# Rung 2b, 2026-09-08: the hang is `relocate_code()`, and the DRAM window aliases

Six more slot-B boots after [README.md](README.md)'s eight, all reversible, all
self-recovering. Two results.

**1. `relocate_code()` is where mainline U-Boot dies.** `board_init_f()` runs to
its last initcall in **0.12 s** and `board_init_r()` is never entered. The
~65 s the board spends in slot B before resetting is the recovery, not the
cause.

**2. The AX630C DDR window aliases with a 1 GiB period.** Measured from Linux,
not inferred. This answers how the vendor U-Boot can claim 2 GiB on a 1 GiB
part, and it kills the "top of DRAM is not writable" hypothesis before it cost
a hardware round.

## The aliasing measurement

`harness/alias.sh`, run on the appliance through `/dev/mem`, inside the reserved
bring-up-log page so nothing the kernel owns is touched:

```
A = 0x480ee000 <- 0xAAAA1111        A reads 0xAAAA1111
B = 0x880ee000 <- 0xBBBB2222        A reads 0xBBBB2222   (+1 GiB aliases A)
C = 0xc80ee000 <- 0xCCCC3333        A reads 0xCCCC3333   (+2 GiB aliases A)
0x7fff0000, 0x7ffff000, 0x7ffffff0 <- 0xD00D0000, all read back
```

Those addresses are above the kernel's `mem=512M` window, so `/dev/mem` maps
them uncached: these are genuine uncached DRAM accesses, not cache hits.

Consequences, all of which matter beyond this rung:

- **1 GiB is the true size**, and `dts/ax630c-nanokvm-pro.dts`'s
  `memory@40000000` node is correct. The image repeats every gigabyte to at
  least 3 GiB.
- **The vendor U-Boot's `gd->ram_size = 0x80000000` works by aliasing.** Our
  board's defconfig does *not* set `CONFIG_AXERA_AX630C_DDR4_RETRAIN` (only
  `AX630C_emmc_arm64_k419_sipeed_maixcam2_defconfig` does, and the Kconfig
  has no `default y`), so `board/axera/ax620e_emmc/ax620e_emmc.c` takes its
  final `#else`: 2 GiB at `0x40000000`. Its `ram_top` is `0xC0000000`, it
  relocates to just under it, and `arm_reserve_mmu()` puts its page tables at
  `0xBFFF0000` -- **physically the same page as ours, `0x7FFF0000`**.
- So "the vendor never writes the top of DRAM" is not true of *this* board's
  vendor build; the `-0x1000` in the retrain branch belongs to a different
  configuration. Mirroring it would have changed nothing, and the top page is
  writable anyway (measured above).

## Where it stops, and how that was measured

Three instrumentation channels were added, each cheaper than the last:

**A scratchpad.** Sixteen words at `0x480EC000`, in the spare tail of the
pstore window, written with `writel()`. With the MMU off those are Device
stores that reach DRAM with no cache flush. The first thing it proved is that
it works at all: word 0 read back `0x55424D31` written from *relocated* code,
so a plain DRAM store post-relocation is fine -- which `printf()` is not
(README.md).

It carried the numbers the register could not:

```
tlb_addr   0x7FFF0000     relocaddr  0x7FF97000     ram_top   0x80000000
tlb_size   0x00004000     start_sp   0x7F695340     ram_size  0x40000000
reloc_off  0x23F96C00     gd         0x7F696E30     flags     0x08000201
```

Every one of them sane, and `tlb_addr` exactly the value README.md had only
been able to derive.

**A number on every initcall.** `board_init_f()` and `board_init_r()` are each
an ordered list of `INITCALL(x)` and the macro is one place, so recording
`__LINE__` there numbers every stage of both for one store apiece. The two
files' line ranges do not overlap, so the number says which phase as well as
which call.

**A timestamp beside it.** `CNTPCT_EL0` is already running at 24 MHz when BL33
is entered, so it is a free stopwatch, and it is what separates a hang from a
timeout.

Results, in order:

| Build | Last initcall | Elapsed | Reading |
|---|---|---|---|
| no-MMU | `board_r.c:630` = `initr_dm` | -- | got much further than any MMU build |
| no-MMU + DM bind trace | `board_r.c:630`, last node bound `pstore@4…` | -- | the last of the four `/reserved-memory` children |
| + `ax630c_check_reloc()` | `board_f.c:1025` = `cyclic_unregister_all`, the **last** initcall of `board_init_f` | -- | moved *earlier* for a 30-instruction change |
| + `CNTPCT_EL0` | same | **0.1223 s** | not a timeout |
| + a marker at the top of `board_init_r()` | same | 0.1223 s | **`board_init_r()` never entered** |

So: `board_init_f()` completes, and control never arrives in `board_init_r()`.
Everything between is `relocate_code()`, the BSS clear and
`c_runtime_cpu_setup()` in `arch/arm/lib/crt0_64.S`.

**And it is layout-sensitive.** The two builds without `ax630c_check_reloc()`
relocated successfully and ran hundreds of driver-model binds; adding one small
static and a handful of instructions moved the failure back into
`relocate_code()` itself. A relocation bug that depends on which relocation
entries an image happens to contain looks exactly like this.

That also re-reads the original MMU-on failure. `mmu_setup()` was never the
subject: it was simply the first substantial post-relocation work in a build
whose relocation had left something wrong.

## The 65 s is the recovery, not the cause

Every failed slot-B attempt has taken ~110 s round trip, of which the slot-A
boot is ~45 s -- a constant ~65 s in slot B, across failure points from
`relocate_code` to `initr_dm`. That constancy was suspicious enough to test:
WDT0 is running on slot A (`EN=1`, `TORR=0x2AEA`, 30 s per stage, armed by the
vendor U-Boot and petted by Linux), so a copy of it surviving the chip reset
would cut every slot-B boot at 60 s regardless of what U-Boot was doing.

Stretched to `TORR=0xD693` (150 s per stage) from Linux before the reboot
(`harness/stretch-wdt.sh`, `timeleft` confirmed the write at 149), the slot-B
duration did not change. And the timestamp above settles it independently:
U-Boot stops **0.12 s** in. Whatever resets the board at ~65 s is a recovery
path, and a welcome one -- it is why fourteen failed slot-B boots have needed
no hands.

## What to try next

1. **Read `.rela.dyn`.** `relocate_code()` walks it applying
   `R_AARCH64_RELATIVE`; the build that fails and the build that does not differ
   only in content. Dump both images' relocation sections and diff the *types*
   present, not just the count.
2. **Instrument `crt0_64.S`/`relocate_code`** with the same scratchpad: a word
   before the copy, after the copy, after the `.rela` loop, and at the branch to
   `board_init_r`. That splits the remaining window into four.
3. **Check `__image_copy_end` versus the appended DTB.** `mon_len` (0x59100)
   is smaller than the image on flash (0x5AF50), and the device tree lives in
   that gap. If the copy length and the relocation bounds disagree about the
   DTB, the relocated image is short by exactly the amount that varies with
   build content.

## Device end state

Unchanged from README.md: slot register `0x00000014`, `bootsystem=A`, `atf_b`
holding the rung-1 `.#atf-mainline`, `uboot_b` restored to the vendor image
(md5 `1521dc39f8a50e726c708fde2c8edce2` over 1 536 KiB, verified from the
medium), the environment restored (`6a579b4ea52ced8ea7ab8cafe2b5102a`),
`/boot` back to its single `ver` file, `nanokvm-checkboot` enabled and active,
no failed units, web 200.
