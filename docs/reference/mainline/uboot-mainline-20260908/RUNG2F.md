# Rung 2f, 2026-09-08: the SD4HC reference dump, and a dark board

Two outcomes, one good and one not.

**Good:** the Cadence SD4HC register file was read off the *working* controller
— mainline Linux driving this eMMC as its rootfs — and it excludes three of the
four candidates outright. Banked in
[`sd4hc-registers-20260908.txt`](sd4hc-registers-20260908.txt).

**Not:** the U-Boot-side dump that was supposed to be diffed against it never
came back. The board went dark and did not self-recover in nineteen minutes of
bounded polling. It needs a power cycle, and that cycle destroys the slot
register and DRAM, so this run's on-board evidence is gone before it can be
read. That is the failure mode rung 2e recorded as a standing rule, and it
caught this rung anyway.

## What the reference dump settles

| Candidate | Verdict | Evidence |
|---|---|---|
| Wrong base clock → wrong divider | **excluded** | CAPS0 base-clock field = `0xC8` = 200 MHz, and the CCF says `clk_emmc_card_eb` really is 200 MHz. U-Boot takes the base from CAPS0 and gets the right number; divider 2 then gives the DT's 50 MHz |
| Preset registers in use | **excluded** | `HOST_CONTROL2 = 0x3008`, bit 15 clear. And U-Boot never writes `SDHCI_CTRL_PRESET_VAL_ENABLE` — the constant appears only in `include/sdhci.h` — while `sdhci_init()` issues `SDHCI_RESET_ALL`, which clears the register |
| Bus width / high-speed never set for eMMC | **excluded** | `sdhci_cdns_set_control_reg()` calls the generic hook only `if (IS_SD(mmc))`, but that hook only does voltage and UHS timing; `sdhci_set_ios()` writes `SDHCI_CTRL_8BITBUS` and `SDHCI_CTRL_HISPD` itself for eMMC too |
| HRS06 / the firmware's PHY state | **the remaining suspect** | below |

## The remaining suspect, stated precisely

```
HRS00 0x00010000   HRS01 0x00000032   HRS02 0x00030000
HRS06 0x00001004   -> MODE[2:0] = 4, TUNE[13:8] = 0x10, TUNE_UP = 0
```

Upstream `sdhci-cadence` defines and touches **HRS04, HRS05 and HRS06 only**.
HRS00/01/02 are non-zero here and are therefore the first-stage loader's.

HRS06 is the one that matters. Upstream's `sdhci_cdns_get_hrs06_mode()` maps
`MMC_HS` to `SDHCI_CDNS_HRS06_MODE_MMC_SDR` = **2**. The working controller sits
at **MODE = 4** (`MMC_HS200`) with a non-zero **TUNE = 16** — a *tuned*
configuration — and our device tree declares no HS200 at all
(`cap-mmc-highspeed`, `max-frequency = 50 MHz`), so nothing in that mapping
produces 4 from this DT. **The value is the boot firmware's, and Linux is
running on top of it.**

That is consistent with what our own Linux patch already says:

> No init hook. The DLL reset pulse the vendor driver issues before writing PHY
> parameters is already performed by the boot firmware, which reads the kernel
> off this controller before Linux starts.

U-Boot's Cadence driver, by contrast, **recomputes the HRS06 mode from
`mmc->selected_mode` and writes it on every `set_ios`**, discarding the tuned
value — and it performs no tuning of its own for `MMC_HS`
(`MMC_SUPPORTS_TUNING` covers HS200/HS400). HRS06 selects the PHY data
sampling path. Commands work; data does not. The shapes match.

**The experiment that settles it, and it is one round:** leave HRS06 alone on
this SoC. Either an `axera,ax630c-sd4hc` compatible in U-Boot's
`sdhci-cadence.c` whose `set_control_reg` skips the HRS06 write, or a DT
property saying the firmware's PHY configuration is authoritative. If the eMMC
then reads, the diagnosis is confirmed and the fix is upstream-shaped.

## Why the board went dark, as far as can be said

The build that hung added two `printf` dumps inside `sdhci_cdns_probe` and one
in `sdhci.c`'s data-timeout path. The pointer arithmetic was checked afterwards
and is correct (`SDHCI_CDNS_SRS_BASE` is `0x200`, so `host->ioaddr - 0x200` is
the HRS base). Two things about it are still suspect and both have been removed:

1. The dump in the **data-timeout path** fires once per failed transfer, and
   there are many; it is the newest and least-proven code in the build. Gone.
2. The dump **after `sdhci_probe()`** reads the register file of a controller
   whose probe may have failed — including the SD slot at `0x104E0000`, which
   has no card and whose clock state under U-Boot is unverified. Reading an
   unclocked block on this SoC hangs the AXI bus (CLAUDE.md). The remaining
   instrumentation dumps only before `sdhci_probe()`, from `plat->hrs_addr`,
   which `devm_ioremap` has just mapped.

No previous slot-B failure in rungs 2 through 2e failed to self-recover; every
one of them reached `reset` or was reset by the SoC within ~65 s. This one did
not, which is itself evidence that the added code, not the port, is what hung.

## Device state — NEEDS A POWER CYCLE

A power cycle lands on slot A: the SPL consumed `SLOTB_BOOTABLE` and the slot
register clears on power loss. Nothing irreversible; slot A, `p3`, `p5`, `p12`,
`p14` and the rootfs have never been written in any rung.

On the device, all reversible, with `/root/rung2/restore.sh` ready:

- `uboot_b` (p6): the rung-2f console/dump build. `restore.sh` puts back the
  vendor image, md5 `1521dc39f8a50e726c708fde2c8edce2` over 1 536 KiB.
- p7: `preboot` and `bootcmd` were deleted before the run, so the environment
  is the vendor's own five variables. Nothing to undo.
- `/boot` (p16): `Image`, the dtb and `extlinux/*.conf` with
  `boot.panic_on_fail panic=10`. `restore.sh` returns it to the single `ver`.

## Next

1. Power-cycle. The register and DRAM are already lost, so there is nothing to
   read first this time — but the rule stands for every future dark board.
2. Run the HRS06 experiment above. It is one round and it is the whole
   remaining question.
3. If it reads: let the chain run to the appliance, with `boot.panic_on_fail`
   already in the banked `harness/extlinux.conf`.
