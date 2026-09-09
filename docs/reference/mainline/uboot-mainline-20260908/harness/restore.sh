#!/bin/sh
# rung 2 (#89) teardown: put uboot_b, the environment and /boot back exactly as
# they were, and leave the slot register on slot A.
#
# /boot is emptied by CONTENT, not by a list of names. The earlier version
# removed the three files it happened to know about, and every round that
# staged a differently-named dtb left one behind (rung 2q ended with
# ax630c-2q3.dtb and ax630c-2q5.dtb still there after a "successful" restore).
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
rm -rf /boot/extlinux
find /boot -mindepth 1 -maxdepth 1 -type f -exec rm -f {} +
cp -a /root/rung2/boot-backup/. /boot/
sync; echo 3 > /proc/sys/vm/drop_caches
find /boot | sort
if [ "$(find /boot -mindepth 1 | wc -l)" != 1 ]; then
	echo "!! /boot is not 'ver' alone -- look at it before going further"
	exit 1
fi
df -h /boot

echo "=== env ==="
fw_printenv

echo "=== slot register -> slot A ==="
devmem 0x0239002C 32 0xFFFFF000
devmem 0x0239002C 32 0x28
devmem 0x02390028 32 0x14
devmem 0x02390024
sync
