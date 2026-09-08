#!/bin/sh
# Rung 2f: the SD4HC register file on the WORKING controller (Linux, mainline,
# reading this eMMC right now). Word loops only -- glibc memcpy on a /dev/mem
# mapping SIGBUSes (CLAUDE.md). The controller is in the flash domain and
# clocked, so these reads are safe.
B=0x1b40000
echo "=== HRS block (0x000..0x0FF) ==="
i=0
while [ $i -lt 256 ]; do
  printf 'HRS+%03x ' $i
  devmem $((B + i)) 32
  i=$((i + 4))
done

echo "=== SRS block (0x200..0x2FF) = standard SDHCI ==="
i=512
while [ $i -lt 768 ]; do
  printf 'SRS+%03x (sdhci %02x) ' $((i - 512)) $((i - 512))
  devmem $((B + i)) 32
  i=$((i + 4))
done

echo "=== decoded ==="
echo "SRS10/11 hostctl+clock (sdhci 0x28): $(devmem $((B + 512 + 0x28)) 32)"
echo "SRS11    clockctl      (sdhci 0x2c): $(devmem $((B + 512 + 0x2c)) 32)"
echo "SRS15    hostctl2+..   (sdhci 0x3c): $(devmem $((B + 512 + 0x3c)) 32)   <- high half is HOST_CONTROL2; bit 15 of it = PRESET_VAL_ENABLE"
echo "SRS16    CAPS0         (sdhci 0x40): $(devmem $((B + 512 + 0x40)) 32)"
echo "SRS17    CAPS1         (sdhci 0x44): $(devmem $((B + 512 + 0x44)) 32)"

echo "=== card clock from CCF ==="
mount -t debugfs none /sys/kernel/debug 2>/dev/null
grep -iE "sd|emmc|mmc" /sys/kernel/debug/clk/clk_summary 2>/dev/null | head -20
