#!/bin/sh
# Bring the VENDOR encoder stack up at RUNTIME on the open image (#64 HEVC
# campaign). Nothing persistent changes: the on-disk loader stays the open one,
# so any reboot returns to the open stack. Minimal set: ax_sys, ax_cmm (with the
# vendor's own cmmpool parameter), ax_pool, ax_base, ax_venc.
D=/root/hevc64
set -x
systemctl stop nanokvm nanokvm-display
sleep 1
lsmod | grep -q '^open_vin_capture' && rmmod open_vin_capture
lsmod | grep -q '^open_vin_csi2' && rmmod open_vin_csi2
lsmod | grep -q '^ax630c_venc_vcmd' && rmmod ax630c_venc_vcmd
# cmmpool param exactly as the vendor loader computes it on this board:
# mem=824M, 1G board -> pool 0x73800000, 200M
CMM="cmmpool=anonymous,0,0x73800000,200M"
grep -q 'mem=824M' /proc/cmdline || { echo "!! unexpected mem= in cmdline; refusing"; exit 9; }
insmod $D/ko/ax_sys.ko || exit 1
insmod $D/ko/ax_cmm.ko $CMM || exit 1
insmod $D/ko/ax_pool.ko || exit 1
insmod $D/ko/ax_base.ko || exit 1
insmod $D/ko/ax_venc.ko || exit 1
lsmod | grep '^ax_'
ls -la /dev/ax_venc /dev/ax_cmm /dev/ax_sys /dev/ax_pool 2>&1
cat /proc/ax_proc/mem_cmm_info | head -20
