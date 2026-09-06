# #69 Chromium white `<video>`: headed-browser reproduction attempt — 2026-09-05

Jeremy's Linux Chromium (KDE Plasma, Wayland, AMD GPU) paints every `<video>`-element
mode white — WebRTC, H.264 (MSE), H.265 (MSE) — while the canvas modes (WebCodecs
direct, MJPEG) work, Firefox works, and chrome://webrtc-internals shows the frames
decoding at 59 fps in software. Earlier evidence came only from `--headless=new`
Chromium, which never reproduced it. This campaign ran *headed* Chromium 152 (and
Google Chrome 152) on real display servers on the build host (AMD Radeon 8060S,
Mesa 26.2.1 radeonsi) and graded what was actually on screen, not what Chromium
thought it drew.

## Method

`harness/xvfb_chrome.py <url> <mode> <secs> <outdir> [--headless|--wayland|--weston|--kwin] [--port N] [--display N] [-- chromium flags]`

- Starts a display server: Xvfb (default), sway with the wlroots headless backend
  (`--wayland`, `WLR_RENDERER=pixman|gles2`, `WLR_RENDER_DRM_DEVICE=/dev/dri/renderD128`
  for the real GPU), Weston 16 headless with `color-management=true` (`--weston`),
  or **KWin 6.7.4 `--virtual`** (`--kwin`, `KWIN_ARGS="--scale 2"` etc.).
- Launches Chromium windowed on it (`--ozone-platform=wayland` where relevant), seeds
  the KVM cookie + `nano-kvm-vide-mode`, hooks `RTCPeerConnection` and
  `requestVideoFrameCallback`.
- At each checkpoint reports: `<video>` state, WebRTC inbound-rtp stats,
  a `drawImage()` pixel sample of the element (decoder output), Chromium's own
  `Page.captureScreenshot`, **and a grab of the display server's framebuffer**
  (`import -window root` / `grim` / `weston-screenshooter` /
  KWin `org.kde.KWin.ScreenShot2` via `kwin_shot.py`) analysed for white fraction,
  mean and std over the video region.
- `chrome://gpu` feature status is dumped per run (`results/gpu-matrix.txt`).

KWin notes: `KWIN_SCREENSHOT_NO_PERMISSION_CHECKS=1` on the compositor is the only way
to call ScreenShot2 from an arbitrary process (the `X-KDE-DBUS-Restricted-Interfaces`
desktop-file route does not work without a full session); `kwinshot.desktop` is kept
for reference. KWin's virtual output reports HDR, wide-gamut and ICC as **incapable**,
so the KDE colour pipeline cannot be exercised headless.

Local control pages: `local_file.html` (software-decoded H.264 file, the
`WebMediaPlayerImpl` path shared by MSE) and `local_video.html`
(`canvas.captureStream()` MediaStream, the `WebMediaPlayerMS` path shared by WebRTC).

## Result: not reproduced anywhere

Every run below painted the video correctly on the display server's framebuffer
(white fraction 0–5 %, all of it UI chrome; mean/std match the source), with
decoded-frame counters advancing and `drawImage` returning real pixels.

| display server | renderer / GPU | Chromium flags | source | on screen |
|---|---|---|---|---|
| Xvfb (X11) | software compositing (llvmpipe blocklisted) | default | device WebRTC, device h264-mse | OK |
| Xvfb | GPU compositing via llvmpipe | `--ignore-gpu-blocklist --enable-gpu-rasterization` | device WebRTC | OK |
| Xvfb | none | `--disable-gpu` | device WebRTC | OK |
| sway headless | pixman | default | device WebRTC | OK |
| sway headless | gles2 on **radeonsi** | default, `--disable-accelerated-video-decode`, `--disable-gpu`, `--disable-gpu-compositing`, `--use-angle=vulkan` (RADV) | local file, local MediaStream | OK |
| sway headless | gles2 on radeonsi | default, **Google Chrome 152** | local file | OK |
| Weston 16 headless | GL on radeonsi, `color-management=true` (Chromium binds `wp_color_manager_v1`) | default, `--disable-gpu` | local file | OK when the window mapped¹ |
| **KWin 6.7.4 virtual** | GL on radeonsi; `wp_color_manager_v1` v2, colour-representation, drm-syncobj, single-pixel-buffer, fractional-scale all bound | default; `--scale 2` | local file, local MediaStream, **device WebRTC, device h264-mse** | OK |

¹ Weston + colour management + GPU compositing: in 2 of 3 runs the Chromium window
never appeared on the Weston output at all (framebuffer = background colour) while
Chromium's own capture showed content — a Weston-headless mapping race, not a white
video, and not Jeremy's symptom.

Also checked and ruled out from the fork's source: every player (canvas ones included)
applies the same `transform: scale(videoParameters.scale)`, so a stored scale cannot
single out the `<video>` modes; the page body is **black**, so a `<video>` that fails to
paint would read black, not white — Jeremy's white means the element is *painting*
white (or his page background differs).

## What is left

Everything that differs between these runs and Jeremy's desktop is per-session state
that cannot be synthesised here: the monitor's KDE colour settings (HDR / wide gamut /
ICC profile drive KWin's per-surface colour conversion, and Chromium 152 hands KWin
`wp_color_management` image descriptions for its surfaces), his Chromium profile
(flags, extensions), and his exact Chromium build. Discriminating tests requested from
Jeremy on the failing machine:

1. Console snippet on the white page: body background, `drawImage()` mean/white
   fraction of the `<video>` (decoder output vs compositor), UA string.
2. `chromium --ozone-platform=x11` (XWayland: bypasses Wayland colour management and
   overlay delegation entirely).
3. `chromium --disable-features=WaylandWpColorManagerV1,SurfaceColorManagement,WaylandOverlayDelegation`
   (feature names verified present in the 152 binary).
4. KDE Display settings for that monitor: HDR / wide colour gamut / ICC profile.

If (2) or (3) fixes it, the defect is in Chromium's Wayland colour-management or
overlay path on KWin, not in this project; the page-side mitigation would be an
opt-in canvas renderer (draw each `<video>` frame into `canvas#screen` on
`requestVideoFrameCallback`, the path the working modes already use).

Files: `harness/` (scripts + local pages + the KWin desktop entry),
`results/gpu-matrix.txt` (per-run `chrome://gpu` compositing/decode state and GPU string).
No screenshots committed (they show the attached host's desktop).

## Update, same night: REPRODUCED — trigger is `chrome://flags/#enable-vulkan`

Jeremy bisected his profile: a fresh profile rendered, and the one flag that breaks
it is **`#enable-vulkan`** (`--enable-features=Vulkan`, Skia's native Vulkan backend).
Reproduced here immediately:

| display server | `--enable-features=Vulkan` | source | on screen |
|---|---|---|---|
| KWin 6.7 virtual (radeonsi) | yes | local H.264 file (`local_file.html`) | **93 % white** (mean 238), Chromium's own capture 95 % white |
| KWin 6.7 virtual | yes | `canvas.captureStream()` MediaStream (`local_video.html`) | OK — canvas-sourced frames bypass the import |
| sway headless, gles2 radeonsi | yes | local H.264 file | **91 % white** |
| Xvfb, llvmpipe, `--ignore-gpu-blocklist` | yes | local H.264 file | OK (Vulkan not actually engaged) |
| KWin 6.7 virtual | no | local H.264 file, black clip | OK |

Chromium 152 with the Vulkan backend fails to import software-decoded video frames
on Wayland; every `<video>` mode (WebRTC, both MSE) is hit, the WebCodecs canvas
modes and MJPEG are not. `--enable-unsafe-webgpu`, Skia Graphite, and ANGLE-Vulkan
(`--use-angle=vulkan --enable-features=Vulkan,VulkanFromANGLE,DefaultANGLEVulkan`)
do NOT reproduce it — it is specifically Skia-on-Vulkan.

### Detector oracle (`local_oracle.html`, served same-origin via `python -m http.server`)

| read path | Vulkan | healthy |
|---|---|---|
| 2D `drawImage` + `getImageData` | opaque black (alpha 255, RGB 0) | real pixels (mean 123) |
| WebGL `texImage2D` + `readPixels` | black | real pixels |
| `createImageBitmap(video)` | black | real pixels |
| `captureStream()` → `MediaStreamTrackProcessor` → `VideoFrame.copyTo()` | **throws `InvalidStateError: Failed to read VideoFrame data`** | resolves, NV12, mean luma 126 |
| genuinely black clip (`local_black.html`), healthy | — | opaque black, RGB 0: pixel tests **cannot** separate it from the failure |

So the page-side fallback (see the `video-paint-fallback-20260905` evidence dir once it
lands) keys on `copyTo` throwing, never on pixel values.
