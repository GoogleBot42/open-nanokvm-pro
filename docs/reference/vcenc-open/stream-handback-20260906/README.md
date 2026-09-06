# Stream hand-back, direct-player reconnect, in-place mode change — 2026-09-06

Device evidence for **#69** (stream-type hand-back, server), **#67** (direct
players reconnect) and **#70** (a video-mode change no longer reloads the page).

Device ran the fixed build hot-deployed over the shipped alpha.4 image: web
bundle `assets/index-CQn16NKV.js`, server md5 `7678a0c9…`, open stack, real
HDMI source at 1920x1080.

## #69 — the stream type is handed back

`harness/handback_test.py` runs on the device (stdlib only) and drives three
phases against the live server:

| phase | consumers | MJPEG frames / 6 s | direct messages |
|---|---|---|---|
| 1 | MJPEG only | 58 | — |
| 2 | MJPEG + h264-direct | 1 | 357 |
| 3 | MJPEG only again | 58 | — |

Phase 2 is the takeover working as designed (newest viewer wins). Phase 3 is
the fix: MJPEG's read loop, still spinning on the skip branch, gets the stream
back the moment the direct client's last socket closes.

**Control** (`handback_pre69_control.txt`): the identical test against the
pre-fix binary, built from `a2eb631` and deployed to both trees, gives phases
1 and 2 unchanged (58 / 1 frames, 359 direct messages) and **phase 3 = 0
frames** — MJPEG never recovers. A/B/A: PASS → FAIL → PASS across three
service restarts, so the test discriminates and the hand-back is what changes
it.

`handback_fixed.txt`, `handback_pre69_control.txt`.

The starved consumer here is MJPEG rather than WebRTC because it is the cheap
one to drive headlessly; the arbitration is the same code path for all four
consumers. The user-visible #69 symptom (a WebRTC page white until reload) is
the same starvation seen from the page that hides its `<video>` on
video-status -4.

## #67 / #70 — in a real browser

`harness/cdp_reconnect.py` runs the real UI in headless Chromium through the
loopback SSH tunnel (`../h264-direct-chromium-20260905/harness/tunnel.sh`).
Both claims are about page *lifetime*, so the oracles are things a reload would
destroy: `window.WebSocket` is wrapped before any app script to count sockets
and messages per URL, and a sentinel is written into `window` after load.

Full output in `cdp_reconnect_run.txt`.

**#67**, across a `systemctl restart nanokvm` 12 s into the run:

```
sockets 1 -> 5, messages 704 -> 3404, loads 1 -> 1, sentinel alive
```

The console shows the backoff ladder while the service was down —
`reconnecting in 500 ms`, `1000`, `2000`, `4000` — and the fifth socket carries
2 700+ messages. `loads` staying at 1 with the sentinel intact proves the page
never reloaded; before the fix there was no reconnect path at all and the
canvas stayed frozen.

**#70**, changing the mode to MJPEG through the real menu (the sidebar's Screen
item opens on click, its video item on hover, then the mode row is clicked):

```
loads 1, sentinel alive, canvas None, screenEl div, direct sockets closed [True x5]
```

The H.264 canvas is gone, every direct socket is closed and the MJPEG player is
mounted (antd's `<Image id="screen">` puts the id on its wrapper div), with the
page still on its first load. Upstream's `window.location.reload()` would have
made `loads` 2 and wiped the sentinel.

No separate pre-fix control was run for these two: the old bundle has no
reconnect code path to exercise, and the old mode-change path reloads by
construction. The bundle diff is the mechanical check — `location.reload()`
occurrences 8 → 6 (the two video-mode selectors) and `"reconnecting in"` 1 → 2
(the DirectPlayer joining the MSE player).

## Reproducing

```sh
# #69, on the device
tools/kvmscp harness/handback_test.py /tmp/
tools/kvmssh 'python3 /tmp/handback_test.py 6'

# #67 + #70, on the host
nohup bash ../h264-direct-chromium-20260905/harness/tunnel.sh &
nix shell --impure --expr '(import <nixpkgs> {}).buildEnv { name="h"; paths = with (import <nixpkgs> {}); [ chromium (python3.withPackages (p: [p.websockets])) ]; }' \
  --command python3 harness/cdp_reconnect.py https://127.0.0.1:8443/ \
  "tools/kvmssh 'systemctl restart nanokvm'"
```
