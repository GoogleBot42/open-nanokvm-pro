#!/usr/bin/env python3
"""Load the real NanoKVM web UI in headless Chromium (through the loopback
tunnel, so the device sees 127.0.0.1 and skips auth), let it negotiate the
default H.264 WebRTC session, and report what Chromium's receiver did:
negotiated H.264 fmtp, inbound-rtp stats (packets, frames decoded, PLIs),
decoder implementation, and the <video> element state.

usage: cdp_webrtc.py <url> [seconds] [extra chromium flags...]
Requires chromium on PATH and python3 with `websockets`.
"""
import asyncio
import json
import subprocess
import sys
import time
import urllib.request

import websockets

url = sys.argv[1]
run_for = float(sys.argv[2]) if len(sys.argv) > 2 else 30
extra = sys.argv[3:]
PORT = 9334
profile = "/tmp/claude-1000/cdp-webrtc-profile"
subprocess.run(["rm", "-rf", profile], check=False)

chrome = subprocess.Popen(
    ["chromium", "--headless=new", "--no-sandbox", "--ignore-certificate-errors",
     "--autoplay-policy=no-user-gesture-required", "--enable-logging=stderr", "--v=0",
     f"--remote-debugging-port={PORT}", f"--user-data-dir={profile}", *extra, "about:blank"],
    stdout=subprocess.DEVNULL, stderr=open("cdp_webrtc_chrome.err", "w"))

HOOK = r"""
(() => {
  // ProtectedRoute only checks the cookie EXISTS; the server sees 127.0.0.1 via the tunnel
  document.cookie = 'nano-kvm-token=loopback-tunnel-bypass; path=/';
  try { localStorage.setItem('nano-kvm-vide-mode', 'h264-webrtc'); } catch (e) {}
  const O = window.RTCPeerConnection;
  window.__pcs = [];
  const W = function (...a) { const pc = new O(...a); window.__pcs.push(pc); return pc; };
  W.prototype = O.prototype; Object.setPrototypeOf(W, O);
  window.RTCPeerConnection = W;
})();
"""

PROBE = r"""
(async () => {
  const out = { href: location.href, title: document.title, pcs: [] };
  const v = document.querySelector('video');
  out.video = v ? { videoWidth: v.videoWidth, videoHeight: v.videoHeight, readyState: v.readyState,
                    paused: v.paused, currentTime: v.currentTime, hasSrc: !!v.srcObject,
                    opacity: getComputedStyle(v).opacity, className: v.className.split(' ').filter(c => /opacity/.test(c)).join(' ') } : null;
  out.h264Caps = (RTCRtpReceiver.getCapabilities('video')?.codecs || [])
      .filter(c => /h264/i.test(c.mimeType)).map(c => c.sdpFmtpLine);
  for (const pc of (window.__pcs || [])) {
    const p = { signalingState: pc.signalingState, connectionState: pc.connectionState,
                iceConnectionState: pc.iceConnectionState };
    const h264 = (sdp) => (sdp || '').split('\r\n').filter(l => /^m=video|a=fmtp|a=rtpmap.*H264/i.test(l));
    p.localH264 = h264(pc.localDescription?.sdp);
    p.remoteH264 = h264(pc.remoteDescription?.sdp);
    p.remoteHasVideo = /m=video/.test(pc.remoteDescription?.sdp || '');
    const stats = await pc.getStats();
    const byId = {}; stats.forEach(s => byId[s.id] = s);
    stats.forEach(s => {
      if (s.type === 'inbound-rtp' && s.kind === 'video') {
        const codec = byId[s.codecId] || {};
        p.inbound = { packetsReceived: s.packetsReceived, bytesReceived: s.bytesReceived,
          framesReceived: s.framesReceived, framesDecoded: s.framesDecoded, keyFramesDecoded: s.keyFramesDecoded,
          framesDropped: s.framesDropped, pliCount: s.pliCount, firCount: s.firCount, nackCount: s.nackCount,
          frameWidth: s.frameWidth, frameHeight: s.frameHeight, decoderImplementation: s.decoderImplementation,
          powerEfficientDecoder: s.powerEfficientDecoder, freezeCount: s.freezeCount,
          totalDecodeTime: s.totalDecodeTime,
          codec: { payloadType: codec.payloadType, mimeType: codec.mimeType, sdpFmtpLine: codec.sdpFmtpLine } };
      }
      if (s.type === 'candidate-pair' && s.nominated) p.pair = { state: s.state, bytesReceived: s.bytesReceived };
    });
    out.pcs.push(p);
  }
  return JSON.stringify(out);
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

        async def call(method, **params):
            nonlocal seq
            seq += 1
            await ws.send(json.dumps({"id": seq, "method": method, "params": params}))
            while True:
                msg = json.loads(await ws.recv())
                if msg.get("method") == "Runtime.consoleAPICalled":
                    args = msg["params"].get("args", [])
                    console.append(" ".join(str(a.get("value", a.get("description", ""))) for a in args)[:300])
                if msg.get("id") == seq:
                    return msg.get("result", msg)

        await call("Page.enable")
        await call("Runtime.enable")
        await call("Page.addScriptToEvaluateOnNewDocument", source=HOOK)
        await call("Page.navigate", url=url)
        t0 = time.time()
        print("page navigate at", time.strftime("%T"), flush=True)
        for checkpoint in (8, 16, 40, run_for):
            while time.time() - t0 < checkpoint:
                await asyncio.sleep(0.5)
                # drain events
                try:
                    msg = json.loads(await asyncio.wait_for(ws.recv(), 0.05))
                    if msg.get("method") == "Runtime.consoleAPICalled":
                        args = msg["params"].get("args", [])
                        console.append(" ".join(str(a.get("value", a.get("description", ""))) for a in args)[:300])
                except Exception:
                    pass
            r = await call("Runtime.evaluate", expression=PROBE, awaitPromise=True, returnByValue=True)
            val = r.get("result", {}).get("value")
            print(f"--- t={int(time.time() - t0)}s wall={time.strftime('%T')}")
            try:
                print(json.dumps(json.loads(val), indent=1))
            except Exception:
                print(r)
        print("--- console (dedup)")
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
