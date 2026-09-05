# Vendor VC8000E measurement campaign — 2026-09-04 (encoder)

Device: NanoKVM-Pro, full vendor stack (21 ax_*.ko, vendor libax), kernel 4.19.125.
Method: the vendor AX_VENC driven through its PUBLIC MPI (`AX_VENC_CreateChn`/`SendFrame`/`GetStream`,
SDK headers from `.#axera-libs`) by an on-device C tool (`tools/vdrive.c`, gcc on the device), with a
synthetic YUYV card in a real `AX_POOL` block, `nanokvm.service` stopped; after chosen frames the
`venc_ko` CMM blocks are dumped over `/dev/mem` (read-only) and the fresh cmdbuf slot is decoded with
`cmdpool_decode.py` (fresh IDR = slot 1, fresh P = slot 2 — verified by pre/post snapshot diff).
Pipeline validation: a 1080p CBR run reproduces the committed
`docs/reference/vcenc-open/geom-probe/programs/vendor_1920x1080_IDR.txt` in all 511 registers except the
16 per-run address registers (uniform +0x22000 pool offset) — `smoke/`. No vendor binary was read.
No /dev/mem writes. No reboots occurred. Device left with `nanokvm` active, web 200.

Everything below lives on-device under `/tmp/axwork/<phase>/` (tmpfs) and here under `<phase>/`.
Per-run artifacts: `<tag>.log` (per-frame NAL sizes/types), `<tag>.h264` (synthetic-content bitstream),
`cmdpool_<tag>_<pre|IDR|P|fNNN>_0x7382c000.bin` (raw 64 KB cmdbuf pool), `vencblk_*` (the other two
venc_ko blocks — they hold the register-image MIRRORS: marker 0x90101010 at 0x7383e800 + 0x2000·n, one
per frame, with HW read-backs sw9 = emitted bytes, sw82 = cycles), `vendor_<tag>_{IDR,P}.txt` (decoded
511-register programs, geom-probe format). Tools: `tools/` (vdrive.c, regpoll2.c, decode_run.py,
analib.py, h264parse.py, e3_analyze.py, e4_analyze.py, e56_analyze.py, e3.sh, e_rest.sh).

## E3 — vendor golden vectors above 1920 wide (`E3/`, `E3/law_check.txt`)

All 9 geometries ACCEPTED (rc=0, 6 frames each; nothing refused): 3840x2160, 2560x1440, 3440x1440,
2560x1080, **3840x2400**, 1920x1440, 2048x1080, 3200x1800, plus 1920x1080 as control.
Programs: `E3/vendor_WxH_{IDR,P}.txt` (consumable by lawfit/golden-vector test as-is).

Law check against `pkgs/vcenc-ewl/vcenc_geom.h` (script `tools/e3_analyze.py`):

| law | result at all 9 geometries |
|---|---|
| sw5, sw38, sw134, sw193(I/P), sw210, sw212, sw213, sw237, sw245, sw246, sw261, sw2=0xf0 | **exact** |
| sw13−sw12 = 2WH, sw14−sw13 = WH, luma pitch (sw15 P−I), chroma pitch, sw72 pitch, sw15−sw46 = 0x12000, sw62−sw60 = align64(w4·mbhp/2), sw239 bank size | **exact** |
| sw9 | exact only with the REFINED law below |

Mismatches / corrections the extrapolation needs:

1. **sw9 (IDR) = 2·W·H + 0x10000 − (SPS+PPS bytes)**, not `2WH + 0xffd8`. 0xffd8 = 65536−40 is the
   1080p header size (SPS 32 + PPS 8). The vendor's 4K SPS is 33 B + PPS 9 B → `0xffd6`; 2560x1080 → 43 B →
   `0xffd5` (E3 logs, `n7:`/`n8:` fields; E4 confirms: profile11/fps30/br2000 change the SPS/PPS length and
   move sw9 by exactly that). P-frame sw9 = 2WH + 0x10000 exactly. The open generator emits its own
   headers, so it must subtract ITS header length.
2. **sw105–107 (TARGETPICSIZE) at the IDR is NOT pixel-scaled: 1760000 at every geometry** (8000 kbps,
   fps 60, gop 30). `vcenc_geom.h`'s `targetpicsize = 1760000·W·H/(1920·1080)` is wrong for >1080p: the
   vendor's value is bitrate/fps/gop-derived only (E4: br2000 → 0x6b6c0=440000, br16000 → 0x35b600=3520000,
   fps30 → 0x2bf200=2880000, gop8 → 0xea9c0=960960, gop120 → 0x1d4c00=1920000, iprop20_80 → 0x222e00).
   Exact form: 1760000 = 8 Mbps × 0.22 s; = bitrate·(1000/60)·(gop-dependent I-share); the gop points fit
   `bits/frame = br·1000/fps`, `IDR target = bits/frame × k(gop)` with k(30)=13.2, k(8)=7.2, k(120)=14.4,
   k(1)=1.0 (gop1 → 133333 = exactly br·1000/fps) — needs a proper fit but the shape is "I-frame budget
   from bitrate and GOP", no pixel term.
3. **sw114 bank spacing**: the vendor separates the two sw114 banks by `align4k(w4·mbhp/2)` (0x1000 at
   1080p … 0x4000 at 2160p, 0x5000 at 2400p). The generator's bound `align4k(mbhp·64)` is SMALLER than the
   vendor's spacing at 3200x1800 (0x2000 vs 0x3000), 3440x1440 (0x2000 vs 0x3000), 3840x2160 (0x3000 vs
   0x4000), 3840x2400 (0x3000 vs 0x5000). The 17-geometry fit was a coincidence of 1920-wide widths
   (60·mbhp ≈ 64·mbhp). Fix: `s114sz = align4k(w4*mbhp/2)` (fits all 26 geometries).
   sw60 bank spacing stays inside the generator's bound at all geometries (e.g. 0x14000 vs bound 0x20000 at 4K).
4. **CBR's chosen initial QP moves with geometry** at 8 Mbps: QP32 up to 2048x1080, QP34 at 1920x1440 /
   2560x1080, QP36 from 2560x1440 up (sw7 hi field; sw37 and sw125–132 follow the E2 laws). Pure RC, not
   geometry — but a >1080p golden-vector test must not expect the 1080p QP block.
5. **P-frame registers sw243/sw244/sw247 vary with geometry** (sw243 0xaaa800@1080p … 0xe40000@4K, sw244
   0/0x400/0x1000/0x1400, sw247 0x1acbc2 … 0x7f83c2) — E4/E1/E5 show they are per-frame RC bit-budget
   state (move with bitrate, profile, slice count, content; zero in fixed-QP; change every frame in the
   live window), so they are NOT geometry laws; the generator's "leave 0" policy matches fixed-QP.
6. P-frame reference/aux address set is sw18/19/64/66/74 (+ sw114 alternate) — sw66 = sw64 + the same
   `align64(w4·mbhp/2)` as sw62 = sw60 + …, at every geometry (matches the generator's parity model).

## E2 — fixed-QP ladder at 1080p (`E2/`, `E2/ladder.txt`, `E2/ladder_{IDR,P}.md`, per-QP programs)

Mode `AX_VENC_RC_MODE_H264FIXQP` (u32IQp=u32PQp=Q), Q ∈ {16,20,24,28,32,36,40,44,48,51} + (I28,P34).
Bitstream slice QP (parsed from the .h264) = the requested QP in every run; the API's
`u32StartQp/u32MeanQp` are not populated by this SDK (always 0), so the bitstream is the QP truth.
Per-frame mirrors give sw9 = slice bytes (e.g. 6309 for Q16 IDR, matches NAL) and sw82 cycles
(IDR ≈ 2.15 M, P ≈ 2.04 M cycles at 1080p — content-independent to ±0.5 %).

Register laws (exact over the whole ladder):

- **sw7 = (pic_init_qp << 26) | (frame_qp << 8)**. Proven by I28/P34: IDR sw7 = 0x88001c00 (init 34
  from the shared PPS, frame 28), P = 0x88002200. The earlier "0x140/QP interpolation" of the low field
  is wrong; the CBR captures' 0x2300/0x2500/0x2800 are simply the P/IDR frame QPs (35, 37, 40).
- **sw125–132 = LUT F(q − 2k), k = 0..7**, with q = min(QP, 35) for I frames and q = min(QP, 35) − 3 for
  P frames (P@Q32 = F(29−2k); I@Q≥36 == I@Q36 == F(35−2k) — the table CLAMPS at QP 35 for I, 32 for P;
  Q36…51 programs are identical in this block). F(q) hi16/lo16 per q from the ladder (hex):
  F16=016c/0510 F18=01c8/0660 F20=0240/0800 F22=02d8/0a20 F24=0394/0cc0 F26=0480/1010 F28=05ac/1440
  F30=0728/1980 F32=0904/2020 F33=0a1c/2410 F35=0cc0/2d70; also F19=0200/0720 F21=0288/0900 F23=0330/0b60
  F25=0404/0e50 F27=0510/1200 F29=0660/16b0 F31=0808/1ca0 F17=0198/05b0 F15=0144/0480 F13=0100/0390
  F11=00cc/02d0 F9=00a0/0240 F7=0080/01d0 F5=0064/0170 F3=0050/0120 F1=0040/00e0 (from P@Q16 = F(13−2k)).
  Growth ≈ 2^((q−32)/6) — a lambda-type table, not the 2^(dQP/8) of gen_idr.py.
- **sw37 = (hi,lo) lambda pair**: I: Q16 0x00040020, Q20 0x000c0050, Q24 0x002400c0, Q28 0x00600200,
  Q32 0x00f00510, Q≥36 0x01e40a20 (clamp); P = I value at QP−3 (Q32 → 0x00780280; Q34 → 0x00c00400).
  ≈ ×2.52 per +4 QP → λ ∝ 2^(QP/3).
- sw105 in fixed-QP: IDR 15000 (0x3a98) constant; P ≈ 14900–15100; sw106 = sw107 = 0.
- Sizes (static card): IDR 6309 (Q16) → 1498 B (Q51); P 3775 → 70 B. Full table in `ladder.txt`.

## E1 — RC-mode differential at 1080p, 8000 kbps (`E1/regdiff_{IDR,P}.md`)

Accepted: CBR, VBR, AVBR, CVBR, FIXQP. **QVBR and QPMAP refused at CreateChn with 0x8007020a**
(AX_ERR_ILLEGAL_PARAM) with the header-documented minimal attrs.

IDR: fixed-QP vs CBR differs in exactly 9 registers:
`sw6 3→2 (bit0)`, `sw22 0xc→0 (bits 3:2)`, `sw105 1760000→15000, sw106/107 →0`, `sw172 0x14f→0xf`,
`sw173 0x662→0x66a (bit3)`, `sw245 0x20000888→0`, `sw246 0x02225028→0x1000`.
P adds the QP block (sw7/37/125–132 = QP32 vs CBR's QP35) and `sw243/247 → 0`.

Reading: **the RC-enable cluster = sw6[0] + sw22[3:2] + sw245/sw246 (the per-MB-row rate coefficients
0x20000000|4·2^16/mbw and 2^18/mbw<<14|0x1028 — geometry-dependent ONLY because RC is on) + sw172/173
QP-range fields + sw105–107 target.** sw172 = minQp<<5 | 0xf, sw173 = maxQp<<5 | flags (E4: qp20_40 →
0x28f/0x502, qp30_30 → 0x3cf/0x3c2; fixqp → 0xf/0x66a); sw173 bit3 set in fixed-QP and in the P programs,
bit1 always. CBR ≡ CVBR bit-for-bit; VBR ≡ AVBR bit-for-bit; VBR differs from CBR only in sw105–107
(IDR: 0/0/0; P: 0x1f3ec/0/0x411aa — no fixed target, only a cap) and the QP block (VBR P uses QP32).
The known CBR cluster sw7/37/105–107/125–132 is confirmed; sw172/173/245/246/6/22 are the additions.
Public Hantro naming: sw6 bit0 ≈ `HWIF_ENC_RC_ENABLE`-class, sw22 bits ≈ picture/row-RC enables,
sw245/246 ≈ ctbRc "bits per CTB / row" coefficients (ctbRcVersion=1 fuse) — offered as reading, not proof.

## E4 — single-knob sweep from the 1080p CBR-8000/fps60/gop30/Main/5.1 baseline (`E4/knobs.txt`)

33 runs; `base` vs `base_rep` identical in all 511 registers (zero run-to-run noise on the static card).
Knob → register map (all 511 registers considered; 464 never move; `*` = generator-`opaque`):

| knob | registers moved (IDR / P) |
|---|---|
| profile 9 (Baseline → CAVLC) | sw193 bit0 cleared (0x10011d→0x10011c; P 0x200119→0x200118)* — **sw193[0] = CABAC enable**; + P RC state |
| profile 11 (High) | sw193 bit1 set (→0x10011f / 0x20011b)* — **sw193[1] = 8x8 transform**; sw9 (SPS 1 B longer); + P RC state |
| entropy | no separate knob in the SDK: entropy follows profile (SPS/PPS parse confirms CAVLC only for Baseline) |
| level 3.1/4.0/4.2 | **nothing** (SPS only) |
| gop 1/8/60/120 | sw105–107 only (gop1: no P frames, IDR target 133333) |
| fps 30 (src=dst) and fps60→dst30 | sw7 hi = pic_init_qp 26 (frame QP stays 32: 0x68002000), sw105–107 (2880000), sw9 (SPS timing); dst30 drops every other input frame |
| bitrate 2000 / 16000 | 2000: QP block at IDR QP 37 (init 36); 16000: pic_init 26 but IDR QP 32 (same QP block as base); + sw105–107 + P sw243/244/247 |
| qpMin/Max 20..40 | sw172/173 only* |
| qpMin=qpMax=30 | sw172/173 + the QP block at 30 |
| intraQpDelta −5 / +5 | QP block: IDR slice QP 30 / 40 (sw7 0x80001e00 / 0x80002800; bitstream-confirmed; note +5 lands at 40, not 37), first P 33 / 39; sw105–107; P sw243/244/247 |
| firstFrameStartQp 30 | pic_init_qp 30 (sw7 hi) but IDR slice QP 27 (sw7 0x78001b00), P 30; QP block at 27 |
| idrQpDeltaRange 8 | sw173 bit3* (0x662→0x668) + P QP block |
| slice split 8 / 1 MB-rows | **sw1 0x9fd→0x209fd*, sw6 3→0x10000003 / 0x2000003*** (sw6[31:16] = MB rows per slice: 8 / 1... encoded 0x1000/0x0200 = rows<<9) |
| bRefRingbuf | sw56/57/73/83 (ring-buffer sizes/base) + sw195 bit1* |
| intra refresh row/col, deBreath, sceneChangeDetect, rowQpDelta, statTime, minIprop/maxIprop (I target only), bRcnRefShareBuf, deBreathQpDelta, re-applying RcParam | **nothing** in the program (iprop → sw105–107 IDR only) |
| moving content | P sw105–107/243/244/247 only |

Deblocking: no H.264 deblocking knob exists in the SDK (only JPEG `bDblkEnable`); PPS carries
`deblocking_filter_control_present=1`, slices `disable_deblocking_filter_idc=0` in every run.
**Secondary-bank pokes (cmdbuf words 516..549: WREG 0x2800=0x44 + 16× WREG 0x2014+i·0x20 = 0) are
byte-identical in all 214 programs of the campaign** (every geometry, RC mode, QP, knob).
Opaque registers that never moved under any knob/mode/QP/geometry: sw3 4 22† 26 35 36 38‡ 39 40 41 45 81
134‡ 136 170 171 182 194 196 201 203 224 225 245† 246† 248–259 272 277 281 288 289 307 319 320 349 430
(†moves with RC mode only, ‡geometry law). Opaque registers that DO move: sw1, sw6 (slices), sw172/173
(QP range), sw193 (entropy/8x8), sw195 (ring buffer), sw247 (RC state).

## E5 — live encoder-core register window (`E5/`, `E5b/`, `E5b/live_vs_program.txt`)

`regpoll2.c` mmaps 0x04010000 (VCMD base, from docs) read-only and polls +0x1000+0x140 until it is not
0xdeadbeef while `vdrive` encodes a moving 1080p card (900 frames) in the background.
Idle: VCMD engine words 0x00..0x1c and the core window all read 0xdeadbeef (clock-gated), confirmed twice.
Live (first non-gated poll, full 512 words in `E5b/live512.bin`, 32 further samples in `.samples`):
**sw80 = 0x88da4280, sw214 = 0x48500800, sw226 = 0x00a19200, sw287 = 0x00000000 — read LIVE from
MMIO, identical to the DRAM-mirror values of docs §8.5.** That closes the "strict proof would be a live
read" caveat: H264=1, HEVC=1, JPEG=0, ctbRcVersion=1 (sw226 byte2 = 0xa1 → the ctbRc field), sw214 hi16
0x4850 (maxEncodedWidth candidate; unit still ambiguous per the public header: 18512 px or 2314·8).
Raw 0x1000..0x1200 dump: `E5/regs.bin` (128 words, hexdump in `E5/e56.txt`).
Bonus: sw509/510/511 read 0x2114 / 0x9b83c / **0x20230307** (a date-coded HW build ID), and a set of
registers is write-only (reads 0: sw39–41, 125–132, 201, 203, 236, 237, 250/251, 272, 281, 289, 307, 349)
while sw215–223 (lambda LUTs), sw243/244/247, sw105–107, sw111–113, sw183–185, sw78/79 are HW-updated
per frame (they vary across the 32 samples) — the program values for those are inputs the HW overwrites.

## E6 — CBR trajectory with a MOVING card, 90 frames, gop 30 (`E6/traj*_trajectory.csv`)

Per-frame bytes + bitstream slice QP:
- 2000 kbps: I at 0/30/60; QP climbs 37→51 within the first GOP and stays pinned at 49–51 (alternating
  ~9.5 KB / ~2.3 KB P frames); achieved 3266 kbps — the moving synthetic card is not encodable at 2 Mbps
  at QP≤51, so RC saturates.
- 8000 kbps: IDR QP32, P QP 35→25 over the GOP (7337 kbps achieved).
- 16000 kbps: QP descends 35→21 and holds at 21; only 8196 kbps achieved (content-limited).
The QP step is at most ±1–2 per frame. Later IDRs (frames 30/60) get QP 30 then 28 at BOTH 8000 and
16000 kbps (identical trajectories for the first 4 frames and all I frames), and 37 at 2000 kbps — the
I-frame QP is not derived from the running P QP (which was 26/19 vs 21/19, and 51 at 2 Mbps).

## Not done / caveats

- QVBR/QPMAP modes: refused (0x8007020a) with header-minimal attrs; no programs.
- `u32StartQp/u32MeanQp` in `AX_VENC_STREAM_T` are 0 on this SDK — QPs come from the bitstream.
- The TARGETPICSIZE(bitrate,fps,gop) closed form is not fitted here (points listed above).
- The bitstreams are synthetic-card content only; no HDMI content was captured.
