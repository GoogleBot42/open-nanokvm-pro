# VCEnc open-reimplementation reference data

Device-observed reference material for a from-source, openly-licensed VC8000E
H.264 encoder core (the "fully open" path for issue #25 / #47). Captured on the
ATX unit, 2026-08-22. Feasibility write-up: `docs/blob-replacement.md`, stage
"2026-08-22 — VCEnc open-reimplementation feasibility".

## Provenance and licensing posture (read first)

Everything here is either **our own observation of the hardware** (register
values/offsets read from `/dev/mem`) or **our own tooling**. These are hardware
facts obtained by observing a device we own and are authorized to probe — the
Asahi/nouveau/OpenIPC interoperability model.

Deliberately **NOT** included: VeriSilicon's `registertable.h` / `nanoe_regs.h`
(marked confidential/proprietary), the vendor `libh2enc.so`/`libax_venc.so` DWARF,
and the EULA `imx-vpu-hantro-vc` sources. A clean, defensible open implementation
must derive register semantics from **these observations + the H.264 spec +
permissively-licensed references** (e.g. the BSD-3 STM32Cube `H264RateControl.c`),
not from those proprietary artifacts. Register *names* that appear in the
write-up are analytical convenience for cross-referencing; the load-bearing facts
are the **offsets and values here**, which were read from the silicon.

## Files

Register images are `swreg<N>` word dumps (byte offset = N×4) of the VC8000E
encoder register image mirrored into the VCMD DRAM pool, located by the
`0x90101010` (swreg0) marker. See `docs/blob-replacement.md` §8.5 for the method.

- `frame-register-image.txt` — full swreg0..319 image for one real H.264 frame,
  with absolute phys per word. The known-good reference program a Stage-1
  record-and-replay PoC starts from. (Truncated at swreg319; the core spans
  swreg0..~400 — extending this dump is Stage 0 work.)
- `regs_A2000.txt`, `regs_B2000.txt` — two captures at 2000 kbps (the run-to-run
  **noise floor**: exactly one register differs, swreg82 = a HW cycle counter).
- `regs_C8000.txt`, `regs_D16000.txt` — 8000 and 16000 kbps. The bitrate/QP
  differential: B→C moves 20 registers, C→D moves 7, all in the RC/QP cluster;
  300 of 320 registers are an invariant template. `TARGETPICSIZE` (swreg105–107)
  is linear in bitrate (440000 / 1760000 / 3520000).
- `regs_I1.txt`, `regs_P2.txt`, `regs_P3.txt` — early frames of a GOP. NOTE: the
  DRAM mirror at the first marker holds the IDR/setup program, so these do **not**
  yet expose P-frame reference/DPB register state — RESOLVED in `stage0/` (below).

## stage0/ — the completed static picture (2026-08-22)

Stage 0 of the feasibility plan: IDR WREG submission order + P-frame DPB register
state + register image extended to swreg400. Write-up: `docs/blob-replacement.md`
stage "2026-08-22 — Stage 0 complete". This resolved the last MEDIUM-HIGH gap;
H.264 confidence is now high. Captured with `tools/stage0dump.py` (parses venc_ko
pool bases live from `/proc/ax_proc/mem_cmm_info`).

- `idr_wreg_order.txt` — the ordered VCMD WREG program for one IDR (bulk swreg1..511
  burst → ASIC-0x2000 secondary-bank pokes → swreg5 kick written last → STALL/readback).
- `cmdbuf_IDR.txt` — the raw decoded IDR command buffer it was derived from.
- `regimg_P_m0..m6` — a 7-slot ring of consecutive frames (frame_num 0..6) in one
  coherent snapshot. The DPB evidence: swreg18 (ref luma) = previous frame's swreg15
  (recon luma) across all 7 slots; recon buffers ping-pong. swreg191 = coding type
  (0x14000000 IDR / 0x04000000 P).
- `regimg_IDR_m0_*` — the IDR register image extended to swreg400 (only swreg320 =
  0x400 is nonzero past the old swreg319 cutoff).
- `ring_slots_P.txt` — derived DPB ping-pong table; `diff_IDR_vs_P.txt` — the
  53-register IDR-vs-P diff (DPB regs + the RC/QP cluster).

## stage1/ — raw-ioctl drive attempt (2026-08-23)

Stage 1 tried to drive the encoder from open code over the public VCMD ioctls.
Write-up: `docs/blob-replacement.md` stage "2026-08-23 — Stage 1". RESERVE(29)/
RELEASE(32)/cmdbuf assembly work from independent open code; **LINK_RUN(30) EFAULTs**
because the stock Axera `ax_venc.ko` reads per-frame state set by extension ioctls
nr70/nr83 (an EWL↔.ko private seam) that an out-of-band reserve skips — properly
resolved by the open-driver port (#44), not here.

- `stage1_trace.log` — the full vendor per-frame ioctl sequence (the ABI ground
  truth): nr70 frame-setup → nr83 ×2 → RESERVE(29) → LINK(30) → WAIT(31) →
  RELEASE(32), with the exchange_parameter arg structs before/after each call.
- `run.out`, `stage1_replay.log` — our replay attempts: RESERVE rc=0, LINK errno=14,
  cycle-counter unchanged (HW never ran). The "OUTPUT identical" lines are false
  positives (output buffer still held libkvm's prior frame).
- `stage1_meta.txt` — captured pool bases + reference NAL metadata for the run.
- tools: `tools/stage1trace.c` (ioctl arg-deref tracer), `tools/stage1_record.py`
  (traced vendor-IDR capture), `tools/stage1_replay.py` (raw-ioctl replay;
  OWNFD/NOMEMCPY toggles).

**Path B — LINK-time cmdbuf hijack (the Stage-1 PoC that WORKED, 2026-08-23).** An
LD_PRELOAD `ioctl` hook lets libkvm set up all vendor state and call LINK on its own
cmdbuf, but rewrites the cmdbuf slot with our program just before the real LINK — so
libkvm's working LINK runs OUR register program. Proved an open register program drives
the encoder to a decodable, quality-controllable 1080p IDR on hardware. Write-up:
`docs/blob-replacement.md` stage "2026-08-23 — Stage 1 PoC ACHIEVED".

- `frame_control.png` — B0 control: a sharp 1080p desktop, decoded through the hijack path.
- `frame_qpforced.png` — B1: same scene, coarser, from forcing the effective-QP register
  block (IDR 7839 B vs 12086 B control, matching a native 400 kbps encode).
- `frame_b2self.png` — B2: full externally-supplied program injected, clean 1080p decode.
- `slot8k.bin`, `slot400.bin` — complete captured IDR register programs (2280 B, 570 words)
  at 8000 / 400 kbps — the known-good programs B1/B2 injected; the effective-QP delta is 13
  registers (swreg7, 37, 105–107, 125–132).
- tools: `tools/stage1hook.c` (the LINK-time hijack hook; copy/qp/edit/asm/dump modes),
  `tools/stage1_hijack_drive.py` (libkvm encode under the hook).

## vendor-diff-20260904/ — the final vendor measurement campaign (2026-09-04)

Six experiments against the vendor `AX_VENC` through its public MPI, taken while
the 4.19 vendor stack was still runnable: golden vectors at nine geometries up to
3840×2400, the fixed-QP QP ladder (the QP→register laws), the RC-mode
differential (the RC-enable register set), a 33-knob sweep classifying the
`opaque` registers, a live MMIO read of the core fuse words, and CBR trajectories
for #46. See its `README.md` and `REPORT.md`.

## hevc-plan.md — HEVC capture brief + implementation outline (2026-09-05)

Plan of record for adding H.265/HEVC to the open encoder (Gitea #64). The ready-
to-run vendor HEVC differential campaign brief (H0–H9, mirroring the 2026-09-04
H.264 method, for a future Fable device subagent) plus the from-source
implementation outline. The campaign needs the vendor `.axp` flashed and is
time-sensitive before the mainline move (#26).

## tools/

Our own capture/decode tooling (libc-only C or python via device libkvm ctypes):

- `pool_asic3.py` — dump the encoder register image (the §8.5 method).
- `pool_asic_diff.py` — parametrized multi-bitrate capture for the differential.
- `pooldump2.py` — VCMD command-buffer + status/register-pool decoder (WREG/RREG/
  STALL). NOTE: the non-WREG opcode mnemonics need confirming (see §8 caveat).
- `axvenctrace.c` — LD_PRELOAD ioctl/mmap tracer, magic-`'k'` filter, safe
  `_IOC_SIZE`-bounded arg reads. Build on-device: `gcc -O2 -fPIC -shared -o
  axvenctrace.so axvenctrace.c`.
- `drive_rc.py` — headless H.264 encode driver (libkvm ctypes) with per-frame
  QP/size extraction; produces the §8.4 rate-control reference trajectory.
