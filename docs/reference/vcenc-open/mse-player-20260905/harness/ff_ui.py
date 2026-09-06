#!/usr/bin/env python3
"""Load the real NanoKVM web UI in headless Firefox (WebDriver BiDi) through the
loopback tunnel with a chosen stored video mode; report console output, the
screen element / notification state, and save a full-page screenshot.

usage: ff_ui.py <url> <video-mode> <seconds> <screenshot.png>
                [--port N] [--probe-at 6,20,40] [--shot-each]
                [--action T:JS] ... [--console-full]

See runspec.py for what the flags do (probe checkpoints, per-checkpoint
screenshots, in-page actions at a given second, ordered console).

Fresh profile every run (so the device's cache-less index.html is never stale)
with autoplay unblocked and self-signed certs accepted.
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

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from runspec import RunSpec, print_console, usage_guard  # noqa: E402

FIREFOX = os.environ.get(
    "FIREFOX_BIN",
    "/nix/store/43rs4f0bccpx10h7fwidvsv4223yjzr5-firefox-154.0.1/bin/firefox")

usage_guard(sys.argv)
spec = RunSpec(sys.argv, HERE, default_port=9444, default_shot="ff_shot.png")
url, mode, run_for = spec.url, spec.mode, spec.run_for

p = urllib.parse.urlsplit(url)
origin = f"{p.scheme}://{p.netloc}/"

PROBE = open(os.path.join(HERE, "probe.js")).read()
HOOK = """
document.cookie = 'nano-kvm-token=loopback-tunnel-bypass; path=/';
try { localStorage.setItem('nano-kvm-vide-mode', %s); } catch (e) { return 'ERR ' + e; }
return JSON.stringify({cookie: document.cookie, mode: localStorage.getItem('nano-kvm-vide-mode')});
""" % json.dumps(mode)

USER_JS = """
// autoplay: allow everything, no user gesture needed
user_pref("media.autoplay.default", 0);
user_pref("media.autoplay.blocking_policy", 0);
user_pref("media.autoplay.block-event.enabled", false);
user_pref("media.block-autoplay-until-in-foreground", false);
// self-signed cert on the tunnel
user_pref("network.stricttransportsecurity.preloadlist", false);
user_pref("security.enterprise_roots.enabled", false);
// never serve a stale index.html
user_pref("browser.cache.disk.enable", false);
user_pref("browser.cache.offline.enable", false);
// quiet first-run / telemetry noise
user_pref("browser.shell.checkDefaultBrowser", false);
user_pref("datareporting.policy.dataSubmissionEnabled", false);
user_pref("toolkit.telemetry.enabled", false);
user_pref("browser.aboutwelcome.enabled", false);
user_pref("app.update.auto", false);
user_pref("extensions.autoDisableScopes", 15);
user_pref("dom.disable_beforeunload", true);
// media stack
user_pref("media.mediasource.enabled", true);
user_pref("media.ffmpeg.enabled", true);
user_pref("dom.media.webcodecs.enabled", true);
"""

profile = tempfile.mkdtemp(prefix="ff-ui-profile-")
with open(os.path.join(profile, "user.js"), "w") as f:
    f.write(USER_JS)

errlog = open(os.path.join(HERE, "ff_ui_firefox.err"), "w+")
ff = subprocess.Popen(
    [FIREFOX, "--headless", "--no-remote", "--new-instance",
     "--window-size=1920,1080",
     f"--remote-debugging-port={spec.port}", "--profile", profile, "about:blank"],
    stdout=subprocess.DEVNULL, stderr=errlog,
    env={**os.environ, "MOZ_HEADLESS": "1", "HOME": profile})

# set just before the app is navigated to, so console timestamps are relative
# to the page load
T0 = [time.time()]


def bidi_url():
    """Wait for the remote agent banner on stderr, then return its ws:// URL."""
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
            args = e.get("args") or []
            text = e.get("text")
            if not text:
                text = " ".join(str(a.get("value", a.get("type"))) for a in args)
            self.console.append((time.time() - T0[0],
                                 f"{e.get('level')}[{e.get('method') or e.get('type')}]: {str(text)[:400]}"))

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


async def main():
    wsurl = bidi_url()
    async with websockets.connect(wsurl, max_size=None) as ws:
        b = Bidi(ws)
        cap = await b.call("session.new", capabilities={
            "alwaysMatch": {"acceptInsecureCerts": True,
                            "webSocketUrl": True}})
        print("--- browser", cap["capabilities"]["browserName"],
              cap["capabilities"]["browserVersion"])
        print(spec.describe())
        await b.call("session.subscribe", events=["log.entryAdded"])
        ctx = (await b.call("browsingContext.getTree"))["contexts"][0]["context"]

        async def ev(expr, awaitp=True):
            r = await b.call("script.evaluate", expression=expr,
                             target={"context": ctx}, awaitPromise=awaitp,
                             resultOwnership="none",
                             userActivation=True)
            if r.get("type") == "exception":
                return {"exception": str(r.get("exceptionDetails", {}).get("text"))[:400]}
            return r.get("result", {}).get("value")

        async def shoot(path):
            r = await b.call("browsingContext.captureScreenshot", context=ctx,
                             origin="document")
            with open(path, "wb") as f:
                f.write(base64.b64decode(r["data"]))
            print(f"--- screenshot {path} ({os.path.getsize(path)} bytes)")

        # 1. reach the origin once so cookie + localStorage have a home
        await b.call("browsingContext.navigate", context=ctx, url=origin, wait="complete")
        seeded = await ev("(() => {" + HOOK + "})()")
        print("--- seeded", seeded)

        # 2. now boot the app
        await b.call("browsingContext.navigate", context=ctx, url=url, wait="complete")
        t0 = time.time()
        T0[0] = t0

        for at, kind, payload in spec.timeline():
            while time.time() - t0 < at:
                await asyncio.sleep(0.2)
            now = time.time() - t0

            if kind == "action":
                print(f"--- action t={now:.1f}s {payload}")
                try:
                    print("   ->", json.dumps(await ev(payload))[:600])
                except Exception as err:
                    print("   -> FAILED", err)
                continue

            val = await ev(PROBE)
            print(f"--- probe t={int(now)}s")
            try:
                print(json.dumps(json.loads(val), indent=1))
            except Exception:
                print(repr(val)[:2000])
            if spec.shot_each:
                await shoot(spec.shot_path(at))

        while time.time() - t0 < run_for:
            await asyncio.sleep(0.2)

        if not spec.shot_each:
            await shoot(spec.shot)

        print_console(b.console, spec.console_full)
        try:
            await b.call("session.end")
        except Exception:
            pass


try:
    asyncio.run(main())
finally:
    ff.terminate()
    try:
        ff.wait(8)
    except Exception:
        ff.kill()
    errlog.close()
    shutil.rmtree(profile, ignore_errors=True)
