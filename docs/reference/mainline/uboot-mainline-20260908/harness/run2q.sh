#!/bin/sh
# rung 2q round 4 (#89): the interface select is fixed (round 3 reports
# "Active PHY interface: RGMII (1)") and MDIO address 1 is STILL missing, so
# dump the ethernet pad mux window from U-Boot and diff it against slot A.
#
# Slot A, measured with Linux running:
#   0x104f003c RGMII_MDCK  0x0000000F   mux 0 = RGMII
#   0x104f0048 RGMII_MDIO  0x0000000F   mux 0 = RGMII
#   0x104f0054 EPHY_CLK    0x00060003   mux 6 = GPIO  (firmware, not Linux)
#   0x104f0060 EPHY_RSTN   0x00060008   mux 6 = GPIO  (Linux reset-gpios)
#   0x104f006c EPHY_LED0   0x00060083   mux 6 = GPIO  (lt6911 interrupt)
#   0x104f0078 EPHY_LED1   0x00060003   mux 6 = GPIO
#   0x104f0084..0x0108     0x0000000F   mux 0 = RGMII, the twelve data pads
# Linux names no pinctrl group for the RGMII data pads, so those twelve are
# pure firmware state: if they differ here, that is the answer.
set -e
cd /root/rung2

dd if=u-boot_2p.bin of=/dev/mmcblk0p6 bs=1M conv=fsync 2>/dev/null
sync; echo 3 > /proc/sys/vm/drop_caches
echo "--- p6 readback (expect abd4acfd8d912db3f28ca01dea89c4c9) ---"
head -c 185864 /dev/mmcblk0p6 | md5sum

mkdir -p /boot/extlinux
cp -f Image-2q3 /boot/Image
cp -f ax630c-2q5.dtb /boot/ax630c-2q5.dtb
cp -f extlinux2q6.conf /boot/extlinux/extlinux.conf
sync; echo 3 > /proc/sys/vm/drop_caches
echo "--- /boot ---"
md5sum /boot/Image /boot/ax630c-2q5.dtb /boot/extlinux/extlinux.conf

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
fw_setenv bootone 'mmc rescan; md.l 0x10030000 0xc; md.l 0x104f0030 0x40; mw.l ${msreg_set} ${ms_extlinux}; sysboot mmc ${bootdev}:${bootpart} any ${scriptaddr} ${extlinux_cfg}'
fw_setenv bootcmd 'run bootone || run bootone || run bootone || run bootone; mw.l ${msreg_set} ${ms_failed}; reset'
echo "--- env ---"
fw_printenv bootone

dd if=/dev/zero of=/dev/mem bs=4096 seek=295144 count=8 2>/dev/null
devmem 0x0239002C 32 0xFFFFF000
devmem 0x0239002C 32 0x14
devmem 0x02390028 32 0x28
echo "--- armed ---"
devmem 0x02390024
sync
