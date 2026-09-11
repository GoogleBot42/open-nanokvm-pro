# Building

How to build the firmware and its components with the flake. For what the pieces
*are*, see [architecture.md](architecture.md); for flashing the output, see
[flashing-and-recovery.md](flashing-and-recovery.md).

- [Prerequisites](#prerequisites)
- [Packages](#packages)
- [Build DAG](#build-dag)
- [Building the firmware image](#building-the-firmware-image)
- [Pinned hashes](#pinned-hashes)
- [Cross-compile notes](#cross-compile-notes)
- [`ax_*.ko` vermagic](#ax_ko-vermagic)
- [Heavy builds & caching](#heavy-builds--caching)

---

## Prerequisites

- Nix with flakes enabled (`experimental-features = nix-command flakes`).
- An `x86_64-linux` dev box (cross-compiles to aarch64; the vendor `ax_gzip`
  partition packer is an x86-64-only static ELF, so the flashable outputs
  cannot build on an aarch64 host). No exotic toolchain is required — stock
  nixpkgs aarch64 glibc GCC is sufficient.
- Disk + patience for the heavy derivations (see [below](#heavy-builds--caching)):
  the base `.axp` is a 1.4 GB fixed-output fetch and the rootfs de-sparses to a
  multi-GB ext4.

```bash
nix flake show          # list all outputs
nix develop             # dev shell: cross toolchain + SDK/image tooling + axdl
```

---

## Packages

All are `nix build .#<name>`. State reflects the current tree.

| Package | Output | Notes |
|---|---|---|
| `axera-libs` | `libax_*.so` + V3.0.0 headers | pinned blob install (msp repo) |
| `ax-ko-blobs` | prebuilt `ax_*.ko` | pinned blob install; **not shipped** — the vendor modules are deleted from the image (#54). Bench/harness reference only |
| `kvm-encoder` | `libkvm.so` / `.so.0` | the original vendor-MPI backend (links `libax_*`); reference/fallback only |
| **`kvm-encoder-v4l2`** | `libkvm.so` / `.so.0` | **the shipped backend** — V4L2 capture + open VC8000E encode, zero `libax_*`. `kvm-encoder-open`/`-openvenc` are the earlier open variants (raw-ioctl capture against the vendor closure) |
| `vc8000-vcmd` | `ax630c_venc_vcmd.ko` | our open VC8000E VCMD encode driver (replaces `ax_venc`/`ax_jenc`) |
| `open-vin-csi2` | `open_vin_csi2.ko` | our open MIPI CSI-2 / D-PHY receiver |
| `open-vin-capture` | `open_vin_capture.ko` | our open VIN/IFE bypass capture driver → V4L2 `/dev/video0` |
| `nanokvm-web` | React `dist/` bundle | built from our in-tree fork `web/`; pnpm-hash pinned |
| `nanokvm-server` | `NanoKVM-Server` (aarch64) | Go+cgo, links libkvm+libopus; vendorHash pinned |
| `kernel` | `Image` + `dtbs` + modules + `lt6911_manage.ko` | Linux 4.19.125 |
| `dtb` / `dtb-sd` | patched board DTB (eMMC / SD-root) | reserved-mem + bootargs patch |
| `dtb-slot-image` / `-sd` | signed `dtb.img` partition | `ax_gzip -9` + 1 KB header |
| `kernel-slot-image` | signed kernel partition | `ax_gzip -9` + 1 KB header |
| `kernel-mainline` | `Image` + `dt-bindings` headers | mainline Linux 7.1.3 from the nixpkgs pin, `arm64 defconfig` + `pkgs/kernel-mainline/ax630c.config`. **Boots this board since #75.** Variants: `-appliance` (NixOS stage 1 embedded), `-appliance-loop`, `-appliance-qemu`. Epic #26 |
| `dtb-mainline` | our own board DTB | compiled from `dts/` **in this repo** with `cpp` + `dtc -p 4096`; nothing vendor about it |
| `kernel-mainline-slot-image` / `dtb-mainline-slot-image` | signed slot-B partitions | same header format as above, so #75's first boot is a reversible slot-B flash |
| `boot` / `boot-sd` | full boot chain (UART0 / UART1 console) | SPL+ATF+OP-TEE+U-Boot. Three deltas to the vendor U-Boot defconfig, all applied in `pkgs/boot.nix`'s `configurePhase`: `CONFIG_SUPPORT_AB=y` (A/B slot), `CONFIG_CMD_AXERA_CIPHER` + `CONFIG_AXERA_SECURE_BOOT` **off** (they linked in 78 KB of closed EIP-130 crypto-engine firmware; #90), and `CONFIG_CONS_INDEX=2` under `sdConsoleUart1` only. The install phase build-asserts the EIP-130 firmware is absent from every output |
| `boot-fsbl/atf/optee/uboot` | boot-chain subsets | selectors over `boot` |
| `base-axp` | pinned vendor v1.0.15 `.axp` | 1.4 GB FOD (overlay base) |
| `rootfs` | overlaid `ubuntu_rootfs_sparse.ext4` | vendor base + our libkvm + modules + service selection |
| `nixos-appliance` | NixOS `ext4` (+ sparse, + the generation's `/boot` tree) | the pure-Nix rootfs, #78. One nixpkgs pin, mainline kernel, **boot-proven on hardware from slot B**. See [nixos-rootfs.md](nixos-rootfs.md) |
| **`firmware-image`** | **`…-selfbuilt.axp`** | **the flashable eMMC image (default output)** |
| **`nixos-firmware-image`** | **`…-nixos.axp`** | **the NixOS appliance's flashable eMMC image** — packed from scratch, no vendor bundle; `system.build.axpImage` on `nixosConfigurations.nanokvm-pro` |
| `uboot-env` / `logo` / `bootfs` | `env` / `logo` / `boot` partition images | the three stored partitions the overlay image still inherited from Sipeed. `bootfs` carries the `/boot` tree NixOS's own extlinux builder wrote for the imaged generation (#99) and asserts room for `configurationLimit + 1` of them |
| **`system-bundle`** | `nanokvm_pro_sys_<ver>.tar.gz` + `nanokvm_pro_sys_latest.json` | **the update artefact** — the appliance's whole store closure — kernel, initrd and dtb included as store paths since #99 — ~450 MB. What a release publishes and what `nanokvm-update` installs. [updates.md](updates.md) |
| `sd-image` | `…-sdcard.img` | non-destructive microSD boot image |
| `axdl` | `axdl-cli` host flasher | built for the dev/host system, not cross |
| `toolchain` | cross-gcc bundle | convenience `buildEnv` |

---

## Build DAG

```
axera-libs ──> kvm-encoder-v4l2 ──> nanokvm-server ─┐
nanokvm-web ────────────────────────────────────────┤
kernel ─┬───────────────────────────────────────────┤
        ├──> vc8000-vcmd ───────────────────────────┼─> rootfs ──> firmware-image
        ├──> open-vin-csi2 ─────────────────────────┤                 ▲
        └──> open-vin-capture ──────────────────────┘                 │
boot ──────> {kernel,dtb}-slot-image ─────────────────────────────────┘
```

(`ax-ko-blobs` is a pinned reference for the vendor `ax_*.ko`; nothing in the
image path builds from it.)

`nix flake check` evaluates the whole tree without building the heavy leaves.
Five of its gates belong to the update and boot path (#86, #99) and are worth
running by name after touching anything under `nixos/lib/`, `pkgs/bootfs.nix`
or `pkgs/system-bundle*`:

```bash
nix build .#checks.x86_64-linux.nanokvm-updater-loop -L        # the update loop, run for real
nix build .#checks.x86_64-linux.nanokvm-update-idle -L         # the checkbox and the idle gate
nix build .#checks.x86_64-linux.nanokvm-mark-good-fallback -L  # the derived rollback config
nix build .#checks.x86_64-linux.nanokvm-boot-dir -L            # the /boot NixOS writes
nix build .#checks.x86_64-linux.nanokvm-system-bundle -L       # the artefact, read back
```

---

## Building the firmware image

```bash
nix build .#firmware-image
# -> result/AX630C_emmc_arm64_k419_sipeed_nanokvm-selfbuilt.axp
```

`image.nix` does a **streaming zip-rewrite** of the pinned base `.axp`, swapping
in our from-source boot chain, signed kernel/dtb partitions, and the overlaid
rootfs — a pure userspace ZIP rewrite (no sudo/mount/chroot). It fails loudly if
any expected swap target is missing from the base `.axp` central directory.

Flash it per [flashing-and-recovery.md](flashing-and-recovery.md).

---

## Pinned hashes

Two fixed-output hashes must be regenerated when their inputs change (set the
field to `pkgs.lib.fakeHash`, rebuild, paste the printed hash back):

| Where | Field | Regenerate when |
|---|---|---|
| `pkgs/nanokvm-server.nix` | `vendorHash` | `server/go.mod` / `go.sum` change, **or `postPatch` changes a Go import** |
| `pkgs/nanokvm-web.nix` | `pnpmDeps.hash` | `web/pnpm-lock.yaml` changes |

The `base-axp` FOD hash changes only if you re-pin a different vendor release
(`pkgs/base-axp.nix`, `version = "1.0.15"`).

`buildGoModule`'s go-modules derivation inherits `postPatch`, so every patch that
adds or removes an import moves `vendorHash` — not just a `go.mod` bump. `go mod
vendor` vendors only the packages the main module actually imports.

**A stale FOD hash is invisible on any host that already has the output.** A
fixed-output derivation's store path comes from its hash alone, so a machine that
once realised that path reuses it and never re-runs the fetch: the build stays
green locally while a fresh runner refetches, gets different content, and dies
with `hash mismatch`. That killed the v2.1.0-alpha.5 release build — the
`vendorHash` had been stale since #71 (2026-09-05) dropped the
`github.com/gin-gonic/contrib/static` import in `postPatch`, and every local
build since had been reusing the July vendor tree.

So validate the release-critical FODs honestly before cutting a release:

```sh
nix build --rebuild "$(nix derivation show .#nanokvm-server \
  | grep -o '/nix/store/[a-z0-9]*-[^"]*-go-modules-[^"]*\.drv')^out"
```

`--rebuild` re-runs the fetch and compares, so drift fails here instead of on the
runner. Setting the field to `pkgs.lib.fakeHash` and rebuilding gets the same
answer.

---

## Cross-compile notes

- `crossPkgs` is `pkgsCross.aarch64-multiplatform`; the flake's only supported
  build system is `x86_64-linux` (`ax_gzip` is an x86-64-only static ELF).
- **Go/cgo:** use `crossPkgs.buildGoModule` (the cross-capable `go`). Overriding
  it with a native `pkgs.go_*` breaks cgo (native go passes `-m64` to the aarch64
  gcc). `GOEXPERIMENT=boringcrypto` is kept for parity with upstream `build.sh`.
- **cgo link:** the server links our real `libkvm.so` (`-L../dl_lib -lkvm`) and
  `libopus`. The shipped `kvm-encoder-v4l2` pulls in no AX graph at all; the
  build keeps `-Wl,-rpath-link,${axera-libs}/lib` so `ld` can still *resolve*
  the transitive `libax_engine` (via `libax_proton`) for the vendor-linked
  `kvm-encoder` variant **without** adding it as `DT_NEEDED` to the server binary.
- **libkvm rpath:** `kvm-encoder.nix` uses `patchelf --force-rpath` to emit
  `DT_RPATH` (transitive), not `DT_RUNPATH`. Moot for the shipped build (zero
  vendor libs), load-bearing the moment a `libax_*`-linking variant is deployed —
  see [architecture.md](architecture.md#the-videoaudio-pipeline-our-libkvm).
- **Vendor triples:** the SDK Makefiles expect `aarch64-none-linux-gnu-`; nixpkgs
  is `aarch64-unknown-linux-gnu-`. `CROSS_COMPILE` is passed explicitly.

---

## `ax_*.ko` vermagic

**Nothing shipped depends on this any more.** Our loader stopped insmod'ing the
prebuilt Axera media modules in #55 M3 (2026-09-02) — three from-source video
modules replace the whole set — and #54 (2026-09-03) deleted the blobs from the
image outright, so a flashed device carries no `ax_*.ko` at all. `vermagic` is
now purely a **bench-harness** concern: the `ax-load-drv.{openvenc,base-only}.sh`
variants insmod vendor blobs, and they only run on a device flashed with the
vendor `.axp`. When you do that, the kernel's `vermagic` (kernel version + key
`CONFIG_*` + compiler) has to line up with what those blobs were built against,
which is why `kernel.nix` still builds against the vendor
`axera_AX630C_emmc_arm64_k419_sipeed_nanokvm_defconfig`. And vermagic match is
not ABI safety — a config flag that adds `#ifdef` fields to a struct the blobs
touch still kills the boot; see [vcmd-cma-unblock.md](vcmd-cma-unblock.md).

The standing rule survives the purge: an `ax_*.ko` must **never** land under
`/lib/modules/4.19.125/`. `rootfs.nix` stages only the from-source modules
there and hard-fails if any `ax_*.ko` sneaks in — a merged tree gives them
`of:` modaliases, udev autoloads `ax_cmm` parameter-less, and the device
panic-loops (this bricked a unit once). On the bench, vendor blobs are reached
only by path from `/soc/ko`, with the required parameters.

---

## Heavy builds & caching

- `base-axp` is a **1.4 GB** fixed-output fetch; `rootfs` de-sparses it to a
  multi-GB raw ext4, edits it with `debugfs`, then re-sparses. Budget disk + time.
- `nix flake check` and `nix build` of the light leaves (`axera-libs`,
  `ax-ko-blobs`, `kvm-encoder`, `nanokvm-web`) are fast and are the right
  inner-loop targets when iterating on the app/encoder layer.
- riscv64 is irrelevant here (that's the other, SG2002 project); this target is
  plain aarch64 and builds with the standard nixpkgs cross set.
