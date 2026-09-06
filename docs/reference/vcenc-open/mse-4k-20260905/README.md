# MSE player at 4K, and a mid-stream resolution change — 2026-09-05

Closes the agent-testable half of #72's open list: 4K HEVC through the
MediaSource player, a resolution change while it is playing, and the stored
video-mode quirk. Player: `web/src/pages/desktop/screen/mse-player.tsx` +
`mse.worker.ts` + `web/src/lib/mp4/`. Harness: the same
`../mse-player-20260905/harness/` (extended — see its README), every run on a
fresh browser profile through the loopback SSH tunnel. Bundle under test:
`assets/index-DbdjOeXz.js`, deployed to both trees for the session and the
device's own bundle restored afterwards.

## There is no resolution API — the EDID is the lever

The encoder always follows the HDMI source. `common/screen.go` reads
`/proc/lt6911_info/{width,height}`; `libkvm.c` ignores the numbers the server
passes and takes the live source geometry itself, re-reading `/proc/lt6911_info`
at 2 Hz and tearing the pipeline down + re-initialising it on a change
(`libkvm.c`, "Absorb a LIVE source mode change"). Nothing in
`POST /api/stream/*` sets geometry, and `OPENKVM_FORCE_GEOM` is read by
`getenv()` at pipeline init **and disables that poll**, so it cannot produce a
mid-stream change either.

So a resolution change is an **EDID switch**, exactly what the UI's Screen →
EDID menu does: `POST /api/vm/edid {"edid":"E18-4K30FPS"}` writes
`/proc/lt6911_info/edid`, `lt6911_manage.ko` programs the LT6911UXC and cycles
HPD, the attached host renegotiates. On this bench the host followed it every
time; **~6 s from the POST to the first new-geometry init segment in the
browser** (20.1 s → 26.0 s, and 55.1 s → 62.0 s, in both switch runs).

Bench state, recorded and restored: EDID `E54-1080P60FPS`, source
1920x1080@59. The 4K runs used `E18-4K30FPS` → source **3840x2160@29**.

## 1. 4K

| browser | mode | codec string from the stream | frames (dropped) | lag behind the last append | first segment |
|---|---|---|---|---|---|
| Firefox 154 | `h265-mse` | `hvc1.1.2.L153.80` 3840x2160 | 597 / 25 s (21) | 40–140 ms | 520 ms |
| Firefox 154 | `h265-direct` (auto) | WebCodecs rejected all 9 configurations → **MSE chosen**, `hvc1.1.2.L153.80` | 481 / 20 s (10) | 53–121 ms | 300 ms |
| Firefox 154 | `h264-mse` | `avc1.4D0033` 3840x2160 | 601 / 25 s (29) | 35–115 ms | 323 ms |
| Chromium 152 | `h264-mse` | `avc1.4D0033` 3840x2160 | 613 / 25 s (14) | 55–63 ms | 442 ms |
| Firefox 154 | `h264-direct` | WebCodecs `avc1.42E01F`, canvas 3840x2160 | — | — | regression check passed |
| Firefox 154 | `h265-mse` at 1080p60 (same bundle, baseline) | `hvc1.1.2.L123.80` | 1481 / 25 s (8) | 61–95 ms | 299 ms |

4K HEVC plays in Firefox's `<video>` through MSE with no WebCodecs involved —
level 5.1 (`L153`), which `MediaSource.isTypeSupported` had already answered
true for. Chromium 152 (nixpkgs, headless) still has no HEVC by any path; its
H.264 MSE numbers are the best of the set.

**Throughput is the pipeline, not the player**: 1080p60 delivers a flat 60.0
fps (1200 segments in 20 s), 4K30 delivers **24.5 fps** (490 segments in 20 s)
against a 30 Hz source, identically in H.264 and H.265 and in both browsers.
Dropped frames stay under 5 % and the live-edge policy holds ≤ 140 ms
throughout; at 4K the player sits at `playbackRate` 1.1 more of the time.

Screenshots (not committed — they show the attached host's desktop) are
self-documenting here: the host's own KDE "Display Configuration" page reads
**3840 × 2160 (16:9) / 30.00 Hz** in the 4K shots and **1920 × 1080 (16:9) /
60.00 Hz** in the 1080p ones.

## 2. Resolution change mid-stream

90 s runs, EDID flipped from inside the page (`--action`, the same
`POST /api/vm/edid` the UI calls) at t=20 s to `E54-1080P60FPS` and at t=55 s
back to `E18-4K30FPS`. No reload, no reconnect, no user action.

| browser | mode | init segments emitted | total | dropped | notes |
|---|---|---|---|---|---|
| Firefox 154 | `h265-mse` | `hvc1.1.2.L153.80` 3840x2160 at 0.3 s → `L123.80` 1920x1080 at **26.0 s** → `L153.80` 3840x2160 at **62.0 s** | 2895 segments / 2885 frames | 39 | `changeType` both ways, `isTypeSupported` true both ways |
| Firefox 154 | `h264-mse` | `avc1.4D0033` → `avc1.4D002A` at **25.96 s** → `4D0033` at **61.85 s** | 2899 / 2896 | 55 | same |
| Chromium 152 | `h264-mse` | `avc1.4D0033` → `4D002A` at **26.06 s** → `4D0033` at **61.39 s** | 2893 / 2892 | 25 | same |

What the logs show at each switch: one new init segment, the codec string moving
with the level, `changeType` accepted, `resolution changed WxH -> WxH`, and
`video.videoWidth` following by the next probe. `readyState` dips 3 → 2 for a
beat and comes back. **Zero** `QuotaExceededError`, zero `<video> error`, zero
`stalled`, zero SourceBuffer rebuilds, zero reconnects, `video.error` null at
every probe. The dropped-frame counter barely moves across a switch (22 → 23,
29 → 31 in the HEVC run).

The path was previously exercised only by the reconnect case, which re-sends an
identical init segment; this is the first run where the parameter sets actually
differ. Pre-emptive hardening that went in with it (`mse-player.tsx`): ask
`MediaSource.isTypeSupported` about the **new** codec string before
`changeType` (a 1080p→4K switch moves the HEVC level, L123 → L153), rebuild the
SourceBuffer when `changeType` is missing or throws rather than appending an
init segment the buffer was never switched to, and never drop an init segment
in the `QuotaExceededError` path. The remuxer now compares parameter sets with
`annexb.bytesEqual` instead of a joined string.

## 3. The stored-video-mode quirk

Upstream: a stored mode that `getSupportedVideoModes()` rejects silently started
the default WebRTC player and left the stored value alone, so the menu kept
showing — and every reload kept choosing — a mode that was not playing.

`lib/video.ts` gains `resolveVideoMode()`: honour the stored mode when it plays,
otherwise pick the nearest mode that does (same codec, then same transport, then
anything that paints) and tell the caller; `pages/desktop/index.tsx` rewrites
localStorage and shows a notice. Proven in headless Chromium with `h265-mse`
stored (`logs/cdp_h265_mse_storedmode.log`):

```
warning: [video-mode] stored mode "h265-mse" is not playable in this browser
         (supported: mjpeg, h264-webrtc, h264-direct, h264-mse, h265-direct); using "h265-direct"
notification: Video mode changed — This browser cannot play the saved video mode
         "h265-mse", so "h265-direct" is playing instead and has been saved.
```

H.265 Direct then runs its own probe, fails at configure time and takes the
existing H.264 Direct fallback with its own notice; the run ends with
`storedMode: "h264-direct"` and a live 3840x2160 canvas. Before the fix the same
run ended with `h265-mse` still stored and a WebRTC `srcObject`.

## Off-device check of the new-init path

`../mse-player-20260905/harness/mux_test.ts` over a synthetic
4K → 1080p → 4K Annex-B stream (ffmpeg `testsrc2`, x265/x264, headers repeated
per segment) emits **three** init segments with the right geometry and levels —
`hvc1.1.6.L150.90 / L120.90 / L150.90` and `avc1.42C033 / 42C028 / 42C033`,
90 media segments, no warnings. Note that `ffcheck.sh` is *not* a valid oracle
for a switch: the remuxer restarts the decode timeline at each init segment,
which MSE `sequence` mode re-bases and a plain MP4 demuxer does not (ffmpeg
reports non-monotonic DTS and loses 2 of 90 frames). The browser is the proof.

## Exact commands

```
PY=/nix/store/z0ifiq53ry90qjzzy8zq7wzczszqb81k-python3-3.14.7-env/bin/python3
H=docs/reference/vcenc-open/mse-player-20260905/harness

# record + set the source geometry (device, localhost auth bypass)
tools/kvmssh 'curl -sk https://127.0.0.1/api/vm/edid'
tools/kvmssh 'curl -sk -X POST -H "Content-Type: application/json" \
  -d "{\"edid\":\"E18-4K30FPS\"}" https://127.0.0.1/api/vm/edid'
tools/kvmssh 'cat /proc/lt6911_info/width /proc/lt6911_info/height /proc/lt6911_info/fps'

$H/tunnel.sh 8443 443 &

# 4K
$PY $H/ff_ui.py  https://127.0.0.1:8443/ h265-mse    25 shot.png --probe-at 6,15,25 --console-full
$PY $H/ff_ui.py  https://127.0.0.1:8443/ h264-mse    25 shot.png --probe-at 6,25    --console-full
$PY $H/cdp_ui.py https://127.0.0.1:8443/ h264-mse    25 shot.png --probe-at 6,25    --console-full
$PY $H/ff_ui.py  https://127.0.0.1:8443/ h265-direct 20 shot.png --probe-at 6,20    --console-full
$PY $H/ff_ui.py  https://127.0.0.1:8443/ h264-direct 18 shot.png --probe-at 6,18    --console-full
$PY $H/cdp_ui.py https://127.0.0.1:8443/ h265-mse    20 shot.png --probe-at 6,20    --console-full

# resolution change mid-stream (4K -> 1080p -> 4K)
$PY $H/ff_ui.py https://127.0.0.1:8443/ h265-mse 90 shot.png \
  --probe-at 6,18,25,32,40,52,62,70,80,90 --shot-each --console-full \
  --action "20:fetch('/api/vm/edid',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({edid:'E54-1080P60FPS'})}).then(r=>r.text())" \
  --action "55:fetch('/api/vm/edid',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({edid:'E18-4K30FPS'})}).then(r=>r.text())"

# restore
tools/kvmssh 'curl -sk -X POST -H "Content-Type: application/json" \
  -d "{\"edid\":\"E54-1080P60FPS\"}" https://127.0.0.1/api/vm/edid'
pkill -f 'L 8443:127.0.0.1:443'
```

Full probe JSON + ordered console for every run in `logs/`.
