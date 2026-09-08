# Rung 2d, 2026-09-08: the relocation fix works, and U-Boot runs end to end

**Fixed.** `relocaddr` now keeps `CONFIG_TEXT_BASE`'s page offset, the
relocation offset is a whole number of pages, and every relocated pointer reads
back correctly. Mainline U-Boot then runs the whole of `board_init_r` for the
first time: MMU, driver model, both Cadence SD4HC controllers, the environment,
the console, `main_loop`, `preboot`, `bootcmd`.

It does not boot Linux yet. Two further bugs, both named by the board's own
console log — which this rung also made readable for the first time.

## The fix, measured

`common/board_f.c` `reserve_uboot()` rounds `gd->relocaddr` down to a page. On
arm64 every symbol reference the compiler emits is an `adrp`/`:lo12:` pair:
`adrp` supplies the page of the runtime PC and `:lo12:` adds the *link-time*
page offset, so the pair is only correct when the image moved by a whole number
of pages. `CONFIG_TEXT_BASE` here is `0x5C000400` — the first-stage loader
enters BL33 past a 1 KiB signed header — so a page-aligned `relocaddr` made the
offset `0x23F95C00`, which is not a page multiple. `.rela.dyn` fixups used that
offset exactly; every `adrp`/`:lo12:` pair landed a page off in one direction or
the other. Patch 0006 keeps TEXT_BASE's page offset instead.

| | before | after |
|---|---|---|
| `gd->relocaddr` | `0x7FF96000` | `0x7FF95400` |
| `gd->reloc_off` | `0x23F95C00` (not a page multiple) | `0x23F95000` (page multiple) |
| `__image_copy_start`, post-reloc, adrp-derived | `0x7FF96400` — **0x400 out** | `0x7FF95400` — **agrees** |
| `mem_map` | `0x7FFAFB98`, into `.text` | `0x7FFE4090` = link `0x5C04F090` + `0x23F95000` |
| `mem_map[0..1]` | AArch64 instructions | `0/0x40000000`, `0x40000000/0x40000000` |

`mmu_setup()`, which every previous rung died inside, now completes:

```
mmu: tlb 7fff0000 size 8000 fill 0 el 1
mmu: tcr 80803520 va_bits 32
mmu: setup_pgtables
mmu: pgtables done, fill 7fff3000
mmu: set_ttbr_tcr_mair
mmu: done
```

## A real console, on a board that has none

Two changes turn `CONFIG_PRE_CONSOLE_BUFFER` into a full boot log:

1. **A third `mm_region` mapping the pstore window `0x48000000 + 1 MiB` as
   `MT_DEVICE_NGNRNE`.** The moment `dcache_enable()` started working, both
   evidence channels this campaign is built on went dark — `writel()` to the
   scratchpad and `pre_console_putc()` alike land in a cache that a chip reset
   discards. An uncached mapping over reserved memory fixes both, and it is what
   Linux does with the same window anyway.
2. **`board_late_init()` clears `GD_FLG_HAVE_CONSOLE`**, so `puts()` takes the
   `pre_console_putc()` path for the rest of the boot.
   `print_pre_console_buffer()` restores `precon_buf_idx` after its flush, so
   the buffer stays live past `console_init_r`.

The result is banked verbatim in
[`uboot-console-20260908.txt`](uboot-console-20260908.txt). It is the single
most useful instrument built in this campaign.

## The two bugs it named

**1. `** Invalid partition 22 **` / `Couldn't find partition mmc 0:16`.**
`blk_get_device_part_str()` parses the partition in a `dev:part` string with
**base 16**. `mmc 0:16` therefore addresses partition 0x16 = 22. p16 is
`mmc 0:10`. `bootpart` is now injected and asserted in hex
(`pkgs/uboot-mainline.nix`, `pkgs/uboot-mainline-check.nix`, and the
upstream-visible default in patch 0001). This is not a build error in any
form — only the board says it.

**2. `Loading Environment from MMC... Transfer data timeout`.**
The environment read fails and U-Boot falls back to the built-in default. That
fallback is why the boot got as far as it did, and it also means rung 2's
shared-p7 trap never fired: the stored environment is never successfully read,
so the vendor's six variables cannot shadow `CFG_EXTRA_ENV_SETTINGS`. Still to
diagnose; `CONFIG_ENV_SIZE` is 1 MiB, which is a 2048-block single read and an
unusually large one for an env.

Everything else in the log is a pass: driver model bound 16 devices, **both**
Cadence SD4HC controllers probed with the eMMC as `mmc 0` (sdhci-cadence needed
no patch, as section 11.10 predicted), the console came up, and `bootcmd`
reached its failure path and issued a clean `reset` — `boot_reason=0x01`, not
the `0x05` abnormal reset every earlier rung produced.

## Device state — NEEDS A POWER CYCLE

The run after the `bootpart` fix did not come back. Both routes fast-fail, so
the board is not on the network; it is hung, not slow. The likely reading, given
the fix removed the last blocker before `sysboot`: U-Boot loaded and booted the
kernel, and the appliance's stage 1 hit the trap CLAUDE.md already records — a
NixOS stage-1 `fail()` is interactive, blocking on a console nobody can reach,
while the kernel pets U-Boot's watchdog forever. `panicOnFail=1` lives in
`nixos/loop-test.nix`, not in the flashed product image. That is a hypothesis,
not a measurement.

**A power cycle lands on slot A**: the SPL consumed `SLOTB_BOOTABLE` and the
slot register clears on power loss. No AXDL, nothing irreversible. Slot A
(`p3`, `p5`, `p12`, `p14`, `p17`) was never written in this rung or any other.

What is on the device, all reversible, with `/root/rung2/restore.sh` ready to
undo it:

- `uboot_b` (p6): the rung-2d debug U-Boot. Restore:
  `dd if=/root/rung2/uboot_b.orig of=/dev/mmcblk0p6` → md5
  `1521dc39f8a50e726c708fde2c8edce2` over 1 536 KiB.
- p7: `preboot` and `bootcmd` set by `arm-slotb.sh`. The vendor U-Boot ignores
  `preboot` (no `CONFIG_USE_PREBOOT`) and overwrites `bootcmd` from
  `board_late_init()` before autoboot, so slot A is unaffected either way.
  `/root/rung2/p7-env.orig` restores it exactly.
- `/boot` (p16): `Image`, `ax630c-nanokvm-pro.dtb`, `extlinux/*.conf`.
  `restore.sh` puts back the single `ver` file.

## Next

1. **Power-cycle, then read the evidence.** The slot register and the U-Boot
   console buffer both survive, and between them they say whether `sysboot`
   ran and whether the kernel started. If bit 29 is set without 31, `sysboot`
   succeeded and the problem is downstream in stage 1.
2. **`panicOnFail=1` for any slot-B appliance test**, per CLAUDE.md — the
   flashed image does not carry it, and a stage-1 failure on slot B is
   otherwise indistinguishable from a hang.
3. **The env transfer timeout**, which `bootcount` and `saveenv` need.
