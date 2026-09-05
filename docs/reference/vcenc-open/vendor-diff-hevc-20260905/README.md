# Vendor VC8000E HEVC measurement campaign (2026-09-05, #64)

The vendor encoder's **H.265/HEVC** behaviour, measured through its public MPI on the shipped open
image with the vendor stack put back at runtime (no reflash). Nine experiments H0–H9 mirroring
`../vendor-diff-20260904/` (E1–E6): the evidence base for adding HEVC to the open encoder
(`docs/reference/vcenc-open/hevc-plan.md`). `REPORT.md` is the source of truth; this file is
provenance + index.

## Method and provenance

Same posture as the rest of `vcenc-open/`: **our own observation of hardware we own, plus our own
tooling. No vendor binary was read, no vendor source consulted, no `/dev/mem` writes.**

The vendor kernel modules came from the pinned `.#ax-ko-blobs` input and the userspace libraries
from `.#axera-libs` plus the stock v1.0.15 rootfs `libax_venc.so` (the SDK snapshot's copy differs and
rejects pixel-unit strides); they were loaded on top of the running open image with `nanokvm.service`
stopped and the three open modules unloaded (`tools/vendor-on.sh`), and discarded by a warm reboot at
the end (`tools/vendor-off.sh` is the no-reboot path; it needs the exact module list). The on-disk
loader was never touched, so a reboot at any point returns the open stack. `tools/vdrive.c`
(cross-built against the `.#axera-libs` headers) calls only `AX_VENC_CreateChn` / `SendFrame` /
`GetStream` on a synthetic YUYV card in a real `AX_POOL` block; the `venc_ko` CMM blocks are dumped
over `/dev/mem` read-only after chosen frames and the fresh cmdbuf slot decoded with
`tools/cmdpool_decode.py` (`decode_run.py --generic`: codec-agnostic slot finder keyed on the frame
type in `sw5[7:0]` and the vendor's fixed slot assignment). H7 polls the core MMIO window read-only.

Pipeline validation: the H.264 control run (H0) reproduces the 2026-09-04 base programs in all 511
registers except the 16 per-run address registers.

## Contents

- `REPORT.md` — every law, number and caveat.
- `H0/` — the H.264 1080p CBR control (must match `../vendor-diff-20260904/E4/vendor_base_*`).
- `H1/` — the codec gate: HEVC base + repeat, decoded programs, `regdiff_h264_vs_hevc_{IDR,P}.txt`,
  the full cmdbuf opcode listings (`ops_*.txt`), the parsed headers (`h1_base.parse.txt`) and the
  1080p stream itself (`h1_base.h265`, 7 KB) as the replay witness.
- `H2/` — geometry sweep, 38 requested / 35 accepted: programs, logs, **raw IDR/P cmdbuf pools**,
  `law_check.txt` (H.264 laws re-checked) and `fit.txt` (the HEVC laws).
- `H3/` — fixed-QP ladder Q16…Q51 + I28/P34, per-frame programs, `ladder.txt`, `fixqp32.h265`.
- `H3x/` — fixed-QP32 golden vectors at six more geometries up to 3840×2400, the 14-frame fixed-QP
  ring, and the H.264 fixed-QP32 control from the same session.
- `H4/` — RC-mode differential (`regdiff_modes.txt`).
- `H5/` — 42-run knob sweep (`knobs.txt`: knob → registers/headers map).
- `H6/` — DPB/RPS rings: gop 30, gop 8 (two wraps), ONELTR at two intervals (`*_table.txt`).
- `H7/` — live core window: `live512.bin`, 32 samples, `h78.txt` (also holds the H8 summary).
- `H8/` — CBR trajectories at 2000/8000/16000 kbps (`*_trajectory.csv`).
- `H9_conformance.txt` — ffmpeg decode of all 108 streams: zero errors.
- `tools/` — `vdrive.c` (codec/tier/gopmode/LTR/VUI/stride knobs), `regpoll2.c`, `cmdpool_decode.py`
  (+ `ops`/`opsig` structural listings), `decode_run.py` (`--generic`), `h265parse.py` (VPS/SPS/PPS/
  slice/RPS parser from ITU-T H.265 §7.3, validated against ffmpeg `trace_headers`), `regdiff.py`,
  the per-phase analysis scripts, the on-device batch (`hbatch.sh`) and the stack swap scripts.

## Deliberately NOT committed

- The other 106 `.h265` bitstreams and the `vencblk_*` register-image mirrors (their `sw9`/`sw82`
  read-backs are transcribed into `H3/ladder.txt`).
- Raw cmdbuf pools outside H2 (H3/H4/H5/H6 pools stayed in the session scratchpad).

## File format

`vendor_*.txt` are geom-probe format: two provenance lines, then `swreg<N>  0x........` for
swreg1..511 — consumable by `../geom-probe/lawfit.py` and the `pkgs/vcenc-ewl/tests/` golden-vector
generator.
