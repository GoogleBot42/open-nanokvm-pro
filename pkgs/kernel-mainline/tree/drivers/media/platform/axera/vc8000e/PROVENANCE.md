# VC8000E VCMD driver — provenance & AX630C port notes

The kernel half of the blob-free encode-submission path (issue #44): the open
VeriSilicon VC8000E **VCMD command-engine** driver, ported out-of-tree to the
NanoKVM-Pro's from-source 4.19.125 kernel.

## Upstream source

- **Project:** eswin `linux-stable`, branch `linux-6.6.18-EIC7X` (EIC7700 BSP).
- **Repo:** https://github.com/eswincomputing/linux-stable
- **Revision:** `fc6038c00e006226e3bd504d2679c534eabf5503` (branch HEAD at fetch, 2026-08-28)
- **Path:** `drivers/staging/media/eswin/venc/`
- **License:** dual **MIT / GPL-2.0**, "COPYRIGHT (C) 2019 VERISILICON ALL RIGHTS
  RESERVED" (per-file SPDX `GPL-2.0` + the dual-license block). Redistributable;
  vendored here with this provenance record.

This is the driver the repo docs identify as the correct port target: the AX630C
VCMD engine reports `hw_version_id = 0x43421500` (VCMD v1.5.0), and this eswin
copy is the cleanest, most modern in-tree VCMD variant matching it
(docs/blob-replacement.md, 2026-08-22 §8 + 2026-08-23 Stage 1).

## What is vendored (`eswin/`)

Pristine upstream, except `vc8000_vcmd_driver.c` (see edits below):

| File | Role | Modified? |
|---|---|---|
| `vc8000_vcmd_driver.c` | the VCMD command-engine driver (char dev, ioctls, cmdbuf link/run) | **yes — 3 compat shims + 2 call sites, all marked `AX630C-PORT`** |
| `vcmdswhwregisters.c/.h` | VCMD register read/write helpers | pristine |
| `bidirect_list.c/.h` | doubly-linked cmdbuf list | pristine |
| `vc8000_driver.h` | shared ABI (ioctls, `struct exchange_parameter`, cfg structs) | pristine |
| `vc8000_vcmd_cfg.h` | compile-time core table (offsets, submodule addrs) | pristine |
| `vcmdregisterenum.h`, `vcmdregistertable.h` | VCMD swreg tables | pristine |
| `vc_drv_log.h` | LOG_* macros | pristine |

**NOT vendored** (deliberately): the eswin platform/probe layer
`vc8000e_driver.c`, the AXI-FE (`vc8000_axife.*`), the MMU (`hantro_mmu.c`,
`hantrommu.h`), the non-VCMD path (`vc8000_normal_driver.c`), and the dma-heap
import helper. `vc8000e_driver.c` is bound to the EIC7700 device tree
(`vcmd-core`/`axife-core` bindings), eswin's SMMU dynamic-SID scheme, and eswin
clk/reset/TBU/pm-runtime — none of which exist on the AX630C. Its role is
replaced by our own AX630C platform layer, `ax630c_vcmd_glue.c` (GPL-2.0).

## The AX630C port

### `ax630c_vcmd_glue.c` (our code, GPL-2.0)

Provides the handful of symbols the VCMD core imports from the (excluded) eswin
platform layer, and stands up a minimal char-device instance:

- `venc_pdev` / `venc_pdev_d1` — the platform device owning the coherent VCMD
  pools (`venc_pdev_d1` is always NULL; AX630C is single-die, no dual-die IOVA).
- `enc_pm_runtime_get/put`, `enc_reset_system` — no-ops (AX630C clock/reset/power
  is standard DT framework; not wired to a real DT node yet — see Remaining).
- `module_init`: register a bare `platform_device` with a 32-bit DMA mask, set
  `venc_vcmd_core_num = 1` and the encoder core's absolute VCMD base
  `0x04010000` (device-traced: `vsi_vcx@0x4010000`; encoder core at
  `+0x1000`), then call the core's `vc8000e_vcmd_init()`
  (`vcmd_mem_init()` + `hantroenc_vcmd_init()`).

### Edits to `vc8000_vcmd_driver.c` (all marked `AX630C-PORT`)

1. **dma-heap include guarded** — `#include <linux/dmabuf-heap-import-helper.h>`
   wrapped in `#ifdef SUPPORT_DMA_HEAP` (undefined in our build; 4.19 has no
   dma-heap). All the `common_dmabuf_heap_*` call sites were already
   `#ifdef SUPPORT_DMA_HEAP`-guarded upstream.
2. **`access_ok()` arity** — the 2-arg form (Linux ≥5.0) wrapped by an
   `AX_ACCESS_OK()` macro that expands to the 3-arg `access_ok(VERIFY_WRITE, …)`
   form on <5.0 (our 4.19). Two call sites updated.
3. **`pfn_to_phys()`** — arm64 4.19 has no `pfn_to_phys()`; compat macro to the
   generic `PFN_PHYS()` (`#include <linux/pfn.h>`).
4. **`hantrovcmd_mmap` maps by bus/phys directly** — the upstream mmap gates on
   `pool.phy_address` (from `vmalloc_to_pfn`) and calls `dma_mmap_coherent`.
   On AX630C the pools live in a `dma_declare_coherent_memory()` carveout
   *outside* kernel-managed DRAM (`mem=` boundary), where `phy_address !=
   busAddress` and `dma_mmap_coherent`'s declared-region path returns ENXIO.
   Fixed to accept the `busAddress` (the value `GET_CMDBUF_PARAMETER` actually
   hands userspace) and to map with a plain `remap_pfn_range` + writecombine
   prot — the same result the vendor stack got via `/dev/mem`, minus the
   STRICT_DEVMEM / no-struct-page hazards. Proven 2026-08-30 by the userspace
   submitter (`pkgs/vcenc-ewl`): full RESERVE→LINK→WAIT→RELEASE, hardware DMAs
   the encoder register file into the mmap'd status pool.
5. **From-source frame-buffer allocator hooks (#45)** — three small additions
   wiring in `framebuf_alloc.c` (our code, see below): two ioctl cases
   (`HANTRO_IOCH_ALLOC_FRAMEBUF`/`FREE_FRAMEBUF`, nrs 36/37 — unused upstream),
   a `vcmd_fb_lookup` branch in `hantrovcmd_mmap` (frame buffers map through
   the same writecombine `remap_pfn_range` path as the pools), and
   `vcmd_fb_release_filp()` in `hantrovcmd_release` (both exits) so a dying
   process leaks nothing.

### `framebuf_alloc.c` / `framebuf_alloc.h` (our code, GPL-2.0)

The other half of #45: a from-source CMM frame-buffer allocator replacing the
Stage-B fixed-address `/dev/mem` placement. First-fit over a bus-sorted list
covering a module-parameter carveout (default `0x78000000+0x04000000` on the 1G
board; the curated loader computes and passes it since #53 — a formal 64 MB
slice of the 200MB CMM region: above ax_cmm’s lowered `cmmpool=` ceiling,
below the open capture carveout and the glue’s 8MB coherent VCMD-pool region
at `0x7F800000` — layout table in docs/vcmd-cma-unblock.md).
Pure address-space bookkeeping: the kernel never maps the memory — the encoder
DMAs it and userspace mmaps it (writecombine) through the driver. Allocations
are owned by the open file and freed on close. Device-proven 2026-08-30: the
allocator-based `ewl_encode` run produced a stream bit-identical to the
`/dev/mem` run.

### Build flags (`Makefile`)

- `-DHANTROVCMD_ENABLE_IP_SUPPORT` → `ASIC_VCMD_SWREG_AMOUNT = 64` (matches the
  AX630C engine).
- `-std=gnu11` → the eswin source uses C11 (declarations after statements, C99
  for-loop initial declarations, per-loop scoping). The 4.19 kernel builds
  modules as gnu89 (relaxed tree-wide to gnu11 only in 5.18+); compiling just
  this out-of-tree module as gnu11 lets the vendored source build **unmodified**.
  Kernel headers are gnu11-clean.
- `SUPPORT_DMA_HEAP`, `HANTROAXIFE_SUPPORT`, `SUPPORT_WATCHDOG` all **off** —
  minimal first port (no dma-heap on 4.19; no AXI-FE/MMU on this path).

## Build

`nix build .#vc8000-vcmd` → `result/ax630c_venc_vcmd.ko`.

The derivation (`pkgs/vc8000-vcmd.nix`) configures the from-source kernel tree
(`make <defconfig> && make modules_prepare`) and does an out-of-tree `M=` build.
MODVERSIONS is off in our kernel (see `pkgs/kernel.nix`), so the missing
`Module.symvers` is expected and harmless — the `.ko` loads by vermagic string
alone, exactly like the vendor `ax_*.ko`.

Verified output:
- `ELF 64-bit LSB relocatable, ARM aarch64`
- `vermagic: 4.19.125 SMP preempt mod_unload aarch64` (byte-identical to the
  vendor blobs → plain `insmod`-loadable into our kernel)
- undefined symbols are **only** standard exported kernel symbols (printk,
  ioremap, dma_*, kthread_*, register_chrdev, platform_device_*, …) — no
  dangling eswin/dma-heap/axife symbols.

## Submission path (milestone 3) — why this removes the vendor EFAULT seam

The public VCMD userspace contract, read directly from this source:

```
open(/dev/…)                                  # char dev, magic 'k'
HANTRO_IOCH_GET_VCMD_PARAMETER   (nr 28)      # enumerate cores, hw_version_id
HANTRO_IOCH_GET_CMDBUF_PARAMETER (nr 25)      # cmd/status/register pool phys+size → mmap
  per frame:
    HANTRO_IOCH_RESERVE_CMDBUF   (nr 29)      # in: exchange_parameter{module_type,exec_time,prio}
                                              # out: cmdbuf_id + slot size (kernel alloc)
    <userspace writes the VC8000E register program into pool_base + id*unit via the mmap>
    HANTRO_IOCH_LINK_RUN_CMDBUF  (nr 30)      # in: exchange_parameter{cmdbuf_id, cmdbuf_size=len}
    HANTRO_IOCH_WAIT_CMDBUF      (nr 31)      # in/out: cmdbuf_id → blocks until frame ready
    HANTRO_IOCH_RELEASE_CMDBUF   (nr 32)      # in: cmdbuf_id
```

`reserve_cmdbuf()` allocates a **kernel-side** `cmdbuf_obj` (in
`global_cmdbuf_node[cmdbuf_id]`) and returns the id. `link_and_run_cmdbuf()`
takes **only** the 16-byte `exchange_parameter` (copied in the ioctl wrapper),
looks the object up by `cmdbuf_id`, and touches the cmdbuf **exclusively through
the kernel's own `cmdbuf_virtualAddress`** of the shared pool — it never
`copy_from_user`s a userspace descriptor VA.

This is the decisive contrast with the on-device vendor `ax_venc.ko`, whose
per-frame path is `nr70 (frame setup — passes a userspace VA) → nr83 ×2 →
RESERVE → LINK → WAIT → RELEASE`, and whose `link_and_run` faults (`-EFAULT`) on
an out-of-band RESERVE→LINK because it reads state that nr70/nr83 register
(docs/blob-replacement.md, 2026-08-23 Stage 1). **The public driver has no nr70,
no nr83, and no such user-access in its LINK path — so the open driver removes
the EFAULT seam wholesale.** The future open EWL (#45) targets exactly the
`RESERVE→LINK→WAIT→RELEASE` sequence above; no frame-setup ioctl is required.

## Remaining work (NOT done here — host-only run, device out of scope)

1. **DT binding + reserved-memory carveout.** Replace the bare
   `platform_device_register_simple` with a real AX630C DT node so the coherent
   VCMD pools come from a known low-DRAM carveout the encoder can reach, and so
   `of`-based IRQ/clock/reset can be wired. (`vcmd_mem_init()` currently computes
   `phy_address` via `vmalloc_to_pfn` on the coherent alloc, which is only valid
   for the reserved-carveout case — revisit with the DT allocation.)
2. **IRQ line.** `AX630C_VENC_VCMD_IRQ = -1` disables `request_irq`; wire the
   real VCMD interrupt (docs cite `GIC_SPI 93` on comparable parts — confirm on
   AX630C) for interrupt-driven WAIT instead of the polling fallback.
3. **Clock/reset/power.** Make `enc_pm_runtime_*`/`enc_reset_system` drive the
   real DT clk/reset (open, standard — "no gap" per docs) rather than no-ops.
4. **On-device load test.** insmod against the from-source kernel, confirm
   `vcmd_reserve_IO` finds `hw_version_id = 0x43421500`, then drive one IDR
   through RESERVE→LINK→WAIT→RELEASE from open userspace and compare to the
   Stage-1 hijack-validated register program. **RISKY** — conflicts with the
   vendor `ax_venc.ko`; must unload the vendor module first and follow the device
   safety envelope. Explicitly deferred to a human/serialized device session.
