#!/usr/bin/env python3
"""Load the real NanoKVM web UI in headless Chromium through the loopback
tunnel with a chosen stored video mode, and report console output plus the
screen element / notification state.

usage: cdp_ui.py <url> <video-mode> [seconds]
"""
import asyncio
import json
import subprocess
import sys
import time
import urllib.request

import websockets

url = sys.argv[1]
mode = sys.argv[2]
run_for = float(sys.argv[3]) if len(sys.argv) > 3 else 20
PORT = 9335
profile = "/tmp/claude-1000/cdp-ui-profile"
subprocess.run(["rm", "-rf", profile], check=False)

chrome = subprocess.Popen(
    ["chromium", "--headless=new", "--no-sandbox", "--ignore-certificate-errors",
     "--autoplay-policy=no-user-gesture-required", "--enable-logging=stderr", "--v=0",
     f"--remote-debugging-port={PORT}", f"--user-data-dir={profile}", "about:blank"],
    stdout=subprocess.DEVNULL, stderr=open("cdp_ui_chrome.err", "w"))

HOOK = """
document.cookie = 'nano-kvm-token=loopback-tunnel-bypass; path=/';
try { localStorage.setItem('nano-kvm-vide-mode', '%s'); } catch (e) {}
""" % mode

PROBE = r"""
(() => {
  const c = document.querySelector('canvas#screen');
  const v = document.querySelector('video#screen');
  const notes = [...document.querySelectorAll('.ant-notification-notice')].map(n => n.innerText.replace(/\s+/g, ' ').trim());
  return JSON.stringify({ href: location.href, title: document.title,
    storedMode: localStorage.getItem('nano-kvm-vide-mode'),
    canvas: c ? { width: c.width, height: c.height } : null,
    video: v ? { videoWidth: v.videoWidth } : null,
    notifications: notes });
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
                console.append(msg["params"].get("type", "") + ": " +
                               " ".join(str(a.get("value", a.get("description", ""))) for a in args)[:400])

        async def call(method, **params):
            nonlocal seq
            seq += 1
            await ws.send(json.dumps({"id": seq, "method": method, "params": params}))
            while True:
                msg = json.loads(await ws.recv())
                note(msg)
                if msg.get("id") == seq:
                    return msg.get("result", msg)

        await call("Page.enable")
        await call("Runtime.enable")
        await call("Page.addScriptToEvaluateOnNewDocument", source=HOOK)
        await call("Page.navigate", url=url)
        t0 = time.time()
        for checkpoint in (6, run_for):
            while time.time() - t0 < checkpoint:
                try:
                    note(json.loads(await asyncio.wait_for(ws.recv(), 0.3)))
                except Exception:
                    pass
            r = await call("Runtime.evaluate", expression=PROBE, returnByValue=True)
            print(f"--- t={int(time.time() - t0)}s")
            print(json.dumps(json.loads(r.get("result", {}).get("value", "{}")), indent=1))
        print("--- console")
        seen = set()
        for c in console:
            if c not in seen:
                seen.add(c)
                print(" ", c)


try:
    asyncio.run(main())
finally:
    chrome.terminate()
    try:
        chrome.wait(5)
    except Exception:
        chrome.kill()
