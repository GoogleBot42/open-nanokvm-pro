#!/bin/sh
# Is the ~65 s slot-B reset a HANG, or the previous boot's WDT0 biting?
# Nothing in the slot-B chain arms a watchdog before `preboot`, so if WDT0
# survives the chip reset with its timeout loaded, every slot-B attempt has
# been cut off at one 60 s period regardless of what U-Boot was doing.
#
# Stretch it to ~300 s (two 150 s stages) and re-run. Same failure at ~65 s =>
# a real hang. Progress past it => the resets were the watchdog.
echo "WDT0 before: EN=$(devmem 0x04840000 32) TORR=$(devmem 0x0484000c 32)"
devmem 0x0484000c 32 0xD693        # (150 s * 24 MHz) >> 16
devmem 0x04840018 32 1
devmem 0x04840018 32 0
echo "WDT0 after:  EN=$(devmem 0x04840000 32) TORR=$(devmem 0x0484000c 32)"
cat /sys/class/watchdog/watchdog0/timeleft
