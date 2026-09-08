# Rung 2m -- the watchdog moves to the first instruction, and PIO retires DMA (#89)

2026-09-08. Seven hardware rounds, and a self-inflicted bug that invalidated
four of them before it was found.

## Step 0: WDT0 arms from `save_boot_params`, proven

Patch `0016` puts the arm in `arch/arm/mach-axera/lowlevel.S`, overriding the
weak `save_boot_params` that `reset:` branches to as the very first instruction
U-Boot executes. Everything the block needs from outside already holds at that
point (`wdt-model-20260906.md` §7.1), so it is nine MMIO writes with no C
runtime, no stack and no timer -- the two level-sensitive strobes get counted
spins instead of `udelay()`.

**Proof round**: TORR `0x2AEA` (60 s) and a deliberate `b .` immediately after
the arm, i.e. a hang at U-Boot's first instruction. The board came back on slot
A **97 s after the reboot command with no power cycle**, and the pre-console
buffer was empty -- correct, because nothing had printed yet.

It has since recovered three more real hangs, one of them timed at **335 s**
against a 300 s reload. A dark round now costs two minutes instead of a human.

## The bug that ate four rounds

`patch` silently truncates a hunk to the line count in its header. The
`lowlevel.S` hunk declared `@@ -0,0 +1,78 @@` for an 81-line body, so the last
three lines -- a blank, `b save_boot_params_ret`, and `ENDPROC` -- were **never
applied**. U-Boot ran off the end of the function into its own literal pool and
executed `0x61696370` as an instruction.

It armed the watchdog perfectly on the way past, which is exactly why it was so
convincing: the dog fired, the board recovered, and every round looked like the
familiar "intermittent early hang". Four rounds were attributed to PIO and to
bad luck before a disassembly of the built image settled it:

```
002170 b900013f 580001a9 5280002a b900012a
002180 61696370 00000000 048700f4 00000000
```

36 instructions and then the literal pool -- no branch. After fixing the count:

```
002170 b900013f 580001a9 5280002a b900012a
002180 17fff7ab 61696370
```

`17fff7ab` is `B` to `0x5c00042c`, which `nm` gives as `save_boot_params_ret`.

**The lesson generalises past this rung: a wrong hunk count is not a build
error, it is a silent truncation, and `git apply`-style strictness is not what
`patch` does.** Where a patch adds code whose tail is load-bearing -- a return,
a branch, a closing brace that happens to still balance -- verify the built
artefact, not the patch file. Every fuzz warning in this series deserves the
same treatment.

## Step 1: PIO fails multi-block. DMA is excluded.

With all of `0007`-`0016` and both `MMC_SDHCI_ADMA` and `MMC_SDHCI_SDMA` off
(verified absent from the generated config), from a freshly identified card:

```
read probe: hc 1 ocr c0ff8080 rca 0001 blksz 512 lba 61079552 bw 8 mode 12 bmax 65535
read lba 00000000 cnt 1 -> 1 cmd 113a0012 arg 00000000 resp 00000900 stat 00000000
read lba 00000000 cnt 2 -> 0 cmd 123a003a arg 00000000 resp 00000900 stat 00108000
read lba 00002600 cnt 1 -> 1 cmd 113a0012 arg 00002600 resp 00000900 stat 00000000
read lba 00002600 cnt 2 -> 0 cmd 123a003a arg 00002600 resp 00000900 stat 00108000
```

The transfer-mode words are `0x0012` and `0x003a` -- **no `SDHCI_TRNS_DMA`**, so
this is the programmed-I/O path, and it behaves exactly like ADMA2 32-bit, ADMA2
96-bit and SDMA before it. Single block passes at both addresses; two blocks
fail at both with `DATA_TIMEOUT`.

**Every data path the driver has now fails identically, so the failure is not in
any of them.** That also retires step 2 before it was written: implementing
`HOST_CONTROL2` bit 13 and the 128-bit v4 ADMA2 descriptor would be work on a
subsystem that has just been shown not to matter.

## Step 3, half taken -- and a new hard trap

The last round added, after the failed CMD18: six samples of `PRESENT_STATE`
(DAT levels, `DAT_LINE_ACTIVE`, `READ_TRANSFER_ACTIVE`, `BUFFER_READ_ENABLE`),
then CMD13 `SEND_STATUS` to ask **the card** whether it thinks it is in TRAN
(never started) or DATA (started, and the host missed it) -- the whole remaining
fork -- and last, a read of `BUFFER_DATA_PORT`.

That last read is the trap. **Reading `SDHCI_BUFFER_DATA_PORT` with nothing
buffered wedges the AXI bus so hard that a WDT0 chip reset does not land**:
seventeen minutes dark against a 300 s reload, recovered only by cutting power,
which took the console -- including the two measurements that had already
printed -- with it.

So it is removed, and the shape of the mistake is worth more than the datum:
**a speculative poke belongs in a round of its own, after the safe measurements
have been banked, never appended to them.** Putting it last in the same round
looked like the careful ordering; it was not, because everything upstream of it
shares its fate.

## Where this leaves the search

| axis | result |
|---|---|
| sampling phase, base clock, PHY delays | excluded (rung 2j) |
| bus width, signal voltage, addressing, transfer size | excluded (2i, 2k) |
| stop convention: none, Auto CMD12, Auto CMD23 | excluded (2k, 2l) |
| bus mode: HS, HS200, HS400ES | excluded (2l) |
| host mode: v3, v4 | excluded (2l) |
| **data path: ADMA2 32-bit, ADMA2 96-bit, SDMA, PIO** | **excluded (2m)** |

Nothing in the host's programming model distinguishes the passing case from the
failing one any more. The next measurement is the unfinished half of step 3 --
`PRESENT_STATE` after the failure, and CMD13 to the card -- run without the
buffer-port read. It is one round and it splits "the card never began" from "the
card began and the host never sampled", which is the last question the registers
can be made to answer.

## Files

- `rung2m-pio-20260908.txt` -- the PIO probe, the proof round, and the
  disassembly that found the truncated hunk.
