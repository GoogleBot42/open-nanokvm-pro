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
windows from the clock side; §2 below closes three of its alias GAPs.
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
The DT-wide pattern holds: of the 144 distinct lines, **47 are bound through
more than one cell count** — 43 as 3-cell *and* 10-cell, 4 as 3-cell *and*
4-cell — and every one of those pairs resolves to the same (window, register,
bit) triple (V, mechanical cross-reference of all 445 specifiers). A further 91
are only ever bound 4-cell, 5 only 3-cell, 1 only 10-cell.

The four 3-cell/4-cell pairs are the clearest case: `AX620E.dtsi:1451` opens the
`vpp` list with `<&mm_reset_4 21 0xC4 21 0xC8>`, while `AX630C_fastemmc.dtsi:1301`
writes the same bit as `<&mm_reset 21 0x10 1>` — value word `0x10`, alias pair
`0xC4`/`0xC8` (V).

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

**This closes three of the four alias GAPs in `clk-model-20260906.md` §1.3**
(dispc, mm, vpu) and confirms its (I) for common. dispc, mm and vpu use the
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

## 3. The specifier formats, decoded

The vendor `of_xlate` is a straight positional unpack of the phandle args (V,
`axera_reset.c:209-236`). No cell is a bitfield; no cell is scaled.

### 3.1 Three cells

| Cell | Meaning |
|---|---|
| 0 | bit number in the value word |
| 1 | byte offset of the **value** word within the syscon window |
| 2 | polarity flag: 1 = the bit reads/writes 1 while the block is held in reset |

**Cell 2 is 1 in every one of the 131 three-cell specifiers in the tree** (V,
mechanical count over `AX620E.dtsi`, `AX630C_fastemmc.dtsi`,
`AX630C_fastnand.dtsi`). Every reset line on this SoC is active-high. A mainline
driver does not need the field.

Worked example — `AX630C_fastemmc.dtsi:611`, `<&comm_reset 0 0x54 1>`: bit 0 of
`0x0234_0054`, active-high.

### 3.2 Four cells

| Cell | Meaning |
|---|---|
| 0 | bit number, used against the **set** alias |
| 1 | byte offset of the **write-1-to-set** alias |
| 2 | bit number, used against the **clear** alias |
| 3 | byte offset of the **write-1-to-clear** alias |

**Cell 2 equals cell 0 in every one of the 314 four- and ten-cell specifiers in
the tree** (V, mechanical count). It is pure redundancy — the same bit position
in two aliases of one register.

Worked examples, the three #76 needs:

```
emmc: resets = <&cpu_reset_ext   12 0x1010 12 0x2010>,   /* prst    */
               <&cpu_reset_ext   12 0x1010 12 0x2010>,   /* arst    */
               <&cpu_reset_ext   11 0x1010 11 0x2010>;   /* cardrst */
sd:   resets = <&flash_reset_ext 17 0x4014 17 0x8014>,   /* prst    */
               <&flash_reset_ext 16 0x4014 16 0x8014>,   /* arst    */
               <&flash_reset_ext 15 0x4014 15 0x8014>;   /* cardrst */
sdio: resets = <&flash_reset_ext 20 0x4014 20 0x8014>,   /* prst    */
               <&flash_reset_ext 19 0x4014 19 0x8014>,   /* arst    */
               <&flash_reset_ext 18 0x4014 18 0x8014>;   /* cardrst */
```
(V, `AX620E.dtsi:1178-1180, 1190-1192, 1202-1204`.)

Decoded:

| Consumer | Line | Window | Value word | Set alias | Clear alias | Bit |
|---|---|---|---|---|---|---|
| emmc | `prst` **and** `arst` | cpu `0x1900000` | `0x10` | `0x1010` | `0x2010` | 12 |
| emmc | `cardrst` | cpu `0x1900000` | `0x10` | `0x1010` | `0x2010` | 11 |
| sd | `prst` | flash `0x10030000` | `0x14` | `0x4014` | `0x8014` | 17 |
| sd | `arst` | flash `0x10030000` | `0x14` | `0x4014` | `0x8014` | 16 |
| sd | `cardrst` | flash `0x10030000` | `0x14` | `0x4014` | `0x8014` | 15 |
| sdio | `prst` | flash `0x10030000` | `0x14` | `0x4014` | `0x8014` | 20 |
| sdio | `arst` | flash `0x10030000` | `0x14` | `0x4014` | `0x8014` | 19 |
| sdio | `cardrst` | flash `0x10030000` | `0x14` | `0x4014` | `0x8014` | 18 |

**The eMMC's `prst` and `arst` are byte-identical specifiers** (V,
`AX620E.dtsi:1178-1179`). One bit gates both the APB and the AXI reset of the
eMMC host. SD and SDIO each get three genuinely distinct bits. The eMMC
therefore has two lines, not three, and the `arst` name in the vendor DT is
decorative.

Absolute addresses for §9:

| | assert (set alias) | deassert (clear alias) |
|---|---|---|
| emmc host (prst/arst) | `0x0190_1010` ← `BIT(12)` | `0x0190_2010` ← `BIT(12)` |
| emmc card | `0x0190_1010` ← `BIT(11)` | `0x0190_2010` ← `BIT(11)` |
| sd prst / arst / cardrst | `0x1003_4014` ← `BIT(17/16/15)` | `0x1003_8014` ← `BIT(17/16/15)` |
| sdio prst / arst / cardrst | `0x1003_4014` ← `BIT(20/19/18)` | `0x1003_8014` ← `BIT(20/19/18)` |

### 3.3 Ten cells

Cells 0–3 are exactly the four-cell form. Cells 4–9 describe the block's clock
gate.

| Cell | Meaning |
|---|---|
| 0 | reset bit, against the set alias |
| 1 | reset **set** alias offset |
| 2 | reset bit, against the clear alias (always == cell 0) |
| 3 | reset **clear** alias offset |
| 4 | clock-gate **value** word offset |
| 5 | clock-gate bit in the value word |
| 6 | clock-gate **set** alias offset |
| 7 | clock-gate bit, set (always == cell 5) |
| 8 | clock-gate **clear** alias offset |
| 9 | clock-gate bit, clear (always == cell 5) |

Cells 7 and 9 equal cell 5 in every ten-cell specifier in the tree (V,
mechanical count over all 68). Cells 4/6/8 are always a consistent value/set/clear
triple under the window's alias family — which is how §2.1 was derived.

Worked example — `AX620E.dtsi:598`,
`<&periph_reset_async 6 0xE0 6 0xE4 0xC 27 0xC0 27 0xC4 27>`:

- reset bit 6 of periph RST1 (value `0x1C`), set alias `0xE0`, clear alias `0xE4`
- clock gate bit 27 of periph EB2 (value `0x0C`), set alias `0xC0`, clear alias `0xC4`

Both alias pairs are exactly the periph Family-B entries for value words `0x1C`
and `0x0C`.

---

## 4. Semantics of the reset operations

### 4.1 Polarity and self-clearing

Active-high, not self-clearing, in every window: writing a 1 into the bit (value
word or set alias) **holds** the block in reset until a 0 is written back (value
word) or a 1 is written to the same bit of the clear alias. Proven three ways:

- Every 3-cell specifier in the tree carries polarity flag 1 (V, §3.1).
- The vendor U-Boot pulses gzip by writing the set alias, waiting, then writing
  the clear alias — a self-clearing bit would not need the second write (V,
  `$U/cmd/axera/gzipd/ax_gzipd_drv.c:92-95`).
- The vendor U-Boot brings the crypto engine out of reset with clear-alias
  writes only, never a set (V, `$U/cmd/axera/cipher/eip130_drv.c:326-328`).

### 4.2 `assert`

| Provider form | Register operation |
|---|---|
| 3 cells | read the value word, OR in `BIT(bit)`, write it back — one read, one write |
| 4 cells | one write of `BIT(bit)` to the **set** alias; no read |
| 10 cells | identical to the 4-cell case — **the clock gate is not touched on assert** |

(V, `axera_reset.c:88-107` for the RMW, `109-129` for the alias write,
`131-155, 167-173` for the 10-cell dispatch.)

No delay, no polling, no readback, no settling wait anywhere in the driver
(V, whole file). The only assert-side timing figure in the whole vendor stack is
U-Boot's `udelay(10)` between the gzip assert and release (V,
`ax_gzipd_drv.c:92-95`).

### 4.3 `deassert`

| Provider form | Register operation |
|---|---|
| 3 cells | read the value word, clear `BIT(bit)`, write it back |
| 4 cells | one write of `BIT(bit)` to the **clear** alias; no read |
| 10 cells | four steps, below |

The ten-cell release sequence (V, `axera_reset.c:46-86, 131-155`):

1. Read the clock-gate **value** word (cell 4). Remember whether `BIT(cell 5)`
   was set.
2. If it was set, write `BIT(cell 5)` to the gate's **clear** alias (cell 8) —
   the block's clock stops.
3. Write `BIT(cell 0)` to the reset **clear** alias (cell 3) — the block comes
   out of reset with its clock stopped.
4. If step 1 found the gate on, write `BIT(cell 5)` to the gate's **set** alias
   (cell 6) — the clock restarts.

No delay between any of the four steps. If the gate was already off, steps 2 and
4 are skipped and the sequence is identical to the 4-cell case. This is a
release-edge glitch mitigation, and it is the *only* thing the `_async` variants
add.

### 4.4 `reset` (pulse) and `status`

Neither is implemented. `axera_reset_ops` carries `.assert` and `.deassert` only
(V, `axera_reset.c:242-245`), so `reset_control_reset()` returns `-ENOTSUPP`
(V, `core.c:266-267`) and `reset_control_status()` returns `-ENOTSUPP` (V,
`core.c:402-405`). Nothing in the tree calls either on an Axera handle.

A mainline driver can implement both trivially: the value word is readable and
the bit reads back what was written, so `.status` is a `regmap_read` plus a bit
test; `.reset` is assert / delay / deassert, and 10 µs is the only assert width
firmware ever uses (V, `ax_gzipd_drv.c:92-95`).

### 4.5 What a consumer actually does with a handle

Twenty-three vendor drivers take Axera reset handles (V, files under `$K/drivers/`
calling `reset_control_get*`: `crypto/axera/ax_cipher_device.c`,
`dma/axera-dma-per/`, `dma/axera-axi-dmac/`, `gpio/gpio-axera.c`,
`gpu/drm/axera/{ax_drm_virt_connector,ax_drm_lvds,ax_cdns_dsi}.c`,
`i2c/busses/i2c-designware-platdrv.c`, `mmc/host/sdhci-axera.c`,
`net/.../dwmac-axera.c`, `pwm/pwm-axera.c`, `soc/axera/{apb_timer,axera_hrtimer,dma,gzipd,timer32}/`,
`spi/spi-axera-{mmio,slv-mmio,slv-raw}.c`, `spi/spi-dw-mmio.c`,
`tty/serial/8250/8250_axera.c`, `usb/dwc3/dwc3-axera.c`, `watchdog/dw_wdt.c`). The pattern is uniform:

| Driver | At probe | On error / remove |
|---|---|---|
| `mmc/host/sdhci-axera.c:1024-1039, 1091` | deassert `arst`, `prst`, `cardrst` | assert all three |
| `crypto/axera/ax_cipher_device.c:223-227` | deassert all five | — |
| `spi/spi-axera-mmio.c:109,117,170` | deassert `rst`, `prst` | assert |
| `tty/serial/8250/8250_axera.c:407,414,446` | deassert `rst`, `preset` | assert |
| `pwm/pwm-axera.c:412` | deassert `pwm-rst`, then each channel on enable | — |
| `gpio/gpio-axera.c:402-411` | assert then deassert (a manual pulse) | — |
| `soc/axera/gzipd/ax_gzipd_drv.c:573-577` | assert then deassert | — |
| `dma/axera-axi-dmac/…:191-192, 1198-1208` | assert then deassert | — |
| `usb/dwc3/dwc3-axera.c:198-210` | assert then deassert | assert |
| `net/…/dwmac-axera.c:253-262, 351-358` | assert then deassert; `ephy_shutdown` deassert | assert `ephy_shutdown` on suspend |

Every one of them uses `devm_reset_control_get_optional*()`, so a DT with no
`resets` property yields `NULL` and every call is a silent no-op (V,
`core.c:302-305, 355-358`).

---

## 5. What the provider does at probe

**Nothing to the hardware.** `axera_reset_probe()` allocates its private struct,
takes `syscon_node_to_regmap(np)` on its own node, fills in the `rcdev`,
initialises an idr and calls `reset_controller_register()`. There is no register
read, no register write, no "deassert everything", no reset-default programming
(V, `axera_reset.c:247-273`, whole function).

Firmware state is therefore left exactly as the boot chain left it, and lines
change only when a consumer driver asks. **A mainline driver must do the same.**

Two implementation details worth carrying over as warnings rather than as code:

- The driver allocates a fresh `axera_reset_data` and a fresh idr id **per
  `of_xlate` call** (V, `axera_reset.c:204,239`). Two consumers naming the same
  bit get two independent handles, and nothing is ever freed on unbind.
- `rcdev->of_reset_n_cells` is assigned from the specifier inside `of_xlate` (V,
  `axera_reset.c:237`) rather than at registration. Because it starts at 0, the
  vendor had to **comment out the core's `args_count` sanity check** to make the
  first lookup succeed (V, `core.c:505-508` — the `WARN_ON` block is inside
  `/* */`). This is a patch to `drivers/reset/core.c`, not to the driver, and it
  is a hard blocker for upstreaming anything shaped like the vendor design. A
  mainline driver sets `rcdev->of_reset_n_cells = 1` at register time and the
  check passes.

---

## 6. The complete line table

**144 distinct reset lines**, deduplicated on (window, value word, bit), drawn
from **445 (consumer, reset-name) bindings** across `AX620E.dtsi` (157),
`AX630C_fastemmc.dtsi` (144) and `AX630C_fastnand.dtsi` (144). Every one of the
144 appears in `AX620E.dtsi`, which is the file our board includes — the two
`AX630C_*` dtsi files add no line that `AX620E.dtsi` lacks.

Column key:

- **ID** — proposed `dt-bindings/reset/ax630c-reset.h` macro. The number in the
  first column is the value the macro takes; the namespace is per-controller,
  mirroring `ax630c-clock.h`.
- **Reg / bit** — the **value** word offset in that controller's syscon window
  and the bit in it. Set and clear alias addresses follow from §2.1; they are
  not repeated per row.
- **Forms** — which vendor cell counts bind this line somewhere in the tree.
- **Gate** — for lines the vendor also binds through an `_async` provider, the
  clock-gate value word and bit that its release sequence cycles (§4.3). `—`
  means no vendor binding ever asked for the clock cycle.
- **Consumers** — `node-label:reset-name`. Where a `fast*` note appears the
  `AX630C_fastemmc`/`fastnand` files bind a different set of consumers to the
  same bit.

### 6.1 cpu — window `0x0190_0000`, value word `0x10` (`SW_RST0`)

| ID | Name | Reg | Bit | Forms | Gate | Consumers |
|---|---|---|---|---|---|---|
| 0 | `RST_CPU_EMMC_CARD` | 0x10 | 11 | 4 | — | emmc:cardrst |
| 1 | `RST_CPU_EMMC` | 0x10 | 12 | 4 | — | emmc:prst, emmc:arst (identical specifiers) |
| 2 | `RST_CPU_SPI4_PRST` | 0x10 | 17 | 4 | — | spi4:prst |
| 3 | `RST_CPU_SPI4` | 0x10 | 18 | 4 | — | spi4:rst |

### 6.2 comm — window `0x0234_0000`, value word `0x54` (`SW_RST_0`)

| ID | Name | Reg | Bit | Forms | Gate | Consumers |
|---|---|---|---|---|---|---|
| 0 | `RST_COMM_AUDIO_CODEC_PRST` | 0x54 | 0 | 3/10 | 0X24.8 | audio_codec:prst |
| 1 | `RST_COMM_BT_DPI0_CM_DPU_1X` | 0x54 | 26 | 3/10 | 0X24.6 | bt_dpi0:cm_dpu_1x_rst |
| 2 | `RST_COMM_BT_DPI0_CM_DPU_NX` | 0x54 | 27 | 3/10 | 0X24.12 | bt_dpi0:cm_dpu_nx_rst |
| 3 | `RST_COMM_BT_DPI1_CM_DPU_1X` | 0x54 | 28 | 3/10 | 0X24.7 | bt_dpi1:cm_dpu_1x_rst |
| 4 | `RST_COMM_BT_DPI1_CM_DPU_NX` | 0x54 | 29 | 3/10 | 0X24.13 | bt_dpi1:cm_dpu_nx_rst |

U-Boot also drives bits 16 and 17 of this word to bring the on-chip RISC-V core
in and out of reset (V, `$U/cmd/axera/riscv/boot_riscv.c:40-50`). No Linux
consumer references them; they are not in the table.

### 6.3 vpu — window `0x0403_0000`, value word `0x0C`

| ID | Name | Reg | Bit | Forms | Gate | Consumers |
|---|---|---|---|---|---|---|
| 0 | `RST_VPU_JENC` | 0x0C | 4 | 3/10 | 0X8.4 | jenc:jenc_rst |
| 1 | `RST_VPU_VDEC` | 0x0C | 6 | 3/10 | 0X8.6 | vdec:vdec_rst |
| 2 | `RST_VPU_VENC` | 0x0C | 7 | 3/10 | 0X8.7 | venc:venc_rst |

### 6.4 mm — window `0x0443_0000`, value word `0x10`

| ID | Name | Reg | Bit | Forms | Gate | Consumers |
|---|---|---|---|---|---|---|
| 0 | `RST_MM_VPP_RST8` | 0x10 | 4 | 3/10 | 0X8.19 | vpp:vpp_rst8, gdc:gdc_rst3, tdp:tdp_rst2, vo0:mm_cdma_prst |
| 1 | `RST_MM_VPP_RST9` | 0x10 | 5 | 3/10 | 0X8.3 | vpp:vpp_rst9, gdc:gdc_rst4, tdp:tdp_rst3, vo0:mm_cdma_rst |
| 2 | `RST_MM_VO1_MM_DPU_OUT` | 0x10 | 7 | 3/10 | 0X4.1 | vo1:mm_dpu_out_rst |
| 3 | `RST_MM_VO1_MM_DPU_PRST` | 0x10 | 8 | 3/10 | 0X8.21 | vo1:mm_dpu_prst |
| 4 | `RST_MM_VO1_MM_DPU` | 0x10 | 9 | 3/10 | 0X8.5 | vo1:mm_dpu_rst |
| 5 | `RST_MM_VO0_MM_DPU_OUT` | 0x10 | 10 | 3/10 | 0X4.2 | vo0:mm_dpu_out_rst |
| 6 | `RST_MM_VO0_MM_DPU_PRST` | 0x10 | 11 | 3/10 | 0X8.20 | vo0:mm_dpu_prst |
| 7 | `RST_MM_VO0_MM_DPU` | 0x10 | 12 | 3/10 | 0X8.4 | vo0:mm_dpu_rst |
| 8 | `RST_MM_GDC_RST0` | 0x10 | 13 | 3/4 | — | gdc:gdc_rst0 |
| 9 | `RST_MM_GDC_RST1` | 0x10 | 14 | 3/10 | 0X8.22 | gdc:gdc_rst1 |
| 10 | `RST_MM_GDC_RST2` | 0x10 | 15 | 3/10 | 0X8.8 | gdc:gdc_rst2 |
| 11 | `RST_MM_IVE_PRST` | 0x10 | 16 | 3 | — | ive:ive_prst |
| 12 | `RST_MM_IVE` | 0x10 | 17 | 3 | — | ive:ive_rst |
| 13 | `RST_MM_TDP_RST0` | 0x10 | 19 | 3/10 | 0X8.24 | tdp:tdp_rst0 |
| 14 | `RST_MM_TDP_RST1` | 0x10 | 20 | 3/10 | 0X8.11 | tdp:tdp_rst1 |
| 15 | `RST_MM_VPP_RST0` | 0x10 | 21 | 3/4 | — | vpp:vpp_rst0 |
| 16 | `RST_MM_VPP_RST1` | 0x10 | 22 | 3/10 | 0X8.13 | vpp:vpp_rst1 |
| 17 | `RST_MM_VPP_RST2` | 0x10 | 23 | 3/10 | 0X8.14 | vpp:vpp_rst2 |
| 18 | `RST_MM_VPP_RST3` | 0x10 | 24 | 3/10 | 0X8.15 | vpp:vpp_rst3 |
| 19 | `RST_MM_VPP_RST4` | 0x10 | 25 | 3/10 | 0X8.16 | vpp:vpp_rst4 |
| 20 | `RST_MM_VPP_RST5` | 0x10 | 26 | 3/10 | 0X8.17 | vpp:vpp_rst5 |
| 21 | `RST_MM_VPP_RST6` | 0x10 | 27 | 3/10 | 0X8.25 | vpp:vpp_rst6 |
| 22 | `RST_MM_VPP_RST7` | 0x10 | 28 | 3/10 | 0X8.12 | vpp:vpp_rst7 |

Four `mm` lines are shared by four consumers each: bits 4 and 5 are
`vpp_rst8`/`vpp_rst9` to `vpp`, `gdc_rst3`/`gdc_rst4` to `gdc`,
`tdp_rst2`/`tdp_rst3` to `tdp` and `mm_cdma_prst`/`mm_cdma_rst` to `vo0` (V,
`AX620E.dtsi:1451,1479,1499,1559`). That is the CDMA block every MM engine sits
behind. A mainline driver must hand those out as **shared** reset controls
(`devm_reset_control_get_optional_shared`), or the first consumer to assert will
reset the DMA under the other three.

### 6.5 dispc — window `0x0460_0000`, value word `0x0C`

| ID | Name | Reg | Bit | Forms | Gate | Consumers |
|---|---|---|---|---|---|---|
| 0 | `RST_DISPC_DSI_DISPC_DPHY2DSI` | 0x0C | 3 | 3/10 | 0X8.2 | dsi:dispc_dphy2dsi_rst |
| 1 | `RST_DISPC_LVDSTX_DPHYTX_PLL_DIV7` | 0x0C | 4 | 3/10 | 0X8.4 | lvdstx:dphytx_pll_div7_rst |
| 2 | `RST_DISPC_LVDSTX_DPHYTX_PLL` | 0x0C | 5 | 3/10 | 0X8.3 | lvdstx:dphytx_pll_rst |
| 3 | `RST_DISPC_DSI_DISPC_DPHYTX` | 0x0C | 6 | 3 | — | dsi:dispc_dphytx_rst |
| 4 | `RST_DISPC_DSI_DISPC_DSI_RX_ESC` | 0x0C | 7 | 3 | — | dsi:dispc_dsi_rx_esc_rst |
| 5 | `RST_DISPC_DSI_DISPC_SYS` | 0x0C | 8 | 3/10 | 0X8.5 | dsi:dispc_sys_rst |
| 6 | `RST_DISPC_DSI_DISPC_TXESC` | 0x0C | 9 | 3/10 | 0X8.6 | dsi:dispc_txesc_rst |
| 7 | `RST_DISPC_DSI_DISPC_TXPIX` | 0x0C | 10 | 3 | — | dsi:dispc_txpix_rst |
| 8 | `RST_DISPC_DSI_DISPC_DSI_PRST` | 0x0C | 12 | 3/10 | 0X8.8 | dsi:dispc_dsi_prst |
| 9 | `RST_DISPC_LVDSTX_LVDS_P` | 0x0C | 13 | 3/10 | 0X8.9 | lvdstx:lvds_p_rst |

Bit 6 (`dispc_dphytx_rst`) is also asserted by the vendor U-Boot before it
re-muxes the six `CDTX_*` pads (V, `$U/board/axera/ax620e_emmc/pinmux.c:12-13,108`).
That is the same D-PHY-parked precondition `dts/ax630c.dtsi` documents for the
pinctrl driver: when #83/#84 land, this line is what
`axera,dphytx-reset` should become.

### 6.6 periph — window `0x0487_0000`, value words `0x18` (RST0), `0x1C` (RST1), `0x20` (RST2)

| ID | Name | Reg | Bit | Forms | Gate | Consumers |
|---|---|---|---|---|---|---|
| 0 | `RST_PERIPH_AUDIO_CODEC` | 0x18 | 0 | 3/10 | 0X4.3 | audio_codec:rst |
| 1 | `RST_PERIPH_DMA_PER_DMAPER_ARST` | 0x18 | 1 | 4 | — | dma_per:dmaper-arst |
| 2 | `RST_PERIPH_DMA_PER_DMAPER_PRST` | 0x18 | 2 | 4 | — | dma_per:dmaper-prst |
| 3 | `RST_PERIPH_PUB_CE_MAIN_SW` | 0x18 | 4 | 4 | — | pub_ce:main_sw_rst |
| 4 | `RST_PERIPH_PUB_CE_CNT_SW` | 0x18 | 5 | 4 | — | pub_ce:cnt_sw_rst |
| 5 | `RST_PERIPH_PUB_CE_SOFT_SW` | 0x18 | 6 | 4 | — | pub_ce:soft_sw_rst |
| 6 | `RST_PERIPH_PUB_CE_SW` | 0x18 | 7 | 4 | — | pub_ce:sw_rst |
| 7 | `RST_PERIPH_PUB_CE_SW_PRST` | 0x18 | 8 | 10 | 0XC.12 | pub_ce:sw_prst |
| 8 | `RST_PERIPH_DMAC` | 0x18 | 9 | 4 | — | dmac:dmac-rst |
| 9 | `RST_PERIPH_AX_GPIO0_GPIO_PRST` | 0x18 | 10 | 4 | — | ax_gpio0:gpio_prst |
| 10 | `RST_PERIPH_AX_GPIO0_GPIO` | 0x18 | 11 | 4 | — | ax_gpio0:gpio_rst |
| 11 | `RST_PERIPH_AX_GPIO1_GPIO_PRST` | 0x18 | 12 | 4 | — | ax_gpio1:gpio_prst |
| 12 | `RST_PERIPH_AX_GPIO1_GPIO` | 0x18 | 13 | 4 | — | ax_gpio1:gpio_rst |
| 13 | `RST_PERIPH_AX_GPIO2_GPIO_PRST` | 0x18 | 14 | 4 | — | ax_gpio2:gpio_prst |
| 14 | `RST_PERIPH_AX_GPIO2_GPIO` | 0x18 | 15 | 4 | — | ax_gpio2:gpio_rst |
| 15 | `RST_PERIPH_AX_GPIO3_GPIO_PRST` | 0x18 | 16 | 4 | — | ax_gpio3:gpio_prst |
| 16 | `RST_PERIPH_AX_GPIO3_GPIO` | 0x18 | 17 | 4 | — | ax_gpio3:gpio_rst |
| 17 | `RST_PERIPH_I2C0_PRST` | 0x18 | 18 | 4 | — | i2c0:prst |
| 18 | `RST_PERIPH_I2C0` | 0x18 | 19 | 4 | — | i2c0:rst |
| 19 | `RST_PERIPH_I2C1_PRST` | 0x18 | 20 | 4 | — | i2c1:prst |
| 20 | `RST_PERIPH_I2C1` | 0x18 | 21 | 4 | — | i2c1:rst |
| 21 | `RST_PERIPH_I2C2_PRST` | 0x18 | 22 | 4 | — | i2c2:prst |
| 22 | `RST_PERIPH_I2C2` | 0x18 | 23 | 4 | — | i2c2:rst |
| 23 | `RST_PERIPH_I2C3_PRST` | 0x18 | 24 | 4 | — | i2c3:prst |
| 24 | `RST_PERIPH_I2C3` | 0x18 | 25 | 4 | — | i2c3:rst |
| 25 | `RST_PERIPH_I2C4_PRST` | 0x18 | 26 | 4 | — | i2c4:prst |
| 26 | `RST_PERIPH_I2C4` | 0x18 | 27 | 4 | — | i2c4:rst |
| 27 | `RST_PERIPH_I2C5_PRST` | 0x18 | 28 | 4 | — | i2c5:prst |
| 28 | `RST_PERIPH_I2C5` | 0x18 | 29 | 4 | — | i2c5:rst |
| 29 | `RST_PERIPH_I2C6_PRST` | 0x18 | 30 | 4 | — | i2c6:prst |
| 30 | `RST_PERIPH_I2C6` | 0x18 | 31 | 4 | — | i2c6:rst |
| 31 | `RST_PERIPH_I2C7_PRST` | 0x1C | 0 | 4 | — | i2c7:prst |
| 32 | `RST_PERIPH_I2C7` | 0x1C | 1 | 4 | — | i2c7:rst |
| 33 | `RST_PERIPH_I2C_SLV0_PRST` | 0x1C | 2 | 4 | — | i2c_slv0:prst |
| 34 | `RST_PERIPH_I2C_SLV0` | 0x1C | 3 | 4 | — | i2c_slv0:rst |
| 35 | `RST_PERIPH_I2C_SLV1_PRST` | 0x1C | 4 | 4 | — | i2c_slv1:prst |
| 36 | `RST_PERIPH_I2C_SLV1` | 0x1C | 5 | 4 | — | i2c_slv1:rst |
| 37 | `RST_PERIPH_I2S_MST0_PRST` | 0x1C | 6 | 3/10 | 0XC.27 | i2s_mst0:prst, i2s_inner_mst0:prst |
| 38 | `RST_PERIPH_I2S_MST0` | 0x1C | 7 | 3/10 | 0X4.16 | i2s_mst0:rst, i2s_inner_mst0:rst |
| 39 | `RST_PERIPH_I2S_SLV0_PRST` | 0x1C | 8 | 3/10 | 0XC.28 | i2s_slv0:prst, i2s_inner_slv0:prst |
| 40 | `RST_PERIPH_I2S_SLV0` | 0x1C | 9 | 3/4 | — | i2s_slv0:rst, i2s_inner_slv0:rst |
| 41 | `RST_PERIPH_I2S_TDM_MST0_PRST` | 0x1C | 10 | 3/10 | 0XC.29 | i2s_tdm_mst0:prst |
| 42 | `RST_PERIPH_I2S_TDM_MST0` | 0x1C | 11 | 3/10 | 0X4.17 | i2s_tdm_mst0:rst |
| 43 | `RST_PERIPH_I2S_TDM_SLV0_PRST` | 0x1C | 12 | 3/10 | 0XC.30 | i2s_tdm_slv0:prst |
| 44 | `RST_PERIPH_I2S_TDM_SLV0` | 0x1C | 13 | 3/4 | — | i2s_tdm_slv0:rst |
| 45 | `RST_PERIPH_PWM0_PWM_CH0` | 0x1C | 15 | 4 | — | pwm0:pwm-ch0-rst |
| 46 | `RST_PERIPH_PWM0_PWM_CH1` | 0x1C | 16 | 4 | — | pwm0:pwm-ch1-rst |
| 47 | `RST_PERIPH_PWM0_PWM_CH2` | 0x1C | 17 | 4 | — | pwm0:pwm-ch2-rst |
| 48 | `RST_PERIPH_PWM0_PWM_CH3` | 0x1C | 18 | 4 | — | pwm0:pwm-ch3-rst |
| 49 | `RST_PERIPH_PWM0_PWM` | 0x1C | 19 | 4 | — | pwm0:pwm-rst |
| 50 | `RST_PERIPH_PWM1_PWM_CH0` | 0x1C | 20 | 4 | — | pwm1:pwm-ch0-rst |
| 51 | `RST_PERIPH_PWM1_PWM_CH1` | 0x1C | 21 | 4 | — | pwm1:pwm-ch1-rst |
| 52 | `RST_PERIPH_PWM1_PWM_CH2` | 0x1C | 22 | 4 | — | pwm1:pwm-ch2-rst |
| 53 | `RST_PERIPH_PWM1_PWM_CH3` | 0x1C | 23 | 4 | — | pwm1:pwm-ch3-rst |
| 54 | `RST_PERIPH_PWM1_PWM` | 0x1C | 24 | 4 | — | pwm1:pwm-rst |
| 55 | `RST_PERIPH_PWM2_PWM_CH0` | 0x1C | 25 | 4 | — | pwm2:pwm-ch0-rst |
| 56 | `RST_PERIPH_PWM2_PWM_CH1` | 0x1C | 26 | 4 | — | pwm2:pwm-ch1-rst |
| 57 | `RST_PERIPH_PWM2_PWM_CH2` | 0x1C | 27 | 4 | — | pwm2:pwm-ch2-rst |
| 58 | `RST_PERIPH_PWM2_PWM_CH3` | 0x1C | 28 | 4 | — | pwm2:pwm-ch3-rst |
| 59 | `RST_PERIPH_PWM2_PWM` | 0x1C | 29 | 4 | — | pwm2:pwm-rst |
| 60 | `RST_PERIPH_SPI0_PRST` | 0x1C | 30 | 4 | — | spi0:prst |
| 61 | `RST_PERIPH_SPI0` | 0x1C | 31 | 4 | — | spi0:rst |
| 62 | `RST_PERIPH_SPI1_PRST` | 0x20 | 0 | 4 | — | spi1:prst |
| 63 | `RST_PERIPH_SPI1` | 0x20 | 1 | 4 | — | spi1:rst |
| 64 | `RST_PERIPH_SPI2_PRST` | 0x20 | 2 | 4 | — | spi2:prst |
| 65 | `RST_PERIPH_SPI2` | 0x20 | 3 | 4 | — | spi2:rst |
| 66 | `RST_PERIPH_AX_HRTIMER_PRESET` | 0x20 | 4 | 4 | — | ax_hrtimer:preset |
| 67 | `RST_PERIPH_AX_HRTIMER` | 0x20 | 5 | 4 | — | ax_hrtimer:reset |
| 68 | `RST_PERIPH_APB_TIMER1_PRESET` | 0x20 | 6 | 4 | — | apb_timer1:preset |
| 69 | `RST_PERIPH_APB_TIMER1` | 0x20 | 7 | 4 | — | apb_timer1:reset |
| 70 | `RST_PERIPH_AX_UART0_PRESET` | 0x20 | 20 | 4 | — | ax_uart0:preset |
| 71 | `RST_PERIPH_AX_UART0` | 0x20 | 21 | 4 | — | ax_uart0:reset |
| 72 | `RST_PERIPH_AX_UART1_PRESET` | 0x20 | 22 | 4 | — | ax_uart1:preset |
| 73 | `RST_PERIPH_AX_UART1` | 0x20 | 23 | 4 | — | ax_uart1:reset |
| 74 | `RST_PERIPH_AX_UART2_PRESET` | 0x20 | 24 | 4 | — | ax_uart2:preset |
| 75 | `RST_PERIPH_AX_UART2` | 0x20 | 25 | 4 | — | ax_uart2:reset |
| 76 | `RST_PERIPH_AX_UART3_PRESET` | 0x20 | 26 | 4 | — | ax_uart3:preset |
| 77 | `RST_PERIPH_AX_UART3` | 0x20 | 27 | 4 | — | ax_uart3:reset |
| 78 | `RST_PERIPH_AX_UART4_PRESET` | 0x20 | 28 | 4 | — | ax_uart4:preset |
| 79 | `RST_PERIPH_AX_UART4` | 0x20 | 29 | 4 | — | ax_uart4:reset |
| 80 | `RST_PERIPH_AX_UART5_PRESET` | 0x20 | 30 | 4 | — | ax_uart5:preset |
| 81 | `RST_PERIPH_AX_UART5` | 0x20 | 31 | 4 | — | ax_uart5:reset |

RST3 (`0x24`, aliases `0xF0`/`0xF4`) has no consumer in any DT.

### 6.7 flash — window `0x1003_0000`, value words `0x14` (RST0), `0x20` (RST1)

| ID | Name | Reg | Bit | Forms | Gate | Consumers |
|---|---|---|---|---|---|---|
| 0 | `RST_FLASH_DMA_ARST` | 0x14 | 2 | 4 | — | dma:dma-arst |
| 1 | `RST_FLASH_DMA_PRST` | 0x14 | 3 | 4 | — | dma:dma-prst |
| 2 | `RST_FLASH_ETH0_EMAC` | 0x14 | 8 | 4 | — | eth0:emac_rst |
| 3 | `RST_FLASH_ETH0_EPHY` | 0x14 | 9 | 4 | — | eth0:ephy_rst |
| 4 | `RST_FLASH_GZIPD` | 0x14 | 10 | 4 | — | gzipd:gzipd_rst |
| 5 | `RST_FLASH_GZIPD_CORE` | 0x14 | 11 | 4 | — | gzipd:gzipd_core_rst |
| 6 | `RST_FLASH_SD_CARDRST` | 0x14 | 15 | 4 | — | sd:cardrst |
| 7 | `RST_FLASH_SD_ARST` | 0x14 | 16 | 4 | — | sd:arst |
| 8 | `RST_FLASH_SD_PRST` | 0x14 | 17 | 4 | — | sd:prst |
| 9 | `RST_FLASH_SDIO_CARDRST` | 0x14 | 18 | 4 | — | sdio:cardrst |
| 10 | `RST_FLASH_SDIO_ARST` | 0x14 | 19 | 4 | — | sdio:arst |
| 11 | `RST_FLASH_SDIO_PRST` | 0x14 | 20 | 4 | — | sdio:prst |
| 12 | `RST_FLASH_SPI_SLV_HRST` | 0x14 | 21 | 4 | — | spi_slv:hrst |
| 13 | `RST_FLASH_SPI_SLV` | 0x14 | 22 | 4 | — | spi_slv:rst |
| 14 | `RST_FLASH_BT_DPI0_FLASH_DPU_1X` | 0x14 | 26 | 3/10 | 0X4.0 | bt_dpi0:flash_dpu_1x_rst, bt_dpi1:flash_dpu_1x_rst |
| 15 | `RST_FLASH_BT_DPI0_FLASH_DPU_NX` | 0x14 | 27 | 3/10 | 0X4.7 | bt_dpi0:flash_dpu_nx_rst, bt_dpi1:flash_dpu_nx_rst |
| 16 | `RST_FLASH_ETH0_EPHY_SHUTDOWN` | 0x20 | 0 | 4 | — | eth0:ephy_shutdown |

**Naming caveat on bits 10 and 11.** The vendor DT calls bit 10 `gzipd_rst` and
bit 11 `gzipd_core_rst` (V, `AX620E.dtsi:1880`); the vendor U-Boot calls bit 11
`GZIPD_SW_RST` and bit 10 `GZIPD_CORE_SW_RST` (V,
`$U/cmd/axera/gzipd/ax_gzipd_reg.h:72-73`). The two sources disagree about which
name goes with which bit. The bits themselves are not in doubt — both are always
pulsed together — but do not read a functional meaning into either macro name.

`bt_dpi0` and `bt_dpi1` share flash bits 26 and 27 (V, `AX620E.dtsi:1646,1681`)
— shared controls again.

### 6.8 Totals

| Window | Distinct lines |
|---|---|
| cpu | 4 |
| comm | 5 |
| vpu | 3 |
| mm | 23 |
| dispc | 10 |
| periph | 82 |
| flash | 17 |
| isp | 0 |
| **total** | **144** |

---

## 7. Reconciliation with the stated invariants

| Invariant | Measured | Verdict |
|---|---|---|
| 18 provider nodes | 18 | agrees |
| `#reset-cells` histogram 8×`<3>`, 4×`<4>`, 6×`<10>` | identical | agrees |
| 8 register windows, 7 shared with a clock node | identical | agrees |
| `resets =` count: `AX620E.dtsi` 59 | 59 properties → **157** specifiers | agrees, but see below |
| `AX630C_fastemmc.dtsi` 53 | 53 properties → **144** specifiers | agrees |
| `AX630C_fastnand.dtsi` 53 | 53 properties → **144** specifiers | agrees |
| `AX630C_nand_arm64_k419.dts` 1 | **0 real bindings** | **disagrees — see below** |

**A `resets =` property is not a binding.** One property can carry up to ten
specifiers (`AX620E.dtsi:1451`, the `vpp` node, carries ten). The three numbers
that matter for a driver are: **59 + 53 + 53 = 165 properties**, **445
(consumer, reset-name) bindings**, **144 distinct lines**.

**The one hit in `AX630C_nand_arm64_k419.dts` is commented out.** Line 167 of
that file reads `/*resets = <&sysclk>;*/` inside `&emmc` — a `resets` phandle
pointing at the `fixed-clock` node, disabled (V). It is not a binding and it is
not even well-formed. A raw `grep -c 'resets *='` counts it; the DT compiler
never sees it. That file contributes zero lines.

For the same reason the specifier counts above exclude two more commented
fragments: `AX620E.dtsi:1451` and `:1479` carry `/* … without clk reg */`
comments *inside* the property, which a naive line-oriented extractor can
mistake for a specifier. Both were stripped before parsing; the 445 total is
comment-free.

---

## 8. Recommended mainline shape

### 8.1 Node shape: fold the resets into the clock-controller nodes

**Recommendation: (b).** Add `#reset-cells = <1>` to the seven existing
`clock-controller@…` nodes in `dts/ax630c.dtsi` and have the clock driver
register a `reset_controller_dev` alongside its clock provider. Do not add
`reset-controller@…` nodes. Do not describe `isp`.

```
	periph_clk: clock-controller@4870000 {
		compatible = AX630C_PERIPH_CLK_COMPAT, "syscon";
		reg = <0x0 0x4870000 0x0 0x10000>;
		#clock-cells = <1>;
		#reset-cells = <1>;
	};
```

The argument, in order of weight:

1. **One window, one regmap, one lock.** `syscon_node_to_regmap()` caches per
   *node*: two DT nodes over the same physical window get two independent
   regmaps with two independent locks, and the 3-cell semantics are a
   read-modify-write. The clock driver already RMWs `dispc`, `mm` and `vpu`
   words (`clk-ax630c-tables.c` marks them `.has_alias = false`) and, once §2.1
   lands, will write their alias apertures. A second regmap over the same
   registers is a race the DT would be creating for no reason. Sharing the node
   shares the regmap by construction.
2. **It is what the repo already decided.** `wdt0` reaches the periph syscon
   through `axera,periph-syscon = <&periph_clk 0>` and the `reboot` node through
   `regmap = <&common_clk>`, both precisely because "two devices cannot both
   `request_mem_region()` one window" (V, `dts/ax630c.dtsi` comments). A
   separate reset node with the same `reg` would reopen that.
3. **It is the upstream house style for exactly this hardware shape.** Rockchip
   CRU, sunxi CCU, Amlogic, MediaTek and Renesas CPG/MSSR all put
   `#clock-cells` and `#reset-cells` on one node when one register block holds
   both. A DT reviewer seeing two nodes with identical `reg` will ask for them
   to be merged; a reviewer seeing one node with both cell counts will not
   comment.
4. **`isp` costs nothing.** The one window that has no clock-controller node has
   no reset consumer either (§1.1), so the "what about isp" objection is void.
   If an ISP driver ever needs it (#83), add a clock-controller node for
   `0x2500000` at that point and it inherits the reset provider for free.

The alternative worth naming, and rejecting, is **(c) a `ti,syscon-reset` child
node under each clock-controller** — see §8.2. It shares the parent's regmap
(so it does not have problem 1) and needs no new driver at all, but it moves a
144-row fixed table into the device tree.

### 8.2 Can mainline `reset-simple` or `reset-ti-syscon` be used?

Honest answer: **`reset-ti-syscon` would work today, unmodified, and
`reset-simple` would work with a one-line compatible addition.** Neither is the
right upstream answer, but the issue's assumption that a custom driver is
*required* is wrong, and that matters for bring-up.

**`reset-ti-syscon` (`$M/drivers/reset/reset-ti-syscon.c`).** `#reset-cells =
<1>`; the table comes from a `ti,reset-bits` property, seven cells per line;
the regmap comes from `syscon_node_to_regmap(np->parent)`, so a child node of
one of our clock-controller syscons shares the parent's regmap and lock.
`assert`/`deassert` are `regmap_write_bits(offset, BIT(bit), SET?mask:0)` — an
RMW on one word — which is **exactly** the AX630C 3-cell semantics, and
`status` is a plain read of the same word, which the hardware supports. Flags
`ASSERT_SET | DEASSERT_CLEAR | STATUS_SET` describe every one of the 144 lines.

What it cannot do: use the write-1-to-set/clear aliases (it always RMWs), and
the `_async` clock cycle. What it costs: 144 × 7 = 1008 cells of `ti,reset-bits`
in the device tree, and a `ti,`-prefixed binding on an Axera SoC.

**Verdict:** a legitimate zero-code bring-up path if #76 is blocked on the
driver. Not submittable as the long-term binding.

**`reset-simple` (`$M/drivers/reset/reset-simple.c`).** Maps `id` to
`(reg_offset + (id/32)*4, id%32)` over its own `ioremap`, RMW, active-high with
`active_low = false`. The AX630C register layout is compatible with that
mapping: `periph` needs `reg_offset = 0x18, nr_resets = 128`; `flash` needs
`0x14`/`128` (which exposes `0x18` and `0x1C` as 64 phantom lines); every other
window has exactly one reset word, so `reg_offset = <value word>, nr_resets =
32`. Adding `{ .compatible = "axera,ax630c-reset" }` to its match table is a
one-line patch.

What it cannot do: share the clock driver's regmap. It calls
`devm_platform_ioremap_resource()`, which takes a `request_mem_region()` over a
window the clock syscon also maps, and it holds its own private spinlock — so
its RMW races the clock driver's. It also forces eight DT nodes whose `reg`
overlaps the clock-controller nodes, which is the reviewer objection from §8.1.

**Verdict:** technically usable, structurally wrong here. Reject.

### 8.3 The driver, sized

A purpose-built driver is small because §3 proved that six of the ten cells, one
of the four and one of the three are redundant. Everything reduces to
`(value word, bit)` plus an optional `(gate word, gate bit)`.

```c
struct ax630c_reset_line {
	u8  reg;	/* value word offset; max seen 0x54  */
	u8  bit;
	u8  gate_reg;	/* clock-gate value word, or AX630C_NO_GATE */
	u8  gate_bit;
};

struct ax630c_reset_desc {
	const struct ax630c_reset_line *lines;
	unsigned int num_lines;
	/* alias arithmetic, reusing struct ax630c_alias from clk-ax630c.h */
};
```

144 lines × 4 bytes = 576 bytes of table, plus seven descriptors. The code is
`assert` (one `regmap_write` to the set alias), `deassert` (the four-step
sequence of §4.3, degenerating to one write when `gate_reg == AX630C_NO_GATE`),
`status` (one `regmap_read`), `reset` (assert, `udelay(10)`, deassert) and a
registration helper the clock driver's `probe()` calls. Call it 150–200 lines in
`drivers/clk/axera/reset-ax630c.c`, sharing `clk-ax630c.h`'s alias machinery and
the `struct ax630c_clk_data`'s regmap.

**Reuse note:** `ax630c_alias_for()` and `ax630c_write_bits()` in
`clk-ax630c.c:66-120` already implement exactly the alias arithmetic §2.1
describes, including the periph-style irregular map. The reset driver should
call them, not reimplement them — which is another argument for keeping the two
in one module.

**Staging.** Implement `assert`/`deassert`/`status` first and leave the `_async`
clock cycle out. None of the lines #76 needs use it (§9), and the cycle carries
a real hazard: steps 1 and 4 of §4.3 are a read-modify-write across two regmap
operations, so a concurrent `clk_enable()` between them is clobbered. Add it
with #83/#84, when the 43 gated lines actually matter, and take the CCF lock or
a driver-private mutex around it then.

### 8.4 ID namespace

**Per-controller, mirroring `ax630c-clock.h`.** The phandle already
disambiguates, the numbering stays parallel to the clock header, and the
driver's per-descriptor table is indexed directly by the cell with no offset
arithmetic. A flat 0–143 namespace would buy nothing and would break the
one-to-one correspondence with the clock IDs a reader is holding in their head.

### 8.5 `dt-bindings/reset/ax630c-reset.h`

Seven blocks, one per controller, in the order and with the values of §6:

```c
/* SPDX-License-Identifier: (GPL-2.0-only OR BSD-2-Clause) */
#ifndef _DT_BINDINGS_RESET_AX630C_H
#define _DT_BINDINGS_RESET_AX630C_H

/* cpu clock-controller@1900000 */
#define RST_CPU_EMMC_CARD		0
#define RST_CPU_EMMC			1	/* host: APB and AXI, one bit */
#define RST_CPU_SPI4_PRST		2
#define RST_CPU_SPI4			3
#define RST_CPU_NR			4

/* comm clock-controller@2340000 */
#define RST_COMM_AUDIO_CODEC_PRST	0
...
#define RST_COMM_NR			5

/* vpu 3, mm 23, dispc 10, periph 82, flash 17 -- see spec section 6 */
#endif
```

Names come from the consumer node label plus its `reset-name`, with the trailing
`_RST`/`_RESET` stripped: the vendor's `reset-names` are the only human-readable
identification these bits have, and the label pins which block they belong to.
Do not invent functional names for the 82 `periph` lines — the DT is the only
evidence of what they gate.

---

## 9. Bring-up subset for #76 (eMMC / SD)

### 9.1 The lines

| Block | Line | Window | Value word | Bit | Set alias | Clear alias |
|---|---|---|---|---|---|---|
| eMMC host | `prst` + `arst` (one bit) | cpu | `0x10` | 12 | `0x0190_1010` | `0x0190_2010` |
| eMMC card | `cardrst` | cpu | `0x10` | 11 | `0x0190_1010` | `0x0190_2010` |
| SD | `prst` / `arst` / `cardrst` | flash | `0x14` | 17 / 16 / 15 | `0x1003_4014` | `0x1003_8014` |
| SDIO | `prst` / `arst` / `cardrst` | flash | `0x14` | 20 / 19 / 18 | `0x1003_4014` | `0x1003_8014` |

None of the eight is bound through an `_async` provider anywhere in the tree, so
**#76 needs no clock-gate cycling** (V, §6.1 and §6.7 "Forms" columns: all
4-cell).

### 9.2 What firmware leaves them in

**The vendor U-Boot never writes any of these bits.** `CPU_SYS_GLB_SW_RST0_*`
and `FLASH_SYS_GLB_SW_RST0_*` are defined in `ax620e.h:44-45,56-57`, and the
only users anywhere in the U-Boot tree are `drivers/dma/axdma/axdma.h:50-51`
(flash bits 2/3, the AXI DMA) and `cmd/axera/gzipd/` (flash bits 10/11). The
U-Boot SD/eMMC driver `drivers/mmc/sdhci_ax620e.c` touches only the SDHCI
block's own software-reset register, never the syscon (V, exhaustive grep).

So at Linux entry these eight bits hold whatever the boot ROM and power-on
reset left. The eMMC host bit (cpu 12) must be released — the boot ROM read
U-Boot off eMMC through that controller. The SD and SDIO bits have no such
argument either way; whether they are released depends on the power-on default
of `0x1003_0014`, which cannot be determined from source. See §10.3.

### 9.3 Would eMMC and SD work with no reset control at all?

**Almost certainly yes for eMMC, probably yes for SD, and mainline's driver does
not even ask unless you tell it to.**

Three separate reasons:

1. **The vendor kernel only ever deasserts.** `sdhci-axera.c` calls
   `axera_clk_reset_control(priv, DEASSERT)` in `probe()` and `ASSERT` only on
   the probe-failure path (V, `sdhci-axera.c:1024-1039, 1091`). Deasserting a
   line firmware already released is a write of a bit into a
   write-1-to-clear alias — a no-op.
2. **Mainline's driver for this IP does not consume `resets` at all in the
   normal path.** `$M/drivers/mmc/host/sdhci-cadence.c:602-609` requests a reset
   control **only if `MMC_CAP_HW_RESET`** is set, which comes from the DT
   property `cap-mmc-hw-reset` (V, `$M/drivers/mmc/core/host.c:366-367`). With
   no `cap-mmc-hw-reset`, `resets` is never read. There is no probe-time
   deassert anywhere in the mainline SDHCI stack.
3. **Every vendor consumer uses the `_optional` getters**, so a missing `resets`
   is `NULL` and every call no-ops (V, §4.5).

**Recommendation for #76: ship the mainline `mmc@…` nodes with no `resets`
property.** It is the smaller change, it cannot hang a serial-less first boot,
and if SD turns out to be held in reset the symptom is a clean "no SD
controller" rather than a hang — diagnosable over the network, fixable in a
follow-up.

### 9.4 The trap if you do add `resets`

Our board's eMMC node carries `cap-mmc-hw-reset` (V,
`AX630C_emmc_arm64_k419_sipeed_nanokvm.dts:312`). If the mainline DT carries
that property forward **and** adds a vendor-ordered `resets` list, then
`sdhci-cadence.c` takes reset **index 0** and installs it as
`mmc_host_ops.card_hw_reset` — asserting it for 3 µs and deasserting with a
300 µs settle whenever the MMC core decides the card needs a hard reset (V,
`$M/drivers/mmc/host/sdhci-cadence.c:529-543, 602-609`). Vendor index 0 is
`prst`: **the host controller's own APB reset**. The MMC core's card-recovery
path would reset the controller it is talking through.

There is a second, better answer sitting in the board DT. The vendor node also
has `hw-reset = <&ax_gpio2 23 0>` (V, same file, line 314) — on this board the
eMMC's `RST_n` pin is driven by GPIO2_A23, not by the `cardrst` syscon bit, and
the vendor driver uses the GPIO for it. Mainline expresses that directly:
`reset-gpios = <&gpio2 23 GPIO_ACTIVE_LOW>` on the `mmc@1b40000` node, which the
reset core turns into a one-line reset controller with no `resets` property at
all (V, `$M/drivers/reset/core.c:1162-1203` fallback,
`$M/drivers/reset/reset-gpio.c`).

**So the correct eMMC binding, when #76 wants the hardware card reset, is
`cap-mmc-hw-reset` + `reset-gpios`, and not `resets` at all.** Whether
`RST_CPU_EMMC_CARD` (cpu bit 11) also drives the pad, or is an internal domain
reset, is a **GAP** — nothing in the vendor sources says, and the vendor driver
never uses it as a card reset.

---

## 10. Risks, gaps and device reads

### 10.1 What could hang a serial-less first boot

| Risk | Severity | Mitigation |
|---|---|---|
| A reset provider that deasserts or resets lines at probe | **fatal** — would reset blocks U-Boot configured, including DDR-adjacent and CPU-window logic | The vendor provider touches no hardware at probe (§5). Mainline must not either. This is the single hard rule. |
| Asserting `RST_CPU_EMMC` (cpu 12) on the boot device | fatal, silent | Do not put `resets` on the eMMC node (§9.3). If you must, never index 0 into `card_hw_reset` (§9.4). |
| The `_async` clock cycle racing CCF | recoverable | Not on #76's path; stage it out (§8.3). |
| Two regmaps over one window | intermittent, very hard to see | Fold the provider into the clock-controller node (§8.1). |
| A wrong bit in the 82-line `periph` table | varies; UART or GPIO reset would be immediately fatal | The table in §6 is mechanically derived from the DT, not hand-typed. Re-derive it, do not transcribe it. |

### 10.2 Known gaps

- **isp `0x2500000`**: no consumer, no driver, no alias evidence. Not described.
- **periph RST3 (`0x24`)**: derived from Family-B arithmetic, no consumer, no
  citation. Marked (I) in §2.2.
- **Whether `cardrst` drives the eMMC/SD card `RST_n` pad** or an internal
  domain. Nothing in the vendor sources distinguishes them (§9.4).
- **Reset-default (power-on) values** of every reset word. Not in any source.
- **`flash` RST1 (`0x20`)** has exactly one consumer, `eth0:ephy_shutdown` at
  bit 0. Nothing else in that word is known.

### 10.3 Device reads that would settle the gaps

All read-only `/dev/mem` word reads on the running vendor system. Use word
loops, never `memcpy` (the `/dev/mem` `memset`/`memcpy` SIGBUS trap in
`docs/reference/deblob-scope/regdumps/README.md`).

| Address | Reads | Settles |
|---|---|---|
| `0x0190_0010` | cpu SW_RST0 | Whether eMMC bits 11/12 are 0 (released) with the vendor kernel up. Expect 0 in both. |
| `0x1003_0014` | flash SW_RST0 | SD (15–17) and SDIO (18–20) state. Also gzip (10/11) and DMA (2/3). |
| `0x1003_0020` | flash RST1 | `ephy_shutdown` (bit 0) plus 31 unknown bits. |
| `0x0487_0018`, `…001C`, `…0020` | periph RST0/1/2 | The 82 periph lines as the vendor leaves them. |
| **`0x0487_0024`** | periph RST3 | **The most valuable read.** No driver and no firmware ever writes this word, so whatever it holds *is* the power-on default of a reset register on this SoC. If it reads 0, reset lines default to released and §9.3's "SD probably works with no reset control" becomes near-certain. If it reads non-zero, the opposite. |
| `0x0443_0010`, `0x0403_000C`, `0x0460_000C`, `0x0234_0054` | mm / vpu / dispc / comm reset words | Cross-checks the value-word derivations of §2.2 against live silicon (a bit that is 0 for a working block corroborates active-high). |
| `0x0487_00D8` … `0x0487_00F4` | periph alias aperture | **Only if a read of an alias is known safe.** Write-1-to-set/clear apertures often read as 0 or as the value word; a read that returns the value word confirms Family B directly. If it returns 0 the test is inconclusive, not a failure. |

Do **not** read `0x0440_3000` (the MM/VPP rst1 hold block) on a base-only boot —
that hangs the AXI bus and watchdog-reboots the board (see CLAUDE.md).

### 10.4 Contributions back to the sibling spec

`clk-model-20260906.md` §1.3 lists the set/clear alias scheme for `dispc`, `mm`,
`vpu` and `isp` as a **GAP**, and `clk-ax630c-tables.c` encodes that as
`.alias = { .has_alias = false }` for three of them. §2.1 of this document
closes three of the four with V-grade evidence: they use the same irregular
`BASE + 2*off` aperture as `periph`, with `BASE` = `0xA0` (dispc), `0xA4` (mm),
`0x104` (vpu). Those three descriptors should gain an `alias_map` so the clock
driver stops read-modify-writing words the reset driver also touches. `isp`
stays a GAP and stays undescribed.
