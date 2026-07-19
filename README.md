# nix-nanokvm-pro

An **open, self-built firmware for the Sipeed NanoKVM-Pro** (Axera **AX630C**,
dual Cortex-A53, aarch64/glibc), packaged as a Nix flake. The boot chain, Linux
kernel, video/encode backend, and the KVM application are built **from source**;
Axera's redistributable media libraries (`libax_*.so`, BSD-3) and the prebuilt
`ax_*.ko` media kernel modules are **pinned as binary inputs**.

The result is a reproducible `.axp` firmware image that **boots and runs the full
web KVM on real hardware**, driven by our own open `libkvm.so` capture/encode
backend instead of Sipeed's withheld closed glue.

> **Status: working.** `nix build .#firmware-image` produces a flashable `.axp`;
> flashed via AXDL it boots our from-source kernel + boot chain and auto-starts
> the web KVM (HTTPS on :80/:443) with our libkvm doing HDMI capture, H.264/MJPEG
> encode, and Opus audio. Verified end-to-end on a NanoKVM-Pro Desk.

---

## Quick start

```bash
# Build the flashable firmware image (aarch64, cross-built from x86_64).
nix build .#firmware-image
ls result/                       # AX630C_emmc_arm64_k419_sipeed_nanokvm-selfbuilt.axp

# Flash it over USB (device in AXDL download mode — see docs/flashing-and-recovery.md).
nix run .#axdl -- --file result/*-selfbuilt.axp --wait-for-device

# Then open the web UI and set a password:
#   https://<device-ip>/
```

Everything you need beyond this lives in [`docs/`](docs/):

| Doc | What's in it |
|---|---|
| [docs/architecture.md](docs/architecture.md) | Boot chain, partition layout, the video pipeline, our `libkvm`, and the **two vendor app stacks** (why we run `nanokvm`, not `kvmcomm`) |
| [docs/building.md](docs/building.md) | Every package, the build DAG, pinned hashes, cross-compile notes |
| [docs/flashing-and-recovery.md](docs/flashing-and-recovery.md) | AXDL USB flashing, the `User`-button recovery path, full backup/restore, non-destructive SD-card boot |
| [docs/updates.md](docs/updates.md) | **Our own OTA/update system**: CI builds images + web-update packages; the web-UI "update" button pulls from **our** GitHub Releases, not Sipeed |

> The deep on-device reverse-engineering log (UART maps, efuse/secure-boot
> findings, the resolved MIPI/VIN/VENC capture config, per-test results) lives in
> `../PLAN.md`. This repo's `docs/` is the distilled, buildable reference.

---

## What's from source vs pinned

| Component | Provenance | License |
|---|---|---|
| FSBL/SPL + DDR init, TF-A 2.7, OP-TEE 3.21, U-Boot 2020.04 | **from source** (`maix_ax620e_sdk`) | GPL/BSD |
| Linux 4.19.125 kernel + NanoKVM-Pro DTS | **from source** (`maix_ax620e_sdk_kernel`) | GPL-2.0 |
| `lt6911_manage.ko` (HDMI-in bridge driver) | **from source** | GPL-2.0 |
| `libkvm.so` (our capture + H.264/MJPEG + Opus backend) | **from source** — our open reimplementation over the Axera MPI | ours (GPL-3 app) |
| NanoKVM-Server (Go) + web UI (React) | **from source** (`NanoKVM-Pro`) | GPL-3.0 |
| `ax_*.ko` media modules (venc/mipi/proton/ivps/…) | **pinned blob** (in the kernel repo) | GPL-tagged, source not published |
| `libax_*.so`, `libsns_dummy.so` | **pinned blob** (`maix_ax620e_sdk_msp`) | BSD-3, redistributable |
| Rootfs base | **pinned** vendor Ubuntu 22.04 arm64 (from the v1.0.15 base `.axp`) | mixed |

The design goal is an **open, reproducible firmware that _links_ the accepted
Axera blobs** — not a blob-free build. See
[docs/architecture.md](docs/architecture.md#from-source-vs-pinned-blobs) for the
rationale and the full blob audit.

---

## How it's put together

Cross-compiled from `x86_64-linux` via nixpkgs `pkgsCross.aarch64-multiplatform`
(stock aarch64 glibc GCC — **no exotic toolchain**). Outputs are keyed off the
dev/build system; the firmware target is always aarch64.

```
firmware-image (.axp)  ◄── image.nix: streaming zip-rewrite of the vendor base .axp,
     ▲                     swapping in our signed partitions + overlaid rootfs
     │
     ├── boot            (SPL/DDR-init + ATF + OP-TEE + U-Boot, one from-source build)
     ├── kernel-slot-image  (Image → ax_gzip -9 + signed header)
     ├── dtb-slot-image     (patched DTB → ax_gzip -9 + signed header)
     └── rootfs          (vendor Ubuntu base + our libkvm.so + merged/depmod'd modules,
                          edited in-place with debugfs — no root/mount needed)
              ▲
              ├── kvm-encoder   → libkvm.so   (MIPI_RX → VIN → ISP-bypass → AX_VENC)
              ├── kernel        → /lib/modules + lt6911_manage.ko
              └── ax-ko-blobs   → prebuilt ax_*.ko (merged, depmod'd against our kernel)
```

Full package list and the dependency DAG are in
[docs/building.md](docs/building.md).

---

## Non-destructive SD-card boot (test path)

`nix build .#sd-image` produces a `dd`-able microSD image that boots the **entire
from-source stack from the SD/TF slot, leaving eMMC untouched** — hold the `User`
button while applying power to select it, power on normally to revert. This is the
safe way to try changes without touching the installed firmware. Details and the
strap/boot-source caveats are in
[docs/flashing-and-recovery.md](docs/flashing-and-recovery.md#sd-card-boot).

---

## Updates come from us, not Sipeed

We build `NanoKVM-Server` from source, so it's patched to fetch updates from
**our** GitHub Releases instead of `cdn.sipeed.com`. Tag a release (`git tag
v2.0.0 && git push --tags`) and `.github/workflows/release.yml` builds the `.axp`
image **and** a web-update package, publishing both as Release assets. Every
device then sees the new version in the web UI's **update** button and pulls it
from us. Full design + setup (including the one-time `updateBaseUrl` step) is in
[docs/updates.md](docs/updates.md).

---

## Recovery

The AX630C's mask-ROM USB **download mode is unbrickable**: hold `User` ~10 s to
enter it, then re-flash any `.axp` (ours or the stock vendor image) with
`nix run .#axdl`. Make a full backup first — see
[docs/flashing-and-recovery.md](docs/flashing-and-recovery.md#backup-and-restore).

---

## License

The Nix expressions and our `libkvm` reimplementation are ours; per-component
upstream licenses are listed above and in each `pkgs/*.nix` header. The pinned
Axera libraries/modules retain their upstream terms.
