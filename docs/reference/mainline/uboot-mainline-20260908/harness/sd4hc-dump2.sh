#!/bin/sh
# Rung 2i (#89): the same register table U-Boot prints, taken from the WORKING
# side -- mainline Linux driving this eMMC as its rootfs -- so the two can be
# diffed register for register.
#
# eMMC (0x1B40000) ONLY. The SD slot at 0x104E0000 is never touched.
# 0x1900000 is the CPU system-global block: always on, and the block the
# first-stage loader programs the eMMC card clock in
# (boot/bl1/driver/mmc/axera_mmc.c, CPU_SYS_GLB + 0x0 / +0x4 / +0xC).
#
# Word loops only -- glibc memcpy on a /dev/mem mapping SIGBUSes (CLAUDE.md).
#
# `--phy` additionally reads the PHY delay registers back through the HRS04
# access port. That means WRITING HRS04 (address + the RD strobe) on a
# controller Linux is actively using for the rootfs. HRS04 is a control port
# and a read changes no PHY value, and the RD strobe is cleared again after
# each read -- but it is a poke at a live controller, so it is opt-in. Run the
# plain form first; add --phy only if the rest of the table does not explain
# the difference.
B=0x1b40000
GLB=0x1900000

echo "== emmc dump (linux) =="

printf 'SRS'
i=0
while [ $i -le 68 ]; do
  [ $i -ne 0 ] && [ $((i % 16)) -eq 0 ] && printf '\nSRS'
  printf ' %02x=%s' $i "$(devmem $((B + 512 + i)) 32 | sed 's/^0x//')"
  i=$((i + 4))
done

printf '\nHRS'
i=0
while [ $i -le 40 ]; do
  [ $i -ne 0 ] && [ $((i % 16)) -eq 0 ] && printf '\nHRS'
  printf ' %02x=%s' $i "$(devmem $((B + i)) 32 | sed 's/^0x//')"
  i=$((i + 4))
done

if [ "$1" = "--phy" ]; then
  printf '\nPHY'
  a=0
  while [ $a -le 13 ]; do
    [ $a -ne 0 ] && [ $((a % 8)) -eq 0 ] && printf '\nPHY'
    devmem $((B + 0x10)) 32 $a                    # ADDR, RD clear
    devmem $((B + 0x10)) 32 $((a | 0x2000000))    # + RD strobe (bit 25)
    v=$(devmem $((B + 0x10)) 32)
    devmem $((B + 0x10)) 32 $a                    # drop RD again
    printf ' %02x=%3d' $a $(( (v >> 16) & 0xff ))
    a=$((a + 1))
  done
fi

printf '\nGLB mux0=%s eb0=%s div0=%s\n' \
  "$(devmem $((GLB + 0x00)) 32 | sed 's/^0x//')" \
  "$(devmem $((GLB + 0x04)) 32 | sed 's/^0x//')" \
  "$(devmem $((GLB + 0x0c)) 32 | sed 's/^0x//')"

echo "== end =="
echo "decode: mux0 bits[6:5] = card clock source (3 = npll_400m)"
echo "        eb0  bit 2     = clk_emmc_card_eb"
echo "        div0 bits[5:0] = divider, bit 6 = update strobe"
echo "        SPL sets sel=3 div=1 -> 400/2 = 200 MHz"
