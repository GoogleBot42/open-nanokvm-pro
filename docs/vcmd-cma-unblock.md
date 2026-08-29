# #49 resolved: the open VC8000E driver runs on the SHIPPING kernel — no flash

**Outcome (2026-08-30, all device-proven):** the open VCMD driver
(`.#vc8000-vcmd`) fully initialises on the unmodified shipping kernel —
coherent pools allocated, clock enabled, real IRQ wired, init self-test
cmdbufs completing through the engine:

```
ax630c-venc-vcmd: coherent carveout 0x7f800000+0x800000 declared
ax630c-venc-vcmd: clk_venc_eb enabled
[es_venc:vc] module inserted. Major <241>
ax630c-venc-vcmd: VC8000E VCMD driver initialised (base 0x4010000)
/proc/interrupts:  52: ... GIC-0 125 Level  es_venc_vcmd_drv
```

The CMA kernel flash this document originally proposed is **dead and
removed** (`.#kernel-cma` / `.#kernel-slot-image-cma` no longer exist). This
file is the record of why, and of what replaced it.

---

## Finding 1: CONFIG_CMA is an ABI break for the vendor blobs

The original safety analysis here claimed the CMA variant was blob-safe
because vermagic is byte-identical and `struct page` is unchanged. Both facts
are true — and insufficient. Flashed to slot B, the CMA kernel (and a
`CMA_SIZE_MBYTES=0` bisection variant, ruling out the reservation itself)
**dies a few seconds into boot** — exactly when the curated loader insmods the
vendor `ax_*.ko` — then the watchdog fires and the SPL fails over to slot A.
The identical kernel without CMA boots fine from the same slot. Root cause,
from the vendor tree:

- **`CONFIG_DMA_CMA` adds a field to `struct device`**:
  `include/linux/device.h` line ~1023, `#ifdef CONFIG_DMA_CMA struct cma
  *cma_area;` — every member after it shifts for every consumer, including
  the prebuilt blobs.
- **`CONFIG_CMA` renumbers the migratetype enum** (`include/linux/mmzone.h`):
  `MIGRATE_CMA` is inserted *before* `MIGRATE_ISOLATE`, changing
  `MIGRATE_ISOLATE`'s value and `MIGRATE_TYPES` — which sizes
  `struct zone`'s `free_area[].free_list[MIGRATE_TYPES]` arrays, so
  `struct zone` layout changes too (and `#if defined CONFIG_COMPACTION ||
  defined CONFIG_CMA` gates further zone fields).

Lesson, now also recorded in `pkgs/kernel.nix`: **vermagic + struct page is
not an ABI proof**. Any config flag must be audited for `#ifdef` fields in
every core struct the blobs touch (`struct device`, `struct zone`,
migratetype values, …) before assuming the blobs survive.

## Finding 2 (the replacement): dma_declare_coherent_memory on the shipping kernel

`vcmd_mem_init` needs 3× 2MB physically-contiguous *coherent* DMA. The 4.19
`dma_alloc_attrs()` consults a device's **declared coherent region first**
(`include/linux/dma-mapping.h`), before any CMA/dma_ops path — and
`dma_declare_coherent_memory` is compiled in and **exported** on the shipping
kernel. So the glue (`pkgs/vc8000-vcmd/ax630c_vcmd_glue.c`) now:

1. **Declares an 8MB coherent carveout** at module load
   (`coherent_base=0x7F800000`, `coherent_size=0x800000`, both module
   params) — the top of the 200MB CMM carveout (`0x73800000–0x7FFFFFFF`).
   ax_cmm allocates bottom-up first-fit (verified: all 9 boot blocks sit at
   `0x738xxxxx`), so the tail is untouched until CMM usage exceeds 192MB;
   during encoder bring-up the vendor app stack — the only large CMM
   consumer — is stopped anyway. A permanent home for these 8MB (shrinking
   CMM via its boot config, or a proper carveout) is #45 integration work.
2. **Enables the block clock** via the *open, in-tree* clk driver: the DT node
   `venc@4010000` (compatible `"axera, venc-encoder"` — note the space) has
   `clocks = <&vpu_clk AX620X_CLK_VENC_EB>` = `clk_venc_eb`
   (`drivers/clk/axera/clk-ax620e.c`). Unclocked, the whole `0x4010000` block
   reads the `0xDEADBEEF` bus poison — the vendor stack gates this clock
   on/off around *each frame* from userspace (caught live: hwid
   `0x43421500` visible only ~4/200 polls during active encode). The glue
   holds the clock for the driver's lifetime. Reset needs no touching — the
   block already runs when clocked.
3. **Wires the real IRQ** with `of_irq_get()` on the same DT node (GIC_SPI 93
   per the dtsi; maps to a live GIC hwirq even though the node is
   `status="disabled"` and unbound). Without it the core's initial self-test
   cmdbuf completes in hardware but nothing wakes the wait queue and insmod
   hangs in `wait_event_interruptible` (observed; recoverable with `kill -9`).

**Bring-up procedure (shipping kernel, no flash):**

```
# [DEVICE]
systemctl stop nanokvm
rmmod ax_jenc ax_venc                  # frees the vsi_vcx mem region
insmod ax630c_venc_vcmd.ko             # nix build .#vc8000-vcmd
dmesg | grep ax630c-venc-vcmd          # expect the 4 lines quoted above
# restore: rmmod ax630c_venc_vcmd; insmod /soc/ko/ax_venc.ko /soc/ko/ax_jenc.ko
#          (separate insmod calls); systemctl start nanokvm
```

Known cosmetic wart: `vcmd_mem_init` prints a bogus `phy_address` with a WARN
backtrace — it calls `virt_to_phys()` on the memremap'd (non-linear) pool
mapping. The `busAddress` used for hardware is correct (inside the carveout).
Worth fixing in the core later.

**Next (#45):** drive an IDR through `RESERVE→LINK→WAIT→RELEASE` via
`/dev/es_venc` with an open EWL, then the frame-buffer glue → closes #25.

## Finding 3: the A/B slot-B test harness works (and how)

Proven end-to-end while chasing this (full procedure now in
`docs/flashing-and-recovery.md`, "Slot-B kernel testing"): vendor
`/etc/init.d/S99checkboot systemB` + `reboot` boots slot B; the SPL's
BOOTABLE bits are consume-once (a raw `SLOTB`-only register poke silently
falls back to A); a kernel that dies on slot B auto-fails-over to slot A in
~40s with no recovery hazard; and verification is over SSH by making the
test kernel self-identifying — no serial exists on this unit.

Bonus result: the **current default kernel (with the #27 nixpkgs-rebuilt
initramfs) is hardware-boot-proven** via this harness, and `kernel_b` (p15)
now permanently holds that proven image.
