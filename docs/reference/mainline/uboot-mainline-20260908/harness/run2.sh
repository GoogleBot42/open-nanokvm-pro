#!/bin/sh
set -e
cd /root/rung2
md5sum u-boot_mainline_debug_signed.bin
SZ=$(stat -c%s u-boot_mainline_debug_signed.bin)
dd if=u-boot_mainline_debug_signed.bin of=/dev/mmcblk0p6 bs=1M conv=fsync
sync; echo 3 > /proc/sys/vm/drop_caches
echo "--- p6 readback ($SZ bytes) ---"
head -c "$SZ" /dev/mmcblk0p6 | md5sum
sh /root/rung2/arm-slotb.sh
