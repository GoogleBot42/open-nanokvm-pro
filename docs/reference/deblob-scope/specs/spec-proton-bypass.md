<!--
Clean-room behavioral spec produced under epic #55 (issue #58b) — the M2 gate.
Written by a DESCRIBING subagent (+4 nested opus describing sub-agents for
SIF/IRQ/selectors/clk-rst) from ax_proton.ko disassembly; no vendor code copied.
Main-session verified against disassembly 2026-08-30:
 - WDMA address gate (§3): ife_wdma_set_parameter selector 6 confirmed —
   `lsr w3,w21,#3` (phys>>3) feeds ax_regio_blk_io_write at 0x52d8. Solid.
 - mc20e reset bin NEVER read (§7): proton imports AX_OSAL_FS_filp_{open,write,
   close} but NO read primitive (no filp_read/kernel_read/vfs_read). The bin is a
   snapshot WRITE target, not a seed. This OVERTURNS an earlier main-session guess
   (that the 868360 B = 0xD4008 size match implied a load) — the size match was
   coincidence (it's a full register-image dump the vendor tooling writes out).
Cross-confirmation: this spec and spec-cdma.md independently conclude the CDMA
queue engine is optional and plain ordered writel() + explicit polls reproduce
the config. UNVERIFIED (device checklist §9): WDMA block absolute base, MODE10
bypass bitmask @0x154/0x158, frame-done bit index (bit9 inferred) + SPI 27-vs-28,
YUV422 plane->channel map, whether nr56/74/89 selectors are droppable.
-->

# Behavioral spec — ax_proton.ko BYPASS + IFE-WDMA capture subset (#58b)

Clean-room behavioral specification for an open VIN/IFE capture video-node driver.
Target path only: `AX620E_TOP_NODE_MODE10` ("BYPASS PPL, only IFE WDMA working")
+ `IFE_NODE_MODE3` ("Whole frame, IFE_IN_ONELINE(YUV)->IFE_OUT_OFFLINE(DUMP)"),
digital YUV422-8 over MIPI CSI-2 → DDR, stride==width, zero ISP processing.

All offsets/bitfields read from disassembly of ax_proton.ko (ET_REL aarch64,
unstripped). Every claim cites function + register. `[speculative]` marks inference.

Naming: register accesses are `(regio-block, byte-offset)` pairs; the absolute
MMIO address = `block_base + offset`, where `block_base` is a sub-range inside the
0x02400000 ISP/VIN register file (len 0xd4008) assigned when the block is
registered. The open driver reproduces `readl/writel(block_base + offset)`.

---

## 0. Register-access model (how proton programs every register)

### 0.1 The regio-block primitive
All register I/O goes through `ax_regio_blk_io_write(blk, descr, offset_w2, value_w3)`
and `ax_regio_blk_io_read(blk, descr, offset)` (defined at 0x3bff0 / 0x3d378).

`ax_regio_blk_io_write` internals (0x3bff0):
- `blk+0x84` = block size in bytes; offset (w2) is bounds-checked `< size` (else
  "reg out of range" printk + dump_stack, write dropped).
- `blk+0xd0` = a cdma-wrapper/"mode" object. Its fn-ptr at `[[blk+0xd0]+0x8]+0x60]`
  is called as a predicate `pred(this=[blk+0xd0])`:
  - predicate returns 0  → **DIRECT path**: `*(u32*)(blk+0xc0 + offset) = value`
    (blk+0xc0 is the register target = ioremapped MMIO base of the block).
  - predicate returns !=0 → **CDMA path**: the write is appended into a CDMA
    command buffer instead (batched; see 0.2).
- RMW is done in the caller: read-modify-write pattern is explicit
  (`io_read` → mask/or in caller → `io_write`), NOT a hardware RMW.

**Driver implication:** For the open driver, every `ax_regio_blk_io_write(blk,
d, off, val)` == `writel(val, block_base + off)`; every `io_read` == `readl`.
The CDMA batching is an atomicity/perf optimization (multi-register frame updates
committed together), **not a hardware requirement** — direct writel to the same
offsets reproduces the config. The only ordering rule that matters (see §4): set
enable/shadow-commit bits LAST.

### 0.2 CDMA-batched commit (the vendor's atomic path)
Register writes accumulated during config are flushed to hardware by a pipe-level
sequence seen in `vin_bypass_pipe_start` (0x797c0), in order:
`ax_regio_pipe_switch_mod → ax_regio_pipe_sync_user → ax_regio_pipe_update_slave
→ ax_regio_pipe_trigger`. `trigger` hands a CDMA descriptor to ax_base's engine
(`ax_base_cdma_add_virtual_queue`/`_trigger`) which replays the register writes
into the ISP file. The CDMA opcode set (from isp_cdma_kern_comm_io_write family):
plain write, `_and`/`_or` (RMW), and `_polling_eq/ge/le` (poll-until a reg matches
before continuing). An open driver can ignore CDMA and do ordered MMIO + explicit
poll loops.

---

## 2. IFE-top bypass mode (MODE10 / MODE3)  [item 2]

Configured by `isp_ife_top_mod_wrapper_setup` (0x26db8) via helpers:
- `ax_ife_top_module_bypass_set_cfg_set` (0x11b90): **full 32-bit write of a
  per-module bypass bitmask to IFE-top register offset 0x154.**
- `ax_ife_top_module_bypass_clr_cfg_set` (0x11c18): paired mask, **offset 0x158.**
- `_get` variants read 0x154 / 0x158.

Semantics: reg 0x154 (block = IFE-top) is a bitmask where each bit bypasses one
pixel-pipeline module; reg 0x158 is the paired clear/complement mask. MODE10
("BYPASS PPL, only IFE WDMA") sets all pipeline-module bits so pixel data flows
IFE-input → WDMA untouched. The exact MODE10 constant is data-driven (a per-mode
config struct consumed by isp_ife_top_mod_wrapper_setup) — **capture the live
value by device trace** (read IFE-top+0x154/0x158 after a vendor bring-up); see §9.

A separate global IFE enable/mode bit is asserted from the WDMA geometry path:
direct MMIO RMW at **absolute file offset 0x146dc** (`ISP_DRV_IO_WRITE32`, in
`ife_wdma_set_parameter` selector 3): keep mask 0x0000f81c, set bit0. This is the
"IFE core go / input-mode" register [speculative: exact field]. Read live to confirm.

---

## 3. IFE-WDMA buffer-address programming  [item 3 — THE GATE]

The low-level programmer is `ife_wdma_set_parameter(blk_x0, index_w1, descr_x2,
selector_w3, param_x4)` (0x5138), a `switch(selector)` where each selector writes a
different WDMA register group. `index` = WDMA channel/plane. Two register banks:

- **Per-channel control bank, stride 0x18 (24 bytes)**, base = `0x18*index`:
  - `+0x14`: **WDMA output buffer BASE ADDRESS**, value = `phys_addr >> 3`
    (selector 6: `ldr x21,[param+0x8]; lsr w3,w21,#3; io_write(0x18*index+0x14, w3)`
    at 0x52ac–0x52d8). i.e. register holds phys[34:3], 8-byte-aligned.
  - `+0x1c`: **channel enable**, bit0 (RMW) — `ife_wdma_chn_enable` (0x5048):
    offset `0x18*chn + 0x1c`, `bfxil` bit0 = enable.
- **Per-channel format/geometry bank, stride 0x20**, base = `(index+0xf)<<5`
  (selector 3, 0x5300+): `+0x1c` low3 = format-code, `+0x18` low4, `+0x10` low16 =
  `param[0x40]`, `+0x14` = `param[0x44]`.
- Word-indexed config regs: selector 8 → `(param[1]+0x14a)<<2`; selector 0xa →
  `(3*index + param[0x10] + 0x188)<<2` value `(param[8]<<1|1)|(param[4]<<16)`.
- Packing/burst + WxH: selector 2 (0x575c) → `0x18*index+0x3e8` (bitfield pack of
  param[2..8], keep-mask 0xfffc8880) and `+0x3ec` = width|height (`bfi ...#16,#16`).

### 3.1 Physical address resolution (vb2 substitution point)
`isp_ife_wdma_wrapper_update` (0x15ed8):
- arg1 (`x22`) = a buffer descriptor. `[desc+0x20]` = **buffer base DDR phys addr**;
  `[desc+0x1c]` = buffer length (stored into the buf ctx at +0x8, 0x16184).
- `ax_drv_calc_ife_wdma_partion_addr_offset` (0xa4c88) computes a per-partition byte
  offset; final target = `[desc+0x20] + partition_offset` (0x15ffc–0x16004:
  `ldr w5,[x24]; add x1,[desc+0x20],x5`).
- For **whole-frame single partition (MODE3)**, offset = 0 → target == buffer base.
- The resolved address is placed in a config struct and handed to the ops callback
  `[[wrapper+8]+0x60]` (== `ife_wdma_set_parameter`) with **selector 6** → the
  `+0x14` addr register above. `wrapper+0x5d0` is the hw handle (regio block).

**Open-driver substitution:** put the vb2 buffer `dma_addr` into `desc+0x20`
(single partition, offset 0) and program `writel(dma_addr >> 3, wdma_block +
0x18*chn + 0x14)`. The opaque vendor pool (`ax_priv_pool_add` in
`vin_bypass_pipe_start`, backed by ax_pool_*/ax_cmm) only supplies that same phys
addr; vb2 replaces it directly. Multi-plane YUV422: program one channel per plane
(`__ife_wdma_get_chn_base`, 0x142c8, maps plane→bank id from table {0,6,3,9}).

### 3.2 Double-buffer / shadow commit
`ife_wdma_shadow` (0x4f18): writes a shadow value (low16) then RMW **sets bit0** of
a per-channel shadow/commit register (offset `0x18*chn + 0x18` region), UNLESS the
descriptor selector w22==0xe which **clears bit0**. bit0 = "latch newly-written
params (incl. buffer addr) at next frame boundary". Per-frame flow: write new
addr (selector 6) → set shadow bit0 → hardware consumes at next VSYNC.

---

## 4. Bring-up register ORDER  [item 4]

### 4.1 High-level pipe start (`vin_bypass_pipe_start`, 0x797c0), in order:
1. `vin_pipe_common_fios_link` — link scheduler nodes.
2. `ax_sys_get_mem_param` + `ax_priv_pool_add` — buffer pool (vb2 replaces).
3. Commit accumulated register program: `ax_regio_pipe_switch_mod` →
   `ax_regio_pipe_sync_user` → `ax_regio_pipe_update_slave` → `ax_regio_pipe_trigger`.
4. `vin_pipe_common_params_set`.
5. `ax_regio_pipe_mem_init`.
6. `vin_pipe_common_register_hw_to_scheduler` — arm per-frame update + frame-done.

### 4.2 Per-channel WDMA enable order (`isp_ife_wdma_wrapper_enable`, 0x14370):
For each channel, calls ops `+0x60` (set_parameter) with selectors in this order,
then ops `+0x68` (shadow/commit):
1. **selector 8** — mode/format word reg `(param[1]+0x14a)<<2`.
2. **selector 6** — buffer base address (`0x18*chn+0x14`, addr>>3).
3. **selector 2** — packing/burst + width/height (`0x18*chn+0x3e8/+0x3ec`).
4. ops `+0x68` shadow-commit (selectors 0x101 / 0xf / 0xffffffff) — latch.
Channel enable bit (`+0x1c` bit0) and shadow bit set LAST.

### 4.3 RMW vs plain-write vs poll
- Plain 32-bit writes: buffer addr (sel 6), bypass masks (0x154/0x158), width/height.
- RMW (read→mask→or→write): format bits, enable bits, shadow bit0, IFE-go 0x146dc.
- Poll-until: only in CDMA path (`_polling_eq/ge/le`); open driver adds explicit
  poll loops where the vendor used them (candidates: reset-done, see §8/§9).

---

## 1. SIF front-end config  [item 1]

Full detail + 17-step recipe: `scratchpad/work/sub-sif.md`. Verified spot-checks:
`ax_isp_sif_sns_start` writes STOP@0x6408 then START@0x6404 (`[2:0]=(1<<dev)&7`) —
confirmed. Absolute base confirmed via `ax_regio_setup` (@0x36c98) slot map:

| slot | phys base | len | accessor |
|---|---|---|---|
| 0 | 0x02400000 | 0xd4008 | ISP_DRV_IO_{READ,WRITE}32 (all SIF + IFE + WDMA regs) |
| 1 | 0x02500000 | 0x2000 | ISP_DRV_IO_GLB_* |
| 2 | 0x02500000+0x100 | 0x100 | ISP_DRV_IO_RST_* (soft reset) |
| 3 | 0x02340000 | 0x100 | ISP_DRV_IO_COM_GLB_* (shared w/ mipi_rx) |

**`isp_sif_mipi_yuv_sns_setup` is inlined into `ax_isp_sif_sns_setup` (@0x2cc0),
gated by `attr.interface_type==1`.** All SIF regs are RMW (read/clear-field/or/write).

### 1.1 SIF register map (absolute = 0x02400000 + off)
- SIF top @ 0x6400: **0x6404 START** (`[2:0]=1<<dev_id` — the bit that begins
  capture), **0x6408 STOP**, `0x640c+4n` VBUS_CTRL[n] (`[0]` en, `[8:4]` 5-bit mux,
  `[15:12]` shift-sel; preserve 0xFFFC0E0E).
- Per-device block @ **0x6500 + 0x80*dev_id** (dev0 0x6500): `+0x00` SIF_CTRL
  (`[2:0]` arm), `+0x04` SIF_ID (=dev_id+1), `+0x0c` frame-seq (RO), **`+0x10`
  SIF_IN_FMT** (YUV format), `+0x14/+0x18` WIN0 start/size, `+0x1c/+0x20` WIN1,
  `+0x24` MISC, `+0x3c` MIPI_CTRL (`[0]`=enable), `+0x40+8i`/`+0x44+8i` VC/DT match.

### 1.2 Format register SIF_IN_FMT (dev0 = 0x02406510)
`[2:0]` = format (0 RAW / 1 TPG / 2 YUV420 / **3 YUV422**), `[6:4]` = depth
(**0 = 8-bit**, 1 = 10-bit), `[16]/[17]/[19]` = yuv-select bits (from a pure table
on `attr.sns_out_mode`; for plain progressive: `[16]=1,[17]=1,[19]=0`), preserve
0xFFF48E88. Mapping from CSI-2 DT: 0x18/0x19→420, **0x1E/0x1F→422**; else rejected.
**⇒ YUV422-8 (DT 0x1E): write `(old & 0xFFF48E88) | 0x00030003`.**

### 1.3 Three plan-shaping facts
1. **No width/height/stride register in SIF.** Geometry = crop rect only:
   `WIN0_SIZE(+0x18) = (x_end-x_start) | ((y_end-y_start)<<16)`, plain subtraction
   (**no +1**; ends exclusive). For full-frame: WIN0_START=0, WIN0_SIZE=`W|(H<<16)`.
   Stride is an IFE-WDMA parameter (§3), not SIF.
2. **No "oneline" register in SIF.** That axis is on the WDMA side
   (`__isp_ife_wdma_whole_frame_setup` vs `..._partition_frame_setup`). For bypass,
   whole-frame WDMA setup is the one to run.
3. **SIF never sees LaneNum / DataRate** — those strings don't exist in ax_proton;
   D-PHY/lane/data-rate live entirely in **ax_mipi_rx.ko**. SIF only does VC + 6-bit
   CSI-2 data-type matching (`VC_DT_MATCH_A/B`). Single-channel "park" idiom:
   unused matcher gets DT 0x3A (never in real traffic) + WIN1_START=0x00200020.

### 1.4 Start/stop ordering (see sub-sif.md §6 for the full recipe)
setup (write IN_FMT, crop, VC/DT, MIPI_CTRL[0]=1) → `ax_isp_sif_sns_start`
(pre-clear CTRL/ID → STOP RMW → **START 0x6404 `[2:0]=1<<dev`** → re-arm CTRL/ID).
Note: START is asserted BEFORE the vbus is enabled at node level. Stop = STOP@0x6408
then a blunt 40ms sleep (no status poll; graceful-drain handshake lives in
`vin_sif_ife_wdma_slow_stop_*` @0x46b60 if clean stop is needed).

## 5. Frame-done / IRQ semantics  [item 5]

**VERDICT: a real per-frame frame-done IRQ exists AND is unmasked on the bypass
path. Polling (our current 5ms hrtimer replay) is our gap, not a hardware limit.**
Independently re-verified from disasm (see below) — high confidence.

### 5.1 VIN/ISP interrupt-controller register layout
Flat array of per-group interrupt registers, 0x10 stride. For group `n`
(verified in `ax_isp_int_mask_set` @0xb8d0 and `ax_isp_ife_int_clr` @0xb4c8):
- enable        = `0x10*n + 0x10`  (RMW: read / OR-in bit / write — `ax_isp_int_mask_set`)
- clear (W1C)   = `0x10*n + 0x14`  (write 0xffffffff to ack — `ax_isp_ife_int_clr` sweeps 0x14..0xa4)
- raw status    = `0x10*n + 0x18`
- masked status = `0x10*n + 0x1c`

Bank 0 (IFE/VIN) base = 0x02400000, 10 groups (n=0..9).
Bank 1 (ITP): base 0x02480000 for n≤7, 0x024C0000 for n≥8 (offset +0x80000 / +0xc0000
inside `ax_isp_int_mask_set`) — NOT on our path.

| event | enable | clear(W1C) | raw | masked-sts | bit |
|---|---|---|---|---|---|
| **IFE WDMA frame-done** (group 4) | 0x02400050 | 0x02400054 | 0x02400058 | 0x0240005C | `1<<(wdma_chn+1)` (bit 9 / 0x200 for dev0/non-HDR/single-plane) [confirm bit on device] |
| frame-start FSOF (group 1) | 0x02400020 | 0x02400024 | 0x02400028 | 0x0240002C | `1<<sof_idx` (bit0 for dev0) |

`0x10*n+0x10` is a true ENABLE (despite the `..._mask_set` name): the ISR computes
`pending = enable & raw_status` and skips groups whose enable==0.

### 5.2 IRQ flow (no polling)
- `__vin_int_handle` (@0x92190) is a plain hardirq (`request_threaded_irq` with
  `thread_fn=NULL`, name `ax_proton_intt`): masks the GIC line, snapshots all group
  statuses, acks via the `+0x14` clear regs, queues a record, wakes an RT kthread.
- kthread `__vin_irq_exec_thread` (@…) matches `pending[group] & node_mask`, calls
  `__vin_ife_wdma_done_irq_exec_node` (frame-done) / `…_fsof_…` (frame-start).
- `__vin_ife_wdma_done_irq_exec_node` accumulates per-plane done bits, then
  `wake_up_interruptible(pipe+0x11B0)`.
- Userspace blocks on that wait via `vin_bypass_pipe_interrupt_query` (blocking, opt
  timeout). `vin_bypass_pipe_irq_register` → `vin_irq_executor_add` (@0x91208) does
  **ack (`ax_isp_int_clear_set`) then enable (`ax_isp_int_mask_set`)** on group 4,
  bank 0 — verified: executor_add calls those two in that order.

### 5.3 hrtimer is a red herring
The only hrtimer users are the ISP job scheduler
(`vin_normal_scheduler_{create,destroy}`, `__vin_scheduler_trigger_task_proc`,
`vin_normal_scheduler_irq_notify_cb`) — a job-submission deadline *cancelled by* an
IRQ, not a frame-done sampler, and not on the bypass path.

### 5.4 Open-driver guidance
Request the bank-0 GIC line, in the ISR read group-4 masked status
(0x0240005C), ack via 0x02400054 (W1C), signal the vb2 buffer done. Enable the
frame-done bit at 0x02400050 during stream-on (ack first, then set the bit).
The open stack can drop the 5ms poll entirely.

### 5.5 Open item (device check)
`platform_get_irq(pdev, 0)` → bank 0, index 0; index 1 → bank 1. Mapping index 0
to SPI 27 vs 28 inferred from ascending DT order (board DTS not reachable in
workspace). On-device: `grep ax_proton_intt /proc/interrupts` (the line ticking at
frame rate is bank 0), and `devmem 0x02400050` while the vendor stack streams
(expect the frame-done bit set).

## 6. Four mandatory selectors nr56/74/54/89  [item 6]

ioctl surface: `ax_isp_fops+0x28 → ax_isp_ioctl` (@0x98368). Encoding
`_IOWR('p'=0x70, nr, 8)` → `cmd = 0xC0087000 | nr`. `ax_isp_ioctl` range-dispatches;
nr 0x22–0x61 → `isp_vin_pipe_ioctl` (compiled jump table at `.rodata+0xBB04`, base
`cmd-0xC0087023`, targets rel. `.text+0x98858`). All 63 entries decoded; ordering
(create/destroy/open/close/start/stop) + set/get pairing self-consistent (PROVEN).

| nr | cmd | handler | param id |
|---|---|---|---|
| 54 (0x36) | 0xC0087036 | `ax_vin_pipe_partition_info_set` | 5 |
| 56 (0x38) | 0xC0087038 | `ax_vin_pipe_black_level_set` | 0x0F |
| 74 (0x4A) | 0xC008704A | `ax_vin_pipe_scene_attr_set` | 1 |
| 89 (0x59) | 0xC0087059 | `ax_vin_pipe_npu_throttle_info_set` | 0x25 |
(also nr38=pipe_open, nr40=pipe_start, nr42=pipe_attr_set.)

**KEY FINDING — contradicts the "or the SoC hard-hangs at the register level"
premise: none of the four writes an MMIO register, and none touches clock/reset/
power.** Verified: `ax_vin_pipe_partition_info_set` (@0x89a90) does only
copy_from_user + memcpy + `ax_wrapper_vin_pipe_set_param` — zero `ax_regio_blk_io_*`,
zero clk/rst calls. All four funnel through `ax_wrapper_vin_pipe_set_param →
vin_pipe_common_params_set (vin_bypass_pipe+0x80)` → a per-param apply-callback that
deposits state into node software contexts. MMIO happens later, at node start
(`ife_wdma_set_parameter` et al). Clock-ungate / reset-deassert live behind the
**global create ioctl nr0** (`VIN_glb_create` → `ax_isp_clk_rst0/1_set`,
`ax_isp_reset_assert_isp_domain`), NOT these four — see §8.

What each deposits:
- **nr54 (partition_info)** — the only structurally load-bearing one. Calls
  `__vin_pipe_hsk_info_set(pipe+0x1178, param+0x18, sel)` (builds the OCM slice
  handshake descriptor table from frame width) and broadcasts sub-id 6 to all 16
  nodes → installs the pointer at `node[0xB8]+0x438`. Skipping it leaves that pointer
  NULL / slice-count 0 in every node — a **credible hang** at node start (the open
  driver MUST program the equivalent slice/partition descriptor for whole-frame).
- **nr56 (black_level)** — 4×u16 BLC into node arrays (IFE `node_ctx+0x250`). IQ
  only; no hang mechanism found. Likely droppable for a digital YUV source.
- **nr74 (scene_attr)** — 24-byte memcpy to `param_block+0xB8`. Pure state, no
  callback/broadcast. Likely droppable.
- **nr89 (npu_throttle)** — `pipe_ctx[0x1544]=-1` + 424-byte memcpy; consumed only
  by `__ax_isp_set_npu_throttle → vin_nnw_set_throttle` (NPU). Inert without AI-ISP.
  Droppable.

**Guidance:** the "exactly these four or hang" is most likely the vendor library's
unconditional call order, not four hardware requirements. The load-bearing content
is nr54's slice/partition handshake descriptor. Cheapest device test: issue nr54
alone, drop the other three. If still hangs, decode the per-param lifecycle
**state-mask table at `.rodata+0x6100`** (used by `ax_wrapper_vin_pipe_set_param`) —
the only remaining path by which nr56/74/89 could be mandatory. [needs device test]

## 7. mc20e_isp_reg_reset_value.bin  [item 7]

**VERDICT: NO — the bypass path does NOT read it. Definitive.** Verified: proton's
entire FS import set is `AX_OSAL_FS_filp_open/filp_write/filp_close` — **no
filp_read / kernel_read / vfs_read / request_firmware anywhere**. The module is
structurally incapable of reading the file.

The single xref to the path string (`.rodata.str1.8+0x50c0`, from
`__ax_regio_default_create` @0x368e8) is a **WRITER**: verified it calls
vmalloc(0xD4008) + memcpy(buf ← live 0x02400000 reg file) + `ax_isp_reset_all_legacy`
+ `filp_open(path, O_RDWR|O_CREAT|O_EXCL|O_LARGEFILE|O_NOFOLLOW, 0600)` +
`filp_write(buf, 0xD4008)`. It snapshots the live register file to disk write-once
(O_EXCL, first boot only), return value ignored. The in-memory "default register
image" it builds is memcpy'd from hardware, not the file — deleting the file
changes nothing.

**Open-driver action: implement nothing for this file.** Do not read it (vendor
doesn't), do not write it (kernel writing /opt/data is exactly what we're removing),
do not copy the .bin into the repo. If a defaults image is ever wanted it is
trivially re-derivable on-target with zero vendor material: run the reset sequence
(§8) and read back 0xD4008 bytes from 0x02400000 — behaviorally identical.

## 8. Clock / reset  [item 8]

Full detail: `scratchpad/work/sub-clkrst.md`. Verified: `ax_isp_clk_eb_set` writes
RST-slot offsets 0xD0/0xD8 (RMW). The clock/reset controller is **not** a separate
CMU — it is the low 0x100 of the **0x02500000** window (ax_regio_setup slot +0x10,
`ISP_DRV_IO_RST_*`). All offsets below relative to phys 0x02500000.

### 8.1 Register map (write-1-to-set / write-1-to-clear pairs; writing 0 = no-op)
| off | role |
|---|---|
| 0x00 | clock-mux read-back |
| 0xC8 / 0xCC | clock-source mux SET / CLEAR — 3-bit fields [10:8],[7:5],[4:2] |
| 0xD0 / 0xD4 | clock-gate group A SET / CLEAR, bits [5:0] |
| 0xD8 / 0xDC | clock-gate group B SET / CLEAR, bits [9:1] |
| 0xE0 / 0xE4 | reset group 0 ASSERT / DEASSERT, 32 bits |
| 0xE8 / 0xEC | reset group 1 ASSERT / DEASSERT, 23 bits |

The bit-matrix helpers (`ax_isp_clk_rst0_set(desc,idx,flag)`, `_rst1_set`,
`clk_eb_set`) are **exact identity maps**: `rst0_set(idx,flag)` writes `1<<idx` to
0xE4 (deassert), and if flag also `1<<idx` to 0xE0 first (assert→deassert pulse).
No PLL, no divider, nothing DataRate-dependent — only 3-bit source-mux selection
from fixed rate ladders. Probe-time rates (`ax_isp_clk_prepare` from `__ax_isp_probe`,
module-load time): domain0=416MHz, domain1=533.333MHz, domain2=297MHz. Sensor MCLK
divider (0x02340000+0x40/0x44) is sensor-side only — irrelevant for HDMI bypass.

### 8.2 Ordering vs MIPI-RX (FORCED — proton FIRST, then mipi_rx)
`ax_isp_reset_all_legacy` (@0x83ec8) pulses every group-0/1 reset, which includes
the MIPI/LVDS receive front-end (`isp_rst_rxhs0..7`, `isp_rst_lvds0..3`). Running it
after mipi_rx bring-up would tear down D-PHY/CSI state. Ownership:
- Resets 0xE0–0xEC: **proton owns exclusively** (mipi_rx never writes them).
- Clock gates 0xD0/0xD4: shared; proton enables a superset incl. bit1 (the D-PHY-RX
  ref clock mipi_rx also sets — harmless, W1S). Open driver: `0xD0|=0x3F`,`0xD8|=0x3FE`.
- 0x02340000 isp_sys_glb: mipi_rx's (VI clk select, D-PHY power, CSI-RX soft reset).

### 8.3 Bring-up sequence (from `VIN_glb_create` @0x84228; runs on the bypass path
via the nr0 global-create ioctl — NOT the four §6 selectors):
1. map 0x02500000; pulse reset-group-1 bit20 (`0xE8=0x00100000` then `0xEC=0x00100000`);
   program mux fields (clear via 0xCC, set level via 0xC8) domains 0/1/2.
2. ungate clocks: `0xD0=0x3F`, `0xD8=0x3FE`.
3. deassert all: `0xE4=0xFFFFFFFF`, `0xEC=0x006FFFFF` (bits 0..22 except 20).
4. AXI quiesce (`ax_isp_axi_busy_check_legacy`), then per-index reset pulse; hold
   `0x0440306C=2` around the group-1 loop, `=0` after.
5. zero the three top-level AXI ctrl regs (IFE/ITP/YUV top).
6. **then** MIPI-RX/D-PHY bring-up (ax_mipi_rx territory).

Clocks are ungated BEFORE resets released — preserve that order.

### 8.4 Reset-bit names (for reference; [speculative] id→bit mapping, from the DEAD
DT-reset table `vin_reset_mapping_tbl` .data+0x46f0 — the DT reset-controller path
`ax_isp_reset_init`/`ax_isp_reset_assert_isp_domain` is DEAD CODE, no callers, the
shipping driver uses raw-MMIO `*_legacy` only): group-0 bits — 0/1 ife_off/ife_core,
2..9 ife_pipe0..7, 10 axim, 11/12 bt0/bt1, 13 itp_core, 14 its, 15 ofl, 16 rosc,
17 yuv, 18..21 lvds0..3, 22 rgb_core, 23..30 rxhs0..7. Confirm on device before
relying on individual names.

---

## 9. Hardware-verification checklist (device register traces)
Run on the live device during a *vendor* bring-up (kvmcomm path) at a known
geometry, then during our open capture, and diff:

1. **WDMA block base:** find absolute address of `wdma_block` — trace the write of
   `dma_addr>>3`. Probe: dump 0x02400000..+0xd4008 before/after a QBUF; the word
   that equals `(buffer_phys>>3)` locates `wdma_block + 0x18*chn + 0x14`. Confirms
   §3 offset and the absolute base.
2. **Buffer-addr register:** with two queued buffers, confirm the `+0x14` word
   toggles between `phys0>>3` and `phys1>>3` each frame; confirms addr>>3 encoding
   + double-buffering (§3.2).
3. **Shadow bit:** watch `+0x18` bit0 pulse per frame (set by driver, cleared by hw).
4. **IFE-top bypass masks:** read IFE-top `+0x154` and `+0x158` after vendor MODE10
   bring-up → record the exact MODE10 bitmask constant (§2). Re-derive, don't copy.
5. **IFE-go reg:** read absolute file offset 0x146dc; confirm bit0=1 while streaming.
6. **Frame-done IRQ (§5):** `grep ax_proton_intt /proc/interrupts` — the line ticking
   at frame rate is bank-0 (resolves SPI 27 vs 28). `devmem 0x02400050` while the
   vendor stack streams → confirm the frame-done enable bit (expect bit9 / 0x200) and
   read 0x0240005C masked-status pulsing per frame. Count IRQs vs frames = 1:1.
7. **Geometry regs:** confirm width|height packed at `0x18*chn+0x3ec` (§3 sel 2)
   and `+0x10/+0x14` (sel 3) match the source resolution. Cross-check SIF crop
   `WIN0_SIZE` @ 0x02406518 = `W|(H<<16)` (§1.3).
8. **SIF format:** read 0x02406510 during vendor YUV422 capture → expect `[2:0]=3`,
   `[6:4]=0` (§1.2); read 0x02406404 bit for dev started (§1.4).
9. **Clock/reset:** read 0x025000D0/D8 (gates on), 0x025000E4/EC (resets deasserted)
   after vendor VIN-glb-create; confirm mux read-back at 0x02500000+0x00. Confirm
   reset-bit names by pulsing one bit of 0x025000E4 and observing (§8.4).
10. **Selectors:** issue nr54 alone (drop nr56/74/89) and check capture still starts
    (§6) — determines whether the other three are truly mandatory.

---

## Solid vs needs-device-trace

**SOLID (read from disasm, high confidence):**
- Register-access model + direct-vs-CDMA path (§0).
- WDMA buffer-address encoding: `writel(phys>>3, wdma_block+0x18*chn+0x14)` (§3) — THE GATE.
- Channel enable bit0 @ +0x1c; shadow-commit bit0 @ +0x18; double-buffer flow (§3.2).
- WDMA per-channel bring-up selector order 8→6→2→shadow (§4.2).
- IFE-top bypass mask register pair 0x154/0x158; IFE-go RMW @ abs 0x146dc (§2).
- Pipe-start high-level order (§4.1).
- **Frame-done IRQ (§5): a real IRQ exists and is unmasked in bypass — group-4
  int regs 0x02400050/54/58/5C; verified in ax_isp_int_mask_set/ife_int_clr/
  vin_irq_executor_add. Open driver can drop the 5ms poll.**
- **SIF front-end (§1): absolute base 0x02400000 confirmed via ax_regio_setup;
  START @0x6404, IN_FMT @0x6510 (YUV422-8 = `[2:0]=3,[6:4]=0`), crop-window geometry
  (no stride reg), VC/DT matching; verified ax_isp_sif_sns_start offsets.**
- **Four selectors (§6): nr→handler mapping PROVEN; none writes MMIO or touches
  clk/rst (verified nr54 handler) — they deposit software state; only nr54
  (partition/slice handshake) is structurally load-bearing.**
- **mc20e bin (§7): DEFINITIVELY not read — proton has no file-read primitive
  (verified import set); the one xref is a snapshot writer. Implement nothing.**
- **Clock/reset (§8): controller = low 0x100 of 0x02500000; W1S/W1C pairs
  0xD0/D8 (gates), 0xE0-EC (resets); identity bit maps; no PLL/no DataRate dep;
  proton-before-mipi_rx ordering forced. Verified clk_eb_set offsets.**

**NEEDS DEVICE TRACE (all one-line devmem/procfs checks; mechanisms are confirmed):**
- Absolute base of the WDMA regio block within 0x2400000 (checklist #1).
- The exact MODE10 bypass bitmask constant for 0x154/0x158 (checklist #4).
- Exact frame-done bit index within group 4 (bit9 inferred) + SPI 27-vs-28 mapping
  (checklist #6 / §5.5).
- Per-plane channel-index assignment for YUV422 (table {0,6,3,9} → which plane).
- Whether nr56/74/89 are truly mandatory or just vendor call-order (checklist #10).
- Reset-bit-name → bit-position mapping (§8.4, [speculative]).
