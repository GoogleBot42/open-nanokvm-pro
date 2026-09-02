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
   consumer — is stopped anyway.

   **Since #53 (2026-09-01) the base is no longer a constant:** the curated
   loader computes the whole DMA map from the board's pool geometry and passes
   `coherent_base`/`coherent_size` in, and lowers ax_cmm's `cmmpool=` ceiling
   below every open carveout. The defaults above are only the 1G-board
   fallback. See "DMA memory map" below.
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

## DMA memory map (#53)

Four consumers DMA out of the same CMM pool, and until #53 three of them
overlapped: the vendor CMM allocator `ax_cmm`, the open encoder's frame-buffer
carveout (`framebuf_alloc.c`), the open capture driver's buffer carveout
(`open_vin_capture.c`), and the open encoder's coherent VCMD cmdbuf pool
(`ax630c_vcmd_glue.c`). Our loader
(`pkgs/rootfs/ax-load-drv.sh`, `compute_mem_map`) computes one map at boot
and hands every consumer its slice as a module parameter. Since #55 M3
(2026-09-02) `ax_cmm` is not loaded at all, so its slice is simply unclaimed on
a default boot; the map still reserves it, which is what keeps the `.openvenc`
rollback loader safe.

**Derivation rule.** The pool `[pool_base, pool_top)` is what the vendor
`get_cmm_size` math already yields from the board id and the kernel `mem=`
(`pool_base = 0x40000000 + os_mem_size`, `pool_top = pool_base + cmm_size`).
Everything is carved from `pool_top` **downward**; nothing is a literal
address, so a 0.5G/2G/4G board relocates the whole map automatically.
`pool_base` itself is never moved — shrinking `cmm_size` before the base is
computed would shove the base *up* and leave the top of DRAM owned by nobody.

| Region | Extent | Size | 1G board |
|---|---|---|---|
| VCMD coherent cmdbuf pool | `[pool_top-8M, pool_top)` | 8 MB | `0x7F800000` |
| Open capture buffers | next 56 MB down | 56 MB | `0x7C000000` |
| Open encoder frame buffers | next 64 MB down | 64 MB | `0x78000000` |
| `ax_cmm` | `[pool_base, framebuf_base)` | remainder | `0x73800000` +72 MB |

On the 1G board the pool is `0x73800000..0x80000000` (200 MB) and the map lands
exactly on the addresses the drivers used to hard-code.

**Why those sizes.**

- **8 MB coherent** — `vcmd_mem_init`'s three 2 MB pools plus slack. Reserving
  the *top* is what makes it safe: `ax_cmm` is bottom-up first-fit, so lowering
  its ceiling is the whole mechanism.
- **56 MB capture** — three 4K YUYV frames (3840×2160×2 ≈ 15.9 MB each).
- **64 MB frame buffers** — the real 1080p encode floorplan is ~43 MB. 4K
  blob-free *encode* needs more than this and is **#52**; the space is now
  there for the taking, since epic #55 retired the vendor capture path and left
  `ax_cmm`'s 72 MB unclaimed on a default boot.
- **72 MB for `ax_cmm`** — sized for the vendor capture path (~16.5 MB at
  1080p, ~66 MB at 4K) so a `.openvenc` rollback still captures at 4K.

**Safety valve.** If a board / `mem=` combination would leave `ax_cmm` below
72 MB (`MAP_CMM_MIN_MB`), the loader prints a five-line `*** WARNING (#53)`
block, **abandons the split**, and falls back to the pre-#53 behaviour —
reserve only the top 8 MB, leave the encoder/capture carveouts on their
compiled-in defaults (which then overlap the pool, safe only because `ax_cmm`
allocates bottom-up). A degraded-but-known state beats a silently broken pool.

**What the loader passes.**

```
insmod ax630c_venc_vcmd.ko coherent_base=… coherent_size=… \
                           framebuf_base=… framebuf_size=…
insmod open_vin_capture.ko carveout_base=… carveout_size=…
```

The `.openvenc` rollback loader additionally passes
`cmmpool=anonymous,0,<pool_base>,<remainder>M` to `ax_cmm` (never load it
without that parameter — it panics). For consumers insmod'd by hand during
bring-up the loader also writes `/run/openkvm-memmap.env`:

```
. /run/openkvm-memmap.env
insmod open_vin_capture.ko carveout_base=$OPENKVM_CAPTURE_BASE \
                           carveout_size=$OPENKVM_CAPTURE_SIZE
```

The file additionally carries `OPENKVM_POOL_BASE/TOP/SIZE_MB`,
`OPENKVM_CMM_BASE/SIZE_MB`, `OPENKVM_FRAMEBUF_*`, `OPENKVM_COHERENT_*` and
`OPENKVM_MEMMAP_SPLIT` (0 when the safety valve fired). The map is printed to
the boot console either way.

The module defaults in `ax630c_vcmd_glue.c`, `framebuf_alloc.c` and
`open_vin_capture.c` are kept at the 1G-board values so an unparameterized
`insmod` still works on the test unit; on any other board the loader's
parameters are load-bearing.

Cross-references: `docs/architecture.md` (boot chain / module load),
`docs/deblob-capture.md` step 4 (the capture carveout under epic #55).

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
