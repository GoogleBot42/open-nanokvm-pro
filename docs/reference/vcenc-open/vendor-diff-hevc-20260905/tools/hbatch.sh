#!/bin/sh
# H2..H8 HEVC campaign batch (#64). Runs with the vendor stack up (vendor-on.sh),
# nanokvm stopped. Every run: vdrive codec=h265 + generic decode. DONE markers per phase.
B=/root/hevc64/bin; T=/root/hevc64/tools; cd /tmp/axwork
run() { ph=$1; tg=$2; shift 2; O=/tmp/axwork/$ph; mkdir -p $O
  echo "=== $tg: $*" >> $O/batch.log
  $B/vdrive codec=h265 tag=$tg out=$O "$@" >> $O/batch.log 2>&1; echo "rc=$?" >> $O/batch.log; }
dec() { python3 $T/decode_run.py /tmp/axwork/$1 $2 ${3:-1920} ${4:-1080} --generic $5 >> /tmp/axwork/$1/batch.log 2>&1; }
# ---- H2: geometry sweep (keep raw pools) ----
for g in 1920x1080 3840x2160 2560x1440 3440x1440 2560x1080 3840x2400 1920x1440 2048x1080 3200x1800 \
         1024x768 1152x864 1280x720 1360x768 1362x768 1364x768 1366x768 1368x768 1370x768 1372x768 1374x768 1440x900 1600x900 1920x1200 800x600 640x480 \
         136x136 200x136 1920x1088 1984x1080 2000x1080 1928x1080 1920x1152 1920x1096 3840x2176 2560x1600 1280x1024 64x64 3840x1080; do
  W=${g%x*}; H=${g#*x}; run H2 $g w=$W h=$H; dec H2 $g $W $H
done
echo done > /tmp/axwork/H2/DONE
# ---- H3: fixed-QP ladder (snapall=1: per-frame pools + mirrors) ----
for q in 16 20 24 28 32 36 40 44 48 51; do run H3 fixqp$q rc=fixqp iqp=$q pqp=$q snapall=1; dec H3 fixqp$q 1920 1080 --all; done
run H3 fixqp_i28_p34 rc=fixqp iqp=28 pqp=34 snapall=1; dec H3 fixqp_i28_p34 1920 1080 --all
echo done > /tmp/axwork/H3/DONE
# ---- H4: RC-mode differential ----
for m in cbr vbr fixqp avbr cvbr qvbr qpmap; do run H4 rc_$m rc=$m br=8000 iqp=32 pqp=32; dec H4 rc_$m; done
echo done > /tmp/axwork/H4/DONE
# ---- H5: knob sweep from the HEVC 1080p CBR-8000/fps60/gop30/Main/5.1 baseline ----
run H5 base; dec H5 base
run H5 base_rep; dec H5 base_rep
for p in 1 2 3; do run H5 profile$p profile=$p; dec H5 profile$p; done
run H5 tier1 tier=1; dec H5 tier1
for l in 120 150 180 93; do run H5 level$l level=$l; dec H5 level$l; done
for g in 1 8 60 120; do run H5 gop$g gop=$g; dec H5 gop$g; done
run H5 fps30 fps=30; dec H5 fps30
run H5 fps60d30 fps=60 dfps=30; dec H5 fps60d30
for b in 2000 16000; do run H5 br$b br=$b; dec H5 br$b; done
run H5 qp20_40 minqp=20 maxqp=40 miniqp=20 maxiqp=40; dec H5 qp20_40
run H5 qp30_30 minqp=30 maxqp=30 miniqp=30 maxiqp=30; dec H5 qp30_30
run H5 iqd_m5 iqd=-5; dec H5 iqd_m5
run H5 iqd_p5 iqd=5; dec H5 iqd_p5
run H5 firstqp30 firstqp=30; dec H5 firstqp30
run H5 idrrange8 idrrange=8; dec H5 idrrange8
run H5 slice8 slice=8; dec H5 slice8
run H5 slice1 slice=1; dec H5 slice1
run H5 ir5row ir=5 irmode=0; dec H5 ir5row
run H5 ir5col ir=5 irmode=1; dec H5 ir5col
run H5 refring refring=1; dec H5 refring
run H5 share share=1; dec H5 share
run H5 debreath debreath=1; dec H5 debreath
run H5 setrc_same setrc=1; dec H5 setrc_same
run H5 scd1 setrc=1 scd=1; dec H5 scd1
run H5 rowqpd3 setrc=1 rowqpd=3; dec H5 rowqpd3
run H5 stattime3 stattime=3; dec H5 stattime3
run H5 iprop20_80 miniprop=20 maxiprop=80; dec H5 iprop20_80
run H5 dbqd5 dbqd=5; dec H5 dbqd5
run H5 vui0 vui=0; dec H5 vui0
run H5 vui1 vui=1; dec H5 vui1
run H5 oneltr gopmode=oneltr ltrint=4; dec H5 oneltr
run H5 svct gopmode=svct; dec H5 svct
run H5 moving move=1; dec H5 moving
echo done > /tmp/axwork/H5/DONE
# ---- H6: DPB/RPS ring ----
run H6 ring30 nframes=14 snapall=1; dec H6 ring30 1920 1080 --all
run H6 ring8 gop=8 nframes=20 snapall=2; dec H6 ring8 1920 1080 --all
run H6 ltr30 gopmode=oneltr ltrint=4 gop=30 nframes=20 snapall=2; dec H6 ltr30 1920 1080 --all
run H6 ltr30i2 gopmode=oneltr ltrint=2 gop=30 nframes=12 snapall=2; dec H6 ltr30i2 1920 1080 --all
echo done > /tmp/axwork/H6/DONE
# ---- H8: CBR trajectories, moving card, 90 frames ----
for b in 2000 8000 16000; do run H8 traj$b br=$b nframes=90 move=1; done
echo done > /tmp/axwork/H8/DONE
# ---- H7: live core window during a continuous HEVC encode ----
mkdir -p /tmp/axwork/H7
$B/vdrive codec=h265 tag=bg out=/tmp/axwork/H7 nframes=900 move=1 > /tmp/axwork/H7/bg.stdout 2>&1 &
BG=$!
sleep 2
$B/regpoll2 /tmp/axwork/H7/live512.bin 10 > /tmp/axwork/H7/regpoll.log 2>&1; echo "regpoll rc=$?" >> /tmp/axwork/H7/regpoll.log
wait $BG
echo done > /tmp/axwork/H7/DONE
echo done > /tmp/axwork/ALLDONE
