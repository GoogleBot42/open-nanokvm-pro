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
  yet expose P-frame reference/DPB register state — that is the main unobserved
  gap, to be resolved in Stage 0 by decoding a P-frame command buffer.

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
