# #55 — full deblob: replacing the capture/ISP kernel stack

Working doc for the epic. Scoped 2026-08-31 from two clean-room reports:
`docs/reference/deblob-scope/scope-static.md` (binary structure of the 10
blobs, by a describing subagent) and `scope-known-abi.md` (everything the
Stage 1–6 / #17 / #49 / #50 RE already banked). Read those for evidence and
citations; this doc carries the conclusions and the plan.

## Standing rules

- **Clean-room, hard requirement (Jeremy, 2026-08-30):** all RE of vendor
  binaries goes through *describing subagents* — the agent reads the
  disassembly and emits a behavioral specification (register sequences, state
  machines, struct semantics); drivers are written from the spec only, never
  from vendor code or disassembly. On-device observation of hardware behavior
  (register snapshots, traces) is unrestricted.
- **End state:** zero closed executing code. WiFi firmware is droppable, not a
  constraint (#28). Every driver written under this epic must be designed to
  port to — ideally live in — mainline (#26 is the sibling epic).

## What scoping changed

The epic filed this as "10 modules, ~6.2 MB, the hard problem — a full ISP
driver written blind." Scoping shrank every dimension of that:

1. **The KVM path never uses the ISP as an image processor.** The pipe mode is
   literally `AX_VIN_PIPE_ISP_BYPASS_MODE`: no tuning bins, no 3A, no CSC, no
   scaling; CSI YUV422-8 in, packed YUYV at stride==width out, zero-copy to
   the encoder. #50 already proved the sole AI-ISP entry point (nr138) can be
   deleted. The vendor names our exact topology in its own strings:
   `TOP_NODE_MODE10: BYPASS PPL, only IFE WDMA working` +
   `IFE_NODE_MODE3: IFE_IN_ONELINE(YUV)->IFE_OUT_OFFLINE(DUMP)`. What #55 has
   to build is a **CSI-2 → IFE-WDMA → DDR frame writer**, not an ISP.
2. **The blobs are unstripped.** Full symtab everywhere — 3264 named functions
   in ax_proton alone, register/bit-field names spelled out in ax_mipi_rx
   symbols. Effectively a vendor source-tree map, ideal input for describing
   agents.
3. **ax_proton is 1.33 MB of code, not 4.5 MB** (the rest is relocations +
   symtab), and the capture-relevant slice is **~17–35 %** of that: the direct
   call closure of bypass+IFE+SIF+top/dev nodes is 17.1 % and imports **no
   NPU, no GDC, no VPP, no IVPS symbols**; ~39 % (AI-NR, RAW/bayer, 3A/IQ,
   test pipes) is provably dead for a digital-YUV source. (Caveat: 45 % of the
   code is reachable only via 51 × 360-byte node-mode ops tables, so static
   closures are lower bounds.)
4. **Clock/reset/IRQ resources are already open.** Our from-source kernel has
   in-tree `drivers/clk/axera/clk-ax620e.c` (505 clock IDs, including the
   `isp`/`csi`/`dphy2csi` gates) and `drivers/reset/axera_reset/` with an
   `isp_sys_reset@2500000` DT node. **Correction (device DT read, 2026-08-31):**
   only `axera,proton` (`isp@2400000`) carries `clocks`/`clock-names` — its
   `interrupts` are `<GIC_SPI 27>, <GIC_SPI 28>` (= GIC hwirq 59/60, the
   `ax_proton_intt` frame-done lines). `axera,mipi` (`mipi_rx@2600000`) carries
   only `reg` + `interrupts` (csictrl0/1) — **no `clocks`/`resets` properties**;
   the isp_clk@2500000 / isp_sys_reset@2500000 providers own those glb ranges via
   their own syscon nodes, so the open CSI-2 driver programs the csirx clock-gate
   / soft-reset / deskew bits directly in the isp_sys_glb range (0x02500000) via
   the shadow SET/CLR registers (safe — no whole-word RMW). Same open-resource
   situation the venc replacement exploited. What was filed as "in-kernel
   clock/PLL sequencing, needs RE" is mostly "call the open clk API (proton) or
   poke the documented glb gates (mipi) in the right order and verify against the
   observed un-gating."
5. **The OSAL layer needs no RE.** 188 of the 229 external symbols the ten
   modules import are `AX_OSAL_*` — and that layer is **GPL source in the
   kernel SDK** (`osal/`, built in via `CONFIG_AXERA_OSAL=y`). Only 41 plain
   kernel symbols are imported in total.
6. **The userspace contract is ~100 % banked.** All capture ioctls our stack
   issues (26 proton + 7 mipi_rx + 4 cmm + 3 pool selectors) are decoded to
   exact copy_from_user sizes and live as device-proven code in
   `kvm_capture_open.c`. Kernel-side implementation knowledge: ~30 % for
   ax_mipi_rx, ~15 % for ax_proton, ~40 % for ax_cmm, ~0 % elsewhere.
7. **ax_ivps / ax_vpp / ax_gdc / ax_npu are never called by anything we
   ship** — zero ioctls, zero device nodes opened. They load only because
   vendor ax_proton links their symbols (26 imports total, each reachable only
   from camera-only node modes: AI-NR → npu, dewarp → gdc, etc.). ax_mipi_rx's
   CSI-2 controller is very likely a licensed Synopsys DWC MIPI CSI-2 host
   core (verbatim DWC error strings) — a mainline-adjacent driver may be
   adaptable rather than written.

Still genuinely dark (the real #55 work): register write **order**/RMW/polling
inside the bypass bring-up (~140 live ISP regs + ~30 MIPI regs — snapshot
diffs exist, sequences don't); the **IFE WDMA buffer-address programming**
(we only ever see an opaque pool handle); the **ax_base CDMA descriptor
format** that proton's `regio` layer pushes register writes through (the
single real gate); frame-done **interrupt** semantics (vendor polls via
hrtimer; we poll too); the four mandatory bypass-config selectors
(nr56/74/54/89 — skipping them hard-hangs the SoC); `mem_iq_level=1`; whether
`/opt/data/mc20e_isp_reg_reset_value.bin` matters in bypass; and a RISC-V
companion core behind a mailbox (statistics/sleep only, probably ignorable).

## Decision — target ABI (step 2 of the epic): clean V4L2, whole-closure swap

**We write a clean V4L2/media-controller capture stack and swap the entire
closure at once. We do not re-implement the vendor ioctl surface, and we do
not build drop-in replacements for individual blobs under the vendor stack.**

- A drop-in path means re-implementing the inter-blob kernel ABI (the
  cmm/pool/sys/base exports and their struct layouts) and living with the
  #49-class struct-layout fragility while open code shares structs with
  blobs. **If the whole closure goes at once, that entire ABI cost is zero** —
  the only frozen interface left is the userspace one, which we own.
- Every line written against the vendor ABI is discarded at the #26 mainline
  move; every line of a V4L2 driver *is* the mainline driver.
- The substrate blobs mostly evaporate rather than get rewritten: vb2 +
  dma-contig/CMA replaces ax_cmm + ax_pool (the #52/#53 carveout/memory-map
  question folds into this design); media-controller links + ktime replace
  ax_sys; ax_ivps was never called; ax_npu and ax_gdc are deleted, not
  replaced; ax_vpp (scaler) is deferred — software scaling covers preview
  needs until measured otherwise.
- Target driver shape: a CSI-2 receiver subdev (`axera,mipi`; likely
  DWC-lineage) + a VIN/IFE capture video node (`axera,proton` reg block, IFE
  WDMA, vb2-dma-contig, frame-done IRQ) + dma-buf export to the open venc
  driver. Developed first on the from-source 4.19 kernel (device-provable
  today, A/B via curated loader + slot-B harness), structured for the
  mainline port.
- Consequence for testing: incremental milestones happen *within the open
  stack* (link-up → frames-to-DDR → backend parity), booted A/B against the
  vendor stack — never by swapping single modules under the blobs (register
  and IRQ ownership forbid coexistence anyway).

## Plan

**Progress (2026-08-30): the three spec deliverables (steps 1 seed, 2 seed, 3)
are DONE and main-session-verified against the disassembly.** Clean-room
behavioral specs live in `docs/reference/deblob-scope/specs/`:
`spec-mipi-rx.md` (#57), `spec-cdma.md` (#58a), `spec-proton-bypass.md` (#58b).
The `ax_stub` symbol-stub module (#56) is built and committed.

**On-device verification pass (2026-08-30) — the specs' inferred values checked
against live hardware during 4K30 vendor capture** (raw dumps preserved in the
session record; kernel has `CONFIG_KPROBE_EVENTS` off, so this used `/dev/mem`
register correlation, not kprobes):
- **The IFE-WDMA address gate is CONFIRMED LIVE.** WDMA block base = `0x02414000`,
  active channel 8; buffer-addr register `0x024140d4` (= base + 0x18*8 + 0x14)
  held `0x0e8fc000` = `phys>>3`; `<<3 = 0x747E0000`, inside the CMM DRAM
  partition (`0x73800000–0x7F7FFFFF`). The `writel(dma_addr>>3, wdma_block +
  0x18*chn + 0x14)` gate is real. SIF `WIN0_SIZE` at `0x02406518` =
  `W|(H<<16)` = `0x08700f00` (3840×2160), IFE-go `0x024146dc` = bit0 set.
- **Frame-done IRQ CONFIRMED.** Group-4 enable `0x02400050` = `0x200` (bit9),
  group-1 FSOF `0x02400020` = bit0, both as spec. Live line = `ax_proton_intt`,
  **GIC hwirq 59/60 = DT `GIC_SPI 27/28`** (SPIs are offset +32: 59−32=27), Linux
  irq 35/36, firing ~3× per frame (FSOF + frame-done + 1, demuxed in-handler).
  So the spec/scope "IRQs 27/28" (DT SPI indices) and the observed hwirq 59/60
  are the SAME lines — the existing `axera,proton` DT `interrupts` property is
  correct and M2 reuses it. (The `arch_timer` at "GIC-0 27" is PPI 27, a
  different number space — not this interrupt.) M2 uses this ISR, drops the poll.
- **CSI-2 core is CUSTOM confirmed** (not DWC-drop-in): `0x02600000+0x00` =
  `0x0001321c` (not an ASCII-BCD version word; ctrl0 ≠ ctrl1 `0x0001021c`).
  Register map validated exactly to spec: `+0x08`=`0x43210410` (comboMode4),
  `+0x40`=`0x1f` (4 lanes), `+0x100`=1 (stream start); link-up health
  `0x02500000+0x00` bits[1:0]=3 (both lanes locked). M1 offsets are authoritative.
- **STILL OPEN (one item):** the MODE10 bypass bitmask constant (`@0x154/0x158`)
  reads 0 live — it is write-only/shadow-strobe and uncapturable by `/dev/mem`
  without a `register_kprobe` tracer module (this kernel lacks `kprobe_events`).
  Resolve during M2 bring-up: the M2 driver programs MODE10 itself and can
  read-back-verify, or a small `register_kprobe` module traces
  `ax_ife_top_module_bypass_set_cfg_set`.
- **`ax_proton` is runtime-UNREMOVABLE** (`rmmod` fails busy at refcount 0 from a
  fresh boot; `ax630c_venc_vcmd` unloads fine). So the capture stack is
  **boot-only-swappable** — which confirms this doc's A/B-by-reboot testing model
  and means **the #56 stub test cannot be a runtime module swap** (it needs
  ax_proton loaded *after* ax_stub). #56 validation folds into the boot-time /
  slot-B A/B path that M2 uses anyway — see step 1.

Three findings from the specs materially change the plan below:

- **The CDMA descriptor/queue engine is OPTIONAL.** Two independent RE passes
  (spec-cdma and spec-proton-bypass) agree: proton's `regio` layer selects at
  runtime between direct MMIO and CDMA batching, and plain ordered `writel()` +
  explicit poll loops reproduce the config. The only ordering rule is *set
  enable/shadow-commit bits last*. M2 does not implement a CDMA descriptor
  engine. (Worst case for any behind-the-bridge register: a ~30-line EXT
  single-poke helper, spec-cdma §2b.) **The item filed as "the single real
  gate" is largely dissolved.**
- **The IFE-WDMA buffer-address gate is SOLVED (spec-proton-bypass §3):**
  `writel(dma_addr >> 3, wdma_block + 0x18*chn + 0x14)`; enable = bit0 @ `+0x1c`;
  shadow-commit = bit0 @ `+0x18`; whole-frame MODE3 = single partition, offset 0.
  vb2 substitutes directly for the vendor pool (put the vb2 `dma_addr` where the
  vendor puts the pool phys addr). This was "never traced" — now traced.
- **Frame-done IRQ is real and unmasked** (spec-proton-bypass §5: group-4 int
  regs `0x02400050/54/58/5C`, enabled by `vin_bypass_pipe_irq_register`). The
  hrtimer is an unrelated scheduler deadline, not a hardware limitation. **M2
  uses a real ISR and drops the 5 ms poll.**
- **`mc20e_isp_reg_reset_value.bin` is NEVER read** (spec-proton-bypass §7,
  verified: proton imports `AX_OSAL_FS_filp_{open,write,close}` but no read
  primitive — the path is a snapshot *write* target). M2 implements nothing for
  it. (Resolves the open question below.)
- **The four "mandatory" selectors touch no registers/clocks** — they deposit
  software state consumed at node-start; only nr54 (`ax_vin_pipe_partition_info_set`,
  the OCM slice/partition handshake) is structurally load-bearing. nr56/74/89 are
  likely vendor call-order (a device test can confirm they are droppable).

1. **Stub experiment (cheap, high information):** replace ax_npu + ax_gdc +
   ax_vpp + ax_ivps with one tiny open module exporting their 26
   proton-imported symbols as logging stubs. If bypass capture runs clean with
   silent stubs, four blobs (~380 KB text) leave the image now and the
   "never executed" claim is runtime-proven; any stub that *does* log reveals
   a hidden init-time call edge the vtable caveat warned about. Rollback = the
   vendor loader. **Module built + committed (`pkgs/ax-stub`, loader variant
   `pkgs/rootfs/ax-load-drv.stub.sh`).** Device test method REVISED (device pass
   2026-08-30): `ax_proton` is runtime-unremovable, so the stub cannot be swapped
   in at runtime — it must be loaded at BOOT (ax_stub before ax_proton). Validate
   by booting the stub loader via the slot-B A/B image harness (same mechanism as
   M2), *not* a runtime rmmod/insmod. Dropping the persistent `/soc` loader +
   reboot also works but risks a boot cycle on the production eMMC; the slot-B
   image is the clean path. The read is still binary: dmesg silent ⇒ 4 blobs
   provably dead; any `NODE-MODE EDGE HIT: <sym>` ⇒ a live edge, named.
2. **CSI-2 identification + first driver (M1):** read the CSI controller
   version/ID registers on-device; if DWC-confirmed, adapt the mainline
   `dw-mipi-csi2`-family driver instead of writing one. Describing-agent spec
   of ax_mipi_rx (7 selectors, ~28+8 register writes, bit names already in
   symbols) fills the gaps. Deliverable: open V4L2 CSI-2 subdev proving PHY
   lock + packet/error counters on hardware, vendor stack not loaded.
3. **The gate RE (spec work, parallel to M1): DONE 2026-08-30.** Behavioral
   specs of (a) the ax_base CDMA format (`spec-cdma.md`) and (b) the proton
   bypass/IFE-WDMA register programming (`spec-proton-bypass.md`) delivered and
   verified — see the progress note above. Both are seeded from the bypass
   closure; on-device *register-trace* confirmation of a handful of live values
   (WDMA absolute base, MODE10 bitmask constant, frame-done bit index/SPI,
   YUV422 plane→channel map) is the one remaining device step, folded into the
   serialized device-verification pass alongside M1's CSI-ident read.
4. **Frames to DDR (M2):** the VIN/IFE capture video node against the spec
   from (3): SIF front-end config, IFE WDMA, vb2 buffers, frame-done IRQ
   (retiring the 5 ms poll). Success = YUYV frames at 1080p and 4K30 with
   zero vendor modules loaded, A/B-verified against the vendor image.
5. **Backend parity (M3):** third capture backend in kvm-encoder (V4L2), wired
   to the open venc path; geometry envelope, audio, mini-display preview
   (software downscale) all at parity; swap the default, retire the closure
   from the loader and the blobs from the image (#54 round 2 absorbs the disk
   cleanup).
6. **Mainline port** rides with #26 once M3 ships on 4.19.

EDID (step 3 of the epic) is DONE: all six bins clean-room as of this commit
(four exotic modes pending hardware validation — Jeremy task).

## Open questions to resolve early

- CSI controller identity (DWC or not) — decides M1's starting point. Static RE
  says DWC-lineage LIKELY but the register interface is Axera-custom (mainline
  `dw-mipi-csi2` is a reference, not a drop-in); no version reg is read
  statically. **Settle on device:** read `0x02600000`/`0x02602000` +0x00 live.
- ~~Does bypass bring-up read `mc20e_isp_reg_reset_value.bin`?~~ **RESOLVED: no.**
  proton has no file-read primitive; the path is a snapshot *write* target
  (spec-proton-bypass §7). Implement nothing for it.
- ~~Frame-done IRQ vs hrtimer poll~~ **RESOLVED + device-confirmed:** a real
  unmasked frame-done IRQ exists — group-4 enable `0x02400050`=`0x200` (bit9,
  confirmed live), `ax_proton_intt` on **GIC hwirq 59/60 = DT `GIC_SPI 27/28`**
  (irq 35/36), ~3× fps (FSOF+frame-done+1, in-handler demux). The hrtimer is
  unrelated. M2 uses the ISR and reuses the existing DT interrupts property.
  (`arch_timer` at "GIC-0 27" is PPI 27 — a different space, not this line.)
