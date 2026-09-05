# MSE player: H.265 (and H.264) direct streams without WebCodecs — 2026-09-05

Evidence for the Media Source Extensions player in `web/src/pages/desktop/screen/mse-player.tsx`
(+ `mse.worker.ts`, `web/src/lib/mp4/`). Design summary in `docs/architecture.md`
("The web UI has two players").

## Why

On Linux, Firefox 154 and Chrome both play HEVC in `<video>` but
`VideoDecoder.isConfigSupported` rejects every HEVC string, so the WebCodecs
direct player (`direct.worker.ts`) cannot show the blob-free H.265 stream
there (#66). The MSE player feeds the same WebSocket stream to the browser's own
media pipeline as fragmented MP4.

## Host check of the remuxer (no browser)

`harness/mux_test.ts` frames a captured Annex-B stream the way the server does
(one message per VCL NAL, parameter sets folded into the key message) and runs
`lib/mp4/remuxer.ts` on it under Node 22 (`node --experimental-transform-types
mux_test.ts <h264|h265> <in> <out.mp4>`); `harness/ffcheck.sh` probes and fully
decodes the result with ffmpeg (`nix shell nixpkgs#ffmpeg-full`).

| stream (device capture) | init | segments | ffprobe | decoded |
|---|---|---|---|---|
| H.265 1080p (`out.h265`, 2026-09-05 #66 capture) | `hvc1.1.2.L123.80` 1920x1080, 741 B | 150 | hevc Main L123 `hvc1` 1920x1080 | 150/150, zero errors |
| H.264 1080p (`live_h264_2000.h264`, #46 capture) | `avc1.4D002A` 1920x1080, 650 B | 555 | h264 Main L42 `avc1` 1920x1080 | 555/555, zero errors |

## Browser runs against the live device (bundle `index-HOFSp_lj`)

Harness: `harness/` — `tunnel.sh` (loopback SSH forward, localhost auth
bypass), `ff_ui.py` (headless Firefox 154 over WebDriver BiDi), `cdp_ui.py`
(headless Chromium 152 over CDP), `probe.js` (shared DOM/video probe). Every
run uses a fresh profile (#71: index.html is served without cache headers).
Full probe JSON + console for each run in `logs/`. Screenshots were inspected
and are not committed (they show the attached host's desktop); each one showed
the live KDE "Display Configuration" settings page the HDMI source was on.

| browser | stored mode | player used | result (20 s unless noted) |
|---|---|---|---|
| Firefox 154 | `h265-mse` | MSE HEVC (`hvc1.1.2.L123.80`, isTypeSupported true) | `video#screen` 1920x1080, **1485 frames / 25 s, 3 dropped**, lag 59–93 ms behind the last append, first segment 313 ms after connect, screenshot = live desktop |
| Firefox 154 | `h265-direct` (auto) | WebCodecs probe rejected all 9 configurations → **MSE chosen** (logged) | 1191 frames / 20 s, 8 dropped, lag 69–88 ms; stored mode still `h265-direct` |
| Firefox 154 | `h265-mse`, 45 s, `systemctl restart nanokvm` at ~14 s | MSE HEVC | WebSocket closed → reconnect 500/1000/2000/4000 ms → new init segment → frames resumed: 1785 before, **2230 total**, 2 dropped, lag 7–30 ms after the reconnect. No page reload. |
| Firefox 154 | `h264-mse` | MSE H.264 (`avc1.4D002A`) | 1189 frames, **0 dropped**, lag 49–59 ms, first segment 286 ms |
| Firefox 154 | `h264-direct` | WebCodecs (unchanged) | canvas 1920x1080, `decoder configured: avc1.42E01F` — regression check passed |
| Chromium 152 | `h264-mse` | MSE H.264 (`blob:` src, not WebRTC) | 1201 frames, 8 dropped, lag 44–45 ms, first segment 396 ms, screenshot = live desktop |
| Chromium 152 | `h265-direct` (auto) | WebCodecs rejected; MSE `isTypeSupported` false for all four HEVC strings; WebCodecs tried anyway → `OperationError: Unsupported configuration` twice → **H.264 Direct fallback with the notice**, stored mode rewritten to `h264-direct` | canvas 1920x1080 from `avc1.42E01F` |
| Chromium 152 | `h264-direct` | WebCodecs (unchanged) | canvas 1920x1080 — regression check passed |

Headless nixpkgs Chromium 152 has no HEVC by any path (no platform decoder);
the `<video>`-can-play-HEVC observation that motivated this work came from a
desktop Chrome. Its `h265-mse` run in `logs/cdp_h265_mse_1.log` is a
**negative** result worth knowing: the stored mode is not in
`getSupportedVideoModes()`, so upstream's `Desktop.getVideoMode()` silently
started the default H.264 WebRTC player (`srcObject: true`) while leaving
`h265-mse` in localStorage — the probe's `src`/`srcObject` fields tell the two
apart.

## Not verified

- A real desktop browser with hardware HEVC (Chrome/Edge/Safari on Windows or
  macOS): expected to take the WebCodecs branch of H.265 Direct; the MSE modes
  should work there too.
- 4K HEVC through MSE (the 1080p60 source was the only one attached);
  `hvc1.1.2.L153.80` is in the probe list.
- Resolution change mid-stream (new init segment path) — exercised only by the
  reconnect case, which re-sends an identical init segment.
