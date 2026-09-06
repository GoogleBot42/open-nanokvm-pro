#!/usr/bin/env python3
"""Prove the web bundle's HTTP caching in a real browser (#71).

usage: cdp_cache.py <url> [--port N]

Headless Chromium, ONE persistent profile, cache ENABLED (the opposite of
cdp_ui.py, which disables it so a stale index.html can never confuse a video
test). Three phases against the same browser:

  A cold      empty cache, first navigation
  B navigate  about:blank, then back to <url> -- a genuine fresh navigation,
              which uses ordinary cache rules. This is the case heuristic
              freshness breaks: with no Cache-Control and a 1970
              Last-Modified the document is "fresh" for years and Chrome
              never asks the device about it again.
  C reload    Page.reload(), the F5 Jeremy has been fighting.

For each phase it reports, per request: HTTP status, whether it came off the
network or out of a cache, and the response's Cache-Control / ETag.
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
PORT = int(sys.argv[3]) if len(sys.argv) > 3 and sys.argv[2] == "--port" else 9337

# Device cert SPKI pin (harness/spki.sh). Regenerate if the device cert changes.
SPKI = os.environ.get("DEVICE_SPKI", "mdfTDLxhu5sylP0GqqSoykKSDz4G19G0bM5jJmYo9g0=")

profile = tempfile.mkdtemp(prefix="cdp-cache-profile-")
chrome = subprocess.Popen(
    [CHROMIUM, "--headless=new", "--no-sandbox",
     # Pin the device cert as TRUSTED rather than --ignore-certificate-errors:
     # Chromium refuses to write a cert-ERROR response to its HTTP cache, which
     # would make every resource look uncacheable no matter what we send.
     # SPKI from harness/spki.sh (regenerate if the device cert changes).
     os.environ.get("SPKI_ARG", "--ignore-certificate-errors-spki-list=" + SPKI),
     "--window-size=1280,800", f"--remote-debugging-port={PORT}",
     f"--user-data-dir={profile}", "about:blank"],
    stdout=subprocess.DEVNULL,
    stderr=open(os.path.join(HERE, "cdp_cache_chrome.err"), "w"))

HOOK = "document.cookie = 'nano-kvm-token=loopback-tunnel-bypass; path=/';"


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


def short(u):
    return u.split("://", 1)[-1].split("/", 1)[-1] or "/"


async def main():
    page = next(t for t in targets() if t["type"] == "page")
    async with websockets.connect(page["webSocketDebuggerUrl"], max_size=None) as ws:
        seq = 0
        reqs = {}      # requestId -> record
        order = []
        loaded = [False]

        def note(msg):
            m = msg.get("method")
            p = msg.get("params", {})
            if m == "Network.requestWillBeSent":
                rid = p["requestId"]
                if rid not in reqs:
                    reqs[rid] = {"url": p["request"]["url"], "cached": False,
                                 "status": None, "cc": "", "etag": "",
                                 "proto": "", "len": 0}
                    order.append(rid)
            elif m == "Network.requestServedFromCache":
                r = reqs.get(p["requestId"])
                if r:
                    r["cached"] = "memory-cache"
            elif m == "Network.responseReceived":
                r = reqs.get(p["requestId"])
                if not r:
                    return
                resp = p["response"]
                r["status"] = resp.get("status")
                h = {k.lower(): v for k, v in resp.get("headers", {}).items()}
                r["cc"] = h.get("cache-control", "-")
                r["etag"] = h.get("etag", "-")
                r["proto"] = resp.get("protocol", "")
                if resp.get("fromDiskCache"):
                    r["cached"] = "disk-cache"
                elif resp.get("fromPrefetchCache"):
                    r["cached"] = "prefetch-cache"
            elif m == "Network.loadingFinished":
                r = reqs.get(p["requestId"])
                if r:
                    r["len"] = int(p.get("encodedDataLength", 0))
            elif m == "Page.loadEventFired":
                loaded[0] = True

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

        async def phase(label, action):
            reqs.clear()
            order.clear()
            loaded[0] = False
            await action()
            await settle(6)
            print(f"\n=== phase {label}")
            print(f"    {'resource':44} {'status':>6}  {'source':13} {'bytes':>8}  cache-control / etag")
            for rid in order:
                r = reqs[rid]
                if not r["url"].startswith("https://"):
                    continue
                src = r["cached"] or "network"
                print(f"    {short(r['url'])[:44]:44} {str(r['status']):>6}  "
                      f"{src:13} {r['len']:>8}  {r['cc']} | {r['etag']}")

        await call("Page.enable")
        await call("Network.enable")
        await call("Network.setCacheDisabled", cacheDisabled=False)
        await call("Page.addScriptToEvaluateOnNewDocument", source=HOOK)

        await phase("A cold (empty cache)", lambda: call("Page.navigate", url=url))

        async def renavigate():
            await call("Page.navigate", url="about:blank")
            await settle(1)
            reqs.clear()
            order.clear()
            await call("Page.navigate", url=url)

        await phase("B fresh navigation (warm cache)", renavigate)
        await phase("C reload (F5, warm cache)", lambda: call("Page.reload"))


try:
    asyncio.run(main())
finally:
    chrome.terminate()
    try:
        chrome.wait(5)
    except Exception:
        chrome.kill()
