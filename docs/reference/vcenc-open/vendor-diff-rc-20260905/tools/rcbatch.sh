#!/bin/sh
# Real-content RC campaign batch (2026-09-05). Runs with the vendor stack up
# (/root/hevc64/dev/vendor-on.sh + ax_jenc.ko), nanokvm stopped. Each run: vdrive on the
# recorded real frames with per-frame pool snapshots (snapall=2), then rc_traj.py
# extracts the trajectory CSV + summary and deletes the pools (tmpfs budget).
# Bitstreams and logs stay in the run dir. Usage: rcbatch.sh R1 [R2 ...]
# (R1 ran from bin/vdrive; R2.. from bin/vdrive2 = the same source plus motion=jump.)
S=/root/rc65; B=$S/bin; T=$S/tools; CLIP=$S/clips
STATIC=$CLIP/static.yuyv
VD=${VD:-$B/vdrive2}
export VCTOOLS=$T
run() { d_=$1; tg=$2; codec=$3; shift 3; O=/tmp/axwork/$d_; mkdir -p $O
  echo "=== $tg: codec=$codec $*" >> $O/batch.log
  $VD codec=$codec tag=$tg out=$O snapall=2 "$@" >> $O/batch.log 2>&1; echo "rc=$?" >> $O/batch.log
  python3 $T/rc_traj.py $O $tg 1920 1080 --codec $codec --rm-pools >> $O/batch.log 2>&1
  rm -f $O/vencblk_*; }
for ph in "$@"; do
case $ph in
# R1: real desktop, labelled vertical scroll 4 px/frame, CBR 2000/8000/16000, 240 frames (8 GOPs)
R1) for c in h264 h265; do for b in 2000 8000 16000; do
      run R1 ${c}_cbr$b $c rc=cbr br=$b nframes=240 src=$STATIC motion=vscroll mstep=4
    done; done ;;
# R2: same, VBR (u32MaxBitRate = the same three values)
R2) for c in h264 h265; do for b in 2000 8000 16000; do
      run R2 ${c}_vbr$b $c rc=vbr br=$b nframes=240 src=$STATIC motion=vscroll mstep=4
    done; done ;;
# R3: mid-stream target change through AX_VENC_SetRcParam: 8000 -> 2000 @60 -> 16000 @120, 270 frames;
#     the mid-GOP variant lands the change on a P frame (75 = I+15, 165 = I+15)
R3) for c in h264 h265; do
      run R3 ${c}_chg $c rc=cbr br=8000 nframes=270 src=$STATIC motion=vscroll mstep=4 chg=60:2000,120:16000
      run R3 ${c}_chg_vbr $c rc=vbr br=8000 nframes=270 src=$STATIC motion=vscroll mstep=4 chg=60:2000,120:16000
      run R3 ${c}_chgmid $c rc=cbr br=8000 nframes=270 src=$STATIC motion=vscroll mstep=4 chg=75:2000,165:16000
    done ;;
# R4: the KVM common case -- the recorded static desktop as-is (no motion), CBR
R4) for c in h264 h265; do for b in 2000 8000 16000; do
      run R4 ${c}_static$b $c rc=cbr br=$b nframes=240 src=$STATIC motion=none
    done; done ;;
# R5: content dynamics -- static 0..89, scroll 90..179, static again 180..269, CBR 8000
R5) for c in h264 h265; do
      run R5 ${c}_phase8000 $c rc=cbr br=8000 nframes=270 src=$STATIC motion=vscroll mstep=4 mstart=90 mstop=180
    done ;;
# R6: in-band stimulus -- the real frame displaced by H/2 (a) every frame (single-reference prediction
#     defeated: every P is intra-like, the RC is bit-starved at every target) and (b) every 15 frames
#     (window-switch pattern: one expensive P per half GOP)
R6) for c in h264 h265; do for b in 2000 8000 16000; do
      run R6 ${c}_jump1_cbr$b $c rc=cbr br=$b nframes=240 src=$STATIC motion=jump mstep=1
      run R6 ${c}_jump15_cbr$b $c rc=cbr br=$b nframes=240 src=$STATIC motion=jump mstep=15
    done; done ;;
esac
echo done > /tmp/axwork/DONE_$ph
done
