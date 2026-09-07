# AX630C (AX620E) reset controller — mainline driver specification

Issue #76 (and every #26 child that needs a reset line). Written 2026-09-06 from
the GPL-2.0 vendor 4.19 kernel and the vendor U-Boot 2020.04. This is a data
specification: a driver author needs nothing from the vendor tree beyond this
file.

**Sources.** `$K` = the vendor kernel tree
(`.../linux/linux-4.19.125`). Citations are `axera_reset.c:NNN` (=
`$K/drivers/reset/axera_reset/axera_reset.c`), `core.c:NNN` (=
`$K/drivers/reset/core.c`), `AX620E_resets.dtsi:NNN`, `AX620E.dtsi:NNN`,
`AX630C_fastemmc.dtsi:NNN` (= `AX630C_fastemmc_arm64_k419.dtsi`), or a vendor
driver under `$K/drivers/`. `$U` = the vendor U-Boot
(`/nix/store/k7b551m83qh9dpxdkvgjgjjc3w2rhknn-source/boot/uboot/u-boot-2020.04`);
citations are `ax620e.h:NNN` (= `$U/arch/arm/include/asm/arch-axera/ax620e.h`)
and the named file under `$U/`. `$M` = mainline Linux 7.1.3, the kernel this
project builds.

**Evidence marking.** Every fact is **V** (read directly out of a cited source
file) or **I** (inferred — the reasoning is always stated). Anything that could
not be resolved is called out as a **GAP**, not guessed.

**Companion specs.** `clk-model-20260906.md` covers the same eight syscon
windows from the clock side; §2 below closes four of its GAPs.
`wdt-model-20260906.md` is the third of the set.

---

## 1. Provider topology

### 1.1 The eighteen DT nodes

All eighteen carry `compatible = "axera,axera_reset_match", "syscon"` and a
64 KiB `reg` window (V, `AX620E_resets.dtsi:8-114`). They cover **eight**
windows; seven of the eight also carry a clock-controller node over the same
address (V, cross-referenced with `clk-model-20260906.md` §1.1).

| Window | `#reset-cells = <3>` | `<4>` | `<10>` | Clock node? |
|---|---|---|---|---|
| `0x0190_0000` cpu | `cpu_reset` | `cpu_reset_ext` | — | `cpu_clk` |
| `0x0234_0000` comm | `comm_reset` | — | `comm_reset_async` | `common_clk` |
| `0x0250_0000` isp | `isp_reset` | — | — | `isp_clk` (no driver) |
| `0x0403_0000` vpu | `vpu_reset` | — | `vpu_reset_async` | `vpu_clk` |
| `0x0443_0000` mm | `mm_reset` | `mm_reset_4` | `mm_reset_async` | `mm_clk` |
| `0x0460_0000` dispc | `dispc_reset` | — | `dispc_reset_async` | `dispc_clk` |
| `0x0487_0000` periph | `periph_reset` | `periph_reset_ext` | `periph_reset_async` | `periph_clk` |
| `0x1003_0000` flash | `flash_reset` | `flash_reset_ext` | `flash_reset_async` | `flash_clk` |

Eight `<3>`, four `<4>`, six `<10>` = 18. Matches the stated invariant exactly.
The ninth clock window, `pllc` at `0x0221_0000`, has no reset node.

**`isp_reset` has zero consumers.** No `resets =` property in any DT in the
vendor tree references it (V, exhaustive grep over
`$K/arch/arm64/boot/dts/axera/`). It is a dead node. Mainline should not
describe it.

### 1.2 Why one window has two or three provider nodes

**The variants are not different hardware.** They are three *software*
behaviours over the same register bits, selected by which phandle a consumer
names. This is the single most important fact in the document and it is proven
directly:

| | `AX620E.dtsi:700` (our board) | `AX630C_fastemmc.dtsi:611` |
|---|---|---|
| audio_codec `prst` | `<&comm_reset_async 0 0x58 0 0x5C 0x24 8 0x28 8 0x2C 8>` | `<&comm_reset 0 0x54 1>` |

Same SoC, same peripheral, same reset-name, same register bit — bound through
the 10-cell provider in one board file and the 3-cell provider in another (V).
The DT-wide pattern holds: of the 144 distinct lines, **111 are bound through
different cell counts in different board files** and every one of those pairs
resolves to the same (window, register, bit) triple (V, mechanical
cross-reference of all 445 specifiers).

What actually differs:

| Variant | Cells | Behaviour |
|---|---|---|
| plain (`*_reset`) | 3 | Read-modify-write the **value** word. |
| `_ext` / `_4` (`cpu_reset_ext`, `mm_reset_4`, `periph_reset_ext`, `flash_reset_ext`) | 4 | Write the **write-1-to-set** and **write-1-to-clear** alias words. No read. |
| `_async` (`comm/vpu/mm/dispc/periph/flash_reset_async`) | 10 | As `_ext`, plus: on **deassert only**, gate the block's clock off across the release edge and restore it. |

There is no asynchronous-vs-synchronous reset domain, no second register bank
and no different assert protocol. `_ext` versus plain is purely "use the atomic
alias apertures instead of a racy RMW". `_async` adds one behaviour — the clock
cycle around the release edge — and nothing else. The naming is the vendor's;
it does not describe the hardware.

The vendor driver dispatches on `rcdev->of_reset_n_cells`, which it assigns from
the specifier's own `args_count` (V, `axera_reset.c:167-173, 188-194, 237`).
Because each provider node has a fixed `#reset-cells`, the dispatch is stable —
but it is per-controller state written from a per-binding path, which is one of
several reasons not to copy the design.

---

## 2. Register-window model

### 2.1 Value words and alias apertures

Each syscon exposes every writable control word three ways: a plain read/write
**value** word, a **write-1-to-set** alias, and a **write-1-to-clear** alias.
Writing a 1 to a bit of an alias acts on that bit; writing a 0 does nothing;
neither alias is read.

There are **two alias families**, and this document establishes both:

**Family A — constant stride.** The alias is the value offset plus a fixed
constant.

| Window | Set alias | Clear alias | Evidence |
|---|---|---|---|
| cpu `0x1900000` | `off + 0x1000` | `off + 0x2000` | V — `ax620e.h:44-45`, `sdhci-axera.c:117-118` |
| flash `0x10030000` | `off + 0x4000` | `off + 0x8000` | V — `ax620e.h:56-57`, `sdhci-axera.c:107-108`, `$U/cmd/axera/gzipd/ax_gzipd_reg.h:71,78-79` |
| comm `0x2340000` | `off + 0x4` | `off + 0x8` | V — `$U/cmd/axera/riscv/boot_riscv.c:20,23` names `+0x58`/`+0x5C` SET/CLR for the word at `0x54`; the 3-cell DT binding at `AX630C_fastemmc.dtsi:611` names that same word |
| pllc `0x2210000` | `off + 0x4` | `off + 0x8` | V — `clk-model-20260906.md` §1.3 |

**Family B — a separate alias aperture, two words per value word.** The alias
pair for the value word at `off` is at `BASE + 2*off` (set) and `BASE + 2*off +
4` (clear). Only `BASE` differs per window.

| Window | `BASE` | Datapoints | Evidence |
|---|---|---|---|
| periph `0x4870000` | `0xA8` | `0x00→0xA8`, `0x04→0xB0`, `0x08→0xB8`, `0x0C→0xC0`, `0x10→0xC8`, `0x14→0xD0`, `0x18→0xD8`, `0x1C→0xE0`, `0x20→0xE8`, `0x24→0xF0` | V — `clk-model-20260906.md` §1.3 for `0x00`–`0x14`; `ax620e.h:94-97` for `0x18`/`0x1C`; the 3-cell/4-cell DT pairs below for `0x18`, `0x1C`, `0x20` |
| mm `0x4430000` | `0xA4` | `0x04→0xAC`, `0x08→0xB4`, `0x10→0xC4` | V — `AX620E.dtsi:1451,1559` (10-cell clock triples) and `AX620E.dtsi:1338` vs `1451` (3-cell `0x10` vs 4-cell `0xC4`/`0xC8`) |
| dispc `0x4600000` | `0xA0` | `0x08→0xB0`, `0x0C→0xB8` | V — `AX620E.dtsi:1723` carries both forms in one property: `<&dispc_reset 10 0xc 1>` and `<&dispc_reset_async 12 0xB8 12 0xBC 0x8 8 0xB0 8 0xB4 8>`; corroborated by `$U/board/axera/ax620e_emmc/pinmux.c:12` (`DPHYTX_SW_RST_SET 0x46000B8`) |
| vpu `0x4030000` | `0x104` | `0x08→0x114`, `0x0C→0x11C` | V — `AX620E.dtsi:1402` (10-cell) vs `AX630C_fastemmc.dtsi` 3-cell `<&vpu_reset 6 0xC 1>` |

**This closes the four GAPs in `clk-model-20260906.md` §1.3** (dispc, mm, vpu,
isp alias schemes) and confirms its (I) for common. dispc, mm and vpu use the
periph scheme with a different base, so `clk-ax630c-tables.c` should give them
an `alias_map` rather than `.has_alias = false`. isp remains unknown — no
consumer, no citation, and no reason to care.

### 2.2 The reset value words

| Window | Value word | Alias set / clear | Name in firmware | Evidence |
|---|---|---|---|---|
| cpu | `0x10` | `0x1010` / `0x2010` | `CPU_SYS_GLB_SW_RST0` | V — `ax620e.h:44-45` |
| comm | `0x54` | `0x58` / `0x5C` | `COMM_SYS_GLB_SW_RST_0` | V — `boot_riscv.c:20,23`; 3-cell DT `AX630C_fastemmc.dtsi:611` |
| vpu | `0x0C` | `0x11C` / `0x120` | — | V — 3-cell/10-cell DT pair |
| mm | `0x10` | `0xC4` / `0xC8` | — | V — `AX620E.dtsi:1338` vs `1451` |
| dispc | `0x0C` | `0xB8` / `0xBC` | `DPHYTX_SW_RST` (set) | V — `AX620E.dtsi:1723`; `pinmux.c:12` |
| periph | `0x18` (RST0) | `0xD8` / `0xDC` | `PERI_SYS_GLB_CLK_RST0` | V — `ax620e.h:94-95`; 3-cell DT |
| periph | `0x1C` (RST1) | `0xE0` / `0xE4` | `PERI_SYS_GLB_CLK_RST1` | V — `ax620e.h:96-97`; 3-cell DT |
| periph | `0x20` (RST2) | `0xE8` / `0xEC` | — | V — alias arithmetic + `AX620E.dtsi:144` etc. |
| periph | `0x24` (RST3) | `0xF0` / `0xF4` | — | I — Family-B arithmetic. No consumer uses it. |
| flash | `0x14` (RST0) | `0x4014` / `0x8014` | `FLASH_SYS_GLB_SW_RST0` | V — `ax620e.h:56-57`, `ax_gzipd_reg.h:71,78-79` |
| flash | `0x20` (RST1) | `0x4020` / `0x8020` | — | V — `AX620E.dtsi:772` (`ephy_shutdown`) + Family-A arithmetic |
| isp | — | — | — | GAP — no consumer, no citation |

**Every register offset in every specifier is a raw byte offset into that node's
64 KiB syscon window.** Nothing is packed into high bits. `0x1010` vs `0x2010`
and `0x4014` vs `0x8014` are set/clear alias addresses of the same 32-bit
register (`0x10` and `0x14` respectively), and the reason the two windows differ
in the bit position that changes is simply that they were given different alias
aperture strides — `0x1000`/`0x2000` on cpu, `0x4000`/`0x8000` on flash. Both
land inside the 64 KiB window (`max_register` for a syscon regmap over a 64 KiB
resource is `0xFFFC`), so both are directly addressable.

---
