#!/bin/sh
# rung 2 (#89): read every evidence channel back from slot A.
echo "=== slot register ==="
devmem 0x02390024
echo "=== debug scratchpad 0x480ec000 (word 0 must read 0x55424D31) ==="
i=0
for name in magic tlb_addr_lo tlb_addr_hi tlb_size relocaddr ram_top ram_size start_sp reloc_off gd flags; do
  printf '%-12s %s\n' "$name" "$(devmem $((0x480ec000 + 4 * i)) 32)"
  i=$((i + 1))
done
echo "=== pre-console buffer 0x480e8000 ==="
dd if=/dev/mem bs=4096 skip=295144 count=2 2>/dev/null | tr -d '\000'
echo
echo "=== uname / cmdline ==="
uname -r
cat /proc/cmdline
