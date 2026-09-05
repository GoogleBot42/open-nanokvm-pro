#!/bin/bash
# #46 device validation, phase B: the live wss h264-direct path on the real HDMI
# source at three bitrates, then a mid-stream bitrate change during a grab.
OUT=/root/rc46
LOG=/var/log/nanokvm/NanoKVM-Server.log
mkdir -p $OUT
cd $OUT
mode() { curl -sk -X POST -d "mode=$1" https://127.0.0.1/api/stream/mode; echo; }
qual() { curl -sk -X POST -d "quality=$1" https://127.0.0.1/api/stream/quality; echo; }
grab() {  # tag codec nmsgs
  python3 /tmp/wsgrab.py $OUT/$1.$2 $3 60 $2 > $OUT/$1.ws 2>&1
  echo "$1: $(grep -c . $OUT/$1.ws) msgs, $(stat -c %s $OUT/$1.$2) bytes"
}
echo "== source: $(cat /proc/lt6911_info/width)x$(cat /proc/lt6911_info/height)@$(cat /proc/lt6911_info/fps)"
mode h264-direct
qual 8000
sleep 1
grab live_h264_8000 h264 600
qual 2000
sleep 1
grab live_h264_2000 h264 600
qual 16000
sleep 1
grab live_h264_16000 h264 600
# mid-stream change during one grab: 8000 -> 2000 after ~5 s
qual 8000
sleep 1
( sleep 5; qual 2000 > /dev/null ) &
grab live_h264_chg h264 600
wait
qual 8000
# persist the controller log lines for this session
grep -E "\[openvenc\]" $LOG | tail -n 4000 > $OUT/live_openvenc.log
echo "openvenc log lines: $(wc -l < $OUT/live_openvenc.log)"
grep -E "\[openvenc\] (up|rc:)" $OUT/live_openvenc.log | tail -n 12
grep -c "retarget" $OUT/live_openvenc.log
grep -c "FAIL" $OUT/live_openvenc.log
curl -sk -o /dev/null -w "web %{http_code}\n" https://127.0.0.1/
systemctl is-active nanokvm
