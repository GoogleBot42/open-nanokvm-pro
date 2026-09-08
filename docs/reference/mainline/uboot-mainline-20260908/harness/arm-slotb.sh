#!/bin/sh
# rung 2 (#89): set the two env variables mainline U-Boot needs, clear the
# milestone bits and the debug scratchpad, arm slot B.  Everything here is
# undone by restoring /root/rung2/p7-env.orig over p7 and writing 0x14 back to
# the slot register.
set -e

# preboot: milestone bit 28, then arm WDT0 the way the vendor U-Boot's
# board_late_init() does -- TORR, strobe TORR_LOAD, mux to 24 MHz, EN.
# 0x80be = (90 s * 24 MHz) >> 16, two stages, so ~180 s: enough head-room for
# an MMU-off U-Boot to read a 51 MB kernel off the eMMC uncached.
PREBOOT='mw.l 0x02390028 0x10000000; mw.l 0x0484000c 0x80be; mw.l 0x04840018 0x1; mw.l 0x04840018 0x0; mw.l 0x048700a8 0x80000; mw.l 0x04840000 0x1'

BOOTCMD='setenv fdt_high 0xffffffffffffffff; setenv initrd_high 0xffffffffffffffff; setenv scriptaddr 0x49000000; setenv pxefile_addr_r 0x49100000; setenv fdt_addr_r 0x49200000; setenv kernel_addr_r 0x4a000000; setenv ramdisk_addr_r 0x4e000000; setenv bootdev 0; setenv bootpart 16; if load mmc 0:16 0x49000000 /extlinux/extlinux.conf; then mw.l 0x02390028 0x20000000; sysboot mmc 0:16 any 0x49000000 /extlinux/extlinux.conf; fi; mw.l 0x02390028 0x80000000; reset'

fw_setenv preboot "$PREBOOT"
fw_setenv bootcmd "$BOOTCMD"
echo "=== env after ==="
fw_printenv | tee /root/rung2/fw_printenv.armed

echo "=== zero the pre-console buffer + debug scratchpad (0x480e8000, 32K) ==="
dd if=/dev/zero of=/dev/mem bs=4096 seek=295144 count=8 2>&1 | tail -1 || echo "  (zeroing failed -- read with care)"

echo "=== slot register before ==="
devmem 0x02390024
devmem 0x0239002C 32 0xFFFFF000    # clear milestone bits 12..31
devmem 0x0239002C 32 0x14          # clear SLOTA | SLOTA_BOOTABLE
devmem 0x02390028 32 0x28          # set   SLOTB | SLOTB_BOOTABLE
echo "=== slot register armed (expect 0x00000028) ==="
devmem 0x02390024
sync
