# HEVC on the open VC8000E encoder — capture plan + implementation outline

> **Status 2026-09-05: the capture campaign (H0–H9) is DONE and banked in
> `vendor-diff-hevc-20260905/` (`REPORT.md` is authoritative).** It ran on the
> shipped open image with the vendor stack loaded at runtime from `.#ax-ko-blobs`
> + `.#axera-libs` + the stock-rootfs `libax_venc.so` — no `.axp` reflash was
> needed (recipe: `.claude/skills/device-re-subagent/SKILL.md`, "Vendor stack on
> a purged device"). The H1 gate passed. **Steps 0+1 of the outline are DONE
> the same day:** the open builder carries the HEVC overlay
> (`vcenc_encode.h` `ENC_CODEC_HEVC`), `vcenc_hevc_header.h` writes VPS/SPS/PPS
> byte-identical to the vendor's, 34 vendor HEVC programs are golden vectors,
> and blob-free IPPP HEVC is device-proven at 1080p…3840×2400
> (docs/blob-replacement.md, "2026-09-05 (later)"). Open: the `PT_H265` /
> libkvm dispatch and the web-path proof.

Plan of record for adding H.265/HEVC to the open encoder (Gitea issue filed
2026-09-05). The silicon supports it (fuse `HEVC=1`, live-read 2026-09-04) and
the VCMD engine, cmdbuf structure, EWL/CMM/DPB machinery and geometry framework
are all shared with the shipped H.264 path. What is missing is the HEVC-specific
register program, the VPS/SPS/PPS writer, and the libkvm/ABI dispatch.

The method mirrors the 2026-09-04 H.264 vendor differential
(`docs/reference/vcenc-open/vendor-diff-20260904/`): drive the vendor encoder
through its **public MPI**, decode the cmdbuf programs from our own `/dev/mem`
reads, write the open implementation from that observation and the public
ITU-T H.265 spec. No vendor binary is read (clean-room rule, CLAUDE.md).

**Sequencing.** The capture step needs the vendor stack. It was assumed to need
a vendor `.axp` reflash after the #54/alpha.4 flash; in practice the vendor
modules and libraries are Nix inputs of this repo and can be loaded on the
running open image for one session (done 2026-09-05). The vendor stack still
disappears entirely at the mainline move (#26), so the evidence was banked
first. The rest of this file is the campaign brief as run and the
implementation outline that follows now that the evidence is banked.

## Facts that shaped the plan

1. **The vendor SDK exposes few HEVC knobs.** `ax_venc_comm.h` / `ax_venc_rc.h`
   (`.#axera-libs`): `PT_H265 = 265`; profiles Main (0) / MainStillPicture (1) /
   Main10 (2) / MainRExt (3); `enTier` 0/1; `enLevel` = level×30; the H265 RC
   structs are typedef aliases of the H264 ones; `AX_VENC_RC_MODE_H265{CBR,VBR,
   AVBR,QVBR,CVBR,FIXQP,QPMAP}`; `AX_VENC_ATTR_H265_T{bRcnRefShareBuf}`; slice
   split by `u32LcuLineNum`; GOP modes `NORMALP/ONELTR/SVC_T`; min width 136
   (vs 144 for H264). **No SAO / CTU-size / TU / AMP / transform-skip /
   deblocking knob exists** — those come from vendor defaults, pinned via the
   emitted VPS/SPS/PPS.
2. **H.265 is disabled at the app layer, not the SDK.** Upstream
   `server/common/kvm_vision.go` defines `ReadH265` but nothing calls it; the
   WebRTC client registers `MimeTypeH264` only; `direct.worker.ts` hardcodes
   `avc1.42E01F`. The 2026-07 recon saw H264+H265 channels live on app v1.2.15,
   so the MPI accepted `PT_H265` then. Whether the *current* SDK build still
   does is campaign gate **H1** — if `CreateChn(PT_H265)` is refused, record the
   code and stop; a spec-only HEVC program is not worth attempting blind.
3. **Our libkvm folds every non-MJPEG type into H.264** (`libkvm.c` `want_type
   = (_type == IMG_MJPEG_TYPE) ? 0 : 1`; `kvm_venc_open.c` accepts only
   `PT_MJPEG`/`PT_H264`). The `IMG_H265_*` constants in `kvm_vision.h` are the
   only H.265 plumbing that exists today.

---

## Campaign brief — vendor HEVC differential (for a future Fable device subagent)

Run when the unit has been reflashed to the vendor `.axp`. Mirrors
`vendor-diff-20260904/` (E1–E6). Launch per `.claude/skills/device-re-subagent`:
`Agent`, `subagent_type: general-purpose`, `model: fable`; resume with
`SendMessage` between phases.

### 1. Context + established facts (do not re-derive)

Open-source driver-replacement / hardware-interoperability work in the lineage
of Asahi Linux, nouveau, OpenIPC and Mesa: the device owner has authorized
reimplementing the NanoKVM-Pro (AX630C) video stack from source to drop
proprietary blobs. We ship a from-scratch open H.264 encoder for the
VeriSilicon VC8000E (Hantro VCMD ABI) built from our own on-device observation.
This campaign measures the vendor encoder's **HEVC** behaviour through its
**public MPI** so the open encoder can add HEVC the same way.

Read in full first: `docs/blob-replacement.md` (stages 2026-08-22 §8.5,
Stage 0, 2026-08-29 fixed-QP, 2026-08-31 #17, **2026-09-04 vendor differential
campaign**), `docs/reference/vcenc-open/vendor-diff-20260904/{README,REPORT}.md`,
`E4/knobs.txt`, `E5b/live_vs_program.txt`, `tools/{vdrive.c,cmdpool_decode.py,
decode_run.py,e3_analyze.py,h264parse.py}`, and `pkgs/vcenc-ewl/{vcenc_geom.h,
vcenc_encode.h,vcenc_qp.h}`.

Known (H.264, shared machinery):
- VCMD `hw_version_id 0x43421500`; fuse (live MMIO, E5) `sw80=0x88da4280`
  H264=1 **HEVC=1** JPEG=0, `sw226` ctbRcVersion=1. MMU off: cmdbufs carry raw
  phys.
- Cmdbuf shape (`vcenc_encode.h` header comment): `RREG(1,0x68)` →
  `WREG(511,0x1004)` bulk swreg1..511 → `WREG 0x2800=0x44` + 16×
  `WREG 0x2014+i·0x20 = 0` → `WREG 0x1014 = sw5|1` kick → STALL →
  `RREG(512,0x1000)` → CLRINT×2 → tail. 570 words. Secondary-bank block
  byte-identical across all 214 H.264 programs.
- Slot ID: fresh IDR = slot 1, fresh P = slot 2 of `venc_ko` pool 0 (pre/post
  diff); register-image mirrors carry per-frame `sw9` bytes / `sw82` cycles.
- Geometry laws (MB-based, exact at 26 geometries): `vcenc_geom.h` header. Frame
  type `sw5` low byte, `sw191`, `sw11`/`sw192` frame_num/POC, DPB ping-pong
  sw15/16↔18/19, 60/62↔64/66, 72↔74, sw114 alternate, sw239/241 swap.
- QP block: `sw7=(init<<26)|(qp<<8)`, `sw37` λ pair, `sw125–132 = F(q−2k)`
  clamped 35(I)/32(P) — E2. RC-enable set: `sw6[0]`, `sw22[3:2]`, `sw105–107`,
  `sw172/173`, `sw245/246`, `sw239/241` — E1. Knob map: E4. Write-only /
  HW-updated register classes: E5b.
- SDK HEVC surface: see "Facts" above. Gate: `AX_VENC_CreateChn(PT_H265)` must
  return 0; if refused, report the code and stop after H0.

### 2. Deliverables

A tree `docs/reference/vcenc-open/vendor-diff-hevc-<date>/` in the scratchpad,
ready for the main session to commit: `README.md` (provenance), `REPORT.md`
(every law/number/caveat — the 2026-09-04 REPORT.md is the template), `tools/`,
and `H0…H9/` with decoded programs in geom-probe format
(`vendor_<tag>_{IDR,P}.txt`, `swregN 0x........`), per-run `.log`, the analysis
outputs below, and raw `cmdpool_*.bin` for H2 only. Not committed: `.h265`
bitstreams (extract facts into logs), non-H2 pool dumps, mirror dumps
(transcribe sw9/sw82). Report back structured; do NOT edit repo docs or commit;
give exact on-device and scratchpad paths.

### 3. Runs

Baseline unless stated: 1920×1080, `PT_H265`, Main profile, Main tier, level
153, CBR 8000 kbps, fps 60, gop 30, `NORMALP`, static card, 6 frames, snapshot
IDR + first P. H.264 base to diff against: `E4/vendor_base_{IDR,P}.txt`.

- **H0 control** — H.264 1080p CBR base (unchanged `vdrive`); must reproduce the
  committed vendor program bar the 16 address regs. A non-address diff means a
  different vendor SDK build — report before proceeding.
- **H1 codec differential (GATE)** — HEVC base + `base_rep`. Full opcode listing
  of the slot plus swreg diff vs H.264 base (IDR and P); parse VPS/SPS/PPS/slice
  (`h265parse.py`). Expect the opcode structure, secondary-bank pokes, RREG
  readback and kick register identical; a codec-mode field plus geometry regs
  (CTU vs MB) move. Any WREG outside `0x1000..0x17fc`, any cmdbuf-length change,
  or a register above sw320 going nonzero is a surprise — flag it. `base` vs
  `base_rep` must be identical.
- **H2 geometry sweep** — HEVC at ≥26 geometries: the E3 nine (incl. 3840×2160,
  3840×2400), the #17 seventeen, plus CTU-edge cases 136×136, 200×136, 1920×1088,
  1984×1080 (31 CTU exact), 2000×1080 (31 CTU + 16). Keep raw IDR/P pools. Fit
  closed forms for every geometry-varying register and the buffer pitches;
  compare which H.264 laws survive and which become CTU-based.
- **H3 fixed-QP ladder** — `H265FIXQP`, QP {16,20,24,28,32,36,40,44,48,51} +
  I28/P34, `snapall`. Decide whether the F/L QP tables and the 35/32 clamp are
  the H.264 ones (reuse `vcenc_qp_tables.h`) or an HEVC set.
- **H4 RC-mode differential** — H265 CBR/VBR/AVBR/CVBR/FIXQP/QVBR/QPMAP at 8000.
  Expect the E1 RC-enable set identical, CBR≡CVBR, VBR≡AVBR, QVBR/QPMAP refused.
- **H5 knob sweep** — profile 1/2/3 (Main10 may refuse 8-bit YUYV — record),
  tier 1, levels, gop 1/8/60/120, fps, bitrate 2000/16000, qp ranges, iqd±5,
  firstqp, idrrange, slice `u32LcuLineNum`, intra-refresh, refring, share,
  debreath, scd, rowqpd, stattime, iprop, VUI, GOP modes ONELTR and SVC_T (a
  refusal is a valid result). Build the knob→register map; flag surprises vs
  E4.
- **H6 DPB/RPS ring** — HEVC gop 30×14, gop 8×20 (two IDRs, wrap), ONELTR gop
  30×20, all `snapall`. Per-frame register table correlated with parsed slice
  headers (POC lsb, short-term RPS, `num_ref_idx`, TMVP) and NAL types. The
  point: find whether/where an RPS descriptor cluster exists and how IDR (no
  reference) and gop-wrap are programmed.
- **H7 live core window** — `regpoll2` during a 900-frame moving encode; classify
  write-only vs HW-updated registers for HEVC; confirm the fuse words.
- **H8 CBR trajectories** — moving card, 90 frames, gop 30, at 2000/8000/16000
  kbps; the HEVC bits/QP curve is #46's validation data.
- **H9 conformance** — decode one `.h265` from H1/H3/H2/H6 with ffmpeg; record
  dims/profile/level/frame-count and zero decode errors. A broken decode at a
  partial-CTU geometry is a finding.

### 4. Methods and tooling

Vendor MPI only (`AX_SYS_Init`, `AX_VENC_*`, `AX_POOL_*`), synthetic YUYV card in
a real `AX_POOL` block — never a captured host-screen pixel. `/dev/mem`
read-only for the `venc_ko` pools (`/proc/ax_proc/mem_cmm_info`) and the core
window `0x04010000+0x1000`; word loops, never `memcpy`, on Device memory.
`vdrive.c` gains `codec=h264|h265` (`enType = PT_H265`, default profile 0 /
level 153), a `tier=` arg, and the H265 RC enum selection (union members alias,
so the field writes are unchanged); `decode_run.py`'s slot finder must learn the
HEVC type/geometry signatures from H1 (the H.264 signatures do not apply);
`cmdpool_decode.py` gains a full opcode listing so H1 diffs structure, not only
values; new `h265parse.py` parses VPS/SPS/PPS/slice from ITU-T H.265 §7.3.
Build: the vendor rootfs likely has python3 but maybe not gcc — cross-build
`vdrive`/`regpoll2` on the host against `.#axera-libs`, decode on the host.
Sequence H0 → H1 (gate) → H2 (scripted) → H3/H4/H5/H6/H8 → H7; persist every
raw dump on-device before retrieving; verify by size.

### 5. Safety envelope

Use the standard device-re-subagent envelope verbatim from
`.claude/skills/device-re-subagent/SKILL.md` (health check first; `/tmp/axwork`
tmpfs; persist-then-retrieve; read-only default with the public-ABI drive path
allowed; no `/dev/mem` register writes, no block-device writes; a hang is a safe
warm watchdog reboot, poll and continue, never a cold cycle; `kvmssh` flakes,
verify via uptime; never print/commit IPs or passwords). **This campaign runs on
a vendor-`.axp` unit, not the hot-patched one:** the reflash and the return to
the open image are Jeremy's (never touch `mmcblk0`); the encoder is held by the
vendor NanoKVM server, not `nanokvm.service` — find that unit
(`fuser -v /dev/ax_venc`), stop it for the runs, restart it and confirm the
vendor web UI answers 200 at the end.

### 6. Content-filter framing

Frame the work as open-source driver-replacement / hardware interoperability in
the lineage of Asahi Linux, nouveau, OpenIPC and Mesa — reimplementing a
device's own stack from source to drop proprietary blobs on hardware the owner
controls and authorized. No vendor binary is read; everything is observable
behaviour through a published API plus our own tooling.

---

## Implementation outline (after the differential is banked)

**Step 0 — replay-and-verify (days).** Add `img_hevc_qp32_payload.h` (the decoded
vendor 1080p HEVC IDR from H1, swreg1..511 — our observation, same provenance as
`img_qp32_payload.h`) and a P overlay from H6, and drive it through the **open**
stack with the standalone prover (`pkgs/vcenc-ewl/ewl_encode.c`), relocating the
16 address registers as `vcenc_build_encode_cmdbuf` does, prepending the
vendor-observed VPS/SPS/PPS for this first decode only. Milestone: ffmpeg decodes
an IPPP HEVC stream at 1080p through `ax630c_venc_vcmd.ko`. This proves the
shared machinery carries HEVC before any generalisation.

**`pkgs/vcenc-ewl/`.**
- `vcenc_encode.h`: a `codec` field in `struct vcenc_frame` selecting the payload
  table and the frame-type constants (the H.264 `sw5|0x02`/`sw191`/`sw193`/
  `sw17`/`sw170/171/173` set becomes per-codec; HEVC values from H1/H6). Codec
  mode bit(s) and POC/RPS registers: from H1/H6. Single-reference IPPP keeps the
  RPS trivial (one negative picture, delta −1, used).
- `vcenc_geom.h`: an HEVC branch with CTU-based laws for the registers H2 shows
  moving, refitted recon/aux pitches, and `sw9` with the HEVC header length.
  Decide the 136×136 (vendor min) vs 64×64 envelope. `tests/gen_vectors.py` gains
  the H2 programs; `vcenc_geom_test.c` pins HEVC golden vectors (≥26 geometries).
- `vcenc_qp.h`: reuse the tables if H3 shows them identical, else add
  `VCENC_F_*_HEVC`. Reuse `ENC_RC_FIXQP` if H4 confirms the E1 set.
- **`vcenc_hevc_header.h`** (new): VPS+SPS+PPS Annex-B writer from ITU-T H.265
  §7.3.2, reusing the existing `bitw`/`bw_ue` helpers. Every field the
  hardware-written slice header depends on (CTU/TU sizes, SAO, AMP,
  `log2_max_pic_order_cnt_lsb`, RPS count, `init_qp`+`slice_qp_delta`,
  `cu_qp_delta`, deblocking, `log2_parallel_merge_level`) is pinned from the
  H1/H5 parses. Profile/tier/level from geometry via an HEVC level table.

**`kvm_venc_open.c` / `libkvm.c`.** Accept `PT_H265` (geometry via the HEVC
branch, session `codec`, per-IDR pack = VPS+SPS+PPS+slice with the `enH265EType`
NAL types). `libkvm.c`: `want_type` becomes three-valued (`_type` 5..8 →
H.265), a third channel id, `next_from_pending` maps `enH265EType` →
`IMG_H265_TYPE_{SPS,PPS,IF,PF}` (VPS rides the SPS slot — decide whether
`kvmv_get_sps_frame` returns VPS+SPS concatenated).

**Server/ABI.** `IMG_H265_*` and `ReadH265` exist upstream but nothing consumes
them (no H.265 streamer, pion H264-only, `direct.worker.ts` hardcodes `avc1`).
Browser delivery (pion `MimeTypeH265`, `hvc1` WebCodecs, the vendor's UI patent
gating) is a **separate issue**; this work ends at a decodable `.h265` served
through `IMG_H265_*`, validated with a bench reader + ffmpeg.

**Hard parts / open questions.** (1) RPS/DPB signalling — which registers, from
H6; IPPP keeps it minimal. (2) CTU geometry laws and re-proven floorplan bounds
(the sw114 under-allocation lesson from E3). (3) HEVC constants without knobs
(SAO/TU/AMP) — template constants pinned by header parse; fine for a fixed
config, not tunable. (4) QP tables — identical or a second set. (5) Rate control
rides on #46. (6) Gate risk — if `CreateChn(PT_H265)` is refused there is no
oracle; do not attempt a spec-only program blind.

**Effort / confidence.** Campaign: one device session. Replay PoC + header writer
+ libkvm plumbing: ~1 week. Geometry fit + golden vectors: 2–3 days. Device proof
at 1080p and 4K: 1–2 days. **GO conditional on H1, medium-high** — every
non-HEVC-specific piece is already shipped and proven; the unknowns are all
observable in the single campaign.
