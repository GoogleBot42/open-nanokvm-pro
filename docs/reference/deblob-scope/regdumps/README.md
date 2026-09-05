# Golden register dumps — live vendor 4K capture vs base-only (M2 bring-up, 2026-08-31)

Our own `/dev/mem` observations of AX630C register state (NOT vendor code/DWARF).
Captured during the #59 M2 bring-up to seed a register-diff bring-up of the open
`open_vin_capture` driver. Little-endian u32 images.

| file | phys base | length | state |
|---|---|---|---|
| `regfile-vendor-live.bin` | 0x02400000 | 0xD4008 | full ISP/VIN register file, VENDOR stack streaming live 4K (3840x2160) |
| `glb-vendor-live.bin`  | 0x02500000 | 0x2000 | isp_sys_glb, vendor live |
| `cglb-vendor-live.bin` | 0x02340000 | 0x100  | common_glb, vendor live |
| `glb-now.bin` / `cglb-now.bin` | as above | | base-only boot (no capture stack) for diffing |

## Confirmed golden values (resolve spec [speculative]/checklist items)
- **WDMA gate**: 0x024140d4 = 0x0e8fc000 -> <<3 = 0x747e0000 (in CMM). `phys>>3` proven.
- WDMA chn8: enable 0x024140dc=1, shadow 0x024140d8=0x000f951f, mode 0x024140d0=0x1e2d1e2d.
- WDMA fmt bank chn8 at (8+0xf)<<5=0x2e0: 0x024142ec=0x08700f00 (W|H 3840x2160), 0x024142f0/f4=0x3c0.
- IFE-go 0x024146dc=1 (bit0). Int grp4 en 0x02400050=0x200 (bit9 chn8 frame-done); grp1 0x02400020=1 (FSOF).

## Spec CORRECTIONS found here (driver must adopt)
- **SIF IN_FMT** 0x02406510 = **0x40** (the driver's OVC_SIF_IN_FMT_YUV422_8=0x00030003 is WRONG for this HDMI YUV422 path).
- SIF DT-match: 0x02406540/44 = 0x00001e00 (DT 0x1E in byte<<8), park 0x02406548 = 0x3a3a3a00, VC/DT ctrl 0x0653c=1; WIN1 park 0x0651c=0x00200020.
- **MODE10 bypass masks are NOT at 0x14154/0x14158** — 0x14154 reads 0x00101720 (a WDMA per-channel stride), so the IFE-top bypass block base is ELSEWHERE and still unlocated.

## Wedged-state dumps + dumper (2026-08-31 device session)
`glb-wedged.bin` (0x02500000, 0x2000) and `cglb-wedged.bin` (0x02340000, 0x100) are
live dumps of the OPEN-stack bring-up state (base-only boot, M1 locked, our clock
writes applied) — captured to diff against the vendor-live dumps. The diff proved
the clock banks are MATCHED to vendor yet the datapath stays 0xDEADBEEF (see below).
`dumpreg.c` is the mmap register dumper used (devmem read() EFAULTs; compile on device
with gcc: `dumpreg <phys_base> <len> > out.bin`). Provenance: our own /dev/mem reads.

## The M2 wall — CLOCKS RULED OUT; blocker is a power domain / top-reset (2026-08-31)
Device-proven this session: with BOTH clock banks matched bit-for-bit to vendor-live
(common 0x02340000 +0x24=0x2ce00 incl CLK_VI_EB b17, +0x78=0x7400; isp_clk 0x02500000
MUX_RD=0x5af, gates 0xD0=0x3F/0xD8=0x3FE, IFE reset 0x5E000, sys_glb 0x90=0x230001),
the clock-activity status 0x025000C0/C4 STAY 0 and 0x02400000 STAYS 0xDEADBEEF. A
source sweep of ACLK_ISP_TOP across npll_533m/cpll_416m/cpll_208m/AND cpll_24m (the
always-on 24MHz reference) woke nothing. => the ISP block is UNPOWERED or held in a
top-level reset, NOT unclocked. Real blocker => ../specs/spec-isp-power-domain.md.
Clock diffs found along the way (now known necessary-but-insufficient): common 0x24
b17 (CLK_VI_EB) was off vs vendor; the 0x02500000 low region matches vendor except
deskew/sys_glb (0x90/98/9c). Key signature to reproduce: 0xC0/0xC4 nonzero == ISP
clock actually ticking (needs the block powered first).

## (superseded) mux notes — necessary, NOT sufficient (2026-08-31)
On a base-only boot the SIF (0x02406xxx) and IFE/WDMA (0x02414xxx) sub-blocks read
0xDEADBEEF and drop writes; the interrupt-controller sub-block (0x02400000-0xff) IS
writable (probe/IRQ work). Clean-room RE (`../specs/spec-vin-write-enable.md`) pointed
at the **ISP clock-source MUX (0x025000C8/CC)** — omitted by M1's gate-only bring-up.
Dump evidence: MUX_RD (0x02500000+0x00) reads 0x5ac base-only (glb-now.bin) vs 0x5af
live-vendor (glb-vendor-live.bin); clock levels 0xC0/0xC4 read 0x62/0x101 (base) and
0x04040404/0x0f0f (vendor); sys_glb 0x90 = 0x230001 (vendor) vs 0 (base).
**Device test (base-only, M1 locked, live 4K source):** writing mux codes 5/5/3 does
drive MUX_RD to 0x5af (mux CONFIRMED reachable) — but even then, with gates + IFE
reset, the datapath STAYS 0xDEADBEEF and 0xC0/0xC4 STAY 0. So the mux selects the
source but the ISP clock never starts; the real blocker is an upstream source-PLL
enable / power-domain (the 0xC0/0xC4 producers), now under RE in
`../specs/spec-isp-clock-enable.md`. NOTE the 0xC0/0xC4 nonzero-vs-zero split in these
dumps is the key signature to reproduce. Folded so far into
`pkgs/open-vin-capture` (`ovc_clk_mux_apply`, constant codes 5/5/3).

## 2026-09-01: the wall resolved (resets + ISP-top gate), front-end goldens, tools
Everything above the "superseded" notes is history; the resolved picture is in
`docs/deblob-capture.md` step 4. Short version: the deep-off boot holds every rst0/rst1
line (read views `0x0250000c/0x10`); per-bit deassert-all wakes the file; the ISP-top
gate `0x02400150` (SET `0x154`/CLR `0x158`, golden `0xffff7ff8` via CLR `0x8007`) makes
datapath writes stick. `0x02210000` (pllc) never changes; `0x02240000`/`0x02250000` are
timers. glibc memset/memcpy on a `/dev/mem` mapping SIGBUSes (DC ZVA on Device memory).

`frontend/` — our own `/dev/mem` dumps of the CSI front end: `vendor-idle-*` (fresh
production boot, deep-off) vs `vendor-streaming-*` (same boot, MJPEG stream running)
for 0x02340000 (0x1000), 0x02500000 (0x800), 0x02600000 (0x4000), 0x023f0000 (0x1000);
`m1-draft-*` = the same banks under the first-draft open receiver (before the
spec-dphy-writes fixes); `vendor-service-stopped-*` = production with nanokvm stopped
(ISP stays powered, only rst0 bits 10-12 held).

`tools/` — `ispbring.c` (mmap step tool: status / mux / gates / per-bit deassert,
pulse / AXI quiesce / top-gate probes; every subcommand is one SSH call so a bus hang
identifies the step), `replay.c` (replays ranges of `regfile-vendor-live.bin` with the
WDMA address pointed at a test buffer, polls frame-start/done, inspects DDR),
`v4l2cap.c` (minimal V4L2 mmap capture test), `bringup.sh` (the one-shot sequence).
Build on device with `gcc`. Never read `0x04403000` (VPP/MM domain) on an open boot.

## 2026-09-02: geometry differential + pixel parity -> `geom/`
The vendor driver run at five geometries against the one 4K source, the open driver
streamed at the same five, frames and register files diffed. Four geometry words
(all already parametric), `0x6530` is a constant, and the `0x142f8 = 0` WDMA sample
width word (missing from the non-zero-only snapshot) was the cause of the shifted
pixel values. Open frames now match the vendor's; packing is YUYV. `geom/README.md`.

## 2026-09-04: vendor receiver under its public API — `mipi-20260904/`
DataRate sweep, lane-count runs, Start/Stop polling and the `0x02303000` block,
all with the vendor `ax_mipi_rx` driven through the SDK API (read-only dumps).
Results are folded into `../specs/spec-mipi-rx.md` §9 (items 4, 6, 8 resolved,
5 partial). See `mipi-20260904/README.md`.
