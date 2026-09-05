#!/bin/sh
# E2, E1, E4, E6, E5 -- runs after E3 finishes. All at 1080p unless noted.
cd /tmp/axwork
while [ ! -f /tmp/axwork/E3/DONE ]; do sleep 5; done
systemctl stop nanokvm; sleep 1
run() { # run <phase> <tag> args...
  ph=$1; tg=$2; shift 2; O=/tmp/axwork/$ph; mkdir -p $O
  echo "=== $tg: $*" >> $O/batch.log
  ./vdrive tag=$tg out=$O "$@" >> $O/batch.log 2>&1; echo "rc=$?" >> $O/batch.log
}
dec() { python3 tools/decode_run.py /tmp/axwork/$1 $2 ${3:-1920} ${4:-1080} $5 >> /tmp/axwork/$1/batch.log 2>&1; }
# ---- E2: fixed-QP ladder (per-frame snapshots for sw9/sw82 mirror readback) ----
for q in 16 20 24 28 32 36 40 44 48 51; do run E2 fixqp$q rc=fixqp iqp=$q pqp=$q snapall=1; dec E2 fixqp$q 1920 1080 --all; done
run E2 fixqp_i28_p34 rc=fixqp iqp=28 pqp=34 snapall=1; dec E2 fixqp_i28_p34 1920 1080 --all
echo done > /tmp/axwork/E2/DONE
# ---- E1: RC-mode differential ----
for m in cbr vbr fixqp avbr cvbr qvbr qpmap; do run E1 rc_$m rc=$m br=8000 iqp=32 pqp=32; dec E1 rc_$m; done
echo done > /tmp/axwork/E1/DONE
# ---- E4: single-knob sweep from the CBR 8000 / fps60 / gop30 / main / 5.1 baseline ----
run E4 base ; dec E4 base
run E4 base_rep ; dec E4 base_rep
run E4 profile9 profile=9; dec E4 profile9
run E4 profile11 profile=11; dec E4 profile11
for g in 1 8 60 120; do run E4 gop$g gop=$g; dec E4 gop$g; done
run E4 fps30 fps=30; dec E4 fps30
run E4 fps60d30 fps=60 dfps=30; dec E4 fps60d30
for b in 2000 16000; do run E4 br$b br=$b; dec E4 br$b; done
run E4 qp20_40 minqp=20 maxqp=40 miniqp=20 maxiqp=40; dec E4 qp20_40
run E4 qp30_30 minqp=30 maxqp=30 miniqp=30 maxiqp=30; dec E4 qp30_30
run E4 iqd_m5 iqd=-5; dec E4 iqd_m5
run E4 iqd_p5 iqd=5; dec E4 iqd_p5
for l in 40 42 31; do run E4 level$l level=$l; dec E4 level$l; done
run E4 ir5row ir=5 irmode=0; dec E4 ir5row
run E4 ir5col ir=5 irmode=1; dec E4 ir5col
run E4 slice8 slice=8; dec E4 slice8
run E4 slice1 slice=1; dec E4 slice1
run E4 debreath debreath=1; dec E4 debreath
run E4 setrc_same setrc=1; dec E4 setrc_same
run E4 scd1 setrc=1 scd=1; dec E4 scd1
run E4 rowqpd3 setrc=1 rowqpd=3; dec E4 rowqpd3
run E4 firstqp30 firstqp=30; dec E4 firstqp30
run E4 stattime3 stattime=3; dec E4 stattime3
run E4 iprop20_80 miniprop=20 maxiprop=80; dec E4 iprop20_80
run E4 idrrange8 idrrange=8; dec E4 idrrange8
run E4 share share=1; dec E4 share
run E4 refring refring=1; dec E4 refring
run E4 dbqd5 dbqd=5; dec E4 dbqd5
run E4 moving move=1; dec E4 moving
echo done > /tmp/axwork/E4/DONE
# ---- E6: CBR trajectory, moving card, 90 frames ----
for b in 2000 8000 16000; do run E6 traj$b br=$b nframes=90 move=1; done
echo done > /tmp/axwork/E6/DONE
# ---- E5: live fuse/config read while a vendor encode runs continuously ----
mkdir -p /tmp/axwork/E5
./vdrive tag=bg out=/tmp/axwork/E5 nframes=1200 move=1 > /tmp/axwork/E5/bg.stdout 2>&1 &
BG=$!
sleep 2
./regpoll /tmp/axwork/E5/regs.bin 12 /tmp/axwork/E5/samples.txt > /tmp/axwork/E5/regpoll.log 2>&1; echo "regpoll rc=$?" >> /tmp/axwork/E5/regpoll.log
wait $BG
echo done > /tmp/axwork/E5/DONE
systemctl start nanokvm
echo done > /tmp/axwork/ALLDONE
