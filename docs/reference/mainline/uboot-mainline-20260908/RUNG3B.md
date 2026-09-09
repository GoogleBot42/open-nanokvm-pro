# #89 rung 3b -- a failed transfer is a retry, and slot A keeps the chain

2026-09-09. Ten consecutive slot-B boots of the appliance through the mainline
chain, then the promotion to slot A. Two U-Boot patches came out of it and both
ship: `0021` (never offer the card a signal voltage the board cannot drive) and
`0022` (retry a failed block read before giving up).

Everything below is measured. The console text is
`CONFIG_PRE_CONSOLE_BUFFER` at `0x480e8000`, read from the boot itself over
SSH; the measurement boots ran `.#uboot-mainline-tee`, which is the shipping
image plus a copy of every console write into that buffer plus one line naming
the selected eMMC mode.

## The ten-boot measurement

Slot B held mainline BL31 (p4) + mainline U-Boot (p6) and slot A kept the
vendor-derived chain, so every failure would have landed on a board that boots.
None did.

| # | reached SSH | wall to SSH | kernel uptime at read | pre-kernel | read retries | of which 10 s timeouts |
|---|---|---|---|---|---|---|
| 1 | yes | 188 s | 64.1 s | 124 s | 6 | 2 |
| 2 | yes | 171 s | 61.6 s | 109 s | 0 | 0 |
| 3 | yes | 174 s | 60.8 s | 113 s | 1 | 0 |
| 4 | yes | 172 s | 61.9 s | 110 s | 0 | 0 |
| 5 | yes | 172 s | 60.3 s | 112 s | 0 | 0 |
| 6 | yes | 172 s | 60.9 s | 111 s | 0 | 0 |
| 7 | yes | 175 s | 63.3 s | 112 s | 0 | 0 |
| 8 | yes | 211 s | 68.3 s | 143 s | 3 | 3 |
| 9 | yes | 196 s | 64.0 s | 132 s | 2 | 2 |
| 10 | yes | 175 s | 62.9 s | 112 s | 0 | 0 |

**10/10.** No fallback, no dark board, `systemctl is-system-running` = running
every time, slot register `0x30000029` every time (bits 28 and 29 set, bit 31
clear, slot B re-armed by `nanokvm-checkboot`).

Twelve read failures across roughly a million single-block commands -- about
1.2 per 100 000 -- and **every one of them was recovered by the first retry**:
no LBA appears twice. Seven were U-Boot's own 10 s software timeout in
`sdhci_transfer_data()`, worth ~10 s of boot each; the other five were an
`SDHCI_INT_ERROR` that returns immediately. The failures are bursty: three
boots carried all twelve, seven boots carried none.

**Not one re-initialisation happened**, so nothing in this table exercises
patch 0021. That proof is in the probe boot below.

The selected mode is the same on every boot and every init:

```
mmc: selected mode 12, 8-bit, 50000000 Hz, signal 2
```

mode 12 = `MMC_HS_400_ES`, signal 2 = `MMC_SIGNAL_VOLTAGE_180`.

## The probe boot: #91 discriminators, and the proof for patch 0021

One extra boot ran `.#uboot-mainline-probe` -- the tee image plus a `preboot`
sequence that lifts the `cdns,single-block-only` cap for exactly one command,
reads the card's own state with CMD13 **before any CMD12 and before the
controller is reset**, reads 8 MiB in `MMC_HS` and 8 MiB in HS200, and forces a
re-init. Verbatim, with the noise removed:

```
PROBE-A-CMD18
MMC read: dev # 0, block # 306688, count 2 ... Transfer data timeout
probe: cmd18 failed int 00000000 present 014f0236
probe: cmd13 int 00108001 resp 00000b00 state 5
mmc0: retrying read at 4ae00                      (x3, all identical)
0 blocks read: ERROR

PROBE-B-HS
mmc: selected mode 1, 8-bit, 26000000 Hz, signal 2
MMC read: dev # 0, block # 306688, count 16384 ... 16384 blocks read: OK

PROBE-B-HS200
probe: cmd21 failed int 00108000 present 01ff02f6  (x6 -- tuning)
probe: cmd13 int 00000001 resp 00000900 state 4
mmc: selected mode 10, 8-bit, 50000000 Hz, signal 2
MMC read: dev # 0, block # 306688, count 16384 ... 16384 blocks read: OK

PROBE-C-REINIT
mmc: selected mode 12, 8-bit, 50000000 Hz, signal 2
PROBE-END
```

### (a) The card starts. The host goes deaf. This reverses #91's headline.

With a genuine open-ended CMD18 -- no CMD23, no Auto CMD12 -- and CMD13 read
before anything is stopped or reset:

* `INT_STATUS = 0x00000000`. **No error interrupt at all.** The failure is
  U-Boot's 10 s software timeout waiting for `DATA_END`, not `DATA_TIMEOUT_ERR`.
* `PRESENT_STATE = 0x014f0236`: `DAT_LINE_ACTIVE` (bit 2) **set**,
  `READ_TRANSFER_ACTIVE` (bit 9) **set**, DAT[3:0] = 0x4, i.e. three of the four
  low data lines pulled down. A transfer is in progress.
* `CMD13` answers `0x00000b00` -> **CURRENT_STATE 5 = DATA**.

#91 records the opposite ("all eight DAT lines high, no transfer active, CMD13
state 4 = TRAN, it never started"). That reading was taken **after** the
controller had been reset, which is precisely what returns the card to TRAN.
Read before the reset, the card is streaming and the host is not collecting.
Three attempts, three identical answers.

The residual CMD17 failures have the same shape from the host side --
`int 00000000`, `READ_TRANSFER_ACTIVE` still set -- but by then the card has
already finished: `CMD13 ... state 4`. One CMD17 failure in the same boot did
raise `int 00108000` (`ERROR | DATA_TIMEOUT_ERR`). So CMD18 fails this way
always and CMD17 fails this way rarely, which is one bug, not two.

### (b) Mode dependence: not answerable at this sample size

`MMC_HS` (26 MHz) and HS200 (50 MHz) each read 16 384 blocks with **zero**
retries. At the measured residual rate of 1.2e-5 per read, 16 384 reads expect
0.2 failures, so 0 and 0 discriminate nothing. A useful comparison needs of the
order of 10^6 single-block reads per arm -- about 35 minutes of bus time each,
which does not fit inside one boot with a 300 s watchdog stage. The method is
in `.#uboot-mainline-probe`; only the read counts need raising.

Worth recording anyway: **HS200 tuning fails on this controller.** Six
`CMD21` (`SEND_TUNING_BLOCK_HS200`) attempts returned `ERROR | DATA_TIMEOUT`
and the core still selected HS200, which then read 8 MiB cleanly.

### (c) Patch 0021, proven on hardware

Five separate re-initialisations happened in that one boot -- the CMD18 probe,
`mmc dev 0 0 1`, `mmc dev 0 0 10`, `mmc dev 0`, and `bootcmd`'s own -- and the
console carries **no** `failed to set vqmmc-voltage to 3.3V` and **no**
`unable to select a mode`. The forced re-init lands on `mode 12, 8-bit,
50000000 Hz, signal 2`: byte for byte the first init's line. Before 0021 that
sequence was nine refusals and no block device.

## The promotion

Slot B put back to the vendor U-Boot first, so slot A still has somewhere to
fall. Then p3 = mainline BL31, p5 = the rung-3b mainline U-Boot, p7 = the
generated environment, `/boot` = the extlinux payload, slot A armed. Three
consecutive warm reboots:

| # | reached SSH | wall to SSH | slot register | bootsystem |
|---|---|---|---|---|
| 12 | yes | 173 s | `0x30000015` | A |
| 13 | yes | 172 s | `0x30000015` | A |
| 14 | yes | 174 s | `0x30000015` | A |

`0x30000015` = preboot (28) + extlinux (29), no failure bit, slot A re-armed.
`systemctl --failed` empty, web 200, `/proc/cmdline` is the extlinux APPEND.
**Slot A now runs the mainline chain and stays on it.**
