#!/bin/sh
# One-shot open ISP bring-up on a base-only boot (device-proven sequence, 2026-09-01):
# clocks -> deassert-all -> quiesce -> pulse -> top gate 0x158 -> M1 -> vendor D-PHY/CSI deltas -> replay.
set -u
cd /root/axbring
L=bringup.log; : > $L
say() { echo "$*" | tee -a $L; sync; }
echo 0 > /proc/sys/kernel/panic_on_oops
say "phase 0: baseline"; ./ispbring st | tee -a $L
say "phase 1: clocks"; ./ispbring p1 20 | tee -a $L; ./ispbring mux | tee -a $L; ./ispbring gates 0x3f 0x3fe | tee -a $L
say "phase 2: deassert-all"; ./ispbring de0 0xffffffff | tee -a $L; ./ispbring de1 0x006fffff | tee -a $L
say "phase 3: quiesce+pulse"; ./ispbring axiq | tee -a $L
for b in $(seq 0 31); do ./ispbring p0 $b >> $L; done; sync
./ispbring axiz | tee -a $L
say "phase 4: top gate"; ./ispbring w 0x02400158 0x8007 | tee -a $L; ./ispbring r 0x02400150 | tee -a $L
./ispbring st | tee -a $L
if [ "${1:-}" = "nom1" ]; then say "stop before M1"; exit 0; fi
say "phase 5: M1"; dmesg -C; insmod ./open_vin_csi2.ko start_on_probe=1; sleep 1; dmesg | grep open_vin | tee -a $L
./ispbring r 0x02500000 | tee -a $L
if [ "${1:-}" = "m1only" ]; then say "stop after M1"; exit 0; fi
say "phase 6: vendor front-end deltas"
./ispbring w 0x023f0034 0x0005c540 | tee -a $L
./ispbring w 0x023f0038 0x00000820 | tee -a $L
./ispbring w 0x023f0048 0x00013f3f | tee -a $L
./ispbring w 0x02600020 0x0000000e | tee -a $L
./ispbring w 0x02600060 0x20000000 | tee -a $L
./ispbring w 0x02600104 0x80000133 | tee -a $L
./ispbring w 0x02600110 0x00000010 | tee -a $L
./ispbring r 0x02500000 | tee -a $L
say "phase 7: replay"; ./replay regfile-vendor-live.bin 0x7C000000 y480.raw 2>&1 | tee -a $L
./ispbring st | tee -a $L
say "done"
