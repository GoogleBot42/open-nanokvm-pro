<!--
Clean-room reset/clock bring-up spec (epic #55, unblocking #59/M2). DESCRIBING
subagent from ax_proton.ko disassembly; no vendor code. Main-session HARDWARE-
VALIDATED 2026-08-31 (devmem, base-only boot, M1 locked):
 - clk-enable 0x025000D0/D8 is the WAKE: writing them un-DEADBEEFs the SIF
   (0x02406xxx) and IFE/WDMA (0x02414xxx) blocks (0xDEADBEEF -> 0x00000000).
   M1 does NOT set these (it's the CSI driver); the open capture driver must.
 - Reset polarity CONFIRMED: 0x025000E0 = ASSERT (writing it returns a block to
   0xDEADBEEF), 0x025000E4 = DEASSERT (returns it to 0). Matches this spec.
 - REMAINING GAP (open): even clocked + reset-deasserted via an all-bits-at-once
   blast, config regs (e.g. WDMA 0x024140d4) still read 0 after a write (writes
   not sticking). The spec's step 5 is a PER-INDEX pulse (1<<idx to E0 then E4,
   each bit) with the AXI-quiesce (step 4) first and the 0x0440306C hold wrap --
   a crude 0xFFFFFFFF blast is NOT equivalent. Implement the exact per-bit
   sequence in the driver (loops), not devmem, to close this.
 - AXI-ctrl 0x02400184 is writable (reads back 0x0000FFFF = 16-bit field); AXI
   status 0x02400188 reads 0 (quiesce idle). int-ctrl sub-block always writable.
-->

# Behavioral spec — AX630C ISP/VIN SIF + IFE/WDMA reset-deassert / clock-enable bring-up

Clean-room behavioral description recovered from `ax_proton.ko` (ET_REL aarch64,
unstripped) disassembly. Register/bitfield names are the vendor's silicon symbol
names. No vendor code is reproduced. Every claim cites `function+offset`.

---

## 0. TL;DR — the ordered reset sequence (what un-DEADBEEFs the blocks)

The vendor's ONE bring-up primitive that makes the SIF (`0x02406xxx`) and IFE/WDMA
(`0x02414xxx`) sub-blocks writable is **`ax_isp_reset_all_legacy`** (`0x83ec8`),
called by `VIN_glb_create` (`0x84314`) right after enabling the ISP clocks. It does
an assert→(AXI-quiesce)→deassert **pulse** on the reset lines, wrapping the second
(rst1) pulse in a top-level "hold" register at **`0x0440306C`**.

All reset/clock registers live in the **RST bank at base `0x02500000`** (the driver
reaches it as `ISP_DRV_IO_RST_*(handle, off)` → `*(handle[0x10] + off)`;
`ISP_DRV_IO_RST_WRITE32` `0x365e8`, offset field `[x0+0x10]` at `0x365f4`). The
datapath sub-blocks (SIF, IFE/WDMA, int-ctrl, AXI-ctrl) live in the **ISP file at
base `0x02400000`** (`ISP_DRV_IO_WRITE32` `0x364f0` → `*(handle[0x0] + off)` at
`0x364fc`).

Ordered sequence (from `ax_isp_reset_all_legacy`, offsets below):

1. **rst0 deassert-all** — for `idx = 0..31`: write `(1<<idx)` to `0x025000E4`.
2. **rst1 deassert-all** — for `idx = 0..22` (skip 20): write `(1<<idx)` to `0x025000EC`.
3. If `drv[+0x4] != 0`: **return here** (skip steps 4-9). In normal bring-up the flag is 0.
4. **AXI quiesce** (`ax_isp_axi_busy_check_legacy` `0x83d28`): write `0xFFFFFFFF` to the
   three AXI-ctrl regs `0x02400184` (IFE), `0x02480144` (ITP), `0x024C0148` (YUV);
   poll the three AXI-status regs `0x02400188`, `0x02480148`, `0x024C014C` until all
   read 0, `udelay(200)` between polls, timeout after 51 iterations (~10 ms).
5. **rst0 pulse-all** — for `idx = 0..31`: write `(1<<idx)` to `0x025000E0` (assert)
   **then** `(1<<idx)` to `0x025000E4` (deassert).
6. **HOLD set**: `ioremap(0x04403060, 0x10)`; write **`2`** to **`0x0440306C`** (`base+0xC`).
7. **rst1 pulse-all** — for `idx = 0..22` (skip 20): write `(1<<idx)` to `0x025000E8`
   (assert) **then** `(1<<idx)` to `0x025000EC` (deassert).
8. **HOLD clear**: write **`0`** to **`0x0440306C`**; `iounmap`.
9. **Zero the three AXI-ctrl regs**: `0x02400184 = 0`, `0x02480144 = 0`, `0x024C0148 = 0`.

After step 5 the SIF and IFE/WDMA register windows stop returning `0xDEADBEEF`.
(The rst1 pulse + hold in steps 6-8 covers the ITP/YUV/other rst1 domains; it is not
required to bring up SIF/IFE, but is part of the faithful full sequence.)

Confidence: **high** for the register map, offsets, values, ordering and W1S-pulse
model; **medium** for the exact electrical meaning of the `0x0440306C` hold (see §4).

---

## 1. Register map (bases, offsets, access semantics)

### 1.1 Bases (from the IO accessor thunks)
| Accessor | Handle field | Physical base | Contents |
|---|---|---|---|
| `ISP_DRV_IO_WRITE32/READ32` (`0x364f0`/`0x36598`) | `handle[0x00]` | **`0x02400000`** | ISP file: int-ctrl `0x00..0xA0`, SIF `0x6xxx`, IFE/WDMA `0x14xxx`, AXI-ctrl/status |
| `ISP_DRV_IO_GLB_WRITE32` (`0x366e8`) | `handle[0x08]` | `0x02500000` (GLB view) | isp_sys_glb config (deskew/lock, `+0x90/0x94`) |
| `ISP_DRV_IO_RST_WRITE32/READ32` (`0x365e8`/`0x36668`) | `handle[0x10]` | **`0x02500000`** (RST view) | clock-enable `0xD0..0xDC`, reset `0xE0..0xEC` |

`handle[0x08]` (GLB) and `handle[0x10]` (RST) both index into the `0x02500000`
isp_sys_glb bank (matches the device-confirmed geography: `+0x00` deskew lock,
`+0xe0-ec` reset area). Evidence: `ISP_DRV_IO_RST_WRITE32` loads `[x0+0x10]` and does
`str w2,[x3, w1]` (`0x365f4`, `0x36600`).

### 1.2 RST bank registers (base `0x02500000`)
| Offset | Name (role) | Access | Written by |
|---|---|---|---|
| `0xD0` | clk-enable bank A (set) | RMW | `ax_isp_clk_eb_set` `0x9c50` (reads/writes `0xD0`,`0xD8`) |
| `0xD4` | clk-enable bank A (clear) | RMW | `ax_isp_clk_eb_clr` `0x9e48` (reads/writes `0xD4`,`0xDC`) |
| `0xD8` | clk-enable bank B (set) | RMW | `ax_isp_clk_eb_set` |
| `0xDC` | clk-enable bank B (clear) | RMW | `ax_isp_clk_eb_clr` |
| **`0xE0`** | **rst0 ASSERT** (into reset) | **W1S** | `ax_isp_clk_rst0_set`/`_all` |
| **`0xE4`** | **rst0 DEASSERT** (out of reset) | **W1S** | `ax_isp_clk_rst0_set`/`_all` |
| **`0xE8`** | **rst1 ASSERT** | **W1S** | `ax_isp_clk_rst1_set`/`_all` |
| **`0xEC`** | **rst1 DEASSERT** | **W1S** | `ax_isp_clk_rst1_set`/`_all` |

**W1S / self-clearing polarity proof.** The per-index setter `ax_isp_clk_rst0_set`
(`0x91a0`) rebuilds a full 32-bit word from bit-tables where, for a given `idx`,
**only the bit `idx` is 1** and it read-modify-writes the register overwriting all 32
bits (`bfi` bit0..31, `0x93f4-0x94c8`). If the register were a plain level register,
each of the 32 calls in the loop would clobber the previous — the loop only makes
sense if writing 0 is a no-op, i.e. these are **write-1-to-act, self-clearing** strobe
registers. This is why they read back 0 / are invisible in a static dump, and why a
plain clock-gate poke is insufficient — the deassert is a *strobe*, not a level.

**Higher offset = deassert.** `ax_isp_reset_ife_legacy` (`0x84078`) is a bring-up
(makes IFE usable) and issues a `mode=2` pulse whose write ORDER is `0xE0` then `0xE4`
(`ax_isp_clk_rst0_set_all` `0x9710→0x9720` writes `0xE0`, `0x9730` writes `0xE4`). To
end deasserted/usable, the *last* write (`0xE4`) must be the release. Same for rst1:
`0xE8` then `0xEC`.

### 1.3 rst0 index→bit mapping (per-index table decoded from `.rodata`)
`ax_isp_clk_rst0_set(handle, idx, mode)` sets register **bit N = idx N** (identity
map) for `idx 0..26`, and `idx 27..31 → bits 27..30`. Decoded from the 32 sparse
bool tables at `.rodata+0x590+0x38 .. +0x3f8` (each 32 bytes, exactly one `1` at
position = its bit index). So a mask with bit `k` set ⇔ reset line `k`.

### 1.4 The `mode` argument (both `_set` and `_set_all`)
| mode | rst0 regs written | rst1 regs written | meaning |
|---|---|---|---|
| 0 | `0xE4` only | `0xEC` only | deassert-only |
| 1 | `0xE0` only | `0xE8` only | assert-only |
| 2 | `0xE0` then `0xE4` | `0xE8` then `0xEC` | assert→deassert **pulse** |

`ax_isp_clk_rst0_set_all(handle, mode, mask)` (`0x96f8`) writes `mask` verbatim
(mode-select at `0x9704`/`0x9708`). `ax_isp_clk_rst1_set_all` (`0x9ba0`) same for
`0xE8`/`0xEC`.

---

## 2. IFE/WDMA reset (standalone, ground-truthed)

**`ax_isp_reset_ife_legacy` (`0x84078`)** — the canonical IFE datapath reset:

```
ax_isp_clk_rst0_set_all(handle, mode=2, mask=0x0005E000)   // 0x84080: w1=2, w2=0x5E000
```
i.e. **write `0x0005E000` to `0x025000E0` (assert), then `0x0005E000` to
`0x025000E4` (deassert)**.

`0x5E000` = **bits 13,14,15,16,18** = reset lines {13,14,15,16,18} = the IFE/WDMA
group. Called from `ife_vin_node_reset` (`0xc9ec8`).

This alone should bring the IFE/WDMA window (`0x02414xxx`) out of reset (clocks must
already be on — see §5). Confidence: **high**.

> Note: the later `ife_wdma_reset` (`0x4db8`) is a *soft* register-level reset of WDMA
> channel config via `ax_regio_blk_io_*` (offsets `0x648/0x64c/0x650...` inside the
> `0x14xxx` block); it runs only AFTER the block is out of reset. Not part of the
> hardware reset-deassert. Do not confuse the two.

---

## 3. SIF reset — there is NO standalone SIF reset

Exhaustive search: the only callers of `ax_isp_clk_rst0_set_all`/`rst1_set_all` with a
constant mask are `ax_isp_reset_ife_legacy` (IFE, `0x5E000`) and
`ax_isp_reset_itp_yuv_legacy` (`0x840a0`, parameterized masks for ITP/YUV). **No
`reset_sif_*` and no hardcoded SIF mask exist in the blob.**

Therefore the SIF front-end (`0x02406xxx`) is brought out of reset **only** by the
full `ax_isp_reset_all_legacy` sweep (§0 steps 1,5 pulse *every* rst0 bit `0..31`).
The SIF reset line is one of `idx 0..31` but is not separately labeled in any static
table (the `isp_sif_*` name strings near `.rodata+0x10` belong to an unrelated
function-name lookup table, not the reset-bit map).

**Recommendation:** implement the full `reset_all_legacy` sweep (§0). To pin SIF's
specific bit empirically, bisect the rst0 deassert mask on-device (see §6). Marking
the exact SIF bit **[speculative]**: SIF is upstream of IFE, so a low index (`0..12`)
is likely, but do not rely on a guess — the full sweep is authoritative.

---

## 4. The `0x0440306C` hold register + the three AXI-ctrl registers

### 4.1 HOLD `0x0440306C` (`ax_isp_reset_all_legacy` `0x83f98-0x83ff4`)
- `ioremap(0x04403060, 0x0A)` → maps the small top-level ctrl page (`0x83f98`,
  `movk 0x440<<16 | 0x3060`).
- **Write `2` to `base+0xC` = `0x0440306C`** BEFORE the rst1 pulse (`0x83fb8`).
- Run the rst1 pulse-all (`0x83fc0-0x83fe8`).
- **Write `0` to `0x0440306C`** AFTER the rst1 pulse (`0x83fec`); then `iounmap`.

Role: a top-level "reset hold / isolation" that wraps **only the rst1 (ITP/YUV/other)
deassert pulse**. It is NOT applied around the rst0 (SIF/IFE) pulse. Its exact
electrical function (AXI/NoC isolation vs reset-ack hold) is **[speculative]** — value
`2` is a bit strobe held during the rst1 pulse. For SIF/IFE bring-up specifically it
is **not required**; include it for a faithful full reset.

### 4.2 The three AXI-ctrl / status registers (in the `0x02400000` file)
| Block | AXI-ctrl (set) | AXI-status (poll) | setter |
|---|---|---|---|
| IFE | `0x02400184` (off `0x00184`) | `0x02400188` | `ax_ife_top_axi_ctrl_set` `0x12890` / `_status_get` `0x128e8` |
| ITP | `0x02480144` (off `0x80144`) | `0x02480148` | `ax_itp_top_axi_ctrl_set` `0x12998` / `_status_get` `0x129e8` |
| YUV | `0x024C0148` (off `0xC0148`) | `0x024C014C` | `ax_yuv_top_axi_ctrl_set` `0x12a18` / `_status_get` `0x12aa0` |

Usage:
- **Quiesce** (`ax_isp_axi_busy_check_legacy` `0x83d28`, runs BEFORE the pulse): write
  `0xFFFFFFFF` to all three ctrl regs, poll all three status regs until 0.
- **Zero** (end of `reset_all`, `0x84000-0x84024`): write `0` to all three ctrl regs
  to release the AXI-idle request after reset.

---

## 5. Ordering constraints

From `VIN_glb_create` (`0x84228`), the actual bring-up order:

1. `ax_regio_create` / `ax_regio_setup` — map the register windows (`0x842d8`, `0x842ec`).
2. **Clocks first:** `for bank = 0..15: ax_isp_clk_eb_set(regio, bank)` (`0x842f8-0x8430c`)
   — enables ISP clocks via RST-bank regs `0x025000D0`/`0x025000D8` (RMW). *(This is
   the step M1 already performs.)*
3. **Then reset:** `ax_isp_reset_all_legacy(drv)` (`0x84314`). Internally it uses
   `regio = drv[+0x30]` as the IO handle (`0x83ee8`).
4. Only afterwards: pipe callback, `ax_regio_backup`, `ax_isp_int_reset` (`0x84388`,
   clears int-ctrl mask regs `0x02400010..0xA0` etc.), `ax_isp_sys_glb_init`
   (`0x84394` → GLB `0x90=0x230001`, `0x94=1`, deskew lock-time).

**Constraint:** clock-enable (`clk_eb`, `0xD0/0xD8`) MUST precede the reset pulse.
Blocks in reset with clocks off will not respond to the deassert. Our M1 already sets
`0xD0/D8` (clk) and CMU `0x02340024` — so the missing operation is specifically the
**reset-deassert strobe on `0x025000E4`/`0xEC`** (and, for IFE, mask `0x5E000` to
`0xE0`→`0xE4`), NOT another clock gate.

**Relative to CSI-2:** the reset sequence touches only the `0x02500000` (RST) and
`0x02400000` (ISP) banks; it is independent of the MIPI/CSI-2 link (`ax_mipi_rx`).
The vendor brings the ISP datapath out of reset in `VIN_glb_create`, i.e. at device
create time, before/independent of sensor stream start. Running the reset pulse with
the CSI-2 link already locked (our M1 state) is fine — no ordering hazard observed.
Confidence: **medium-high** (no explicit cross-dependency found in the reset path).

---

## 6. Driver author checklist ("do exactly this")

Prerequisite (already done by M1): ISP clocks enabled — `0x025000D0` and `0x025000D8`
programmed via `ax_isp_clk_eb_set` equivalent for banks 0..15; CMU `0x02340024` set.

All writes below are 32-bit. `RST = 0x02500000`, `ISP = 0x02400000`.

**A. Minimal — bring up IFE/WDMA only (highest confidence):**
1. `write32(RST + 0xE0, 0x0005E000)`   // assert IFE reset lines {13,14,15,16,18}
2. `write32(RST + 0xE4, 0x0005E000)`   // deassert (release) — strobe
3. Verify: `read32(ISP + 0x14000)` no longer returns `0xDEADBEEF`.

**B. Full sequence — brings up SIF + IFE + all ISP (faithful to vendor):**
1. rst0 deassert-all: `for idx in 0..31: write32(RST+0xE4, 1<<idx)`
2. rst1 deassert-all: `for idx in 0..22 if idx!=20: write32(RST+0xEC, 1<<idx)`
3. AXI quiesce:
   `write32(ISP+0x184, 0xFFFFFFFF); write32(ISP+0x80144, 0xFFFFFFFF); write32(ISP+0xC0148, 0xFFFFFFFF);`
   poll until `read32(ISP+0x188)==0 && read32(ISP+0x80148)==0 && read32(ISP+0xC014C)==0`
   (udelay 200 between polls, ≤51 tries).
4. rst0 pulse-all: `for idx in 0..31: { write32(RST+0xE0, 1<<idx); write32(RST+0xE4, 1<<idx); }`
5. `hold = ioremap(0x0440306C,4); write32(hold, 2);`
6. rst1 pulse-all: `for idx in 0..22 if idx!=20: { write32(RST+0xE8,1<<idx); write32(RST+0xEC,1<<idx); }`
7. `write32(hold, 0); iounmap(hold);`
8. Zero AXI-ctrl: `write32(ISP+0x184,0); write32(ISP+0x80144,0); write32(ISP+0xC0148,0);`

(Optional simplification: bits can be written as one mask instead of per-idx, since
these are W1S — e.g. `write32(RST+0xE0, 0x7FFFFFFF); write32(RST+0xE4, 0x7FFFFFFF)` for
the rst0 pulse. Per-idx mirrors the vendor exactly; masked is equivalent given W1S.)

**On-device verification (which reg stops reading `0xDEADBEEF` after which step):**
- After step A.2 / B.4: `read32(0x02414000)` (IFE/WDMA) becomes a real value. If still
  `0xDEADBEEF`, clocks (`0xD0/0xD8`) are not on, or you wrote `0xE0` without the
  following `0xE4` strobe.
- SIF (`read32(0x02406000)`): un-DEADBEEFs only after the full rst0 pulse-all (B.4),
  not after the IFE-only mask. To identify SIF's exact bit, bisect: pulse each single
  `write32(RST+0xE0,1<<i); write32(RST+0xE4,1<<i)` and watch `read32(0x02406000)`.
- A read of `0x0440306C` only echoes the hold latch; it proves nothing about SIF/IFE
  liveness — verify against the `0x02406xxx`/`0x02414xxx` windows themselves.

---

## 7. Confidence summary

| Claim | Confidence |
|---|---|
| RST bank `0x02500000`, offsets `0xE0/E4/E8/EC` reset, `0xD0-DC` clk | high |
| W1S / self-clearing strobe semantics; higher offset = deassert | high |
| IFE/WDMA reset mask `0x5E000` (bits 13-16,18), mode-2 pulse | high |
| Full `reset_all_legacy` order (steps 1-9) incl. AXI quiesce | high |
| `0x0440306C` = 2 before / 0 after rst1 pulse; wraps rst1 only | high (values/order); medium (electrical meaning) |
| Three AXI-ctrl regs `0x184`/`0x8144`/`0xC148`, status `+4` | high |
| clk-enable precedes reset; independent of CSI-2 | medium-high |
| No standalone SIF reset; SIF via full sweep; exact SIF bit | high (no standalone); SIF bit = speculative |
