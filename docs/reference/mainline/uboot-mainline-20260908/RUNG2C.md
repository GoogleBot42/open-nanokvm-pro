# Rung 2c, 2026-09-08: the relocation offset is wrong by 0x400

Six more slot-B boots. The BSS-overlays-`.rela.dyn` hypothesis is **refuted for
the shipping code path** — and confirmed as the cause of rung 2b's
`relocate_code()` failures, which were self-inflicted by the instrumentation.
Underneath it is a different and much sharper bug:

**U-Boot relocates itself to `0x7FF96400`, while `gd->relocaddr` says
`0x7FF96000` and `gd->reloc_off` says `0x23F95C00`. Everything is 0x400 out.**

## The measurement

All from the scratchpad at `0x480EC000`, read back from slot A.

```
pre-relocation      _start              0x5C000400   == link address, correct
                    __image_copy_start  0x5C000400   == link address, correct
                    __image_copy_end    0x5C050AB0

post-relocation     __image_copy_start  0x7FF96400   <- where the code IS
                    gd->relocaddr       0x7FF96000   <- where gd says it is
                    gd->reloc_off       0x23F95C00   <- 0x7FF96000 - 0x5C000400

                    actual shift        0x23F96000   = 0x7FF96400 - 0x5C000400
                    disagreement        0x400
```

So the first-stage loader puts the image exactly where it is linked — that half
is right, and it rules out a load-address/header mix-up. The disagreement
appears *during* relocation: the code ends up running, and the fixups end up
applied, at `+0x23F96000`, while U-Boot's own bookkeeping records
`+0x23F95C00`.

## What that breaks, and why it presents as an MMU bug

`mem_map` is an ordinary initialised pointer in `.data` with a correct
relocation in the ELF:

```
00005c04f0a0  000000000403 R_AARCH64_RELATIV   5c04f0a8      (= &ax620e_mem_map)
000000005c04f0a0 D mem_map
000000005c04f0a8 d ax620e_mem_map
```

On the board, after relocation:

```
&mem_map     0x7FFE50A0     = 0x5C04F0A0 + 0x23F96000   consistent with the code
 mem_map     0x7FFAFB98     expected 0x7FFE50A8         WRONG -- points into .text
 mem_map[0].virt   0xA9BF7BFD     stp x29, x30, [sp, #-16]!
 mem_map[0].size   0xA8C17BFD     ldp x29, x30, [sp], #16
 mem_map[1].size   0xF9400C04     ldr x4, [x0, #24]
 mem_map[1].attrs  0xD61F0200     br  x16
```

`mem_map` reads as **AArch64 instructions**. The only loop in `get_tcr()` is

```c
	for (i = 0; mem_map[i].size || mem_map[i].attrs; i++)
		max_addr = max(max_addr, mem_map[i].virt + mem_map[i].size);
```

which now walks machine code looking for a 16-byte run of zeros. Sometimes it
never finds one and runs off into addresses no slave answers — the hang inside
`get_tcr()`. Sometimes it terminates by luck on a zero run, returns a nonsense
`max_addr`, and `setup_pgtables()` then maps nonsense regions — the hang inside
`setup_pgtables()`. **Both were observed, and they are the same bug.**

That is why every earlier diagnosis pointed at the MMU: `mmu_setup()` is simply
the first code to dereference a relocated `.data` pointer.

## The failure is deterministic

The same binary was run twice — the one thing eight earlier boots never did,
because each used a different build.

| | slot register | last initcall | elapsed |
|---|---|---|---|
| run 1 | `0x0420F014` | `board_r.c:606` (`initr_caches`) | 0x0031886C = 0.1353 s |
| run 2 | `0x0420F014` | `board_r.c:606` | 0x003181F0 = 0.1352 s |

Identical, to 1.8 ms. The apparent non-determinism of rungs 2 and 2b was
entirely "different binary, different layout, different garbage".

## `.rela.dyn` is intact — and rung 2b's failure was self-inflicted

`ax630c_check_rela()` walks the table validating every entry (each must be
`R_AARCH64_RELATIVE`, `r_info = 0x403`, `r_offset` inside the copied image) and
sums it. Run on entry to `board_init_f` and again as the last initcall before
`relocate_code()`:

```
                 entries   bad   sum
early            0x678     0     0x765D50B4
late             0x678     0     0x765D50B4
host (readelf)   1656      -     0x765D50B4
```

1656 entries, none malformed, sum identical to the host at both ends. **Nothing
clobbers the relocation table in the shipping path.**

But the mechanism the coordinator described is real, and rung 2b hit it: BSS
overlays `.rela.dyn` on arm64 —

```
__image_copy_end = __rel_dyn_start = __bss_start = 0x5C04FAD0
__bss_end = 0x5C059028      __rel_dyn_end = _end = 0x5C059610
```

— and rung 2b's device-name tracer used `static unsigned int ax630c_bind_count`
inside `lists_bind_fdt()`, which **`initf_dm()` calls before relocation**. That
write landed on a relocation entry. It is why those builds died in
`relocate_code()` and why the failure moved when a single static was added, and
it is why the counter read back as `0x5C04EAC7` — a link-time address, i.e. the
content of a relocation entry. Removing it put relocation back.

Lesson worth keeping: **instrumentation for a pre-relocation code path may not
use a static.** Everything in this rung writes through `writel()` to a fixed
address instead.

## What is not the cause

- Not the load address: `_start` runs at `0x5C000400`, its link address.
- Not the relocation table: validated intact, twice, against the host.
- Not the toolchain: the ELF's relocation for `mem_map` carries the right
  addend.
- Not the MMU, the page-table window, DRAM size or aliasing (rung 2b), or the
  watchdog (rung 2b).

## Next probe

The disagreement is between the value `relocate_code()` was called with and
what `gd` records. `arch/arm/lib/crt0_64.S` loads both from the *same* struct:

```
	ldr	x18, [x18, #GD_NEW_GD]
	adr	lr, relocation_return
	ldr	x9, [x18, #GD_RELOC_OFF]	/* return address adjustment */
	add	lr, lr, x9
	ldr	x0, [x18, #GD_RELOCADDR]	/* copy destination */
	b	relocate_code
```

and `relocate_code` recomputes its own `x9 = x0 - _TEXT_BASE`. For the code to
run at `+0x23F96000` while `gd->reloc_off` reads `0x23F95C00`, `x0` must have
been `0x7FF96400`. Two things can do that, and one round separates them:

1. **`asm-offsets` disagreeing with `struct global_data`** — `GD_RELOCADDR` or
   `GD_RELOC_OFF` pointing at a neighbouring field. Check
   `include/generated/asm-offsets.h` against the struct first; it costs nothing.
2. **`gd->relocaddr` changing between `setup_reloc` (board_f.c:1010) and the
   branch**, or `new_gd` not being the struct the later dump reads.

The measurement that settles it: four scratchpad words written from
`crt0_64.S` immediately before `b relocate_code` (x0 and x9 as loaded) and two
from the top of `relocate_code` (x0, and x9 after `subs x9, x0, x1`). If the
words disagree with `gd`, it is (1); if they agree and the running code still
lands 0x400 high, it is the copy/branch pairing.

## Device end state

Slot register `0x00000014`, `bootsystem=A`, `atf_b` still the rung-1
`.#atf-mainline`, `uboot_b` restored to the vendor image
(md5 `1521dc39f8a50e726c708fde2c8edce2` over 1 536 KiB, verified from the
medium), `/boot` back to its single `ver` file, the environment back to the
vendor's own six variables with no `preboot` (its md5 moves on every boot
because the vendor U-Boot rewrites `boot_reason` into `bootargs` and calls
`env_save()`), `nanokvm-checkboot` enabled and active, no failed units, web 200.
