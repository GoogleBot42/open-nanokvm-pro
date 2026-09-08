# Rung 2, 2026-09-08: mainline U-Boot on the AX630C — runs, does not finish

Eight slot-B boots of `.#uboot-mainline` (upstream U-Boot 2026.07 + our
five-patch AX630C port) under the mainline BL31 rung 1 left in `atf_b`, with the
NixOS appliance kernel and an `extlinux.conf` staged on `/boot` (p16).

**Result: mainline U-Boot starts, initialises itself, sizes DRAM correctly and
relocates — and then hangs in `mmu_setup()`, the arm64 page-table build, before
it ever enables the MMU.** Nothing downstream of that ran: no eMMC probe, no
environment, no `extlinux.conf`, no kernel. Every failed attempt landed back on
slot A on its own in ~110 s; the board never needed a hand.

Nothing was written to slot A, `p3`, `p5` or the rootfs. `uboot_b` (p6), the
environment (p7) and `/boot` were restored byte-for-byte afterwards and
hash-verified from the medium.

## What ran, per attempt

The slot register `0x02390024` was cleared to its slot bits before every run and
read back from slot A afterwards. `0x14` in the low byte is slot A re-armed.

| # | Build | Register | Meaning |
|---|---|---|---|
| 1 | `.#uboot-mainline` (shipping) | `0x00000014` | no milestone at all — U-Boot never reached `preboot` |
| 2 | debug v1: hooks in `dram_init`, `dram_init_banksize`, `board_init`, `board_early_init_r`, `misc_init_r`, `board_late_init` | `0x00003014` | 12, 13 — DRAM sizing done, `board_init` (post-relocation) never reached |
| 3 | debug v2: `enable_caches()` overridden, `board_get_usable_ram_top()` prints gd | `0x0000F014` | 12, 13, 14, 15 — **`relocate_code()` returned**, `icache_enable()` returned, `dcache_enable()` did not |
| 4 | debug v3: `dcache_enable()` unrolled into its four steps | `0x0020F014` | + 21 — `__asm_invalidate_tlb_all()` returned, **`mmu_setup()` did not** |
| 5 | debug v4: `mmu_setup()` replaced with a printf-instrumented copy | `0x0020F014` | unchanged, and **not one of its `printf()`s reached the pre-console buffer** |
| 6 | debug v5: the same copy with milestone bits as well as printfs | `0x0C20F014` | + 26, 27 — `mmu_setup()` entered, `get_tcr()` returned, `setup_pgtables()` did not |
| 7 | debug v6: + DRAM probes at the page-table window, + page-table address published through the register | `0x0420F014` | 26 but not 27 — one step earlier than run 6, so the stopping point moves a little between runs |
| 8 | debug v6 + the `mem_map` fix below | `0x0C20F014` | 26, 27 — identical to run 6. The fix changed nothing |

Bit map for the debug builds (`pkgs/uboot-mainline.nix`, `debugMilestones`):
12 `dram_init`, 13 `dram_init_banksize`, 14 `enable_caches` entered,
15 `icache_enable` returned, 21 TLB invalidate returned, 26 `mmu_setup` entered,
27 `get_tcr` returned, 29 `setup_pgtables` returned, 30 TTBR/TCR/MAIR written,
22 `mmu_setup` returned, 23 MMU on, 24 dcache invalidated, 25 `SCTLR.C` set,
16 `board_init`, 17 `board_early_init_r`, 19 `misc_init_r`, 20 `board_late_init`.
These overlap Linux's shipping assignment on purpose: a run that needs this
build is a run that never reaches Linux.

## Facts established on hardware

- **The SPL → mainline BL31 → mainline U-Boot handoff works.** U-Boot prints its
  banner, so it was entered in AArch64 at EL1h with a working stack, and its own
  early init, device tree and console all came up. Rung 1's `INIT_UNUSED_NS_EL2`
  fix carries rung 2 as well.
- **The board has 1 GiB of DRAM and it does not alias.** Writes to `0x5ff00000`
  and `0x7ff00000` read back independently, and so do `0x7fff0000` and
  `0x7ffff000`. So `dts/ax630c-nanokvm-pro.dts`'s `memory@40000000` node is
  right, and the vendor U-Boot's hardcoded `gd->ram_size = 0x80000000` (2 GiB,
  `board/axera/ax620e_emmc/ax620e_emmc.c`) is a number the hardware does not
  back — it works only because that U-Boot never touches the top of what it
  claims.
- **Relocation succeeds.** `enable_caches()` runs from the relocated image at
  the top of DRAM (`gd->ram_top` = `0x80000000`, monitor 0x59100 bytes).
- **`get_page_table_size()` = 0x4000, so the page tables land at `0x7FFF0000`,
  which was probed writable in the same boot.** The inputs to the thing that
  hangs are all sane.
- **`printf()` is dead after relocation on this board** — even with
  `GD_FLG_HAVE_CONSOLE` cleared so that `puts()` can only reach the pre-console
  buffer, nothing appears. The pre-console buffer is a *pre-relocation* channel
  here and nothing more; post-relocation evidence has to go through the slot
  register.
- **Sizing `mem_map`'s DRAM entry to `gd->ram_size` does not fix it.** The port
  mapped a flat 4 GiB of normal memory over 1 GiB of DRAM, which is worth fixing
  on its own (and is now fixed in patch 0001), but it is not the cause: run 8
  reproduced run 6 exactly.

## Where it stops

Inside `mmu_setup()` (`arch/arm/cpu/armv8/cache_v8.c`), after `get_tcr()`
returns and at or before `setup_pgtables()` returns. `setup_pgtables()` does two
things this board has not otherwise been made to do post-relocation: it calls
`memset()` on 4 KiB at `0x7FFF0000`, and it walks `mem_map` through
`add_map()`/`map_range()` writing block PTEs. The first `printf()` placed in the
same region also fails to produce output, so "a plain DRAM write at the top of
memory, from relocated code, with the MMU off" is the common shape of both.

Not yet ruled out, in rough order of suspicion:

1. The relocation is incomplete in a way the milestone writes cannot see — e.g.
   `.rela.dyn` entries for data pointers (`mem_map` itself is one) not applied,
   so complex code reads plausible-looking garbage. `get_tcr()` reading
   `mem_map` worked, which argues against it, but it also stopped one step
   earlier on run 7 than on runs 6 and 8, and that non-determinism has to come
   from somewhere.
2. Something about writing DRAM from relocated code with the MMU off that the
   pre-relocation image does not do.
3. A fault taken with no usable vector table, which would look exactly like a
   hang because the handler's `printf()` cannot reach the buffer either.

The next probe wants the exception vectors: install a minimal
`do_bad_sync`/`do_bad_error` that writes a milestone bit instead of printing,
so "hang" and "abort" stop being indistinguishable.

## Harness

`harness/` holds the three scripts the runs used, unchanged:

- `arm-slotb.sh` — sets `preboot` and `bootcmd` in the environment, zeroes the
  pre-console buffer, clears milestone bits 12-31, arms `SLOTB | SLOTB_BOOTABLE`.
- `run2.sh` — writes the image under test to `uboot_b` (p6), hash-verifies it
  from the medium after `drop_caches`, then runs `arm-slotb.sh`.
- `restore.sh` — puts p6, p7 and `/boot` back and re-arms slot A.
- `extlinux.conf` — the boot entry staged on p16, with `APPEND` copied verbatim
  from the appliance's own `/proc/cmdline`.

`preconsole-final.txt` is the pre-console buffer from the last run, annotated.

## The environment, and why only two variables were written

Mainline U-Boot and the vendor-derived U-Boot share the environment at p7
(`0x4C0000`, 1 MiB, non-redundant), and a valid stored environment **replaces**
the built-in default wholesale — `env_import()` calls `himport_r()` without
`H_NOCLEAR`. The stored environment on this device is `baudrate`, `bootargs`,
`bootcmd=axera_boot`, `bootdelay=0`, `bootsystem=A`, `fdtcontroladdr`, so a
mainline U-Boot booting against it has **no** `bootcmd` it understands, no
`preboot`, and none of `CFG_EXTRA_ENV_SETTINGS`. That is a real trap for rung 3
and for the final layout: the first boot of a mainline U-Boot on a device whose
environment was written by the vendor one needs `env default -a; saveenv`, or an
environment partition of its own.

Two variables were set with `fw_setenv` for the test, both provably invisible to
the vendor U-Boot on slot A:

- `preboot` — the vendor defconfig does not set `CONFIG_USE_PREBOOT`, so its
  `main_loop()` never runs the variable.
- `bootcmd` — the vendor's `setup_boot_mode()` (`cmd/axera/setup_boot/setup_boot.c`)
  runs from `board_late_init()` and `env_set("bootcmd", ...)`s unconditionally
  on every path before autoboot, then `env_save()`s. So a stored `bootcmd` is
  overwritten before it can run, and self-heals on the next slot-A boot.

`bootcmd` was made self-contained (`setenv` for every address it needs, then
`load` / `sysboot` on `mmc 0:16`) so that no other variable had to be stored.
`preboot` also arms WDT0 the way the vendor U-Boot's `board_late_init()` does
(`TORR = 0x2aea`, strobe `TORR_LOAD`, mux to 24 MHz, `EN = 1`; 60 s), so a hang
after that point would have rescued itself — the mainline kernel already adopts
and pets a U-Boot-armed WDT0 today, which is why that was safe to add.

## Device end state

Slot register `0x00000014`, `bootsystem=A`, `atf_b` still holding the rung-1
`.#atf-mainline`, `uboot_b` restored to the vendor image
(md5 `1521dc39f8a50e726c708fde2c8edce2` over 1 536 KiB), the environment restored
(`6a579b4ea52ced8ea7ab8cafe2b5102a` over 1 MiB), `/boot` back to its single
`ver` file, `nanokvm-checkboot` enabled and active, no failed units, web 200.
Every image and backup used is in `/root/rung2/` on the device.
