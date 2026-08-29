# The one reversible flash that unblocks the open VC8000E encoder (#49)

The open VeriSilicon VC8000E VCMD driver (`#44`, flake output `.#vc8000-vcmd`)
loads on-device, but `vc8000e_vcmd_init → vcmd_mem_init` needs **3× 2 MB
physically-contiguous *coherent* DMA** (`dma_alloc_attrs(…, DMA_ATTR_FORCE_CONTIGUOUS)`)
before it claims any MMIO. The shipping kernel has **`CONFIG_CMA` not set**, and
the 200 MB CMM carveout (`0x73800000–0x7FFFFFFF`) is reserved *outside*
kernel-managed DRAM — so no allocator can satisfy those pools. Proven on-device
2026-08-29 (`docs/blob-replacement.md`, "#25 finish-line probe"): first insmod
NULL-derefs → watchdog reboot; with the fail-safe null-check the second insmod
aborts cleanly with `dma_alloc_attrs(2097152) FAILED (no CMA?)` →
`vcmd_mem_init failed (-12)`.

This is the **single human action** that converts the open-driver bring-up
(`#44`/`#45`) from "blocked" into "no-new-RE finish": flash a purpose-built
kernel that carries a CMA area, to the **reversible `kernel_b` slot**.

---

## Decision: CONFIG_CMA kernel variant (approach 1), kernel-Image-only

Two approaches were analysed (see the safety section for the full reasoning):

1. **CONFIG_CMA kernel variant** — enable `CONFIG_CMA` + `CONFIG_DMA_CMA` + a
   16 MiB default CMA area. arm64 bootmem auto-reserves it; the driver's bare
   platform device falls back to that default area, so its `FORCE_CONTIGUOUS`
   pools allocate. **Zero driver change, zero DTB change, one partition flashed.**
2. **VCMD reserved-memory DT carveout** — a `shared-dma-pool` region bound to the
   device via `of_reserved_mem_device_init`. DTB-only for kernel config, but needs
   a driver change (turn the `register_simple` platform device into a DT-probed
   one with a `memory-region` phandle), a hand-placed phys carveout inside
   `mem=256M`, and a second partition (`dtb_b`) reflashed.

**Approach 1 is implemented and recommended.** It has the strictly smaller blast
radius: the encoder driver stays byte-for-byte as-is, no device-tree address
guessing, and only `kernel_b` is touched. Its only theoretical downside vs (2) —
"a kernel-config change could disturb the `ax_*.ko` ABI" — is **disproven by
evidence below**: the vermagic string is byte-identical and `struct page` is
unchanged, so the vendor blobs load exactly as before. Approach (2)'s
"config-change-free" edge is therefore moot.

Flake outputs (opt-in; the default `.#kernel` and every shipping image are
**byte-for-byte unchanged** — the default kernel's `.drv` hash is identical):

| Output | What |
|---|---|
| `.#kernel-cma` | the kernel `Image` + modules, `CONFIG_CMA=y` + 16 MiB default CMA area (`pkgs/kernel.nix`, `cmaSizeMBytes = 16`) |
| `.#kernel-slot-image-cma` | that Image → `ax_gzip -9` + 1 KB signed header, sized for the 64 MB `kernel_b` partition |

---

## Safety verdict: SAFE to flash to `kernel_b`

**Blast radius:** one partition, `kernel_b` = `/dev/mmcblk0p15` (A/B slot B).
Slot A (`kernel` = p14) is never touched. `dtb_b` (p13) already holds the correct
patched DTB — our `image.nix` writes the same signed dtb to both `dtb` and
`dtb_b`, and the same from-source kernel to both `kernel` and `kernel_b` — so a
slot-B boot uses a matching, known-good DTB with **no DTB flash required**.

**Rollback:** boot slot A. Because slot A was never written, rollback is a slot
switch, not a restore.

**ABI safety — the decisive question, answered with evidence:**

- **Vermagic is byte-identical.** `VERMAGIC_STRING` (`include/linux/vermagic.h`)
  is built only from `UTS_RELEASE`, `SMP`, `PREEMPT`, `MODULE_UNLOAD`,
  `MODVERSIONS`, `MODULE_ARCH_VERMAGIC`, `RANDSTRUCT` — **`CONFIG_CMA` is not a
  component.** Verified empirically: a module built by `.#kernel-cma`
  (`lt6911_manage.ko`) carries `vermagic=4.19.125 SMP preempt mod_unload
  aarch64`, byte-for-byte equal to the vendor `ax_cmm.ko` / `ax_venc.ko`. So the
  blobs still `insmod` with no `--force-vermagic` (`MODVERSIONS` stays off; no
  `__versions` CRC gate). The in-build guards in `pkgs/kernel.nix` fail loudly if
  `kernelrelease`, `SMP/PREEMPT/MODULE_UNLOAD`, or `MODVERSIONS` ever drift.
- **`struct page` is unchanged**, so `ax_cmm`'s page arithmetic is unaffected.
  In `include/linux/mm_types.h` the only config-gated field of `struct page` is
  under `CONFIG_MEMCG` — which stays **off** (`# CONFIG_MEMCG is not set`).
  `CONFIG_CMA` adds no `struct page` field; it reuses the existing pageblock
  migrate-type machinery (`MIGRATE_CMA`, a value in the already-3-bit
  pageblock-type field, not a new bit). This is the exact contrast CLAUDE.md
  warns about: `CONFIG_MEMCG` *would* resize `struct page` and break the blobs'
  inter-module page math — `CONFIG_CMA` does not. The two symbols `CONFIG_CMA`
  `select`s (`MEMORY_ISOLATION`, `MIGRATION`) are **already `=y`** in the vendor
  defconfig, so enabling CMA pulls in no new subsystem.
- **Memory pressure is near-zero.** CMA memory is movable/reclaimable: until the
  driver claims a pool, the 16 MiB is available to the page allocator for movable
  allocations. It is not carved out of general use the way a fixed reserved-memory
  region would be.

**What could NOT be verified without a device boot** (honest boundary):

- That the reserved 16 MiB default CMA area actually lands and that
  `dma_alloc_attrs(FORCE_CONTIGUOUS)` then succeeds on *this* board at
  `mem=…` — the source path is fully traced (arm64 `dma_contiguous_reserve()` →
  `dma_contiguous_default_area` → `dev_get_cma_area()` fallback), but the
  allocation itself is only confirmable on-device (step B4 below).
- The exact, reliable way to *force* a slot-B boot on this unit (the SPL's
  slot-register behaviour at cold boot). The mechanism and a candidate method are
  documented below, but the human must confirm it over serial (look for
  `From slotb boot`). If forcing slot B proves unreliable, fall back to approach
  (2) or to an interactive-U-Boot build — neither is needed if the register
  method works.

---

## Flash + bring-up plan (reversible)

Legend: **[HOST]** = the build box; **[DEVICE]** = over SSH on the NanoKVM-Pro;
**[SERIAL]** = UART0 console (`ttyS0`, 115200), needed to *watch* the slot boot;
**[HUMAN]** = only the owner can do this (physical/flash/serial).

### A. Build + stage the artifact — [HOST]

```
nix build .#kernel-slot-image-cma -L
# → result/kernel_b.bin  (ax_gzip -9 + 1 KB signed header; magic 0x55543322 @ off 4)
```

Sanity (host): `result/kernel_b.bin` is < 64 MB and its `FLASH-NOTES.txt` names
`kernel_b` / `/dev/mmcblk0p15`.

### B. Flash slot B + boot it — [HUMAN]/[DEVICE]/[SERIAL]

> `mmcblk0` is eMMC. **Never write `mmcblk0p14` (slot A) or any other partition.**
> Only `mmcblk0p15` (`kernel_b`) is written here. Back it up first so the test is
> perfectly reversible even at the partition level.

1. **Back up the current `kernel_b`** (so slot B itself is restorable):
   ```
   # [DEVICE]
   dd if=/dev/mmcblk0p15 of=/tmp/kernel_b.stock.img bs=1M
   ```
   Copy it to the host; verify magic `2233 5455` at offset 4
   (`xxd -s4 -l4 /tmp/kernel_b.stock.img`).

2. **Write the CMA kernel to `kernel_b`** (`/dev/mmcblk0p15`) and hash-verify —
   drop caches before read-back so you verify the medium, not the page cache:
   ```
   # copy result/kernel_b.bin to the device first (tools/kvmscp), then [DEVICE]:
   dd if=/root/kernel_b.bin of=/dev/mmcblk0p15 bs=1M conv=fsync
   sync; echo 3 > /proc/sys/vm/drop_caches
   sz=$(stat -c%s /root/kernel_b.bin)
   cmp -n "$sz" /root/kernel_b.bin /dev/mmcblk0p15 && echo "VERIFY OK"
   ```

3. **Force a slot-B boot, then reboot.** Slot selection: U-Boot's
   `set_slot_ab()` (`arch/arm/mach-axera/ax620e/ax620e.c`) reads
   `TOP_CHIPMODE_GLB_BACKUP0` = **`0x02390024`** and sets env `bootsystem` from it
   (`SLOTA=BIT(2)=0x4`, `SLOTB=BIT(3)=0x8`); `do_axera_boot()`
   (`cmd/axera/boot/axera_boot.c`) then loads `kernel_b`+`dtb_b` when
   `bootsystem=="B"`. The register has write-1-to-set / write-1-to-clear aliases
   `_SET=0x02390028` / `_CLR=0x0239002C`. Candidate method from Linux (uses
   busybox `devmem`; confirm the tool exists on the rootfs):
   ```
   # [DEVICE] select slot B: set SLOTB, clear SLOTA
   devmem 0x02390028 32 0x8    # BACKUP0_SET  <- SLOTB
   devmem 0x0239002C 32 0x4    # BACKUP0_CLR  <- SLOTA
   reboot
   ```
   **[SERIAL] confirm** the U-Boot log prints `From slotb boot` (and that the
   kernel banner/boot proceeds). If it prints `From slota boot`, the SPL
   re-derived the slot before U-Boot read it — do not proceed; see the honest
   boundary above. (`bootdelay=0`, so there is no interactive U-Boot prompt; the
   register is the lever.)

4. **[DEVICE] confirm CMA is active** on the booted kernel:
   ```
   grep Cma /proc/meminfo        # expect CmaTotal:  ~16384 kB
   dmesg | grep -i cma           # expect: "cma: Reserved 16 MiB at 0x..."
   uname -r                      # 4.19.125 (unchanged)
   ```

### C. Path-B open-driver bring-up — [DEVICE] (RISKY, serialized session)

This conflicts with the vendor encoder modules and must follow the device safety
envelope. `vcmd_reserve_IO` does `request_mem_region(0x04010000)`, which the
loaded vendor `ax_venc` holds (`04010000-… : vsi_vcx`), so the vendor venc/jenc
must be unloaded first (refcount clears with the app stopped):

```
# [DEVICE]
systemctl stop nanokvm            # release the encoder
rmmod ax_jenc ax_venc             # free the vsi_vcx mem region + core
insmod /path/to/ax630c_venc_vcmd.ko   # nix build .#vc8000-vcmd -> ax630c_venc_vcmd.ko
dmesg | tail -20
# SUCCESS looks like: "ax630c-venc-vcmd: VC8000E VCMD driver initialised (base 0x4010000)"
#   and NO "dma_alloc_attrs(2097152) FAILED (no CMA?)" / "vcmd_mem_init failed (-12)".
```

A clean `vcmd_mem_init` (three 2 MB coherent pools allocated) is the milestone
this flash exists to reach. Driving one IDR through
`RESERVE→LINK→WAIT→RELEASE` is the next step (`#45` open EWL) and is out of scope
here.

### D. Rollback — [HUMAN]/[DEVICE]/[SERIAL]

Slot A was never written, so rollback is a slot switch:

```
# [DEVICE] select slot A again
devmem 0x02390028 32 0x4    # BACKUP0_SET  <- SLOTA
devmem 0x0239002C 32 0x8    # BACKUP0_CLR  <- SLOTB
reboot
# [SERIAL] confirm "From slota boot"
```

To also restore `kernel_b` to stock, `dd` `/tmp/kernel_b.stock.img` back to
`/dev/mmcblk0p15` (same verify-with-drop-caches discipline). If a slot-B boot
ever hangs before Linux, the SPL/watchdog failover or a physical AXDL re-flash
recovers the unit (`docs/flashing-and-recovery.md`); slot A remains intact
throughout.

---

## Why not just make this the default kernel?

The shipping kernel is deliberately left byte-identical: this is a purpose-built
bring-up kernel for a reversible slot-B experiment, not a firmware change. Once
the open encoder path is proven end-to-end on the CMA kernel and integrated
(`#44`/`#45`/`#25`), folding `CONFIG_CMA` into the default `.#kernel` (and sizing
the area to the final pool footprint) is a small, separately-reviewed follow-up.
