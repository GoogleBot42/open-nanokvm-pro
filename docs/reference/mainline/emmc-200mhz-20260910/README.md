# #91 CLOSED: the eMMC clock, not the transfer sequence

2026-09-10, hardware, branch `issue-91-hw`. Fourteen boot cycles.

**Mainline U-Boot could not do a multi-block eMMC read because the device tree
said `max-frequency = <50000000>` and the board runs HS400ES.** In HS400 the
host samples the data lines on a strobe the *card* drives, against the fixed
`cdns,phy-dll-delay-strobe = <18>` — a tap count the vendor chose while running
this part at 200 MHz, which is what its first-stage loader does on every boot.
At 50 MHz that delay lands in the wrong place: the card streams, the host
frames nothing, no CRC error is raised because no block is ever assembled to
check it, and the only failure is the driver's own software timeout. Which is
exactly the signature #89 rung 3b measured and could not explain.

Linux was never a counter-example. It runs **HS200**, where the host samples on
its own clock, and 50 MHz is fine there. Nobody but mainline U-Boot has ever run
this part in HS400ES at 50 MHz.

## The measurement

`.#uboot-mainline-probe-mb` is the shipping image plus a `preboot` that lifts
the `cdns,single-block-only` cap for exactly two open-ended reads and then hands
the card back, so the appliance still boots and the DRAM ring can be read from
Linux. One device-tree value separates the two rounds.

| clock | `MB-A` CMD18 × 2 blocks | `MB-B` CMD18 × 64 blocks | boot |
|---|---|---|---|
| **200 MHz** | `2 blocks read: OK` | `64 blocks read: OK` | 3 min, no retries |
| 50 MHz (control) | `Transfer data timeout` | `Transfer data timeout` | 6 min 21 s, retry storm |

Captures: [`ring-200mhz-probe.txt`](ring-200mhz-probe.txt),
[`ring-50mhz-control.txt`](ring-50mhz-control.txt). The 50 MHz control still
prints #91's signature verbatim —

```
probe: cmd18 failed int 00000000 present 016f02c6
probe: cmd13 int 00108001 resp 00000b00 state 5
```

no error interrupt, `READ_TRANSFER_ACTIVE` set, card in **DATA**.

## What shipped

* `max-frequency = <200000000>` on the eMMC node (U-Boot patch `0003`). The SD
  slot keeps 50 MHz.
* U-Boot patch `0017` (`cdns,single-block-only`) **deleted**, and the property
  with it. `0022` (retry a failed block read) stays.

## The boot-time record

Same board, same rootfs, `systemctl reboot` to SSH. `bootcount` is U-Boot
starts since the last healthy boot, read at the health gate.

| | time to SSH | U-Boot starts |
|---|---|---|
| before (#94's table, six cold boots) | 2:49, 7:10, 7:42, 12:43, 17:35, 24:51 | 1-4 |
| after, chainloaded through the test slot (4 boots) | 2:04, 1:29, 1:14, 1:13 | 2 each — one production pass, one candidate pass |
| **after, from flash (3 boots)** | **1:11, 1:11, 1:12** | **1, 1, 1** |

Of those 71 seconds, 46 are Linux: the boot chain is about 20 s, against the
105 s the 48.8 MiB `Image` alone used to take at 474 KiB/s. **No boot since the
fix has needed a second U-Boot attempt.**

## The chainload test slot works, and both halves were watched firing

Nothing in this round was written to the `uboot` partition until the answer was
already proven (§ below). Every candidate went through the one-shot slot
(patch `0025`), and its two proofs were run first, because rounds 2 and 3 of
2026-09-09 had both spent themselves on the mechanism.

| proof | candidate | oracle |
|---|---|---|
| positive | `.#uboot-mainline`, byte-identical to flash | `CHLD` at `0x480EE000`, target `0x5C000400`, `chainstat` = 3, token zero on the medium, appliance up |
| negative | `.#uboot-mainline-hangtest` (`b .` right after the WDT arm) | same record, then WDT0 reset at ~300 s and the production copy on flash booted the appliance unattended, 13m10s end to end, **token still zero — the hung candidate was never re-armed** |

The hang was verified in the linked image before it ran, not in the patch:
`5c002580: b 5c002580`, immediately after the store that enables WDT0.

### The slot had a byte-order bug, and it cost the first round

`bootchain` compares the token block with `itest.l *${tokaddr} == ${tokmagic}`,
which is a native `*(u32 *)`. The appliance writes the four bytes `43 48 54 4B`
("CHTK"), so the word to compare against is **`0x4B544843`** — the environment
carried `0x4348544B`, the hexdump reading. The gate therefore never opened, and
the round is indistinguishable from a load that failed: no `CHLD` record, and
the token gone anyway because the appliance's own clear unit zeroes it on the
next boot. Fixed in patch `0025`; `.#checks.uboot-mainline` now asserts the
value. The rounds before the fixed U-Boot reached flash were armed by hand with
the reversed bytes.

## The SPL-driver candidate is a dead end, and it takes the board with it

`.#uboot-mainline-spldrv` (patch `0026`) was chainloaded once. **The board went
dark for 38 minutes and did not come back** — WDT0 did not recover it, which
matches #89 rung 2m's AXI wedge. The power cycle that did recover it destroys
the DRAM ring, so the round measured nothing at all.

That is the shape of the whole experiment: its answer is written into memory
that only survives a *chip reset*, and the failure it is built to investigate
is one that survives chip resets. It needs a flash-backed evidence channel and
a step bisect before it is worth another cycle — and now it is not worth one,
because the four differences it existed to test have been settled by the first
of them.

`splDrvCmds`/`splDrvTag` were added to `pkgs/uboot-mainline.nix` for that
bisect and are unused; they cost nothing and the next person will want them.

## Device end state

| what | value |
|---|---|
| `uboot` partition (2 MiB, from `/dev/loop0p2` **and** raw eMMC LBA 5632, after `drop_caches`) | `88b65081496b6f9f75e71a55a121b0a0` |
| the signed image inside it (187344 B) | `003eaffdc66b874dc182937641a3a603` |
| previous contents | `/root/uboot-prev-91.img` (rootfs — an AXDL flash destroys it; rebuild from the flake instead) |
| token block (raw LBA 9728) | all zero, nothing armed |
| staged candidate | none |

## Two lessons worth carrying

**A guard that reads memory as a word must be written as that word.** A magic
spelled the way it reads in a hexdump builds, boots, and silently never matches.

**An 8 KiB ring is a budget, and a failing boot spends it.** The 50 MHz control
was told to `reset` straight after its probe precisely so the retry storm could
not wrap the ring — and it wrapped anyway, because the storm happened inside the
`mmc dev 0` re-init that came *before* the reset. The signature survived; the
`MB-A`/`MB-B` markers did not. Put the marker you need to read first, and reset
before anything that can print in a loop.
