#!/usr/bin/env python3
"""#67 (direct players reconnect) and #70 (mode change swaps the player in
place) in a real browser, through the loopback tunnel (tunnel.sh in the
h264-direct-chromium-20260905 harness).

Both claims are about page LIFETIME, so the oracles are things a reload would
destroy:

  #67  window.WebSocket is wrapped before the app loads, counting sockets
       opened per URL and messages received on each. The device's
       nanokvm.service is restarted mid-run; a reconnecting player opens a
       SECOND socket to /api/stream/h264/direct and its message count keeps
       climbing. A page that reloaded instead would reset the counters to one
       socket, and the sentinel below would be gone.

  #70  a sentinel is written into `window` AFTER load, then the video mode is
       changed through the real menu (hover the "Video" item, click a mode in
       the popover). If the sentinel survives, the page did not reload; the
       socket counters then show the old player's socket closed and the new
       mode's socket opened.

usage: cdp_reconnect.py <url> <restart-command> [seconds]
       restart-command is run on the HOST and is expected to restart
       nanokvm.service on the device (e.g. "tools/kvmssh 'systemctl restart
       nanokvm'").
"""
import asyncio
import json
import subprocess
import sys
import time
import urllib.request

import websockets

url = sys.argv[1]
restart_cmd = sys.argv[2]
run_for = float(sys.argv[3]) if len(sys.argv) > 3 else 60
PORT = 9337
profile = "/tmp/claude-1000/cdp-reconnect-profile"
subprocess.run(["rm", "-rf", profile], check=False)

chrome = subprocess.Popen(
    ["chromium", "--headless=new", "--no-sandbox", "--ignore-certificate-errors",
     "--autoplay-policy=no-user-gesture-required", "--enable-logging=stderr", "--v=0",
     f"--remote-debugging-port={PORT}", f"--user-data-dir={profile}", "about:blank"],
    stdout=subprocess.DEVNULL, stderr=open("cdp_reconnect_chrome.err", "w"))

# Runs before any app script, and again after a reload -- which is the point:
# __wsStats starting over is how a reload shows up.
HOOK = """
document.cookie = 'nano-kvm-token=loopback-tunnel-bypass; path=/';
try { localStorage.setItem('nano-kvm-vide-mode', 'h264-direct'); } catch (e) {}
(() => {
  const Native = window.WebSocket;
  window.__wsStats = { loads: (window.__wsStats?.loads || 0) + 1, sockets: [] };
  function Wrapped(url, protocols) {
    const sock = protocols === undefined ? new Native(url) : new Native(url, protocols);
    const rec = { url: String(url), opened: Date.now(), msgs: 0, closed: null };
    window.__wsStats.sockets.push(rec);
    sock.addEventListener('message', () => { rec.msgs++; });
    sock.addEventListener('close', () => { rec.closed = Date.now(); });
    return sock;
  }
  Wrapped.prototype = Native.prototype;
  for (const k of ['CONNECTING', 'OPEN', 'CLOSING', 'CLOSED']) Wrapped[k] = Native[k];
  window.WebSocket = Wrapped;
})();
"""

STATS = r"""
(() => {
  const s = window.__wsStats || { loads: 0, sockets: [] };
  const stream = s.sockets.filter(x => /\/api\/stream\//.test(x.url));
  return JSON.stringify({
    sentinel: window.__sentinel ?? null,
    loads: s.loads,
    canvas: (() => { const c = document.querySelector('canvas#screen'); return c ? `${c.width}x${c.height}` : null; })(),
    video: (() => { const v = document.querySelector('video#screen'); return v ? `${v.videoWidth}x${v.videoHeight}` : null; })(),
    // what useScreenElement binds input to: the tag tells you which player is mounted
    screenEl: (() => { const e = document.getElementById('screen'); return e ? e.tagName.toLowerCase() : null; })(),
    streamSockets: stream.map(x => ({ url: x.url.replace(/^wss?:\/\/[^/]+/, ''), msgs: x.msgs, closed: !!x.closed }))
  });
})()
"""

# The mode list is two popovers deep: the icon-only sidebar's "Screen" item
# (lucide-monitor) opens a submenu on CLICK (components/menu-item.tsx sets
# trigger="click"), and that submenu's video item (lucide-tv-minimal-play) opens
# the mode list on HOVER (the default trigger). Locate each by its lucide icon
# class rather than its label, so the run does not depend on the UI language;
# a hover means dispatching the pointer events rc-trigger listens for, and each
# popover gets its open delay before the next step reaches into it.
ACTIVATE = r"""
(() => {
  const icon = document.querySelector('svg.%(cls)s');
  if (!icon) return 'not found: %(cls)s';
  const hit = icon.closest('div');
  if ('%(how)s' === 'click') {
    hit.click();
  } else {
    for (const type of ['pointerenter', 'pointerover', 'mouseenter', 'mouseover'])
      hit.dispatchEvent(new MouseEvent(type, { bubbles: true, cancelable: true }));
  }
  return '%(how)s %(cls)s -> ' + document.querySelectorAll('.ant-popover').length + ' popovers';
})()
"""

# The mode rows are <div><div>[check]</div><span>LABEL</span></div>; click the
# row, not the label, and never the group wrapper (which has no handler).
PICK_MODE = r"""
(() => {
  const want = %s;
  const span = [...document.querySelectorAll('span')].find(s => s.innerText.trim() === want);
  if (!span || !span.parentElement) return 'mode row not found: ' + want;
  span.parentElement.click();
  return 'clicked: ' + want;
})()
"""


def targets():
    for _ in range(50):
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{PORT}/json") as r:
                return json.load(r)
        except Exception:
            time.sleep(0.2)
    raise SystemExit("devtools endpoint never came up")


async def main():
    page = next(t for t in targets() if t["type"] == "page")
    async with websockets.connect(page["webSocketDebuggerUrl"], max_size=None) as ws:
        seq = 0
        console = []

        def note(msg):
            if msg.get("method") == "Runtime.consoleAPICalled":
                args = msg["params"].get("args", [])
                console.append(msg["params"].get("type", "") + ": " + " ".join(
                    str(a.get("value", a.get("description", ""))) for a in args)[:300])

        async def call(method, **params):
            nonlocal seq
            seq += 1
            await ws.send(json.dumps({"id": seq, "method": method, "params": params}))
            while True:
                msg = json.loads(await ws.recv())
                note(msg)
                if msg.get("id") == seq:
                    return msg.get("result", msg)

        async def idle(seconds):
            end = time.time() + seconds
            while time.time() < end:
                try:
                    note(json.loads(await asyncio.wait_for(ws.recv(), 0.3)))
                except Exception:
                    pass

        async def stats(label):
            r = await call("Runtime.evaluate", expression=STATS, returnByValue=True)
            data = json.loads(r.get("result", {}).get("value", "{}"))
            print(f"--- {label}")
            print(json.dumps(data, indent=1))
            return data

        await call("Page.enable")
        await call("Runtime.enable")
        await call("Page.addScriptToEvaluateOnNewDocument", source=HOOK)
        await call("Page.navigate", url=url)

        await idle(12)
        # a reload wipes this; every later probe reports it
        await call("Runtime.evaluate", expression="window.__sentinel = 'alive';")
        before = await stats("t=12s  h264-direct running")

        print(f"--- restarting the service: {restart_cmd}")
        subprocess.run(restart_cmd, shell=True, check=False,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        await idle(30)
        after = await stats("t=42s  after the service restart (#67)")

        for cls, how in (("lucide-monitor", "click"), ("lucide-tv-minimal-play", "hover")):
            print("---", (await call("Runtime.evaluate",
                                     expression=ACTIVATE % {"cls": cls, "how": how},
                                     returnByValue=True))["result"].get("value"))
            await idle(1.5)
        print("---", (await call("Runtime.evaluate", expression=PICK_MODE % '"MJPEG"',
                                 returnByValue=True))["result"].get("value"))
        await idle(10)
        switched = await stats("after the mode change (#70)")

        print("--- console")
        seen = set()
        for c in console:
            if c not in seen:
                seen.add(c)
                print(" ", c)

        direct_before = [s for s in before["streamSockets"] if "h264/direct" in s["url"]]
        direct_after = [s for s in after["streamSockets"] if "h264/direct" in s["url"]]
        grew = (sum(s["msgs"] for s in direct_after) > sum(s["msgs"] for s in direct_before)
                and len(direct_after) > len(direct_before))

        print()
        print(f"#67 reconnect : sockets {len(direct_before)} -> {len(direct_after)}, "
              f"messages {sum(s['msgs'] for s in direct_before)} -> {sum(s['msgs'] for s in direct_after)}, "
              f"loads {before['loads']} -> {after['loads']}, sentinel {after['sentinel']}")
        print(f"  {'PASS' if grew and after['loads'] == 1 and after['sentinel'] == 'alive' else 'FAIL'}")
        # MJPEG mounts antd's <Image id="screen">, which puts the id on its
        # wrapper div rather than the <img>; either way the canvas is gone and
        # the direct sockets are closed, with the page never having reloaded.
        swapped = (switched["loads"] == 1 and switched["sentinel"] == "alive"
                   and switched["canvas"] is None and switched["screenEl"] in ("img", "div")
                   and all(s["closed"] for s in switched["streamSockets"] if "h264/direct" in s["url"]))
        print(f"#70 in-place  : loads {switched['loads']}, sentinel {switched['sentinel']}, "
              f"canvas {switched['canvas']}, screenEl {switched['screenEl']}, direct sockets closed "
              f"{[s['closed'] for s in switched['streamSockets'] if 'h264/direct' in s['url']]}")
        print(f"  {'PASS' if swapped else 'FAIL'}")


try:
    asyncio.run(main())
finally:
    chrome.terminate()
    try:
        chrome.wait(5)
    except Exception:
        chrome.kill()
