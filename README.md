# nix-nanokvm-pro

A Nix flake that builds an **open, self-built firmware image for the Sipeed
NanoKVM-Pro** (Axera **AX630C**, ARM Cortex-A53, aarch64/glibc). The boot chain,
kernel, and application layer are built **from source**; Axera's redistributable
media libraries (`libax_*.so`, BSD-3) and the prebuilt `ax_*.ko` media kernel
modules are **pinned as binary inputs**. The goal is an open, reproducible
firmware that *links* the accepted Axera blobs — not a blob-free build.

> **Source of truth for the video path:** `../PLAN.md` (the "NanoKVM-Pro"
> sections). It holds the bill of materials, on-device recon, the resolved
> MIPI/VIN/VENC capture config, and the build-option analysis. This README
> describes only the *flake structure*.

> **Status:** this is a **STRUCTURE/DESIGN pass**. Light derivations build; the
> heavy ones (kernel, boot chain, image assembly) are documented derivations
> with correct sources + approach + TODOs, deliberately **not** compiled yet.
> See [Build status](#build-status).

---

## Architecture

Cross-compiled from `x86_64-linux` via nixpkgs `pkgsCross.aarch64-multiplatform`
(stock aarch64 glibc GCC — **no exotic toolchain**, unlike the SG2002/T-Head
RISC-V target). Outputs are keyed off the dev/build system; the firmware target
is always aarch64.

```
flake.nix
  inputs:
    nixpkgs (unstable), flake-utils
    maix_ax620e_sdk        (boot chain + image pipeline + tools)   [from source]
    maix_ax620e_sdk_kernel (Linux 4.19.125 + DTS + lt6911; ax_*.ko blobs live here)
    maix_ax620e_sdk_msp    (libax_*.so + V3.0.0 headers)           [pinned blobs]
    nanokvm-pro-src        (Go server + React web, GPL-3.0)        [from source]
pkgs/
  toolchain.nix     cross gcc bundle + GCC-version caveats (kernel/boot)
  axera-libs.nix    install libax_*.so + headers                  [REAL, builds]
  ax-ko-blobs.nix   install prebuilt ax_*.ko                      [REAL, builds]
  boot-fsbl.nix     SPL + DDR init      (boot/bl1)                [STUB]
  boot-atf.nix      TF-A 2.7 BL31       (boot/atf)                [STUB]
  boot-optee.nix    OP-TEE 3.21         (boot/optee)              [STUB]
  boot-uboot.nix    U-Boot 2020.04+fdl2 (boot/uboot)              [STUB]
  kernel.nix        Linux 4.19.125 + DTS + lt6911_manage.ko       [STUB, slow]
  kvm-encoder.nix   libkvm.so (kvm_vision.h backend)              [REAL, builds]
  nanokvm-server.nix Go+cgo, links libkvm+libopus                 [needs vendorHash]
  nanokvm-web.nix   React/Vite static bundle                      [REAL, needs pnpm hash]
  rootfs.nix        Ubuntu 22.04 arm64 base (design doc)          [STUB]
  image.nix         17-partition .axp/.img assembly (layout doc)  [STUB]
  devshell.nix      cross toolchain + SDK/image tooling
```

## From-source vs pinned-blob

| Component | Provenance | License |
|---|---|---|
| FSBL/SPL + DDR init, TF-A, OP-TEE, U-Boot | **from source** (maix_ax620e_sdk) | GPL/BSD |
| Linux 4.19.125 kernel + DTS | **from source** (maix_ax620e_sdk_kernel) | GPL-2.0 |
| `lt6911_manage.ko` (HDMI bridge) | **from source** (open GPL) | GPL-2.0 |
| `ax_*.ko` media modules (venc/mipi/proton/ivps/...) | **pinned blob** (in kernel repo) | GPL-tagged, source not published |
| `libax_*.so`, `libsns_dummy.so` | **pinned blob** (msp repo) | BSD-3, redistributable |
| `libkvm.so` (our encode backend) | **from source** (our open reimpl. over AX MPI) | ours / GPL-3 app |
| NanoKVM-Server (Go) | **from source** | GPL-3.0 |
| Web UI (React) | **from source** | GPL-3.0 |
| Rootfs base | **pinned** Ubuntu 22.04 arm64 (v1 decision) | mixed |

## Build order (dependency DAG)

```
axera-libs ─┬─> kvm-encoder ──> nanokvm-server ─┐
            │                                    ├─> rootfs ──> firmware-image
ax-ko-blobs ┼────────────────────────────────────┤              ▲
kernel ─────┤                    nanokvm-web ─────┘              │
boot-{fsbl,atf,optee,uboot} ───────────────────────────────────┘
```

## Build status

| Package | State | Notes |
|---|---|---|
| `axera-libs` | **builds** | copies `out/arm64_glibc/{lib,include}` from msp repo |
| `ax-ko-blobs` | **builds** | copies `osdrv/out/.../ko/ax_*.ko` |
| `kvm-encoder` | **builds** | cross-compiles our **REAL** open capture+encode backend (`libkvm.c` + `kvm_pipeline.c` over the Axera MPI: MIPI_RX→VIN→ISP-bypass→AX_VENC) → aarch64 `libkvm.so`/`.so.0`, SONAME + AX_* NEEDED. Source in `pkgs/kvm-encoder/src/` is a **snapshot** of `scratchpad/capture-poc/` — **re-sync after the CMM-teardown fix lands** (see kvm-encoder.nix header) |
| `toolchain` | **builds** | buildEnv bundle |
| `nanokvm-web` | **builds** | pnpm hash pinned; emits a real Vite `dist/` bundle |
| `nanokvm-server` | **builds** | vendorHash pinned; cross cgo → real aarch64 `NanoKVM-Server` ELF linking the **real** libkvm (`libkvm.so.0` NEEDED) + libopus; `-rpath-link` to axera-libs resolves libkvm's transitive AX graph at link time |
| `boot-fsbl/atf/optee/uboot` | **stub** | evaluate; buildPhase documents real commands + `exit 1` |
| `kernel` | **stub** | evaluate; slow build intentionally not run |
| `rootfs` | **stub** | Option A/B design doc |
| `firmware-image` | **stub** | 17-partition layout + tooling doc |

`nix flake check` evaluates the whole tree (all derivations are valid); it does
not *build* the packages, so the stubs don't block it.

## Open design decisions (flagged assumptions)

1. **Rev pins.** All four SDK inputs are pinned to `main` HEAD as of 2026-07-17,
   **not** release tags. The msp HEAD matches the on-device V3.0.0_20250319 libs.
   **TODO:** re-pin to a tagged SDK release for reproducibility.
2. **Toolchain / GCC.** Stock nixpkgs aarch64 cross GCC. Kernel 4.19.125 wants an
   older GCC than bleeding-edge — try `gcc12`, fall back `gcc10`; boot chain used
   vendor `gcc-arm-9.2` / app uses ARM GNU 12.2. Vendor triple is
   `aarch64-none-linux-gnu-`; nixpkgs is `aarch64-unknown-linux-gnu-` — pass
   `CROSS_COMPILE` explicitly to the SDK Makefiles.
3. **`ax_*.ko` vermagic.** Prebuilt blobs must load into the from-source kernel:
   match the vendor defconfig + GCC so vermagic aligns, or `--force-vermagic`.
4. **Rootfs.** **Option A (Ubuntu 22.04 arm64, vendor default) chosen for v1**
   (lowest risk, matches on-device ABI/systemd layout). Option B (pure nix-built
   rootfs) is the north star; deferred. See `pkgs/rootfs.nix`.
5. **Image format.** Primary = Axera `.axp` (AXDL flash), plus raw `.img`.
   17 fixed A/B partitions on eMMC; layout + tools documented in `pkgs/image.nix`.
   Fastest bootstrap: run the vendor `make ... axp` once, then nix-ify piecewise.
6. **`vendorHash` / `pnpmDeps.hash`** are now pinned (computed 2026-07-17).
   Regenerate if `go.mod` / the pnpm lockfile change (set to `lib.fakeHash`,
   rebuild, paste the printed hash).
7. **Secure boot** enforcement on retail units is **UNVERIFIED** (PLAN.md). Boot
   derivations default to the unsigned path; if efuse enforces, keys are needed.

## Usage

```bash
# Evaluate the whole skeleton
nix flake check

# The packages that build today
nix build .#axera-libs
nix build .#ax-ko-blobs
nix build .#kvm-encoder

# Quick win (after pasting the printed pnpm hash into pkgs/nanokvm-web.nix)
nix build .#nanokvm-web

# Go server (after pasting the printed vendorHash into pkgs/nanokvm-server.nix)
nix build .#nanokvm-server

# Dev shell (cross toolchain + SDK/image tooling)
nix develop
```

## SD-card boot (non-destructive test path)

`nix build .#sd-image` produces a **`dd`-able raw microSD image**
(`<out>/AX630C_..._sipeed_nanokvm-sdcard.img`) that boots the **entire
from-source stack** (SD SPL + DDR-init + ATF + OP-TEE + U-Boot + kernel + dtb +
overlaid rootfs) **from the SD/TF slot, leaving eMMC untouched**. To boot it you
**hold the `User` button while applying power** (see caveat below); revert by
powering on normally. See `pkgs/sd-image.nix` for the full derivation notes.

**How SD boot works on the AX630C (from SDK source):** the BootROM's SD path is
*file-based*, not raw-offset. It reads an MBR table, mounts the first **FAT32**
partition and loads **`boot.bin`** (the `boot/bl1/sd` SPL variant, which links
FatFS + the SD mmc driver). That SPL then loads each later stage as a *named
file* from the same FAT partition — the names are the SPL's own table
(`boot/bl1/core/boot/boot.c` `sd_img_name[]`): `ddrinit.img`, `atf.img`,
`uboot.bin`, `optee.img`, `dtb.img`, `kernel.img`; rootfs is p2 (ext4). This
mirrors the vendor's own `gen_sd_image.sh` for this exact board (MBR: 1 MiB gap,
p1 FAT32 128 MiB boot, p2 ext4 rootfs), rebuilt with **no root** (mtools + the
raw ext4 from `rootfs.nix` + `sfdisk`).

**SD SPL size fix (from source):** the `boot/bl1/sd` SPL links FatFS on top of
the normal SPL and under gcc13 overflowed the sign tool's hard **50 K (51200 B)**
slot by 248 B (51448 B). `pkgs/boot.nix` now compiles it with
`-ffunction-sections -fdata-sections --gc-sections`, dropping it to **48460 B**
(2740 B headroom) — **no vendor blob needed**; a build-time guard fails loudly if
it ever creeps back over 51200 B.

```bash
nix build .#sd-image
# Write it (PICK THE RIGHT DEVICE — destructive to the CARD only):
lsblk                                   # find the removable card, e.g. /dev/sdX
sudo dd if=result/AX630C_emmc_arm64_k419_sipeed_nanokvm-sdcard.img \
        of=/dev/sdX bs=4M oflag=direct conv=fsync status=progress
sync
# Insert card, then HOLD the `User` button while applying power, release it
# right away -> boots self-built firmware from SD.
# Revert: power on WITHOUT holding `User` (and/or remove card) -> stock eMMC.
```

> **Gating caveat — SD boot needs a button hold, it is NOT auto-on-insert**
> (HIGH confidence: [Sipeed NanoKVM-Pro wiki](https://wiki.sipeed.com/hardware/en/kvm/NanoKVM_Pro/faq.html)).
> The AX630C latches its boot source from the `CHIP_MODE` strap at reset; on the
> NanoKVM-Pro that strap is the **`User` button**. **Hold `User` while applying
> power, then release** to boot the SD card. A normal power-on **always** boots
> eMMC regardless of card presence — so revert is just a normal power-on (and/or
> pull the card); **eMMC is never written**. (Holding `User` *longer* enters USB
> download mode, so release it right after power comes on.) This matches the SPL
> source: `spl_main.c` only trusts a ROM-set `is_sd_boot` flag from
> `chip_mode[0]` (`USB_DL_SD_BOOT`); it never probes mmc1-vs-mmc0. Consequence:
> this is a **manually-triggered** SD boot/recovery path, not an unattended
> insert-and-go appliance boot.

## What a follow-up pass must do

- **kernel.nix**: locate the `*nanokvm*` arm64 defconfig, build `Image`+`dtbs`+
  `modules` + `lt6911_manage.ko`; match vermagic to the `ax_*.ko` blobs.
- **boot-\***: drive the SDK `build/` system (`make p=<project> ...`) in a
  writable tree with our `CROSS_COMPILE`; collect signed/unsigned blobs.
- **kvm-encoder.nix**: DONE — now cross-builds our real `libkvm.c`+`kvm_pipeline.c`
  backend (`-lax_venc -lax_sys -lax_proton -lax_mipi -lax_ivps -ldl -lpthread`).
  **Remaining TODO:** re-sync `pkgs/kvm-encoder/src/` from `scratchpad/capture-poc/`
  once the concurrent CMM-teardown fix lands (`cp libkvm.c kvm_pipeline.{c,h}` +
  `server/include/kvm_vision.h`), then `nix build .#kvm-encoder`.
- **nanokvm-server.nix / nanokvm-web.nix**: pin the real `vendorHash` / pnpm hash.
- **rootfs.nix + image.nix**: assemble Option-A rootfs, populate `/opt/lib`,
  modules, app; pack the 17-partition `.axp` + raw `.img`.
```
