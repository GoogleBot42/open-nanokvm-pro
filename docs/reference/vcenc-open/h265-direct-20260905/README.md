# h265-direct device validation — 2026-09-05 (#66, #64)

First device run of the `h265-direct` stream mode: the Go server's second direct
streamer (`service/stream/direct/h265.go`) over libkvm's blob-free H.265 channel,
plus the web bundle that adds the mode. Numbers and logs only; no captured pixels.

## Setup

- Device: open stack from a warm reboot (`open_vin_capture`, `open_vin_csi2`,
  `ax630c_venc_vcmd`; zero vendor `.ko`), libkvm with the H.265 channel already
  hot-patched (`351c0619406d25fd…`). Source 1920x1080 via `/proc/lt6911_info`.
- Deployed (both `/kvmapp/server` and `/dev/shm/kvmapp/server`, stage + `mv`,
  sha256-verified): `NanoKVM-Server` `0dbf4e9b94bb7f41…` (branch `feat/h265-direct`,
  `nix build .#nanokvm-server`), web bundle `assets/index-X3sNjxxb.js`
  (`.#nanokvm-web`). Previous binary + web kept in `/root/pre66/` on the device.
- `systemctl restart nanokvm` → active, `:80`/`:443` listening, `/` → 200 with the
  new bundle hash.

## Results

| Step | Result |
|---|---|
| `POST /api/stream/mode {"mode":"h265-direct"}` | `{"code":0}` |
| `GET /api/stream/h265/direct` (WebSocket, `wsgrab-h265.log`) | 101; 150 messages, 5 key. Every key message = `[VPS 32, SPS 33, PPS 34, IDR 19]` in one payload (32011 B); every other message one `TRAIL_R (1)`. 60 fps timestamps, GOP 30. |
| Server log | `[openvenc] up: … H.265 1920x1080 … rc=fixqp QP32 gop=30`; zero `failed to read H.265` |
| `ffprobe` on the concatenated payloads (`ffprobe.txt`) | `hevc`, Main, 1920x1080, `level=123` (L4.1 — what `vcenc_hevc_level_idc` writes for 1080p), yuvj420p; `ffmpeg -f null` decodes all 150 frames (5 I + 145 P), 0 error lines |
| NAL inventory (`nal-units.txt`) | 165 NALs: 5×VPS(27 B) 5×SPS(53 B) 5×PPS(12 B) 5×IDR 145×TRAIL_R |
| H.264 regression (`wsgrab-h264.log`) | `h264-direct` framing unchanged (SPS/PPS as separate delta messages, IDR key); channel switch H.265→H.264 clean |
| WebCodecs probe, headless Chromium 152 / Linux (`headless-chromium-webcodecs-probe.txt`) | `isConfigSupported` false for `hvc1.1.6.L153.B0`, `hvc1.1.6.L123.B0`, `hev1.1.6.L153.B0`; true for `avc1.42E01F`. Decoding the capture with `hvc1` → `OperationError: Unsupported configuration` (expected: no platform HEVC decoder on this host) |
| Shipped UI, stored `h265-direct`, browser without HEVC (`ui-fallback-headless-chromium.txt`) | Page opens `wss://…/api/stream/h264/direct`, canvas mounts, notice "The current browser does not support H.265! / This browser cannot decode H.265 video; playing H.264 Direct instead.", stored mode rewritten to `h264-direct`, no page exceptions |
| Shipped UI, stored `h264-direct` (control) | identical H.264 behaviour, no notice |

## Not exercised

- The **supported** browser branch: decoding the `hvc1` stream in the direct worker
  and seeing live HDMI in a real Chrome/Edge/Safari with a platform HEVC decoder.
  No browser on the build host can decode HEVC. The server side of that path is
  proven by the ffmpeg decode above; the codec string and Annex-B key-chunk layout
  follow WebCodecs' documented behaviour but need a human at such a browser.
- Firefox: not run; expected to take the same fallback branch as the Linux Chromium.
- Resolution switch (1080p↔4K) while streaming `h265-direct`.

## End state

Device left with stream mode `h264-direct`, `nanokvm.service` active, web 200,
libkvm and kernel modules untouched. Captures (`/tmp/out.h265`, `/tmp/out.h264`)
and the staged files live in the device's tmpfs `/tmp` only.
