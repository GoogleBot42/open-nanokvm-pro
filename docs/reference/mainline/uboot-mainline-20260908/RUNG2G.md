# Rung 2g, 2026-09-08: the bus is driven at the wrong voltage

**The cause is found and it is one line of upstream U-Boot.** The eMMC on this
board runs its I/O at 1.8 V; U-Boot drives it at 3.3 V, because
`sdhci_cdns_set_control_reg()` gates the only call that sets
`SDHCI_CTRL_VDD_180` behind `if (IS_SD(mmc))`.

**It is not fixed yet.** The route U-Boot offers to 1.8 V signalling runs
through HS200, and declaring HS200 hung the board — exactly as the Linux device
tree warns in the same node. The board is dark and needs a power cycle.

## The measurement

`/sys/kernel/debug/mmc0/ios` on the running Linux that drives this eMMC fine
([`emmc-bus-mode-20260908.txt`](emmc-bus-mode-20260908.txt)):

```
timing spec:    9 (mmc HS200)
signal voltage: 1 (1.80 V)      <-- this one
bus width:      3 (8 bits)
driver type:    4
clock:          50000000 Hz
```

It agrees with the register dump from rung 2f: the working controller has
`HOST_CONTROL2 = 0x3008`, and bit 3 of that is `SDHCI_CTRL_VDD_180`, set.

U-Boot never sets it:

- `sdhci_cdns_set_control_reg()` calls the generic `sdhci_set_control_reg()`
  only `if (IS_SD(mmc))`.
- That generic function is `sdhci_set_voltage()` + `sdhci_set_uhs_timing()`, and
  `sdhci_set_voltage()` is the only writer of `SDHCI_CTRL_VDD_180` in the driver.
- `CONFIG_MMC_IO_VOLTAGE` was not even enabled, so the function was compiled out.

CMD is one line and tolerant enough to survive the wrong level — the card
identifies, its CSD reads, speed switches succeed. Eight data lines are not.
**That is why the failure survived every change to DMA, transfer length, bus
width, clock and PHY delays: none of them is the level the bus is driven at.**

### Correcting rung 2f

RUNG2F.md listed this gate as excluded. The check made there was that
`sdhci_set_ios()` writes `SDHCI_CTRL_8BITBUS` and `SDHCI_CTRL_HISPD`
generically — true, which made the gate look harmless. It is not: the same
skipped call also sets the signal voltage, and nothing else does.

## Two other things measured, both corrections

**The firmware does not leave a tuned PHY.** Rung 2f inferred, from Linux
showing `HRS06 = 0x00001004` (MODE 4, TUNE 0x10), that the boot firmware left a
tuned value U-Boot was discarding. Wrong: U-Boot's own probe reports

```
mmc@1b40000:  firmware HRS00 00010000 HRS02 00030000 HRS06 00000006
mmc@104e0000: firmware HRS00 00010000 HRS02 00030000 HRS06 00000000
```

`HRS06 = 0x06`, TUNE zero. The `0x1004` is **Linux's own** configuration,
written after it selected HS200 and tuned. Freezing HRS06 at the firmware value
made things worse — the card stopped identifying at all
(`Card did not respond to voltage select! : -110`), because MODE has to follow
the bus during identification. That experiment is reverted.

**The cardless SD slot at `0x104E0000` is clocked.** It reports its HRS words
from U-Boot without hanging, so the AXI worry rung 2f raised about it does not
apply here. What hung rung 2f was a dump in `sdhci.c`'s data-timeout path, not
the second controller.

## What is in the tree

Two upstream-shaped patches, both defensible on their own merits, neither
sufficient alone:

- **0007, `mmc: support the fixed-emmc-driver-type device tree property`.**
  U-Boot has never read it; Linux has since 4.10. This board's Linux DT sets
  type 4 (40 ohm) and the comment there says dropping it "would change the
  card's drive strength". Now parsed in `mmc_of_parse()` and OR'd into
  `EXT_CSD_HS_TIMING`. Measured on hardware: no change by itself.
- **0008, `mmc: sdhci-cadence: program Host Control2 for eMMC too`.** Removes
  the `IS_SD` gate. Plus `CONFIG_MMC_IO_VOLTAGE=y` in the defconfig so
  `sdhci_set_voltage()` exists at all.

And one thing deliberately **not** in the tree: `mmc-hs200-1_8v` on the eMMC
node. It is what would actually make U-Boot switch to 1.8 V — and it hung the
board. The node now carries a commented-out property and the reason.

## Why HS200 hung, and what the next step is

U-Boot switches signalling to 1.8 V only along its HS200 path
(`mmc_select_hs200()` → `mmc_set_signal_voltage(MMC_SIGNAL_VOLTAGE_180)`).
There is no DT knob for "this eMMC is 1.8 V" independent of speed mode. So
declaring HS200 was the only lever available — and HS200 requires tuning.

`dts/ax630c.dtsi` warns about precisely this, in this node, and the warning was
right:

> Mainline runs a read-gap tuning step over HRS37/HRS38 (0x94/0x98) for HS200+,
> and those registers appear in NO AX630C source — not the vendor kernel, not
> the SPL, not U-Boot. If they are unimplemented the tuning loop degrades
> harmlessly, but a 16-iteration retry storm could outlast U-Boot's 30 s
> watchdog and look exactly like a crash on a board with no console.

The board went dark and stayed dark through thirteen minutes of bounded
polling. **Weight that comment properly next time**: it named the failure mode
and the cost before the experiment ran.

**Next, and it is a small piece of work:** get the bus to 1.8 V without HS200
tuning. Two candidates, in order:

1. **A `vqmmc-supply` regulator in the DT.** `sdhci_set_voltage()` already
   drives `mmc->vqmmc_supply` under `DM_REGULATOR`; a fixed 1.8 V regulator on
   the eMMC node, with `CONFIG_DM_REGULATOR_FIXED`, would let the core set the
   level without a speed-mode change. Needs `mmc->signal_voltage` to be 180,
   which still comes from mode selection — so check that path first.
2. **A DT property or match-data flag meaning "this eMMC is fixed 1.8 V"**,
   setting `mmc->signal_voltage = MMC_SIGNAL_VOLTAGE_180` at probe. Upstream
   would want a good name; `mmc-fixed-signal-voltage-180` or a
   `no-1-8-v`-shaped inverse. This is the honest description of the hardware:
   the rail is 1.8 V regardless of speed.

Either lands with patch 0008 already in place and does not need HS200.

## Device state — NEEDS A POWER CYCLE

A power cycle lands on slot A: the SPL consumed `SLOTB_BOOTABLE` and the slot
register clears on power loss. Slot A, `p3`, `p5`, `p12`, `p14` and the rootfs
have never been written in any rung.

Nothing can be read from this run afterwards — the register and DRAM both go
with the power, which is the rule rung 2e recorded. The last evidence obtained
was from the run before it, banked above.

On the device, all reversible, `/root/rung2/restore.sh` ready:

- `uboot_b` (p6): the rung-2g HS200 build. `restore.sh` puts back the vendor
  image, md5 `1521dc39f8a50e726c708fde2c8edce2` over 1 536 KiB.
- p7: `preboot` and `bootcmd` set by `arm-slotb.sh` for the run — both invisible
  to the vendor U-Boot on slot A. `p7-env.orig` restores it exactly.
- `/boot` (p16): `Image`, the dtb and `extlinux/*.conf` carrying
  `boot.panic_on_fail panic=10`.

## The environment question, still open

The env read still fails (`Transfer data timeout`), so U-Boot still falls back
to its built-in default and the stored p7 environment is still never imported.
The rung-2 shared-env question therefore remains untestable until the eMMC data
path works. `arm-slotb.sh` now sets `preboot` and `bootcmd` explicitly anyway,
so the run behaves identically whether the env loads or not — and the stored
env was captured to `/root/rung2/fw_printenv.before` before each run.
