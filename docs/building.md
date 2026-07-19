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
- A dev box that is `x86_64-linux` (the default, cross-compiles to aarch64) or
  `aarch64-linux` (native). No exotic toolchain is required — stock nixpkgs
  aarch64 glibc GCC is sufficient.
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
| `ax-ko-blobs` | prebuilt `ax_*.ko` | pinned blob install |
| `kvm-encoder` | `libkvm.so` / `.so.0` | our from-source capture+encode backend |
| `nanokvm-web` | React `dist/` bundle | pnpm-hash pinned |
| `nanokvm-server` | `NanoKVM-Server` (aarch64) | Go+cgo, links libkvm+libopus; vendorHash pinned |
| `kernel` | `Image` + `dtbs` + modules + `lt6911_manage.ko` | Linux 4.19.125 |
| `dtb` / `dtb-sd` | patched board DTB (eMMC / SD-root) | reserved-mem + bootargs patch |
| `dtb-slot-image` / `-sd` | signed `dtb.img` partition | `ax_gzip -9` + 1 KB header |
| `kernel-slot-image` | signed kernel partition | `ax_gzip -9` + 1 KB header |
| `boot` / `boot-sd` | full boot chain (UART0 / UART1 console) | SPL+ATF+OP-TEE+U-Boot |
| `boot-fsbl/atf/optee/uboot` | boot-chain subsets | selectors over `boot` |
| `base-axp` | pinned vendor v1.0.15 `.axp` | 1.4 GB FOD (overlay base) |
| `rootfs` | overlaid `ubuntu_rootfs_sparse.ext4` | vendor base + our libkvm + modules + service selection |
| **`firmware-image`** | **`…-selfbuilt.axp`** | **the flashable eMMC image (default output)** |
| `sd-image` | `…-sdcard.img` | non-destructive microSD boot image |
| `axdl` | `axdl-cli` host flasher | built for the dev/host system, not cross |
| `toolchain` | cross-gcc bundle | convenience `buildEnv` |

---

## Build DAG

```
axera-libs ─┬─> kvm-encoder ──> nanokvm-server ─┐
            │                                    ├─> rootfs ──> firmware-image
ax-ko-blobs ┼──────────────────────> kernel ─────┤              ▲
            │                    nanokvm-web ─────┘              │
boot ───────┴──> {kernel,dtb}-slot-image ──────────────────────┘
```

`nix flake check` evaluates the whole tree without building the heavy leaves.

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
| `pkgs/nanokvm-server.nix` | `vendorHash` | `server/go.mod` / `go.sum` change |
| `pkgs/nanokvm-web.nix` | `pnpmDeps.hash` | the web `pnpm-lock.yaml` changes |

The `base-axp` FOD hash changes only if you re-pin a different vendor release
(`pkgs/base-axp.nix`, `version = "1.0.15"`).

---

## Cross-compile notes

- Outputs are keyed off the **build/dev** system; `crossPkgs` is
  `pkgsCross.aarch64-multiplatform` on x86_64, or a native no-op on aarch64.
- **Go/cgo:** use `crossPkgs.buildGoModule` (the cross-capable `go`). Overriding
  it with a native `pkgs.go_*` breaks cgo (native go passes `-m64` to the aarch64
  gcc). `GOEXPERIMENT=boringcrypto` is kept for parity with upstream `build.sh`.
- **cgo link:** the server links our real `libkvm.so` (`-L../dl_lib -lkvm`) and
  `libopus`. `libkvm` pulls in the full AX graph, so the build adds
  `-Wl,-rpath-link,${axera-libs}/lib` so `ld` can *resolve* the transitive
  `libax_engine` (via `libax_proton`) at link time **without** adding it as
  `DT_NEEDED` to the server binary. On-device those libs load from `/opt/lib`.
- **libkvm rpath:** `kvm-encoder.nix` uses `patchelf --force-rpath` to emit
  `DT_RPATH` (transitive), not `DT_RUNPATH`. This is load-bearing — see
  [architecture.md](architecture.md#the-videoaudio-pipeline-our-libkvm).
- **Vendor triples:** the SDK Makefiles expect `aarch64-none-linux-gnu-`; nixpkgs
  is `aarch64-unknown-linux-gnu-`. `CROSS_COMPILE` is passed explicitly.

---

## `ax_*.ko` vermagic

The prebuilt Axera media modules must `insmod` into our **from-source** kernel, so
the kernel's `vermagic` (kernel version + key `CONFIG_*` + compiler) has to line up
with what the blobs were built against. `kernel.nix` builds against the vendor
`axera_AX630C_emmc_arm64_k419_sipeed_nanokvm_defconfig` for this reason;
`rootfs.nix` merges the blobs into `/lib/modules/4.19.125/` and re-runs `depmod`
on a host staging tree so the dependency graph
(`ax_venc → ax_base/ax_pool/ax_cmm/ax_sys`, plus `lt6911_manage`) resolves on the
target with no on-device `depmod`. The build asserts those edges exist.

---

## Heavy builds & caching

- `base-axp` is a **1.4 GB** fixed-output fetch; `rootfs` de-sparses it to a
  multi-GB raw ext4, edits it with `debugfs`, then re-sparses. Budget disk + time.
- `nix flake check` and `nix build` of the light leaves (`axera-libs`,
  `ax-ko-blobs`, `kvm-encoder`, `nanokvm-web`) are fast and are the right
  inner-loop targets when iterating on the app/encoder layer.
- riscv64 is irrelevant here (that's the other, SG2002 project); this target is
  plain aarch64 and builds with the standard nixpkgs cross set.
