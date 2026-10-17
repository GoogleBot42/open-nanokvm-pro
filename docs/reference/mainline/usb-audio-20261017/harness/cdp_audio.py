#!/usr/bin/env python3
"""Drive the real NanoKVM web UI's H.264 WebRTC session in headless Chromium
(through the loopback tunnel, so the server's localhost auth bypass applies)
and report both audio directions (#82):

  KVM -> browser  the audio peer connection's inbound-rtp audio stats
                  (packets, totalSamplesReceived, audioLevel, concealment):
                  what vision.ReadAudio() delivered and Chromium decoded.
  browser -> KVM  after --mic-at seconds, a fake microphone (Chromium's
                  --use-fake-device-for-media-stream beep) is added to the
                  audio peer connection exactly as the UI's own mic toggle
                  does (getUserMedia + addTrack, then the UI's
                  onnegotiationneeded sends the audio-offer); outbound-rtp
                  audio stats show it leaving.

usage: cdp_audio.py <url> [seconds] [--mic-at N] [extra chromium flags...]
Needs chromium and python3 with `websockets` (see run.sh).
"""
import asyncio
import json
import subprocess
import sys
import time
import urllib.request

import websockets

args = sys.argv[1:]
url = args.pop(0)
run_for = float(args.pop(0)) if args and not args[0].startswith("--") else 40
mic_at = None
if args and args[0] == "--mic-at":
    args.pop(0)
    mic_at = float(args.pop(0))
extra = args
PORT = 9335
profile = "/tmp/claude-1000/cdp-audio-profile"
subprocess.run(["rm", "-rf", profile], check=False)

chrome = subprocess.Popen(
    ["chromium", "--headless=new", "--no-sandbox", "--ignore-certificate-errors",
     "--autoplay-policy=no-user-gesture-required",
     "--use-fake-ui-for-media-stream", "--use-fake-device-for-media-stream",
     "--enable-logging=stderr", "--v=0",
     f"--remote-debugging-port={PORT}", f"--user-data-dir={profile}", *extra, "about:blank"],
    stdout=subprocess.DEVNULL, stderr=open("cdp_audio_chrome.err", "w"))

HOOK = r"""
(() => {
  document.cookie = 'nano-kvm-token=loopback-tunnel-bypass; path=/';
  try { localStorage.setItem('nano-kvm-vide-mode', 'h264-webrtc'); } catch (e) {}
  const O = window.RTCPeerConnection;
  window.__pcs = [];
  const W = function (...a) { const pc = new O(...a); window.__pcs.push(pc); return pc; };
  W.prototype = O.prototype; Object.setPrototypeOf(W, O);
  window.RTCPeerConnection = W;
})();
"""

MIC = r"""
(async () => {
  const pc = (window.__pcs || []).find(p => p.getTransceivers().some(t => t.receiver.track.kind === 'audio'));
  if (!pc) return 'no audio peer connection';
  const stream = await navigator.mediaDevices.getUserMedia({ audio: {
    sampleRate: 48000, channelCount: 2, echoCancellation: true, noiseSuppression: true, autoGainControl: true } });
  window.__mic = stream;
  pc.addTrack(stream.getAudioTracks()[0], stream);
  return 'mic track added: ' + stream.getAudioTracks()[0].label;
})()
"""

PROBE = r"""
(async () => {
  const out = { pcs: [] };
  const a = document.querySelector('audio');
  // What the UI's volume slider does above 0: unmute and play. Chromium
  // reports audioLevel 0 for a muted element's track.
  if (a) { a.muted = false; a.volume = 1; if (a.paused) a.play().catch(() => {}); }
  out.audioEl = a ? { hasSrc: !!a.srcObject, paused: a.paused, muted: a.muted, volume: a.volume } : null;
  for (const pc of (window.__pcs || [])) {
    const p = { conn: pc.connectionState, sig: pc.signalingState,
                kinds: pc.getTransceivers().map(t => t.receiver.track.kind + ':' + (t.currentDirection || t.direction)) };
    const stats = await pc.getStats();
    stats.forEach(s => {
      if (s.type === 'inbound-rtp' && s.kind === 'audio')
        p.inAudio = { packetsReceived: s.packetsReceived, bytesReceived: s.bytesReceived,
          totalSamplesReceived: s.totalSamplesReceived, concealedSamples: s.concealedSamples,
          silentConcealedSamples: s.silentConcealedSamples, audioLevel: s.audioLevel,
          totalAudioEnergy: s.totalAudioEnergy, jitterBufferEmittedCount: s.jitterBufferEmittedCount };
      if (s.type === 'outbound-rtp' && s.kind === 'audio')
        // One per audio sender: the UI's addTrack opens a second m-line
        // beside the sendrecv one, whose own sender has no track.
        (p.outAudio = p.outAudio || []).push({ mid: s.mid, packetsSent: s.packetsSent, bytesSent: s.bytesSent });
      if (s.type === 'inbound-rtp' && s.kind === 'video')
        p.inVideo = { packetsReceived: s.packetsReceived, framesDecoded: s.framesDecoded };
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

        def note(msg):
            if msg.get("method") == "Runtime.consoleAPICalled":
                a = msg["params"].get("args", [])
                console.append(" ".join(str(x.get("value", x.get("description", ""))) for x in a)[:300])

        async def call(method, **params):
            nonlocal seq
            seq += 1
            await ws.send(json.dumps({"id": seq, "method": method, "params": params}))
            while True:
                msg = json.loads(await ws.recv())
                note(msg)
                if msg.get("id") == seq:
                    return msg.get("result", msg)

        async def idle(until):
            while time.time() < until:
                try:
                    note(json.loads(await asyncio.wait_for(ws.recv(), 0.25)))
                except Exception:
                    pass

        await call("Page.enable")
        await call("Runtime.enable")
        await call("Page.addScriptToEvaluateOnNewDocument", source=HOOK)
        await call("Page.navigate", url=url)
        t0 = time.time()
        print("navigate at", time.strftime("%T"), flush=True)
        mic_done = mic_at is None
        t = 5.0
        while t <= run_for:
            if not mic_done and t >= mic_at:
                await idle(t0 + mic_at)
                r = await call("Runtime.evaluate", expression=MIC, awaitPromise=True, returnByValue=True)
                print(f"--- t={int(time.time() - t0)}s wall={time.strftime('%T')} MIC:",
                      r.get("result", {}).get("value", r), flush=True)
                mic_done = True
            await idle(t0 + t)
            r = await call("Runtime.evaluate", expression=PROBE, awaitPromise=True, returnByValue=True)
            val = r.get("result", {}).get("value")
            print(f"--- t={int(time.time() - t0)}s wall={time.strftime('%T')} {val}", flush=True)
            t += 5.0
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
