# Input binding: keyboard/mouse reaching the HID socket (#73)

2026-09-05. Evidence for "H.265 Direct (auto-MSE path): keyboard and mouse input
dead; explicit H.265 Direct (MSE) mode is fine".

## What was wrong

`web/src/pages/desktop/mouse/{absolute,relative}.tsx` read
`document.getElementById('screen')` **once**, inside a mount-time `useEffect`
that returned when the element was missing, with deps that never mentioned it.
`h265-direct.tsx` renders no player until the async `probeH265DirectConfig()`
resolves and picks WebCodecs or MSE, so on that path `#screen` first exists a
tick or two after the mouse hooks have already given up: no listeners, no mouse
frames. The explicit `h265-mse` mode mounts `MsePlayer` synchronously and was
unaffected — exactly the asymmetry in the report.

Fix: `web/src/hooks/useScreenElement.ts` tracks `#screen` with a
`MutationObserver` on the body and both mouse hooks take it as an effect
dependency, so they bind when it appears and **rebind when it is replaced**
(mode switch, WebCodecs→MSE demotion, player remount).

## Keyboard was never broken

The keyboard hook binds to `document`, not to `#screen`, and it fired on every
run — including the unfixed h265-direct one (2 frames, the ShiftLeft
down/up pair). The "keyboard dead" half of the report is a conflation: with no
mouse listeners nothing on the page calls `preventDefault()` on pointer events
and the pointer never moves on the attached host, which reads as total input
death.

## Method

`harness/ff_input.py` (headless Firefox 154, WebDriver BiDi, fresh profile per
run because of #71) installs a **BiDi preload script** that wraps
`WebSocket.prototype.send` and counts frames per socket path, bucketed by the
app's own tag byte (`web/src/lib/websocket.ts`: 0 heartbeat, 1 keyboard,
2 mouse). The HID socket is `/api/ws`. After the page settles it dispatches
three `mousemove`s, a `mousedown`/`mouseup` and a `wheel` on `#screen`, plus a
`keydown`/`keyup` on `document`, then reports the counter delta. Injected input
is harmless to the attached host by construction: button 4 (Forward) and
ShiftLeft, so nothing is clicked and no character is typed.

`harness/mock_server.py` serves a built bundle with a stub backend (static files
+ an accepting `/api/ws` + a catch-all JSON reply), which is enough to reproduce
the bug with no device: the video never plays, but every player still mounts its
`#screen`, and that is what the binding bug is about.

Against the live device, use `../mse-player-20260905/harness/tunnel.sh 8443 443`
and point `ff_input.py` at `https://127.0.0.1:8443/`.

## Results (offline, `offline/*.json`)

Bundles: unfixed = `assets/index-Bg_C9wJe.js` (parent of the fix),
fixed = `assets/index-C49rIKCi.js`. Frames counted on `/api/ws` for one
injection burst.

| bundle | stored mode | `#screen` | mouse frames | keyboard frames |
|---|---|---|---|---|
| unfixed | `h265-direct` | `video#screen` | **0** | 2 |
| unfixed | `h265-mse` | `video#screen` | 6 | 2 |
| fixed | `h265-direct` | `video#screen` | **6** | 2 |
| fixed | `h265-mse` | `video#screen` | 6 | 2 |
| fixed | `h264-direct` | `canvas#screen` | 6 | 2 |
| fixed | `mjpeg` | `div#screen` | 6 | 2 |

The unfixed `h265-direct` row is the bug, the unfixed `h265-mse` row is the
control that reproduces "explicit MSE is fine", and the fixed rows show no
regression in the modes that already worked. Firefox picks MSE on this path for
the measured reason: `isConfigSupported` rejects every HEVC WebCodecs
configuration while `MediaSource.isTypeSupported` accepts `hvc1`/`hev1`.

## Reproducing

```
PY=$(nix build --impure --expr '(import <nixpkgs> {}).python3.withPackages (p: [p.websockets])' \
       --no-link --print-out-paths)/bin/python3
nix build .#nanokvm-web --out-link /tmp/result-web
$PY harness/mock_server.py /tmp/result-web 8099 &
$PY harness/ff_input.py http://127.0.0.1:8099/ h265-direct 12 /tmp/shot.png --json /tmp/run.json
```

Exit status is 0 only when both mouse and keyboard frames were seen.
