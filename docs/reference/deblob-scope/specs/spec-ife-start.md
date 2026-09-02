# Behavioural spec — AX630C IFE / IFE-WDMA start path (`ax_proton.ko`)

Derived from static disassembly of the vendor module only. Behaviour descriptions,
register offsets, field masks and ordering; no vendor source is reproduced.
Every claim carries a `function+0xNN` / absolute-`.text`-offset citation and a
certainty marker:

* **[C]** certain — read directly off the instruction stream.
* **[I]** inferred — structural analogy or single-consumer reasoning; stated as such.

All offsets below are **absolute byte offsets inside the 0x100000 register file at
phys 0x02400000** unless explicitly labelled otherwise.

---

## 0. Address model — how to convert any citation to a physical address

### 0.1 The two write primitives

| Primitive | `.text` | What it does |
|---|---|---|
| `ISP_DRV_IO_WRITE32(h, off, val)` | `0x364f8` | `*(u32*)(h[0x00] + off) = val` — the store is `36504: ldr x3,[x0]` / `36510: str w2,[x3, w1 uxtw]`. **[C]** |
| `ISP_DRV_IO_READ32(h, off)` | `0x36570` | `3657c: ldr x0,[x0]` / `36584: ldr w0,[x0, w1 uxtw]`. **[C]** |
| `ISP_DRV_IO_GLB_WRITE32` | `0x366f0` | uses `h[0x08]` (`366fc`) — the 0x02500000 window. **[C]** |
| `ISP_DRV_IO_RST_WRITE32` | `0x365f0` | uses `h[0x10]` (`365fc`) — 0x02500000. **[C]** |
| `ISP_DRV_IO_COM_GLB_WRITE32` | `0x367f0` | uses `h[0x18]` (`367fc`) — a fourth window, only used by `ax_isp_common_isp_mm_set` at off `0x28`. **[C]** |
| `ax_regio_blk_io_write(blk, dummy, off, val)` | `0x3bff8` | bounds-checks `off` against `blk+0x84` (`3c020`), calls a pre-hook `blk[0xd0]->[8]->[0x60]` (`3c038`–`3c048`), and on hook success does a **plain 32-bit MMIO store**: `3c050: ldr x1,[x19,#192]` / `3c054: str w22,[x1, w20 uxtw]`. **[C]** |
| `ax_regio_blk_io_read(blk, off)` | `0x3d380` | mirror of the above. **[C]** |

**Consequence (answers part of Q3/Q4):** every register write in the whole IFE /
IFE-WDMA / SIF start path reaches the hardware as an ordinary CPU 32-bit store to
`block_base + off`. There is **no CDMA-only write anywhere in the IFE path** — the
CDMA-only entry points `ax_regio_blk_io_write_appending_v1`, `_within_cdma`,
`_polling_eq`, `_extension`, `_lut`, `_shadow_cmdbuf` are called *exclusively* from
ITP / YUV / sync-agent code (`isp_sync_agent_mod_wrapper_trigger`, `itp_rdma_shadow`,
`itp_wdma_shadow`, `itp_hdr_*_within_cdma`, `yuv_rdma_shadow`, `yuv_wdma_shadow`,
`yuv_wdma_set_parameter`, `__isp_yuv_wdma_setirq`, `isp_itp_top_wrapper_regio_create`,
`ax_isp_int_{mask,clear}_set_cdma`, `isp_drv_wrapper_regio_dft_create`). **[C]**
A plain-CPU replay of the IFE path therefore loses **no** register write to a cmdbuf.

### 0.2 Block bases (`.data+0x2810`, 0x4c-byte entries)

`isp_regio_ife_reglist_get` (`0x2ed78`) walks an 18-entry table at `.data+0x2810`,
stride 0x4c, matching on `{u32 module_id, u32 index}`; the entry layout is
`{id, idx, base, end, byte_size, n_regs, …, char name[0x20] @ +0x2c}`. **[C]**

| id | name | base | end | regs |
|---|---|---|---|---|
| 0 | `ife_top` | **0x00000** | 0x03fff | 137 (window 0x000–0x223) |
| 1 | `ife_shadow` | 0x00000 | 0x0d1fff | 137 |
| 2 | `ife_hsk` | **0x04000** | 0x05fff | 72 (0x4000–0x411f) |
| 4 | `ife_sif` | **0x06000** | 0x07fff | 465 |
| 5 | `ife_blc0..3` | 0x08000/9/a/b000 | | 152 each |
| 6 | `ife_raw_drc0..3` | 0x0c000..0x0f000 | | 43 each |
| 7 | `ife_raw_scl0..3` | 0x10000..0x13000 | | 23 each |
| 9 | `ife_wdma` | **0x14000** | 0x14fff | 458 (0x14000–0x14727) |
| 10 | `ife_nuc` | 0x15000 | 0x15fff | 28 |

(`isp_regio_itp_reglist_get` `0x2edd8` → `itp_top` 0x80000 … ; `isp_regio_yuv_reglist_get`
`0x2ee40` → `yuv_top` 0xc0000, `yuv_fbc` 0xc4000, `yuv_eis_pre_stat` 0xd1000,
`yuv_eis_post_stat` 0xd10b8.) **[C]**

So: `ax_ife_top_*` offsets are already absolute (base 0); every `ife_wdma_*` offset
below must be read as **`0x14000 + off`**.

---

## 1. IFE-top control helpers — complete write behaviour

| Helper | `.text` | Reg | Access | Write semantics | RO / strobe? |
|---|---|---|---|---|---|
| `ax_ife_top_init` | `0x11ab0` | — | — | **does nothing**: `11ab0: mov w0,#0` / `11ab4: ret`. Contrast `ax_itp_top_init` `0x111e0` which sets `+0x80004` bit0 (`11200`) and clears `+0x80008` (`11228`). **[C]** | — |
| `ax_ife_top_module_bypass_get` | `0x11ac0` | **0x150** | regio read `11ad0` | — | readable state |
| `ax_ife_top_module_bypass_set` | `0x11af0` | **0x150** | regio write `11b2c` | writes the caller's whole u32; the preceding read (`11b18`) is **discarded** (`w3` comes from `[x2]` at `11b14`). Not an RMW. **[C]** | writable |
| `ax_ife_top_module_bypass_set_cfg_get/_set` | `0x11b48` / `0x11b78` | **0x154** | `11b5c` / `11bb4` | whole u32, read discarded. **[C]** | see §1.1 |
| `ax_ife_top_module_bypass_clr_cfg_get/_set` | `0x11bd0` / `0x11c00` | **0x158** | `11be4` / `11c3c` | whole u32, read discarded. **[C]** | see §1.1 |
| `ax_ife_top_module_enable` | `0x11c58` | **0x158** | — | **is literally a tail-jump** `11c58: b 11c00 <ax_ife_top_module_bypass_clr_cfg_set>`. "Enable module" == write its bit into **0x158**. **[C]** | — |
| `ax_ife_top_module_disable` | `0x11c60` | **0x154** | — | tail-jump `11c60: b 11b78 <…bypass_set_cfg_set>`. "Disable" == write bit into **0x154**. **[C]** | — |
| `ax_ife_top_data_source_mux_get/_set` | `0x11c68` / `0x11c98` | **0x16c** | `11c7c` / `11cd4` | whole u32. **`_set` has no caller anywhere in the module.** **[C]** | mirror, see §1.2 |
| `ax_ife_top_data_source_mux_enable` | `0x11cf0` | **0x170** | `11d2c` | whole u32 from `*arg`. Only caller: `isp_ife_top_mod_wrapper_update+0x4c` (`27294`). **[C]** | **strobe [I]** |
| `ax_ife_top_data_source_mux_disable` | `0x11d48` | **0x174** | `11d84` | whole u32 from `*arg`. Only caller: `…_update+0x5c` (`272a4`). **[C]** | **strobe [I]** |
| `ax_ife_top_mem_share_cfg_set` | `0x11f78` | **0x178** | `11fb4` | whole u32. Caller `…_update+0x80` (`272c8`). **[C]** | writable |
| `ax_ife_top_module_bypass_get_cpu / _set_cpu` | `0x11fd0` / `0x12000` | **0x150** | `ISP_DRV_IO_*` (`11fe4`, `12034`) | identical to the regio pair but bypasses the regio layer entirely. **[C]** | writable |
| `ax_ife_top_axi_ctrl_set` | `0x12878` | **0x184** | `ISP_DRV_IO_WRITE32` `128ac` | whole u32, read discarded. Callers: `VIN_glb_sleep`, `VIN_glb_wakeup`, `ax_isp_axi_busy_check_legacy`, `ax_isp_reset_all_legacy` — **not** in the normal stream-start path. **[C]** | writable |
| `ax_ife_top_axi_ctrl_get` | `0x128c8` | — | — | stub, returns 0, reads nothing. **[C]** | — |
| `ax_ife_top_axi_status_get` | `0x128d0` | **0x188** | read `128e4` | — | **read-only** |
| `ax_ife_top_dummy_en_get` | `0x12900` | **0x0004** | read `12914` | **no setter exists in `ax_proton` at all** (grep of every `ISP_DRV_IO_WRITE32` / `ax_regio_blk_io_write` call site). **[C]** | read-only from this module |
| `ax_ife_top_split_en_cfg_set/_get` | `0x11ef0` / `0x11f48` | **0x1a4** | `11f2c` / `11f5c` | whole u32. **[C]** | writable |
| `ax_ife_top_vbus_monitor_set` | `0x11da0` | **0x200** | `11de8` | **RMW**: `new = (old & 0xffffffe0) \| (arg[1] & 0xf) \| ((arg[0] & 1) << 4)` — `11dcc: and w20,w20,#1`, `11dd0: and w3,w0,#0xffffffe0`, `11ddc: bfi w19,w20,#4,#28`, `11de4: orr w3,w3,w19`. **[C]** | writable |
| `ax_ife_top_vbus_monitor_get` | `0x11e00` | **0x200** | read | | |
| `ax_ife_top_glb_pts_timer_sel` | `0x12818` | **0x1b8** | `ISP_DRV_IO_WRITE32` `12860` | RMW set/clear of `bit(dev)`: `12848: lsl x3,x2,x22`, `1284c/12850: orr/bic`, `1285c: csel`. Caller `vin_dev_path_set`. **[C]** | writable |
| `ax_ife_top_get_pts` | `0x11e38` | **0x1bc / 0x1c0** (dev0), **0x1c4 / 0x1c8** (dev1) | reads only (`11e58`, `11e60`, `11ed0`) | 64-bit frame timestamp, low word then high word. `ax_ife_top_glb_get_pts` `0x127a8` generalises: low = `0x1bc + 8*dev` (`127c8`), high = `0x1c0 + 8*dev` (`127c4/127d0`). **[C]** | **READ-ONLY COUNTER** |

### 1.1 `0x150 / 0x154 / 0x158` — per-module bypass mask semantics

* `0x150` is the **readable accumulated bypass mask**; `1 = module bypassed`,
  `0 = module active`. It is directly writable (`ax_ife_top_module_bypass_set`,
  `…_set_cpu`). **[C]**
* `0x154` = "SET bypass bits" (module **disable**); `0x158` = "CLEAR bypass bits"
  (module **enable**). Established by the two tail-jumps at `11c58` / `11c60`. **[C]**
* Bit assignment, from `ife_top_bypass_get_module_id` (`0x115ad0`) — `bit = f(module_id, index)`:

  | module id | block | bit |
  |---|---|---|
  | 0 `ife_top` | `115b8c` → `idx + 0` | 0 |
  | 2 `ife_hsk` | `115be8` → `idx + 1` | 1 |
  | 4 `ife_sif` | `115c28` → `idx + 2` | 2 |
  | 5 `ife_blc0..3` | `115b1c` → `idx + 3` (idx ≤ 3) | 3–6 |
  | 6 `ife_raw_drc0..3` | `115c14` → `idx + 7` (idx ≤ 3) | 7–10 |
  | 7 `ife_raw_scl0..3` | `115b78` → `idx + 0xb` (idx ≤ 3) | 11–14 |
  | 9 `ife_wdma` | `115bfc` → `idx + 0xf` | 15 |
  | 10 `ife_nuc` | `115b58` → `idx + 0x10` | 16 |

  **[C]** This reproduces the observed `0x158 <- 0x8007` (top+hsk+sif+wdma un-bypassed)
  giving `0x150 == 0xffff7ff8`.

* **How the vendor actually writes them** — `isp_ife_top_mod_wrapper_setup` (`0x26dc0`):
  1. read the current `0x154` into a local (`26df4`) and `0x158` into a local (`26e08`); **[C]**
  2. compute `bit = 1 << bitidx` (`26e60`); **[C]**
  3. if the module is being **enabled** (`cfg[+4] != 0`, `26e6c`): `set_word &= ~bit`,
     `clr_word |= bit` (`26fd4`–`26fdc`); if being **disabled**: `set_word |= bit`,
     `clr_word &= ~bit` (`26e70`–`26e78`); **[C]**
  4. write **both** registers, `0x154` first then `0x158` (`26e88`, `26e94`). **[C]**

  So the vendor always writes a *full accumulated mask* into both, and always writes
  `0x154` **before** `0x158`. Whether `0x154` latches or self-clears cannot be decided
  statically — the code RMWs it as if it latched, but the same code RMWs `0x158`, which
  hardware evidence shows acts as a W1C strobe on `0x150`. **[I]** Practically:
  **`0x150` is the authoritative state and it already matches vendor, so this is not the wall.**

* There is a second, independent path: `vin_dev_node_init` (`0xb9cf8`) reads `0x150`
  with `…_get_cpu` (`b9d84`) and writes it back with `…_set_cpu` (`b9da4`) after
  `low16 &= 0x7ffb` (`b9d90`/`b9d94`) — i.e. a direct CPU clear of **bit 2 (`ife_sif`)
  and bit 15 (`ife_wdma`)** only, leaving every other bit untouched. **[C]**

### 1.2 `0x16c / 0x170 / 0x174` — the data-source mux

Structurally identical triple to `0x150 / 0x154 / 0x158`: a `_get`/`_set` pair on
`0x16c`, an `_enable` on `0x170`, a `_disable` on `0x174`. **[C]**

The decisive observation: in the whole module, `ax_ife_top_data_source_mux_set`
(the only writer of `0x16c`) is **never called**, while `_enable` (`0x170`) and
`_disable` (`0x174`) are both called on every `isp_ife_top_mod_wrapper_update`. **[C]**
Therefore the vendor establishes the IFE data-source routing **exclusively through
`0x170` / `0x174`**, and by analogy with the bypass triple these are W1S/W1C strobes
whose effect is visible in the `0x16c` mirror. **[I — high confidence]**

**Snapshot implication:** if `0x170`/`0x174` self-clear, they read back 0 and a
"replay every non-zero word" pass writes nothing to them; and writing the mirror
`0x16c` may be a no-op if `0x16c` is status-only. This is candidate #2 in §5.

---

## 2. The bypass (MODE10) start sequence

### 2.1 Call spine

`ax_vin_pipe_start` (`0x85d20`) → `ax_wrapper_vin_pipe_start` (`0x42790`) →
`pipe->[176]->[8]->[104]` (`427cc`/`427d8`) → **`vin_bypass_pipe_start`** (`0x797a0`). **[C]**

`vin_bypass_pipe_start` itself issues **no register writes**: it is a generic node-graph
walker that invokes per-node vtable slots (`node->ops[+0x90]` at `79834`/`7984c`,
`node->ops[+0x98]` at `798d4`/`798ec`, `node->ops[+0x58]` at `79ac0`, `node->ops[+0x88]`
at `79b30`, …) over the 0x18 × 0x10 node matrix. **[C]** All hardware programming
lives in the node/wrapper leaves below.

`vin_bypass_pipe_trigger` (`0x339c`, in `.text.unlikely`) is a **logging stub** — it
validates its arguments and calls `ax_printk`, nothing else. **[C]** There is no
per-frame "pipe trigger" register write for the bypass pipe.

### 2.2 IFE-top programming (`isp_ife_top_mod_wrapper_*`)

`isp_ife_top_mod_wrapper_setup` (`0x26dc0`), per module — see §1.1 step list.
Net writes: `0x154` then `0x158`. **[C]**

`isp_ife_top_mod_wrapper_update` (`0x27248`), in strict order: **[C]**

| # | call site | register | value |
|---|---|---|---|
| 1 | `27284` `ax_ife_top_vbus_monitor_set` | `0x200` | `(old & ~0x1f) \| 0` — arg struct at `sp+0x38` was zeroed at `27254` |
| 2 | `27294` `…_data_source_mux_enable` | **`0x170`** | `cfg[0]` (u32 at `arg+0`) |
| 3 | `272a4` `…_data_source_mux_disable` | **`0x174`** | `cfg[1]` (u32 at `arg+4`) |
| 4 | `272b4` `…_split_en_cfg_set` | `0x1a4` | **constant `0x57fffbbf`** — built at `27274`/`27278`, stored to `sp+0x34` at `2727c` |
| 5 | `272c8` `…_mem_share_cfg_set` | `0x178` | `cfg[2]` (u32 at `arg+8`) |

Note item 4: `0x1a4` is written with a fixed literal `0x57fffbbf` every update. **[C]**

### 2.3 IFE-WDMA register map (all offsets `+0x14000`)

From `ife_wdma_shadow` (`0x4f20`), `ife_wdma_chn_enable` (`0x5050`),
`ife_wdma_set_parameter` (`0x5140`), `ife_wdma_reset` (`0x4dc0`). Vtable slots are
`.data+0x48 reset / +0x50 shadow / +0x58 chn_enable / +0x60 set_parameter`
(relocations in `.data` at 0x48–0x60). **[C]**

**Per-channel bank A — stride 0x18:**

| formula | chn 8 → file | meaning | citation |
|---|---|---|---|
| `0x18*chn + 0x0c` | **0x140cc** | **shadow-load trigger, bit0** | `ife_wdma_shadow+0x34` (`4f54`), write at `4fa4`; `orr w3,w0,#1` (`4f94`) or `and w3,w0,#0xfffffffe` (`4fc4`) when mode == 0xe |
| `0x18*chn + 0x10` | **0x140d0** | **shadow value, low 16 bits only** — `and w3,w23,#0xffff` (`4f74`), write at `4f7c` | `ife_wdma_shadow+0x30` (`4f50`) |
| `0x18*chn + 0x14` | **0x140d4** | **DMA base address >> 3** — `lsr w3,w21,#3` (`52d4`), write at `52e0` | `set_parameter` type 6 (`52b4`–`52e0`) |
| `(chn+1)*0x18` = `0x18*chn + 0x18` | **0x140d8** | per-channel control word: `new = (old & 0xffe060c0) \| 0x000f941f \| (old bit8)` — `53b4: mov w25,#0xffe060c0`, `53e4: ubfx x24,x24,#8,#1`, `53e8/53f0: mov w3,#0x000f941f`, write at `540c` | `set_parameter` type 0 |
| `0x18*chn + 0x1c` | **0x140dc** | **channel enable, bit0** — `bfxil w3,w21,#0,#1` (`50a0`), write at `50a4` | `ife_wdma_chn_enable` (`507c`–`50a4`) |

**Per-channel bank B — stride 0x20, base `(chn+0xf)<<5`** (`5310`/`5318`; chn 8 → `0x142e0`): **[C]**

| formula | chn 8 | meaning |
|---|---|---|
| `bank+0x1c` | 0x142fc | bits[2:0] ← rodata table lookup by pixel format (`5354`, `5374`–`538c`) |
| `bank+0x18` | 0x142f8 | bits[3:0] ← second rodata table lookup (`5358`, `539c`–`53b0`) |
| `bank+0x10` | 0x142f0 | low 16 bits ← `p[64]` (`541c`–`5448`) |
| `bank+0x14` | 0x142f4 | ← `p[68]` (`544c`–`546c`) |
| `bank+0x0c` | 0x142ec | `{hi16 = p[44], lo16 = p[40]}` (special "p[3] ≤ 1" branch, `58f0`–`5918`) |

**Type-1 (geometry) registers**, `x21 = (chn<<5) + 0x200` (`5638`/`563c`; chn 8 → `0x14300`): **[C]**

| reg | chn 8 | value |
|---|---|---|
| `(chn<<5)+0x200` | 0x14300 | `{hi16 = p[4], lo16 = p[12]}` (`566c`, write `5670`) |
| `(chn<<5)+0x204` | 0x14304 | `{hi16 = p[8], lo16 = p[16]}` (`5690`, write `569c`) |
| `(chn<<5)+0x1e8` | 0x142e8 | bit0 ← `p[0]` (`567c: sub x21,x21,#0x18`, `56b8`) |

**Other `set_parameter` families:** type 2 → `0x3e8 + 0x18*chn` and `0x3ec + 0x18*chn`
(chn ≤ 0xc; `577c`–`5870`); type 4 → `0x638 + 4*chn` (chn ≤ 4; `56dc`–`5710`);
type 8 → `4*(0x14a+p[1])`, `4*(0x142+p[3])`, `4*(0x162+p[5])`, `4*(0x156+p[7])`
(`54f8`–`5608`); the "p[0]==1" variant also hits `0x5c8 + 0xc*idx` (bit0 |= 1, `59fc`)
and `0x5cc + 0xc*idx` (`5a30`). **[C]**

**The two writes at the end of `set_parameter` type 0** — these are the ones a
snapshot replay is most likely to lose:

| # | register | operation | citation |
|---|---|---|---|
| A | **`0x146dc`** (absolute; built as `mov w1,#0x46dc` + `movk w1,#1,lsl#16`, `5478`/`547c`) | **RMW via raw CPU I/O**: `new = (old & 0x0000f81c) \| 1` — read `5488`, `548c: mov w2,#0xf81c`, `5490: and`, `5494: orr w2,w2,#1`, write `54a4`. Note the mask **clears bits 0,1,5–10 and all of 16–31** and preserves only bits 2,3,4,11–15. | `ife_wdma_set_parameter+0x338` |
| B | **`0x146e0`** (blk off `0x6e0`) | read (`54b0`, result discarded) then **write `0xffffffff`** (`54bc`, `54c4`) | `ife_wdma_set_parameter+0x36c` |

`ife_wdma_reset` (`0x4dc0`), for completeness (deinit path, not start):
`0x14648` bit0←0 (`4de0`), `0x1464c`←0 (`4e04`), `0x14650 = (old & ~0x3f) | 0x20` (`4e20`),
`0x14654 &= 0xffef0000` (`4e48`), `0x14658 = (old & 0xc0000000) | 0x180420c4` (`4e6c`/`4e74`),
`0x1465c` low-byte bits[1:0]←0 (`4e94`/`4ea8`), `0x14660 &= ~3` (`4ebc`). **[C]**

### 2.4 IFE-WDMA wrapper ordering

`isp_ife_wdma_wrapper_setup` (`0x15cb0`): **[C]**
1. `set_parameter(chn=0, type=0xb, …)` — `15d08: mov w3,#0xb`, `15d10: blr`
   (`type 0xb` is a no-op/validate branch, `5254`).
2. `__isp_ife_wdma_whole_frame_setup` (`0x14de0`) or `__isp_ife_wdma_partition_frame_setup`
   (`0x15678`) depending on `cfg[1]` (`15d1c`/`15d24`).
3. copies the config into the per-channel slot and bumps a counter (`15d60`, `15d70`).

`__isp_ife_wdma_whole_frame_setup` (`0x14de0`) issues, in this order: **[C]**
1. `set_parameter(chn, type = 0, …)` — `14f0c: mov w3,#0` / `14f10: blr x5`.
   → programs bank B format/stride, the `(chn+1)*0x18` control word, `0x140d0`-adjacent
   size words, **and the `0x146dc` go-bit RMW + `0x146e0 = 0xffffffff`**.
2. `set_parameter(chn′, type = 4, …)` — `14f54: mov w3,#4` / `14f5c: blr x5`
   (guarded by `cfg[3] != 0`, `14f1c`).
3. `set_parameter(chn, type = 1, …)` — `14fa0: mov w3,#1` / `14fa4: blr x5`
   (guarded by `cfg[6] != 0`, `14f6c`) → the width/height pair + the `bank-0x18` bit0.

Note the ordering oddity: **the `0x146dc` go bit is asserted in step 1, before the
geometry registers of step 3 are written.** **[C]**

`isp_ife_wdma_wrapper_enable` (`0x14358`), per channel: **[C]**
1. `set_parameter(chn, type = 8, …)` — `144c8: mov w3,#8` / `144cc: blr x5`
   (and the second copy at `14690`/`14694`).
2. `set_parameter(chn, type = 2, …)` — `14538: mov w3,#2` / `1453c: blr x5`
   (and `14700`/`14704`); only when `cfg[+31] != 0` (`144d8`).
3. `chn_enable(chn, en)` — slot `+0x58`, `1454c`/`14564` (and `14718`/`14730`)
   → `0x18*chn + 0x1c` bit0. **[C]**

`isp_ife_wdma_wrapper_update` (`0x15ec0`) — the **per-frame buffer programming**:
computes the partition address offset (`ax_drv_calc_ife_wdma_partion_addr_offset`,
`15f7c`), then `set_parameter(chn, type = 6, addr)` — `15fd4: mov w3,#6` / `16018: blr x5`
(whole-frame variant at `160dc: mov w3,#6` / `160e0: blr x5`)
→ `0x18*chn + 0x14 = addr >> 3`. **[C]**

### 2.5 SIF arm order (`ax_isp_sif_sns_start`, `0x27b8`)

For `dev == 0` the exact write order is: **[C]**

| # | reg | operation | citation |
|---|---|---|---|
| 1 | `0x6500` | low byte: `bits[2:0] ← 0` (`296c: and w3,w2,#0xfffffff8`, `2974: bfxil`) | `295c`–`2978` |
| 2 | `0x6504` | ← `0` | `2984`–`2994` |
| 3 | `0x6408` | `new = (old & 0xfffcfff8) \| (((1<<dev) & 3) << 16)` — `2804: ubfiz w2,w20,#16,#2`, `2808: movk w23,#0xfffc,lsl#16` | `27f0`–`281c` |
| 4 | **`0x6404`** | `new = (old & 0xfffcfff8) \| ((1<<dev) & 7)` — **the start strobe** | `2824`–`2840` |
| 5 | `0x6510` | read only, to detect TPG mode (`w0 & 7 == 1`) | `28d8`–`28f0` |
| 6 | `0x6500` | low byte: `bits[2:0] ← 1` | `28f4`–`2914` |
| 7 | `0x6504` | ← `dev + 1` (as u16) | `2918`–`2930` |
| 8 | if TPG: `ax_isp_sif_tpg_start` (writes `0x6000`) | | `293c` |

For `dev == 1` the analogous pair is `0x6580` / `0x6584` with the mode probe at `0x6590`
(`29dc`–`2a34`); for `dev == 2`, `0x6600` / `0x6604` with the probe at `0x6610` (`2864`–`28a4`).
Caller: `vin_dev_node_start` (`0xba650`, call at `ba684`). **[C]**

### 2.6 Interrupt block (base 0, groups n = 0…9)

* mask/enable: `0x10 + 0x10*n` — `ax_isp_int_mask_set` ORs bits in (`b8f0`),
  `ax_isp_int_unmask_set` BICs them (`b9b4`). So **1 = masked**. **[C]**
* W1C clear: `0x14 + 0x10*n` — `ax_isp_int_clear_set` (`b818`/`b830`);
  `ax_isp_ife_int_clr` (`0xb4b0`) writes `0xffffffff` to `0x14, 0x24 … 0xa4` (`b4e0`, loop `b4e8`). **[C]**
* raw: `0x18 + 0x10*n`; masked status: `0x1c + 0x10*n`. **[I — from the group stride,
  consistent with the observed `+0x28` (grp1 raw), `+0x58` (grp4 raw), `+0x68` (grp5 raw)]**
* `ax_isp_ife_int_reset` (`0xb340`) zeroes `0x10, 0x20 … 0xa0` (`b368`, loop `b36c`). **[C]**
* Second bank for ITP is `0x80010 + 0x10*n`, YUV `0xc0010 + 0x10*n`
  (`ax_isp_itp_int_reset` `b3b0`, `ax_isp_yuv_int_reset` `b3f8`; `ax_isp_int_unmask_set`
  adds `#0x80,lsl#12` / `#0xc0,lsl#12` at `ba30` / `b9f8`). **[C]**

---

## 3. The per-frame path

### 3.1 Frame-start (SOF)

`__vin_pipe_sns_fsof_irq_exec_node` (bypass copy at **`0x7a838`**) does **no direct
register I/O**. It: **[C]**
* accumulates a node-ready bitmap in driver RAM (`7a8d0`–`7a8e4`: `ldr w2,[x21,#3640]`,
  `orr`, `str w1,[x21,#3640]`) and bails out unless every expected node has reported
  (`7a8e8: bics wzr, w0, w1`);
* then walks the node list twice, invoking `node->ops[+0xa8]` (`7a984`/`7a990`) and
  `node->ops[+0xb0]` (`7aa10`/`7aa1c`) per node — the "forward"/"backward" hooks that
  hand buffers between nodes.

The SIF-side FSOF waiters `__ax_its_dev_wait_sif_l_fsof_irq_event` (`0x7d8e0`),
`_s_` (`0x7d900`), `_vs_` (`0x7d920`) are 8-instruction wait stubs — no register I/O. **[C]**

### 3.2 WDMA frame-done

`__vin_ife_wdma_done_irq_exec_node` (bypass copy at **`0x7aea0`**) is likewise a
buffer/FIO bookkeeping node; the register-touching work it dispatches to is the
wrapper `update` + `trigger` pair below. **[C]**

### 3.3 The actual per-frame register writes

Exactly **three** register writes per frame, all to `ife_wdma`: **[C]**

1. **`isp_ife_wdma_wrapper_update`** → `set_parameter(type 6)` →
   `0x14000 + 0x18*chn + 0x14  =  (dma_addr >> 3)`  (chn 8 → **0x140d4**).
2. **`isp_ife_wdma_wrapper_trigger`** (`0x151a0`) → `hw->shadow` (slot `+0x50`), called at
   `152cc` with `(blk, chn, ptr, mode = w22, seq = w4)`; `seq` is a per-channel counter
   read and post-incremented at `152b8` / `15384`–`15394` (`ldr w4,[x21,#100]`,
   `add w1,w4,#1`, `str w1,[x21,#100]`). Inside `ife_wdma_shadow`:
   * `0x14000 + 0x18*chn + 0x10  =  seq & 0xffff`   (chn 8 → **0x140d0**, low half only);
   * `0x14000 + 0x18*chn + 0x0c  |= 1`               (chn 8 → **0x140cc**) —
     or `&= ~1` when `mode == 0xe` (`4f88`/`4fc0`/`4fc4`), which is the stop case
     (`isp_ife_wdma_wrapper_trigger+0x6c` sets `w22 = 0xe` at `1520c`).

**This is the shadow-load strobe.** The register at `0x140d0` is written by software in
its **low 16 bits only**; the vendor's observed value `0x1e2d1e2d` is the same 16-bit
token appearing in both halves, i.e. the upper half is a **hardware-latched copy taken
when the shadow is loaded**. **[I — high confidence; the `and #0xffff` at `4f74` proves
software never writes the upper half, and the value is a frame sequence counter]**
An upper half stuck at 0 therefore means *the shadow has never been loaded*.

### 3.4 CDMA / cmdbuf

`ax_regio_pipe_trigger` (`0x37da0`) resolves a slave and calls
`ax_regio_slave_trigger` (`37e18`, an `ax_base` export) — it writes **no ISP register
itself**. `ax_regio_blk_io_write_shadow_cmdbuf` (`0x3cdb0`) finds the block
(`3cdec`) and dispatches to `blk[0xd0]->[8]->[0x80]` (`3ce04`/`3ce1c`) — again all inside
`ax_base`, and, per §0.1, **no IFE code path ever calls it**. **[C]**

Therefore: **there is no per-frame "commit" that a plain-CPU replay would miss other
than the `0x140cc` shadow strobe in §3.3.** **[C]** for the cmdbuf claim,
**[I]** for the completeness claim.

---

## 4. Writes a register-file snapshot cannot contain

### (a) Outside the 0x02400000 file

| register | what | citation |
|---|---|---|
| `0x02500000 + 0xd0 / 0xd4` | ISP clock enable set / clear | `ax_isp_clk_eb_set` / `_clr` via `ISP_DRV_IO_RST_WRITE32` |
| `0x02500000 + 0xd8 / 0xdc` | second clock enable set / clear | `ax_isp_clk_eb_set` / `_clr` |
| `0x02500000 + 0xe0 / 0xe4` | reset bank 0 set / clear | `ax_isp_clk_rst0_set_all` |
| `0x02500000 + 0xe8 / 0xec` | reset bank 1 set / clear | `ax_isp_clk_rst1_set_all` |
| `0x02500000 + 0x90 / 0x94` (write), `+0x98 / 0x9c` (read) | `ax_isp_sys_glb_init`, `…_lock_time` | via `ISP_DRV_IO_GLB_*` |
| `h[0x18] + 0x28` | `ax_isp_common_isp_mm_set` | `ISP_DRV_IO_COM_GLB_WRITE32` |

All of these are pure set/clear strobe pairs — **none of them read back**. **[C]**

### (b) Inside the file, but not readable-as-written

| register | why | citation |
|---|---|---|
| **`0x14000 + 0x18*chn + 0x0c`** (chn8 = **0x140cc**) | shadow-load strobe; RMW-`orr #1` per frame | `ife_wdma_shadow` `4f54`/`4f94`/`4fa4` |
| **`0x146e0`** | written with `0xffffffff`, read discarded — strobe/clear-all shape | `ife_wdma_set_parameter` `54b0`–`54c4` |
| **`0x0170` / `0x0174`** | mux enable / disable; W1S/W1C into the `0x16c` mirror **[I]** | `11d2c` / `11d84`, only callers `27294` / `272a4` |
| **`0x0154` / `0x0158`** | bypass SET / CLR; effect appears in `0x150` | `11bb4` / `11c3c` |
| `0x14 + 0x10*n` (n = 0…9) | interrupt W1C | `b4e0`/`b830` |
| `0x0004` (`dummy_en`) | only ever read by this module; if anything sets it, it is `ax_base`'s default-register list | `12900` |
| `0x4000 – 0x411f` (`ife_hsk`, 72 regs) | **no code in `ax_proton` writes this block at all** — it is programmed only by the `ax_base` regio default-register list at block create/enable. Its read-back behaviour is unknown. **[I]** | block table entry id 2 |

### (c) Read-only status registers — *not* configuration (important negative results)

| register | what it is | citation |
|---|---|---|
| **`0x01bc` / `0x01c0`** | dev-0 frame PTS, **low / high 32 bits of a free-running 64-bit timestamp**. `0x01c4` / `0x01c8` are dev-1's. | `ax_ife_top_get_pts` `11e58`/`11e60`/`11ed0`; `ax_ife_top_glb_get_pts` `127c4`–`127dc` (`low = 0x1bc + 8*dev`, `high = 0x1c0 + 8*dev`) |
| `0x0188` | AXI status | `128e4` |
| `0x14704`, `0x14710`, `0x14724` | never written by any code in the module (exhaustive scan of all `ax_regio_blk_io_write` / `ISP_DRV_IO_WRITE32` call sites) → WDMA status/counters | — |
| `0x1018`, `0x105c` | likewise never written by `ax_proton`, and outside every `ife_*` regio window (`ife_top` ends at `0x223`); `ax_mipi_rx.ko` does not touch them either | — |

> **Red herring resolved:** the reported "`0x1c0` reads 3, vendor 4" is **not a missing
> configuration write** — `0x1c0` is the *upper word of the frame timestamp counter*.
> Any two boots will differ. **[C]**
>
> By the same argument `0x1018`/`0x105c`/`0x14704`/`0x14724` are almost certainly
> *symptoms* (status registers that only become non-zero once the core actually
> processes a frame), not causes. **[I]**

### (d) Time-ordered relative to SIF start

* `0x146dc` go-bit and `0x146e0` flush happen inside `set_parameter` type 0, i.e. during
  **setup**, *before* the type-1 geometry writes and long before the SIF start. **[C]**
* `chn_enable` (`0x140dc` bit0) happens in `wrapper_enable`, after setup. **[C]**
* The **`0x140cc` shadow strobe and the `0x140d4` address are re-issued for every
  frame**, i.e. at least once after the SIF is armed and thereafter on every WDMA
  done IRQ. **[C]** A one-shot static replay that never re-issues them will program
  at most the first buffer and never load it.
* The SIF start strobe `0x6404` (§2.5 step 4) is the last thing in the arm order and
  is preceded by `0x6408`. **[C]**

---

## 5. Most likely missing element — ranked

### #1 — The WDMA shadow-load strobe is at `0x140cc`, not `0x140d8`

The register triple for channel 8 is
`0x140cc` (**trigger**), `0x140d0` (**shadow value, low 16 bits**),
`0x140d4` (address >> 3), `0x140d8` (control word from `set_parameter` type 0),
`0x140dc` (channel enable). Derived from `0x18*chn + {0x0c, 0x10, 0x14, 0x18, 0x1c}`
at `ife_wdma_shadow` `4f50`/`4f54`, `ife_wdma_set_parameter` `52b4`–`52e0` and `53b8`–`53cc`,
`ife_wdma_chn_enable` `507c`. **[C]**

The prior working note describes "`+0x18` shadow/commit" — i.e. `0x140d8` — which is
**the per-channel control word**, not the commit. The commit bit0 lives one word pair
lower, at **`0x140cc`**. If the driver has been pulsing `0x140d8` bit0, it has never
issued a shadow load, which exactly explains the upper half of `0x140d0` staying 0
while the low half takes `0x1e2d`.

**Try, in order (as a single sequence, then repeat step 3 once per source frame):**
```
1.  w32(0x140d4, buffer_phys >> 3)          # address
2.  w32(0x140d0, (r32(0x140d0) & 0xffff0000) | (seq & 0xffff))   # 16-bit token
3.  w32(0x140cc, r32(0x140cc) | 1)          # SHADOW LOAD  <-- the missing strobe
4.  read back 0x140d0: upper half should now equal seq
```
Also re-run the full type-0 tail while you are there:
```
5.  w32(0x146dc, (r32(0x146dc) & 0x0000f81c) | 1)
6.  w32(0x146e0, 0xffffffff)
```
(Note step 5's mask: it *clears* bits 0,1,5–10 and 16–31 — a straight `|= 1` on the
snapshot value is **not** what the vendor does.)

### #2 — The IFE data-source mux was never *enabled*, only mirrored

`0x16c` is the mirror; `0x170` (enable) and `0x174` (disable) are the write-only
set/clear pair, and they are the **only** ones the vendor ever writes
(`isp_ife_top_mod_wrapper_update` `27294` / `272a4`; `ax_ife_top_data_source_mux_set`,
the sole writer of `0x16c`, has zero callers). **[C]** for the call analysis,
**[I]** for the W1S/W1C nature.

**Try:**
```
1.  m = snapshot_value_of(0x16c)     # the vendor's mirrored mux state
2.  w32(0x170, m)                    # W1S: enable exactly those sources
3.  w32(0x174, ~m)                   # W1C: disable the rest  (optional, do it second)
4.  read back 0x16c and compare with the vendor snapshot
```
If `0x16c` does not move, `0x170`/`0x174` are not W1S/W1C and this candidate is dead;
if it does move, the mux was the wall. While testing also re-issue the top-gate pair in
the vendor's order — `0x154` **first**, then `0x158`:
```
5.  w32(0x154, vendor_0x154_value)   # set-bypass word (accumulated mask)
6.  w32(0x158, 0x8007)               # clear-bypass word
```

### #3 — The `ife_hsk` block at `0x4000–0x411f` is unprogrammed

`ax_proton` contains **no writer at all** for the `ife_hsk` block (id 2, base `0x4000`,
72 registers) — it is filled in only by `ax_base`'s regio default-register list when the
block is created/enabled (`isp_drv_wrapper_regio_enable` → `ax_regio_blk_enable`,
`13268`). **[C]** "HSK" is the SIF↔IFE handshake; a stalled handshake is exactly
consistent with "SIF counts frames, IFE core never processes one".

**Try:**
```
1.  Diff the 0x02404000..0x0240411f window against the vendor snapshot word by word,
    including words that read 0 in the vendor snapshot.
2.  Replay all 72 words (0x4000..0x411c) unconditionally, zeros included, then
    re-issue the sequence from candidate #1.
3.  If nothing reads back, the block is write-only RAM and must be reconstructed from
    ax_base's default table rather than from a snapshot.
```

### Explicitly ruled out by this analysis

* **Any CDMA/cmdbuf-only write.** The IFE path uses zero CDMA write primitives (§0.1). **[C]**
* **A missing bypass-mask write.** The mask arithmetic in
  `isp_ife_top_mod_wrapper_setup` + the bit table in `ife_top_bypass_get_module_id`
  reproduces the observed `0x150 == 0xffff7ff8` exactly. **[C]**
* **`0x1c0` (and by extension the other never-written words).** `0x1c0` is the high
  half of the frame PTS counter, not configuration. **[C]**
