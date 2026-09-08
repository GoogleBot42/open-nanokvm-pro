#!/bin/sh
# rung 2 (#89): stage /boot, write the image under test to uboot_b, arm slot B.
set -e
cd /root/rung2
IMG=${1:-u-boot_mainline_debug_signed.bin}
md5sum "$IMG"
SZ=$(stat -c%s "$IMG")
dd if="$IMG" of=/dev/mmcblk0p6 bs=1M conv=fsync
sync; echo 3 > /proc/sys/vm/drop_caches
echo "--- p6 readback ($SZ bytes) ---"
head -c "$SZ" /dev/mmcblk0p6 | md5sum

echo "--- stage /boot ---"
mkdir -p /boot/extlinux
cp Image /boot/Image
cp ax630c-nanokvm-pro.dtb /boot/ax630c-nanokvm-pro.dtb
cp extlinux.conf /boot/extlinux/extlinux.conf
cp extlinux-fallback.conf /boot/extlinux/extlinux-fallback.conf
sync; echo 3 > /proc/sys/vm/drop_caches
md5sum /boot/Image /boot/ax630c-nanokvm-pro.dtb /boot/extlinux/extlinux.conf

sh /root/rung2/arm-slotb.sh
