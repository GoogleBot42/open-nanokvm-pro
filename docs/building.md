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
| `boot` / `boot-sd` | full boot chain (UART0 / UART1 console) | SPL+ATF+OP-TEE+U-Boot |
| `boot-fsbl/atf/optee/uboot` | boot-chain subsets | selectors over `boot` |
| `base-axp` | pinned vendor v1.0.15 `.axp` | 1.4 GB FOD (overlay base) |
| `rootfs` | overlaid `ubuntu_rootfs_sparse.ext4` | vendor base + our libkvm + modules + service selection |
| `nixos-rootfs` | NixOS `ext4` (+ sparse) | **scaffold, never booted** — pure-Nix rootfs, issue #26; built from the separate `nixpkgs-rootfs` pin. See [nixos-rootfs.md](nixos-rootfs.md) |
| **`firmware-image`** | **`…-selfbuilt.axp`** | **the flashable eMMC image (default output)** |
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
| `pkgs/nanokvm-web.nix` | `pnpmDeps.hash` | `web/pnpm-lock.yaml` changes |

The `base-axp` FOD hash changes only if you re-pin a different vendor release
(`pkgs/base-axp.nix`, `version = "1.0.15"`).

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
