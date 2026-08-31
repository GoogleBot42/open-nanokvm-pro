# Vendor 17-geometry differential probe (#17, 2026-08-31)

Evidence base for the open encoder's parametric geometry
(`pkgs/vcenc-ewl/vcenc_geom.h`). The VENDOR encoder (`libax_venc` via the
deployed libkvm's exported `kvm_venc_*` wrappers) was driven at 17 distinct
geometries with a synthetic YUYV frame from a real `AX_POOL` block — no
capture involvement, no EDID/source changes — and each session's live cmdbuf
WREG program (all 511 registers, IDR + P) was decoded from the `venc_ko` CMM
pool. Same provenance posture as the rest of `vcenc-open/`: our own
observation of hardware we own, no vendor code consulted.

- `venc_geom_probe.py` — on-device driver (run with `nanokvm.service`
  stopped): AX_SYS_Init → `kvm_venc_create(chn7, H264, WxH, 60fps, gop30,
  8000kbps CBR)` → AX_POOL frame → 6× send/get → dump register-image mirrors
  + raw cmdbuf pool.
- `cmdpool_decode.py` — offline cmdbuf-slot → `{swreg: value}` decoder
  (fresh IDR = slot 1, fresh P = slot 2 of that run's pool dump).
- `lawfit.py` — the multi-geometry law-fitting harness (candidate formula
  table; the final laws live in `vcenc_geom.h`'s header comment).
- `programs/vendor_WxH_{IDR,P}.txt` — the decoded 511-register programs.
  Beyond #17 these are also RC evidence: each geometry's CBR-chosen initial
  QP (sw7), quant/lambda tables (sw125–132) and TARGETPICSIZE trajectory
  (sw105–107) at 8 Mbps are visible per geometry (#46 material).

Geometries: 640x480, 800x600, 1024x768, 1152x864, 1280x720, 1360/1362/1364/
1366/1368/1370/1372/1374 x768 (the partial-macroblock width sweep), 1440x900,
1600x900, 1920x1080, 1920x1200.

Key falsifications of earlier 1080p-only inferences (both were coincidences
at 1920x1080): `sw2` low16 is a CONSTANT 240 (not `2*mbw`); `sw237` low16 is
a constant 0x44 (not `mbh`). The golden-vector test
(`pkgs/vcenc-ewl/tests/vcenc_geom_test.c`, auto-generated vectors) pins every
law against all 17 observations: `nix build .#checks.x86_64-linux.open-venc-geometry`.

## 4K capture trace (2026-08-31 addition)

- `ioctltrace.c` — generic LD_PRELOAD ioctl tracer (`_IOC_SIZE`-safe hexdump of
  the arg for both directions, fd→path resolution). Cross-compile for aarch64;
  `LD_PRELOAD=… TRACE_OUT=/tmp/x.trace`.
- `cap4k_trace.py` — drives the VENDOR capture path (`kvm_sys_init` /
  `kvm_cap_start` / `kvm_cap_get`, exported by the deployed libkvm) at the live
  source geometry under the tracer, dumps the delivered frame's
  geometry/stride/format + a raw YUYV dump. Used to prove the vendor captures
  4K30 with the SAME MIPI config ({4 lanes, nDataRate=600, MODE_0}) and sys
  nr45 scalar (0x016e3600) the open path already replays — i.e. the MIPI link
  is not resolution-limited. See docs/blob-replacement.md "2026-08-31 — Open
  capture at 4K30".
