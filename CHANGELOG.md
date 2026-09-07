# Changelog

One section per release, newest first. The heading is the exact tag
(`## vX.Y.Z` or `## vX.Y.Z-alpha.N`); the Gitea `cut-release` workflow refuses
to cut a version whose section is missing, and the GitHub release workflow
lifts the section verbatim into the release description. Write the section
before cutting. Older releases (through v2.1.0-alpha.3) predate this file.

## v2.1.0-alpha.6

Blob-free H.265, real rate control on both codecs, and the web UI becomes our
own. (v2.1.0-alpha.5 was tagged with this content but never published: its
release build died on a Go vendor hash left stale by #71. alpha.6 is alpha.5
plus that fix.)

- **Release build fixed.** `nanokvm-server`'s `vendorHash` is regenerated; a
  stale fixed-output hash is invisible on a host that already has the output,
  so `docs/building.md` now carries the pre-release `--rebuild` check.

- **H.265 (#64, #66).** The open encoder emits HEVC from source (VPS/SPS/PPS
  byte-identical to the vendor's, device-proven 1080p to 3840x2400) and the web UI
  gains "H.265 Direct" over a new `wss /api/stream/h265/direct`; every key
  message carries VPS/SPS/PPS so a decoder can start at any IDR.
- **H.265 in Firefox and Chrome on Linux (#72).** Those browsers decode HEVC for
  video elements but not through WebCodecs, so a MediaSource player remuxes the
  direct stream into fragmented MP4 for the browser's own decoder. "H.265 Direct"
  picks WebCodecs where it works and MSE otherwise; "H.264/H.265 Direct (MSE)"
  force it. The MSE player reconnects by itself after a service restart.
- **Rate control (#46).** A from-scratch CBR/VBR controller replaces fixed QP32
  for H.264 and H.265, written from measured vendor behaviour on real desktop
  content. The UI bitrate setting takes effect and changes apply in place without
  a stream restart. `OPENKVM_VENC_RC=legacy|fixqp` pin the old fixed-QP programs.
- **Web UI forked (`web/`).** Sipeed's web UI is now in-tree source (GPL-3.0 fork
  at `nanokvm@1.2.15`), no longer a patch stack over the upstream fetch.
- **Chromium fix (#68).** H.264 Direct no longer shows a white screen in
  Chromium: SPS/PPS ride in every key message. The H.265 option is never greyed
  out by a probe; fallback to H.264 happens only on a real decoder failure.
- **4K H.265 in the browser and live resolution changes (#72).** The MSE player
  plays 3840x2160 HEVC in Firefox and follows an HDMI mode change mid-stream
  with a new init segment, no reload. A stored video mode the browser cannot
  play is rewritten to the nearest one that can, with a notice, instead of
  silently starting WebRTC.
- **Web UI cached correctly (#71).** `index.html` is served `no-cache` with a
  content ETag and hashed assets `immutable`, so a plain reload picks up a new
  firmware's UI. Before, browsers kept the old bundle for years and even a forced
  reload got a stale 304.
- **Input in H.265 Direct (#73).** Mouse handlers bind whenever the video
  surface appears or is replaced; the auto-selected MSE player used to mount too
  late for them.
- **White video element auto-detected (#69).** Chromium's Vulkan backend
  (`chrome://flags/#enable-vulkan`) decodes into a video element it never
  paints, so the WebRTC and MSE players look white while every counter is
  healthy. The page now reads one frame from the element a couple of seconds
  into playback, and when the browser cannot hand it over it switches to
  H.264 Direct by itself, with a notice naming the flag.
- **Direct players reconnect (#67).** H.264 and H.265 Direct now reopen their
  WebSocket with backoff instead of freezing on a closed one, so a service
  restart, an OTA or a transient drop no longer needs a page refresh. The
  decoder rebuilds at the next key frame, which carries its own parameter sets.
- **Changing the video mode no longer reloads the page (#70).** The player is
  swapped in place, so the menu or settings panel the mode was picked from
  stays open.
- **The stream is handed back (#69).** One capture channel serves every viewer,
  and whoever connects last takes it. Before, nobody gave it back: a second
  browser or tab in another mode — or a single `curl /api/stream/mjpeg` — left
  the first viewer starved for good, which is what turned a WebRTC page white
  until it was reloaded. A consumer that loses its last client now passes the
  stream to whichever one still has viewers, and that page recovers on its own.
- **Fixes.** libkvm self-heals capture starvation and live geometry changes
  (#65).
- Known: the Chromium Vulkan bug behind #69 is not fixed, only worked around —
  H.265 needs a video element, so H.265 modes stay unusable there until the flag
  is set back to Default.
- Not in this image: the mainline-kernel port (#26) began in this window, and a
  mainline Linux 7.1.3 booted the AX630C for the first time (#74, #75, #80).
  It builds as separate flake outputs and changes nothing the firmware ships;
  `docs/mainline-port.md` tracks it.

## v2.1.0-alpha.4

The video path is blob-free at 4K, and the image ships no closed kernel
module or media library at all.

- **Zero vendor kernel blobs on the image (#54).** Every vendor `.ko` in
  `/soc/ko` (the 22-module ISP/VIN closure plus the aic8800 and touch copies),
  the vendor `libsns_*.so`, the NPU / AI-ISP model sets and the ISP
  sensor-tuning files are deleted from the rootfs (~355 files, ~248 MB).
  `/soc/ko` holds exactly the three open modules. No rollback loader ships;
  returning to the vendor stack is a reflash of the vendor `.axp`. WiFi
  bring-up now `modprobe`s the from-source aic8800 modules.
- **4K H.264 without blobs (#52).** The open encoder's envelope rises to
  3840x2160 and its frame-buffer carveout grows to 136 MB by taking the slice
  the vendor allocator no longer uses. Live H.264 at a native 4K source is
  device-proven; rate control remains fixed QP32.
- **Capture drivers linked (#55).** The open VIN capture driver binds the open
  CSI-2 receiver over v4l2-async and starts the link with the stream; a media
  device and subdev node are exposed.
- **Fixes.** The encoder module no longer emits DMA-mask WARN traces at load
  (#63). 720p60 is selectable from the web UI's EDID list (#62).
- Applying this by OTA keeps the old vendor files on disk (an OTA cannot
  delete); a fresh flash removes them.
