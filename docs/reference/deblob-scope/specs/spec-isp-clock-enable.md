<!--
Clean-room behavioral spec (epic #55, unblocking #59/M2 "0xC0/C4 stay 0 / datapath
stays 0xDEADBEEF" wall). Produced by a DESCRIBING subagent.

Two evidence classes, kept distinct:
  1. ax_proton.ko (VENDOR BLOB) — behavioral description + `function+offset`
     citations only, NO vendor code reproduced (clean-room rule).
  2. In-tree GPL kernel source (drivers/clk/axera/*, drivers/reset/axera_reset/*,
     arch/arm64/boot/dts/axera/*) — these are OPEN GPL sources shipped in the
     kernel tree, NOT the restricted vendor blob. Register offsets / bit numbers
     quoted from them are cited file:line and may be used directly.
  3. Our own /dev/mem golden dumps (docs/reference/deblob-scope/regdumps/).

Static + dump analysis only; no device was touched. On-device experiments are
proposed at the end for the author to run.

>> DEVICE-TEST RESULT (2026-08-31, base-only boot, M1 locked, live 4K source):
>> this spec's common-bank hypothesis was tested and the CLOCKS ARE RULED OUT as
>> the blocker. Every clock the spec names was set to match the live-vendor golden
>> — common 0x02340000: +0x00[29:27]=5, +0x0C[19:17]=4, +0x24 bits 11 AND 17
>> (=0x2ce00), +0x78 bit10 (=0x7400); isp_clk 0x02500000: MUX_RD->0x5af, gates
>> 0xD0=0x3F/0xD8=0x3FE, IFE reset 0x5E000, sys_glb 0x90=0x230001. RESULT:
>> 0x025000C0/C4 STAY 0 and 0x02400000 STAYS 0xDEADBEEF. A source sweep of
>> ACLK_ISP_TOP across npll_533m/cpll_416m/cpll_208m/AND cpll_24m (always-on ref)
>> woke nothing. A block that ignores even the always-on reference clock is
>> UNPOWERED or held in a top-level reset, not unclocked. -> the real blocker is a
>> POWER DOMAIN / top-level reset, tracked in spec-isp-power-domain.md. The
>> common-bank writes here remain correct prerequisites (CLK_VI_EB bit17 in
>> particular was genuinely missing vs vendor) but are not the wall.
>> Wedged-state dumps preserved: regdumps/glb-wedged.bin, cglb-wedged.bin.
-->

# Behavioral spec — starting the ISP clock so `0x025000C0/C4` come alive and the datapath stops reading `0xDEADBEEF`

## 0. TL;DR — the missing bank is `0x02340000` (common_clk), not another `0x02500000` write

Our open driver (`pkgs/open-vin-capture/open_vin_capture.c`) touches **only the
`0x02500000` isp_clk bank** (mux `0x00`/`0xC8`/`0xCC`, gates `0xD0`/`0xD8`) and the
`0x02400000` ISP file. It never touches the **`0x02340000` common_clk bank**, which
is where the ISP's **AXI/bus clock (`ACLK_ISP_TOP`) and `CLK_ISP_MM`** are muxed and
gated. Those two clocks are the *parents* of everything in `0x02400000` (the ISP
register file) and of the internal `0x02500000` divider tree. With them off, the
`0x02400000`/`0x02406xxx`/`0x02414xxx` windows decode-fault (`0xDEADBEEF`) and the
`0x02500000` divider-status registers `0xC0`/`0xC4` read `0`.

Decisive facts:

- **`ax_proton` contains NO source-PLL enable, NO power-domain/isolation write, and
  never writes `0x025000C0`/`0xC4`.** Verified exhaustively (see §1). Its only clock
  actions are the `0x02500000` mux+gates and a chip-version read at `0x02340208`.
- The **PLLs** (npll/cpll/epll…) live in a separate bank at **`0x02210000`** (pllc)
  and are brought up at boot by the GPL clk driver / bootloader; `npll_533m` (mux
  code 5) is shared with the CPU AXI, so it is always locked. The driver does **not**
  need to enable a PLL.
- The **DT "isp domain" reset framework** that `ax_proton` calls
  (`reset_control_(de)assert` of 31 named ISP resets) **resolves to NULL on this
  board** — the `isp@2400000` "axera,proton" DT node declares **no `resets=`
  property** — so that whole layer is a no-op and is **not** the missing power step.
- **`0x025000C0`/`0xC4` are ISP-internal clock STATUS/divider-observation registers.**
  Nothing in software writes them (not `ax_proton`, not the GPL clk driver). They go
  nonzero **iff the ISP internal clocks are actually toggling**, which requires the
  upstream `ACLK_ISP_TOP` (`0x02340000`) to be live. They are a *symptom*; the cause
  is the `0x02340000` bus clock.

**The one thing to add to the driver:** program/enable the ISP top+MM clocks in the
`0x02340000` common_clk bank (see §5/§6), then re-check `0x02500004`/`0x08` (gate
status) and `0x025000C0`/`0xC4`. This is the bank our driver omits entirely.

---

## 1. What `ax_proton` does — and conclusively does NOT do — for clocks

All citations are `function+offset` in `ax_proton.ko` (ET_REL aarch64, unstripped).

### 1.1 `ax_isp_clk_prepare` @`0x82c20` (called once at probe, from `__ax_isp_probe` @`0x146890`)
- `ioremap(0x02500000, 0x100)` @`0x82c5c`-`0x82c60`, stored at `drv[+0x50]`.
- Writes `0x00100000` (bit20) to `base+0xE8` @`0x82c70` then `base+0xEC` @`0x82c78`
  (rst1 bit20 assert→deassert pulse).
- Calls `__isp_clk_set_rate(base, rate_table)` @`0x82c7c`.
- **No other bank is mapped or written.** No PLL, no power, no `0xC0`/`0xC4`.

### 1.2 `__isp_clk_set_rate` @`0x82b28`
Per ISP domain (loop index → shift 8/5/2): `code = __isp_clk_domain_match_rate(...)`
@`0x82b5c`; `str (7<<shift), [base+0xCC]` @`0x82b68` (clear field); `str
(code<<shift), [base+0xC8]` @`0x82b6c` (set field). **Touches only `0xCC`/`0xC8`.**
Never `0xC0`/`0xC4`, never a PLL.

### 1.3 `ax_isp_pm_prepare` @`0x98210` is a STUB
Body is `mov w0,#0; ret` (@`0x98210`-`0x98214`). There is **no** power-management /
regulator / power-domain bring-up in the module.

### 1.4 `ax_isp_bw_limiter_register` @`0x829e8`
Calls `AX_OSAL_DEV_bwlimiter_register_with_clk(9, NULL)`, `(10, NULL)`, `(11, NULL)`
@`0x82a00`/`0x82a0c`/`0x82a18` — **clk argument is NULL** (bandwidth-limiter client
registration only; not a clock enable). Rules out bwlimiter as the clock source.

### 1.5 The DT reset framework — present, but a NO-OP on this board
`ax_isp_reset_init` @`0x837e0` loops idx 0..30, matches a name against the
`vin_reset_mapping_tbl` (`.data+0x46f0`, 31 entries of `[id:4][name:32]`), calls
`AX_OSAL_DEV_devm_reset_control_get_optional(dev, name)` @`0x8387c`, stores the
returned pointer to `handle[+0x58 + idx*8]`, then `reset_control_assert` @`0x83888`
and `reset_control_deassert` @`0x83894` on each. `ax_isp_reset_(de)assert_isp_domain`
@`0x83be8`/`0x83c88` and `_isp_all` @`0x83a38`/`0x83ad8` index the same
`handle+0x58` pointer array and call `reset_control_assert`/`deassert`.

The 31 reset names (decoded from `.data+0x46f0`):

| idx | name | idx | name | idx | name |
|---|---|---|---|---|---|
| 0 | isp_rst_ife_off | 11 | isp_rst_bt0 | 22 | isp_rst_rgb_core |
| 1 | isp_rst_ife_core | 12 | isp_rst_bt1 | 23 | isp_rst_rxhs0 |
| 2-9 | isp_rst_ife_pipe0..7 | 13 | isp_rst_itp_core | 24-30 | isp_rst_rxhs1..7 |
| 10 | isp_rst_axim | 14 | isp_rst_its |  |  |
|  |  | 15 | isp_rst_ofl |  |  |
|  |  | 16 | isp_rst_rosc |  |  |
|  |  | 17 | isp_rst_yuv |  |  |
|  |  | 18-21 | isp_rst_lvds0..3 |  |  |

**But `devm_reset_control_get_optional` returns NULL when the consumer DT node has no
matching `reset-names`.** The `isp@2400000` node (`compatible="axera,proton"`,
`AX620E.dtsi:1122`) declares **only `clocks = <MCLK0..5_EB>` and no `resets=`
property**. So every `get_optional` returns NULL, the `cbz x0` guard at `0x83884`
skips assert/deassert, and the entire DT-reset layer is inert. **This confirms: the
ISP is NOT brought out of reset or un-isolated via the kernel reset framework on this
SoC — the only reset path is the `0x02500000` MMIO strobes** already covered by
`spec-vin-reset.md` / `spec-vin-write-enable.md`. There is no separate power-domain
register to find here.

### 1.6 `__ax_isp_probe` CMU touch is a READ, not an enable
At `0x1466cc`-`0x1466d8`: `ioremap(0x02340208, 4)`, read the word, store a byte to
`drv[+0x19e]`, test bit0 (`0x1466e8`-`0x1466f0`), `iounmap` @`0x14670c`. This is a
**chip-version/strap read** at `0x02340208`, not a clock/PLL enable.

**Conclusion:** `ax_proton` assumes the ISP top/bus clock and the source PLLs are
*already running* when it probes. It only programs the internal `0x02500000` divider
mux+gates and does the `0x02500000` MMIO reset. Whatever turns on the parent bus
clock is **outside `ax_proton`** — it is the SoC clk framework / bootloader.

---

## 2. The real ISP clock tree (from GPL `clk-ax620e.c` + DT — free to use)

Three physical banks are involved. Bases from `AX620E_clk.dtsi` /
`AX620E_resets.dtsi`:

| bank | phys base | provider compatible | role |
|---|---|---|---|
| pllc | **`0x02210000`** | `axera,ax620x-pllc-clk` | the PLLs (cpll/hpll/npll/vpll0/1/epll/dpll) |
| common_clk | **`0x02340000`** | `axera,ax620x-common-clk` | **ACLK_ISP_TOP, CLK_ISP_MM, MCLK0-5, CLK_VI** muxes+gates |
| isp_clk | **`0x02500000`** | `axera,ax620x-isp-clk` (bare syscon) | ISP-internal divider mux+gates (driven by `ax_proton` MMIO, NOT modeled in `clk-ax620e.c`) |

### 2.1 The ISP AXI/bus clock — `ACLK_ISP_TOP` (the load-bearing parent)
`clk-ax620e.c:236` (array `ax620x_mux_clks_common`):
`{ACLK_ISP_TOP_SEL, "aclk_isp_top_sel", parents, ..., offset 0x0, shift 27, width 3}`
→ **mux at `0x02340000 + 0x00`, bits `[29:27]`**, parents
`{cpll_24m, cpll_208m, cpll_312m, cpll_416m, epll_500m, npll_533m}` (`:214`). So
**code 5 = `npll_533m`** — the ~533 MHz ISP AXI clock. This is the clock that gates
the `0x02400000` register bus; unclocked ⇒ `0xDEADBEEF`.

### 2.2 The ISP media clock — `CLK_ISP_MM`
- mux `CLK_ISP_MM_SEL`: `clk-ax620e.c:247` → **`0x02340000 + 0x0C`, bits `[19:17]`**,
  parents `{epll_100m, cpll_156m, epll_250m, cpll_312m, cpll_416m}` (`:225`).
- gate `CLK_ISP_MM_EB`: `clk-ax620e.c:263` → **`0x02340000 + 0x24`, bit 11**, RMW
  enable (the gate driver's `axera_clkgate_enable` uses the RMW `enable` path when
  `set_offset==0`: `clk.c:344`-`346` `readl(0x24) |= BIT(11); writel`).

### 2.3 Neighbouring gates in `0x02340000 + 0x24` (for context)
`clk-ax620e.c:260`-`279`, RMW bits in reg `0x24`: MCLK0-5_EB = bits 0-5,
CLK_1X_VO0/1 = 6/7, CLK_AUDIO_TLB = 8, **CLK_DPHYRX_TLB_EB = bit 9** (MIPI D-PHY RX,
CSI), CLK_DPHYTX_TLB = bit 10, **CLK_ISP_MM_EB = bit 11**, CLK_VI_EB = bit 17,
CLK_TMR_SYNC = 16.

### 2.4 The PLLs (`0x02210000`) — enabled at boot, no driver action needed
`clk-ax620e.c:27`-`64`, `struct axera_pll_cfg_reg`: each PLL has
`re_open_reg=0x230`, an `on_reg`, `cfg0/1`, `lock_sts`, `rdy_sts=0x1C0` (offsets
relative to `0x02210000`; e.g. `AX_VPLL0_BASE 0x02210050` at `:48`). `npll` is a
fixed 1.6 GHz PLL (`npll_533m` = npll/3). Because `npll_533m` also feeds
`aclk_cpu_top_sel` (`:215`), the PLL is always locked while the system runs — **the
capture driver must not, and need not, touch `0x02210000`.**

---

## 3. Why `0x025000C0`/`0xC4` are the symptom, not the cause

- **No software writes them.** `ax_proton` does not (§1); `clk-ax620e.c` does not model
  the `0x02500000` isp_clk bank at all (there is no `ax620x_*_isp` clock array — the
  `axera,ax620x-isp-clk` node is a bare `syscon` with no `CLK_OF_DECLARE` handler).
- **They read as live divider fields.** Golden dumps (`glb-*.bin`, base=0x02500000):
  `0xC0` = `0x00000062` base vs `0x04040404` vendor-4K-live; `0xC4` = `0x00000101`
  base vs `0x00000f0f` live. Byte/nibble-packed values that change with clock rate ⇒
  **clock-active / divider-status observation registers**, populated by hardware when
  the ISP internal clocks tick.
- On a boot where the ISP internal clocks tick, `0xC0`/`0xC4` are nonzero **and** the
  gate-status readbacks `0x02500004`/`0x08` show `0x3f`/`0x3fe` (glb-now.bin). On the
  wedged base-only boot they are `0` because the parent `ACLK_ISP_TOP` is not
  delivering a clock.

**[speculative, testable]** By analogy to the periph bank (where the DT encodes
`clk_set_reg=0xC0, clk_clr_reg=0xC4` for a cells=10 reset+clock line,
`AX620E.dtsi:598`), `0x025000C0`/`0xC4` *might* also be a clk enable SET/CLR pair
whose readback is the enable status. If so, writing `BIT(n)` to `0x025000C0` could
force-enable an internal ISP clock. This is worth one devmem probe (§7) but is **not**
how the vendor does it (the vendor relies on the upstream bus clock running).

Confidence that `0xC0/0xC4` are status-driven-by-upstream, not a required write:
**medium-high.**

---

## 4. Sub-question answers (with confidence)

1. **Source-PLL enable.** No PLL enable exists in `ax_proton` (§1.1-1.2). PLLs live in
   `0x02210000` (pllc, GPL driver) and are boot-enabled; `npll_533m`(code 5) is shared
   with the CPU AXI and always locked. **The driver does not enable a PLL.**
   Confidence: **high** (ax_proton has none; npll shared with CPU).
2. **Power domain / isolation.** None in `ax_proton`: `ax_isp_pm_prepare` is a stub
   (§1.3); the DT reset/isolation framework resolves to NULL because the ISP DT node
   has no `resets=` (§1.5). The `0x0440306C` "hold" (spec-vin-reset §4) is the only
   top-ctrl touch and wraps the rst1 pulse — it is not a domain power/isolation enable.
   **There is no separate power-domain register.** Confidence: **high**.
3. **What produces `0x025000C0`/`0xC4`.** Nothing in software; they are ISP-internal
   clock/divider STATUS regs that light up when the ISP internal clocks tick, which
   requires the upstream `ACLK_ISP_TOP` (`0x02340000+0x00 [29:27]=5`) to be live (§3).
   Confidence: **medium-high**.
4. **Additional clock-enable beyond `0xD0/0xD8`.** **YES — the whole `0x02340000`
   common_clk bank.** Our driver enables only the internal isp_clk gates (`0x02500000`
   `0xD0/0xD8`) and omits `ACLK_ISP_TOP` (`0x02340000+0x00 [29:27]`) and `CLK_ISP_MM`
   (`0x02340000+0x0C [19:17]` mux, `0x02340000+0x24` bit11 gate). These are the ISP
   AXI/media bus clocks — the parents of the entire datapath. Confidence: **high** that
   this bank is the omission; **medium** that enabling it alone un-DEADBEEFs (needs §7
   device confirmation, because on the golden base dump these bits already read
   "enabled", so the wedge may be a *cleared* bit specific to our boot — the diff
   experiment §7.1 settles it).
5. **Exact ordered sequence.** §5/§6 below.

---

## 5. The ordered bring-up (parent clocks first)

Physical banks: `PLLC=0x02210000`, `CMU=0x02340000`, `ISPRST=0x02500000`,
`ISP=0x02400000`. All 32-bit accesses.

1. **PLLs** (`0x02210000`): already locked at boot (npll shared with CPU). No action.
2. **ISP AXI bus clock** (`CMU 0x02340000`):
   - `ACLK_ISP_TOP_SEL` = code 5 (npll_533m): RMW `CMU+0x00`, set bits `[29:27]=5`
     (`v = (v & ~(7<<27)) | (5<<27)`).
   - `CLK_ISP_MM_SEL` = pick a source (vendor uses one of `[19:17]`; `cpll_416m`=code4
     is a safe high rate): RMW `CMU+0x0C` bits `[19:17]`.
   - `CLK_ISP_MM_EB`: RMW `CMU+0x24 |= BIT(11)`.
   - (CSI already needs `CMU+0x24 |= BIT(9)` DPHYRX_TLB — M1 sets `0x02340024`;
     verify it does not *clear* bit 11.)
3. **ISP internal divider mux** (`ISPRST 0x02500000`): as today — rst1 bit20 pulse
   (`+0xE8`,`+0xEC`), then per-domain CLR(`+0xCC`)/SET(`+0xC8`) shifts {8,5,2}, verify
   `+0x00 == 0x5af` (spec-vin-write-enable §1).
4. **ISP internal gates** (`ISPRST 0x02500000`): `+0xD0 = 0x3F`, `+0xD8 = 0x3FE`
   (as today). **Now verify `+0x04 == 0x3F` and `+0x08 == 0x3FE`** (gate status). If
   these do NOT read back, step 2 (bus clock) is still missing — the gates cannot
   latch without a functional clock.
5. **ISP reset pulse** (`ISPRST`): IFE `+0xE0=0x5E000` then `+0xE4=0x5E000`
   (spec-vin-reset §2); full sequence per spec-vin-reset §6.B if needed.
6. **Verify:** `read32(0x02500000+0xC0)` and `+0xC4` are now nonzero, and
   `read32(0x02406408)` / `read32(0x02414000)` no longer `0xDEADBEEF`.

**Ordering constraint:** step 2 (CMU bus clock) MUST precede steps 3-5. This is the
new requirement; everything from step 3 down is what the driver already does.

---

## 6. Driver-author "do exactly this" — the new code (CMU `0x02340000`)

Add a CMU window (`ioremap(0x02340000, 0x100)`) and, before the existing
`ovc_clk_mux_apply()`:

```
/* ISP AXI bus clock: source = npll_533m (code 5), bits [29:27] of CMU+0x00 */
v = read32(CMU + 0x00); v = (v & ~(0x7u<<27)) | (0x5u<<27); write32(CMU + 0x00, v);
/* ISP media clock source (cpll_416m = code 4), bits [19:17] of CMU+0x0C */
v = read32(CMU + 0x0C); v = (v & ~(0x7u<<17)) | (0x4u<<17); write32(CMU + 0x0C, v);
/* enable CLK_ISP_MM_EB (bit 11) — RMW; and keep DPHYRX_TLB (bit 9) for CSI */
v = read32(CMU + 0x24); v |= (1u<<11); write32(CMU + 0x24, v);
```

All three are idempotent RMW writes and safe to run even if boot already set them (on
the golden base dump they read: `CMU+0x00 = 0x2d000000` ⇒ `[29:27]=5` already;
`CMU+0x24 = 0xcc00` ⇒ bit11 already set). The value of doing them explicitly is that
**a minimal (non-vendor) boot may leave one cleared**, and the diff experiment §7.1
tells you exactly which.

---

## 7. On-device experiments (the driver author must run — static analysis cannot
close this)

### 7.1 The decisive diff (do this FIRST)
On the CURRENT wedged boot (`0x025000C0/C4 == 0`, datapath `0xDEADBEEF`), dump the CMU:
`devmem`/read `0x02340000..0x023400FF` and **diff against `cglb-now.bin`** (the base
dump that had the ISP clock RUNNING). Any register that differs is the missing enable.
Prime suspects: `0x02340000+0x00` (should be `0x2d000000`, `[29:27]=5`) and
`0x02340000+0x24` (should have bit 11 set, i.e. `& 0x800`). This single diff will
either confirm the CMU-bank hypothesis (a bit is cleared vs the running dump) or point
upstream to the PLL.
*(Note: the existing `glb-now.bin`/`cglb-now.bin` were captured on a boot where the
ISP clock was already on, so they cannot show the off→on delta by themselves — you
must capture a fresh CMU dump in the wedged state to diff.)*

### 7.2 Confirm the fix
Apply §6 (the three CMU writes), then:
- read `0x02500004` (expect `0x3f`) and `0x02500008` (expect `0x3fe`) — gate status now
  latches;
- read `0x025000C0`/`0xC4` — expect nonzero (base-rate values ~`0x62`/`0x101`);
- read `0x02406408` (SIF) and `0x02414000` (IFE/WDMA) — expect not `0xDEADBEEF`;
- a write/read round-trip on a non-shadowed reg (SIF `0x02406408`, per
  spec-vin-write-enable §5) now sticks.

### 7.3 Fallback probe if the CMU diff shows no delta (i.e. CMU already correct)
Then the ISP internal clocks have a live parent but the internal tree is not ticking.
Test the `[speculative]` §3 hypothesis: on the wedged boot write
`write32(0x025000C0, 0xFFFFFFFF)` (and/or the per-domain bit) and re-read
`0x025000C0`/`0xC4` and the datapath. If `0xC0/C4` change and DEADBEEF clears, `0xC0`
is an ISP-internal clk-enable SET register (mirror of the periph-bank `0xC0` clk_set).
If nothing changes, `0xC0/C4` are pure read-only status and the wedge is upstream —
re-examine the PLL (`0x02210000` rdy_sts `0x1C0`).

---

## 8. Re-verification commands (for the next analyst)

Toolchain: host `objdump` cannot disassemble AArch64 (`can't disassemble for
architecture UNKNOWN`); use `nix shell nixpkgs#llvm --command llvm-objdump -d`.
Symbols/relocations via `nix shell nixpkgs#binutils` (`nm -n`, `readelf -rW`).

- `ax_isp_clk_prepare` body: `llvm-objdump -d ax_proton.ko` → `<ax_isp_clk_prepare>`
  (`0x82c20`); confirm only `0x02500000` mapped, writes `0xE8/0xEC/0xC8/0xCC`.
- `ax_isp_pm_prepare` stub: `<ax_isp_pm_prepare>` @`0x98210` = `mov w0,#0; ret`.
- DT-reset NULL guard: `readelf -rW` shows `devm_reset_control_get_optional` reloc at
  `0x8387c` inside `<ax_isp_reset_init>` (`0x837e0`); `cbz x0` at `0x83884`.
- Reset name table: `.data+0x46f0`, 31 × `[id:4][name:32]`.
- GPL clk map: `drivers/clk/axera/clk-ax620e.c:214,236,247,263`; gate write semantics
  `drivers/clk/axera/clk.c:331-356`; reset encoding
  `drivers/reset/axera_reset/axera_reset.c:88-196`; ISP DT node
  `arch/arm64/boot/dts/axera/AX620E.dtsi:1122` (no `resets=`); bank bases
  `arch/arm64/boot/dts/axera/AX620E_clk.dtsi` (isp_clk@2500000, pllc_clk@2210000,
  common@2340000) and `AX620E_resets.dtsi` (isp_reset@2500000).

## 9. Confidence summary
| Claim | Confidence |
|---|---|
| `ax_proton` has no PLL enable / no power-domain write / never writes `0xC0/C4` | high |
| DT ISP-reset framework is a no-op here (ISP node has no `resets=`) | high |
| ISP AXI clock = CMU `0x02340000+0x00 [29:27]`, code5=npll_533m; ISP_MM gate `+0x24` bit11 | high (from GPL source) |
| PLLs at `0x02210000`, boot-enabled, no driver action needed | high |
| `0x025000C0/C4` are upstream-driven status, not a required write | medium-high |
| Enabling the CMU bank alone un-DEADBEEFs the datapath | medium — settle with §7.1 diff |
