#!/bin/sh
# Does the AX630C DDR window alias above 1 GiB?  Probe from Linux through
# /dev/mem, inside the reserved bring-up-log page (0x480ee000) so nothing the
# kernel owns is touched.  A = 0x480ee000, and its +1 GiB / +2 GiB images.
A=0x480ee000
B=0x880ee000
C=0xc80ee000

echo "--- baseline ---"
devmem $A 32 0xAAAA1111
echo "A after write A: $(devmem $A 32)"

echo "--- write +1GiB image ---"
devmem $B 32 0xBBBB2222
echo "B reads: $(devmem $B 32)"
echo "A reads: $(devmem $A 32)   (== 0xBBBB2222 means a 1 GiB alias)"

echo "--- restore A, write +2GiB image ---"
devmem $A 32 0xAAAA1111
devmem $C 32 0xCCCC3333
echo "C reads: $(devmem $C 32)"
echo "A reads: $(devmem $A 32)   (== 0xCCCC3333 means a 2 GiB alias)"

echo "--- top-of-DRAM page, the one setup_pgtables writes ---"
for a in 0x7fff0000 0x7ffff000 0x7ffffff0; do
  devmem $a 32 0xD00D0000
  echo "$a reads: $(devmem $a 32)"
done
