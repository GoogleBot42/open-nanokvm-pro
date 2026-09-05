# NanoKVM-Pro web-UI browser harness

Drives the *real* web UI on the live device in headless Chromium (CDP) and
headless Firefox (WebDriver BiDi), with the video mode pre-seeded in
localStorage, and reports what the video surface actually did.

Every run uses a **fresh browser profile** (temp dir, deleted on exit) plus
cache-disabled prefs, so the device's cache-less `index.html` is never stale
(#71).

## 0. Tunnel (required)

`tunnel.sh [local-port] [device-port]` opens an SSH loopback forward. Requests
then arrive at the device from `127.0.0.1`, so the server's localhost auth
bypass applies; the React `ProtectedRoute` only needs a `nano-kvm-token` cookie
to *exist*, and both scripts set one.

```
./tunnel.sh 8443 443 &          # https://127.0.0.1:8443  <- use this one
```

It runs in the foreground, so background it and poll the port:

```
until curl -sk -m 2 -o /dev/null https://127.0.0.1:8443/; do sleep 1; done
```

Kill it when done: `pkill -f 'L 8443:127.0.0.1:443'` (or kill the recorded PID).

**Do not bother with plain HTTP.** `./tunnel.sh 8080 80` works, but the device's
:80 answers `307 -> https://127.0.0.1/` (port 443, hard-coded), which breaks
outside the tunnel. Use https on 8443 — both scripts already accept the
self-signed cert (`--ignore-certificate-errors` / `acceptInsecureCerts: true`).

## 1. Python

`python3` is not on PATH and `nix shell nixpkgs#python3Packages.websockets`
does **not** put `websockets` on that interpreter's path. Use an env:

```
nix build --impure --expr '(import <nixpkgs> {}).python3.withPackages (p: [p.websockets p.pillow])' \
  --no-link --print-out-paths
# -> /nix/store/z0ifiq53ry90qjzzy8zq7wzczszqb81k-python3-3.14.7-env
```

or one-shot:

```
nix shell --impure --expr '(import <nixpkgs> {}).python3.withPackages (p: [p.websockets])' \
  --command python3 ./ff_ui.py ...
```

## 2. Invocations

Both take the same arguments:

```
<script> <url> <video-mode> <seconds> <screenshot.png> [--port N]
```

video-mode is stored verbatim in localStorage `nano-kvm-vide-mode` (sic):
`h264-direct | h265-direct | h264-webrtc | mjpeg | h264-mse | h265-mse`.

Exact commands that were verified against the live device (2026-09-05):

```
PY=/nix/store/z0ifiq53ry90qjzzy8zq7wzczszqb81k-python3-3.14.7-env/bin/python3

# Firefox 154, MJPEG
$PY ./ff_ui.py  https://127.0.0.1:8443/ mjpeg       20 ./ff_mjpeg.png
# Firefox 154, H.264 direct (WebCodecs -> canvas#screen)
$PY ./ff_ui.py  https://127.0.0.1:8443/ h264-direct 20 ./ff_h264.png
# Chromium 152, H.264 direct
$PY ./cdp_ui.py https://127.0.0.1:8443/ h264-direct 20 ./cdp_h264.png
# Chromium 152, WebRTC (exercises the video#screen probe)
$PY ./cdp_ui.py https://127.0.0.1:8443/ h264-webrtc 14 ./cdp_webrtc.png
```

Default debug ports: Chromium 9335, Firefox 9444 — override with `--port N` to
run both at once.

Browser binaries default to the store paths; override with `$CHROMIUM_BIN` /
`$FIREFOX_BIN`.

## 3. What each run prints

- `--- seeded` (Firefox only): the cookie + mode actually written before boot.
- `--- probe t=6s` and `--- probe t=<duration>s`: `probe.js` evaluated in the
  page, as JSON — `href`, `title`, stored mode, cookie names,
  `canvas#screen {width,height,clientWidth,clientHeight}`,
  `video#screen {videoWidth, videoHeight, currentTime, readyState, networkState,
  paused, ended, duration, buffered ranges, quality.{totalVideoFrames,
  droppedVideoFrames}, srcObject, src, error}`,
  `img {naturalWidth, naturalHeight, complete, src}`, `MediaSource`/`VideoDecoder`
  availability, and every `.ant-notification-notice` text.
- `--- screenshot <path>`: full-page PNG (`Page.captureScreenshot
  captureBeyondViewport` / BiDi `captureScreenshot origin:"document"`).
- `--- console`: de-duplicated console log/warn/error + page exceptions for the
  whole run (CDP `Runtime.consoleAPICalled` + `Log.entryAdded`; BiDi
  `log.entryAdded`).

`probe.js` is shared by both scripts — edit it once, both pick it up.

## 4. Gotchas

- **MJPEG mode has no `#screen`.** It renders an antd `<img class="ant-image-img
  …">` with **no id**, `src=/api/stream/mjpeg`. `probe.js` therefore falls back
  to `img[src*="/api/stream/"]` and reports which element it matched (`el`).
- **Firefox BiDi endpoint**: `firefox --headless --remote-debugging-port=N`
  announces `WebDriver BiDi listening on ws://127.0.0.1:N` on **stderr**; the
  session websocket is that URL + **`/session`**. Connecting to the bare URL is
  rejected (HTTP 200, not an upgrade), and `/json/version` 404s — Firefox 154 is
  BiDi-only, CDP is off. `ff_ui.py` parses the stderr banner rather than guessing.
- **Cookie/localStorage seeding**: Firefox BiDi has no equivalent of CDP's
  `Page.addScriptToEvaluateOnNewDocument`, so `ff_ui.py` navigates to the origin
  once, runs the seed script, then navigates to the target URL. Chromium keeps
  using the pre-document hook.
- **Autoplay**: Chromium `--autoplay-policy=no-user-gesture-required`; Firefox
  `media.autoplay.default=0` + `media.autoplay.blocking_policy=0` in the fresh
  profile's `user.js` (plus BiDi `userActivation: true` on every evaluate).
  Verified: WebRTC `<video id=screen>` reports `paused: false`.
- **Cert**: never trusted, always bypassed — Chromium
  `--ignore-certificate-errors`, Firefox `acceptInsecureCerts` capability. Do not
  try to import the device cert.
- The UI pops a "Browser Recommendation" notification in Firefox (not Chromium)
  and a "Change Password" one in both; both show up in `notifications` and sit on
  top of the video in the screenshot.
- `HOME` is redirected into the throwaway profile for Firefox so nothing touches
  the real `~/.mozilla`.
