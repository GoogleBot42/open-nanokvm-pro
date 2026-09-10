# #91: the first-stage loader's own eMMC read path, and a way to try it

2026-09-12, branch `issue-91-spldrv`. **Offline half only — nothing here has run
on the board.**

Two things live in this directory. The first is a way to boot a U-Boot candidate
without writing the only `uboot` partition there is. The second is the candidate
that matters: mainline U-Boot carrying the AX630C first-stage loader's own
Cadence SD4HC read sequence, so the sequence can be run against the four-read
matrix on the same silicon that the loader reads 18 MiB through on every boot.

## 1. The chainload test slot

The minimal layout (#89 rung 4) has one `uboot` partition and no B twin. A
candidate written to it that hangs is a USB recovery trip, and this board has no
console to say why. U-Boot patch `0025` gives the partition its A/B property
back without a second copy of it.

**How it works.** Production U-Boot's built-in `bootcmd` begins `run bootchain`.
`bootchain` fires only when `bootcount` is 1 — the first attempt after a boot
that reached a healthy userspace — and only when `/uboot-test.bin` is on the
boot filesystem. It loads the file to `CONFIG_TEXT_BASE` (`0x5C000400`), clears
milestone bit 28, and runs `chainload`.

**`chainload` is not `go`.** `go` calls the entry point as a C function with the
MMU and both caches on, and with `x0` = argc. A U-Boot image's first
instructions run before any of that is valid: `arch/arm/cpu/armv8/start.S` is
written against exactly what the SPL leaves — MMU off, caches off, EL unchanged
(EL1h here, because BL31 drops to EL1). `chainload` is `go` plus
`cleanup_before_linux()` plus zeroed `x0..x3`, which is the state `booti`
already hands a kernel. The compiled sequence, from the shipped ELF:

```
5c0025f8:  bl   printf
5c002610:  str  w1, [x0]        ; 0x43484C44 -> 0x480EE000
5c002618:  str  w19, [x0, #4]   ; the target address
5c00261c:  bl   flush
5c002620:  bl   cleanup_before_linux
5c002624:  mov  x0, #0 ... x3, #0
5c002634:  br   x19
```

The candidate then does what it does from the SPL: `save_boot_params` (which on
this SoC arms WDT0 at the first instruction, patch `0016`), the vector table,
`board_init_f` on the init stack at `0x5BF00000`, `relocate_code()` to the top
of DRAM — over the running production copy, which is fine because nothing
returns — and `board_init_r`. No DTB pointer is needed: the port appends its
device tree to the image and `fdtdec_setup()` finds it at `_end`, so a candidate
loaded at its link address finds its own.

**Three things bound the blast radius, and all three are needed:**

1. `bootcount` == 1. The counter is `0x02390030`, survives a chip reset, and is
   cleared only by `nanokvm-mark-good` (patch `0024`). A candidate that hangs is
   reset by WDT0 after 300 s into attempt 2, which skips the test file and boots
   the production image still on flash. Unattended, one extra cycle.
2. The candidate increments the counter itself the moment it reaches
   `main_loop`, so it cannot chainload a third U-Boot and a stale file cannot
   loop the board.
3. Nothing writes flash. Staging is `cp`; recovery is a reboot.

**Reading the result costs no milestone bit,** and that is deliberate: bits
12..24 of `0x02390024` belong to the #75 bring-up initramfs, 25..27 to
`nixos/loop-test.nix`, 28..31 to the bootloader. A bootloader bit that drifted
into that range would forge somebody else's evidence rather than fail — which is
what `.#checks.uboot-mainline` asserts. Instead:

| `0x480EE000` | bit 28 of `0x02390024` | meaning |
|---|---|---|
| not `CHLD` | — | nothing was staged, or the load failed |
| `0x43484C44` | clear | it jumped, and the candidate never reached its own `preboot` |
| `0x43484C44` | set | **two U-Boot passes in one boot** |

`0x480EE000` is the spare page of the pstore window: nothing else writes it, it
survives a chip reset, and `cleanup_before_linux()`'s D-cache flush is what
pushes it to DRAM. `nanokvm-uboot-test-clear.service` latches it into
`/run/nanokvm-uboot-test.chainload` and zeroes it on the next boot, so a record
that is present always describes the boot that just happened.

**The appliance half** is `nanokvm-uboot-test {stage <file>|clear|status}`.
`stage` refuses anything whose bytes 8..15 are not `_TEXT_BASE = 0x5C000400` —
`start.S` puts `.quad CONFIG_TEXT_BASE` at offset 8, so those eight bytes are an
exact, free identity check, and they are what separates a raw `u-boot.bin` from
the axgzip'd signed container (which would be jumped into as if it were code),
from a kernel `Image`, and from a U-Boot built for another board. It then
verifies the copy from the medium after dropping caches.

## 2. The candidate: `.#uboot-mainline-spldrv`

U-Boot patch `0026` adds `drivers/mmc/axera_spl_sdhci.c`, 1460 lines
transcribing the eMMC init and read path of `boot/bl1/driver/mmc/{sdhci_cdns.c,
mmc.c,axera_mmc.c}` from the SDK snapshot (GPL source, `maix_ax620e_sdk`
`45ebcc32`), and exposes it as a `splmmc` command. It is deliberately **not** a
`UCLASS_MMC` driver: going through U-Boot's mmc core would put U-Boot's sequence
back in, which is the thing under test. It takes the controller over for the
length of the command and leaves it reset; `mmc rescan` hands it back.

Nothing is improved. Two departures are marked `DEVIATION` in the file — a
d-cache invalidate around the SDMA buffer (the loader runs with the MMU off,
U-Boot does not) and a watchdog kick between chunks of the 51 MiB read. Neither
touches a controller register. Three `OBSERVATION` snapshots read
`PRESENT_STATE` and `INT_STATUS` at the moment a transfer gives up, **before**
the driver's own CMD/DAT reset — the reset that returns the card to TRAN and
made #91's first reading of this bug the exact opposite of the truth (rung 3b).

### What reading the loader's source already settled

Four differences in the sequence, before a line of it ran:

| axis | the loader | mainline U-Boot | Linux |
|---|---|---|---|
| card clock | **HS400ES at 200 MHz** | HS400ES at **50 MHz** | HS200 at 50 MHz |
| PHY 0x0c, output delay in HS200/HS400 | **23** | 31 | 31 |
| PHY 0x01, input delay SD default | **18** | 4 | 4 |
| SRS03 (cmd + transfer mode) | **one 32-bit store** | two 16-bit stores | — |

The clock is the one to look at first. `flash_get_bus_clk` is dead code
(`#ifdef OLD_INTERFACE`); the live path is `read_img_header()`, which sets
`sel_clk = 0` for every eMMC boot type and `bus_width = BUS_WIDTH_8`, and
`flash_clk_array[0]` is `200000000`. `emmc_init()` routes 200 MHz + 8-bit to
`mmc_select_hs400es()`. Mainline U-Boot never gets there because the device tree
says `max-frequency = <50000000>`. **Nobody but U-Boot has ever run this part in
HS400ES at 50 MHz** — Linux runs HS200, the loader runs HS400ES at 200 MHz — and
HS400 is the one mode where the card generates the data strobe the host samples
on, with a fixed 18-tap strobe delay that was chosen at 200 MHz. That is
consistent with the rung-3b signature in a way none of the fourteen excluded
axes are: the card streams, the host's DAT sampling never frames a block, no
CRC error is raised because no block is ever framed, `READ_TRANSFER_ACTIVE`
stays set, and the only failure is U-Boot's own 10 s software timeout.

`SRS03` is second. The loader writes command and transfer mode as one 32-bit
store with the comment *"set CMD_R & transfer mode together for cadence special
4B align"*; `sdhci.c` writes `0x0c` and `0x0e` as two 16-bit stores. The
readback in the #91 issue body (`123a003b`) proves the register FILE holds the
right value, which is not the same as the transfer engine having latched it.

### And one thing the loader does not do

**It never sets the eMMC card clock up at all.** `axera_sys_glb_clk_set()` — the
`npll_400m` select, the divider, and the "emmc_card_sw_rst for dll lock" pulse —
is inside `#if 0` in `axera_mmc.c` *and* commented out at its only call site in
`mmc.c`. The loader inherits whatever the boot ROM left. `splmmc clk` performs
it on demand so the axis is testable; nothing calls it, because the loader does
not. This corrects the framing in the #91 issue body and in the task that
opened this branch.

### What the probe measures

`.#uboot-mainline-spldrv` is `.#uboot-mainline-tee` (every console write also
copied into the pre-console buffer at `0x480E8000`) plus the driver, with:

```
preboot = mw.l ${msreg_set} ${ms_uboot}; splmmc regs; splmmc init;
          splmmc probe 0x4a000000 0x4ae00; mmc rescan
```

`splmmc init` runs the loader's ladder: `sdhci_reset(ALL)`, the status-enable
word `0x027F003B`, HRS06 MODE = EMMC_LEGACY for identification, the loader's PHY
table, `sdhci_set_power()` from `get_emmc_voltage()`, the 400/300/200/100 kHz
identification ladder with the RST_n pulse on GPIO2+0x60 between attempts,
CMD0/CMD1/CMD2/CMD3/CMD9/CMD7, `CMD16`, `EXT_CSD_BUS_WIDTH` = 8, then
`mmc_select_hs400es()` — HS downgrade, `EXT_CSD_BUS_WIDTH` = 8 | DDR | STROBE,
`HS_TIMING` = HS400, HRS06 MODE = 6, and `sdhci_set_clock(200 MHz, 200 MHz)`.

`splmmc probe` is the #91 four-read matrix — CMD17 and CMD18 at LBA 0 and at LBA
0x2600, back to back on a freshly identified card — then 99870 blocks
(51 133 440 B) from LBA `0x4AE00` in 32768-block chunks, timed. Then `mmc
rescan` and a normal boot, so the appliance comes up and the answer can be read
out of the pre-console buffer from Linux.

**If multi-block works here**, the bug is in `sdhci.c`'s sequence and the
difference is bisectable one register at a time — and the chainload slot makes
each round reversible. **If it fails identically**, the sequence is not what
makes the loader work, and the difference is in the SoC state around it; the
next step is `splmmc regs` before and after, diffed against the loader's.

## 3. The hardware procedure

Not yet run. Ten boot cycles budgeted; a mainline boot takes 3–25 minutes today
(#91), so poll 30.

**Proof of the slot, first, with a candidate that cannot fail:**

1. `nix build .#uboot-mainline`, copy `images/u-boot.bin` to the board.
2. `nanokvm-uboot-test stage /root/u-boot.bin` — the *current production*
   U-Boot, so a working chainload is indistinguishable from a working boot
   except in the evidence.
3. `reboot`, wait for SSH.
4. `nanokvm-uboot-test status` and `journalctl -u nanokvm-uboot-test-clear`:
   expect `chainload: yes, to 0x5c000400` and `ms_uboot (28): set`.

**Then a candidate that must fail:** the same image with `b .` immediately after
the WDT arm in `save_boot_params`. Expect the board back on its own after
~300 s + a boot, `chainload: yes` with `ms_uboot (28): CLEAR`, and
`bootcount` = 2 at the health gate.

**Then the experiment:** stage `.#uboot-mainline-spldrv`'s `images/u-boot.bin`,
reboot, and read the pre-console buffer:

```
dd if=/dev/mem bs=4096 skip=295144 count=2 2>/dev/null | tr -d '\000'
```

(`295144 × 4096 = 0x480E8000`.) The `splmmc:` lines carry the four-read matrix,
the fail-path snapshots, the 51 MiB timing and the register dumps.

### Rules for the hardware phase

- Never `dd` a candidate into the `uboot` GPT partition. That is what the slot
  is for.
- Hash-verify any block write, dropping caches first.
- Read the slot register, the chainload record, the pre-console buffer and the
  pstore archive **before** any power cycle — the cycle destroys all four.
  `~/.claude/skills/power-switch/switch.sh "nanokvm switch"`; leave it off ≥15 s.
- `.#uboot-mainline-spldrv` is a diagnostic. It is never flashed.

---

# HARDWARE, 2026-09-09: three rounds, one stranded board, one real lesson

The offline half above was written before any of this ran. What follows is what
the board actually did. **The #91 experiment never executed** — the slot that
was supposed to make it safe is what stopped it.

## What was measured

| # | round | result |
|---|---|---|
| 1 | production U-Boot + patch 0025 written to `uboot` (p2) | **PASS.** Hash `a35f1388f42507697dffa8cf86b7dad1` verified from `/dev/loop0p2` *and* from the raw eMMC at physical offset 2 883 584. Appliance back in 12m32s, `running`, milestones `0x30000014`, no CHLD record — the correct negative for "nothing staged" |
| 2 | production `u-boot.bin` staged as the candidate | **NO CHAINLOAD.** `CHLD` = 0, file still staged, and `nanokvm-mark-good` reported `bootcount was 0xB0010003` |
| 3 | gate widened to `bootcount <= 2`; `.#uboot-mainline-spldrv` staged | **BOARD STRANDED.** Dark for 48 min, then dark through two cold cycles (30 s off each). Needs AXDL |

## Round 2: the gate never opened

`bootchain` was gated on `bootcount == 1`. The board reported **three** U-Boot
attempts for that one Linux boot (`journalctl --list-boots` shows a single
Linux boot; the counter is incremented once per `main_loop`). Attempts 2 and 3
skipped the gate by design, and attempt 1 either lost its `load` to a single
flaky read — #91 itself — or never reached it.

**A gate that only opens on attempt 1 is the wrong gate for this board.** Until
#91 is fixed, `bootcmd` ending `mw.l ${ms_failed}; reset` makes multi-attempt
boots routine, and attempt 1 is *also* the attempt most likely to lose a read,
being the first transfer after an initialisation (#89 rung 2o). Cost: one
13-minute round that measured nothing and reported it as "no chainload".

## Round 3: the gate that stranded the board

The fix applied was `bootcount <= 2` plus a `mmc rescan`, three load retries,
and status words at `0x480EE008`/`0x480EE00C` so a round could say *why* it did
nothing. That build was written to `uboot` (hash
`e24741da1f7ac75fdcd3599e297622da`, verified both ways) and
`.#uboot-mainline-spldrv` was staged in the same round.

The board never came back. Two cold cycles, 30 s off, did not recover it.

**`bootcount` lives in a register that clears on power loss.** So the cold
cycle — the only recovery a console-less board has — resets the counter to
zero, which re-opens the gate, which re-arms the candidate that just hung. If
that candidate wedges anything WDT0 cannot reset (a measured hazard on this
controller: #89 rung 2m, an AXI wedge that survives a WDT0 chip reset), there
is no way out at all. Every power cycle walks straight back into it.

Which of the two writes is at fault is not yet distinguishable: the `spldrv`
candidate wedging in `splmmc`, or the second production U-Boot itself. Both fit
"dark and not recovering", and the DRAM status words that would have separated
them die with the power. The AXDL reflash will settle it — round 4 should
re-flash the *first* production U-Boot (`a35f1388…`, already proven in round 1)
and stage nothing, before anything else is tried.

## The fix, and the general form

**An arming condition for a dangerous test must not live in state that the
recovery action clears.** Flash is the only storage on this board whose
lifetime outlives a power cycle, so the arming token now lives in flash and is
spent *before* the risk is taken:

* One 512-byte block at the head of the unused `env` partition (p3, physical
  LBA 9728 = `0x2600`) holds the magic `CHTK`.
* `bootchain` reads it with `mmc read`, tests it with `itest.l`, and — if it is
  there — **zeroes it with `mmc write` before it loads or jumps**.
* So a candidate is tried exactly once, ever. A candidate that hangs at its
  first instruction has already spent the thing that would arm the next
  attempt, and no number of power cycles brings it back.
* `bootcount` still bounds the damage as a second belt, but nothing depends
  on it.

`.#checks.uboot-mainline` section 6 now asserts the ordering, not just the
presence: it extracts the `bootchain` string from the linked image and fails if
`mmc write` does not appear before both the load and `chainload`.

## What the next session should do

1. AXDL-reflash `.#nixos-firmware-image-mainline`. Then, from the appliance,
   write the **round-1** U-Boot to `uboot` and confirm a clean boot with
   nothing staged.
2. Write the token-gated U-Boot, confirm a clean boot with nothing staged and
   `nanokvm-uboot-test status` reporting `armed: no`.
3. Only then stage a candidate — and stage the *harmless* one first
   (`.#uboot-mainline`, byte-identical to flash), because rounds 2 and 3 both
   spent their evidence on the mechanism rather than on #91.
4. `.#uboot-mainline-hangtest` is built and staged-ready for the negative half.
5. The #91 experiment itself is unchanged and still worth the cycle: the four
   source-level differences above are all still unmeasured.
