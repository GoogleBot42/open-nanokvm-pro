#!/bin/sh
# rung 2 (#89) teardown: put uboot_b, the environment and /boot back exactly as
# they were, and leave the slot register on slot A.
set -e
cd /root/rung2

echo "=== restore uboot_b (p6) ==="
dd if=uboot_b.orig of=/dev/mmcblk0p6 bs=1M conv=fsync
echo "=== restore env (p7) ==="
dd if=p7-env.orig of=/dev/mmcblk0p7 bs=1M conv=fsync
sync; echo 3 > /proc/sys/vm/drop_caches
echo "expect 1521dc39f8a50e726c708fde2c8edce2 / 6a579b4ea52ced8ea7ab8cafe2b5102a"
head -c 1572864 /dev/mmcblk0p6 | md5sum
head -c 1048576 /dev/mmcblk0p7 | md5sum

echo "=== restore /boot ==="
rm -f /boot/Image /boot/ax630c-nanokvm-pro.dtb
rm -f /boot/extlinux/extlinux.conf /boot/extlinux/extlinux-fallback.conf
rmdir /boot/extlinux 2>/dev/null || true
cp -a /root/rung2/boot-backup/. /boot/
sync; echo 3 > /proc/sys/vm/drop_caches
find /boot | sort
df -h /boot

echo "=== env ==="
fw_printenv

echo "=== slot register -> slot A ==="
devmem 0x0239002C 32 0xFFFFF000
devmem 0x0239002C 32 0x28
devmem 0x02390028 32 0x14
devmem 0x02390024
sync
