# First mainline boot on the AX630C — 2026-09-06 (#75)

The first time a kernel other than Sipeed's 4.19 vendor tree has run on this
silicon. Captured from slot B, read back from slot A on the following boot.

Both files are the same boot (the third of three runs that day; the first two
differed only in the `/dev/kmsg` ratelimit fix and the dwell length, and
produced identical boot behaviour). Neither is a transcript of a console —
there is no serial console on this unit. They are the two persistence channels
described in [../../mainline-port.md](../../mainline-port.md) §8.

| File | Channel | Covers |
|---|---|---|
| `mainline-first-boot-dmesg.txt` | log stash at `0x480e8000`, written by `/init` | `/dev/kmsg` records, first printk → the moment `/init` copied them (t≈1.16 s) |
| `mainline-first-boot-ramoops-console.txt` | ramoops console zone at `0x480e0000` | the whole boot, t=0 → `reboot: Restarting system` at t=122 s |

The stash is in `/dev/kmsg` record format (`<level>,<seq>,<usec>,-;text`); the
ramoops zone is plain console text. The stash stops earlier by construction —
it is written before the dwell so that a board that dies mid-dwell still leaves
it behind — and the ramoops zone covers the rest.

## What this boot proves

- **The kernel runs.** Both A53s up, `Machine model: Sipeed NanoKVM-Pro`,
  the three `reserved-memory` regions honoured, `Run /init as init process`.
- **The watchdog driver works, and that is the whole point of #75.** U-Boot
  arms wdt0 for 30 s per stage immediately before `booti`; this boot lived
  **122 seconds** and then rebooted on purpose. `ax630c-wdt 4840000.watchdog:
  instance 0 at 24000000 Hz, timeout 60s, max 357s`, and the twelve `alive Ns`
  lines each report `watchdog0 state=inactive timeleft=29` — the countdown
  never decays across a 10 s sample, which is the watchdog core petting the dog
  it adopted from the bootloader. `state=inactive` is correct: no userspace has
  opened `/dev/watchdog`, so the core is petting on `WDOG_HW_RUNNING` alone.
- **#80's clock and pin-control drivers survive a real boot.** `clk: Disabling
  unused clocks` is the clock framework running the tree to completion.
- **Reboot works without PSCI.** `reboot: Restarting system` is followed by an
  actual chip reset, from the `syscon-reboot` node on `CHIP_RST_SW`.
- **The slot machinery returns the board on its own.** `BACKUP0` read
  `0x0000f014` afterwards — milestone bits 12-15 all set, and `0x14` = slot A
  re-armed. Nothing here re-arms `SLOTB_BOOTABLE`, so the SPL failed back to
  slot A exactly as designed.

## What it does not prove

No storage, network, GPIO, USB or video driver is present (#76 onward). The
kernel reaches its initramfs and stops there. Nothing observed the watchdog
block reaching its second expiry stage, so "the reset lands at 2x the
programmed reload" is still inference — see
[../wdt-model-20260906.md](../wdt-model-20260906.md) §12.
