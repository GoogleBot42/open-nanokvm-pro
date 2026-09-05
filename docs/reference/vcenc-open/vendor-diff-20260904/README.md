# Vendor VC8000E measurement campaign (2026-09-04)

The last measurement of the vendor encoder before the mainline move retires the
4.19 vendor stack. Six experiments (E1–E6) against the vendor `AX_VENC`, driven
through its **public MPI** — the evidence base for the open encoder's rate
control (#46), for the geometry laws above 1920 wide, and for classifying the
`opaque` registers of `pkgs/vcenc-ewl/`. `REPORT.md` is the source of truth;
this file is provenance + index.

## Method and provenance

Same posture as the rest of `vcenc-open/`: **our own observation of hardware we
own, plus our own tooling. No vendor binary was read, no vendor source
consulted, no `/dev/mem` writes.**

The device was temporarily restored to the full vendor stack (21 `ax_*.ko`,
vendor libax, kernel 4.19.125; open-state backup in `/root/open-state-20260904`)
with `nanokvm.service` stopped. An on-device C tool (`tools/vdrive.c`, compiled
on the device against the `.#axera-libs` SDK headers) calls only the documented
MPI — `AX_VENC_CreateChn` / `SendFrame` / `GetStream` — and feeds it a
**synthetic YUYV test card** in a real `AX_POOL` block, so no host-screen pixel
is ever captured. After the chosen frames the `venc_ko` CMM blocks are dumped
over `/dev/mem` **read-only** and the fresh cmdbuf slot is decoded with
`geom-probe/cmdpool_decode.py` (fresh IDR = slot 1, fresh P = slot 2, verified
by pre/post snapshot diff). E5 additionally polls the VC8000E core MMIO window
at `0x04010000 + 0x1000` read-only while an encode runs.

Pipeline validation: a 1080p CBR run reproduces the committed
`geom-probe/programs/vendor_1920x1080_IDR.txt` in all 511 registers except the
16 per-run address registers (uniform `+0x22000` pool offset) — `smoke/`.
No reboots; device left with `nanokvm` active, web 200.

## Contents

- `REPORT.md` — the full write-up: every law, every number, the caveats.
- `E1/` — RC-mode differential at 1080p/8000 kbps. `regdiff_{IDR,P}.md` are the
  mode-vs-mode register tables; `vendor_rc_<mode>_{IDR,P}.txt` the programs
  (CBR/VBR/AVBR/CVBR/FIXQP; QVBR and QPMAP are refused at `CreateChn`).
- `E2/` — the fixed-QP QP ladder (Q16…Q51 plus I28/P34). `ladder.txt` carries
  per-frame NAL sizes, mirror read-backs and bitstream slice QPs;
  `ladder_{IDR,P}.md` the moved-register tables; per-QP and per-frame programs.
- `E3/` — vendor golden vectors **above 1920 wide**: nine geometries up to
  3840×2400. `law_check.txt` is the machine check of every `vcenc_geom.h` law
  against them. Includes the raw IDR/P cmdbuf pool dumps (below).
- `E4/` — 33-run single-knob sweep from the 1080p CBR baseline. `knobs.txt`
  holds the knob→register map, the never-moving register set, and the
  secondary-bank identity check; `vendor_<tag>_{IDR,P}.txt` the programs.
- `E5/`, `E5b/` — the live MMIO read of the encoder core during a vendor encode.
  `E5b/live_vs_program.txt` is the live-vs-program comparison plus the
  write-only / HW-updated register classification; `E5b/live512.bin` the full
  512-word snapshot, `E5/regs.bin` the 128-word `0x1000..0x1200` dump.
- `E6/` — CBR trajectories on a moving card, 90 frames each at 2000/8000/16000
  kbps: `traj*_trajectory.csv` (frame, type, bytes, slice QP).
- `smoke/` — the pipeline-validation 1080p run.
- `tools/` — `vdrive.c` (the MPI driver), `regpoll.c` / `regpoll2.c` (read-only
  core-window pollers; E5b came from `regpoll2.c`), `cmdpool_decode.py`,
  `decode_run.py`, `analib.py`, `h264parse.py`, `e3_analyze.py`,
  `e4_analyze.py`, `e56_analyze.py`, `e3.sh`, `e_rest.sh`.

## Deliberately NOT committed

- **The `.h264` bitstreams.** Synthetic-card content only, but bulky and of no
  evidential value — every claim about them (NAL sizes, slice QPs, SPS/PPS
  fields) is already extracted into the `.log`/`.csv`/`ladder.txt` artifacts.
  Same policy as `stage-fixedqp/`.
- **Most raw 64 KB cmdbuf pool dumps.** Only `E3/cmdpool_*_{IDR,P}_*.bin` are
  kept, as witnesses of the on-the-wire opcode format the decoder consumes. The
  E1/E2/E4/E6 pools stayed in the session scratchpad — including the pools that
  `E5b/live_vs_program.txt`'s "secondary-bank pokes identical across all 214
  programs" claim was checked against, so that particular claim is reproducible
  only from a re-run, not from this tree.
- Register-image mirror dumps (`vencblk_*`): their load-bearing fields (`sw9`
  emitted bytes, `sw82` cycles) are transcribed into `E2/ladder.txt`.

## File format

`vendor_*.txt` are **geom-probe format** — a two-line provenance header then
`swreg<N>  0x........`, one per line, swreg1..511. They are consumable as-is by
`geom-probe/lawfit.py` and by the golden-vector test generator
(`pkgs/vcenc-ewl/tests/`), so the nine E3 geometries can be folded into
`nix build .#checks.<sys>.open-venc-geometry` alongside the 17 from #17.
