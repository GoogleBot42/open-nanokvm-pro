#!/usr/bin/env python3
"""Drive headless Chromium over CDP in REAL time (no virtual-time budget, so
VideoDecoder output callbacks are delivered) and print the harness page's
<pre id="log"> once it contains RESULT.

usage: cdp_run.py <url> [timeout_s]
Requires: chromium on PATH, python3 with `websockets`.
"""
import asyncio
import json
import subprocess
import sys
import time
import urllib.request

import websockets

url = sys.argv[1]
timeout = float(sys.argv[2]) if len(sys.argv) > 2 else 40
PORT = 9333

chrome = subprocess.Popen(
    ["chromium", "--headless=new", "--no-sandbox", "--enable-logging=stderr", "--v=0",
     f"--remote-debugging-port={PORT}", "--user-data-dir=/tmp/claude-1000/cdp-profile",
     "about:blank"],
    stdout=subprocess.DEVNULL, stderr=open("cdp_chrome.err", "w"))


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

        async def call(method, **params):
            nonlocal seq
            seq += 1
            await ws.send(json.dumps({"id": seq, "method": method, "params": params}))
            while True:
                msg = json.loads(await ws.recv())
                if msg.get("id") == seq:
                    return msg.get("result", msg)

        await call("Page.enable")
        await call("Page.navigate", url=url)
        deadline = time.time() + timeout
        text = ""
        while time.time() < deadline:
            r = await call("Runtime.evaluate",
                           expression="(document.getElementById('log')||{}).textContent||''",
                           returnByValue=True)
            text = r.get("result", {}).get("value", "")
            if "RESULT" in text or "FATAL" in text:
                break
            await asyncio.sleep(0.5)
        print(text)


try:
    asyncio.run(main())
finally:
    chrome.terminate()
    try:
        chrome.wait(5)
    except Exception:
        chrome.kill()
