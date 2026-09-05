#!/usr/bin/env python3
"""Load the real NanoKVM web UI in headless Chromium (CDP) through the loopback
tunnel with a chosen stored video mode; report console output, the screen
element / notification state, and save a full-page screenshot.

usage: cdp_ui.py <url> <video-mode> <seconds> <screenshot.png> [--port N]

Fresh profile every run, so the device's cache-less index.html is never stale.
"""
import asyncio
import base64
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request

import websockets

CHROMIUM = os.environ.get(
    "CHROMIUM_BIN",
    "/nix/store/3qgx41z8882ff85y9prdc5zgbb2id6y8-chromium-152.0.7977.64/bin/chromium")
HERE = os.path.dirname(os.path.abspath(__file__))

url = sys.argv[1]
mode = sys.argv[2]
run_for = float(sys.argv[3]) if len(sys.argv) > 3 else 20
shot = os.path.abspath(sys.argv[4]) if len(sys.argv) > 4 else os.path.join(HERE, "cdp_shot.png")
PORT = int(sys.argv[6]) if len(sys.argv) > 6 and sys.argv[5] == "--port" else 9335

PROBE = open(os.path.join(HERE, "probe.js")).read()

profile = tempfile.mkdtemp(prefix="cdp-ui-profile-")
chrome = subprocess.Popen(
    [CHROMIUM, "--headless=new", "--no-sandbox", "--ignore-certificate-errors",
     "--autoplay-policy=no-user-gesture-required",
     "--disable-application-cache", "--disk-cache-size=1",
     "--window-size=1920,1080",
     "--enable-logging=stderr", "--v=0",
     f"--remote-debugging-port={PORT}", f"--user-data-dir={profile}", "about:blank"],
    stdout=subprocess.DEVNULL,
    stderr=open(os.path.join(HERE, "cdp_ui_chrome.err"), "w"))

HOOK = """
document.cookie = 'nano-kvm-token=loopback-tunnel-bypass; path=/';
try { localStorage.setItem('nano-kvm-vide-mode', '%s'); } catch (e) {}
""" % mode


def targets():
    for _ in range(100):
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{PORT}/json") as r:
                t = json.load(r)
                if any(x["type"] == "page" for x in t):
                    return t
        except Exception:
            pass
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
            elif msg.get("method") == "Runtime.exceptionThrown":
                d = msg["params"].get("exceptionDetails", {})
                console.append("exception: " + str(d.get("text")) + " " +
                               str(d.get("exception", {}).get("description", ""))[:300])
            elif msg.get("method") == "Log.entryAdded":
                e = msg["params"]["entry"]
                console.append(f"{e.get('level')}[{e.get('source')}]: {str(e.get('text'))[:300]}")

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
        await call("Log.enable")
        await call("Network.setCacheDisabled", cacheDisabled=True)
        await call("Page.addScriptToEvaluateOnNewDocument", source=HOOK)
        await call("Page.navigate", url=url)
        t0 = time.time()
        for checkpoint in (6, run_for):
            while time.time() - t0 < checkpoint:
                try:
                    note(json.loads(await asyncio.wait_for(ws.recv(), 0.3)))
                except Exception:
                    pass
            r = await call("Runtime.evaluate", expression=PROBE, returnByValue=True,
                           awaitPromise=True)
            print(f"--- probe t={int(time.time() - t0)}s")
            val = r.get("result", {}).get("value")
            try:
                print(json.dumps(json.loads(val), indent=1))
            except Exception:
                print(json.dumps(r, indent=1)[:2000])

        r = await call("Page.captureScreenshot", format="png", captureBeyondViewport=True)
        data = r.get("data")
        if data:
            with open(shot, "wb") as f:
                f.write(base64.b64decode(data))
            print(f"--- screenshot {shot} ({os.path.getsize(shot)} bytes)")
        else:
            print("--- screenshot FAILED", json.dumps(r)[:400])

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
    shutil.rmtree(profile, ignore_errors=True)
