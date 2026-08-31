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
   `isp_sys_reset@2500000` DT node; `axera,proton` (0x2400000, IRQs 27/28) and
   `axera,mipi` (0x2600000, IRQs 31/33) DT nodes carry reg/interrupts/clocks.
   Same open-resource situation the venc replacement exploited. What was filed
   as "in-kernel clock/PLL sequencing, needs RE" is mostly "call the open clk
   API in the right order and verify against the observed un-gating."
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

1. **Stub experiment (cheap, high information):** replace ax_npu + ax_gdc +
   ax_vpp + ax_ivps with one tiny open module exporting their 26
   proton-imported symbols as logging stubs. If bypass capture runs clean with
   silent stubs, four blobs (~380 KB text) leave the image now and the
   "never executed" claim is runtime-proven; any stub that *does* log reveals
   a hidden init-time call edge the vtable caveat warned about. Rollback = the
   vendor loader.
2. **CSI-2 identification + first driver (M1):** read the CSI controller
   version/ID registers on-device; if DWC-confirmed, adapt the mainline
   `dw-mipi-csi2`-family driver instead of writing one. Describing-agent spec
   of ax_mipi_rx (7 selectors, ~28+8 register writes, bit names already in
   symbols) fills the gaps. Deliverable: open V4L2 CSI-2 subdev proving PHY
   lock + packet/error counters on hardware, vendor stack not loaded.
3. **The gate RE (spec work, parallel to M1):** describing-agent behavioral
   specs of (a) the ax_base CDMA descriptor/queue format, (b) the proton
   bypass/IFE-WDMA register programming — write order, buffer-address regs,
   IRQ/frame-done semantics — seeded from the 550-function bypass closure and
   verified by on-device register traces. **Do this before committing to a
   proton-driver timeline.**
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

- CSI controller identity (DWC or not) — decides M1's starting point.
- Does bypass bring-up read `mc20e_isp_reg_reset_value.bin`? (Check on device;
  if yes, the reset values need a clean-room re-derivation, not a copy.)
- Frame-done IRQ: is one of GIC 27/28 usable for capture completion in bypass
  mode, or is the vendor's hrtimer poll a hardware limitation?
