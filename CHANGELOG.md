# Changelog

One section per release, newest first. The heading is the exact tag
(`## vX.Y.Z` or `## vX.Y.Z-alpha.N`); the Gitea `cut-release` workflow refuses
to cut a version whose section is missing, and the GitHub release workflow
lifts the section verbatim into the release description. Write the section
before cutting. Older releases (through v2.1.0-alpha.3) predate this file.

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
