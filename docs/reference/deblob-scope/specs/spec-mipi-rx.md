<!--
Clean-room behavioral spec produced under epic #55 (issue #57, M1). Written by a
DESCRIBING subagent from ax_mipi_rx.ko disassembly (no vendor code copied);
register offsets/bitfield names describe silicon, not vendor source. Main-session
verified against disassembly 2026-08-30: ax_mipi_rx_reg_init ioremap immediates
confirm CSI-2 protocol base 0x02600000 (+0x02602000 dev1) and pinmux 0x02300000;
ax_mipi_rx_ioctl decode confirms the 9-selector ABI exactly — magic 'm' (0x6d),
nr 0/1 = _IO, nr 2..8 = _IOWR 8-byte (0xc0086d02..0xc0086d08).
UNVERIFIED (needs on-device probes per the spec's own checklist, deferred to the
M1 device pass): DWC-vs-custom identity (no version reg is read statically —
read 0x02600000 live), the phys->virt field correlation for isp_sys_glb vs
common_glb (agent inferred it; internally consistent), and D-PHY timing offsets.

DEVICE-CONFIRMED (on-hardware pass 2026-08-30, /dev/mem): CSI-2 core is CUSTOM
(0x02600000+0x00 = 0x0001321c, NOT a DWC version word; ctrl0 != ctrl1
0x0001021c). Register map validated exactly: +0x08=0x43210410 (comboMode4),
+0x40=0x1f (4 lanes), +0x100=1 (stream start). Link-up health 0x02500000+0x00
bits[1:0]=3 (locked). mainline dw-mipi-csi2 is a reference only; these offsets
are authoritative.
-->

# Behavioral Specification — `ax_mipi_rx.ko` (CSI-2 / D-PHY receiver)

Clean-room behavioral spec for issue #57. Derived by static analysis of the
unstripped vendor module. All register/bitfield names below are the vendor's own
**hardware symbol names** (they describe the silicon, not the vendor code). No
vendor code, comments, or verbatim disassembly is reproduced.

Module identity: `description=Axera MIPI Soc Chip Driver`, `vermagic=4.19.125`,
version banner `ax_mipi_rx V3.0.0_20250319114413`. Two RX instances (dev 0/1);
KVM uses a single fixed HDMI→MIPI bridge on dev 0, digital YUV422, no bayer sensor.

---

## 0. MMIO base map (AUTHORITATIVE — from `ax_mipi_rx_reg_init`)

The driver keeps one private context (`mipi_pdrvdata` → single heap struct). Each
hardware block is `ioremap`'d and its virtual pointer stored at a fixed field in
that struct. Physical bases are hard-coded immediates in `ax_mipi_rx_reg_init`
(each passed to `AX_OSAL_DEV_ioremap`), so they are firm:

| Block (function family) | Phys base | ctx field | Notes |
|---|---|---|---|
| CSI-2 protocol controller 0 | `0x02600000` | `+0x98` | `csi_ctrl_*`, `csi2rx_*` |
| CSI-2 protocol controller 1 | `0x02602000` | `+0xa0` | dev-index 1 (stride 0x2000); per-dev accessor = `ctx + dev*8 + 0x98` |
| pinmux / pad file | `0x02300000` | `+0xa8` | `dphy_pin_mux_config`; shared with pinctrl (HAZARD) |
| secondary (DVP/BT) | `0x02303000` | `+0xb0` | used by `ax_dvp_bt_soc_init`; not on the MIPI data path |
| isp_sys_glb (csirx clk-gate + soft-reset + lock status) | `0x02500000` | `+0xb8` | `isp_sys_glb_*` |
| D-PHY global config (analog/PPI, lane swap, HS-RX timing, PHY enable) | `0x023f0000` | `+0xc0` | `dphyrx_*` |
| common_glb (VI subsystem controller: DPHY power, VI clk, TLB) | `0x02340000` | `+0xc8` | `common_glb_*` |

> **Correction to prior established facts:** the "0x2340000/0x2500000 = isp_sys_glb"
> lumping is imprecise. This driver treats **0x02500000 as isp_sys_glb** (csirx
> reset/clock/lock) and **0x02340000 as common_glb** (DPHY power + VI clk + TLB).
> The D-PHY register file is at **0x023f0000**, *not* in the 0x2600000 band.
> The 0x2600000 band is the CSI-2 protocol controller **only**.

**Register access idiom — two distinct shadow-register schemes:**

- **Set/Clear pair (bit-addressable, atomic):** most clock-enable and soft-reset
  registers come as a pair `{SET @ even_off, CLR @ even_off+4}`. Writing a 1 to a
  bit in the SET register asserts that bit; writing a 1 to the same bit position in
  the CLR register de-asserts it. No read-modify-write; unwritten bits are untouched.
- **Value/Mask pair (field-addressable):** the clock *mux* and `csi_ctrl_sel`
  registers use `{VALUE @ even_off, MASK @ even_off+4}`: software writes the field
  mask to the MASK register, then the new field value to the VALUE register.

The open driver may instead do plain RMW on a single logical register if it maps a
different (non-shadowed) alias — but the vendor path only ever touches these
shadow offsets, so the shadow scheme is what the hardware exposes here.

---

## 1. Controller identity — DWC lineage: **LIKELY, but register map is Axera-custom (NOT drop-in)**

**No version/ID register is ever read.** Exhaustive scan of all 128 functions found
no read of CSI-controller offset `0x00`, and no comparison against any magic/version
constant anywhere in the module. The driver hard-codes every offset.

**Evidence FOR DWC lineage:** the CSI-2 controller emits the verbatim Synopsys
DesignWare MIPI CSI-2 Host error taxonomy — "Overflow detected in resynchronization
FIFO between DPHY lane Management and protocol blocks", "a truncated long packet has
been received…Too few/many bytes", "unrecoverable ECC error", "invalid access to the
configuration register space", per-lane "errsot hs". These strings are DWC-specific.

**Evidence AGAINST a stock DWC register interface:** the offsets this driver
programs do **not** match the public DWC CSI-2 Host layout (DWC has VERSION@0x00,
N_LANES@0x04, CSI2_RESETN@0x08, INT_ST_MAIN@0x10, PHY_SHUTDOWNZ@0x40,
PHY_STOPSTATE@0x4C, INT_ST_PHY_FATAL@0xe0…). Here: soft-reset@0x04, lane-map@0x08,
err-status@0x28 & 0x4c, N_LANES@0x40, stream-ctrl@0x100. Partial echo only (the
0x40/0x4c/0x50 cluster rhymes with PHY_SHUTDOWNZ/STOPSTATE/TEST_CTRL) — the map is
renumbered/customized.

**VERDICT:** the protocol/error core is DWC-*derived*, but Axera wrapped it with a
custom register interface. **Mainline `dw-mipi-csi2` is not adaptable drop-in**;
use the offsets in §5/§2 from this spec as authoritative.

**→ Concrete on-device probe (main session):**
```
# ctrl0 offset 0x00; also 0x02602000 for ctrl1
devmem2 0x02600000 w      # or busybox devmem 0x02600000
```
Interpretation: a DWC core returns an ASCII-BCD version at offset 0x00 (e.g.
`0x3130_3000`/`0x3132_3000` = "1.0"/"1.20"). If it reads `0`, all-ones, or bus-error
→ offset 0x00 is not a version register → fully custom core confirmed. Do this while
`nanokvm.service`/capture is up so the block is clocked and out of reset (a gated
block reads 0 or faults). Compare ctrl0 vs ctrl1 — they should match.

---

## 2. CSI-2 protocol controller register map (base `0x02600000` / `0x02602000`)

All offsets relative to the controller base (ctx `+0x98` for dev0). Recovered from
`ax_mipi_rx_csi_ctrl_init`, `csi2rx_soft_reset`, `csi_ctrl_*`, `csi_rx_ctrl_get_irq_status`.

| Offset | Role | Behavior observed |
|---|---|---|
| `+0x04` | CSI2 soft-reset | `csi2rx_soft_reset` forces bits[1:0]=1 (asserts). Deassert path clears them. |
| `+0x08` | D-PHY lane control / lane-map (`csi_ctrl_dphy_lane_control`) | RMW under mask `0x77770710`; programmed value `0x43210010 \| (comboMode<<8)`. Upper four nibbles (`0x4321…`) = default per-lane data-lane map; bits[10:8] = combo/lane selector; bit4 fixed set. |
| `+0x1c` | error-IRQ enable/mask A | written `0x7` |
| `+0x24` | D-PHY error-IRQ mask (`csi_ctrl_dphy_err_irq_mask_cfg`) | written `0x6f` |
| `+0x28` | **ERR/INFO interrupt STATUS 0** (read, write-1-to-clear) | latched into ctx `+0x18` = ABI `ErrorStatus0`; see §5 bit map |
| `+0x2c` | error-IRQ mask (`csi_ctrl_err_irqs_mask_cfg`) | written `0x00011ee1` |
| `+0x38` | error-IRQ mask (second, per-ctrl copy) | written `0x00011ee1` |
| `+0x40` | N_LANES / lane-enable (`csi_ctrl_stream_cfg` lane count) | value from a 4-entry table indexed by `(LaneNum-1)`, OR'd with `0x10`, RMW'd in |
| `+0x4c` | **ERR interrupt STATUS 1 / D-PHY errsot status** (read, W1C) | latched into ctx `+0x1c` = ABI `ErrorStatus1`; per-lane errsot bits |
| `+0x50` | monitor/info-IRQ mask (`csi_ctrl_info_irqs_mask_cfg`) | written `0x00111100` |
| `+0x100` | **stream control** | bit0 = start (`csi_ctrl_stream_ctrl_start`), bit1 = stop (`csi_ctrl_stream_ctrl_stop`), bit4 = stream soft-reset (`csi_ctrl_stream_ctrl_soft_rst`, toggled) |
| `+0x10c` | stream cfg (`csi_ctrl_stream0_monitor_ctrl_cfg`) | RMW mask `0x333`, value `0x301` |
| `+0x110` | stream monitor ctrl | bit4 toggled |
| `+0x118` | stream monitor loopback cfg (`csi_ctrl_stream0_monitor_lb_cfg`) | written `0x00000d1f` |

`csi_ctrl_clear_irq(dev)` writes `0xFFFFFFFF` to both `+0x28` and `+0x4c`.

### CSI-2 controller init order (`ax_mipi_rx_csi_ctrl_init(dev, comboMode)`)
Strictly ordered; each step is one register write/RMW on the base above:
1. `+0x08` ← lane control (`0x43210010 | combo<<8`, mask `0x77770710`)
2. `+0x40` ← N_LANES (table[LaneNum-1] | 0x10)
3. `+0x1c` ← `0x7`
4. `+0x24` ← `0x6f`
5. `+0x2c` ← `0x11ee1`; `+0x38` ← `0x11ee1`
6. `+0x50` ← `0x111100`
7. `+0x10c` ← RMW(mask 0x333, val 0x301)
8. `+0x110` ← toggle bit4
9. `+0x118` ← `0xd1f`
10. `csi_ctrl_stream_ctrl_soft_rst(dev)` → `+0x100` bit4 toggle
11. `AX_OSAL_TM_udelay(100)`
12. `csi_ctrl_stream_ctrl_stop(dev, 0)` → `+0x100` bit1 path (arg 0)
13. `csi_ctrl_stream_ctrl_start(dev, 1)` → `+0x100` bit0 = 1 (stream ENABLE)
14. `csi_ctrl_clear_irq(dev)` → clear `+0x28`, `+0x4c`

Ordering constraint: masks (steps 3–9) MUST precede the soft-reset→stop→start
sequence; IRQ clear is last.

---

## 3. isp_sys_glb register map (base `0x02500000`, ctx `+0xb8`)

| Offset | Scheme | Field(s) |
|---|---|---|
| `+0x00` | read-only status | bits[1:0] = per-controller **deskew / lane-lock status** (polled; `3` = locked/done, `2` = intermediate). This is the link-up health register. |
| `+0xc8` VALUE / `+0xcc` MASK | mux | `isp_sys_glb_csirx_cfg_clk_sel` bits[1:0] (mask 0x3); `isp_sys_glb_isp_top_clk_sel` bits[10:8] (mask 0x700) |
| `+0xd0` SET / `+0xd4` CLR | clk enable | bit0 = `cfg_phy_clk_eb`; bit1 = `dphy_rx_ref_clk_eb` |
| `+0xd8` SET / `+0xdc` CLR | clk enable | bit7 = csirx0 pclk, bit8 = csirx1 pclk; bit4 = sys_pixel0 clk, bit5 = sys_pixel1 clk |
| `+0xe0` SET / `+0xe4` CLR | **soft resets** (assert=SET, deassert=CLR) | csirx0: bit2 pixel, bit3 ppi_rx_byte, bit4 presetn(`sw_prst`), bit5 sys; csirx1: bit6 pixel, bit7 ppi_rx_byte, bit8 presetn, bit9 sys; bit10 deskew0, bit11 deskew1, bit12 dphyrx |
| `+0x218` VALUE / `+0x21c` MASK | `csi_ctrl_sel` | routes D-PHY→controller and lane-combo split (values `0x3`/`0x30`/`0x20`/`0x30` depending on combo arg; used with mask `0x3`/`0x30`) |

---

## 4. D-PHY global config register map (base `0x023f0000`, ctx `+0xc0`)

| Offset | Scheme | Field(s) |
|---|---|---|
| `+0xc8` SET / `+0xcc` CLR | lane cfg + swaps | `dphyrx_lane_swap` writes six 3-bit per-lane swap-select fields: bits[8:6], [11:9](=`c0_swap`), [14:12], [17:15], [20:18], [23:21]. Also bit24 = `databus16_sel`, bit25 = `1d2c_en` (1-data-lane/2-clk mode) |
| `+0xd8` SET / `+0xdc` CLR | HS-RX timing | `hsrx_clk_pre_time_grp0` = bits[31:24] |
| (timing grp1 / data grp0 / data grp1) | SET/CLR | `hsrx_clk_pre_time_grp1`, `hsrx_data_pre_time_grp0/1` — same scheme, adjacent offsets; **exact offsets NOT confirmed statically** (see §7) |
| `+0x110` | PHY enable (write value) | per-lane enable bits [5:0]; `0x3f` = all (clk+4 data), `0x3c` = 4 data lanes, `0x30` = 2 data (bits5:4), `0xc` = 2 data (bits3:2), `0x3` = clk only. `dphyrx_glb_cfg_phy_en` selects `0x3f`/`0x3d`/`0x3e` per lane count and the combo flag (ctx `+0x188`). |
| `+0x114` | PHY disable (write value) | mirror of `+0x110` (write-1-to-disable) |

> **PHY timing is FIXED, not DataRate-derived.** `ax_dphyrx_glb_init` writes constant
> timing words (observed: `0x820`, `0xfff`, `0x3820`, `0x3c00`, `0x3000`, `0xc00`)
> into the HS-RX pre-time and PHY config registers, **selected by the lane-combo mode
> flag (ctx `+0x188`), never computed from the `DataRate` attr field**. For the fixed
> HDMI-bridge case the open driver can use these fixed presets. (Impact on the #17
> parametric-geometry work: PHY timing does not scale with pixel clock in the vendor
> path — flagged for on-device confirmation, §7.)

---

## 5. IRQ / error semantics

**IRQ registration:** `ax_mipi_register_mipi_rx_irq` hooks the CSI-controller error
IRQ(s) (GIC lines 31/33 = csictrl0/1 per DT). Handler chain:
`ax_mipi_csi_rx_handler` → `csi_rx_ctrl_get_irq_status` → `csi_rx_ctrl_err_irqs_handle`
(+ `csi_rx_ctrl_dphy_err_status_handle`).

`csi_rx_ctrl_get_irq_status(dev)`:
- reads controller `+0x28`, writes it back (W1C), stores to ctx `+0x18` (`ErrorStatus0`)
- reads controller `+0x4c`, W1C, stores to ctx `+0x1c` (`ErrorStatus1`)

`csi_rx_ctrl_err_irqs_handle` decodes `ErrorStatus0` (`+0x28`) bit-by-bit and logs
one message per set bit (bit→string, from the module's error strings):

| bit | condition |
|---|---|
| 0 | (packet/protocol error — first entry) |
| 4,5,6,7 | STREAM0/1/2/3_FIFO_OVERFLOW |
| 8 | truncated header (short or long) |
| 9 | truncated long packet — wrong byte count |
| 10 | truncated long packet — no payload |
| 11 | reserved/invalid short packet |
| 12 | invalid access to configuration register space |
| 16 | **resynchronization-FIFO overflow (DPHY↔protocol)** — the DWC-signature error |
| 17 | data-id error in header |
| 18 | ECC error detected and corrected |
| 19 | unrecoverable ECC error |
| (CRC) | CRC error — from the same status word |

`ErrorStatus1` (`+0x4c`) carries the per-lane `dphy data lane N errsot hs` bits
(lanes 0–3). The mask `0x11ee1` at `+0x2c` matches the enabled subset of these bits.

**This is an ERROR-ONLY interrupt path. There is NO frame-received / packet-received
interrupt used here.** The stream-monitor registers (`+0x50`, `+0x110`, `+0x118`)
configure loopback/monitor counters but the ISR handles only error bits. Frame timing
for capture comes from the downstream VIN/proton pipeline, not from this subdev.

**Error-counter / health telemetry:** the handler also accumulates 64-bit counters in
the ctx (fields at ctx `+0x28`/`+0x30` incremented per event). A separate polling
thread `ax_mipi_csi_rx_thread` + `mipi_rx_recovery_work` (a delayed-work item)
performs "lane0 err recovery" when errors persist.

**→ Link-up health check for the open driver (no IRQ needed):** poll isp_sys_glb
`0x02500000 + 0x00`, bits[1:0] == `3` (both lanes deskewed/locked). This is exactly
what `isp_sys_glb_checkdeskew_status` does (retry ~20× with delay). Complement with
`ErrorStatus0/1` counters staying flat.

---

## 6. Reset / clock / bring-up sequences (ordered call traces)

### 6a. START — `ax_mipi_rx_start(dev)` (the 996-B bring-up)
Observed call order (arg values noted; SET/CLR polarity per §3/§4):
1. `common_glb_check_fastboot_mode` — if firmware fastboot already streamed, skip re-init
2. `isp_sys_glb_csirx_pixel_swrst(dev, 0)`  → deassert pixel reset (CLR `+0xe4`)
3. `isp_sys_glb_csirx_ppi_rx_byte_swrst(dev, 0)` → deassert
4. `isp_sys_glb_csirx_sw_prst(dev, 0)` → deassert presetn
5. `isp_sys_glb_csirx_sys_swrst(dev, 0)` → deassert sys reset
6. `isp_sys_glb_deskew_swrst(...)` ; `dphyrx_glb_debug_ctrl_deskew_reset(...)`
7. `common_glb_dphyrx_tlb_sw_reset(0)` → deassert TLB reset
8. `AX_OSAL_TM_udelay(10)`
9. `isp_sys_glb_csirx_pclk_eb(dev, 1)` → enable pclk (SET `+0xd8`)
10. `isp_sys_glb_sys_pixel_clk_eb(dev, 1)` → enable pixel clk
11. `ax_dphyrx_glb_init(dev)` — D-PHY lane swap + fixed HS-RX timing + `csi_ctrl_sel`
12. `dphy_pin_mux_config(...)` — pad mux (block `0x02300000`)
13. `ax_dvp_bt_soc_init(...)` — DVP/BT path init (block `0x02303000`; not used for pure MIPI)
14. (fastboot branch) `isp_sys_glb_csirx_cfg_clk_sel(3)`
15. `isp_sys_glb_cfg_phy_clk_eb(1)` → SET `+0xd0` bit0
16. `isp_sys_glb_dphy_rx_ref_clk_eb(1)` → SET `+0xd0` bit1
17. `common_glb_clk_dphyrx_tlb_en(1)` → SET common_glb `+0x28` bit9
18. `common_glb_dphy_power_off(0)` → CLR common_glb `+0x1f0` (power UP)
19. `AX_OSAL_TM_udelay(100)`
20. `common_glb_dphy_power_ready(0)`; `AX_OSAL_TM_udelay(100)`
21. `dphyrx_glb_cfg_phy_clk_and_data_en(0)`
22. `ax_dphyrx_glb_init(dev)` (second pass — real PHY analog config)
23. `dphyrx_glb_cfg_phy_en(...)` → D-PHY `+0x110`
24. `dphyrx_glb_cfg_phy_data_disable(...)` then `dphyrx_glb_cfg_phy_data_enable(...)` (data-lane toggle)
25. `ax_mipi_rx_csi_ctrl_init(dev, combo)` — §2 (ends by enabling the stream)
26. `common_glb_clk_dphyrx_tlb_en(1)` ; `dphy_pin_mux_config(...)`

**Hard ordering constraints:** clocks (steps 9,10,15–17) before PHY power-up (18);
PHY power-up + settle delays before PHY enable (23); PHY enabled before controller
init/stream-start (25). Deskew status (§5) becomes valid only after 25.

### 6b. `ax_dphyrx_glb_init(dev)` (D-PHY analog config)
Order: `isp_sys_glb_csi_ctrl_sel(dev, 4)` → `dphyrx_lane_swap(dev)` (writes lane
swap fields to D-PHY `+0xc8/+0xcc`) → several fixed writes (`0x3f`, `0xff0000`,
`0x80000`, `0x8000000`, `0xff`, `0xff00`, `0x800`, `0xfff`, `0x820`, `0x2`…) into the
lane/timing/config registers → `AX_OSAL_TM_msleep(2)` → `isp_sys_glb_dphyrx_swrst(0)`
(release DPHY reset) → `isp_sys_glb_csi_ctrl_sel(dev, 2)` → HS-RX pre-time writes
(`1d2c_en`, `hsrx_clk/data_pre_time_grp0/1`, `databus16_sel`) with fixed values.
For dev 1 the same block repeats. The `msleep(2)` between the config writes and the
DPHY-reset release is a required settle.

### 6c. RESET — `mipi_rx_reset(dev)` (~8-register soft-reset path)
Order:
1. `common_glb_check_fastboot_mode`
2. `csi_ctrl_stream_ctrl_stop(dev,1)` ×2 → stop stream (`+0x100` bit1)
3. `dphyrx_glb_debug_ctrl_deskew_reset(...)`
4. `common_glb_dphy_power_ready(1)`; `udelay(100)`; `common_glb_dphy_power_off(1)`; `udelay(100)` (power cycle)
5. `csi_ctrl_stream_ctrl_soft_rst(dev,0)`; `…(dev,1)`; `udelay(100)` (`+0x100` bit4)
6. `csi2rx_soft_reset(dev,0)`; `csi2rx_soft_reset(dev,1)`; `udelay(100)` (`+0x04` bits[1:0])
7. `isp_sys_glb_dphyrx_swrst(1)`; `udelay(100)` (assert DPHY reset — SET `+0xe0` bit12)
8. `isp_sys_glb_checkdeskew_status(...)` (poll §5)
9. `AX_OSAL_SYNC_schedule_delayed_work(...)` (arm recovery worker)
10. `dphyrx_glb_cfg_phy_data_disable(0)`; `dphyrx_glb_cfg_phy_data_enable(0)`

De-assert order (release): DPHY reset released in `ax_dphyrx_glb_init` step; csirx
sub-resets released in the START path (§6a steps 2–5). Deassert of the pixel/ppi/
presetn/sys resets happens (CLR `+0xe4`) BEFORE clock enable BEFORE PHY power-up.

### 6d. STOP / teardown — `mipi_rx_stop` / `ax_mipi_rx_runtime_suspend`
`AX_OSAL_DEV_disable_irq` → `cancel_delayed_work` → `isp_sys_glb_dphyrx_swrst(1)`
→ `isp_sys_glb_dphy_rx_ref_clk_eb(0)` → `isp_sys_glb_cfg_phy_clk_eb(0)` →
`dphyrx_glb_cfg_phy_clk_and_data_en(0)` → power_ready/power_off cycle →
`isp_sys_glb_deskew_swrst` → `common_glb_clk_dphyrx_tlb_en(0)` → stream stop.

---

## 7. Clock-ungate ordering & the **proton coordination hazard**

Enable order (from §6a): csirx sub-resets released → pclk/pixel-clk enabled →
cfg_phy_clk + dphy_rx_ref_clk enabled → dphyrx_tlb clk enabled → DPHY powered up.
De-assert (CLR) of a reset must NOT precede the corresponding clock enable being
stable; the `udelay(10)`/`udelay(100)` gaps enforce settle.

**Blocks this driver writes that `ax_proton` / VIN also touch (HAZARD — audit before
concurrent bring-up):**
- **common_glb `0x02340000`** — `clk_vi` (`+0x28` bit17), `rx_en_vi` (`+0x408` bit2),
  DPHY power (`+0x1ec`/`+0x1f8`). This is the VI-subsystem controller; proton's VIN
  path enables `clk_vi`/`rx_en_vi` here too. Racing writes to `+0x28`/`+0x408` (even
  with the SET/CLR scheme, different bits are safe, but a full-register RMW would
  clobber) are the risk. Prefer the SET/CLR bit writes, never RMW the whole word.
- **isp_sys_glb `0x02500000`** — csirx clock gates and soft-resets. If proton also
  resets/clocks csirx, an unsequenced reset here can drop an active stream.
- **pinmux `0x02300000`** — shared with pinctrl and (per project notes) the SW_PWR
  pad trap. `dphy_pin_mux_config` re-muxes MIPI/DVP pads; coordinate with any GPIO
  users on the same pad file.

The `common_glb_check_fastboot_mode` gate exists precisely so the driver can skip
re-initialising a block the boot firmware already brought up — the open driver should
replicate that check to avoid glitching a live stream.

---

## 8. ioctl ABI (char-dev `ax_mipi_rx`, `ax_mipi_rx_ioctl`)

Magic = `'m'` (0x6d). The ioctl arg is a pointer/handle (`_IOC_SIZE`=8 for the WR
ones); handlers then `copy_from_user` the real attr struct.

| Command | Encoding | Handler | Action |
|---|---|---|---|
| `_IO('m',0)` = `0x6d00` | no data | `ax_mipi_rx_reg_init` | map/allocate device registers (DEV_INIT) |
| `_IO('m',1)` = `0x6d01` | no data | `ax_mipi_deinit` | teardown |
| `_IOWR('m',2)` = `0xc0086d02` | ptr→28-B attr | `ax_mipi_set_attr` | set attr (see below) |
| `_IOWR('m',3)` = `0xc0086d03` | ptr→attr | `ax_mipi_get_attr` | read attr back |
| `_IOWR('m',4)` = `0xc0086d04` | ptr | `ax_mipi_reset` | assert reset (§6c) |
| `_IOWR('m',5)` = `0xc0086d05` | ptr | `ax_mipi_unreset` | release reset |
| `_IOWR('m',6)` = `0xc0086d06` | ptr | `ax_mipi_start` | bring-up + stream on (§6a) |
| `_IOWR('m',7)` = `0xc0086d07` | ptr | `ax_mipi_stop` | stream off + teardown (§6d) |
| `_IOWR('m',8)` = `0xc0086d08` | ptr | `ax_mipi_set_lanecombo` | set LaneComboMode (must precede start; error "lane combo has not set yet" otherwise) |

> **9 selectors, not 7** (the prior "7" estimate is superseded). Selectors 2–8 are
> `_IOWR('m',N, <ptr>)`; 0/1 are dataless `_IO`.

**Attr struct** — `ax_mipi_set_attr` does `copy_from_user(dst, user_ptr, 0x1c)` =
**28 bytes = 7 × u32**. Fields (per project ABI + observed store to handle `+0x170`
region): `LaneNum`, `DataRate`, `DataLaneMap`, `ClkLane`, `LaneComboMode`, and two
more (InputMode / ResetCount). `LaneComboMode` lands at handle `+0x188` (the flag read
by `dphyrx_glb_cfg_phy_en` and `ax_dphyrx_glb_init`); a `LaneNum`-indexed table lookup
lands at handle `+0x180`. `ErrorStatus0/1` are OUTPUT-only (ctx `+0x18`/`+0x1c`,
populated by the ISR) and read back via `get_attr`.

Sequencing: userspace must issue `set_lanecombo`(8) and `set_attr`(2) **before**
`start`(6); `reset`(4)/`unreset`(5) bracket re-locks; `stop`(7) tears down.

---

## 9. Open questions / on-device verification checklist

1. **[identity]** `devmem2 0x02600000 w` (and `0x02602000`) with capture live — is
   offset 0x00 a DWC ASCII-BCD version? Confirms/denies DWC core. (§1)
2. **[link-up]** Read `0x02500000 + 0x00` bits[1:0] while streaming — expect `3`.
   Validates the deskew/lock health check for the open driver. (§5)
3. **[D-PHY timing offsets]** Confirm the exact offsets of `hsrx_clk_pre_time_grp1`,
   `hsrx_data_pre_time_grp0/1` in the `0x023f0000` file (grp0 clk = `+0xd8` confirmed;
   others are adjacent SET/CLR pairs — dump `0x023f00c8..0x023f0110` before/after a
   `start` to capture them). (§4)
4. **[DataRate]** Confirm on hardware that `DataRate` does **not** change any D-PHY
   register (sweep the attr `DataRate` and diff `0x023f0000` register dumps). If true,
   the open driver uses fixed per-combo timing presets. (§4, relevant to #17)
5. **[N_LANES table]** Dump the 4-entry lane table used for `+0x40` (values for
   LaneNum 1..4) — it is in `.rodata`; read `+0x40` after init for the KVM lane count
   to get the concrete value rather than reconstructing the table.
6. **[stream-ctrl bit semantics]** Verify `+0x100` bit0=start / bit1=stop / bit4=srst
   by toggling and watching the deskew-status + error counters (the stop/start
   encodings are RMW with sentinel `2`, worth a live check).
7. **[common_glb sharing]** With proton/VIN running, snapshot `0x02340000+0x28`,
   `+0x408`, `+0x1ec/+0x1f8` before/after a mipi `start`/`stop` to see whether proton
   depends on bits this driver toggles (the coordination hazard, §7).
8. **[0x02303000 block]** Identify the `ax_dvp_bt_soc_init` target — likely a DVP/BT656
   bridge unrelated to the MIPI path; can probably be omitted for the pure-MIPI open
   driver, but confirm it is not gating a shared clock.

---

## Function → claim cross-reference (for spot-checking)
- Base map: `ax_mipi_rx_reg_init` (ioremap immediates), `mipi_rx_get_csi_base_addr`
- CSI ctrl map + init order: `ax_mipi_rx_csi_ctrl_init`, `csi2rx_soft_reset`,
  `csi_ctrl_stream_ctrl_start/stop/soft_rst`, `csi_ctrl_clear_irq`
- IRQ/error: `csi_rx_ctrl_get_irq_status`, `csi_rx_ctrl_err_irqs_handle`
- isp_sys_glb: `isp_sys_glb_*_swrst`, `isp_sys_glb_*_clk_eb`, `isp_sys_glb_csi_ctrl_sel`,
  `isp_sys_glb_checkdeskew_status`
- D-PHY: `dphyrx_glb_cfg_phy_en/_data_enable/_data_disable/_clk_and_data_en`,
  `dphyrx_lane_swap`, `dphyrx_glb_rg_hsrx_clk_pre_time_grp0`, `dphyrx_dphy_cfg_1d2c_en`,
  `dphyrx_dphy_cfg_databus16_sel`, `ax_dphyrx_glb_init`
- common_glb: `common_glb_dphy_power_ready/_off`, `common_glb_clk_vi_en`,
  `common_glb_rx_en_vi`, `common_glb_clk_dphyrx_tlb_en`, `common_glb_dphyrx_tlb_sw_reset`
- Start/reset/stop order: `ax_mipi_rx_start`, `mipi_rx_reset`, `mipi_rx_stop`
- ioctl/attr: `ax_mipi_rx_ioctl`, `ax_mipi_set_attr` (copy size 0x1c)
