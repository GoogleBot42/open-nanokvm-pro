# Rung 2i -- the eMMC register table, U-Boot against Linux (#89)

2026-09-08. Five hardware rounds. The question: mainline U-Boot's Cadence SD4HC
enumerates the eMMC and every data transfer times out. Rung 2i takes one full
register dump from U-Boot and the same table from the running vendor Linux, and
diffs them.

## How the dump is taken

`ax630c_emmc_dump()` in `board_late_init()` (see `pkgs/uboot-mainline.nix`,
`consolePostPatch`), i.e. after the environment read has already failed, so the
failure is captured with the controller in its post-failure state. It clears
`GD_FLG_HAVE_CONSOLE` first so the table lands in the pre-console buffer at
`0x480e8000` and is read back from Linux after the next boot.

**Only `0x01B40000` (eMMC) is touched.** The SD slot at `0x104E0000` has no card
and is not clocked; reading it hangs the AXI bus and reboots the board -- that
cost rung 2f a dark run.

- SRS block: `0x01B40000 + 0x200`, offsets 0x00..0x44.
- HRS block: `0x01B40000`, offsets 0x00..0x28.
- PHY 0x00..0x0d through the HRS04 read strobe.
- SYS_GLB (`0x01900000`) eMMC card-clock mux/divider words.

## The measured diff

Final round (patches 0008 revised + 0012), U-Boot against Linux:

| Register | U-Boot | Linux | Verdict |
|---|---|---|---|
| SRS 0x04 blocks/size | `08007200` | -- | 2048 x 512 = the 1 MiB env read |
| SRS 0x0c cmd/mode | `123a0033` | -- | CMD18, DMA + block-count + read + multi |
| SRS 0x10 response | `00000900` | -- | card in TRAN, READY_FOR_DATA |
| SRS 0x24 present | `010f0000` | -- | CMD high, DAT[3:0] high, no transfer active |
| SRS 0x28 HOST_CONTROL | `0x34` | `0x34` | **now identical** (was `0x1e`, then `0x16`) |
| SRS 0x2c clock/timeout | `000e0207` | `000E0207` | identical -- divider 2, 50 MHz, timeout 0x0e |
| SRS 0x30 int status | `00108000` | `00000000` | ERROR_INTERRUPT + DATA_TIMEOUT_ERR |
| SRS 0x3c HOST_CONTROL2 | `0x0008` | `0x3008` | VDD_180 identical; **Linux adds V4_MODE + 64-bit** |
| SRS 0x40 / 0x44 CAPS | `176ac8b2` / `10000077` | same | base clock 0xC8 = 200 MHz |
| HRS06 | `0x1104` | `0x0f04` | both mode 4 (HS200); tune 17 vs 15 |
| PHY 0x00-0x0d | identical for every register either driver writes | | 0x06/0x09 are written by neither |
| GLB mux0 / div0 | `0x73` / `1` | `0x73` / `1` | **SDMCLK = npll_400m / 2 = 200 MHz, both sides** |

CAPS0 `0x176ac8b2`: bit 18 (`CAN_DO_8BIT`) is **clear**, bit 22 (`CAN_DO_SDMA`)
is set. CAPS1 `0x10000077`: SDR50/SDR104/DDR50 all set, which is where U-Boot's
`sdhci_setup_cfg()` promotes the eMMC to HS200 -- Linux's sdhci does the same
promotion, so HS200 is not by itself the difference.

## Two upstream bugs fixed, both register-confirmed

**`0008` (revised): the UHS timing field is SD-only, the signal voltage is not.**
Rung 2h removed the whole `if (IS_SD(mmc))` around `sdhci_set_control_reg()`,
which also made U-Boot write the standard UHS_MODE field for the eMMC --
HOST_CONTROL2 read `0x000b` (SDR104) where Linux reads `0x3008` (UHS_MODE 0).
Linux's sdhci-cadence deliberately never writes that field for eMMC: on this
controller the bus timing lives in HRS06. Split into an unconditional
`sdhci_set_voltage()` plus an `IS_SD()`-gated `sdhci_set_uhs_timing()`.
Measured: HOST_CONTROL2 `0x000b` -> `0x0008`, matching Linux's low bits exactly.

**`0012`: `sdhci_setup_cfg()` clears a DT-declared 8-bit bus.**

```c
	if (SDHCI_GET_VERSION(host) >= SDHCI_SPEC_300) {
		if (!(caps & SDHCI_CAN_DO_8BIT))
			cfg->host_caps &= ~MMC_MODE_8BIT;
	}
```

`mmc_of_parse()` has already set `MMC_MODE_8BIT` from `bus-width = <8>`, and
this takes it away again. For a soldered eMMC that is backwards: how many data
lines are routed is a board fact that only the device tree knows, and Linux's
sdhci only ever ORs `MMC_CAP_8_BIT_DATA` in. This controller advertises no
8-bit support while the NanoKVM-Pro wires all eight lines and Linux runs it
8-bit. Measured: HOST_CONTROL `0x16` -> `0x34`, byte-identical to Linux.

## Still failing, and what the diff no longer explains

Every data transfer still ends in `Transfer data timeout` /
`fs_devread read error`. What the registers say about that failure:

- The card is in TRAN and answered CMD18 (`SRS 0x10 = 0x00000900`).
- DAT[3:0] read high and no transfer is active (`SRS 0x24 = 0x010f0000`).
- The only error is DATA_TIMEOUT (`SRS 0x30` bit 20). **Not** an ADMA error --
  so the descriptor table is being fetched and parsed without complaint.
- Host and card clock, timeout counter, bus width, driver type, signal
  voltage, PHY delays and HRS06 mode are now all identical to the working
  Linux side.

Two differences survive, and neither is a "flip this register" fix:

1. **V4 mode.** Linux sets HOST_CONTROL2 bits 12 and 13 (Host Version 4 mode
   plus 64-bit addressing) and runs 64-bit ADMA2 descriptors. Mainline U-Boot
   has no V4-mode support whatsoever -- `SDHCI_CTRL_V4_MODE` does not exist in
   `include/sdhci.h`, and `SDHCI_SPEC_400` appears only as a version constant.
2. **HRS06 tune 17 vs 15.** U-Boot's `sdhci_cdns_execute_tuning()` sweeps the
   tuning points with real CMD21 reads and reports a window, so *some* data
   transfer is completing during identification; the value it settles on moved
   from 15 to 17 when the bus went 4-bit -> 8-bit.

## The PIO round (round 5, dark)

To separate "the descriptor format is wrong" from "the bus is wrong", one round
dropped `CONFIG_MMC_SDHCI_ADMA` from the defconfig. With `MMC_SDHCI_SDMA` also
unset that leaves the pure PIO path. The board **hung** -- no reset, no
milestone, and the power cycle that recovered it destroyed the pre-console
buffer, so the run banked nothing. The ADMA-versus-bus question is therefore
still open; the defconfig is back to ADMA + `ADMA_FORCE_32BIT`, which is what
the tree builds and what rounds 3 and 4 were measured on.

## Method notes worth keeping

- **`tools/kvmssh`'s pre-probe can lie.** It skips an IP when
  `bash -c "echo > /dev/tcp/$ip/22"` fails, and that redirection is blocked in
  some sandboxes -- reporting `tcp/22 unreachable` for a board that is up and
  answering. One healthy board was power-cycled on that false negative, costing
  the pre-console buffer of a completed run. Confirm with a second probe
  (`socat - TCP:$ip:22 </dev/null` returns the SSH banner) before calling a
  board dark.
- The vendor U-Boot on slot A rewrites `bootcmd` back to `axera_boot` and saves
  it, so the mainline `bootcmd` has to be re-set before **every** armed run.
- A power cycle clears the slot register and DRAM. Everything volatile --
  slot register, pre-console buffer, pstore -- must be read before cycling, and
  a hung board therefore banks nothing. Evidence for a run that can hang has to
  land in eMMC.

## Files

- `emmc-registers-rung2i-20260908.txt` -- the U-Boot console + register table,
  verbatim from the pre-console buffer, for the 8-bit round.
