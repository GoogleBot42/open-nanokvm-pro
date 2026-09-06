#!/usr/bin/env python3
"""Load the real NanoKVM web UI in headless Chromium (CDP) through the loopback
tunnel with a chosen stored video mode; report console output, the screen
element / notification state, and save a full-page screenshot.

usage: cdp_ui.py <url> <video-mode> <seconds> <screenshot.png>
                 [--port N] [--probe-at 6,20,40] [--shot-each]
                 [--action T:JS] ... [--console-full]

See runspec.py for what the flags do (probe checkpoints, per-checkpoint
screenshots, in-page actions at a given second, ordered console).

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

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from runspec import RunSpec, print_console, usage_guard  # noqa: E402

CHROMIUM = os.environ.get(
    "CHROMIUM_BIN",
    "/nix/store/3qgx41z8882ff85y9prdc5zgbb2id6y8-chromium-152.0.7977.64/bin/chromium")

usage_guard(sys.argv)
spec = RunSpec(sys.argv, HERE, default_port=9335, default_shot="cdp_shot.png")
url, mode, run_for = spec.url, spec.mode, spec.run_for

PROBE = open(os.path.join(HERE, "probe.js")).read()

profile = tempfile.mkdtemp(prefix="cdp-ui-profile-")
chrome = subprocess.Popen(
    [CHROMIUM, "--headless=new", "--no-sandbox", "--ignore-certificate-errors",
     "--autoplay-policy=no-user-gesture-required",
     "--disable-application-cache", "--disk-cache-size=1",
     "--window-size=1920,1080",
     "--enable-logging=stderr", "--v=0",
     f"--remote-debugging-port={spec.port}", f"--user-data-dir={profile}", "about:blank"],
    stdout=subprocess.DEVNULL,
    stderr=open(os.path.join(HERE, "cdp_ui_chrome.err"), "w"))

HOOK = """
document.cookie = 'nano-kvm-token=loopback-tunnel-bypass; path=/';
try { localStorage.setItem('nano-kvm-vide-mode', '%s'); } catch (e) {}
""" % mode

# set just before the app is navigated to
T0 = [time.time()]


def targets():
    for _ in range(100):
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{spec.port}/json") as r:
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
            text = None
            if msg.get("method") == "Runtime.consoleAPICalled":
                args = msg["params"].get("args", [])
                text = msg["params"].get("type", "") + ": " + \
                    " ".join(str(a.get("value", a.get("description", ""))) for a in args)[:400]
            elif msg.get("method") == "Runtime.exceptionThrown":
                d = msg["params"].get("exceptionDetails", {})
                text = "exception: " + str(d.get("text")) + " " + \
                    str(d.get("exception", {}).get("description", ""))[:300]
            elif msg.get("method") == "Log.entryAdded":
                e = msg["params"]["entry"]
                text = f"{e.get('level')}[{e.get('source')}]: {str(e.get('text'))[:300]}"
            if text is not None:
                console.append((time.time() - T0[0], text))

        async def call(method, **params):
            nonlocal seq
            seq += 1
            await ws.send(json.dumps({"id": seq, "method": method, "params": params}))
            while True:
                msg = json.loads(await ws.recv())
                note(msg)
                if msg.get("id") == seq:
                    return msg.get("result", msg)

        async def evaluate(expr):
            r = await call("Runtime.evaluate", expression=expr, returnByValue=True,
                           awaitPromise=True)
            details = r.get("exceptionDetails")
            if details:
                return {"exception": str(details.get("text"))[:400]}
            return r.get("result", {}).get("value")

        async def shoot(path):
            r = await call("Page.captureScreenshot", format="png", captureBeyondViewport=True)
            data = r.get("data")
            if data:
                with open(path, "wb") as f:
                    f.write(base64.b64decode(data))
                print(f"--- screenshot {path} ({os.path.getsize(path)} bytes)")
            else:
                print("--- screenshot FAILED", json.dumps(r)[:400])

        async def idle_until(deadline):
            """Pump CDP events (so console/log entries are recorded) until t."""
            while time.time() < deadline:
                try:
                    note(json.loads(await asyncio.wait_for(ws.recv(), 0.3)))
                except Exception:
                    pass

        print(spec.describe())
        await call("Page.enable")
        await call("Runtime.enable")
        await call("Log.enable")
        await call("Network.setCacheDisabled", cacheDisabled=True)
        await call("Page.addScriptToEvaluateOnNewDocument", source=HOOK)
        await call("Page.navigate", url=url)
        t0 = time.time()
        T0[0] = t0

        for at, kind, payload in spec.timeline():
            await idle_until(t0 + at)
            now = time.time() - t0

            if kind == "action":
                print(f"--- action t={now:.1f}s {payload}")
                try:
                    print("   ->", json.dumps(await evaluate(payload))[:600])
                except Exception as err:
                    print("   -> FAILED", err)
                continue

            val = await evaluate(PROBE)
            print(f"--- probe t={int(now)}s")
            try:
                print(json.dumps(json.loads(val), indent=1))
            except Exception:
                print(repr(val)[:2000])
            if spec.shot_each:
                await shoot(spec.shot_path(at))

        await idle_until(t0 + run_for)

        if not spec.shot_each:
            await shoot(spec.shot)

        print_console(console, spec.console_full)


try:
    asyncio.run(main())
finally:
    chrome.terminate()
    try:
        chrome.wait(5)
    except Exception:
        chrome.kill()
    shutil.rmtree(profile, ignore_errors=True)
