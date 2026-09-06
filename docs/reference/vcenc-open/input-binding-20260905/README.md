# Input binding: keyboard/mouse reaching the HID socket (#73)

2026-09-05. Evidence for "H.265 Direct (auto-MSE path): keyboard and mouse input
dead; explicit H.265 Direct (MSE) mode is fine". Reproduced and fixed, both
off-device and on the live device.

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
`MutationObserver` on the body, and both mouse hooks take it as an effect
dependency, so they bind when it appears and **rebind when it is replaced**
(mode switch, WebCodecs→MSE demotion, player remount).

## Keyboard was never broken

The keyboard hook binds to `document`, not to `#screen`, and it fired on every
run — including both unfixed h265-direct runs (2 frames, the ShiftLeft down/up
pair). The "keyboard dead" half of the report is a conflation: with no mouse
listeners nothing on the page calls `preventDefault()` on pointer events and the
pointer never moves on the attached host, which reads as total input death.
The device screenshots (not committed; they show the attached host's screen)
confirmed it: cursor untouched at the top in the unfixed run and parked at the
centre of the video (where the injected `mousemove` aimed) in the fixed one.

## Method

`harness/ff_input.py` (headless Firefox 154, WebDriver BiDi, fresh profile per
run) installs a **BiDi preload script** that wraps `WebSocket.prototype.send` and
counts frames per socket path, bucketed by the app's own tag byte
(`web/src/lib/websocket.ts`: 0 heartbeat, 1 keyboard, 2 mouse). The HID socket is
`/api/ws`. After the page settles it dispatches three `mousemove`s, a
`mousedown`/`mouseup` and a `wheel` on `#screen`, plus a `keydown`/`keyup` on
`document`, then reports the counter delta. Exit status is 0 only when both mouse
and keyboard frames were seen.

Injected input is harmless to the attached host by construction: button 4
(Forward) and ShiftLeft, so nothing is clicked and no character is typed — only
the pointer moves and the wheel scrolls.

`harness/mock_server.py` serves a built bundle with a stub backend (static files
+ an accepting `/api/ws` + a catch-all JSON reply), which reproduces the bug with
no device at all: the video never plays, but every player still mounts its
`#screen`, and that is what the binding bug is about.

For the live device, open `../mse-player-20260905/harness/tunnel.sh 8443 443` and
point `ff_input.py` at `https://127.0.0.1:8443/`.

## Results

Bundles: unfixed = `assets/index-Bg_C9wJe.js`, fixed = `assets/index-C49rIKCi.js`.
Frames counted on `/api/ws` for one injection burst.

### On the device (`device/*.json`)

Live open-stack HEVC playing throughout the h265 runs (1920x1080, ~880 segments
per 18 s run, 0 dropped on the fixed runs).

| bundle | stored mode | `#screen` | mouse | keyboard |
|---|---|---|---|---|
| unfixed | `h265-direct` | `video#screen` | **0** | 2 |
| unfixed | `h265-mse` | `video#screen` | 6 | 2 |
| fixed | `h265-direct` | `video#screen` | **6** | 2 |
| fixed | `h265-mse` | `video#screen` | 6 | 2 |
| fixed | `h264-direct` | `canvas#screen` | 6 | 2 |

### Off-device against the mock backend (`offline/*.json`)

| bundle | stored mode | `#screen` | mouse | keyboard |
|---|---|---|---|---|
| unfixed | `h265-direct` | `video#screen` | **0** | 2 |
| unfixed | `h265-mse` | `video#screen` | 6 | 2 |
| fixed | `h265-direct` | `video#screen` | **6** | 2 |
| fixed | `h265-mse` | `video#screen` | 6 | 2 |
| fixed | `h264-direct` | `canvas#screen` | 6 | 2 |
| fixed | `mjpeg` | `div#screen` | 6 | 2 |

Firefox picks MSE on this path for the measured reason: `isConfigSupported`
rejects every HEVC WebCodecs configuration while `MediaSource.isTypeSupported`
accepts `hvc1`/`hev1`.

## Trap: never deploy from a `--out-link` symlink

The first device deploy shipped an **unfixed** bundle under a *different* hash
(`index-DbdjOeXz.js`), so the "served hash changed" check passed and the fixed
run still measured mouse 0. A scratch `result-web` out-link had been re-pointed
at another build between the build and the `tar`. This is the deploy-iterate
skill's stale-`result-X` trap in its web-bundle form.

Deploy from the store path, and verify a *behavioural* marker in the artefact
rather than only its hash — for this fix, the entry bundle must contain exactly
**one** `getElementById("screen")` (the hook); the unfixed one has two:

```
OUT=$(nix build .#nanokvm-web --no-link --print-out-paths)
grep -o 'getElementById("screen")' $OUT/assets/*.js | wc -l   # 1 = fixed, 2 = not
tar czf web-fixed.tar.gz -C $OUT .
```

## Reproducing off-device

```
PY=$(nix build --impure --expr '(import <nixpkgs> {}).python3.withPackages (p: [p.websockets])' \
       --no-link --print-out-paths)/bin/python3
OUT=$(nix build .#nanokvm-web --no-link --print-out-paths)
$PY harness/mock_server.py $OUT 8099 &
$PY harness/ff_input.py http://127.0.0.1:8099/ h265-direct 12 /tmp/shot.png --json /tmp/run.json
```
