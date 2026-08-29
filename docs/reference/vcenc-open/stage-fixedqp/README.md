# Stage fixed-QP — from-scratch open VC8000E fixed-QP IDR generator

Device-proven 2026-08-29 (ATX unit). The blob-free encoder-core deliverable for
the **fixed-QP open v1** decision (#47): a documented, from-scratch generator that
emits the VC8000E register program for a chosen fixed QP + 1080p geometry, validated
end-to-end on real silicon via the Stage-1 Path B hijack harness.

See `docs/blob-replacement.md`, the 2026-08-29 fixed-QP stage, for the full writeup
and the overseer verification.

## Provenance (what is and isn't here)

Everything in this tree is **our own tooling and our own device observations** — no
proprietary vendor source, no vendor binary DWARF, no captured host-screen pixels.

- `tools/gen_idr.py` — the generator. Emits swreg1..511 for a chosen QP. Registers are
  classified `qp` (computed from QP by a derived scaling law), `known` (fixed template,
  meaning decoded from public VC8000E/Hantro semantics + our dumps), or `opaque` (fixed
  template, role known but exact bitfields not yet decoded — copied from our invariant
  1080p observation). The QP block (sw7/37/105-107/125-132) is computed, not replayed.
- `tools/gen_hook.c` — Path B LD_PRELOAD hook: overlays swreg1..511 into the live cmdbuf
  slot at LINK, **preserving the 16 per-run address registers** (output/input/recon
  physes) so no invented physical address ever reaches DMA. This is the on-hardware test
  harness — it drives libkvm's own working LINK with our register image.
- `tools/drive_gen.py`, `tools/pps_patch.py`, `tools/repps.py` — the QP-ladder driver and
  the matching-PPS emitter (pic_init_qp must agree with the slice for a clean decode).
- `evidence/img_qp32.bin`, `img_qp36.bin` — generated register images (swreg1..511) at the
  two anchor QPs. img_qp32 is byte-identical to the captured QP32 anchor; img_qp36 matches
  the QP36 anchor within &lt;17-LSB rounding.
- `evidence/gen_*.regs` — swreg0..320 readback dumps per QP run. These are **encoder
  register values**, not pixel data; they carry the `swreg82` HW cycle counter that proves
  the hardware genuinely executed each distinct program (it advances and varies per QP).

**Deliberately NOT committed:** the `.nal`/`.h264` bitstreams and `.png` decodes. Those are
captures of whatever was on the HDMI-captured host screen and are treated as potentially
sensitive content (same policy as the mini-display fb dumps). The register evidence above
is sufficient to re-derive every load-bearing claim.

## What this proves and doesn't

Proven: a from-scratch open register program drives this silicon to a correct, decodable,
QP-controllable 1080p H.264 IDR. NAL size is monotonic in QP; swreg82 varies per program.

Not yet: ~40 `opaque` template registers have role-known/bitfield-undecoded values copied
from our 1080p observation (cracking them needs the public eswin VCEnc reference cross-walk
— a follow-up, not a blocker for fixed-QP 1080p KVM). The QP anchor is empirical (two
captures), P-frames are not attempted here, and the true fixed-QP path should disable RC
rather than drive TARGETPICSIZE (RC-enable bit not yet located). See the doc stage.
