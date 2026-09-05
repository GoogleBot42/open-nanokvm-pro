# Vendor rate controller on real HDMI content — 2026-09-05 (#46 oracle)

Device: NanoKVM-Pro (AX630C), shipped open image v2.1.0-alpha.4, vendor encoder stack put back at
runtime for one session (method, provenance and the exact matrix: `README.md`). Content: the real
1080p desktop the bench source shows (a static KDE settings window, captured through the open V4L2
driver, 30 byte-identical frames), fed to `AX_VENC_SendFrame` as recorded (R4) or with **labelled
software motion** — a 4 px/frame vertical scroll (R1/R2/R3/R5) or a half-screen jump every frame /
every 15 frames (R6/R7). USB HID to the host was down (host link suspended), so no real motion was
possible; see README. 1920×1080, fps 60, gop 30, StatTime 1 s, qp range 10..51. 51 runs, 11 400
frames, every frame with its cmdbuf program; every `sw7` frame QP equals the bitstream slice QP.

Per-run data: `R*/<tag>_trajectory.csv` (+ `_summary.txt`); `aggregate.md` (one row per run: achieved
kbps, I QPs, first-P QPs, kbps per GOP, P range, P-step histogram); `fits.txt` (I-QP and P-step tables
per run, produced by `tools/rc_fit.py`). Every number below is in one of those files.

## 1. Where the controller actually operates on a KVM desktop

| content (CBR, both codecs) | 2000 | 8000 | 16000 |
|---|---|---|---|
| static desktop (R4) H.264 / HEVC | 1996 / **414** | 2606 / 1754 | 2607 / 1742 |
| 4 px scroll (R1) H.264 / HEVC | 2004 / **436** | 2780 / 1996 | 2781 / 1991 |
| H/2 jump every 15 frames (R6) H.264 / HEVC | 2027 / **514** | 3755 / 3007 | 3661 / 2957 |
| H/2 jump every frame (R6) H.264 / HEVC | 2646 / 2197 | 8193 / 8223 | 16214 / 16262 |

A static or smoothly scrolling 1080p desktop cannot absorb 8 Mbps at any QP ≥ 10: at 8000 and 16000
the controller is **content-limited** and runs an identical open-loop descent (QP 35 → I−11, I QP −2
per GOP, §3), so those rows are the same trajectory to the frame (`R1/h264_cbr8000` vs `_cbr16000`:
same I QPs, same first-P QPs, same step histogram). The in-band regime — where QP moves both ways
around a target — is 2000 kbps on scroll/static (H.264 only, §6) and 8000/16000 on the jump stimulus.
The static P frame of this desktop costs a constant **1890 B at QP 21** (H.264, `R4/h264_static8000`
frames 17–29) — skip frames are not free.

## 2. Initial QP and first-P offset (real content = synthetic; E4/H5 confirmed)

| target kbps | H.264 CBR IDR / first P | HEVC CBR IDR / first P | VBR IDR / first P (both) |
|---|---|---|---|
| 1000 | 37 / 40 (R7) | 35 / 38 — no-target mode (R7) | — |
| 2000 | 37 / 40 | 35 / 38 — no-target mode | 36 / 36 |
| 3000 | 37 / 40 (R7) | 35 / 38 — no-target mode (R7) | — |
| 7500 | — | 32 / 35 (R7) | — |
| 8000 | 32 / 35 | 32 / 35 | 32 / 32 |
| 16000 | 32 / 35 | 32 / 35 | 26 / 26 |

**CBR: first P = IDR QP + 3 on every GOP of every CBR run** (8–9 GOPs × 32 runs, both codecs, in band,
under and over target — `I->firstP QP delta` lines). **VBR: first P = IDR QP** (GOP 0) and IDR −1..0
afterwards. The IDR program itself is content-independent: the real-frame IDR program equals the E4
synthetic base in all 511 non-address registers (`smoke/`).

## 3. Per-frame P-QP update law (CBR)

Define r = bits(i−1)·8 / sw105(i−1): the previous frame's size against the target the vendor
programmed for it. From `fits.txt` (`P-step rule` tables):

| r (previous frame vs its target) | ΔQP(i) | evidence |
|---|---|---|
| [0.95, 1.05) | **0** | 82/89 (R1 h264 2000), 15/18, 35/35 (R6 jump1 8000 h264/h265), 20/40 (jump1 16000: 19 were +1) |
| [1.05, 1.30) | **+1**, sometimes +2 | R1 2000: +1:41 +2:5; jump1 16000: +1:66; jump1 8000 h264: +1:64 +2:41 |
| ≥ 1.30 | +1 / +2 | jump1 8000: +1:6; R1 2000: +2:2 |
| [0.85, 0.95) | **−1**, sometimes −2 | R1 2000: −1:41 −2:1; jump1 16000: −1:86; jump1 8000 h264: −1:42 −2:16 |
| < 0.85, in band | **−2** | jump1 8000 h264: −2:37/37 at [0.70,0.85); HEVC −2:15/15 |
| ≪ 1 (content-limited, r ≈ 0.05–0.5) | **−1 per frame** | every 8000/16000 scroll/static run: 35 → 21 in frames 1–14, then hold |

So: dead band ±5 %, unit steps, |ΔQP| ≤ 2, and the −2 step is taken only when the controller is in
band and the miss is > 15 %; in deep undershoot the descent is throttled to −1/frame. Whether a ±1 or
±2 is taken in the 5–30 % bands is **not** a function of r alone (the 16000 and 8000 jump runs differ
in the same bin) — the per-frame RC state words `sw243/244/247` are in every CSV for whoever fits
that; the trajectories themselves are the oracle.

**Bounds inside a GOP.** P QP never goes below **IDR QP − 11** (floor hit and held in every
content-limited GOP: `I32/min21 I30/min19 … I20/min10 I18/min10`, `R4/h264_static8000`; same in HEVC,
R1, R5, R6-jump15) until `minQp` = 10 takes over. Over target, P QP saturates at **51 in the first GOP
and at 46 from the second GOP on** (`R6/h264_jump1_cbr2000`, `R1/h265_cbr2000`, `R4/h265_static2000`:
per-GOP max 51 46 46 46 46 46 46 46) — the same 51→46 pattern is in the synthetic E6/H8 2000-kbps
CSVs.

## 4. IDR QP rule

- **Under target** (the KVM common case): IDR QP drops **exactly 2 per GOP** — 32 30 28 26 24 22 20
  18 (16) — in all 14 content-limited CBR runs of both codecs (R1/R4/R5/R6-jump15 at 8000/16000),
  regardless of how far under (achieved/target 0.24–0.47).
- **In band**: IDR QP settles at **mean P QP of the previous GOP − 4** (`R6/h264_jump1_cbr8000`:
  meanP 36.0 35.1 34.8 35.2 34.6 35.3 34.8 → IDR 32 32 31 31 31 31 31, exact for 7/7 GOPs; HEVC 8000:
  −3…−5). The −2/GOP descent is also what brings it there (jump1 16000: 32 30 28 25 23 21 21 22 while
  meanP ≈ 25).
- **Over target**: IDR QP **never rises above its initial value** (`R6/h264_jump1_cbr2000`: 37 × 8
  GOPs at 1.3× the target; HEVC 2000: 35, 36 × 7).
- In the 2000-kbps in-band scroll run the per-GOP change was −2 −2 −2 −3 0 −3 −1 (37 → 24 while the
  achieved rate alternated 0.88/1.11 of target GOP by GOP, `fits.txt` first table) — the descent is
  driven by the I-frame's own bit result (22 KB vs a 440 000-bit target), not by the P QPs.

## 5. Targets: the StatTime window (`sw105–107`)

- `StatTime = 1 s` = 60 frames = **two GOPs**; every per-GOP pattern below repeats with period 2 GOPs
  (`fits.txt`, `P target sw105 per GOP`).
- **First IDR target = 0.22 × bitrate × 1 s** in bits: 220 000 @1000, 440 000 @2000, 660 000 @3000,
  1 760 000 @8000, 3 520 000 @16000 (H.264) and 1 650 000 @7500 (HEVC) — E4's "1760000 = 8 Mbps ×
  0.22 s" holds at every bitrate. Later IDR targets adapt to the observed I/P cost ratio: 0.15× when
  P frames are expensive (jump1 at 1000/3000), 0.29× (579 710) when they are cheap (scroll at 2000),
  up to 2 550 724 = 0.32× when the window is under-spent (8000 scroll) — i.e. within the
  `u32MinIprop/u32MaxIprop` 10..40 % defaults.
- **P target**: the first P of a window gets ≈ 0.95 × bits/frame (127 433 @8000, 25 752 @2000); it is
  then re-planned every frame from the window balance — it grows while the window under-spends and the
  **last frame of the window absorbs the whole remainder** (4 895 192 bits at frame 59 of
  `R1/h264_cbr8000`; 41 635 at frame 59 of the in-band 2000 run vs 33 333 bits/frame). This is what
  makes the −2/GOP IDR descent and the −1/frame P descent open-loop: the target runs away from what the
  content can spend.
- `sw106 / sw107` = per-frame lower / upper bit bounds, either the tight pair **0.95× / 1.05×** or the
  wide pair **0.30× / 2.00×** of `sw105` (both codecs; in the jump runs always the wide pair). VBR
  programs `sw106 = 0` and `sw107 = 2 × bits/frame` (0x411aa = 266 666 @8000, 0xfc68 ≈ 64 616 @2000)
  and **no IDR target at all** (`sw105–107 = 0` on every VBR IDR).
- `sw172/173` never move (0x14f / 0x662 on IDR, 0x66a on P = minQp 10, maxQp 51, the E1 bits);
  `sw6` = 0x3 (H.264) / 0x20000b–0x200003 (HEVC), `sw22` = 0xc throughout — RC enabled in every
  CBR/VBR program, **including the HEVC no-target programs**.

## 6. HEVC CBR below ≈ 7.25 Mbps is not a rate controller (R1/R4/R6/R7)

With `u32BitRate` ≤ 7000 kbps at 1080p60 the HEVC CBR program carries **`sw105 = sw106 = sw107 = 0`
on every frame**, the IDR QP freezes at 36 (35 on the first), the first P is IDR+1 (+3 only in GOP 0)
and P QP ramps **+1 per frame** to the ceiling (51 in GOP 0, then 46) whatever the bits — the rate is
whatever the content costs at QP 46: 414–436 kbps static/scroll, 514 kbps jump15, and **2101 kbps at
3000, 4000, 6000 and 7000 alike** on jump1 (R7). At 7500 kbps the target appears (1 650 000 IDR,
119 439 first P) and the run lands at 7532 kbps; at 8000 HEVC tracks like H.264 (8223 kbps in band).
Threshold 7000 < br ≤ 7500 kbps ↔ **≈ 0.0563–0.0603 bit/pixel/frame**, consistent with H2 (at 8000 kbps
every geometry ≥ 1920×1200, i.e. ≤ 0.0579 bpp, programmed `sw105–107 = 0`). H.264 has no such gate:
1000 kbps (0.008 bpp) still gets a target and tracks. HEVC VBR is unaffected (2000 → 1802 kbps, R2).
This is H8's "HEVC under-shoots at 2000" explained: a defect, and the open controller must not copy
it — HEVC at KVM bitrates needs the H.264 law.

## 7. Mid-stream target change through the public API (R3)

`AX_VENC_GetRcParam` → `u32BitRate`/`u32MaxBitRate` → `AX_VENC_SetRcParam`, rc = 0, read-back
confirms (`chg frame=… readback=` lines in the logs). Observed:

- **Latency: the next frame.** The new target is in the very next program: `R3/h264_chgmid`
  `sw105` 142 804 → 36 332 at frame 75 (8000 → 2000) and 36 120 → 288 426 at frame 165 (2000 →
  16000, a catch-up value 2.2× bits/frame); IDR-aligned changes likewise (`h264_chg` IDR target
  579 710 at frame 60, 4 637 681 at frame 120).
- **QP response, downward (more bits available): −1 per frame from the current QP, no jump** —
  frame 165: 30 30 29 28 27 26 25 24 23 22 21 21 (`h264_chgmid`), then the I−11 floor. Same in HEVC
  (`h265_chgmid` from 46: 46 45 44 43 42 41 40 39 38 …).
- **QP response, upward (fewer bits): +1 per frame** where the content demands it (`h265_chgmid`
  frame 75: 17 18 19 20 … 27 — the HEVC no-target ramp); in `h264_chgmid` the QP did not move at all
  after the 8000 → 2000 change at frame 75 because the scrolling desktop at QP 17 already fitted the
  new 36 kbit/frame target (3112 B = 24.9 kbit) — the controller only reacts to bits, never to the
  target value itself.
- **The first IDR after a change restarts at the new bitrate's initial QP**: 37 for → 2000 and 32
  for → 16000 in both codecs, GOP-aligned or mid-GOP (`h264_chg` IDR QPs 32 30 | 37 35 | 32 30 28 26
  24; `h264_chgmid` 32 30 28 | 37 35 32 | 32 30 28), then the §4 descent resumes. In VBR the first IDR
  after a change is **32** regardless of the new cap (`h264_chg_vbr`, `h265_chg_vbr`: 32 13 | 32 27 |
  32 12 10 10 10 — 32 for both → 2000 and → 16000, although a fresh VBR start at 2000/16000 uses 36/26).
- Segment rates (`aggregate.md` change views): H.264 8000 → 2000 held 2258 kbps over the 60-frame
  segment (the IDR at QP 37 costs 22 KB of a 1 Mbit half-window), → 16000 content-limited at 2842.

## 8. CBR vs VBR on real content (R2, R3)

VBR = the E1/H4 register difference (IDR `sw105–107 = 0`, P `sw106 = 0`, `sw107` = 2× bits/frame) and
a different QP policy: no IDR+3 offset; **QP descends −1/frame whenever the cap is not hit, all the way
to `minQp` 10** (8000 and 16000 reach 10 by frame 45 and stay there: 202–210 zero steps of 240);
**up-steps are +2** (2000 kbps: +2:44 H.264, +2:31 HEVC, no +1 at all); the IDR QP follows the running
P QP (13 after a GOP that ended at 10–12, 31 after one ending at 30). At the 2000 cap both codecs land
at 1802 kbps (0.90 × cap) — VBR keeps a 10 % margin; CBR H.264 at 2000 lands at 1996–2027.

## 9. H.264 vs HEVC

With a target present the RC is codec-agnostic to the frame: `R1/h264_cbr8000` and `R1/h265_cbr8000`
have identical IDR QPs, first-P QPs, P ranges and step histograms (−2:1 −1:106 +0:117), and the R6
jump1 runs at 8000/16000 match within a QP. HEVC spends 0.67–0.72× the H.264 bytes at the same QP
trajectory (1996 vs 2780 kbps scroll, 1754 vs 2606 static) and 0.8× at the same 51/46 saturation. The
one codec difference in the controller is the §6 gate.

## 10. Against the synthetic E6/H8 trajectories

- E6/H8 8000: "P 35 → 25 over the GOP, later IDRs 30 then 28" — the same −2/GOP IDR rule and the
  same −1/frame descent; the card just cost more per frame (stopped at 25 where the desktop reaches
  the I−11 floor at 21). Real content puts the 8000/16000 KVM case fully in the open-loop regime.
- E6 2000 (H.264, over target): pinned 49–51 in GOP 0, 46 after — identical ceiling behaviour to
  `R6/h264_jump1_cbr2000`; on the real scroll the same target is in band (2004 kbps).
- H8 2000 (HEVC): the undershoot is the §6 no-target mode, now bounded to br ≤ 7000 kbps at 1080p60.
- The initial QPs, IDR+3 offset, `sw105–107` values and the IDR program are identical on real and
  synthetic content — the card measured the right controller; only the operating point differed.

## Not done / caveats

- No real motion: HID to the host was down (USB link suspended); motion rows are real texture with
  synthetic translation/jumps, labelled. Real scrolling with new content entering the screen would sit
  between the scroll and jump15 rows.
- 4K native geometry: not applicable (source is 1080p).
- R5's content-phase boundaries (90/180) coincide with IDRs — no mid-GOP content-transition sample.
- The ±1 vs ±2 selection inside the 5–30 % bands, the exact P-target re-planning formula and the
  adaptive IDR share are recorded (per-frame `sw105–107`, `sw243/244/247`) but not fitted here.
- HEVC no-target threshold bracketed at 7000 < br ≤ 7500 kbps (1080p60), not bisected further.
- `u32StartQp/u32MeanQp` are 0 on this SDK (as E2); QPs come from the bitstream.
