#!/bin/bash
# #46 device validation, phase A: the standalone prover (ewl_encode) with the
# software rate controller over the open VCMD driver. Service stopped for the
# duration, restarted unconditionally at the end. Logs + bitstreams -> /root/rc46.
OUT=/root/rc46
mkdir -p $OUT
cd $OUT
echo "refcnt before: $(cat /sys/module/ax630c_venc_vcmd/refcnt)"
systemctl stop nanokvm
sleep 1
run() {  # tag codec rc kbps kbps2 nframes
  tag=$1; codec=$2; rc=$3; kbps=$4; kbps2=$5; n=$6
  ext=h264; [ "$codec" = h265 ] && ext=h265
  env EWL_CODEC=$codec EWL_RC=$rc EWL_KBPS=$kbps EWL_KBPS2=$kbps2 EWL_FPS=60 \
    /tmp/ewl_encode $OUT/$tag.$ext $n 30 yuyv > $OUT/$tag.log 2>&1
  echo "$tag: $(grep -c ' ok$' $OUT/$tag.log) ok, $(grep -c FAIL $OUT/$tag.log) fail; $(grep RESULT $OUT/$tag.log | cut -c1-160)"
}
run h264_cbr2000   h264 cbr 2000  0 180
run h264_cbr8000   h264 cbr 8000  0 180
run h264_cbr16000  h264 cbr 16000 0 180
run h265_cbr2000   h265 cbr 2000  0 180
run h265_cbr8000   h265 cbr 8000  0 180
run h265_cbr16000  h265 cbr 16000 0 180
run h264_vbr8000   h264 vbr 8000  0 180
run h265_vbr2000   h265 vbr 2000  0 180
run h264_chg8to2   h264 cbr 8000  2000  240
run h264_chg2to16  h264 cbr 2000  16000 240
run h265_chg8to2   h265 cbr 8000  2000  240
run h264_fixqp32   h264 none 0    0 60
echo "refcnt after: $(cat /sys/module/ax630c_venc_vcmd/refcnt)"
systemctl start nanokvm
sleep 4
systemctl is-active nanokvm
ls -la $OUT | tail -n +2 | awk '{print $5, $9}' | tr '\n' ' '; echo
