#!/usr/bin/env python3
"""Headed Chromium on an Xvfb display against the real NanoKVM web UI through the
loopback tunnel. Seeds the video mode, then at checkpoints reports the <video>
state, WebRTC stats, a drawImage() pixel sample of the video, AND an X-server
framebuffer grab (what is really on screen), analysed for whiteness.

usage: xvfb_chrome.py <url> <mode> <seconds> <outdir> [--display N] [--port N] [--headless] [-- extra chromium flags]
"""
import asyncio, json, os, subprocess, sys, time, urllib.request, shutil
import websockets
from PIL import Image

CHROMIUM = os.environ.get("CHROMIUM_BIN", "/nix/store/3qgx41z8882ff85y9prdc5zgbb2id6y8-chromium-152.0.7977.64/bin/chromium")
XVFB = "/nix/store/2ngsl5s8gmkbvav54pg2khb5ykxc4d10-xvfb-21.1.24/bin/Xvfb"
IMPORT = "/nix/store/1fj0wg21ba24hv612yg4kqwzxbnyappm-imagemagick-7.1.2-29/bin/import"

args = sys.argv[1:]
extra = []
if "--" in args:
    i = args.index("--"); extra = args[i + 1:]; args = args[:i]
url, mode, secs, outdir = args[0], args[1], float(args[2]), os.path.abspath(args[3])
display = "99"; port = 9340; headless = False; wayland = False
SWAY = "/nix/store/hnvycxmyhl4r4s5mphzx13xxrzfbpxi2-sway-1.12/bin/sway"
GRIM = "/nix/store/j46b9y2gj3dyw2mma1hl2wcbz3b6llws-grim-1.5.0/bin/grim"
WESTON_DIR = "/nix/store/bym3mrisbsrph2654wj5bhc1x5ijhv0q-weston-16.0.0/bin"
weston = False; kwin = False
KWIN = "/nix/store/dnhnbjfygx79an8s30kif7iniawdnqc5-kwin-6.7.4/bin/kwin_wayland"
SPECTACLE = os.environ.get("SPECTACLE_BIN", "")
i = 4
while i < len(args):
    if args[i] == "--display": display = args[i + 1]; i += 2
    elif args[i] == "--port": port = int(args[i + 1]); i += 2
    elif args[i] == "--headless": headless = True; i += 1
    elif args[i] == "--wayland": wayland = True; i += 1
    elif args[i] == "--weston": wayland = True; weston = True; i += 1
    elif args[i] == "--kwin": wayland = True; kwin = True; i += 1
    else: i += 1
os.makedirs(outdir, exist_ok=True)
profile = os.path.join(outdir, "profile"); shutil.rmtree(profile, ignore_errors=True)
W, H = 1600, 1000

xvfb = None
env = dict(os.environ)
if kwin:
    env.update({"XDG_RUNTIME_DIR": "/run/user/1000", "WAYLAND_DISPLAY": f"wayland-k{display}",
                "KWIN_WAYLAND_NO_PERMISSION_CHECKS": "1", "KWIN_SCREENSHOT_NO_PERMISSION_CHECKS": "1", "QT_QPA_PLATFORM": "wayland"})
    env.pop("DISPLAY", None)
    klog = os.path.join(outdir, "kwin.out")
    kenv = dict(env); kenv.pop("WAYLAND_DISPLAY", None)
    here = os.path.dirname(os.path.abspath(__file__))
    kenv["XDG_DATA_HOME"] = os.path.join(here, "kwin-data")
    kenv["XDG_CACHE_HOME"] = os.path.join(here, "kwin-cache")
    kenv["XDG_DATA_DIRS"] = "/nix/store/x8n3i66y4vw76zfg5r8m1ss2qc7bwd79-spectacle-6.7.4/share:/run/current-system/sw/share"
    xvfb = subprocess.Popen([KWIN, "--virtual", f"--width={W}", f"--height={H}", "--no-lockscreen", "--no-global-shortcuts",
                             "--no-kactivities", "--socket", env["WAYLAND_DISPLAY"], *os.environ.get("KWIN_ARGS", "").split()],
                            env=kenv, stdout=open(klog, "w"), stderr=subprocess.STDOUT)
    for _ in range(100):
        if os.path.exists(f"/run/user/1000/{env['WAYLAND_DISPLAY']}"): break
        time.sleep(0.2)
    else:
        raise SystemExit("kwin never created its socket: " + open(klog).read()[-2000:])
    time.sleep(2.0)
    print("--- kwin socket", env["WAYLAND_DISPLAY"], "args", os.environ.get("KWIN_ARGS", ""))
    if os.environ.get("KWIN_SETUP"):
        r = subprocess.run(os.environ["KWIN_SETUP"], shell=True, env=env, capture_output=True, text=True, timeout=60)
        print("--- kwin setup rc", r.returncode, (r.stdout + r.stderr).strip()[-1500:])
        time.sleep(1.0)
    extra = ["--ozone-platform=wayland", *extra]
elif weston:
    ini = os.path.join(outdir, "weston.ini")
    cm = os.environ.get("WESTON_CM", "true")
    open(ini, "w").write(f"[core]\ncolor-management={cm}\nidle-time=0\n[shell]\npanel-position=none\nbackground-color=0xff808080\nlocking=false\n")
    env.update({"XDG_RUNTIME_DIR": "/run/user/1000", "WAYLAND_DISPLAY": f"wayland-9{display[-1]}"})
    env.pop("DISPLAY", None)
    wlog = os.path.join(outdir, "weston.out")
    xvfb = subprocess.Popen([f"{WESTON_DIR}/weston", "--backend=headless", f"--renderer={os.environ.get('WESTON_RENDERER', 'gl')}",
                             f"--width={W}", f"--height={H}", f"--socket={env['WAYLAND_DISPLAY']}", f"--config={ini}", "--debug"],
                            env=env, stdout=open(wlog, "w"), stderr=subprocess.STDOUT)
    for _ in range(50):
        if os.path.exists(f"/run/user/1000/{env['WAYLAND_DISPLAY']}"): break
        time.sleep(0.2)
    else:
        raise SystemExit("weston never created its socket: " + open(wlog).read()[-2000:])
    time.sleep(1.5)
    print("--- weston socket", env["WAYLAND_DISPLAY"], "color-management", cm)
    extra = ["--ozone-platform=wayland", *extra]
elif wayland:
    cfg = os.path.join(outdir, "sway.cfg")
    open(cfg, "w").write(f"output HEADLESS-1 resolution {W}x{H} position 0,0\ndefault_border none\nfocus_follows_mouse no\n")
    env.update({"WLR_BACKENDS": "headless", "WLR_LIBINPUT_NO_DEVICES": "1", "WLR_RENDERER": os.environ.get("WLR_RENDERER", "pixman"),
                "XDG_RUNTIME_DIR": "/run/user/1000"})
    env.pop("DISPLAY", None); env.pop("WAYLAND_DISPLAY", None)
    swaylog = os.path.join(outdir, "sway.out")
    xvfb = subprocess.Popen([SWAY, "-c", cfg, "--unsupported-gpu", "--verbose"], env=env,
                            stdout=open(swaylog, "w"), stderr=subprocess.STDOUT)
    import re
    for _ in range(50):
        m = re.search(r"Running compositor on wayland display '([^']+)'", open(swaylog).read())
        if m: env["WAYLAND_DISPLAY"] = m.group(1); break
        time.sleep(0.2)
    else:
        raise SystemExit("sway never announced its socket: " + open(swaylog).read()[-2000:])
    print("--- sway socket", env["WAYLAND_DISPLAY"], "renderer", env["WLR_RENDERER"])
    time.sleep(1.0)
    extra = ["--ozone-platform=wayland", *extra]
elif not headless:
    xvfb = subprocess.Popen([XVFB, f":{display}", "-screen", "0", f"{W}x{H}x24", "-nolisten", "tcp", "+extension", "GLX", "+render"],
                            stdout=subprocess.DEVNULL, stderr=open(os.path.join(outdir, "xvfb.err"), "w"))
    env["DISPLAY"] = f":{display}"
    time.sleep(1.0)
if not wayland: env.pop("WAYLAND_DISPLAY", None)

flags = [CHROMIUM, "--no-sandbox", "--ignore-certificate-errors", "--autoplay-policy=no-user-gesture-required",
         "--no-first-run", "--no-default-browser-check", "--disable-session-crashed-bubble",
         f"--remote-debugging-port={port}", f"--user-data-dir={profile}",
         f"--window-size={W},{H}", "--window-position=0,0", "--enable-logging=stderr", "--v=0", *extra]
if headless:
    flags.insert(1, "--headless=new")
flags.append("about:blank")
chrome = subprocess.Popen(flags, env=env, stdout=subprocess.DEVNULL, stderr=open(os.path.join(outdir, "chrome.err"), "w"))

HOOK = r"""
(() => {
  document.cookie = 'nano-kvm-token=loopback-tunnel-bypass; path=/';
  try { localStorage.setItem('nano-kvm-vide-mode', '%MODE%'); } catch (e) {}
  const O = window.RTCPeerConnection;
  window.__pcs = [];
  const Wc = function (...a) { const pc = new O(...a); window.__pcs.push(pc); return pc; };
  Wc.prototype = O.prototype; Object.setPrototypeOf(Wc, O);
  window.RTCPeerConnection = Wc;
  window.__rvfc = 0;
  const arm = () => { const v = document.querySelector('video#screen'); if (v && !v.__armed && v.requestVideoFrameCallback) { v.__armed = true; const cb = () => { window.__rvfc++; v.requestVideoFrameCallback(cb); }; v.requestVideoFrameCallback(cb); } };
  setInterval(arm, 500);
})();
""".replace("%MODE%", mode)

PROBE = r"""
(async () => {
  const out = { href: location.href, rvfc: window.__rvfc, pcs: [] };
  const v = document.querySelector('video#screen') || document.querySelector('video');
  if (v) {
    const cs = getComputedStyle(v); const r = v.getBoundingClientRect();
    out.video = { videoWidth: v.videoWidth, videoHeight: v.videoHeight, readyState: v.readyState, paused: v.paused,
      currentTime: v.currentTime, hasSrcObject: !!v.srcObject, src: v.src ? v.src.slice(0, 40) : '', error: v.error ? v.error.code : null,
      opacity: cs.opacity, visibility: cs.visibility, display: cs.display, transform: cs.transform, objectFit: cs.objectFit,
      rect: { x: r.x, y: r.y, w: r.width, h: r.height }, className: v.className,
      quality: v.getVideoPlaybackQuality ? { total: v.getVideoPlaybackQuality().totalVideoFrames, dropped: v.getVideoPlaybackQuality().droppedVideoFrames } : null,
      dpr: devicePixelRatio, inner: [innerWidth, innerHeight] };
    try {
      const c = document.createElement('canvas'); c.width = 64; c.height = 36;
      const ctx = c.getContext('2d'); ctx.drawImage(v, 0, 0, 64, 36);
      const d = ctx.getImageData(0, 0, 64, 36).data; let s = 0, s2 = 0, white = 0, n = 0;
      for (let k = 0; k < d.length; k += 4) { const l = (d[k] + d[k+1] + d[k+2]) / 3; s += l; s2 += l*l; n++; if (d[k] > 245 && d[k+1] > 245 && d[k+2] > 245) white++; }
      out.drawImage = { mean: +(s/n).toFixed(1), std: +Math.sqrt(s2/n - (s/n)**2).toFixed(1), whiteFrac: +(white/n).toFixed(3) };
    } catch (e) { out.drawImage = { error: String(e) }; }
  }
  const cv = document.querySelector('canvas#screen'); if (cv) out.canvas = { w: cv.width, h: cv.height };
  out.notices = [...document.querySelectorAll('.ant-notification-notice')].map(n => n.innerText.slice(0, 120));
  out.bodyBg = getComputedStyle(document.body).backgroundColor;
  for (const pc of (window.__pcs || [])) {
    const p = { connectionState: pc.connectionState, iceConnectionState: pc.iceConnectionState };
    const stats = await pc.getStats(); const byId = {}; stats.forEach(s => byId[s.id] = s);
    stats.forEach(s => { if (s.type === 'inbound-rtp' && s.kind === 'video') {
      const codec = byId[s.codecId] || {};
      p.inbound = { framesReceived: s.framesReceived, framesDecoded: s.framesDecoded, keyFramesDecoded: s.keyFramesDecoded, framesDropped: s.framesDropped,
        pliCount: s.pliCount, freezeCount: s.freezeCount, frameWidth: s.frameWidth, frameHeight: s.frameHeight,
        decoderImplementation: s.decoderImplementation, powerEfficientDecoder: s.powerEfficientDecoder, fmtp: codec.sdpFmtpLine }; } });
    out.pcs.push(p);
  }
  return JSON.stringify(out);
})()
"""

def targets():
    for _ in range(100):
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{port}/json") as r: return json.load(r)
        except Exception: time.sleep(0.2)
    raise SystemExit("devtools endpoint never came up")

def browser_ws():
    with urllib.request.urlopen(f"http://127.0.0.1:{port}/json/version") as r: return json.load(r)["webSocketDebuggerUrl"]

def xgrab(name):
    if headless: return None
    path = os.path.join(outdir, name)
    if kwin:
        r = subprocess.run([sys.executable, os.path.join(os.path.dirname(os.path.abspath(__file__)), "kwin_shot.py"), path],
                           check=False, env=env, capture_output=True, text=True, timeout=40)
        if not os.path.exists(path): return {"error": "kwin_shot produced nothing", "stderr": r.stderr[-400:], "stdout": r.stdout[-200:]}
    elif weston:
        before = set(os.listdir(outdir))
        subprocess.run([f"{WESTON_DIR}/weston-screenshooter"], check=False, env=env, cwd=outdir, timeout=20)
        new = [f for f in set(os.listdir(outdir)) - before if f.endswith(".png")]
        if not new: return {"error": "weston-screenshooter produced nothing"}
        os.rename(os.path.join(outdir, new[0]), path)
    elif wayland: subprocess.run([GRIM, path], check=False, env=env)
    else: subprocess.run([IMPORT, "-display", f":{display}", "-window", "root", path], check=False, env=env)
    if not os.path.exists(path): return {"error": "no grab"}
    im = Image.open(path).convert("RGB")
    # analyse the central region where the video sits (skip top 120px of chrome UI)
    box = im.crop((100, 150, W - 100, H - 50))
    px = list(box.getdata()); n = len(px)
    white = sum(1 for r, g, b in px if r > 245 and g > 245 and b > 245)
    lum = [ (r + g + b) / 3 for r, g, b in px ]
    mean = sum(lum) / n; std = (sum((l - mean) ** 2 for l in lum) / n) ** 0.5
    # a smaller crop for the thumbnail
    box.resize((375, 200)).save(os.path.join(outdir, name.replace(".png", "-thumb.png")))
    return {"file": path, "whiteFrac": round(white / n, 3), "mean": round(mean, 1), "std": round(std, 1)}

async def main():
    page = next(t for t in targets() if t["type"] == "page")
    console = []
    async with websockets.connect(browser_ws(), max_size=None) as bws:
        await bws.send(json.dumps({"id": 1, "method": "SystemInfo.getInfo"}))
        info = json.loads(await bws.recv()).get("result", {})
        gpu = info.get("gpu", {})
        with open(os.path.join(outdir, "gpu.json"), "w") as f: json.dump(gpu, f, indent=1)
        print("--- gpu featureStatus:", json.dumps(gpu.get("featureStatus", {})))
        print("--- gpu devices:", json.dumps([{k: d.get(k) for k in ("vendorString", "deviceString", "driverVendor", "driverVersion")} for d in gpu.get("devices", [])]))
        print("--- auxAttributes:", json.dumps({k: gpu.get("auxAttributes", {}).get(k) for k in ("glRenderer", "glVendor", "glVersion", "isSoftwareRendering", "passthroughCmdDecoder", "canSupportThreadedTextureMailbox")}))
    async with websockets.connect(page["webSocketDebuggerUrl"], max_size=None) as ws:
        seq = 0
        async def call(method, **params):
            nonlocal seq; seq += 1
            await ws.send(json.dumps({"id": seq, "method": method, "params": params}))
            while True:
                msg = json.loads(await ws.recv())
                if msg.get("method") == "Runtime.consoleAPICalled":
                    a = msg["params"].get("args", []); console.append(msg["params"].get("type", "") + ": " + " ".join(str(x.get("value", x.get("description", ""))) for x in a)[:300])
                if msg.get("method") == "Runtime.exceptionThrown":
                    console.append("EXC: " + json.dumps(msg["params"].get("exceptionDetails", {}).get("exception", {}).get("description", ""))[:300])
                if msg.get("id") == seq: return msg.get("result", msg)
        await call("Page.enable"); await call("Runtime.enable")
        await call("Page.addScriptToEvaluateOnNewDocument", source=HOOK)
        await call("Page.navigate", url=url)
        t0 = time.time(); print("navigate", time.strftime("%T"), "mode", mode, "headless", headless, "extra", extra, flush=True)
        checkpoints = [c for c in (6, 12, 25, 45, 90) if c < secs] + [secs]
        for cp in checkpoints:
            while time.time() - t0 < cp:
                try:
                    msg = json.loads(await asyncio.wait_for(ws.recv(), 0.3))
                    if msg.get("method") == "Runtime.consoleAPICalled":
                        a = msg["params"].get("args", []); console.append(msg["params"].get("type", "") + ": " + " ".join(str(x.get("value", x.get("description", ""))) for x in a)[:300])
                    if msg.get("method") == "Runtime.exceptionThrown":
                        console.append("EXC: " + json.dumps(msg["params"].get("exceptionDetails", {}).get("exception", {}).get("description", ""))[:300])
                except Exception: pass
            r = await call("Runtime.evaluate", expression=PROBE, awaitPromise=True, returnByValue=True)
            val = r.get("result", {}).get("value")
            print(f"--- t={int(time.time()-t0)}s")
            try: print(json.dumps(json.loads(val), indent=None))
            except Exception: print(r)
            shot = await call("Page.captureScreenshot", format="png")
            if "data" in shot:
                import base64
                p = os.path.join(outdir, f"cdp-{int(cp)}s.png")
                open(p, "wb").write(base64.b64decode(shot["data"]))
                im = Image.open(p).convert("RGB"); box = im.crop((100, 100, im.width - 100, im.height - 50)); px = list(box.getdata()); n = len(px)
                print("cdp-shot:", json.dumps({"whiteFrac": round(sum(1 for r_, g, b in px if r_ > 245 and g > 245 and b > 245) / n, 3), "size": im.size}))
            print("x-grab:", json.dumps(xgrab(f"x-{int(cp)}s.png")), flush=True)
        print("--- console (dedup)")
        seen = set()
        for c in console:
            if c not in seen: seen.add(c); print(" ", c)

try:
    asyncio.run(main())
finally:
    chrome.terminate()
    try: chrome.wait(5)
    except Exception: chrome.kill()
    if xvfb: xvfb.terminate()
