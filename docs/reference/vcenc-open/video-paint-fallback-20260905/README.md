# #69 page-side safety net: undrawable-video detection + H.264 Direct fallback

2026-09-05. Some Chromium installs decode video into a `<video>` element they
never paint: the page looks white (or blank), while every counter says the
stream is healthy. The trigger is **Chromium's Vulkan backend**
(`chrome://flags/#enable-vulkan`, i.e. `--enable-features=Vulkan`); it was
reproduced on the build host under headless KWin and confirmed on Jeremy's
desktop. The canvas modes (WebCodecs `h264-direct`, MJPEG) are unaffected.

The fix is in the page: the `<video>` players (`h264-webrtc.tsx`,
`mse-player.tsx`) run a paint check a couple of seconds into playback and, if
the element's frames cannot be read, switch to H.264 Direct with a notice that
names the flag.

## What discriminates (measured, both directions, same page, same Chromium)

The check builds one `VideoFrame` **from the element** and copies it out:

```js
const frame = new VideoFrame(video, { timestamp: 0 });
await frame.copyTo(new Uint8Array(frame.allocationSize()));
```

| KWin run | screen | `new VideoFrame(video)` + `copyTo` | WebRTC remote track | `captureStream()` track |
|---|---|---|---|---|
| `--enable-features=Vulkan` | 94% **white** | `InvalidStateError: Failed to read VideoFrame data` | ok, max luma 236 | ok, max luma 236 |
| no flag | desktop visible | ok, format NV12, max luma 237 | ok, max luma 236 | ok, max luma 236 |

Two things that do **not** work, both ruled out by measurement here:

- **Track-based reads.** Reading the WebRTC remote track, or a
  `captureStream()` track, succeeds in BOTH states. Frames really do leave the
  decoder; it is the element's own output that is lost. An early build probed
  those tracks and reported a healthy picture on a white screen
  (`fix-webrtc.log`-era runs; see `exp-vulkan.log` vs `exp-healthy.log` for the
  side-by-side). Stopping a `captureStream()` track on a WebRTC element also
  disturbed the live stream.
- **Pixel sampling.** Every GPU-side read under Vulkan — 2D `drawImage`, WebGL
  `readPixels`, `createImageBitmap` — comes back **opaque black**, which is
  exactly what a genuinely black host screen looks like on a healthy browser.
  The baseline logs show `drawImage {alphaSum: 587520, mean: 0, std: 0}` while
  the screen grab is 94% white.

## Behaviour

- Runs only in Chromium-family browsers that have `VideoFrame`, and only in the
  two `<video>` players. Firefox is never pushed off `h265-mse`.
- Starts 2 s after `playing`; up to 4 attempts 1 s apart. Only
  `InvalidStateError` counts; any other error is inconclusive and the check
  stops silently.
- On a verdict: logs
  `[video-paint] <mode>: Chromium is not painting decoded video frames (chrome://flags/#enable-vulkan does this); switching to h264-direct`,
  raises `videoPaintNoticeAtom`, rewrites the stored mode to `h264-direct`,
  tells the server, and sets `videoModeAtom` so the canvas player mounts.
- The notice is shown by `pages/desktop/index.tsx`, not by the player — the
  fallback unmounts the player, which would take its own notification with it.
- A `sessionStorage` flag (`nano-kvm-video-paint-fallback`) makes a second
  detection notify only, so a user who deliberately picks a `<video>` mode
  again is not bounced out of it.
- Debug-only: `localStorage.setItem('nano-kvm-debug-force-undrawable', '1')`
  forces the unreadable verdict. Kept deliberately, for testing the fallback on
  a browser that paints correctly.

## Evidence

Bundle under test: `assets/index-BZloHD67.js` (deployed to the device).
Baseline is the pre-fix bundle `assets/index-BXrlhUlY.js`, kept at
`/root/pre69/web` on the device.

| log | run | result |
|---|---|---|
| `base-webrtc.log` | pre-fix, Vulkan/KWin, `h264-webrtc` | 1779 frames decoded, screen **94% white**, `drawImage` mean 0 |
| `base-mse.log` | pre-fix, Vulkan/KWin, `h264-mse` | screen **94% white** |
| `exp-vulkan.log` / `exp-healthy.log` | discriminator matrix above | element frame throws only when white |
| `fix3-webrtc.log` | fixed, Vulkan/KWin, `h264-webrtc` | `[video-paint]` line, notice, `canvas#screen` 1920x1080, grab shows the desktop (whiteFrac 0.018) |
| `fix3-mse.log` | fixed, Vulkan/KWin, `h264-mse` | same, plus `storedMode: h264-direct`, `fallbackFlag: 1`, `video: false` |
| `fix3-healthy-webrtc.log` | fixed, KWin, no flag | `frames are readable; paint check done`; still `h264-webrtc`, no notice |
| `healthy-cdp-h264-webrtc.log`, `healthy-cdp-h264-mse.log` | fixed, headless Chromium, 30 s | `paint check done` at ~2.3 s, no fallback |
| `healthy-ff-h264-mse.log`, `healthy-ff-h265-mse.log` | fixed, headless Firefox, 30 s | check never runs, 1781 / 1782 frames shown |
| `forced-webrtc.log` | headless Chromium + the debug key | log line at 5.4 s, notice, stored mode `h264-direct`, `canvas#screen`, WebCodecs decoder configured |
| `predicate-test.log` | `node predicate-test.mjs` | 7/7 cases for the error classifier |

No screenshots are kept: every grab contains the attached host's desktop.

## Harness

`harness/` is the KWin/Xvfb runner copied from
`../chromium-white-compositors-20260905/harness/`, plus a `PROBE_JS`
environment hook that evaluates an extra expression at each checkpoint (used
for the discriminator matrix and the storage assertions), and the two probes
themselves:

```
KWIN_SCREENSHOT_NO_PERMISSION_CHECKS=1 \
/nix/store/fpriqpqsrnc747ribl2kh6121pwrdajp-python3-3.14.7-env/bin/python3 \
  xvfb_chrome.py https://127.0.0.1:8443/ h264-webrtc 30 <outdir> \
  --kwin --port 9380 --display 3 -- --enable-features=Vulkan
```

Drop the trailing `--enable-features=Vulkan` for the healthy control. Set
`PROBE_JS="$(cat harness/discriminator-probe.js)"` or
`harness/storage-probe.js` to add those readings. The tunnel comes from
`../mse-player-20260905/harness/tunnel.sh 8443 443`, and the headless
Chromium/Firefox runs use `cdp_ui.py` / `ff_ui.py` from that same directory.

`predicate-test.mjs` runs off-device (no browser): it lifts
`classifyCopyFailure` out of the hook source and checks that only
`InvalidStateError` means "not painting".
