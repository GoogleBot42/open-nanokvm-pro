# Rung 2p -- the FDT lands correctly, and the retry has to re-init the card (#89)

2026-09-08. Five rounds against a budget of four. Row 2 is still not done: the
kernel starts and does not reach the network. Three things were settled.

## The FDT fix works

Patch `0018` puts `fdt_high` and `initrd_high` at `0x5f000000` in the built-in
environment. Measured on the next boot:

```
   Loading Device Tree to 000000005effa000, end 000000005effff58 ... OK
Starting kernel ...
```

`0x5effa000` is just under the ceiling and inside the `mem=512M` window, against
`0x7e68c000` before. Placement no longer depends on `ram_top` in either
direction.

## Retries only work if they re-initialise the card

The same patch wrapped the payload reads in three attempts. That is not enough,
and the console shows why:

```
Error reading cluster
Failed to load '/extlinux/extlinux.conf'
Error reading cluster
Failed to load '/extlinux/extlinux.conf'
1375 bytes read in 24 ms (55.7 KiB/s)
```

Two failures then a success -- on a **1375-byte** file, three single blocks. The
failures are not spread evenly across blocks; they are bursty, because a
DATA_TIMEOUT poisons this controller and afterwards even CMD16 fails (rung 2k).
U-Boot's per-command `SDHCI_RESET_CMD` / `SDHCI_RESET_DATA` does not clear it, so
a bare retry runs into the same wall.

Putting `mmc rescan` -- which re-runs `mmc_init()` -- in front of each attempt
fixes it. With

```
bootone = mmc rescan; mw.l ${msreg_set} ${ms_extlinux}; sysboot mmc ...
bootcmd = run bootone || run bootone || run bootone || run bootone; mw.l ${msreg_set} ${ms_failed}; reset
```

the boot read `extlinux.conf`, the 48.8 MiB kernel and the dtb, and handed off:
slot register `0x30000015` -- bits 28 and 29, **no failure bit** -- so `sysboot`
never returned. **This belongs in the built-in `bootcmd`**; it is currently only
in the stored environment.

## `mem=512M` cannot simply be dropped

Removing it left the board dark for seventeen minutes **with no watchdog reset**,
where the identical configuration with `mem=512M` reset itself at 337 s every
time. A hang that also defeats WDT0 is what the AXI-stall failures look like on
this SoC. The reserved-memory nodes are all inside the first 512 MB as expected,
so whatever is up there is not described in the device tree -- a TrustZone or
TZASC-protected region would not be. The appliance does run on half its RAM
(`free -m` total 428 MB), and that is worth fixing, but **not by deleting the
argument and hoping**: rung 3 should find where the vendor U-Boot injects it and
what it is protecting before changing it.

## What still fails

With the FDT correct, the payload loaded and `sysboot` handed off, the kernel
starts and then:

- with the watchdog node disabled + `clk_ignore_unused`, it is reset at 337 s
  and `/sys/fs/pstore` is **empty** -- it dies before ramoops probes;
- with the stock dtb (watchdog enabled, no `clk_ignore_unused`), it goes dark
  and stays dark, because `ax630c_wdt` stops WDT0 at probe.

The second case is not a worse outcome -- it means the kernel reached the
watchdog probe, which is much later than "before ramoops". It is just
unobservable, and that is the trap to design around next time: the two channels
are mutually exclusive as things stand.

## A round lost to the environment

Round 4 tested nothing. The console said so:

```
Unknown command 'axera_boot' - try 'help'
ax630c#
```

**The vendor U-Boot on slot A rewrites `bootcmd=axera_boot` and saves it on
every boot.** Any run that arms slot B without re-setting the environment first
inherits that, and mainline U-Boot sits at its prompt until the watchdog fires.
`arm-slotb.sh` does the re-set; a hand-rolled arm sequence must too.

## Files

- `rung2p-fdt-20260908.txt` -- consoles and registers per round.
