# Building

How to build the firmware and its components with the flake. For what the pieces
*are*, see [architecture.md](architecture.md); for flashing the output, see
[flashing-and-recovery.md](flashing-and-recovery.md).

- [Prerequisites](#prerequisites)
- [Building the image](#building-the-image)
- [Packages](#packages)
- [Checks](#checks)
- [Pinned hashes](#pinned-hashes)
- [Cross-compile notes](#cross-compile-notes)
- [Caching](#caching)

---

## Prerequisites

- Nix with flakes enabled (`experimental-features = nix-command flakes`).
- An **`x86_64-linux`** dev box. This is the flake's only supported build
  system, and the reason is one prebuilt tool: Axera's `ax_gzip` partition
  packer (`tools/ax_gzip_tool/ax_gzip` in the SDK snapshot) is an **x86-64-only
  static ELF**, and every stage the default SPL loads must be axgzip'd — that
  SPL rejects a raw payload.
  **#95 has built the way out, but it is not the default yet.** The `-raw`
  variants (`.#spl-minimal-raw`, `.#atf-mainline-raw`, `.#uboot-mainline-raw`,
  `.#nixos-firmware-image-mainline-raw`) compile the SPL with
  `SUPPPORT_GZIPD=FALSE`, store `atf` and `uboot` uncompressed, use no prebuilt
  binary and declare `platforms = lib.platforms.linux`;
  `.#checks.<sys>.no-x86-blobs` asserts they carry no x86-64 ELF. They stay
  non-default until the raw chain has booted the board, because
  `.#nixos-firmware-image-mainline` is also the AXDL recovery image.
  `pkgs/boot.nix` (the FDL agents) already drops `ax_gzip` unconditionally.
- Cross-compilation to aarch64 uses the stock nixpkgs cross set; no exotic
  toolchain is needed.

```bash
nix flake show     # every output
nix develop        # dev shell: cross toolchain + SDK/image tooling + axdl
```

---

## Building the image

```bash
nix build .#nixos-firmware-image-mainline     # also `packages.default`
# -> result/AX630C_emmc_arm64_k419_sipeed_nanokvm-nixos_mainline.axp
```

That is the whole product: a `.axp` packed **from scratch** by
`nixos/lib/make-axp-image.nix` — there is no vendor bundle behind it, and every
partition it stores comes out of this flake. It is a function of a system
closure, called from inside the module system by `nixos/image-axp.nix`, so
`.#nixos-firmware-image-mainline` and
`.#nixosConfigurations.nanokvm-pro.config.system.build.axpImage` are one
derivation and the image can never disagree with the system it images.

Flash it per [flashing-and-recovery.md](flashing-and-recovery.md):

```bash
nix run .#axdl -- --file result/*.axp --wait-for-device
```

The appliance is also a first-class NixOS system, so ordinary tooling works:

```bash
nix build .#nixosConfigurations.nanokvm-pro.config.system.build.toplevel
nixos-rebuild switch --flake .#nanokvm-pro --target-host root@<device>
```

To watch a boot on a console — the real board has none — run the same appliance
under QEMU:

```bash
nix run .#nixos-appliance-qemu-run
```

---

## Packages

All are `nix build .#<name>`.

### The product

| Package | Output | Notes |
|---|---|---|
| **`nixos-firmware-image-mainline`** | `…-nixos_mainline.axp` | **the flashable eMMC image; `packages.default`** |
| `appliance-toplevel` | the appliance's system closure | what a release pushes to the binary cache, and what `nix copy --to ssh://` sends to a board |
| `system-manifest` | `nanokvm_pro_sys_latest.json` | the release artefact — a few hundred bytes naming the toplevel above. [updates.md](updates.md) |
| `nixos-appliance-mainline-chain` | rootfs ext4 (+ sparse) + the generation's `/boot` tree | the appliance itself, unpacked. `.eval` is the NixOS evaluation |
| `bootfs` | the `boot` partition image | 272 MiB ext4 carrying the `/boot` tree NixOS's extlinux builder wrote; asserts room for `configurationLimit + 1` generations |
| `nixos-appliance-qemu` / `-qemu-run` | the same appliance retargeted at `qemu-system-aarch64 -M virt` | where the NixOS half of a boot is proven before anything is written to the device |

### Boot chain

| Package | Output | Notes |
|---|---|---|
| `spl-minimal` | signed SPL | blob-free (empty firmware member, #90), compiled for this layout's byte offsets |
| `spl-minimal-eip` | signed SPL | the vendor-shaped container with the closed EIP-130 firmware spliced in. Kept as a `dd`-away fallback; no image stores it |
| `atf-mainline` | signed BL31 | upstream TF-A 2.15 + our `plat/axera/ax630c` |
| `uboot-mainline` | signed BL33 | upstream U-Boot 2026.07 + our 25-patch AX630C board port |
| `spl-minimal-raw` / `atf-mainline-raw` / `uboot-mainline-raw` / `nixos-firmware-image-mainline-raw` | the #95 chain | `SUPPPORT_GZIPD=FALSE` and the stages stored uncompressed — no `ax_gzip`, no prebuilt binary. **One set — never mix a `-raw` stage with a default one**: the SPL reads only the format it was compiled for, and either mismatch is a dark board with no console. Not yet on hardware; see [flashing-and-recovery.md](flashing-and-recovery.md#95-the-raw-boot-chain) |
| `uboot-env` | the `env` partition | generated from the mainline U-Boot's own compiled-in default, so partition and binary cannot disagree |
| `gpt-image` | primary + alternate GPT | generated from `nixos/lib/emmc-layout.nix` |
| `boot` | the vendor SDK boot chain | **nothing boots from it.** Two things come out: the FDL1/FDL2 download agents the flasher pushes into BootROM RAM, and the vendor `atf_bl31_signed.bin` the `atf-mainline` check compares its header against |

`atf-mainline-debug` and the `uboot-mainline-*` family are **diagnostics, never
shipped**. Reach for one when a stage dies before it can say anything:

| Variant | What it adds |
|---|---|
| `atf-mainline-debug` | seven milestone-bit writes through BL31 |
| `uboot-mainline-debug` | milestone writes through every `board_init_r` hook. Writes bits 12–20, which are Linux's in the shipping assignment |
| `uboot-mainline-console` | the pre-console capture and nothing that writes the slot register — the variant to reach for on this board |
| `uboot-mainline-trace` | the shipping image with the console redirected into the pre-console buffer from `board_late_init()` |
| `uboot-mainline-tee` | every console write *also* copied into the buffer; takes nothing away |
| `uboot-mainline-probe` | `tee` plus a one-shot eMMC interrogation in `preboot` |
| `uboot-mainline-spldrv` | `tee` plus the first-stage loader's own SD4HC read path. Wedges this board past WDT0 — chainload-slot only, and it has never measured anything |
| `uboot-mainline-hangtest` | hangs at the first instruction U-Boot runs. The negative half of the chainload-slot proof |
| `uboot-mainline-nommu` | never switches the MMU on |

Try a candidate through the one-shot chainload slot (`nanokvm-uboot-test stage
<raw u-boot.bin>`), **never** by writing the `uboot` partition — there is one
copy and no B twin.

### Kernel and drivers

| Package | Output | Notes |
|---|---|---|
| `kernel-mainline-appliance` | `Image` + kernelrelease + the module set | **the appliance's kernel.** Linux 7.1.x, no embedded initramfs — the initrd is the generation's. `boot.kernelPackages` names this |
| `kernel-mainline` | `Image` with the bring-up initramfs | the #75 variant: a static `/init` that leaves boot evidence and reboots. `initramfsMainline` is that cpio |
| `dtb-mainline` | the board DTB | compiled from `dts/` **in this repo** with `cpp` + `dtc -p 4096`; nothing vendor about it |
| `video-modules` | six `.ko` as `/lib/modules/<release>` | `open_vin_csi2`, `open_vin_capture`, `ax630c_venc_vcmd` and the three videobuf2 modules, copied out of the appliance kernel with a `load-order` beside them |
| `display-modules` | `fbtft` + `fb_jd9853` | the mini-display's panel, same shape, separate package on purpose |
| `aic8800` / `aic8800-src` / `aic8800-firmware` | WiFi | GPL driver built out of tree against the appliance kernel; the firmware is the only closed content the blob policy permits, MD5-pinned |

### App layer

| Package | Output | Notes |
|---|---|---|
| `kvm-encoder` | `libkvm.so` / `.so.0` | **the one build** — V4L2 capture + open VC8000E encode, zero `libax_*` linked |
| `nanokvm-server` | `NanoKVM-Server` (aarch64) | Go+cgo, links libkvm + libopus; `vendorHash` pinned |
| `nanokvm-web` | React `dist/` bundle | built from our in-tree fork `web/`; pnpm hash pinned |
| `nanokvm-gpio` | ATX power/reset/LED tool | resolves a line by its `gpio-line-names` entry over libgpiod v2; the request programs the pad mux |
| `nanokvm-display` | mini-display status daemon | pure-stdlib Python + build-time-generated fonts |
| `vcenc-ewl` | `ewl_probe` | userspace VC8000E submitter; shares its register-program sources with libkvm's encoder |
| `edid` | clean-room EDID set | for the LT6911UXC front end, from source, `edid-decode --check` clean |

### Host tools

| Package | Output | Notes |
|---|---|---|
| `axdl` | `axdl-cli` | USB flasher; built for the local system, not cross-compiled. Also `nix run .#axdl` |
| `toolchain` | cross-gcc bundle | convenience `buildEnv` |

Host-side regression provers — `kvm-encoder-geom-test`, `vcenc-geom-test`,
`vcenc-rc-test` — are also packages; they are wired up as checks below.

`appliance-toplevel-cachetest` is the #100 hardware harness: the same appliance
with its update channel, cache URL, cache key and version read from the
*environment*. `builtins.getEnv` returns `""` under pure evaluation, so it is
inert unless deliberately built with `--impure`. **Never cut a release from it** —
its device would trust a key nobody rotates and poll a channel nobody publishes.

---

## Checks

`nix flake check` evaluates the whole tree without building the heavy leaves.
Every gate is hardware-free.

```bash
nix build .#checks.x86_64-linux.<name> -L
```

| Check | What it proves |
|---|---|
| `open-capture-geometry` | 1080p byte-identity for the open capture backend's parametric geometry |
| `open-venc-geometry` | the open encoder's geometry laws against 17 golden vendor vectors + a 1080p template identity |
| `open-venc-rc` | the from-scratch rate controller: vendor trajectory replay + closed-loop simulation |
| `mainline-dtb` | the DT asserts its own boot contract — FDT slack, the `blkdevparts=` clause, the ATF/OP-TEE reservations |
| `atf-mainline` | BL31 builds, its ELF entry and link address are `0x40040000`, the signed image fits the 256 KiB `atf` partition, and its Axera header matches the vendor `atf_bl31_signed.bin` field for field with both checksums recomputed |
| `uboot-mainline` | U-Boot links where the SPL jumps, the signed image fits `uboot` and carries the AX header magic, the DT reserves what belongs to other stages, and the `blkdevparts=` partition driver — compiled from the *shipped* source — yields the same table `nixos/emmc-partitions.nix` does |
| `uboot-gpt` | the GPT-at-a-base-LBA parser (patch 0023) **run**, not read: sandbox U-Boot against a faithful model of the eMMC |
| `emmc-partition-map` | the layout, rendered — the table, the `blkdevparts=` clause and `fw_env.config` from the one definition |
| `nixos-axp-manifest` | the from-scratch `.axp` read back: one manifest, the partition table against the `blkdevparts=` clause, every `<Img>` against what the host flasher's parser requires, every member inside its partition, the signed headers intact |
| `nanokvm-boot-dir` | the `/boot` tree the flashed image carries: one `extlinux.conf`, no top-level `MENU` keyword, `LINUX`/`INITRD`/`FDT` lines whose files are actually there |
| `nanokvm-mark-good-fallback` | the rollback fallback derivation against a fake `/boot`: promote, and check exactly the `DEFAULT` line moved — then that it *refuses* when the booted generation has no `LABEL` in the file |
| `nanokvm-updater-loop` | the update loop for real against a fake root: apply, check the profile advanced and the boot config names the new generation and its kernel, then collect and check the right things survived — including that `gc` refuses when it cannot know the live set |
| `nanokvm-update-idle` | the policy around it: the automatic-updates checkbox gating the timer, the pending markers, and the reboot that waits for an empty room — including that an unanswerable idle question fails **closed** |
| `nanokvm-system-manifest` | the release artefact read back: the manifest names the toplevel *this commit* builds, carries this commit's version, and its closure list is the toplevel's real closure |
| `no-x86-blobs` | #95's acceptance test, run on the **`-raw`** chain and on `boot`: no `EM_X86_64` ELF, no `ax_gzip`, and none of them still declaring itself `x86_64-linux`-only. Their *outputs*, not their closures — anything cross-compiled has the x86-64 cross toolchain in its closure by construction |
| `atf-mainline-raw` / `uboot-mainline-raw` | the raw chain's own header assertions: `img_size`, both checksums recomputed with the SPL's arithmetic, and the stored payload byte-identical to the raw binary |

The two updater checks run **real nix inside the build sandbox** — a signed
`file://` cache and two chroot stores — so they are slower than they look. They
need no network. Run them by name after touching anything under `nixos/lib/`,
`pkgs/bootfs.nix` or `pkgs/system-manifest*`.

---

## Pinned hashes

Fixed-output hashes to regenerate when their inputs change (set the field to
`pkgs.lib.fakeHash`, rebuild, paste the printed hash back):

| Where | Field | Regenerate when |
|---|---|---|
| `pkgs/nanokvm-server.nix` | `vendorHash` | `server/go.mod` / `go.sum` change, **or `postPatch` changes a Go import** |
| `pkgs/nanokvm-web.nix` | `pnpmDeps.hash` | `web/pnpm-lock.yaml` changes |
| `pkgs/atf-mainline.nix` / `pkgs/uboot-mainline.nix` | the source `hash` / `sha256` | the pinned upstream tag moves |
| `pkgs/axdl.nix` | the source `hash` | the flasher pin moves |

`buildGoModule`'s go-modules derivation inherits `postPatch`, so **every patch
that adds or removes an import moves `vendorHash`** — not just a `go.mod` bump.
`go mod vendor` vendors only the packages the main module actually imports.

`pkgs/aic8800-src.nix` pins the WiFi driver by commit and `sha256`. Bumping that
`rev` means a new hash **and** two assertions to reconcile: the count of
`debian/patches` entries that touch `src/SDIO` (the build prints every one it
applies or skips), and the 62 firmware files `pkgs/aic8800-firmware.nix` checks
against the upstream MD5 manifest. Both exist so an upstream change is read
rather than absorbed.

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
answer. This is a step of [cutting a release](releasing.md), not an optional one:
the release job pushes `.#appliance-toplevel`'s whole closure to the binary
cache, and that closure contains the server this FOD builds.

---

## Cross-compile notes

- `crossPkgs` is `pkgsCross.aarch64-multiplatform`; `supportedSystems` is
  `x86_64-linux` alone, because the default boot chain is packed with the
  prebuilt `ax_gzip`. #95's `-raw` variants need no prebuilt tool; the
  constraint goes when they become the default.
- **Go/cgo:** use `crossPkgs.buildGoModule` (the cross-capable `go`). Overriding
  it with a native `pkgs.go_*` breaks cgo — native go passes `-m64` to the
  aarch64 gcc. `GOEXPERIMENT=boringcrypto` is kept for parity with upstream's
  `build.sh`.
- **cgo link:** the server links our real `libkvm.so` (`-L$PWD/dl_lib -lkvm`) plus
  libopus, and its own `DT_RUNPATH` is the bare, store-free
  `$ORIGIN/dl_lib:/opt/lib:/opt/usr/lib`.
- **libkvm rpath:** `pkgs/kvm-encoder.nix` uses `patchelf --force-rpath` to emit
  `DT_RPATH` (transitive), not `DT_RUNPATH`, and `nixos/modules/server.nix` re-rpaths
  both copies into the image so no closed-library store path survives as a
  closure reference. Both halves are load-bearing —
  [architecture.md](architecture.md#load-bearing-linker-detail).
- **Kernel:** `pkgs/kernel-mainline.nix` drives `make` directly rather than going
  through nixpkgs' `buildLinux`, because we want the config we wrote, an
  assertable `kernelrelease` and the raw `Image` U-Boot's `booti` wants. Only the
  *source* comes from nixpkgs, so the tarball stays pinned and hash-verified by
  the flake's nixpkgs input. `CONFIG_LOCALVERSION` lives in
  `pkgs/kernel-mainline/ax630c.config` **and** is asserted against the string
  `pkgs/kernel-mainline.nix` computed; changing only the Nix side fails the build
  with `CONFIG_LOCALVERSION is not '…'`. That is the assertion working.
- **Vendor triples:** the SDK Makefiles expect `aarch64-none-linux-gnu-`; nixpkgs
  is `aarch64-unknown-linux-gnu-`. `CROSS_COMPILE` is passed explicitly.

---

## Caching

**There is no binary cache yet, and that is #96.** Every build above is from
source on your machine — a cross toolchain, a kernel, U-Boot and an appliance
closure.

The flake carries the intended `nixConfig.extra-substituters` /
`extra-trusted-public-keys` as a **comment** next to the `description`, not as a
value. A substituter listed there is contacted for every path any build on any
host is missing, so a placeholder URL would cost every developer and the release
runner a warning or a connect timeout per path and buy nothing. An unreachable
substituter is worse than no substituter.

#96 fills those two lines in, and the same cache is what the appliance
substitutes its updates from ([updates.md](updates.md)); until then
`nanokvm.update.cacheUrl` stays empty and a built image says at evaluation time
that it cannot update itself.

The light leaves — `.#kvm-encoder`, `.#nanokvm-web`, `.#nanokvm-server`,
`.#dtb-mainline` — are fast, and are the right inner-loop targets when iterating
on the app or encoder layer.
