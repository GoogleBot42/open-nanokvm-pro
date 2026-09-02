#!/bin/sh
# Open-driver multi-geometry capture run on a base-only boot (our own tooling).
cd /root/axbring
echo 0 > /proc/sys/kernel/panic_on_oops
. /run/openkvm-memmap.env
lsmod | grep -q open_vin_csi2 || { dmesg -C; insmod ./open_vin_csi2.ko start_on_probe=1; sleep 1; }
lsmod | grep -q open_vin_capture || insmod ./open_vin_capture.ko carveout_base=$OPENKVM_CAPTURE_BASE carveout_size=$OPENKVM_CAPTURE_SIZE
sleep 1; dmesg | grep -i "open_vin\|ovc\|openvin" | tail -15
V=$(ls /dev/video* | head -1); echo "video node: $V"
for g in "3840 2160" "1920 1080" "1280 720" "2560 1440" "1920 1200" "3840 2160"; do
  set -- $g; echo "=== open $1x$2"
  ./v4l2grab $V $1 $2 30 5 geo/open-$1x$2.yuyv 2>&1 | tail -4
  dmesg | tail -3
done
ls -la geo/open-*.yuyv
