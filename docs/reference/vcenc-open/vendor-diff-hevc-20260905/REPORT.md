# Vendor VC8000E HEVC measurement campaign — 2026-09-05 (#64)

Device: NanoKVM-Pro (AX630C), running the shipped **open** image (v2.1.0-alpha.4) with the vendor
encoder stack put back **at runtime** for one session — no reflash, no on-disk change: `ax_sys/cmm/pool/
base/venc/jenc` (+ ivps/npu/vpp/gdc/tdp, loaded while bisecting an init failure) from `.#ax-ko-blobs`,
`libax_venc.so` from the stock v1.0.15 rootfs and the rest of the libax closure from `.#axera-libs`,
kernel 4.19.125. `nanokvm.service` stopped. Method as in `../vendor-diff-20260904/`: the vendor
`AX_VENC` driven through its **public MPI** by `tools/vdrive.c` (now `codec=h264|h265`), a synthetic
YUYV card in a real `AX_POOL` block, `venc_ko` CMM pools dumped over `/dev/mem` read-only, the fresh
cmdbuf slot decoded with `cmdpool_decode.py` (fresh IDR = slot 1, fresh P = slot 2, both codecs).
No vendor binary was read. No `/dev/mem` writes. Two warm reboots (one to clear a leaked module
reference before the swap, one to return to the open stack). Device left on the open stack, `nanokvm`
active, web 200, MJPEG streaming.

Pipeline validation (**H0**): the H.264 1080p CBR control run reproduces `../vendor-diff-20260904/E4/
vendor_base_{IDR,P}.txt` in all 511 registers except the 16 per-run address registers — the re-blobbed
stack is the same encoder the 2026-09-04 campaign measured (`H0/`).

Every `.h265` decodes in ffmpeg with zero errors: **108/108 streams**, every geometry including the
partial-CTU ones (`H9_conformance.txt`). Per-run artifacts as in the H.264 campaign; `vendor_*.txt` are
geom-probe format (`swregN 0x........`, swreg1..511).

## H1 — codec differential (the gate): PT_H265 is accepted; 19 registers separate HEVC from H.264

`AX_VENC_CreateChn(PT_H265)` rc=0 at 1080p CBR 8000 / fps 60 / gop 30 / Main / L5.1 / Main tier. Six
frames: VPS 27 B + SPS 53 B + PPS 12 B + IDR (nal 19) then TRAIL_R P frames. `base` ≡ `base_rep` in all
511 registers (IDR and P). The **cmdbuf opcode structure is byte-identical** to H.264
(`H1/ops_h264_IDR_slot1.txt` vs `ops_h265_IDR_slot1.txt`): the same 570 words — RREG(1,0x68),
WREG(511,0x1004), the 34-word secondary-bank block (`0x2800=0x44`, 16× `0x2014+i·0x20=0`), the
`sw5` kick, STALL/RREG(512)/CLRINT tail. No WREG outside `0x1000..0x17fc`, no length change, nothing
above sw320 nonzero.

Vendor HEVC headers (`H1/h1_base.parse.txt`): profile Main (1), tier 0, level 5.1; **CTB 64, min CB 8,
TB 4..16, max TU depth inter 4 / intra 2; AMP=1, SAO=1, PCM=0, TMVP=0, strong-intra-smoothing=0,
scaling lists off**; `log2_max_poc_lsb = 16`; two SPS short-term RPS sets, both `{neg=[-1 used]}`;
no long-term refs; VUI present (video_format 5, full_range 1, timing 1/60). PPS: `cabac_init_present=1`,
`num_ref_idx_default = 1/1`, **`init_qp = 32`**, `cu_qp_delta_enabled=1 (depth 0)`, sign-data-hiding 0,
transform-skip 0, weighted pred 0/0, tiles 0, WPP 0, deblocking control present (override 0, not
disabled, beta/tc 0), `log2_parallel_merge_level = 2`. Slices: IDR `slice_qp_delta=0`; P: `poc_lsb`
counts 1,2,3…, `short_term_ref_pic_set_sps_flag=1 idx 0`, `num_ref_idx=1`, `cabac_init_flag=0`,
`five_minus_max_num_merge_cand → 3 candidates`, SAO luma/chroma on, `slice_loop_filter_across=1`.
`num_extra_slice_header_bits=0`, no dependent slices, no slice header extension.

**IDR, H.264 → HEVC (19 non-address registers, `H1/regdiff_h264_vs_hevc_IDR.txt`):**

| swreg | H.264 | HEVC | reading |
|---|---|---|---|
| sw4 | `0x4090004a` | `0x21900054` | codec/config word (constant across every HEVC run) |
| sw5 | `0x3c044303` | `0x3c043803` | [31:20] `align8(W)/2`, [19:8] `align8(H)` — H.264 used align16 and `+3`; [1:0] frame type unchanged |
| sw6 | `0x00000003` | `0x0020000b` | bit21 set in every HEVC program; bit3 = intra picture (P clears it); bit0 = RC enable (as E1) |
| sw9 | `0x004047d8` | `0x004047a4` | `2WH + 0x10000 − (VPS+SPS+PPS bytes)` = −92 (E3 law, now with three parameter sets) |
| sw36 | `0x1c995f3c` | `0x1c995f14` | constant (0x1c995f00 at 640×480) |
| sw190 | `0x04000000` | `0` | H.264-only; HEVC sets bit30 (`0x40000000`) only once a long-term ref exists (H6) |
| sw191 | `0x14000000` | `0x4c000000` | picture-type word: HEVC IDR `0x4c`, P `0x04` (same as H.264 P) |
| sw193 / sw194 | `0x0010011d` / `0x0010011c` | `0x00100101` / `0x00100100` | the E4 CABAC (bit0) and 8×8 (bit1) H.264 bits are clear; bits [4:2] `0x1c` clear too; no HEVC knob moves them |
| sw202–207 | 0 / `0x05000101` / 0… | `00020002 00020002 00020002 000c0003 0033000c 00cc0033` | new HEVC constant block (write-only per H7) — CU/TU-size cost or split thresholds; not tunable from the SDK |
| sw208 | `0x78001ff0` | `0x79e01ff0` | constant |
| sw245 / sw246 | `0x20000888` / `0x02225028` | `0x20002224` / `0x08889010` | the E1 per-row RC coefficients, **now per CTB row** (law below) |
| sw277 | `0x84000000` | `0x83000000` | constant |

Everything else — including every geometry register but the ones above, the QP block at the same QP,
sw105–107, sw172/173, the secondary-bank pokes — is **identical**. The P-frame diff (36 registers,
`regdiff_h264_vs_hevc_P.txt`) adds only the QP/RC block (HEVC P chose QP 35 with a different table
instantiation — H3), `sw192 = 0` (H.264 P carries POC there; HEVC keeps it 0 and counts in `sw11`),
`sw198 = 0` (H.264 P `0xe00`) and the RC state words sw243/244/247.

## H2 — geometry sweep: 35 geometries accepted, three refused; the H.264 laws carry over (`H2/`)

Accepted (CBR 8000, fps 60, gop 30, 6 frames each): the E3 nine, the #17 set, 800×600, 640×480,
1280×1024, 2560×1600, 3840×1080, and the CTU-edge cases 1920×1088, 1920×1096, 1920×1152, 1928×1080,
1984×1080, 2000×1080, 3840×2176. **Refused with `0x8007020a`: 136×136, 200×136, 64×64** — the SDK's
documented 136 minimum is not the real floor; the smallest accepted here is 640×480 (the floor was not
bisected). Raw IDR/P pools kept for all 35 (`cmdpool_<geom>_{IDR,P}_*.bin`).

**H.264 laws that hold unchanged for HEVC at all 35 geometries** (`H2/law_check.txt`): `sw9`
(IDR `2WH+0x10000−hdr`, P `2WH+0x10000`), `sw38`, `sw134`, `sw210`, `sw212`, `sw213`, `sw237`,
`sw13−sw12 = 2WH`, `sw14−sw13 = WH`, luma pitch, chroma pitch, `sw72` pitch, `sw15−sw46 = 0x12000`,
`sw62−sw60 = align64(w4·mbhp/2)`. The recon floorplan is the H.264 one — still MB/4-MB padded — even
though the codec works in 64×64 CTUs. `sw202–207`, `sw4`, `sw208` do not move with geometry.

**HEVC laws for the registers that left the H.264 ones** (`H2/fit.txt`, exact at 35/35 unless noted):

- `sw5 = (align8(W)/2) << 20 | align8(H) << 8 | type` (H.264: `align16(W)/2`, `align16(H)+3`).
- `sw261 = align8(W) << 16 | 0x400` (H.264: `align16(W)`; differs at 1362/1364/1366/1368×768 and
  1928×1080). The coded width is the min-CB-aligned width.
- `sw245 = 0x20000000 | round(2^16/ctbw)·4`, `sw246 = round(2^18/ctbw) << 14 | 0x1010`, with
  `ctbw = ceil(W/64)` (H.264 used `mbw` and low field `0x1028`). P-frame `sw246` low field is `0x1018`
  at 640×480 and 800×600 only. In fixed-QP both are `0` / `0x1000` exactly as in H.264 (H3, H3x).
- `|sw241−sw239| = align4k(ctbw·ctbh)` — `0x1000` at every geometry up to 3840×2400 (2280 CTBs).
  RC buffers, `0` in fixed-QP (as E1).
- **`sw114 = 0` in every HEVC program**, IDR and P (H.264 alternates two banks of
  `align4k(w4·mbhp/2)`). One buffer fewer in the HEVC floorplan.
- `sw35 = 0x00010e1a` and `sw36 = 0x1c995f00` at 640×480 only (0x00018e1a / 0x1c995f14 elsewhere).

CBR's chosen IDR QP moves with geometry as in E3 (32 up to 2048×1080, 34/36 above) and, new, **the
vendor programs `sw105–107 = 0` at every geometry from 1920×1200 up** (1920×1200, 1920×1440, 2560×*,
3200×1800, 3440×1440, 3840×*) — no picture target at all, the VBR shape — while 1080p-class geometries
get the E3 `1760000`. RC behaviour, not geometry; irrelevant to the fixed-QP open path.

## H3 — fixed-QP ladder (`H3/ladder.txt`; per-frame programs `vendor_fixqpNN_f00k.txt`)

`AX_VENC_RC_MODE_H265FIXQP`, Q ∈ {16…51} + I28/P34, 1080p. Bitstream slice QP = requested QP in every
run (I and P). `u32StartQp/u32MeanQp` and the H265 CU-count stats are all 0 on this SDK.

- **`sw7 = (pic_init_qp << 26) | (frame_qp << 8)`** — the E2 law, unchanged (I28/P34: IDR `0x88001c00`,
  P `0x88002200`; `init_qp` = the PPS value, 34).
- **I frames: `sw37` and `sw125–132 = F(q−2k)` with `q = min(QP, 35)` — the E2 table, byte-identical**
  (F16 `016c/0510` … F32 `0904/2020`, F35 `0cc0/2d70`; Q≥36 clamps to the Q36 program).
- **P frames: `q = min(QP, 35)` with NO −3 offset** (H.264 P used `min(QP,35)−3`, clamping at 32).
  HEVC P at Q32 carries `F(32−2k)` and `sw37 = 0x00f00510`, the I values — except four table entries
  that differ between the I and P instantiations: F20 lo `0800→0810`, F26 hi `0480→0484`, F27 lo
  `1200→1210`, F33 hi `0a1c→0a20`. New table points: `sw37` at q=34 = `0x01800810`, F34 hi/lo
  `0b5c/2880` (from the P34 run).
- `sw105` 15000 at the IDR, 14828–15303 on P; `sw106 = sw107 = 0`; `sw172/173 = 0xf/0x66a`;
  `sw6 = 0x0020000a` (bit0 clear; P `0x00200002`); `sw22 = 0`; `sw245 = 0`, `sw246 = 0x1000`;
  `sw239 = sw241 = 0`; `sw243/244/247 = 0`. Same RC-off shape as E1/E2.
- Mirror read-backs (`vencblk_*`, transcribed): `sw9` = slice bytes; **`sw82` ≈ 2.03–2.08 M cycles for a
  1080p HEVC IDR, ≈ 2.04–2.09 M for P** — the same order as H.264 (2.15 M / 2.04 M).
- Static-card sizes: IDR 2499 B (Q16) → 740 B (Q51); the 6-frame HEVC streams are 30–40 % of the H.264
  ones at equal QP (H.264 Q16 IDR 6309 B).

`H3x/`: **fixed-QP32 IDR/P golden vectors at 1024×768, 1280×720, 1920×1200, 2560×1440, 3840×2160,
3840×2400** (+ 1080p from H3), all decodable, all obeying the H2 laws with the RC-off zeros
(`H3x/law_check.txt`, `fit.txt`); `fixring` = 14 fixed-QP frames per-frame (`fixring_table.txt`);
`h264_fixqp32` = the H.264 fixed-QP32 control from the same session.

## H4 — RC-mode differential (`H4/regdiff_modes.txt`)

Accepted: H265 CBR, VBR, AVBR, CVBR, FIXQP. **QVBR and QPMAP refused `0x8007020a`** (as H.264).
**CBR ≡ CVBR bit-for-bit; VBR ≡ AVBR bit-for-bit**; VBR differs from CBR only in `sw105–107` (IDR 0/0/0,
P `0x1f513/0/0x411aa`) and the P QP block (VBR P QP 32). **Fixed-QP vs CBR at the IDR = exactly the
E1 RC-enable set** — `sw6[0]`, `sw22[3:2]`, `sw105–107`, `sw172/173`, `sw245/246` (→ `0`/`0x1000`),
plus `sw239/241 → 0`; P adds the QP block and `sw243/244/247 → 0`. RC registers are codec-agnostic.

## H5 — knob sweep from the HEVC 1080p CBR baseline (`H5/knobs.txt`, 42 runs)

`base` ≡ `base_rep`. 460 of 511 registers never move under any knob. Knob → effect:

| knob | result |
|---|---|
| profile 1 (Main Still Picture) | accepted; **all-intra**: every frame an IDR (`dpb=1`, empty RPS), `general_profile_idc=3` in VPS/SPS; program unchanged bar `sw9` (header 91 B) |
| profile 2 (Main10) | accepted, **header-only**: `profile_idc=2` but `bit_depth 8/8`; program unchanged |
| profile 3 (MainRExt) | **refused `0x80070280`** |
| tier 1, level 3.1/4.0/5.0/6.0 | header-only (VPS+SPS PTL); program unchanged |
| gop 1/8/60/120 | `sw105–107` only (gop1 all-IDR: 133333) — E4 values reproduced exactly (gop8 960960, gop120 1920000) |
| fps 30, fps 60→30 | `sw7` hi = init_qp 26, `sw105–107` 2880000, SPS timing; `sw9` moves with the SPS length |
| bitrate 2000 / 16000 | 2000: QP block at IDR QP 35 (init 36) and **`sw105–107 = 0`**; 16000: init 26, target 3520000 |
| qpMin/Max 20..40 | `sw172 = 0x28f`, `sw173 = 0x502` (`minQp<<5|0xf`, `maxQp<<5|flags`) |
| qpMin=qpMax=30 | `sw172/173` + QP block at 30 |
| intraQpDelta −5 / +5 | IDR slice QP 30 / 40 (`sw7 0x80001e00` / `0x80002800`), first P 33 / 39 |
| firstFrameStartQp 30 | PPS `init_qp 30`, IDR slice QP 27, P 30 |
| idrQpDeltaRange 8 | `sw173` bit3 (`0x662→0x668`) + P QP block |
| slice split (`u32LcuLineNum`) 8 / 1 | `sw1 0x9fd→0x209fd`, **`sw6[31:16] = rows<<9 \| 0x20`** (`0x1020` / `0x0220`); second slice at `slice_segment_address` 240 / 30 (CTU units) |
| bRefRingbuf | `sw56/57/73/83` + `sw195` bit1 — as E4 |
| GOP mode ONELTR (interval 4) | accepted: `sw6 0x0020000b→0x0040001b` (bit22 + bit4), **`sw91 = 0x10`, `sw104 = 0x80000000`, `sw198 = 0x1000` at the IDR**; SPS gains `long_term_ref_pics_present`, four RPS sets, PPS `lists_modification_present=1` |
| GOP mode SVC-T | **refused `0x80070280`** |
| VUI on/off, intra refresh row/col, share, deBreath, deBreathQpDelta, sceneChangeDetect, rowQpDelta, statTime, re-applying RcParam | **nothing** in program or headers (VUI timing is emitted regardless) |
| minIprop/maxIprop 20/80 | IDR `sw105–107 = 0x222e00` only |
| moving content | P `sw105–107/243/244/247` only |

The secondary-bank poke block is byte-identical across every HEVC program of the campaign.
No SAO / CTU / TU / AMP / deblocking / transform-skip knob exists; the SPS/PPS defaults above are the
only HEVC configuration the silicon was ever driven with.

## H6 — DPB / RPS ring (`H6/*_table.txt`)

- **IPPP (`ring30`, `ring8`, `fixring`): the only register that changes from P to P is `sw11`, which
  counts 1, 2, 3…** and is the `slice_pic_order_cnt_lsb` written into the slice header. `sw192` stays
  0 (the H.264 POC register is unused). The recon/reference set ping-pongs exactly as in H.264:
  `sw18/19` = previous frame's `sw15/16`, `sw74` = previous `sw72`, `sw60/62 ↔ sw64/66`; `sw114` = 0.
- **IDR → P**: `sw5` low byte `03→01`, `sw6` bit3 clear, `sw191 0x4c000000→0x04000000`,
  `sw17 0x30→0xffd0007c`, `sw197 0→0xffc00000`, `sw173` bit3 (CBR only).
- **GOP wrap (`ring8`, IDRs at 8 and 16)**: `sw11 → 0`, `sw17 = 0xffd0003c` (bit6 clear vs P's `0x7c`;
  the very first IDR is `0x30`), `sw197` keeps `0xffc00000`, and the IDR programs its reference
  registers equal to its own recon (`sw18 = sw15`, `sw74 = sw72`) instead of 0. Later IDRs are
  `IDR_W_RADL` with `poc_lsb` restarting at 0.
- **ONELTR (`ltr30`)** is where the RPS descriptor lives: three recon banks; the IDR is pinned in bank
  0 as the long-term picture; every 4th P references bank 0 (`sw18 = IDR recon`) with `sw6` bit3 set;
  `sw190 = 0x40000000` from the second P on; **`sw17` carries the POC distance to the long-term
  picture** — `0xffdffa7c, 0xffdff67c, …` stepping `−0x400` per frame in bits [21:10], and on the
  LTR-referencing frames `0xff3ff47c / 0xfe3fe47c / 0xfd3fd47c / 0xfc3fc47c` (bits [27:22] = −4, −8,
  −12, −16); `sw91 = 0x10`, `sw104 = 0x80000000` on every frame, `sw198 = 0x1000` on the IDR only.
  Slice headers confirm: `lt=1 used=1` with `rps=sps[2] {}` on those frames, `used=0` otherwise.
  The P-frame lambda/F tables also differ under ONELTR (`sw37 = 0x01300650`, a distinct instantiation).

For the open encoder's IPPP path the RPS is trivial: increment `sw11`, keep `sw192 = 0`, alternate the
two banks. Nothing else in the program encodes the reference structure.

## H7 — live core window (`H7/`)

`regpoll2` on the VC8000E window during a 900-frame HEVC encode. Fuse words identical to E5:
**`sw80 = 0x88da4280` (H264=1, HEVC=1, JPEG=0), `sw214 = 0x48500800`, `sw226 = 0x00a19200`,
`sw287 = 0`, build id `sw509..511 = 0x2114 / 0x9b83c / 0x20230307`**. Against the H1 P program the live
window agrees in 458/511 registers; the write-only set (program nonzero, always read 0) is
`sw39–41, 125–132, 201–207, 236, 237, 250, 251, 272` — **the HEVC `sw202–207` block is write-only**,
like the rest of the lambda/threshold registers. `sw215–223` (lambda LUTs), `sw105–107`, `sw243/244/
247`, `sw78/79`, `sw111–113`, `sw183–185` are HW-updated per frame, as in E5b.

## H8 — CBR trajectories, moving card, 90 frames (`H8/traj*_trajectory.csv`)

- 2000 kbps: IDR QP 35, P QP climbs 38→51 within the first GOP, later GOPs settle at 46; achieved
  **1083 kbps** — HEVC under-shoots (H.264 over-shot to 3266 kbps on the same card).
- 8000 kbps: IDR QP 32, P 35→21 over the GOP; achieved 5191 kbps (content-limited).
- 16000 kbps: identical first-GOP trajectory to 8000; 5298 kbps achieved.
- Later IDRs get QP 30 then 28 at 8000 and 16000 (as H.264), 36 at 2000. `sw105–107 = 0` on the IDR of
  the 2000 kbps run (the VBR shape again).

## Not done / caveats

- The real minimum geometry was not bisected (640×480 accepted, 136×136/200×136/64×64 refused).
- QVBR/QPMAP, MainRExt and SVC-T: refused; no programs.
- `pred_weight_table` is not parsed by `h265parse.py`; the vendor never sets weighted prediction, so
  nothing was skipped.
- `sw17` / `sw190` / `sw91` / `sw104` / `sw198` semantics under ONELTR are recorded, not decoded to a
  bit map; the open encoder's IPPP path does not need them.
- The `.h265` streams are synthetic-card content only; only two 1080p streams are committed
  (`H1/h1_base.h265`, `H3/fixqp32.h265`, 7 KB and 4.6 KB) as decode witnesses for the replay step.
