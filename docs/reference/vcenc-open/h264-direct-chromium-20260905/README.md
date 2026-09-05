# Chromium white screen: H.264 Direct parameter sets + WebRTC stream-type takeover — 2026-09-05 (#68)

Two browser-side white screens on the open stack, both reproduced against the
real device from headless Chromium 152 (Linux, no GPU) and both understood.
Numbers and logs only; no captured pixels or bitstreams. Reusable harness in
`harness/` (see the file comments; `tunnel.sh` reads credentials from
`~/.config/nanokvm/device.env`, nothing is printed).

## 1. H.264 Direct: first key chunk without SPS/PPS (fixed)

Upstream `service/stream/direct/streamer.go` sends every NAL as its own
WebSocket message and flags only the IDR as key; the upstream worker creates its
`VideoDecoder` on the first key message and drops everything before it, so the
first chunk Chromium decodes has no parameter sets. Chromium's H.264 decoder
(`media/filters/ffmpeg_video_decoder.cc:324 DecoderStatus::1`) fails on it —
and, as the `buffered` run below shows, on **every** later key chunk without
them — while Firefox tolerates it. Fix: `pkgs/nanokvm-server.nix` step 10 folds
SPS+PPS into the IDR message they precede (as `h265.go` already did); the
worker additionally folds separately-sent parameter sets into the next key
message for older servers.

Live server after the fix (`wsgrab.py`, loopback `wss /api/stream/h264/direct`,
150 messages): message 1 `key=1 nal_types=[7, 8, 5]`, every key message
`[7, 8, 5]` (5 in 150, GOP 30), every other message `[1]`; `ffmpeg -f null`
0 error lines, ffprobe `h264` Main 1920x1080 level 42, 150 frames. H.265 Direct
unchanged (`[32, 33, 34, 19]` key messages); MJPEG 75 frames in 8 s.

Headless Chromium on the grabs (`harness/wc_test.html`, real time over CDP with
`harness/cdp_run.py`; `--virtual-time-budget` runs never deliver output frames,
so "no error + configured" is the differential there):

| Input | Feeding | frames | errors |
|---|---|---|---|
| pre-fix grab (`old.h264`, 70 NALs) | one NAL per message, upstream worker | 0 | `cb:Decoding error.` + flush error, 1 ffmpeg warning |
| pre-fix grab | buffer SPS/PPS only before the first key | 30 (one GOP) | error at the second IDR |
| pre-fix grab | fold SPS/PPS into every key (patched worker) | 64/64 | none |
| fixed server, raw framed messages (`mode=framed`, 150 msgs, 5 key) | as sent | 150/150 | none, 0 ffmpeg warnings |

Real UI through the loopback tunnel (`harness/cdp_ui.py`, stored mode
`h264-direct`): canvas resized to 1920x1080 by the first decoded frame, no
console errors, no decoder error.

## 2. WebRTC: another stream consumer parks the viewer on a white screen (open)

The profile hypothesis is falsified. Through the tunnel Chromium negotiated
`profile-level-id=42001f;packetization-mode=1` (pion binds the browser's first
H.264 entry because the track declares no fmtp) for the Main 4.2 stream and
decoded it anyway: 60 s baseline 3594 frames decoded, 72 key frames, 0 PLI/FIR,
1920x1080, `<video>` playing. pion's payloader stashes SPS/PPS and emits them as
a STAP-A in the same `Packetize` call as the IDR (one RTP timestamp) — the
Direct bug has no WebRTC analogue.

What does reproduce (`webrtc-contention-probe.json.txt`): a direct client
connected mid-session (device-side `wsgrab.py` at 13:12:14, after the 16 s
checkpoint). `sendVideoStream` saw `StreamType != H264_WEBRTC`, sent
`video-status -4`, the page set `isPlaying=false` → `opacity-0` on the video;
frames froze at 2065 (currentTime 34.37) and stayed there through the 60 s
checkpoint; Chromium sent one PLI (the server drains RTCP unparsed). Nothing
hands the stream type back after the intruder disconnects, so the viewer stays
white until reload. Any second consumer triggers it — a second browser or tab in
Direct/MJPEG mode, a `curl /api/stream/mjpeg`, a mode POST. Not browser-specific.

## 3. H.265 Direct selectability (fixed)

The shipped web gate greyed the option out when `VideoDecoder.isConfigSupported`
rejected one string. Now the option is always listed, the probe is advisory and
logged (`[h265-direct] isConfigSupported <codec> <accel>: …`), the worker derives
the codec string from the stream's own VPS (live 1080p stream:
`hvc1.1.2.L123.80`, level 4.1 — the hard-coded `L153` was the 4K level), and only
a decoder failure before the first frame falls back to H.264 Direct with a notice.
Build-host Chromium (`harness/probe.html`): every HEVC string × acceleration
`false`, `avc1` `true`; the real UI run with stored `h265-direct` logs the nine
answers, tries anyway, gets `OperationError: Unsupported configuration`, shows the
notice and plays H.264 Direct (canvas 1920x1080), stored mode rewritten.
Firefox 154 (coordinator's run): HEVC supported via canPlayType/mediaCapabilities,
`isConfigSupported` false for every HEVC string — WebCodecs cannot carry H.265
there.
