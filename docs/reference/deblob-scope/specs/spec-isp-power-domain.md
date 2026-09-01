<!--
Clean-room behavioral spec (epic #55, unblocking #59/M2). Produced by a DESCRIBING
subagent to answer ONE question: what powers up / releases from top-level
reset-isolation the ISP region at phys 0x02400000 so it stops reading 0xDEADBEEF?

Three evidence classes, kept distinct:
  1. Vendor blobs (ax_proton/ax_sys/ax_base/ax_cmm/ax_mipi_rx .ko, aarch64 ET_REL) —
     BEHAVIORAL description + `function+offset` citations only, NO vendor code
     reproduced (clean-room rule; drivers are written from this spec, never from
     the disassembly).
  2. In-tree GPL kernel source (drivers/reset/axera_reset, drivers/clk/axera,
     arch/arm64/boot/dts/axera) — OPEN GPL, quoted file:line, usable directly.
  3. Our own /dev/mem golden dumps (docs/reference/deblob-scope/regdumps/).

Static + dump analysis only; NO device was touched, NO repo files edited beyond
writing this spec. On-device experiments are proposed for the author to run.

>> DEVICE-TEST RESULT (2026-08-31) — THE BOOT-FIRMWARE HEADLINE BELOW IS SUPERSEDED.
>> The decisive experiment (§7) was run and the answer is the OPPOSITE of the static
>> conclusion: `0x02400000` reads `0xDEADBEEF` even in FULL PRODUCTION at idle (vendor
>> stack loaded, ax_proton running). Triggering an actual capture (curl the MJPEG
>> stream) makes it read a real value (`0x40`) and 5 MB of frames flow. So the ISP is
>> powered/clocked ON-DEMAND by the vendor's RUNTIME STREAM-START, not by boot firmware
>> — DEADBEEF-at-idle is the normal resting state (the golden regfile-vendor-live.bin
>> had real values only because it was captured DURING streaming). An idle->streaming
>> register diff on the same production boot (regdumps/stream-delta/DELTA.txt) captures
>> the exact vendor stream-start changes: 0x02500000 gate-status +0x04/+0x08 go
>> 0->0x3f/0x3fe, MUX 0x5ac->0x5af, C0/C4 light up; plus changes in undocumented banks
>> 0x02240000 / 0x02250000 (per-lane/per-instance stride = likely DPHY/PLL) and CPU
>> bank 0x01900000 (probably encode-load noise). REFRAME: the remaining M2 work is to
>> reproduce the vendor ISP stream-start clock/power sequence (which ax_proton DOES do
>> at streamon — the static pass looked at probe/create, not streamon), separating the
>> ISP/proton writes from the CSI/mipi ones M1 already handles. So §1-§4's "no Linux
>> module powers it" is TRUE for probe-time but a module (ax_proton, at streamon) does
>> it at runtime.
-->

<!--
HEADLINE (static, SUPERSEDED — see the device banner above): The ISP top-domain power
release appeared NOT to be performed by any Linux-side software (verified by
elimination §1-§4, static/probe-time only). The device test above shows the power is
runtime/streamon, not boot firmware — the static pass did not cover the streamon path.
-->

# Behavioral spec — powering / un-isolating the ISP region `0x02400000` (why it reads `0xDEADBEEF`)

## 0. TL;DR

- **What un-DEADBEEFs `0x02400000` is upstream of clocks and upstream of the
  `0x02500000` isp-reset bank.** Device-proven this session: the block ignores every
  clock source, including the always-on 24 MHz reference, and `0x025000C0/C4` stay 0.
  A block that ignores even its always-on reference is **unpowered or held in
  top-level reset/isolation**, not merely unclocked. This spec accepts that premise
  and asks where the power/isolation release lives.
- **It is not in Linux.** Exhaustive search of the candidate kernel modules
  (`ax_proton`, `ax_sys`, `ax_base`, `ax_cmm`, `ax_mipi_rx`), the GPL `axera_reset`
  and `clk-ax620e`/`clk.c` drivers, and the whole device tree found **no power-domain
  register write, no isolation register, and no SMC/PSCI/SMCCC call** that could power
  the ISP domain. Details + citations in §1-§4.
- **There is no Linux power-domain (genpd) framework for the ISP** — no
  `power-domain-cells`, no `power-controller`, no `genpd` provider anywhere in the
  axera DT. The only genpd code in the kernel tree is unrelated reference drivers
  (`soc/dove`, `soc/actions`). §2.
- **No bootloader source in the tree.** Only `linux/`, `osal/`, `osdrv/` — no
  `boot/`, `atf/`, `u-boot/`, `bl3*`, `optee/`. §5.
- **Conclusion + confidence.** The ISP power/isolation release is performed by the
  secure pre-Linux boot firmware (most likely an always-on PMU / isolation domain),
  which explains both device facts: it ignores the 24 MHz reference (power/isolation,
  not clock) and — per the prior session's observation — the enabled state **persists
  across a warm reboot** (AON domain retained through soft reset). **Confidence:
  medium-high** that it is pre-Linux/AON; **high** that it is not any Linux register
  we can see.
- **The one experiment that resolves everything (§7.1):** on a fresh COLD base-only
  boot, BEFORE running any open bring-up, `devmem 0x02400000`. `0xDEADBEEF` ⇒ the
  bootloader did NOT power the ISP on this boot ⇒ hypothesis #4 confirmed (power is
  vendor-boot-only / warm-reboot-residual). A real value ⇒ the bootloader DID power
  it and the wedge is self-inflicted by our bring-up. This single read decides the
  entire investigation and is 100% safe.

---

## 1. The vendor modules do NOT write an ISP power/isolation register

Method: for each candidate `.ko` I enumerated every physical MMIO base it builds
(`movz/movk …, lsl #16` immediates) plus literal-pool bases the prior specs already
resolved, and searched for `smc`/`hvc` instructions and `arm_smccc`/`psci`
relocations. Citations are `function+offset` in each ET_REL object.

### 1.1 `ax_proton.ko` — touches only clock/reset banks, no power reg
The ONLY top-level bank immediates in the whole module are:
- `movk x0,#0x440,lsl#16` @`0x83fa0` → builds `0x04403060`, then `str w0,[x22,#0xc]` =
  write to **`0x0440306C`**. This is the transient rst1 "hold": written **`2`** at
  `0x83fb8` then **`0`** at `0x83fec`, inside `ax_isp_reset_all_legacy`, wrapping ONLY
  the rst1 pulse (spec-vin-reset §4). It is set-then-cleared within one call ⇒ a
  momentary handshake, **not a persistent power enable**. Physically it lands in the
  `vpp@4403000` block (DT `AX620E.dtsi:1437`, reg `0x4403000` size `0x1000`), i.e. an
  MM-side reset-hold, unrelated to powering `0x02400000`.
- `movk x0,#0x234,lsl#16` @`0x1466d4` (in `__ax_isp_probe`) → `0x02340208`, a **read**
  of the chip-version/strap word (`ioremap`, `ldr`, test bit0, `iounmap`) — prior spec
  spec-isp-clock-enable §1.6. Not a write.

Everything else `ax_proton` writes is the `0x02500000` isp clk/reset bank and the
`0x02400000` ISP file itself (both via ioremap handles). `ax_isp_pm_prepare` @`0x98210`
is a stub (`mov w0,#0; ret`). **No PLL enable, no power-domain write, no isolation
write, no `smc`/`hvc`, no smccc/psci reloc** (0 found). Confidence: **high**.

### 1.2 `ax_sys.ko` — maps a "sys" block and reads a version word; no power write
`ax_sys_dev_init` @`0xaf0`:
- `ioremap(0x02250000, 0xac)` @`0xbc4` → stored at driver `+0x8`. A "sys global"
  window near the PLL/AON cluster (see §6 bank list). I did not observe a datapath
  power write to it in the init path; it is used for sys-management bookkeeping.
- `ioremap(0x02340220, 4)` @`0xbc0`/`0xbdc` (`movk #0x234,lsl#16`, low `0x220`) →
  reads `[x0]` into `+0x10` then unmaps @`0xbf4`. A **version/id read** of comm bank
  `+0x220`. Not a power write.

No `smc`/`hvc`, no smccc/psci reloc.

### 1.3 `ax_base.ko`, `ax_cmm.ko` — no ISP power write, no secure call
`ax_base` provides a generic `ax_base_sys_ioremap` helper but builds no top-level ISP
power base of its own; `ax_cmm` is the CMA/pool manager (bases `0x10xxxxx`/`0x20xxxx`).
Neither issues `smc`/`hvc` or has smccc/psci relocs.

### 1.4 `ax_mipi_rx.ko` — MIPI PHY + pinmux only
MMIO bases: `0x02600000` (MIPI RX PHY) and `0x02300000` (**pinctrl**, DT
`pinctrl@0x2300000`, `AX620E.dtsi:135`, reg `0x2300000` size `0xB000` — this is the
SW_PWR pinmux region, not a power controller). No `smc`/`hvc`, no smccc/psci reloc.

### 1.5 Net
Across `ax_proton`, `ax_sys`, `ax_base`, `ax_cmm`, `ax_mipi_rx`, `ax_mipi_switch`,
`ax_pool`: **0 `smc`/`hvc` instructions, 0 smccc/psci relocations, 0 top-level
power/isolation register writes.** The only ISP-region writers are `ax_proton`
(`0x02500000` + `0x02400000` + the transient `0x0440306C` hold) — all downstream of,
and useless without, the power that is already missing. Confidence: **high**.

> Scope note: the full vendor `.ko` set is ~25 modules. This pass covered the ISP/VI
> front-end modules and all three base modules loaded in the base-only config. A cheap
> follow-up (grep the remaining kos for `smc`/`hvc` and top-bank immediates offline —
> my in-loop scan timed out under repeated `nix shell` startup, not from finding
> anything) would close the last gap, but the base-only-config modules are the ones
> that matter for the warm-reboot argument in §0/§7, and they are clean.

---

## 2. There is no Linux power-domain / isolation framework for the ISP

- **No genpd provider in the axera DT.** No node carries `#power-domain-cells`,
  `power-domains`, `power-controller`, or a `genpd`-style compatible. The only
  `genpd`/isolation code in the kernel tree is foreign reference drivers
  (`drivers/soc/dove/pmu.c`, `drivers/soc/actions/owl-sps.c`) — not built for and not
  referenced by AX630C.
- **The `axera_reset` framework is reset + clock-gate ONLY, no power/isolation.**
  `drivers/reset/axera_reset/axera_reset.c` (whole file): the reset "control" a
  consumer gets is `{dev_id, rst_set_reg, rst_clr_bit, rst_clr_reg[, clk_reg,
  clk_bit, clk_set_reg, clk_set_bit, clk_clr_reg, clk_clr_bit]}` (`of_xlate`,
  `:198-240`). `assert`/`deassert` just write a bit to a set/clr reg
  (`axera_reset_updatenew*`, `:109-155`); the "async" (`of_reset_n_cells==10`) path
  additionally closes/restores a **clock gate** around the reset
  (`axera_clk_close`/`axera_clk_restore`, `:46-86`) — that is the entire "isolation"
  it models. **No power rail, no isolation cell, no handshake/poll.** So even for
  blocks that DO use the framework, there is no power step to find.
- **The ISP node itself declares no resets.** `isp@2400000` (`compatible =
  "axera,proton"`, `AX620E.dtsi:1122`) lists only `clocks = <MCLK0..5_EB>` and **no
  `resets=`**. `ax_proton`'s DT-reset init (`ax_isp_reset_init` @`0x837e0`) therefore
  gets NULL from every `devm_reset_control_get_optional` and no-ops (prior spec
  spec-isp-clock-enable §1.5). Confirmed.

Confidence: **high** (open GPL source + DT).

---

## 3. The common/isp/mm reset banks show no non-clock power delta (dump diff)

Diffing our own comm-bank dumps `cglb-wedged.bin` (DEADBEEF state) vs
`cglb-vendor-live.bin` vs `cglb-now.bin` (base `0x02340000`, 256 B):

| offset | wedged | vendor-live | now | meaning |
|---|---|---|---|---|
| `+0x24` | `0000ce00` | `0002ce00` | `0002cc00` | bit17 = **CLK_VI_EB** (a clock) differs |
| `+0x78` | `00007000` | `00007400` | `00007400` | bit10 = ISP **divider** (a clock) differs |
| `+0x58`/`+0x5C` (comm reset set/clr) | `0` | `0` | `0` | W1S strobes, read 0 in ALL states |

**The only comm-bank deltas are clocks** (already matched bit-for-bit by the main
session), and the reset strobes read 0 everywhere (write-1 self-clearing, invisible in
a static dump). **There is no non-clock "power" bit in the comm bank that the vendor
sets and we don't.** This corroborates §1-§2: the missing step is not a comm-bank
register. Confidence: **high** (our own dumps).

Note the comm_reset (`0x02340000`) consumers in the DT are `audio_codec` (bit 0, `+0x58`,
`AX620E.dtsi:700`) and `bt_dpi0/1` (VO display, bits 26-29, `:1646`,`:1681`) — **no
VI/ISP consumer**. The mm_reset (`0x04430000`) consumers are `vpp`/`gdc`/`jenc`/`dispc`
(`:1451`,`:1479`,`:1338`,`:1499`) — also not the ISP. So neither the comm nor the mm
reset controller carries an "ISP top" reset line at all.

---

## 4. The clock enable path has no hidden power/isolation side-effect

`drivers/clk/axera/clk.c` gate-enable (`:341-354`) is a pure gate write: RMW
`enable |= BIT(bit_idx)` (flags==1) or a single `BIT()` to a set/clr reg (flags==2/3).
No poll, no isolation, no reset, no power. `clk_power()` @`:488` is an integer `pow()`
helper (used for PLL post-div math, `:520`), **not** a power-domain function. PLL
config writes (`:535/537`) are in the PLL bank and gated on PLL setup, not the ISP.

This matters because it means **matching the clock register *state* is equivalent to
running the clock enable path** — there is no strobe/handshake with a power side effect
that state-matching would miss. This closes the "did we skip a prepare-side isolation
release?" question: no. Confidence: **high** (open GPL source).

---

## 5. No boot-chain source exists in this tree

`/nix/store/…-source/` top level = `linux/`, `osal/`, `osdrv/`, `LICENSE`,
`README.md`. `osdrv/` = `out/`, `private_drv2kernel/`, `third_drv/`. There is **no
`boot/`, `atf/`, `u-boot/`, `bl1/bl2/bl31`, `optee/`, `fip/`, `scp/` directory
anywhere** (verified by find). The pre-Linux firmware that (per §1-§4, by elimination)
powers the ISP is **not available as source** in this checkout. Whatever register it
writes cannot be recovered from what we have here — only empirically on the device
(§7) or by obtaining the BL/ATF/u-boot sources (§8).

---

## 6. Concrete conclusion for the driver author

**The exact register that powers/un-isolates `0x02400000` cannot be given from static
analysis, because it is not written by any Linux code in this tree and the boot
firmware that writes it is not in this tree.** What IS established:

1. **Stop looking in Linux.** Do not add a power write to the open capture driver on
   the theory that a kernel register powers the ISP — none does (§1-§4, high
   confidence). Time spent sweeping `0x02500000`/`0x02340000`/comm-reset for a "power"
   bit is time wasted; those banks are clock+reset only and already matched.
2. **The mechanism is pre-Linux / always-on PMU.** Consistent with both device facts:
   ignores the 24 MHz reference (⇒ power/isolation, not clock) and — per the prior
   session — the powered state survives a warm reboot (⇒ retained in an AON domain a
   soft reset does not clear). Medium-high confidence.
3. **Hypothesis #4 is the leading explanation and is directly testable.** The prior
   session that saw clk-enable "un-DEADBEEF" the blocks was a WARM reboot from a full
   vendor boot; the ISP was already powered/un-isolated by that earlier boot and the
   AON domain retained it. A clean COLD base-only boot never had the vendor boot
   power it, so it stays `0xDEADBEEF`. §7.1 confirms or refutes this in one read.

### 6.1 Candidate power/isolation banks to capture the off→on delta against (§7.2)
No source pins these; they are the physically plausible AON/top/fabric banks near the
ISP, ranked. Bases from `AX620E_resets.dtsi` / `AX620E.dtsi` / the module scan:

| rank | phys base | what it is | why a suspect |
|---|---|---|---|
| 1 | **`0x01900000`** | `cpu_sys_reset` (`AX620E_resets.dtsi:8`, size `0x10000`) | top-level fabric/NoC/AXI-master resets live in the CPU-sys block on Axera; a "VI/ISP AXI slave enable" plausibly here |
| 2 | **`0x02250000`** | "sys" window `ax_sys` ioremaps (`ax_sys_dev_init+0xd4`) | the one AON-cluster block a base module maps; unread bits are unknown |
| 3 | **`0x02240000`** | `wake_timer` second map (`AX620E.dtsi:844`) — AON/wake block | AON-domain neighbour; power/isolation often colocated with wake logic |
| 4 | `0x02210000` | pllc (`AX620E_clk.dtsi`) | PLL/AON edge; `rdy_sts 0x1C0` — rule PLL out or in |
| 5 | `0x04430000` | `mm_sys_reset` (`:51`) | only if the ISP shares the MM power island (unlikely — ISP is at `0x2xxxxxx`, MM is `0x4xxxxxx`) |

`0x02340000` (comm) and `0x02500000` (isp) are already captured and show only clock
deltas — exclude from the hunt except as controls.

---

## 7. On-device experiments (the ONLY way to close this from here)

### 7.1 THE decisive read (do this FIRST — zero risk)
On a **fresh COLD (power-cycled) base-only boot**, before M1/M2 or any open bring-up
runs its resets/clocks: `devmem 0x02400000` (and `0x02406408`, `0x02414000`).
- `0xDEADBEEF` ⇒ the bootloader did **not** power the ISP on this boot. Hypothesis #4
  confirmed: the power is done only by the full vendor boot path and retained across
  warm reboot. The register is pre-Linux; proceed to §7.2 to find it, or §8.
- A real value (e.g. `0x00000000` or a version) ⇒ the bootloader **did** power it;
  the DEADBEEF the main session sees is then **self-inflicted** by the open bring-up
  (a reset asserted and never released, `0x0440306C` left at `2`, or an AXI-ctrl left
  at `0xFFFFFFFF`). In that case the fix is in our own sequence, not a missing power
  write — audit spec-vin-reset §4/§6 ordering.

This one read tells the driver author which of the two entire problem-classes they are
in. 100% safe (a read of a decode-faulting address returns `0xDEADBEEF`, no side
effect).

### 7.2 Capture the off→on power delta (if 7.1 shows DEADBEEF cold)
1. COLD base-only boot (ISP OFF). Dump each §6.1 bank (4 KB each) via `/dev/mem`:
   `0x01900000`, `0x02250000`, `0x02240000`, `0x02210000`, `0x04430000`.
2. From a **full vendor boot** (ISP ON, `0x02400000` != DEADBEEF), **warm-reboot into
   base-only** (do NOT power-cycle — preserve the AON state) and dump the SAME banks.
3. `diff` each pair. A register that is set in the ON dump and clear in the OFF dump,
   in the CPU-sys (`0x01900000`) or sys (`0x02250000`) bank especially, and that is
   NOT a clock gate, is the ISP power/isolation enable. Then bisect its bits to the
   minimal write that flips `0x02400000` off DEADBEEF.

This is the exact method that already worked for the clock diffs; it is the only path
that does not require the boot firmware source.

### 7.3 Risk flags (writes that can HARD-HANG the SoC → physical power-cycle needed)
Flag for the main session before any WRITE experiment:
- **`0x01900000` (cpu_sys_reset) writes are high-risk.** This block holds CPU/fabric
  resets; a wrong bit can reset the AXI/NoC fabric or the CPU cluster ⇒ instant hard
  hang, no SSH, requires power-cycle. Treat as read-only until a specific bit is
  identified by the §7.2 diff, then bisect one bit at a time with a watchdog/known
  reboot path armed.
- **The full `0x025000E0` rst0 sweep still hangs** (prior spec-vin-reset §3): the
  hang bit is the ISP AXI-master reset (`isp_rst_axim` in the vendor name table) —
  asserting the AXI master while transactions are outstanding wedges the NoC. Keep it
  out of any narrowed mask, or wrap it in the AXI-quiesce (spec-vin-reset §4). This is
  a reset hazard, not the power question, but it is the other known hard-hang.
- **`0x04430000` / `0x0440306C` writes** touch the MM domain; `0x0440306C` left at `2`
  holds the MM rst1 domain — always pair a `2` with a following `0`.
- Reads of any bank (§7.1/§7.2) are safe.

---

## 8. If the register must be found without the device
Obtain and read (all GPL/BSD, quotable) the AX630C/AX620E boot chain: the Axera SDK
`u-boot`, ARM Trusted Firmware `bl31`/`plat/axera`, and any `bl2`/SPL — search them for
an ISP/VI/media power-domain or isolation init (look for writes to `0x01900000`,
`0x02250000`, an AON/PMU base, or an `mmio` power table keyed on the ISP). None of
these are in the current source drop (§5); they would have to be fetched from the
vendor SDK. That is the only static route to the exact register.

---

## 9. Confidence summary
| Claim | Confidence |
|---|---|
| No kernel module (`ax_proton`/`ax_sys`/`ax_base`/`ax_cmm`/`ax_mipi_rx`) writes an ISP power/isolation reg or issues SMC/PSCI | high |
| No Linux genpd/power-domain framework for the ISP; `axera_reset` is reset+clkgate only | high |
| Clock enable path has no hidden power/isolation side-effect (state-match == path-run) | high |
| Comm/isp/mm reset banks carry no ISP "power" bit; comm dump delta is clocks only | high |
| No boot/ATF/u-boot source in this tree | high |
| ISP power/isolation is done pre-Linux (AON PMU), retained across warm reboot | medium-high |
| Hypothesis #4 (prior un-DEADBEEF was warm-reboot residual from a vendor boot) | medium-high — settled by §7.1 |
| The specific bank/bit of the power register | unknown from static analysis — needs §7.2 diff or §8 boot source |
</content>
