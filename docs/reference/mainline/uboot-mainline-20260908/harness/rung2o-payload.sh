#!/usr/bin/env bash
# Rung 2o (#89): build the slot-B payload for booting the NixOS appliance under
# mainline U-Boot. Run from the repo root; leaves everything in $OUT.
#
# The kernel and dtb come straight from the flake and are byte-identical to
# what the flashed board runs from slot A -- root is p17 and needs no staging.
#
# The dtb copy disables the watchdog node so ax630c_wdt does not stop WDT0 at
# probe. That MUST be paired with clk_ignore_unused on the cmdline: with no
# consumer, clk_wdt0_eb is gated off by clk_disable_unused at late_initcall and
# the counter stops, which is exactly as unobservable as letting the driver
# stop it.
set -euo pipefail
OUT=${1:?usage: rung2o-payload.sh <outdir>}
mkdir -p "$OUT"

nix build .#kernel-mainline-appliance -o "$OUT/.krn"
nix build .#dtb-mainline             -o "$OUT/.dtb"
cp -L "$OUT/.krn/Image" "$OUT/Image"
cp -L "$OUT/.dtb/dtb/ax630c-nanokvm-pro.dtb" "$OUT/ax630c-nowdt.dtb"
chmod +w "$OUT/ax630c-nowdt.dtb"
nix shell nixpkgs#dtc --command \
  fdtput -t s "$OUT/ax630c-nowdt.dtb" /soc/watchdog@4840000 status disabled
nix shell nixpkgs#dtc --command \
  fdtget "$OUT/ax630c-nowdt.dtb" /soc/watchdog@4840000 status
md5sum "$OUT/Image" "$OUT/ax630c-nowdt.dtb"

cat <<'NOTE'

Now, on the device:
  dd the stopgap U-Boot to /dev/mmcblk0p6 and verify from the medium
  cp Image ax630c-nowdt.dtb to /boot, extlinux.conf to /boot/extlinux/

bootcmd (stored env). fdt_high is the load-bearing part: WITHOUT it U-Boot
relocates the FDT against its own ram_top -- the real 1 GiB -- and parks it at
~0x7e68c000, outside the mem=512M the kernel is told about, so the kernel dies
before any console. With it set to ~0 U-Boot warns the DT ends up misaligned.
A real ceiling below the kernel's limit is what the variable is for:

  setenv fdt_high 0x5f000000; setenv initrd_high 0x5f000000;
  mw.l 0x02390028 0x10000000;
  load mmc 0:10 0x4a000000 /Image || load ... || load ...;
  load mmc 0:10 0x49200000 /ax630c-nowdt.dtb || ... ;
  mw.l 0x02390028 0x20000000;
  setenv bootargs '<the board's own /proc/cmdline> boot.panic_on_fail=1 panic=10 clk_ignore_unused';
  mw.l 0x02390028 0x40000000;
  booti 0x4a000000 - 0x49200000;
  mw.l 0x02390028 0x80000000; reset

The retries are not paranoia: single-block reads under the #91 stopgap have a
residual failure rate, and the kernel is ~100 000 of them.
NOTE
