# Behavioral spec: AX630C MIPI D-PHY RX bring-up (`ax_mipi_rx.ko`)

Derived by static disassembly of `ax_mipi_rx.ko` (aarch64 ET_REL, unstripped).
All citations are `symbol+0xNN` **section-relative instruction offsets** as printed by
`objdump -d -r`. This document describes *register behavior only* — offsets, values,
masks, ordering, delays. No vendor source or disassembly text is reproduced.

Certainty is marked per row: **certain** = read directly off the instruction stream;
**inferred** = a deduction (naming, bit meaning, mirror mapping) not literally in the code.

---

## 1. Base-pointer attribution

All register bases live in one heap object. `mipi_pdrvdata` (`.bss+0x400`, 8 bytes) is a
single global pointer to a 400-byte (`0x190`) allocation made in
`__ax_mipi_device_init+0x88` (`kmalloc(0x190)`, zeroed at `+0xc4`).

`ax_mipi_init+0x0c` passes `mipi_pdrvdata + 0x98` to `ax_mipi_rx_reg_init`, so the
ioremap slots sit at `drvdata + 0x98 …`:

| drvdata off | phys base | ioremap len | ioremap site | block | certainty |
|---|---|---|---|---|---|
| `+0x98` | `0x0260_0000` | `0x2000` | `ax_mipi_rx_reg_init+0xe4` | CSI-2 controller 0 | certain |
| `+0xa0` | `0x0260_2000` | `0x2000` | `ax_mipi_rx_reg_init+0x130` | CSI-2 controller 1 | certain |
| `+0xa8` | `0x0230_0000` | `0x1000` | `ax_mipi_rx_reg_init+0x244` | pad-mux bank A | certain |
| `+0xb0` | `0x0230_3000` | `0x1000` | `ax_mipi_rx_reg_init+0x60` | pad-mux bank B | certain |
| `+0xb8` | `0x0250_0000` | `0x1f8` | `ax_mipi_rx_reg_init+0x180` | `isp_sys_glb` | certain |
| `+0xc0` | `0x023f_0000` | `0x120` | `ax_mipi_rx_reg_init+0x1c8` | **D-PHY RX global** | certain |
| `+0xc8` | `0x0234_0000` | `0x49c` | `ax_mipi_rx_reg_init+0x208` | `common_glb` | certain |

Notes:
- The CSI base is fetched per device as `drvdata[0x98 + dev*8]` — `mipi_rx_get_csi_base_addr+0x14`;
  `dev` is range-checked `<= 1` at `+0x04`.
- Every D-PHY accessor re-reads `*mipi_pdrvdata` then `[..+0xc0]`, e.g.
  `dphyrx_dphy_cfg_1d2c_en+0x04/+0x08`, `ax_dphyrx_glb_init+0x18/+0x1c`.
- `isp_sys_glb` accessors use `[..+0xb8]`, e.g. `isp_sys_glb_csi_ctrl_sel+0x2c/+0x30`.
- `common_glb` accessors use `[..+0xc8]`, e.g. `common_glb_dphy_power_off+0x04/+0x08`.
- **Mapping-length trap (certain):** `isp_sys_glb` is ioremapped for only `0x1f8` bytes but
  `isp_sys_glb_csi_ctrl_sel` writes `+0x218`/`+0x21c` (`+0x48`/`+0x4c` of that function).
  It works only because ioremap rounds to a page. An open driver should map `0x1000`.

### Per-device attribute block

`ax_mipi_set_attr+0x34…+0x60` copies a 28-byte user struct verbatim to
`drvdata + dev*0x30 + 0xdc`. Fields used by the PHY path:

| offset (drvdata + dev*0x30) | meaning | evidence | certainty |
|---|---|---|---|
| `+0xdc` | device id (u32) | `ax_mipi_set_attr+0x34` | certain |
| `+0xe0` | **input mode** (u32) | read as `w22` in `ax_dphyrx_glb_init+0x38`, `ax_mipi_rx_start+0x48` | certain |
| `+0xe4` | (u32, DVP/BT param) | `ax_mipi_rx_start+0x48` (`w26`) | certain |
| `+0xe8` | **lane mode** (u32, used as byte) | `ax_mipi_rx_start+0x50`, `dphyrx_glb_cfg_phy_data_enable+0x24` | certain |
| `+0xf0..0xf5` | **lane_swap[6]** = `{d0,d1,d2,d3,c0,c1}`, *signed* bytes | `dphyrx_lane_swap+0x20/+0x48/+0x70/+0x98/+0xc0/+0xe8` | certain |
| `+0xfc` | driver-private "configured" flag | `ax_mipi_rx_start+0x298` | certain |

Global (not per-device):

| offset | meaning | evidence |
|---|---|---|
| `drvdata+0x160 + dev` | per-device "started" byte, set by `ax_mipi_start+0x74` | certain |
| `drvdata+0x168` | resume guard (u32) | `ax_dphyrx_glb_resume+0x68` |
| `drvdata+0x170` | mutex | `ax_mipi_start+0x48` |
| `drvdata+0x178` | delayed work (deskew recovery) | `ax_mipi_rx_start+0x330` |
| `drvdata+0x188` | **lane_divide_mode / "combo"** (u32), set by `mipi_rx_set_lane_combo+0x1c` | certain |

`lane_divide_mode` string table (`.rodata+0xf18`, 4 entries, used by
`ax_mipi_proc_get_lane_mode+0x08`): `0 -> "4"`, `1 -> "2+2"`, `2 -> "2"`, `3 -> "0"`.
**So "4 lanes on one PHY" is `lane_divide_mode == 0`** — this is the value that reproduces
every observed readable word (see §5). `ax_mipi_rx_start+0x14` rejects the raw value `4`.

`lane_mode` (`+0xe8`) is **the data-lane count, 1-based**: `ax_mipi_rx_csi_ctrl_init+0x94`
indexes `CSWTCH.22 = {1, 3, 3, 0xf}` with `lane_mode - 1` to build the CSI lane-enable
bitmap, so `lane_mode == 4` ⇒ 4 data lanes ⇒ `0xf`. Every D-PHY helper's `lane_mode > 2`
test therefore means "3 or 4 data lanes". [inferred from the table, certain about the indexing]

`input mode` string table (`.rodata+0xf38`, 9 entries, `ax_mipi_proc_get_input_mode+0x10`):
`0=MIPI, 1=SUBLVDS, 2=LVDS, 3=HISPI, 4=SLVS, 5..8=BT`. `ax_dphyrx_glb_init+0x40` returns
immediately unless input mode is `0` or `1`.

---

## 2. D-PHY RX global block (`0x023f_0000`) register model

Every configuration register in this block is a **write-only SET / CLR pair**:
`SET = base + 0xC0 + 8k`, `CLR = SET + 4`. Writing 1-bits to CLR clears them; writing
1-bits to SET sets them. The vendor idiom is always *CLR(mask) then SET(value<<shift)*.

**Mirror law [inferred, but confirmed against all six observed words in §5]:**
`readable_word = 0x34 + (SET_offset - 0xC8) / 2`.

| SET | CLR | readable mirror | contents | certainty |
|---|---|---|---|---|
| `0xc8` | `0xcc` | `0x34` | lane swap / dp-dn swap / databus16 / 1d2c | certain (fields), inferred (mirror) |
| `0xd0` | `0xd4` | `0x38` | unnamed 12-bit timing/mode field | certain (writes), inferred (mirror) |
| `0xd8` | `0xdc` | `0x3c` | HS-RX pre-time, 4 × 8-bit | certain |
| `0xe0` | `0xe4` | `0x40` | *never written by this module* | inferred |
| `0xe8` | `0xec` | `0x44` | debug-ctrl deskew reset | certain |
| `0xf0` | `0xf4` | `0x48` | *never written by this module* | inferred |
| `0x110` | `0x114` | `0x58` | per-physical-lane PHY enable, bits[5:0] | certain |

Words `0x00 … 0x30` (13 words) are written with zero directly (not via SET/CLR) at the top
of `ax_dphyrx_glb_init+0x78 … +0xb4`.

### `0xc8/0xcc` field map (certain — each derived from its dedicated accessor)

| bits | mask | field | accessor |
|---|---|---|---|
| `[5:0]` | `0x0000003f` | `dpdn_swap` | `dphyrx_dphy_cfg_dpdn_swap+0x10/+0x1c` |
| `[8:6]` | `0x000001c0` | `c1_swap_sel` | `dphyrx_dphy_cfg_c1_swap_sel+0x10/+0x1c` |
| `[11:9]` | `0x00000e00` | `c0_swap_sel` | `dphyrx_dphy_cfg_c0_swap_sel+0x10/+0x1c` |
| `[14:12]` | `0x00007000` | `d3_swap_sel` | `dphyrx_dphy_cfg_d3_swap_sel+0x10/+0x1c` |
| `[17:15]` | `0x00038000` | `d2_swap_sel` | `dphyrx_dphy_cfg_d2_swap_sel+0x10/+0x1c` |
| `[20:18]` | `0x001c0000` | `d1_swap_sel` | `dphyrx_dphy_cfg_d1_swap_sel+0x10/+0x1c` |
| `[23:21]` | `0x00e00000` | `d0_swap_sel` | `dphyrx_dphy_cfg_d0_swap_sel+0x10/+0x1c` |
| `[24]` | `0x01000000` | `databus16_sel` | `dphyrx_dphy_cfg_databus16_sel+0x14/+0x24` |
| `[25]` | `0x02000000` | `1d2c_en` | `dphyrx_dphy_cfg_1d2c_en+0x14/+0x24` |

Each `*_swap_sel` field selects which of six physical lane slots (0–5) feeds that logical
lane [inferred from the 3-bit width and the 6-bit enable register].

### `0xd8/0xdc` field map (certain)

| bits | mask | field | accessor |
|---|---|---|---|
| `[7:0]` | `0x000000ff` | `hsrx_data_pre_time_grp1` | `dphyrx_glb_rg_hsrx_data_pre_time_grp1+0x10/+0x1c` |
| `[15:8]` | `0x0000ff00` | `hsrx_data_pre_time_grp0` | `dphyrx_glb_rg_hsrx_data_pre_time_grp0+0x10/+0x1c` |
| `[23:16]` | `0x00ff0000` | `hsrx_clk_pre_time_grp1` | `dphyrx_glb_rg_hsrx_clk_pre_time_grp1+0x10/+0x1c` |
| `[31:24]` | `0xff000000` | `hsrx_clk_pre_time_grp0` | `dphyrx_glb_rg_hsrx_clk_pre_time_grp0+0x10/+0x1c` |

(The `.part.0` bodies in `.text.unlikely` are the cold-path error printers only —
`dphyrx_glb_rg_hsrx_clk_pre_time_grp0.part.0` etc. contain **no** MMIO. Verified: they end in
a single `ax_printk` call.)

---

## 3. `ax_dphyrx_glb_init(dev, lane_mode)` — complete ordered MMIO list

Resolved for `dev = 0`, `input_mode = 0 (MIPI)`, `lane_divide_mode = 0 ("4")`,
`lane_swap = {d0=0, d1=1, d2=3, d3=4, c0=2, c1=5}` (the values that reproduce the observed
hardware state — see §5).

Preconditions checked first (all **certain**):
- `+0x18/+0x20`: D-PHY base non-NULL else bail with an error print.
- `+0x3c`: `input_mode > 1` → return without touching anything.
- `+0x44 … +0x4c`: `lane_divide_mode == 1` → `isp_sys_glb_csi_ctrl_sel(dev, 2)`, else `(dev, 4)`.
- `+0x60 … +0x74`: if `started[0] == 1` **and** device-0 `input_mode == 0` → return;
  if `started[1] == 1` → return. (Shared-PHY re-entry guard.)

| # | block | offset | value | kind | cite | certainty |
|---|---|---|---|---|---|---|
| 1 | isp_sys_glb | `0x21c` | `0x00000003` | mask/write-enable | `isp_sys_glb_csi_ctrl_sel+0x48` | certain |
| 2 | isp_sys_glb | `0x218` | `0x00000000` | value | `isp_sys_glb_csi_ctrl_sel+0x4c` | certain |
| 3 | isp_sys_glb | `0x21c` | `0x00000030` | mask | `isp_sys_glb_csi_ctrl_sel+0x8c` | certain |
| 4 | isp_sys_glb | `0x218` | `0x00000030` | value | `isp_sys_glb_csi_ctrl_sel+0x90` | certain |
| 5 | D-PHY | `0x00,0x04,0x08,0x0c,0x10,0x14,0x18,0x1c,0x20,0x24,0x28,0x2c,0x30` | `0` each | plain write | `ax_dphyrx_glb_init+0x78 … +0xb4` | certain |
| — | | | | *`dphyrx_lane_swap(dev)` — rows 6–17* | `ax_dphyrx_glb_init+0xb4` | |
| 6 | D-PHY | `0xcc` | `0x00e00000` | CLR | `dphyrx_lane_swap+0x130` → `dphyrx_dphy_cfg_d0_swap_sel+0x10` | certain |
| 7 | D-PHY | `0xc8` | `d0 << 21` = `0x00000000` | SET | `dphyrx_dphy_cfg_d0_swap_sel+0x18/+0x1c` | certain |
| 8 | D-PHY | `0xcc` | `0x001c0000` | CLR | `dphyrx_dphy_cfg_d1_swap_sel+0x10` | certain |
| 9 | D-PHY | `0xc8` | `d1 << 18` = `0x00040000` | SET | `dphyrx_dphy_cfg_d1_swap_sel+0x18/+0x1c` | certain |
| 10 | D-PHY | `0xcc` | `0x00038000` | CLR | `dphyrx_dphy_cfg_d2_swap_sel+0x10` | certain |
| 11 | D-PHY | `0xc8` | `d2 << 15` = `0x00018000` | SET | `dphyrx_dphy_cfg_d2_swap_sel+0x18/+0x1c` | certain |
| 12 | D-PHY | `0xcc` | `0x00007000` | CLR | `dphyrx_dphy_cfg_d3_swap_sel+0x10` | certain |
| 13 | D-PHY | `0xc8` | `d3 << 12` = `0x00004000` | SET | `dphyrx_dphy_cfg_d3_swap_sel+0x18/+0x1c` | certain |
| 14 | D-PHY | `0xcc` | `0x00000e00` | CLR | `dphyrx_dphy_cfg_c0_swap_sel+0x10` | certain |
| 15 | D-PHY | `0xc8` | `c0 << 9` = `0x00000400` | SET | `dphyrx_dphy_cfg_c0_swap_sel+0x18/+0x1c` | certain |
| 16 | D-PHY | `0xcc` | `0x000001c0` | CLR | `dphyrx_dphy_cfg_c1_swap_sel+0x10` | certain |
| 17 | D-PHY | `0xc8` | `c1 << 6` = `0x00000140` | SET | `dphyrx_dphy_cfg_c1_swap_sel+0x18/+0x1c` | certain |
| 18 | D-PHY | `0xcc` | `0x02000000` (`1d2c_en=0`) | CLR | `dphyrx_lane_swap+0x120` | certain |
| 19 | D-PHY | `0xcc` | `0x0000003f` (dpdn_swap mask) | CLR | `ax_dphyrx_glb_init+0xc8` | certain |
| 20 | D-PHY | `0xc8` | `0x00000000` (dpdn_swap = 0) | SET | `ax_dphyrx_glb_init+0xcc` | certain |
| 21 | D-PHY | `0xcc` | `0x01000000` (`databus16_sel=0`) | CLR | `ax_dphyrx_glb_init+0xe0` | certain |
| 22 | D-PHY | `0xdc` | `0x00ff0000` | CLR | `ax_dphyrx_glb_init+0xf4` | certain |
| 23 | D-PHY | `0xd8` | `0x00080000` → `hsrx_clk_pre_time_grp1 = 8` | SET | `ax_dphyrx_glb_init+0xfc` | certain |
| 24 | D-PHY | `0xdc` | `0xff000000` | CLR | `ax_dphyrx_glb_init+0x110` | certain |
| 25 | D-PHY | `0xd8` | `0x08000000` → `hsrx_clk_pre_time_grp0 = 8` | SET | `ax_dphyrx_glb_init+0x118` | certain |
| 26 | D-PHY | `0xdc` | `0x000000ff` | CLR | `ax_dphyrx_glb_init+0x12c` | certain |
| 27 | D-PHY | `0xd8` | `0x00000008` → `hsrx_data_pre_time_grp1 = 8` | SET | `ax_dphyrx_glb_init+0x134` | certain |
| 28 | D-PHY | `0xdc` | `0x0000ff00` | CLR | `ax_dphyrx_glb_init+0x148` | certain |
| 29 | D-PHY | `0xd8` | `0x00000800` → `hsrx_data_pre_time_grp0 = 8` | SET | `ax_dphyrx_glb_init+0x150` | certain |
| 30 | **D-PHY** | **`0xd4`** | **`0x00000fff`** | **CLR** | `ax_dphyrx_glb_init+0x158` | certain |
| 31 | **D-PHY** | **`0xd0`** | **`0x00000820`** | **SET** | `ax_dphyrx_glb_init+0x160` | certain |
| 32 | — | — | `AX_OSAL_TM_msleep(2)` | **delay** | `ax_dphyrx_glb_init+0x16c/+0x170` | certain |
| 33 | isp_sys_glb | `0xe4` | `0x00001000` (dphyrx swrst **de-assert**) | CLR | `isp_sys_glb_dphyrx_swrst+0x20/+0x24`, called at `ax_dphyrx_glb_init+0x178` | certain |

**SUBLVDS variant** (`input_mode == 1`, taken at `ax_dphyrx_glb_init+0x164`): rows 32/33 are
preceded by two extra writes and the `msleep(2)` still applies:
- D-PHY `0xd0` ← `0x00003820` (SET) — `ax_dphyrx_glb_init+0x1c0`
- D-PHY `0xcc` ← `0x02000000` (CLR, `1d2c_en=0`) — `ax_dphyrx_glb_init+0x1d4`

Notes:
- No lane-count- or combo-indexed constant table feeds the D-PHY path. Every pre-time is the
  literal `8`; there is no `.rodata` lookup. (The only `.rodata` tables in the module are
  string-pointer arrays: `CSWTCH.1` at `+0xf18`, `CSWTCH.3` at `+0xf38`, `CSWTCH.22` at
  `+0x180`, `CSWTCH.30` at `+0x270`.)
- Rows 19–21 are the inlined bodies of `dphyrx_dphy_cfg_dpdn_swap(0)` and
  `dphyrx_dphy_cfg_databus16_sel(0)`; `databus16_sel(0)` writes CLR only, never SET.
- The `1d2c_en` write in `dphyrx_lane_swap` chooses SET (`+0x1c8`) when
  `lane_divide_mode == 1`, CLR (`+0x120`) otherwise.

### `isp_sys_glb_csi_ctrl_sel(dev, sel)` decode (certain)

Masked-write pair: `0x218` = value, `0x21c` = mask/write-enable.
Field `[1:0]` = controller-0 select, field `[5:4]` = controller-1 select [inferred naming].

| dev | sel | writes |
|---|---|---|
| 0 | `0` | mask `3`, value `3` |
| 0 | `1` or `2` | mask `3`, value `1` |
| 0 | `> 2` (e.g. 4) | mask `3`, value `0`; then mask `0x30`, value `0x30` |
| 1 | `1` or `2` | mask `0x30`, value `0x20` |
| 1 | `0` | mask `0x30`, value `0x30` |
| 1 | `> 2` | mask `0x30`, value `0`; then mask `3`, value `3` |

Cites: `isp_sys_glb_csi_ctrl_sel+0x18/+0x38/+0x44/+0x48/+0x4c/+0x88/+0x8c/+0x90` (dev 0),
`+0xa0/+0xc0/+0xd8/+0xdc/+0xe0/+0xf8/+0xfc/+0x100` (dev 1).

---

## 4. PHY enable / disable helpers — complete write lists

All target the D-PHY block. `0x110` = enable (write-1-to-enable), `0x114` = disable
(write-1-to-disable). Both write-only; mirror is readable word `0x58`.

### `dphyrx_glb_cfg_phy_en(dev, lane_mode)`
Single write to `0x110` — `dphyrx_glb_cfg_phy_en+0x38` (combo-0 path) or `+0x64` (otherwise).

| condition | value written to `0x110` | cite | certainty |
|---|---|---|---|
| `lane_divide_mode == 0` (any dev/lane) | `0x3f` | `+0x2c…+0x38` | certain |
| `dev == 0`, `lane_mode > 2` | `0x3d` | `+0x1c/+0x24/+0x28` | certain |
| `dev == 0`, `lane_mode <= 2` | `0x31` | `+0x20/+0x24/+0x28` | certain |
| `dev == 1`, `lane_mode > 2` | `0x3d` | `+0x50/+0x54/+0x58` | certain |
| `dev == 1`, `lane_mode <= 2` | `0x0e` | `+0x4c/+0x54/+0x58` | certain |
| `dev > 1` | `0x00` | `+0x40/+0x44` | certain |

### `dphyrx_glb_cfg_phy_clk_and_data_en(en)`
- `en != 0` → `0x110` ← `0x3f` (`+0x14/+0x18`)
- `en == 0` → `0x114` ← `0x3f` (`+0x20/+0x24`)

### `dphyrx_glb_cfg_phy_data_enable(dev)`
Reads `lane_mode` from `drvdata + dev*0x30 + 0xe8` (`+0x24`). One write to `0x110` (`+0x40`):
- `dev == 0`, `lane_mode > 2` → `0x3c`
- `dev == 0`, `lane_mode <= 2` → `0x30`
- `dev != 0` → `0x0c`

### `dphyrx_glb_cfg_phy_data_disable(dev)`
Identical value selection (`+0x14 … +0x3c`); the single write goes to `0x114` (`+0x40`).

### `dphyrx_glb_cfg_phy_clk_disable()`
`0x114` ← `0x00000003` — `dphyrx_glb_cfg_phy_clk_disable+0x10/+0x14`.

[inferred] Bits[5:0] of `0x110/0x114/0x58` are the six *physical* lane slots. Bit 0 appears as
the clock slot for controller 0 (`0x3d`/`0x31` = data value + bit 0), bit 1 for controller 1
(`0x0e` = `0x0c` + bit 1).

### `dphyrx_glb_debug_ctrl_deskew_reset(dev, lane_mode, assert)`
Value selection at `+0x14 … +0x4c`; one write:
- `lane_mode > 2` → `0x3c00`
- `lane_mode <= 2`, `dev == 0` → `0x3000`
- `lane_mode <= 2`, `dev == 1` → `0x0c00`
- `lane_mode <= 2`, `dev > 1` → `0x0000`

Destination: `assert != 0` → `0xe8` (SET, `+0x30`); `assert == 0` → `0xec` (CLR, `+0x38`).

---

## 5. Start path — `ax_mipi_rx_start(drvdata, dev)`

Entered from `ax_mipi_start+0x58` under `drvdata+0x170` mutex, only if
`started[dev] != 1` (`ax_mipi_start+0x34`).

Guards:
- `+0x14`: `lane_divide_mode == 4` → error return `0x800e0180`.
- `+0x48`: loads `input_mode` (`w22`) and the DVP param (`w26`); `+0x50` loads `lane_mode` (`w25`).
- `+0x54`: `common_glb_check_fastboot_mode()` — reads `common_glb + 0x208`, true iff low byte
  is `0xff` (`common_glb_check_fastboot_mode+0x10 … +0x1c`).

### Cold path (`input_mode == 0`, not fastboot, `started[] == 0`)

| # | call / write | block+offset & value | delay | cite | certainty |
|---|---|---|---|---|---|
| 1 | `isp_sys_glb_csirx_pixel_swrst(dev,0)` | isp `0xe4` ← `0x04` (dev0) / `0x40` (dev1) | — | `ax_mipi_rx_start+0x64`; `isp_sys_glb_csirx_pixel_swrst+0x48/+0x78` | certain |
| 2 | `isp_sys_glb_csirx_ppi_rx_byte_swrst(dev,0)` | isp `0xe4` ← `0x08` / `0x80` | — | `+0x70`; `…ppi_rx_byte_swrst+0x48/+0x78` | certain |
| 3 | `isp_sys_glb_csirx_sw_prst(dev,0)` | isp `0xe4` ← `0x10` / `0x100` | — | `+0x7c`; `…sw_prst+0x48/+0x78` | certain |
| 4 | `isp_sys_glb_csirx_sys_swrst(dev,0)` | isp `0xe4` ← `0x20` / `0x200` | — | `+0x88`; `…sys_swrst+0x48/+0x78` | certain |
| 5 | `isp_sys_glb_deskew_swrst(dev,lane,0)` | isp `0xe4` ← `0x400` (deskew0); if `lane>2` **also** `0x800` (deskew1) | — | `+0x98`; `isp_sys_glb_deskew_swrst+0x38/+0x40`; `…deskew0_swrst+0x24`; `…deskew1_swrst+0x24` | certain |
| 6 | `dphyrx_glb_debug_ctrl_deskew_reset(dev,lane,0)` | **D-PHY `0xec` ← `0x3c00`** (lane>2) | — | `+0xa8` | certain |
| 7 | `common_glb_dphyrx_tlb_sw_reset(0)` | common `0x5c` ← `0x80` | — | `+0xb0`; `common_glb_dphyrx_tlb_sw_reset+0x20/+0x24` | certain |
| 8 | — | — | **`udelay(10)`** | `+0xb4/+0xb8` | certain |
| 9 | `isp_sys_glb_csirx_pclk_eb(dev,1)` | isp `0xd8` ← `0x80` (dev0) / `0x100` (dev1) | — | `+0xc4`; `isp_sys_glb_csirx_pclk_eb+0x34/+0x68` | certain |
| 10 | `isp_sys_glb_sys_pixel_clk_eb(dev,1)` | isp `0xd8` ← `0x10` / `0x20` | — | `+0xd0`; `isp_sys_glb_sys_pixel_clk_eb+0x34/+0x68` | certain |
| — | branch `+0xd4/+0xdc`: if `started[0..1]` halfword ≠ 0, skip 11–17 and go straight to `ax_dphyrx_glb_init` | | | | certain |
| 11 | `isp_sys_glb_csirx_cfg_clk_sel(3)` | isp `0xcc` ← `0x3` (CLR), then isp `0xc8` ← `0x3` (SET) | — | `+0x184`; `isp_sys_glb_csirx_cfg_clk_sel+0x14/+0x18` | certain |
| 12 | `isp_sys_glb_cfg_phy_clk_eb(1)` | isp `0xd0` ← `0x1` | — | `+0x18c`; `isp_sys_glb_cfg_phy_clk_eb+0x14/+0x18` | certain |
| 13 | `isp_sys_glb_dphy_rx_ref_clk_eb(1)` | isp `0xd0` ← `0x2` | — | `+0x194`; `isp_sys_glb_dphy_rx_ref_clk_eb+0x14/+0x18` | certain |
| 14 | `common_glb_clk_dphyrx_tlb_en(1)` | common `0x28` ← `0x200` | — | `+0x19c`; `common_glb_clk_dphyrx_tlb_en+0x14/+0x18` | certain |
| 15 | `common_glb_dphy_power_off(0)` | common `0x1f0` ← `0x1` (CLR of power_off) | — | `+0x1a4`; `common_glb_dphy_power_off+0x20/+0x24` | certain |
| 16 | — | — | **`udelay(100)`** | `+0x1ac/+0x1b0` | certain |
| 17 | `common_glb_dphy_power_ready(0)` | common `0x1fc` ← `0x1` (CLR of power_ready) | — | `+0x1b4`; `common_glb_dphy_power_ready+0x20/+0x24` | certain |
| 18 | — | — | **`udelay(100)`** | `+0x1bc/+0x1c0` | certain |
| 19 | `dphyrx_glb_cfg_phy_clk_and_data_en(0)` | **D-PHY `0x114` ← `0x3f`** (disable all lanes) | — | `+0x1c4` | certain |
| 20 | **`ax_dphyrx_glb_init(dev, lane)`** | §3 rows 1–33 | msleep(2) inside | `+0x1d0` | certain |
| — | branch `+0x1d4`: `input_mode > 1` skips 21–26 | | | | certain |
| 21 | `dphyrx_glb_cfg_phy_en(dev, lane)` | **D-PHY `0x110` ← `0x3f`** (combo 0) | — | `+0x1e4` | certain |
| 22 | `dphyrx_glb_cfg_phy_data_disable(dev)` | **D-PHY `0x114` ← `0x3c`** (dev0, lane>2) | — | `+0x1ec` | certain |
| 23 | `dphyrx_glb_cfg_phy_data_enable(dev)` | **D-PHY `0x110` ← `0x3c`** | — | `+0x1f4` | certain |
| — | branch `+0x1f8`: `input_mode != 0` → jump to `dphy_pin_mux_config` and finish | | | | certain |
| 24 | `ax_mipi_rx_csi_ctrl_init(dev, lane)` | see below | udelay(100) inside | `+0x204` | certain |
| 25 | clear bit0 of `drvdata + dev*0x48 + 0x48`; if it had been set, `enable_irq(drvdata[.. +0x14])` | — | — | `+0x210…+0x220`, `+0x33c` | certain |
| 26 | `common_glb_clk_dphyrx_tlb_en(1)` | common `0x28` ← `0x200` | — | `+0x228` | certain |
| 27 | if `dev == 0 && lane_mode == 2`: `schedule_delayed_work(drvdata+0x178, 50)` | — | — | `+0x22c/+0x328` | certain |
| 28 | `dphy_pin_mux_config(dev, lane_divide_mode)` | pad-mux writes, below | — | `+0x240` | certain |

`ax_mipi_rx_csi_ctrl_init(dev, lane)` writes, in order (CSI base = `0x0260_0000 + dev*0x2000`):

| offset | operation | cite |
|---|---|---|
| `+0x08` (`csi2rx_static_cfg`) | RMW under mask `0x7777_0710`, value `0x4321_0010 \| (lane_mode << 8)` | `+0x34…+0x54` |
| `+0x40` (`csi_ctrl_dphy_lane_control`) | RMW; bits are only ever OR-ed in (`bic`+`eor` = `old \| new`). Value = `0x13` when `lane_mode-1 > 3`, else `table[lane_mode-1] \| 0x10` with `table = {1, 3, 3, 0xf}` at `.rodata+0x180` (`CSWTCH.22`) — so 4 data lanes (`lane_mode == 4`) gives `0x1f` | `+0x74…+0xa8` |
| `+0x1c` | plain `0x00000007` | `+0xcc` |
| `+0x24` | plain `0x0000006f` | `+0xf0` |
| `+0x2c` | plain `0x00011ee1` | `+0x11c` |
| — | the same value is also cached to the **driver-private** word `drvdata + dev*0x48 + 0x38` — not MMIO | `+0x130` |
| `+0x50` | plain `0x00111100` | `+0x158` |
| `+0x10c` | RMW under mask `0x333`, value `0x301` | `+0x180…+0x190` |
| `+0x110` | RMW: OR in bit 4 | `+0x1b0…+0x1c0` |
| `+0x118` | plain `0x00000d1f` | `+0x1e8` |
| — | `csi_ctrl_stream_ctrl_soft_rst(dev)`: `+0x100` OR bit 4 | `+0x1f0`; `csi_ctrl_stream_ctrl_soft_rst+0x28…+0x38` |
| — | **`udelay(100)`** | `+0x1f8` |
| — | `csi_ctrl_stream_ctrl_stop(dev, 0)`: `+0x100` clear bit 1 | `+0x204`; `csi_ctrl_stream_ctrl_stop+0x28…+0x44` |
| — | `csi_ctrl_stream_ctrl_start(dev, 1)`: `+0x100` set bit 0 | `+0x210`; `csi_ctrl_stream_ctrl_start+0x28…+0x3c` |
| — | `csi_ctrl_clear_irq(dev)`: `+0x28` ← `0xffffffff`, `+0x4c` ← `0xffffffff` | `+0x218`; `csi_ctrl_clear_irq+0x28…+0x30` |

Also: `csi2rx_soft_reset(dev)` sets bits[1:0] of CSI `+0x04` (`csi2rx_soft_reset+0x28…+0x38`).

`dphy_pin_mux_config(dev, lane_divide_mode)` calls `dphy_dvp_gpio_pin_mux` when
`input_mode <= 2` or `input_mode` in `4..8` (`dphy_pin_mux_config+0x6c…+0x80`), i.e. **MIPI
does go through the pad mux**. `dphy_dvp_gpio_pin_mux.isra.0`:

- Unconditionally RMWs pad-mux bank A (`0x0230_0000`), clearing bits `[18:16]` (mask
  `0xfff8ffff`) at offsets `0x0c, 0x18, 0x24, 0x30, 0x3c, 0x48, 0x54, 0x60, 0x6c, 0x78, 0x84`
  — `dphy_dvp_gpio_pin_mux.isra.0+0x14 … +0x94`. **`0x0230_0060` is in this list** (the SW_PWR /
  VI_D7 pad trap).
- Bank B (`0x0230_3000`), 12 pads at `0x0c, 0x18, 0x24, 0x30, 0x3c, 0x48, 0x54, 0x60, 0x6c,
  0x78, 0x84, 0x90`, function field = bits `[18:16]`:
  - `lane_divide_mode` 0 or 1 → all 12 set to function 0 (`+0x108 … +0x198`)
  - `lane_divide_mode == 2` → first 6 to function 0, last 6 to function 1 (`+0x19c … +0x244`)
  - `lane_divide_mode == 3` → all 12 to function 1 (`+0xa8 … +0x244`)

### `mipi_rx_reset(drvdata, dev)` — NOT on the start path

Reached only from `ax_mipi_reset` / the PM path, not from `ax_mipi_rx_start`. Sequence
(`mipi_rx_reset+0x68 … +0xe4`): `csi_ctrl_stream_ctrl_stop(0,1)`,
`csi_ctrl_stream_ctrl_stop(1,1)`, `dphyrx_glb_debug_ctrl_deskew_reset(dev,lane,0)`,
`common_glb_dphy_power_ready(1)` (common `0x1f8` ← `1`), `udelay(100)`,
`common_glb_dphy_power_off(1)` (common `0x1ec` ← `1`), `udelay(100)`,
`csi_ctrl_stream_ctrl_soft_rst(0)`, `csi_ctrl_stream_ctrl_soft_rst(1)`, `udelay(100)`,
`csi2rx_soft_reset(0)`, `csi2rx_soft_reset(1)`, `udelay(100)`,
`isp_sys_glb_dphyrx_swrst(1)` (isp `0xe0` ← `0x1000`, assert), `udelay(100)`.

### `ax_dphyrx_glb_resume(dev, lane_mode)` — deltas vs `ax_dphyrx_glb_init`

Write list is **byte-identical** to §3 rows 1–31 and row 33 (`ax_dphyrx_glb_resume+0x50 …
+0x168`). Differences:

1. **No `msleep(2)`** before `isp_sys_glb_dphyrx_swrst(0)` (`+0x164` jumps straight to the call).
2. Different entry guard: instead of the `started[]` check it uses
   `if (lane_mode <= 2 && drvdata[0x168] == 0) return;` (`+0x5c … +0x6c`).
3. The `input_mode == 1` extra writes are the same two (`+0x1a4`, `+0x1bc`).

### Deskew lock polling

`isp_sys_glb_checkdeskew_status()` polls **`isp_sys_glb + 0xc4`, bits `[1:0]`**
(`isp_sys_glb_checkdeskew_status+0x1c/+0x28/+0x30`):
- `== 3` → locked, return 0 immediately
- `== 2` → tight loop, `udelay(1)` × up to 10, counting occurrences; returns 1 if seen more
  than once (`+0x60 … +0xb0`)
- otherwise → `msleep(1)`, up to 20 attempts (`+0x44/+0x48`)

`mipi_rx_recovery_work` (`drvdata+0x178`, scheduled 50 jiffies out for `dev 0, lane 2`) calls
it and, on a non-zero result, does `dphyrx_glb_cfg_phy_data_disable(0)` then
`dphyrx_glb_cfg_phy_data_enable(0)` and reschedules (`mipi_rx_recovery_work+0x08 … +0x38`).

Note the block `isp_sys_glb + 0xc0/0xc4` is **never written** by this module — `0xc4` is a
read-only status word, not the CLR half of a pair. [inferred]

---

## 6. Reconciliation with the observed readable words

Applying the mirror law `readable = 0x34 + (SET - 0xC8)/2`:

| readable | vendor value | produced by | verdict |
|---|---|---|---|
| `0x34` | `0x0005c540` | SET/CLR pair `0xc8/0xcc` — §3 rows 6–21 | **certain** the pair is the source; the exact value decodes cleanly (below) |
| `0x38` | `0x00000820` | SET/CLR pair `0xd0/0xd4` — §3 rows 30–31 (`CLR 0xfff`, `SET 0x820`) | **certain** — the literal `0x820` appears nowhere else in the module |
| `0x3c` | `0x08080808` | SET/CLR pair `0xd8/0xdc` — §3 rows 22–29, all four pre-times = `8` | **certain** |
| `0x40` | `0x00000064` | pair `0xe0/0xe4` — **never written by `ax_mipi_rx.ko`** | hardware reset default (or set by bootloader / another module) [inferred] |
| `0x44` | `0x00000000` | pair `0xe8/0xec` — start path writes `CLR 0x3c00` only | **certain** (consistent) |
| `0x48` | `0x00013f3f` | pair `0xf0/0xf4` — **never written by `ax_mipi_rx.ko`** | hardware reset default [inferred] |
| `0x58` | `0x0000003f` | pair `0x110/0x114`: `0x114←0x3f`, `0x110←0x3f`, `0x114←0x3c`, `0x110←0x3c` | **certain** — the final `0x3f` requires `lane_divide_mode == 0` (the `dphyrx_glb_cfg_phy_en` combo-0 override); `0x3d`/`0x31` cannot reach `0x3f` |

The mirror law is validated by four independent points (`0x38`↔`0x820`, `0x3c`↔`0x08080808`,
`0x58`↔`0x3f`, `0x44`↔`0` after a CLR-only write), so it is safe to rely on.

### Decoding the two words that differ from the open driver

`0x34 = 0x0005c540` (vendor) → bits set: 6, 8, 10, 14, 15, 16, 18. Split by the §2 field map:

| field | vendor | open driver (`0x00053940`) |
|---|---|---|
| `dpdn_swap[5:0]` | `0` | `0` |
| `c1_swap_sel[8:6]` | `5` | `5` |
| `c0_swap_sel[11:9]` | **`2`** | **`4`** |
| `d3_swap_sel[14:12]` | **`4`** | **`3`** |
| `d2_swap_sel[17:15]` | **`3`** | **`2`** |
| `d1_swap_sel[20:18]` | `1` | `1` |
| `d0_swap_sel[23:21]` | `0` | `0` |
| `databus16_sel[24]` | `0` | `0` |
| `1d2c_en[25]` | `0` | `0` |

**This is the whole `[15:10]` delta.** The vendor board maps the clock lane to physical slot 2
with the data lanes at 0, 1, 3, 4 (`{d0,d1,d2,d3,c0,c1} = {0,1,3,4,2,5}`); the open driver is
using the naive sequential map `{0,1,2,3,4,5}`. These values are **not** hard-coded in the
module — they arrive from userspace in the `AX_MIPI` attribute struct
(`ax_mipi_set_attr`, §1) and are copied to `drvdata + dev*0x30 + 0xf0..0xf5` as signed bytes.
A negative byte means "no override": `dphyrx_lane_swap` then writes CLR(mask) followed by
SET(mask), i.e. the field is forced to `7` (`dphyrx_lane_swap+0x30/+0x34` and the five
analogous sites).

`0x38 = 0x00000820` — the open driver reads `0` here, meaning §3 rows 30–31 are missing
entirely. The fix is exactly two writes, immediately after the four pre-time writes and
immediately before the `msleep(2)` + dphyrx reset de-assert:

```
D-PHY + 0xd4  <-  0x00000fff        (CLR, clears bits [11:0])
D-PHY + 0xd0  <-  0x00000820        (SET, sets bits 5 and 11)
```

Field names for bits 5 and 11 of `0xd0/0xd4/0x38` are not recoverable from this binary; the
only other value ever written there is `0x3820` (bits 5, 11, 12, 13) on the SUBLVDS path,
which suggests bits `[13:12]` are a mode selector and `0x820` is the MIPI/D-PHY setting.
[inferred]
