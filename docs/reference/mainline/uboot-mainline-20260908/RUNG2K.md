# Rung 2k -- multi-block is the axis, and the watchdog is real (#89)

2026-09-08. Seven hardware rounds. Two results, one of them decisive.

## Step 0: WDT0 arms from U-Boot, and it is proven

Rung 2j armed the watchdog and it never fired, which the rung read as "the block
is not clocked". It was not that. Our own model doc already says every
precondition is in place before U-Boot runs
([`wdt-model-20260906.md`](../wdt-model-20260906.md) 7.1): the SPL sets the
counter gate `CLK_EB0` bit 14 before every stage jump and
`COMM_ABORT_CFG = 0x2C0`, and `CLK_EB3` bit 19 plus both `SW_RST3` bits come out
of chip reset already right. The arm now writes all of them anyway, because they
are idempotent alias writes on the periph controller at `0x0487_0000` and they
remove the dependency on what ran before:

| what | id | register | write |
|---|---|---|---|
| release arst, then prst | `AX630C_RST_PERIPH_WDT0_ARST` 83, `_PRST` 82 | `SW_RST3` clear alias `0xF4` | `2`, then `1` |
| counter gate | `AX630C_CLK_WDT0_EB` 19 | `CLK_EB0` set alias `0xB0` | `BIT(14)` |
| APB gate | `AX630C_PCLK_WDT0_EB` 99 | `CLK_EB3` set alias `0xC8` | `BIT(19)` |
| 24 MHz source | `AX630C_CLK_WDT0_SEL` 3 | `CLK_MUX0` set alias `0xA8` | `BIT(19)` |

`1 = held in reset`, so releasing is a write to the *clear* alias.

**Proof round**, TORR `0x2AEA` (30 s a stage, 60 s to reset) and a deliberate
`for (;;)` at the end of `board_late_init()`:

```
WDT en=00000001 torr=00002aea ccvr=08a1c45b abort=000002c0
PERIPH mux0=000fbf98 eb0=00037ffe eb3=000fffff rst3=00000000
== end ==
wdt proof: hanging here on purpose
```

The console ends there -- **no `resetting ...`**, so U-Boot never reset itself --
and the board was back on slot A 96 s after the reboot command with that log
intact. The dog runs, its expiry reaches the SoC, and slot B's bootable bit is
consumed by the first entry so the reset lands on slot A. Shipping reload is
`0xD693`, 150 s a stage, 300 s to reset.

What rung 2j actually got wrong was the *call site*: `board_early_init_r()` runs
after relocation, and a hung round outlived the reload from there. The arm now
runs from `arch_cpu_init()`, the earliest initcall a board may own -- ahead of
`initf_dm()` and `board_early_init_f()`, with only `setup_mon_len()`,
`fdtdec_setup()` and `initf_malloc()` before it. Two rounds still went dark past
300 s even from there, which places those hangs earlier still: in those three
calls, the SPL handoff, or the assembly startup.

## Step 1: the axis is multi-block, not addressing

The first attempt at this measured nothing, and the reason is worth keeping:
**a data timeout leaves the controller unable to run even a command.** Taken
after the environment read failed, all four reads returned 0 with `resp` and
`stat` both zero and the last command register reading `0x101a0033` -- CMD16
`SET_BLOCKLEN`, which `mmc_bread()` issues before every read and which was
failing silently. The probe was measuring the wreckage. Re-identifying the card
first (`mmc->has_init = 0; mmc_init(mmc)`, which returns 0) fixes it.

From a freshly identified card:

```
read probe: hc 1 ocr c0ff8080 rca 0001 blksz 512 lba 61079552 bw 8 mode 10 bmax 65535
read lba 00000000 cnt 1 -> 1 cmd 113a0013 arg 00000000 resp 00000900 stat 00000000
read lba 00000000 cnt 2 -> 0 cmd 123a0037 arg 00000000 resp 00000900 stat 00108000
read lba 00002600 cnt 1 -> 0 cmd 101a0037 arg 00000200 resp 00000000 stat 00000000
read lba 00002600 cnt 2 -> 0 cmd 101a0037 arg 00000200 resp 00000000 stat 00000000
```

- **CMD17 (`0x11`) at LBA 0, one block: returns its block.** `resp 0x900` is R1
  from TRAN with READY_FOR_DATA, `stat 0` is no error at all. An **addressed**
  read works.
- **CMD18 (`0x12`) at the same LBA, two blocks: fails.** Same R1, then
  `stat 0x00108000` = ERROR_INTERRUPT + DATA_TIMEOUT_ERR, and no ADMA error, so
  the descriptor chain was fetched and the card was simply never started.
- Reads three and four are collateral: the CMD18 failure has poisoned the
  controller again, and they die at CMD16 exactly as before.

The only difference between the two transfer-mode words is `SDHCI_TRNS_MULTI`.
**Addressing is fine; every R1 is clean; no OUT_OF_RANGE (bit 31) and no
ADDRESS_MISALIGN (bit 30) anywhere. Multi-block is the whole failure.** That
also retires the last doubt about the earlier rungs: the environment read failed
because it was CMD18, not because it was 1 MiB, not because of the ADMA chunk
size, and not because of the tuning phase.

## Two more candidates tried and rejected

**Auto-CMD12.** `SDHCI_TRNS_ACMD12` is defined in `include/sdhci.h` and set
nowhere in U-Boot; Linux sets it for every multi-block transfer and even carries
a quirk whose comment reads "controller needs to have the ACMD12 enabled for
multiblock reads". Setting it (and skipping the core's own `CMD12`, which would
otherwise be a second stop to a card already back in TRAN) put `0x0037` in the
transfer-mode register, visible in the trace above -- and the read failed
identically.

**SDMA, the first-stage loader's own path**, never tried before this rung:
`CONFIG_MMC_SDHCI_SDMA` with ADMA off. Also identical. Together with the earlier
ADMA2-32, ADMA2-96 and PIO rounds, that is **every data-transfer engine the
driver has, all failing the same way** -- so the failure is not in the DMA
engine at all.

## Where this points

`SDHCI_CTRL_V4_MODE`. It is the last structural difference from Linux, and it is
now the only remaining candidate that distinguishes a single-block transfer from
a multi-block one: **Host Version 4 mode moves the block count out of the 16-bit
register at `SRS 0x06` and into the 32-bit register at `SRS 0x00`, with the
16-bit one required to be zero.** A controller that implements only the V4 path
would see block count 0 for CMD18 and never start the data phase, while CMD17
-- which does not consult the block count -- would work perfectly. That is
exactly the observed behaviour, and `SRS 00` reads `00000000` in every dump
while the 16-bit count in `SRS 04`'s upper half reads 2 or 2048.

Linux sets `HOST_CONTROL2` bits 12 and 13 on this controller (`0x3008`);
mainline U-Boot has no V4 support whatsoever -- `SDHCI_CTRL_V4_MODE` does not
exist in `include/sdhci.h`, and `SDHCI_SPEC_400` appears only as a version
constant. Implementing it is rung 2l.

## Files

- `rung2k-reads-20260908.txt` -- the proof round, the four-read traces for
  ADMA + Auto-CMD12 and for SDMA, and the surrounding console.
