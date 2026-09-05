# Vendor VC8000E rate-control oracle on REAL HDMI content (2026-09-05, #46)

Per-frame trajectories of the vendor encoder's rate controller — CBR, VBR and mid-stream target
changes, H.264 and HEVC — measured on the real desktop the bench source shows, through the vendor's
**public MPI**, on the shipped open image with the vendor stack put back at runtime. Closes the gap
left by `../vendor-diff-20260904/E6` and `../vendor-diff-hevc-20260905/H8`, which were synthetic-card
only. `REPORT.md` is the source of truth; this file is provenance + index.

## Method and provenance

Same posture as the rest of `vcenc-open/`: **our own observation of hardware we own, plus our own
tooling. No vendor binary was read, no vendor source consulted, no `/dev/mem` writes, no firmware or
block-device writes.** Device: NanoKVM-Pro (AX630C), kernel 4.19.125, open image v2.1.0-alpha.4 with
the H.265 libkvm hot-patch from the same day; uptime 9.5 h at the start, `nanokvm` active, web 200,
`ax630c_venc_vcmd` refcnt 0 (no phantom reference — no pre-swap reboot needed).

**Real frames.** With `nanokvm` and `nanokvm-display` stopped and the OPEN stack still loaded,
`tools/v4lrec.c` (plain V4L2 MMAP streaming on `/dev/video0`, driver `open_vin_capture`, S_FMT
1920×1080 YUYV → `bytesperline 3840`, `sizeimage 4147200`) recorded 30 frames after discarding 10 to
`/root/rc65/clips/static.yuyv` (124 416 000 B; sidecar `clips/static.yuyv.seq`). The LT6911 reported
1920×1080 @ 59 (59.94) Hz. **All 30 frames were byte-identical** (one MD5; 0 differing bytes between
frames 0 and 1) — the source is a static KDE *System Settings → Display Configuration* window
(luma 16..235, mean 47: a dark theme), and HDMI capture is digitally exact. The recorder dropped
frames (V4L2 sequence 10..82 over 30 frames: a 4 MB CPU copy per frame does not keep 60 fps), which
is irrelevant for identical frames. The encoding runs used `fps=60` (as E6/H8) rather than 59.94.

**Motion.** The plan was to move the host pointer through the KVM's own HID. That was impossible in
this session: the UDC read `state=default`, `link_state=Suspend`, the dwc3 interrupt counter was
frozen and a 4-byte write to `/dev/hidg1` blocked (`timeout` 124) — the host side of the USB link is
suspended (the #42 pattern; needs hands on the bench). So the motion rows use **labelled software
motion applied to the real frame inside `vdrive`**: `motion=vscroll mstep=4` (whole-frame vertical
wrap-around scroll, 4 px/frame — the smooth-scroll case, perfectly motion-compensable) and
`motion=jump` (the frame displaced by H/2 every `mstep` frames — the window-switch case; `mstep=1`
defeats single-reference prediction so every P is intra-like). Every frame's source index and motion
offset are in the run log (`src frame i: srcf= off= br=`) and the CSV. These are real texture with
synthetic motion; they are labelled as such everywhere.

**Vendor stack at runtime** (device-re-subagent skill, "Vendor stack on a purged device"): the
2026-09-05 staging dir `/root/hevc64/{ko,lib,bin,dev}` was reused as-is (`SHA256SUMS` there);
`/root/hevc64/dev/vendor-on.sh` (stop services, rmmod the three open modules, insmod
`ax_sys/cmm(cmmpool=anonymous,0,0x73800000,200M)/pool/base/venc`) **plus `insmod ax_jenc.ko`**
(required for `AX_VENC_Init`; the script does not load it). `libax_venc.so` is the stock-rootfs
build. Nothing on disk changed; the on-disk loader is the open one.

**Driver tool.** `tools/vdrive.c` = the HEVC campaign's `vdrive.c` plus `src=` (recorded frames,
mmap'ed), `loop=`, `motion=`/`mstep=`/`mstart=`/`mstop=`/`mjump=`, and `chg=<frame>:<kbps>,…`
(mid-stream bitrate change through `AX_VENC_GetRcParam` → edit `u32BitRate` / `u32MaxBitRate` →
`AX_VENC_SetRcParam`, immediately before `AX_VENC_SendFrame` of that frame; the read-back is logged).
Built on the device: `gcc -O2 -std=gnu17 -Iinc vdrive.c -L/root/hevc64/lib -lax_venc -lax_sys
-lax_ivps -lax_proton -Wl,--allow-shlib-undefined -Wl,--disable-new-dtags -Wl,-rpath,/root/hevc64/lib`
(`inc/` = the public headers of `.#axera-libs`; `--disable-new-dtags` gives DT_RPATH so the transitive
libax deps resolve). R1 ran `bin/vdrive` (built before `motion=jump` existed), R2–R6 `bin/vdrive2`
(the committed source); the non-jump code paths are identical. `snapall=2` dumps the 64 KB `venc_ko`
cmdbuf pool over `/dev/mem` (read-only) after every frame.

**Extraction.** `tools/rc_traj.py` (on-device, python3) joins per frame: the `AX_VENC_GetStream` pack
length and coding type (log), the slice type / slice QP / VCL NAL size parsed from the bitstream
(`h264parse.py` / `h265parse.py` from the sibling campaigns, unchanged), the source frame / offset /
target bitrate (log), and the frame's cmdbuf program = the ≥400-register slot that changed between
consecutive pool snapshots (the vendor walks slots 2→7 as a ring; every frame of every run had exactly
one fresh slot — `slot flags: {'': N}` in each summary). Register columns: `sw7` (+ decoded init/frame
QP), `sw105–107`, `sw172/173`, `sw243/244/247`, `sw6`, `sw22`, `sw11`. `sw7[13:8]` equalled the
bitstream slice QP on **every frame of every run** (the `sw7 frame-QP == slice QP` line).

**Pipeline validation** (`smoke/`): the real-frame H.264 1080p CBR-8000 IDR program equals
`../vendor-diff-20260904/E4/vendor_base_IDR.txt` in all 511 registers except the 16 address registers
(`regdiff.py`: "0 registers differ") — the IDR program is content-independent and this is the same
encoder E1–E6/H0–H8 measured.

**Independent recomputation.** `R1/h264_cbr2000.h264` was pulled to the host and parsed with
`h264parse.py` outside `rc_traj.py`: the 240 slice QPs and the 240 VCL NAL sizes are identical to the
committed CSV columns; ffmpeg decodes it and `R1/h265_cbr2000.h265` with zero errors.

**End state.** The raw clip and every bitstream were deleted from the device (they carry the desktop
image); the device was rebooted to the open stack and verified (`nanokvm` active, web 200, the three
open modules, an MJPEG frame). `/root/rc65/{bin,tools,inc}` (tools + public headers, no clips) and
`/root/hevc64` remain as staging. Two warm reboots would be the worst case; this session needed one
(the return). No watchdog reboot occurred.

## Exact run matrix (`tools/rcbatch.sh`)

All runs: 1920×1080, `fps=60`, `gop=30`, `StatTime=1`, Main/5.1, qp range 10..51 (vdrive defaults),
`snapall=2`, `src=/root/rc65/clips/static.yuyv`.

| phase | runs | frames | stimulus |
|---|---|---|---|
| R1 | `{h264,h265}_cbr{2000,8000,16000}` | 240 | vscroll 4 px/frame |
| R2 | `{h264,h265}_vbr{2000,8000,16000}` | 240 | vscroll 4 px/frame |
| R3 | `{h264,h265}_chg` CBR 8000→2000 @60→16000 @120; `_chg_vbr` same in VBR; `_chgmid` CBR @75/@165 (mid-GOP) | 270 | vscroll 4 px/frame |
| R4 | `{h264,h265}_static{2000,8000,16000}` CBR | 240 | none (the recorded desktop as-is) |
| R5 | `{h264,h265}_phase8000` CBR | 270 | static 0..89, vscroll 90..179, static 180..269 |
| R6 | `{h264,h265}_jump{1,15}_cbr{2000,8000,16000}` CBR | 240 | H/2 jump every 1 / every 15 frames |
| R7 | `h265_jump1_cbr{1000,3000,4000,6000,7000,7500}`, `h264_jump1_cbr{1000,3000}` CBR | 60 | H/2 jump every frame (the HEVC no-target threshold bisect; run by hand, commands in `R7/batch.log`) |

## Contents

- `REPORT.md` — findings, laws, differences to E6/H8.
- `aggregate.md` — `tools/rc_report.py` over all runs: one row per run (achieved kbps, IDR QPs,
  first-P QPs, kbps per GOP, P range, step histogram) + the frame-by-frame views around every
  mid-stream change. `fits.txt` — `tools/rc_fit.py` tables (IDR-QP rule, P-step rule, targets) for
  the nine runs the report quotes.
- `R1/ … R7/` — per run: `<tag>_trajectory.csv`, `<tag>_summary.txt`, `<tag>.log` (vdrive log incl.
  every `src frame` and `chg` line), plus `batch.log`; `batch_all.out`/`batch_rest.out` are the batch
  drivers' stdout.
- `smoke/` — the 6-frame real-frame control: trajectory, log, and the six decoded per-frame programs
  (`vendor_smoke_f00k.txt`, geom-probe format).
- `tools/` — `v4lrec.c`, `vdrive.c`, `rc_traj.py`, `rcbatch.sh`, `rc_report.py` (aggregate table +
  change views), `rc_fit.py` (I-QP and P-step law tables). Parsers are the sibling campaigns' files.

## Deliberately NOT committed

The raw YUYV clip, every `.h264`/`.h265` bitstream (all show the desktop), the per-frame cmdbuf pools
(deleted on the device after extraction, 15 MB per run). Numbers, CSVs and tooling only.

## CSV format

`frame,type,bytes,slice_bytes,slice_qp,srcf,off,br_kbps,slot,flag,sw7,sw7_initqp,sw7_frameqp,sw105,
sw106,sw107,sw172,sw173,sw243,sw244,sw247,sw6,sw22,sw11` — `bytes` is the `AX_VENC` pack length (the
IDR pack includes VPS/SPS/PPS), `slice_bytes` the VCL NAL, `br_kbps` the target in force when the frame
was sent, registers in hex as programmed in the frame's cmdbuf.
