# Rung 2j -- the tuning window, measured (#89)

2026-09-08. Six hardware rounds. The hypothesis under test: U-Boot picks HRS06
tune 17 where Linux picks 15, and a tune value that passes one 128-byte CMD21
block but fails a 1 MiB CMD18 is what an edge-of-window pick looks like.

**It is not.** The sweep was instrumented to print its own pass/fail map, and
the window is enormous:

```
cdns tune opcode 21 map XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX...... streak 34 end 33 pick 16
cdns tune opcode 21 map XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX........ streak 32 end 31 pick 15
```

Two runs of the same image. **Tuning points 0 to 31 (or 33) all pass; only the
top 6 to 8 of the 40 fail.** The pick is the exact centre of that window, and in
the second run it is **15 -- the same value Linux settles on**. The 1 MiB
environment read timed out anyway, at tune 15, with the register table
byte-identical to the run at tune 16.

The tuning transfer is not a token gesture: U-Boot's `mmc_send_tuning()` reads
128 bytes with `MMC_DATA_READ` through the same sdhci/ADMA path as every other
read, and then `memcmp()`s the result against the expected tuning pattern. A
pass means real, correct data crossed the bus. So:

> **A 128-byte single-block read succeeds at 32 to 34 of 40 sampling phases;
> a 2048-block read fails at every one of them.** Phase, PHY delay, tuning and
> the clock are all excluded as causes.

## The two rejected fixes

**Disabling `CONFIG_MMC_HS200_SUPPORT`** so U-Boot settles at `MMC_HS_52` like
the SPL, with nothing else selecting `MMC_SUPPORTS_TUNING` (verified: the symbol
is absent from the generated config and `execute_tuning` is gone from the ELF).
The board went dark -- no reset, no console. See "hangs are intermittent" below
before reading anything into that.

**`ADMA_MAX_LEN` 65532 -> 65536.** U-Boot chunks ADMA descriptors at 65532
bytes, which is not a multiple of 512: every intermediate descriptor boundary in
a transfer longer than that falls 508 bytes into a block. Linux has always used
65536 (`SDHCI_ADMA2_MAX_LEN`), which is block aligned and encodes as zero in the
descriptor's 16-bit length field. The theory fit the evidence exactly -- 128-byte
tuning reads use a single descriptor and pass; the 1 MiB read needs seventeen and
fails -- and it made no difference at all. Reverted rather than left in the tree:
an unproven behaviour change is a confound for the next rung, and with large
transfers already broken there is no way to tell whether this controller even
accepts the zero-means-65536 encoding.

## Hangs on this board are intermittent

The same image, in two consecutive rounds, hung once and reset cleanly once --
with the environment read failing identically both times, so both rounds ran the
same built-in default `bootcmd` down the same path. **A dark board is therefore
not evidence about the change under test.** Two of this rung's six rounds were
spent discovering that, and the round that "showed" HS200 mattered proves
nothing on its own.

## The watchdog does not arm from U-Boot

A hang banks nothing: the pre-console buffer and the slot register both die with
the power cycle that is the only way to recover. The fix should be a watchdog --
a hang becomes a chip reset, slot B's bootable bit is already consumed, the reset
lands on slot A, and Linux reads the log back.

It does not work. `board_early_init_r()` (which runs before `initr_env()`) was
given the exact sequence our own `ax630c_wdt` driver uses -- select the 24 MHz
source, program TORR, strobe TORR_LOAD, kick with the magic word `0x61696370`,
then set WDT_EN -- with TORR `0xD693`, 300 s at that source. A control run with
the arm in place and the rest of the image known-good returned normally with a
full console, so **the arm site is harmless**; but a hung round with the same arm
sat dark for ten minutes without resetting, so **the dog never runs**.

The reason is almost certainly that the block is not clocked. The kernel driver
takes clocks *and resets* from the peripheral clock controller before touching
the registers; our U-Boot never enables either, so the writes are posted into a
block that is not running. Rung 2e's `mw`-only attempt reset the board in about
a second, which on this reading was not the watchdog at all. **Arming WDT0 from
U-Boot needs the clock and reset released first** -- that is the prerequisite for
any future rung that wants a hang to be observable.

## What the diff looks like now

Unchanged from rung 2i except HRS06's tune field, which tracks the sweep:

| Register | U-Boot | Linux |
|---|---|---|
| SRS 0x28 HOST_CONTROL | `0x34` | `0x34` |
| SRS 0x2c clock/timeout | `000e0207` | `000E0207` |
| SRS 0x30 int status | `00108000` | `00000000` |
| SRS 0x3c HOST_CONTROL2 | `0x0008` | `0x3008` |
| HRS06 | `0x0f04` / `0x1004` / `0x1104` | `0x0f04` |
| GLB mux0 / div0 | `0x73` / `1` | `0x73` / `1` |

`PHY 09` reads 194, 195 or 196 across runs; neither driver writes it, so it is
not a comparison point.

## What is left

**V4 mode.** Linux sets `HOST_CONTROL2` bits 12 and 13 -- Host Version 4 mode and
64-bit addressing -- and runs 64-bit ADMA2 descriptors. Mainline U-Boot has no V4
support whatsoever: `SDHCI_CTRL_V4_MODE` does not exist in `include/sdhci.h`, and
`SDHCI_SPEC_400` appears only as a version constant. It is now the only
structural difference left between a driver that reads this eMMC and one that
does not, and it explains the size dependence in a way nothing else does: V4 mode
changes how the controller consumes the descriptor chain and the block-count
register, which is invisible to a single-descriptor 128-byte read and decisive
for a seventeen-descriptor one.

## Files

- `tune-map-20260908.txt` -- the two sweeps and the surrounding console.
