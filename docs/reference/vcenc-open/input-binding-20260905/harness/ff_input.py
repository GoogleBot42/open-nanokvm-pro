#!/usr/bin/env python3
"""Prove that keyboard/mouse input reaches the HID WebSocket in the REAL web UI,
in headless Firefox (WebDriver BiDi) through the loopback tunnel, for a chosen
stored video mode.  Written for #73 ("H.265 Direct auto-MSE path: input dead").

usage: ff_input.py <url> <video-mode> <settle-seconds> <screenshot.png>
                   [--port N] [--json out.json]

Method
------
1. A BiDi preload script (runs before any page script, survives navigation)
   wraps `WebSocket.prototype.send` and counts every frame per socket path,
   bucketed by the app's own message tag byte: 0 heartbeat, 1 keyboard,
   2 mouse (web/src/lib/websocket.ts `MessageEvent`).  The HID socket is
   `/api/ws`.
2. After the page settles, synthetic events are dispatched: `mousemove`,
   `wheel`, `mousedown`/`mouseup` on `#screen`, and `keydown`/`keyup` on
   `document`.  The counter delta is the answer -- mouse frames appear only if
   the mouse hooks actually bound to `#screen`, keyboard frames only if the
   keyboard hook bound to `document`.

The injected events are deliberately harmless to the attached host: the button
is 4 (Forward) and the key is ShiftLeft, so nothing is clicked and no character
is typed -- only the pointer moves and the wheel scrolls.

Fresh profile every run (the device serves index.html with no cache headers,
#71), autoplay unblocked, self-signed cert accepted.  Same conventions as
../../mse-player-20260905/harness/ff_ui.py; use that directory's tunnel.sh.
"""
import asyncio
import base64
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.parse

import websockets

FIREFOX = os.environ.get(
    "FIREFOX_BIN",
    "/nix/store/43rs4f0bccpx10h7fwidvsv4223yjzr5-firefox-154.0.1/bin/firefox")
HERE = os.path.dirname(os.path.abspath(__file__))

args = sys.argv[1:]
opts = {}
positional = []
i = 0
while i < len(args):
    if args[i] in ("--port", "--json"):
        opts[args[i][2:]] = args[i + 1]
        i += 2
    else:
        positional.append(args[i])
        i += 1

url = positional[0]
mode = positional[1]
settle = float(positional[2]) if len(positional) > 2 else 12
shot = os.path.abspath(positional[3]) if len(positional) > 3 else os.path.join(HERE, "ff_input.png")
PORT = int(opts.get("port", 9444))
JSON_OUT = os.path.abspath(opts["json"]) if "json" in opts else None

p = urllib.parse.urlsplit(url)
origin = f"{p.scheme}://{p.netloc}/"

PROBE = open(os.path.join(HERE, "probe.js")).read()

# Runs before every document, ahead of the app's own scripts.
PRELOAD = r"""
() => {
  const counts = {};
  const proto = WebSocket.prototype;
  const orig = proto.send;
  proto.send = function (data) {
    try {
      const path = String(this.url || '').replace(/^wss?:\/\/[^/]+/, '');
      const rec = counts[path] || (counts[path] = { total: 0, bytes: 0, tags: {} });
      rec.total++;
      let tag = 'text';
      let len = 0;
      if (data instanceof ArrayBuffer) { const v = new Uint8Array(data); len = v.length; tag = v[0]; }
      else if (data && data.buffer instanceof ArrayBuffer) { const v = new Uint8Array(data.buffer, data.byteOffset, data.byteLength); len = v.length; tag = v[0]; }
      else if (typeof data === 'string') { len = data.length; }
      rec.bytes += len;
      const name = tag === 0 ? 'heartbeat' : tag === 1 ? 'keyboard' : tag === 2 ? 'mouse'
        : tag === 'text' ? 'text' : ('tag' + tag);
      rec.tags[name] = (rec.tags[name] || 0) + 1;
    } catch (e) { /* never break the app */ }
    return orig.apply(this, arguments);
  };
  window.__wsSend = counts;
}
"""

SEED = """
document.cookie = 'nano-kvm-token=loopback-tunnel-bypass; path=/';
try { localStorage.setItem('nano-kvm-vide-mode', %s); } catch (e) { return 'ERR ' + e; }
return JSON.stringify({cookie: document.cookie, mode: localStorage.getItem('nano-kvm-vide-mode')});
""" % json.dumps(mode)

SNAPSHOT = "JSON.stringify(window.__wsSend || null)"

# Dispatch the synthetic input and report what it landed on.
INJECT = r"""
(() => {
  const el = document.getElementById('screen');
  const out = { screen: el ? el.tagName.toLowerCase() + '#' + el.id : null, dispatched: [] };
  if (el) {
    const r = el.getBoundingClientRect();
    const cx = Math.round(r.left + r.width / 2);
    const cy = Math.round(r.top + r.height / 2);
    out.rect = { x: Math.round(r.left), y: Math.round(r.top), w: Math.round(r.width), h: Math.round(r.height) };
    const mouse = (type, extra) => new MouseEvent(type, Object.assign(
      { bubbles: true, cancelable: true, view: window, clientX: cx, clientY: cy, button: 4, buttons: 16 }, extra || {}));
    // three moves to different points so a coordinate bug is visible too
    for (const [dx, dy] of [[0, 0], [-40, -30], [40, 30]]) {
      el.dispatchEvent(mouse('mousemove', { clientX: cx + dx, clientY: cy + dy }));
      out.dispatched.push('mousemove');
    }
    el.dispatchEvent(mouse('mousedown'));
    el.dispatchEvent(mouse('mouseup'));
    out.dispatched.push('mousedown', 'mouseup');
    el.dispatchEvent(new WheelEvent('wheel', { bubbles: true, cancelable: true, view: window,
      clientX: cx, clientY: cy, deltaY: 120, deltaMode: 0 }));
    out.dispatched.push('wheel');
  }
  // keyboard binds to `document`, independent of #screen; ShiftLeft is a
  // modifier-only report, so nothing is typed on the attached host
  for (const type of ['keydown', 'keyup']) {
    document.dispatchEvent(new KeyboardEvent(type, { bubbles: true, cancelable: true,
      code: 'ShiftLeft', key: 'Shift', location: 1 }));
    out.dispatched.push(type + ':ShiftLeft');
  }
  return JSON.stringify(out);
})()
"""

USER_JS = """
user_pref("media.autoplay.default", 0);
user_pref("media.autoplay.blocking_policy", 0);
user_pref("media.autoplay.block-event.enabled", false);
user_pref("media.block-autoplay-until-in-foreground", false);
user_pref("network.stricttransportsecurity.preloadlist", false);
user_pref("security.enterprise_roots.enabled", false);
user_pref("browser.cache.disk.enable", false);
user_pref("browser.cache.offline.enable", false);
user_pref("browser.shell.checkDefaultBrowser", false);
user_pref("datareporting.policy.dataSubmissionEnabled", false);
user_pref("toolkit.telemetry.enabled", false);
user_pref("browser.aboutwelcome.enabled", false);
user_pref("app.update.auto", false);
user_pref("extensions.autoDisableScopes", 15);
user_pref("dom.disable_beforeunload", true);
user_pref("media.mediasource.enabled", true);
user_pref("media.ffmpeg.enabled", true);
user_pref("dom.media.webcodecs.enabled", true);
"""

profile = tempfile.mkdtemp(prefix="ff-input-profile-")
with open(os.path.join(profile, "user.js"), "w") as f:
    f.write(USER_JS)

errlog = open(os.path.join(HERE, "ff_input_firefox.err"), "w+")
ff = subprocess.Popen(
    [FIREFOX, "--headless", "--no-remote", "--new-instance",
     "--window-size=1920,1080",
     f"--remote-debugging-port={PORT}", "--profile", profile, "about:blank"],
    stdout=subprocess.DEVNULL, stderr=errlog,
    env={**os.environ, "MOZ_HEADLESS": "1", "HOME": profile})


def bidi_url():
    deadline = time.time() + 60
    seen = ""
    while time.time() < deadline:
        errlog.flush()
        with open(errlog.name) as f:
            seen = f.read()
        m = re.search(r"WebDriver BiDi listening on (ws://\S+)", seen)
        if m:
            return m.group(1).rstrip("/") + "/session"
        if ff.poll() is not None:
            raise SystemExit("firefox exited early:\n" + seen[-2000:])
        time.sleep(0.3)
    raise SystemExit("BiDi never announced itself:\n" + seen[-2000:])


class Bidi:
    def __init__(self, ws):
        self.ws = ws
        self.seq = 0
        self.pending = {}
        self.console = []
        self.reader = asyncio.create_task(self._read())

    async def _read(self):
        try:
            async for raw in self.ws:
                msg = json.loads(raw)
                if msg.get("type") == "event":
                    self._event(msg)
                elif "id" in msg:
                    fut = self.pending.pop(msg["id"], None)
                    if fut and not fut.done():
                        fut.set_result(msg)
        except Exception:
            pass

    def _event(self, msg):
        if msg.get("method") == "log.entryAdded":
            e = msg["params"]
            args_ = e.get("args") or []
            text = e.get("text")
            if not text:
                text = " ".join(str(a.get("value", a.get("type"))) for a in args_)
            self.console.append(
                f"{e.get('level')}[{e.get('method') or e.get('type')}]: {str(text)[:400]}")

    async def call(self, method, **params):
        self.seq += 1
        i = self.seq
        fut = asyncio.get_running_loop().create_future()
        self.pending[i] = fut
        await self.ws.send(json.dumps({"id": i, "method": method, "params": params}))
        msg = await asyncio.wait_for(fut, 90)
        if msg.get("type") == "error":
            raise RuntimeError(f"{method}: {msg.get('error')}: {str(msg.get('message'))[:300]}")
        return msg.get("result", {})


def delta(before, after):
    """after - before, per socket path, per tag."""
    out = {}
    for path, rec in (after or {}).items():
        b = (before or {}).get(path, {"total": 0, "bytes": 0, "tags": {}})
        tags = {}
        for tag, n in rec.get("tags", {}).items():
            d = n - b.get("tags", {}).get(tag, 0)
            if d:
                tags[tag] = d
        d_total = rec["total"] - b.get("total", 0)
        if d_total or tags:
            out[path] = {"total": d_total, "bytes": rec["bytes"] - b.get("bytes", 0), "tags": tags}
    return out


async def main():
    result = {"url": url, "mode": mode, "settle": settle}
    wsurl = bidi_url()
    async with websockets.connect(wsurl, max_size=None) as b_ws:
        b = Bidi(b_ws)
        cap = await b.call("session.new", capabilities={
            "alwaysMatch": {"acceptInsecureCerts": True, "webSocketUrl": True}})
        result["browser"] = (cap["capabilities"]["browserName"] + " "
                             + cap["capabilities"]["browserVersion"])
        print("--- browser", result["browser"])
        await b.call("session.subscribe", events=["log.entryAdded"])
        ctx = (await b.call("browsingContext.getTree"))["contexts"][0]["context"]

        async def ev(expr, awaitp=True):
            r = await b.call("script.evaluate", expression=expr, target={"context": ctx},
                             awaitPromise=awaitp, resultOwnership="none", userActivation=True)
            if r.get("type") == "exception":
                return {"exception": str(r.get("exceptionDetails", {}).get("text"))[:400]}
            return r.get("result", {}).get("value")

        # the WebSocket counter must exist before the app opens /api/ws
        await b.call("script.addPreloadScript", functionDeclaration=PRELOAD)

        # cookie + stored video mode need an origin to live in
        await b.call("browsingContext.navigate", context=ctx, url=origin, wait="complete")
        seeded = await ev("(() => {" + SEED + "})()")
        print("--- seeded", seeded)
        result["seeded"] = seeded

        # boot the app
        await b.call("browsingContext.navigate", context=ctx, url=url, wait="complete")
        t0 = time.time()
        while time.time() - t0 < settle:
            await asyncio.sleep(0.2)

        probe = await ev(PROBE)
        try:
            result["probe"] = json.loads(probe)
        except Exception:
            result["probe"] = {"raw": str(probe)[:2000]}
        print("--- probe")
        print(json.dumps(result["probe"], indent=1))

        before = json.loads(await ev(SNAPSHOT) or "null")
        result["before"] = before
        print("--- ws counters before")
        print(json.dumps(before, indent=1))

        injected = json.loads(await ev(INJECT))
        result["injected"] = injected
        print("--- injected", json.dumps(injected))

        await asyncio.sleep(1.0)
        after = json.loads(await ev(SNAPSHOT) or "null")
        result["after"] = after
        result["delta"] = delta(before, after)
        print("--- ws counters delta (injection only)")
        print(json.dumps(result["delta"], indent=1))

        hid = result["delta"].get("/api/ws", {}).get("tags", {})
        result["verdict"] = {
            "screen_present": bool(injected.get("screen")),
            "mouse_frames": hid.get("mouse", 0),
            "keyboard_frames": hid.get("keyboard", 0),
            "mouse_ok": hid.get("mouse", 0) > 0,
            "keyboard_ok": hid.get("keyboard", 0) > 0,
        }
        print("--- verdict", json.dumps(result["verdict"]))

        r = await b.call("browsingContext.captureScreenshot", context=ctx, origin="document")
        with open(shot, "wb") as f:
            f.write(base64.b64decode(r["data"]))
        print(f"--- screenshot {shot} ({os.path.getsize(shot)} bytes)")
        result["screenshot"] = shot

        console = []
        seen = set()
        for c in b.console:
            if c not in seen:
                seen.add(c)
                console.append(c)
        result["console"] = console
        print("--- console")
        for c in console:
            print(" ", c)

        try:
            await b.call("session.end")
        except Exception:
            pass

    if JSON_OUT:
        with open(JSON_OUT, "w") as f:
            json.dump(result, f, indent=1)
        print(f"--- json {JSON_OUT}")

    v = result["verdict"]
    return 0 if (v["mouse_ok"] and v["keyboard_ok"]) else 1


rc = 1
try:
    rc = asyncio.run(main())
finally:
    ff.terminate()
    try:
        ff.wait(8)
    except Exception:
        ff.kill()
    errlog.close()
    shutil.rmtree(profile, ignore_errors=True)
sys.exit(rc)
