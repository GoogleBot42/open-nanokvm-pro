# Rung 2l -- v4 mode, HS400ES and CMD23, and the read matrix that survives them (#89)

2026-09-08. Six hardware rounds, three of them dark (the intermittent pre-
`arch_cpu_init` hang from rung 2k). Three real driver gaps closed, all verified
live on hardware, none of which fixes the multi-block failure.

## The clean statement of the bug

From the last round, on a freshly identified card, in HS400ES, with v4 mode on
and Auto CMD23 accepted by the card:

| read | result | command | status |
|---|---|---|---|
| LBA 0, 1 block | **pass** | `113a0013` CMD17 | `00000000` |
| LBA 0, 2 blocks | fail | `123a003b` CMD18 | `00108000` DATA_TIMEOUT |
| LBA 0x2600, 1 block | **pass** | `113a0013` CMD17 | `00000000` |
| LBA 0x2600, 2 blocks | fail | `123a003b` CMD18 | `00108000` DATA_TIMEOUT |

**Single-block reads work at any address. Two-block reads fail at any address.**
Not the address, not the size, not the DMA engine, not the bus mode, not the
stop convention.

## What was ruled out this rung

**Host Version 4 mode** (new patch `0013`). U-Boot had no notion of it at all --
`SDHCI_CTRL_V4_MODE` did not exist, `SDHCI_SPEC_400` appeared only as a version
constant. The controller reports `SDHCI_HOST_VERSION = 0x0003`, which is spec
4.00 (read from Linux at `0x01B402FE`, and confirmed on the U-Boot side as
`SRS fc = 0x00030000`), and Linux drives it with `HOST_CONTROL2 = 0x3008`.
U-Boot now runs it at `0x1008`. **No change to the failure.**

One dead end inside that, worth recording because it looked exactly right: the
first version also moved the block count to the 32-bit register at
`SDHCI_32BIT_BLK_CNT` and zeroed the 16-bit one, on the theory that a controller
implementing only the v4 count path would see zero blocks for CMD18 and never
start. It fits the evidence perfectly and it is wrong: the 32-bit block count is
a **4.10** feature that Linux uses only behind `SDHCI_QUIRK2_USE_32BIT_BLK_CNT`.
On this 4.00 part it broke identification outright -- `re-init -70`, `No block
device`, dying at the first EXT_CSD read, because now *every* transfer had a
block count of zero. The register trace says so plainly: `SRS 00 = 00000001`
with `SRS 04 = 00007200`, the 16-bit count zeroed.

**HS400 Enhanced Strobe** (new patch `0014`). The first-stage loader hands over
with `HRS06 = 0x06`, which is HS400ES, and that is the one mode in which
anything on this board has been observed to do a multi-block read. Two driver
gaps stood in the way: `SDHCI_CDNS_HRS06_MODE_MMC_HS400ES` is defined in
`sdhci-cadence.h` and never used (`MMC_HS_400_ES` shared the plain HS400 arm of
the mode switch), and with no `.set_enhanced_strobe` op `mmc_select_hs400es()`
fails at its last step with `-ENOTSUPP`, so the mode was unreachable. Both
fixed; U-Boot now reports `mode 12` and writes `HRS06 = 0x00000006`, byte for
byte the loader's own state. **No change to the failure.**

**Auto CMD23** (new patch `0015`). U-Boot issues every multi-block transfer
open-ended: no CMD23 in front, no auto command, a hand-sent CMD12 afterwards.
In v4 mode SDHCI can send CMD23 itself, with the count in the register that
doubles as its argument. Now `TRANSFER_MODE = 0x003b` (`AUTO_CMD23` set),
`SRS 00 = 0x00000002` is the argument, and `SRS 1c = 0x00000900` is the
auto-command response -- **the card received CMD23 and answered R1 from TRAN**.
The core's own CMD12 is suppressed when the host closes the transfer itself,
which is also why reads three and four now succeed instead of being collateral
damage from a hand-sent stop to a card the controller had already stopped.
**No change to the failure.**

## The whole exclusion list, after four rungs

| axis | tried | result |
|---|---|---|
| sampling phase | 32-34 of 40 tuning points pass (rung 2j) | excluded |
| base clock | 200 MHz both sides, `mux0 0x73` / `div0 1` | excluded |
| PHY delays | identical to Linux for every register either driver writes | excluded |
| bus width | 4-bit and 8-bit | excluded |
| signal voltage | `VDD_180` set, matches Linux | excluded |
| addressing | CMD17 passes at LBA 0 and 0x2600, R1 clean everywhere | excluded |
| transfer size | 1 MiB and 1 KiB fail alike; 512 B passes | excluded |
| DMA engine | ADMA2 32-bit, ADMA2 96-bit, SDMA, PIO | excluded |
| ADMA chunking | 65532 vs block-aligned 65536 | excluded |
| stop convention | none, Auto CMD12, Auto CMD23 | excluded |
| bus mode | HS SDR, HS200, HS400ES | excluded |
| host mode | v3, v4 | excluded |

What is left is the last piece of Linux's configuration that U-Boot still does
not reproduce: `HOST_CONTROL2` bit 13, 64-bit addressing, with the **128-bit v4
ADMA2 descriptor** it implies. U-Boot's `USE_ADMA64` is not that -- its
descriptor is 12 bytes, the 96-bit v3 format, which is why `0013` deliberately
sets only bit 12. Implementing the v4 descriptor is the next thing to try, and
it is the last item on the match-Linux list.

## Files

- `rung2l-reads-20260908.txt` -- the four-read matrix per round, the failed
  32-bit-block-count round, and the register dumps.
