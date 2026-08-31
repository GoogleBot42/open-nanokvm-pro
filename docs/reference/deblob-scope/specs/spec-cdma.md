<!--
Clean-room behavioral spec produced under epic #55 (issue #58a). Written by a
DESCRIBING subagent from ax_base.ko disassembly (no vendor code copied); the
behavioral claims (register offsets, values, order) are a description of the
hardware/descriptor layout, not vendor source. Main-session verified against the
disassembly 2026-08-30: the EXT single-write sequence in
ax_base_cdma_cross_sys_reg_set was confirmed instruction-by-instruction —
ldr [+0x4c] (status), str 0xFFFFFFFF -> [+0x34], str 0x10001008 -> [+0x38],
str 0 -> [+0x44], matching §2b. Headline verdict (descriptor/queue engine is
OPTIONAL for bypass capture) accepted.
-->

# Behavioral spec: ax_base.ko CDMA (command-DMA) engine

Clean-room behavioral description of the AX630C "CDMA" command-DMA engine as
implemented by the vendor `ax_base.ko` (ET_REL aarch64, unstripped). All claims
cite the vendor function + instruction offset they were derived from; nothing
below is copied vendor code — it is a description of hardware register layout and
in-memory descriptor layout only.

Target file: `scratchpad/axp/ko/ax_base.ko`. Consumer cross-checked against
`ax_proton.ko` (`__ax_regio_slave_cdma_ext_ptn_upt` @ 0x38c40).

---

## 0. TL;DR verdict (read this first)

**CDMA's descriptor/virtual-queue engine is OPTIONAL for a bypass-YUV capture
driver.** The engine exists to batch and *frame-synchronize* large numbers of
ISP register/LUT updates (per-frame 3A tuning, "pattern"/shadow commit). A
bypass capture (MIPI RX -> IFE input -> WDMA-to-DRAM, configured once then left
streaming) performs *static* register setup with no per-frame shadow commit, so
it does not need the batching/atomic-commit machinery.

Two independent facts make the queue engine skippable:

1. **The same CDMA block exposes a trivial CPU-driven single-register poke port**
   ("EXT access", registers +0x34..+0x4c). It writes one arbitrary target
   register synchronously: set address, set data, pulse, poll-done. An open
   driver can reach any register behind the CDMA AXI master with ~6 writes + 1
   poll, *without* building descriptors, DRAM value-buffers, or a queue.
   (`ax_base_cdma_cross_sys_reg_set` @ 0x16c.)

2. **Peer IPs are programmed by direct CPU MMIO, not through CDMA.** `ax_mipi_rx.ko`
   and `ax_proton.ko` both import `AX_OSAL_DEV_ioremap` and write registers
   directly; MIPI RX config never touches CDMA. So at least part of the capture
   path is already plain `writel()`.

**Remaining risk (must be hardware-checked):** whether the *specific* IFE-input /
WDMA-output registers the bypass path needs are directly CPU-addressable, or sit
behind the CDMA AXI master (the "cross_sys" bridge). If the latter, the open
driver still does **not** need the queue engine — it uses the EXT single-write
sequence (path B below). Worst realistic case = a ~30-line register poke helper.
Best case (registers directly ioremappable) = plain `writel()`, CDMA ignored
entirely. See §6 for the on-device test that decides this.

---

## 1. Hardware topology

- OF compatible `axera,dma`; driver binds manually via `of_find_compatible_node`
  + `of_irq_get` (not a platform_driver). Has one IRQ. (established fact)
- **Two physical CDMA instances.** `cdma_get_hw_id` (@0xfe0) maps a caller
  "consumer/queue id" in range 0..9 onto instance 0 or 1 (id<=3 -> inst 0,
  else inst 1; ids >9 rejected). So up to 10 logical consumer channels multiplex
  onto 2 hardware engines. `AX_CDMA_HW_ID_MAX` bound is enforced everywhere.
- MMIO (established): `0x10034000` and `0x10038000` (len 0x20 each) are the two
  engine control blocks; `0x10460000` (len 0x200) is a shared/global block.
  `ax_base_sys_ioremap` (@0x20) ioremaps **3** regions per device (loop count 3,
  struct stride 0x28, size 0x1000 each; region phys at struct+0x10, resulting
  virt stored at struct+0x18).
- Per-instance software record: `g_cdma_hw_info` (`.data+0x4d0`, 128 bytes = 2 x
  64-byte entries; `ax_base_cdma_push` @0x12bc indexes it by `hwid*64`). Fields
  used: **+0x10 = virt base of that instance's command register block**;
  **+0x18 = software write-index byte** (compared against hw queue depth).
  Enable flags live at struct +0x8/+0x30/+0x58 (`ax_base_device_init` @0x300-308,
  one per ioremapped sub-region).

Everywhere below, "reg+0xNN" means an offset from the per-instance command
register base = `g_cdma_hw_info[hwid] + 0x10`.

---

## 2. CDMA hardware register map

Offsets are certain (read directly from the store/load displacements). Symbolic
names come from the module's own debug strings (`cdma_*_set`, `CMD_*`); the
binding of a given name to a given offset is [speculative] where noted, but the
*functional role* of each offset is certain from the code.

### 2a. Queue / batch submission path ("SYNC_TX")

| Off | Dir | Role (certain) | Likely name | Evidence |
|-----|-----|----------------|-------------|----------|
| 0x00 | W | **Command word 0** — target register address + control bits (layout §3) | CMD_INFO0 | push 0x137c; trigger 0x1930 |
| 0x04 | W | **Command word 1** — physical DRAM address of the value/pattern payload, shifted right by 3 (i.e. in 8-byte units), 30-bit field | CMD_INFO1 | push 0x13a4-0x13b8; group_push 0xfac-0xfb0 |
| 0x08 | W | **Opcode / kick.** 1 = enqueue the entry just written to 0x00/0x04; 2 = trigger/execute the whole queued batch; 4 = clear queue | CMD_CTRL0 | push 0x13ec (=1); trigger 0x1a1c (=2); clr 0x1c08 (=4) |
| 0x14 | W | **AXI hold control** — write 3 to request the engine quiesce its AXI master | — | axi_hold 0x1ca4 |
| 0x18 | R | **Queue occupancy status** — bits[15:1] = number of entries currently queued; hardware capacity = **32** entries | — | push 0x187c (ubfx #1,#15); group_push 0xe64-0xe6c (32 - level) |
| 0x20 | R | **AXI/engine busy status** — bit0 and bit5 both clear => AXI idle | — | axi_hold 0x1cc4 (tests bit0 | bit5) |
| 0x2c | R | **Completion / ready status** — bit0 = engine busy / not-ready (must be 0 before writing 0x00); bits[25:1] = a completion/level counter returned to callers | — | push 0x1358 (tbnz bit0); req 0x1548-0x154c (ubfx #1,#25) |

Arming + trigger handshake (from `ax_base_cdma_push` @0x11d8 and
`ax_mm_cdma_req_group_push_trigger` @0xe00):

1. Take `spin_lock_irqsave` (push 0x1350). Poll **reg+0x2c bit0**; if set, `udelay(5)`
   and retry up to **201** times (push 0x145c-0x1468). (group_push also pre-checks
   free space = `32 - (reg+0x18 bits[15:1])` >= entries-to-push, waiting up to
   201 iters — 0xe5c-0xe74.)
2. For each entry: write command-word0 -> **reg+0x00**, payload-addr>>3 ->
   **reg+0x04**, then **reg+0x08 = 1** (enqueue). (group_push loop 0xf94-0xfb4.)
3. After all entries queued: `udelay(10)` then **reg+0x08 = 2** (trigger).
   (group_push 0xfbc-0xfc8.)
4. Release spin lock.

**Completion is signaled by polling, not by the IRQ, on the submit side.**
`ax_base_cdma_req` (@0x14b0) is the "wait/trigger-by-id" call: it polls reg+0x2c
bit0 until clear (udelay 5 x up to 201), reads the bits[25:1] completion counter,
writes the consumer id into command-word0 bits[31:7] (`bfi w,#7,#25`, 0x1604) and
writes **reg+0x08 = 2** (0x163c) to kick, returning the counter to the caller.
The module has an IRQ + `ax_dma_handler` (@0x21a0) but that handler services the
separate 2D crop-DMA (§5), not the register-command queue — the command queue is
driven by CPU poll of reg+0x2c/reg+0x18. [The IRQ's exact role for the command
queue is unconfirmed; submit paths never rely on it.]

### 2b. External single-register access path ("EXT access" / SW bridge)

This is a CPU-programmed port that writes **one arbitrary register on the target
subsystem's bus** synchronously. `ax_base_cdma_cross_sys_reg_set(hwid, addr, val)`
@0x16c performs, in order (each is a 32-bit store to the offset shown):

| Off | Value written | Likely name | Evidence |
|-----|---------------|-------------|----------|
| 0x4c | (read first) — status; nonzero => busy/locked, abort with -1 | CMD_EXT_STA | 0x1b8-0x1d8 |
| 0x34 | 0xFFFFFFFF (byte-enable / write mask) | CMD_SYNC_TX_HEADER | 0x1f4 |
| 0x38 | 0x10001008 (fixed control constant) | CMD_SYNC_TX_CTRL | 0x208-0x21c |
| 0x44 | 0 (direction / write-enable) | CMD_EXT_WR | 0x24c |
| 0x3c | target register address | CMD_EXT_ADDR | 0x278 |
| 0x40 | value to write | CMD_EXT_WDATA | 0x2a4 |
| 0x48 | 1 (pulse => perform the access) | CMD_EXT_ACCESS_PULSE | 0x2d0 |

Debug strings also name `SW_ACCESS_ADDR` and `cdma_ext_wdata_set` /
`cdma_ext_addr_set` / `cdma_ext_access_pulse_set` / `cdma_ext_sta_get`,
confirming this is a software register-access bridge: *address + data + pulse +
poll-status*. This is the escape hatch that lets a driver poke any behind-the-
bridge register without the descriptor/queue engine.

### 2c. Debug + filter blocks (not needed for capture)

- `ax_base_cdma_debug_get_queue_info` @0x304: clears reg+0x58, writes a 16-bit
  queue/consumer id to **reg+0x54**, reads the result from **reg+0x5c** (0x350-0x378).
- `ax_base_cdma_filter_config` @0x1078 + strings `FILTER_CTRL0/FILTER_ADDR_L/
  FILTER_ADDR_H`: programs a 64-bit-address match "filter" (a write-snoop/trace
  trigger). Debug only.
- `ax_base_cdma_axi_hold`/`_axi_release` (@0x1c38 / 0x1dc8): quiesce/resume the
  AXI master around reconfiguration (reg+0x14 control, reg+0x20 status). Not
  needed for steady-state capture.
- `ax_base_cdma_clr` @0x1b20: reg+0x08 = 4 to flush a queue.

---

## 3. Descriptor / virtual-queue format (the crux)

The queue path consumes an in-DRAM array of **8-byte descriptors** (two 32-bit
words). `ax_base_cdma_add_virtual_queue` (@0xce8) builds one descriptor into a
caller-supplied buffer; `ax_mm_cdma_req_group_push_trigger` (@0xe00) streams such
descriptors word-for-word into reg+0x00/reg+0x04. `ax_base_cdma_push` (@0x11d8)
builds and submits an equivalent descriptor straight to the registers. The
consumer `__ax_regio_slave_cdma_ext_ptn_upt` (@0x38c40) builds the identical
layout inline in a per-pipe DRAM ring at `[pipe+0x720]`.

### 3a. `add_virtual_queue` input struct (what the caller fills)

`add_virtual_queue(x0=?, x1=queue_ctx, x2=cmd)`. Reads `cmd` (x2):

| cmd off | size | meaning | evidence |
|---------|------|---------|----------|
| +0x00 | u32 | **target register address** — must fit in 23 bits; top 9 bits (0xff800000) => -EINVAL | 0xce8-0xcf0 |
| +0x04 | u32 | **slot index** — which 8-byte descriptor slot to write (`*8`) | 0xcf4-0xd04 |
| +0x08 | u32 | **3-bit selector** (only low 3 bits used) -> word0 bits[6:4] | 0xd38-0xd3c |
| +0x0c | u8  | flag -> word0 bit1 | 0xd14-0xd18 |
| +0x0d | u8  | flag -> word0 bit2 | 0xd24-0xd28 |
| +0x0e | u8  | flag -> word0 bit31 | 0xd54-0xd60 |
| +0x18 | u64 | **payload physical address** of the value/pattern buffer -> word1 = addr>>3 | 0xd68-0xd74 |

`queue_ctx` (x1): the descriptor buffer base is at `[x1+0x10]`; slot address =
`[x1+0x10] + cmd.slot*8` (0xcfc-0xd04).

### 3b. Descriptor word 0 (offset +0x00 of the 8-byte slot / value at reg+0x00)

Bit-exact layout (from the bit-field inserts in add_virtual_queue 0xd08-0xd64,
confirmed identically in push 0x1360-0x137c and proton 0x38df8-0x38e0c):

```
bit0        = 1                     (valid / entry-present)
bit1        = flag (cmd+0x0c)       ["last" or sync flag]
bit2        = flag (cmd+0x0d)       [pattern/shadow-select flag]
bit3        = 1                     (constant)
bits[6:4]   = 3-bit selector (cmd+0x08)   [consumer / target-master id]
bits[30:7]  = 24-bit field holding the register address (source constrained to
              23 bits at the API boundary)
bit31       = flag (cmd+0x0e)       [pattern/mode flag]
```

In `ax_base_cdma_push` the low control nibble is built as the constant `0xd`
(bits 0,2,3 set) OR (flag<<1) OR (sel<<4), i.e. bit0=bit2=bit3=1 for a normal
"present" write entry (0x1364-0x1370).

### 3c. Descriptor word 1 (offset +0x04 of the slot / value at reg+0x04)

```
bits[29:0]  = (payload_physical_address >> 3)      // 8-byte-aligned, 33-bit reach
```
(add_virtual_queue 0xd68-0xd74; push 0x13a4; proton 0x38e24-0x38e30.)

**Key semantic:** word1 is a *pointer*, not an immediate value. The engine
DMA-fetches the register value(s)/pattern from that DRAM address and writes them
to the target register selected by word0. That is why simple single-register
writes go through the EXT path (§2b) instead — the descriptor path is for
value/pattern *buffers* (e.g. LUT / shadow-register uploads: proton function name
is `..._ext_ptn_upt` = "external pattern update", source buffer `[slave+0x508]`).

### 3d. How the 23-bit register address is composed (consumer side)

`__ax_regio_slave_cdma_ext_ptn_upt` builds cmd+0x00 as a hierarchical address
(0x38d10-0x38d6c), then masks to 23 bits:

```
bits[7:0]   = register offset within block   (slave+0x99)
bits[11:8]  = sub-block id                    (slave+0x9a, 4 bits)
bits[15:12] = pipe id                         (pipe+0x6b0, 4 bits)
bits[19:16] = sys/ISP id                      (pipe+0x6b4, 4 bits)
bits[22:20] = block/master id                 (cmdbuf[0], 3 bits)
```
So the "register address" the engine consumes is a routed {master, sys, pipe,
subblock, offset} tuple, not a raw AXI address. This confirms the engine is a
router into an internal ISP register fabric.

---

## 4. End-to-end programming model (what a consumer does)

Two distinct submission styles share the register block:

**Path A — batched descriptor queue (per-frame ISP tuning / LUT upload):**
1. Allocate a DRAM ring of 8-byte descriptors (vendor: `[pipe+0x720]`, capacity
   tracked at `[pipe+0x6e8]` write-idx vs `[pipe+0x6ec]` cap).
2. For each register/pattern write, build word0 (routed address + flags) and
   word1 (value-buffer phys >>3) — via `add_virtual_queue` or inline.
3. Submit with `ax_mm_cdma_req_group_push_trigger(array, start, end)`: waits for
   >= (end-start) free seats (reg+0x18), waits reg+0x2c bit0 clear, then for each
   descriptor writes reg+0x00, reg+0x04, reg+0x08=1; finally reg+0x08=2 to fire.
4. Optionally `ax_base_cdma_req(hwid, cons_id)` to trigger-by-consumer and read
   back the bits[25:1] completion counter (poll-based).

`ax_base_cdma_trigger(id, ctx)` (@0x1740) is a two-entry variant: it pushes one
data entry (reg+0x00/04, reg+0x08=1) and then a second "go" entry carrying the
queue id in word0 bits[31:7] with reg+0x08=2 — i.e. enqueue-then-trigger fused.

**Path B — external single-register write (static setup / one-off poke):**
`ax_base_cdma_cross_sys_reg_set(hwid, target_addr, value)` — the §2b sequence.
No DRAM buffer, no descriptor, no queue. Synchronous (poll reg+0x4c). This is the
minimal primitive an open driver needs to reproduce.

---

## 5. fbcdc and ax_dma_xfer_crop

**FBCDC (frame-buffer compress/decompress codec):** `ax_fbcdc_hw_enable`/`_disable`
(@0x718/0x958), `ax_fbcdc_cfg_lossy_lut` (@0x538). Up to 3 FBCDC HW ids
(`AX_FBCDC_HW_ID_MAX`). It is programmed by **direct CPU MMIO** on its own
ioremapped register bases (read-modify-write at `[fbc+0x00]`, `[fbc+0x20]`,
`[fbc+0x18]` — 0x7c0-0x818), gated by `ax_base_sys_clock_enabled`, and uploads a
900-byte default lossy LUT (`g_base_fbcdc_default_lut_cfg`). Purpose: transparently
compress/decompress framebuffers in DRAM to save bandwidth on ISP/VPP surfaces.
**Not needed for bypass YUV capture** — a KVM capture wants raw uncompressed YUV
in DRAM; FBCDC should stay disabled (its absence just means uncompressed buffers).
Confirm nothing in the capture surface descriptors sets an "FBC" tile/header flag.

**ax_dma_xfer_crop (2D crop/copy DMA):** `ax_dma_xfer_crop` (@0x2848),
`ax_dma_xfer_start` (@0x20b0), `ax_dma_handler` (@0x21a0, the module IRQ handler),
`ax_dma_open/close`. A memory-to-memory 2D engine: it takes a source rect
(base/stride/width/height from a caller struct at x0: src `[x0+0]`, dst `[x0+0x10]`,
dims `[x0+0xc]/[x0+0x1c]`, strides `[x0+8]/[x0+0x18]`), computes log2 of the
dimensions (rbit/clz, 0x28d8-0x2900), programs a descriptor at `[ctx+0x48]`
(offsets +0x00 src, +0x08 dst, +0x18 tile ctrl, +0x28/0x2c strides, +0x44/0x46
and +0x50/0x52 dims), sets +0x10=1 to start, and completes via the IRQ
(`dma_wait_cond_func` @0x2098 waits on `[desc+0]==0`). It is a standalone
blit/crop channel, unrelated to the register-command queue. **Not needed for the
capture datapath** — frames reach DRAM via the ISP/IFE WDMA, not this blitter. It
could later be repurposed for in-kernel crop, but the KVM path crops/scales
elsewhere, so ignore it for M2.

---

## 6. Hardware-verification checklist (on-device, unrestricted)

These decide the build-vs-bypass question and confirm the layouts above. All are
`/dev/mem` reads or light traces on the live device (which currently runs the
vendor stack).

1. **Direct-writel feasibility (THE decision):** identify the physical addresses
   of the IFE-input-mux and WDMA-output registers the bypass path programs (from
   `ax_proton.ko` ioremap sites / device tree `reg` props). With the vendor stack
   streaming, `devmem` read a couple of those registers and compare to expected
   config. Then in a controlled test, attempt a `devmem` *write* to a benign one
   and read back: if it sticks, those registers are directly CPU-addressable and
   **CDMA can be skipped entirely** (plain writel). If the write does not stick
   (reads back unchanged / needs the EXT bridge), the register lives behind the
   CDMA AXI master -> use Path B.

2. **Confirm reg+0x2c bit0 = busy and reg+0x18 bits[15:1] = occupancy:** map
   0x10034000, read reg+0x18 and reg+0x2c while the vendor stack is idle vs.
   mid-frame; occupancy should rise/fall and bit0 should pulse during submits.

3. **Confirm the EXT single-write port works standalone:** replicate the §2b
   sequence from userspace via `/dev/mem` on 0x10034000: read reg+0x4c (expect
   idle 0), write mask/ctrl/addr/data, pulse reg+0x48=1, poll reg+0x4c, and
   verify the *target* register changed. Success proves an open driver can reach
   any behind-bridge register with no descriptor engine.

4. **Descriptor layout confirmation:** trace one real `group_push_trigger` batch
   (kprobe on the exported symbol, or dump `[pipe+0x720]` after a frame): verify
   each 8-byte slot matches §3b/§3c bit layout, and that word1<<3 points at a
   readable DRAM buffer holding the register values.

5. **Instance mapping:** confirm `cdma_get_hw_id` maps the capture pipe's consumer
   id to instance 0 (0x10034000) vs 1 (0x10038000), so probes target the right block.

6. **FBCDC-off sanity:** confirm captured surfaces carry no FBC header/tile flag
   (so uncompressed reads are valid) — read the WDMA surface descriptor / a few
   KB of the output buffer and check it is plausible raw YUV.

---

## 7. Open questions

- **Q1 (blocking the verdict's residual risk):** Are the IFE-input/WDMA registers
  directly CPU-writable, or only via the EXT bridge? -> checklist #1. Either way
  the queue engine is unneeded; this only picks writel() vs the 6-write EXT poke.
- **Q2:** Does the command IRQ ever matter for register-command completion, or is
  it purely for the 2D crop DMA? Submit paths poll reg+0x2c, so probably crop-only,
  but unconfirmed (§2a).
- **Q3:** Exact meaning of word0 bit1/bit2/bit31 flags (cmd+0x0c/0x0d/0x0e). They
  select "pattern" variants (proton stores 0 / 1 / 0x101 into cmd+0x0d/0x0e paths,
  0x38e7c-0x38f58) — likely last-entry / shadow-target / double-buffer-slot
  selects. Not needed if the queue path is skipped.
- **Q4:** The fixed CMD_SYNC_TX_CTRL constant `0x10001008` at reg+0x38 — is it a
  control bitmask or a bus base? Reproduce EXT writes with it (checklist #3) to
  confirm it is required verbatim.
