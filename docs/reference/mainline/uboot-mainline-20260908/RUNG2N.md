# Rung 2n -- block gap cleared, the card never begins, and the chain runs (#89)

2026-09-08. Five hardware rounds. The multi-block bug is now filed separately as
**#91**; this rung established what it is not, proved what the card is doing, and
put a workaround in that carries the chain to `booti`.

## Round 1: block gap is clean, and the card never starts

The full `SRS 0x28` word, before the first read and after the failed CMD18:

```
pre-read hostctl 00000f34 present 01ff00f0 int 00000000
post cmd18 srs 28=00000f34
```

Byte 2 is `BLOCK_GAP_CONTROL` and it is **zero** at both points -- no stale
stop-at-block-gap, no continue request, no read-wait, no interrupt-at-block-gap
-- byte-identical to Linux's `0x00000F34`. **Block gap excluded**, and with it
the last "stale bit that only a multi-block transfer would notice" theory.

The rest of the round answers the question rung 2m could not finish:

```
post cmd18 present 01ff00f0     (six samples, all identical)
post cmd18 srs 24=01ff00f0  28=00000f34  2c=000e0207  30=00108000
post cmd18 srs 34=027f003b  38=00000000  3c=10080000
post cmd18 cmd13 0 status 00000900 state 4
```

- `PRESENT_STATE 0x01ff00f0`: CMD line high, **all eight DAT lines high**,
  `DAT_LINE_ACTIVE` (bit 2) clear, `READ_TRANSFER_ACTIVE` (bit 9) clear. No
  transfer is active and none was.
- **CMD13 succeeds and the card reports CURRENT_STATE 4, TRAN.** Had it begun
  and been interrupted it would be in DATA (5).

**The card never begins the transfer.** That closes the fork the last three
rungs were circling: this is not the host failing to sample data the card sent.
The card accepts CMD18 -- answers R1 from TRAN, with CMD23 accepted too when
Auto CMD23 is on -- and then declines to enter the data phase.

## Round 2-5: the stopgap, and how far the chain gets

`cdns,single-block-only` (U-Boot patch `0017`) caps `cfg->b_max` at 1, so the
core splits every request into CMD17/CMD24 loops. It is a device-tree property
rather than a compatible-wide quirk so it is easy to find and delete when #91 is
understood.

It works, first time:

```
Loading Environment from MMC... Reading from MMC(0)... OK
read probe: hc 1 ocr c0ff8080 rca 0001 blksz 512 lba 61079552 bw 8 mode 12 bmax 1
read lba 00000000 cnt 1 -> 1 cmd 113a0013 arg 00000000 resp 00000900 stat 00000000
read lba 00000000 cnt 2 -> 2 cmd 113a0013 arg 00000001 resp 00000900 stat 00000000
read lba 00002600 cnt 1 -> 1 cmd 113a0013 arg 00002600 resp 00000900 stat 00000000
read lba 00002600 cnt 2 -> 2 cmd 113a0013 arg 00002601 resp 00000900 stat 00000000
```

**The environment loads** -- the first time in this whole epic -- and the
two-block reads now succeed as pairs of CMD17s, visible in the argument stepping
`0x00000000` then `0x00000001`.

Slot register on return: `0xB0000015`, i.e. **bit 28 `ms_uboot` and bit 29
`ms_extlinux` both set** -- `load mmc 0:10 /extlinux/extlinux.conf` succeeded.
(Bit 31 is set because that round's `bootcmd` deliberately ends in
`ms_failed; reset`.)

Round 4 loaded the payload and reset without booting it, so U-Boot's own timings
landed in the console:

| file | size | time | rate |
|---|---:|---:|---|
| `extlinux.conf` | 680 B | 23 ms | 28.3 KiB/s |
| `Image` | 51 132 928 B | **105 329 ms** | 473.6 KiB/s |
| `ax630c-nanokvm-pro.dtb` | 16 213 B | 47 ms | 335.9 KiB/s |

Slot register `0x70000015` -- bits 28, 29 and 30, no `ms_failed`. **Environment,
extlinux, kernel and device tree all read correctly over single-block transfers,
in 105 seconds.**

## Where observability ends: the kernel disables its own rescue

Rounds 2 and 5 ran the full `sysboot` and went dark for 16 and 10 minutes with
**no watchdog reset**, which is itself the interesting part. Our
`drivers/watchdog/ax630c_wdt.c` stops the dog at probe -- "U-Boot left it armed
and counting, and everything below must not race it" -- and re-arms it only
through the watchdog core. So a kernel that probes that driver and then fails
has switched off the only channel that survives a hang, and a power cycle takes
the console with it.

That is consistent with the kernel booting (it is the same 105 s load that round
4 measured, followed by a handoff), but it is **not proof**, and this rung does
not claim it. What is proven is everything up to and including `booti`'s inputs.

**For the next rung**: boot the kernel with `initcall_blacklist` on the watchdog
driver, or a cmdline that keeps it out, so that a failed hand-off still resets
and still banks its buffer. The appliance rootfs was never staged here -- that is
#78's harness, and it is the other half of what "row 2 DONE" needs.

## Files

- `rung2n-blockgap-20260908.txt` -- round 1's full register dump, the stopgap
  probe, and the load timings.
