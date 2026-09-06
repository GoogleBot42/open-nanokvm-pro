#!/usr/bin/env python3
"""Does a warm browser pick up a redeployed index.html? (#71)

usage: cdp_swap.py <url> <swap-command> [--port N]

The deploy test, end to end, in a real browser with a WARM cache:

  1 load <url> in headless Chromium (fresh profile, cache ENABLED) and read
    the <meta name="cache-probe"> marker the page was built with
  2 run <swap-command> -- the "deploy": it edits index.html on the device
  3 navigate away and back (an ordinary page open, warm cache)
  4 reload (F5)

and report the marker the browser saw at each step. Marker unchanged after a
deploy = the browser is running a stale index.html, which with hashed chunk
names means it is also asking for chunks that no longer exist.

Cert handling and the profile follow cdp_cache.py; see the note there about
why the cert is pinned rather than ignored.
"""
import asyncio
import json
import os
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
swap_cmd = sys.argv[2]
PORT = int(sys.argv[4]) if len(sys.argv) > 4 and sys.argv[3] == "--port" else 9338

SPKI = os.environ.get("DEVICE_SPKI", "mdfTDLxhu5sylP0GqqSoykKSDz4G19G0bM5jJmYo9g0=")

profile = tempfile.mkdtemp(prefix="cdp-swap-profile-")
chrome = subprocess.Popen(
    [CHROMIUM, "--headless=new", "--no-sandbox",
     "--ignore-certificate-errors-spki-list=" + SPKI,
     "--window-size=1280,800", f"--remote-debugging-port={PORT}",
     f"--user-data-dir={profile}", "about:blank"],
    stdout=subprocess.DEVNULL,
    stderr=open(os.path.join(HERE, "cdp_swap_chrome.err"), "w"))

HOOK = "document.cookie = 'nano-kvm-token=loopback-tunnel-bypass; path=/';"

PROBE = """(() => {
  const m = document.querySelector('meta[name="cache-probe"]');
  const s = document.querySelector('script[type="module"]');
  return JSON.stringify({marker: m ? m.content : null,
                         entry: s ? s.getAttribute('src') : null});
})()"""


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
        doc = {"src": "?", "len": 0}

        def note(msg):
            if msg.get("method") == "Network.responseReceived":
                p = msg["params"]
                if p.get("type") == "Document":
                    r = p["response"]
                    doc["src"] = ("disk-cache" if r.get("fromDiskCache")
                                  else "network")
            elif msg.get("method") == "Network.loadingFinished":
                pass

        async def call(method, **params):
            nonlocal seq
            seq += 1
            await ws.send(json.dumps({"id": seq, "method": method, "params": params}))
            while True:
                msg = json.loads(await ws.recv())
                note(msg)
                if msg.get("id") == seq:
                    return msg.get("result", msg)

        async def settle(sec):
            t0 = time.time()
            while time.time() - t0 < sec:
                try:
                    note(json.loads(await asyncio.wait_for(ws.recv(), 0.25)))
                except Exception:
                    pass

        async def report(label):
            await settle(4)
            r = await call("Runtime.evaluate", expression=PROBE, returnByValue=True)
            v = json.loads(r["result"]["value"])
            print(f"    {label:34} document={doc['src']:11} "
                  f"marker={v['marker']}  entry={v['entry']}")

        await call("Page.enable")
        await call("Network.enable")
        await call("Runtime.enable")
        await call("Network.setCacheDisabled", cacheDisabled=False)
        await call("Page.addScriptToEvaluateOnNewDocument", source=HOOK)

        await call("Page.navigate", url=url)
        await report("1 cold load")

        print(f"--- deploy: {swap_cmd}")
        rc = subprocess.run(swap_cmd, shell=True).returncode
        print(f"--- deploy exit {rc}")

        await call("Page.navigate", url="about:blank")
        await settle(1)
        await call("Page.navigate", url=url)
        await report("2 open the page again (warm)")

        await call("Page.reload")
        await report("3 reload / F5 (warm)")


try:
    asyncio.run(main())
finally:
    chrome.terminate()
    try:
        chrome.wait(5)
    except Exception:
        chrome.kill()
