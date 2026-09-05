#!/bin/sh
# E3: vendor golden vectors above 1920 wide (CBR 8000, fps60, gop30, H264)
O=/tmp/axwork/E3; mkdir -p $O; cd /tmp/axwork
systemctl stop nanokvm; sleep 1
for g in 3840x2160 2560x1440 3440x1440 2560x1080 3840x2400 1920x1440 2048x1080 3200x1800 1920x1080; do
  W=${g%x*}; H=${g#*x}
  echo "=== $g ===" >> $O/batch.log
  ./vdrive w=$W h=$H tag=$g out=$O >> $O/batch.log 2>&1; echo "rc=$?" >> $O/batch.log
  python3 tools/decode_run.py $O $g $W $H >> $O/batch.log 2>&1
done
systemctl start nanokvm
echo done > $O/DONE
