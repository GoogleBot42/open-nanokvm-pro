# Open rate controller on the device — 2026-09-05 (#46 hardware validation)

The from-scratch frame-level controller (`pkgs/vcenc-ewl/vcenc_rc.h`) driving the
open VC8000E encoder on the shipped open stack (alpha.4 image, `ax630c_venc_vcmd` +
the two open capture modules, zero vendor `.ko`), libkvm `.#kvm-encoder-v4l2` built
from branch `worktree-agent-a79b9f647adb6311b` (md5 `7430681e…`). Numbers and logs
only; no bitstreams or desktop pixels are committed. Tools used: `tools/`.

## A. Standalone prover (`ewl_encode`, moving synthetic card, 1080p, gop 30, 60 fps)

`prover/*.log` — 12 runs, 2340 frames, every frame `ok`, module refcnt 0 before and
after, service restored. Pulled bitstreams decoded on the host with ffmpeg: **0 errors
in all 12**, and every bitstream slice QP equals the controller's logged QP
(0 mismatches / 2340 frames; H.264 via `h264parse.py`, HEVC via `h265parse.py`) —
the PPS `pic_init_qp` = seed / frame QP ≠ seed split works through our own builder
for both codecs.

| run | IDR QPs | P QP | note |
|---|---|---|---|
| h264/h265 cbr 8000, 16000 | 32 30 28 26 24 22 | 35 33 32 … 21 → floor IDR−11, then 19, 17, 16 | content-limited (card ≈ 150 B/P), the vendor's R1/R4 trajectory |
| h264 cbr 2000 | 37 35 33 31 29 27 | 40 38 37 … 26 (floor) | seed 37 at ≤ 3000 kbps |
| h265 cbr 2000 | 35 33 31 29 27 25 | 38 37 … 24 | seed 35; no HEVC no-target mode |
| h264 vbr 8000 / h265 vbr 2000 | 32, then 17 17 17… / 36, then 17… | descends to 16 | VBR: IDR follows last P + 1 |
| chg 8000→2000 (frame 120), 2000→16000, h265 8000→2000 | 32 30 28 26 **37** 35 33 31 / 37 35 33 31 **32** 30 28 26 | | first IDR after the change restarts at the new seed |
| h264 fixqp32 (control) | 32 32 | 32 | pinned program unchanged |

## B. Live web path, real 1080p59 HDMI desktop (`live/`)

libkvm deployed into both trees (stage + `mv`), `OPENKVM_VENC_RC_LOG=1`, restart;
grabs through `wss /api/stream/h264/direct` and `/api/stream/h265/direct`
(`tools/wsgrab.py`, 600 messages ≈ 10 s each); bitrate changed with
`POST /api/stream/quality` while streaming. The channel came up
`rc=cbr program=fixqp QP32 gop=30`, seed 32 (bpp 0.0654 at 59 fps); every quality
change was applied in place (`[rc] retarget`), no channel rebuild, **0 `FAIL` lines
in 10 587 logged frames**, server RSS 35 264 → 34 236 KB across the session.

Per segment (`tools/rc_segments.py live/live_openvenc*.log`, achieved rate from the
controller's own byte counts at 59 fps):

| segment | frames | achieved | IDR QPs | P QP | vendor on the same desktop |
|---|---|---|---|---|---|
| H.264 CBR 8000 | 563 | 1658 kbps | 32 30 28 … 16 (−2/GOP) | 35 → 21 floor, then 19 … 16 | 2606 kbps (R4: CTB-shaped 7–9 KB descent frames) |
| → 2000 (in place) | 563 | 1676 kbps | 37 35 33 … 21 | 40 → 26 floor … 16 | 1996 kbps |
| → 16000 | 563 | 1657 kbps | 32 30 … 16 | 35 → 21 … 16 | 2607 kbps |
| → 8000, then → 2000 mid-grab | 288 / 280 | 1718 / 1886 kbps | as above | | |
| H.265 CBR 8000 (`live_openvenc3.log`) | 301 | 901 kbps | 32 30 28 26 24 22 20 | 35 → 21 … 16 | 1754 kbps |
| H.264 VBR 8000 (app-selected, gop 50) | 615 | 1237 kbps | 32, then 17 | 32 → 16 in 17 frames | 2384 kbps, QP 10 |
| H.265 VBR 2000 | 601 | 897 kbps | 36, then 17 | 36 → 16 | 1802 kbps (scroll) |

The first 60 QPs of the 8000 segment are frame-for-frame the vendor's
`R4/h264_static8000` trajectory (I32 35 33 32 31 … 21 hold; I30 33 32 … 19). The
static desktop is content-limited at every target ≥ 8000 for both controllers; ours
delivers fewer bits because the core runs with RC off and the descent frames are not
shaped up to `sw105` (the vendor's CTB RC spends 7–9 KB per descent frame, ours
~1.5 KB). At 2000 kbps ours lands at 84–94 % of target (vendor 100 %) for the same
reason.

Grabbed streams: `live_h264_8000` and both HEVC grabs decode with 0 ffmpeg errors;
`live_h264_2000/16000/chg` joined the running stream mid-GOP and decode with 0
errors from their first SPS (the direct-ws server does not resend SPS/PPS to a
late joiner until the next IDR — pre-existing behaviour, not RC).

Caveats: another viewer was connected to the device during the session (one
established `:443` connection from a remote host); it re-created the channel with
its saved `VBR` / `gop 50` settings between scripts, starved the first HEVC-8000 grab
(the retry with `POST /api/stream/rate-control mode=cbr` is the row above) and cut
the 3-minute stability grab at 63 s (`live_long.ws`, 3739 messages, clean). The
controller state it left behind (`rc=vbr gop=50`) is libkvm process state, reset by
the final service restart.

## Verdict

CBR-by-default is safe on the live path: the trajectories are the vendor's, both
codecs, every frame decodes, retargets are seamless, no failures or leaks. The one
visible difference from the vendor is lower delivered bitrate on content-limited
desktops (the core's in-frame CTB RC is off), which is a quality-headroom question
for v2, not a stability one. libkvm keeps `OPENKVM_VENC_RC=legacy|fixqp` as the
pinned-QP fallbacks.
