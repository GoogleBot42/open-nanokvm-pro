#!/bin/sh
# rung 2q round 3 (#89): the dwmac-axera interface-select-before-reset fix.
set -e
cd /root/rung2

dd if=u-boot_2p.bin of=/dev/mmcblk0p6 bs=1M conv=fsync 2>/dev/null
sync; echo 3 > /proc/sys/vm/drop_caches
echo "--- p6 readback (expect abd4acfd8d912db3f28ca01dea89c4c9) ---"
head -c 185864 /dev/mmcblk0p6 | md5sum

mkdir -p /boot/extlinux
cp -f Image-2q3 /boot/Image
cp -f ax630c-2q3.dtb /boot/ax630c-2q3.dtb
cp -f extlinux2q3.conf /boot/extlinux/extlinux.conf
rm -f /boot/ax630c-2q2.dtb /boot/ax630c-stock.dtb /boot/ax630c-nowdt.dtb
rm -f /boot/ax630c-nanokvm-pro.dtb /boot/extlinux/extlinux-fallback.conf
sync; echo 3 > /proc/sys/vm/drop_caches
echo "--- /boot (expect e2a0f2ddebbb1af40e173894713ab1b5 / 05581c10e6b955dbdc0256bcbf87d1f0) ---"
md5sum /boot/Image /boot/ax630c-2q3.dtb /boot/extlinux/extlinux.conf

fw_setenv scriptaddr 0x49000000
fw_setenv fdt_addr_r 0x49200000
fw_setenv kernel_addr_r 0x4a000000
fw_setenv ramdisk_addr_r 0x4e000000
fw_setenv fdt_high 0x5f000000
fw_setenv initrd_high 0x5f000000
fw_setenv bootdev 0
fw_setenv bootpart 10
fw_setenv extlinux_cfg /extlinux/extlinux.conf
fw_setenv msreg_set 0x02390028
fw_setenv ms_uboot 0x10000000
fw_setenv ms_extlinux 0x20000000
fw_setenv ms_altboot 0x40000000
fw_setenv ms_failed 0x80000000
fw_setenv preboot 'mw.l ${msreg_set} ${ms_uboot}'
fw_setenv bootone 'mmc rescan; md.l 0x10030000 0xc; mw.l ${msreg_set} ${ms_extlinux}; sysboot mmc ${bootdev}:${bootpart} any ${scriptaddr} ${extlinux_cfg}'
fw_setenv bootcmd 'run bootone || run bootone || run bootone || run bootone; mw.l ${msreg_set} ${ms_failed}; reset'
echo "--- env ---"
fw_printenv fdt_high

dd if=/dev/zero of=/dev/mem bs=4096 seek=295144 count=8 2>/dev/null
devmem 0x0239002C 32 0xFFFFF000
devmem 0x0239002C 32 0x14
devmem 0x02390028 32 0x28
echo "--- armed ---"
devmem 0x02390024
sync
