# eMMC and SD on a mainline kernel — 2026-09-06 (#76)

The second mainline milestone on this silicon: a kernel with no vendor code
enumerating the eMMC, parsing the vendor partition layout and reading the
rootfs. Captured from slot B, read back from slot A on the following boot, by
the [mainline-boot-test](../../../.claude/skills/mainline-boot-test/SKILL.md)
loop. There is no serial console on this unit — these are persistence channels,
not transcripts.

| File | Channel | Covers |
|---|---|---|
| `storage-boot-dmesg.txt` | log stash at `0x480e8000` | first printk → after the storage probe |
| `storage-boot-ramoops-console.txt` | ramoops console zone at `0x480e0000` | whole boot → `reboot: Restarting system` at t=123 s |
| `no-partition-parser-dmesg.txt` | log stash, **first run** | the failed run that diagnosed the missing partition parser |

Milestone register on return: **`0x0003F014`** — every bit, including the two
`#76` added (16 = partitioned block device, 17 = ext4 mounted and read).

## What this boot proves

- **Stock `sdhci-cadence` drives this controller.** Both instances bind:
  `mmc0: SDHCI controller on 1b40000.mmc` (eMMC) and `mmc1: SDHCI controller on
  104e0000.mmc` (SD). The only code this needed was a 14-line patch adding a
  compatible for `SDHCI_QUIRK2_PRESET_VALUE_BROKEN`.
- **The card negotiates HS200**: `mmc0: new HS200 MMC card at address 0001`,
  `mmcblk0: mmc0:0001 AT3SFB 29.1 GiB`, plus both boot partitions and rpmb.
  Note this happened *despite* the DT deliberately withholding
  `mmc-hs200-1_8v` — sdhci derives HS200 from CAPS1 SDR104 and the voltage
  bits, not from the DT. So the read-gap tuning storm the conservative
  `max-frequency` was hedging against does not occur on this silicon, and the
  hedge can be lifted.
- **The clock rows work.** The eMMC and SD card clocks come from the #80 driver
  (extended by #76), and `clk: Disabling unused clocks` runs *before* the card
  enumerates without turning any of them off — which is the `CLK_IS_CRITICAL`
  marking on the bus gates doing its job. Those gates cannot be named in DT,
  because `cdns,sd4hc` allows exactly one clock.
- **No resets, and none needed.** No mmc node carries a `resets` property. The
  controller works because firmware leaves the three SoC reset lines
  deasserted, exactly as both behavioural specs predicted independently.
- **`blkdevparts=` is honoured.** All 17 partitions appear with the vendor's
  sizes, `mmcblk0p17` at major 179 / minor 17.
- **ext4 reads.** Mounted read-only, 34 root entries, unmounted cleanly. The
  eMMC was never written.
- **The watchdog still holds** with storage in the picture: `timeleft=28`
  steady across all twelve 10 s samples, then a clean restart at t=123 s.

## The first run, and why it is kept

`no-partition-parser-dmesg.txt` is the run that failed, and it is the more
instructive artifact. Storage worked perfectly on the first attempt — same
HS200 card, same 29.1 GiB — but `/proc/partitions` held only `mmcblk0`,
`mmcblk0boot0` and `mmcblk0boot1`. The eMMC has no on-disk partition table; its
layout *is* the `blkdevparts=` clause U-Boot puts on the cmdline, and the kernel
said so:

```
Unknown kernel command line parameters "... blkdevparts=mmcblk0:768K(spl),..."
```

`CONFIG_BLK_CMDLINE_PARSER`, added in #74 for exactly this purpose, does not
exist in 7.x — it is the 4.19 name for `CMDLINE_PARTITION`, whose prompt is
`if PARTITION_ADVANCED`. `olddefconfig` drops an unknown symbol silently, and
the build's "fragment survived olddefconfig" assertion was a hand-maintained
list that did not include it. The assertion that existed to catch this exact
failure could not see it. It is now generated from the fragment itself and
checks every line.

## Two log-reading traps this run produced

- **The partition dump looked empty.** The probe wrote prefix, data and newline
  as three `write()`s, and every write to `/dev/kmsg` is a separate record — so
  a working eMMC was reported as four blank `part:` lines with the data
  orphaned in the records between them. One `write()` per line now. The
  original form is visible in `no-partition-parser-dmesg.txt` at records
  243–254.
- **`mmc0: invalid driver type, default to driver type B` is correct and should
  not be chased.** `fixed-emmc-driver-type` carries an eMMC-spec driver type
  (table 206; 4 = 40 Ω) but sdhci can only express the SD host types A/B/C/D =
  0..3. It warns and uses B while the *card* is still programmed to type 4
  through `EXT_CSD_HS_TIMING`. The vendor driver has the identical limitation,
  so keeping the property reproduces the vendor's proven electrical state.

## Not proven here

The SD slot. `mmc1` binds and the controller is healthy, but **there is no card
in the device** (`card_present` = 0 on the vendor system, and no `mmcblk1`
anywhere in this log), so nothing exercised it end to end. Rooting a mainline
system from SD — the half of #76 that gives #77 a shell — needs the card back
in the slot.
