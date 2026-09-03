# open-nanokvm-pro

An **open, self-built firmware for the Sipeed NanoKVM-Pro** (Axera **AX630C**,
dual Cortex-A53, aarch64/glibc), packaged as a Nix flake. The boot chain, Linux
kernel, video/encode backend, and the KVM application are built **from source**.

**The whole video stack is now blob-free, kernel included** (#55, 2026-09-02):
the device boots **three from-source kernel modules and zero vendor ones** —
`ax630c_venc_vcmd.ko` (open VC8000E encode), `open_vin_csi2.ko` (open MIPI
CSI-2 / D-PHY receiver) and `open_vin_capture.ko` (open VIN/IFE bypass capture,
exposing a plain V4L2 `/dev/video0`). Our `libkvm.so` captures over **standard
V4L2** and hands each buffer's dma-buf to the encoder zero-copy, doing H.264 +
MJPEG with **zero** Axera userspace libraries linked. Since #54 (2026-09-03)
the vendor media closure is **deleted from the image**, not merely unloaded:
all 22 `ax_*.ko` plus the vendor `libsns_*.so`, the NPU/AI-ISP model data and
the ISP sensor-tuning set are gone (~355 files, ~248 MB). Still closed on the
image: the aic8800 Wi-Fi/BT **firmware** and the flash-time-only AXDL helper.

The result is a reproducible `.axp` firmware image that **boots and runs the full
web KVM on real hardware**, driven by our own open `libkvm.so` backend instead
of Sipeed's withheld closed glue.

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
| [docs/updates.md](docs/updates.md) | **Our own OTA/update system**: tag on Gitea → mirrored to GitHub → Actions builds images + web-update packages; the web-UI "update" button pulls from **our** GitHub Releases, not Sipeed |
| [docs/mini-display.md](docs/mini-display.md) | The built-in screen: driven **fully from source** (kernel drivers built from our tree + our open Python status daemon; no `kvm_ui`, no `.ko` blobs), incl. sleep/wake on the knob button |

> The deep on-device reverse-engineering log (UART maps, efuse/secure-boot
> findings, the resolved MIPI/VIN/VENC capture config, per-test results) lives in
> [docs/plan-sg2002-research.md](docs/plan-sg2002-research.md). This repo's
> `docs/` is the distilled, buildable reference.
> **That log is frozen** — its last substantive entry is 2026-07-18, predating
> blob-free capture, idle power-down, the mini-display, and the SD-image
> rework; current status lives in this repo's `docs/` and git history.

---

## What's from source vs pinned

| Component | Provenance | License |
|---|---|---|
| FSBL/SPL + DDR init, TF-A 2.7, OP-TEE 3.21, U-Boot 2020.04 | **from source** (`maix_ax620e_sdk`) | GPL/BSD |
| Linux 4.19.125 kernel + NanoKVM-Pro DTS | **from source** (`maix_ax620e_sdk_kernel`) | GPL-2.0 |
| `lt6911_manage.ko` (HDMI-in bridge driver) | **from source** | GPL-2.0 |
| Mini-display stack: `fbtft`/`fb_jd9853`/`gpio_keys`/`rotary_encoder` drivers + `nanokvm-display` status daemon | **from source** (drivers from the SDK kernel tree; daemon is ours, fonts generated from source-built `terminus_font`) | GPL-2.0 / GPL-3.0 |
| `libkvm.so` (our capture + H.264/MJPEG + Opus backend) | **from source** — V4L2 capture + open VC8000E encode, dma-buf zero-copy between them; **links zero `libax_*`** | ours (GPL-3 app) |
| `ax630c_venc_vcmd.ko` (open VC8000E encode driver) | **from source** — replaces vendor `ax_venc`/`ax_jenc` | GPL-2.0 / MIT |
| `open_vin_csi2.ko` + `open_vin_capture.ko` (open MIPI CSI-2 receiver + VIN/IFE bypass capture → V4L2) | **from source** — replace the entire vendor `ax_proton` capture closure | GPL-2.0 |
| `lt6911_manage.ko` (HDMI-in bridge) | **from source** | GPL-2.0 |
| NanoKVM-Server (Go) + web UI (React) | **from source** (`NanoKVM-Pro`) | GPL-3.0 |
| ~~`ax_*.ko` modules (`proton`/`mipi_rx`/`ivps`/`sys`/`cmm`/`venc`/`jenc`/…)~~ | **REMOVED from the image** — the encode pair in #25, the whole 22-module `/soc/ko` set in #54; `/soc/ko` now holds only our three open modules | — |
| ~~vendor `libsns_*.so`, NPU/AI-ISP model data, ISP tuning `*.ini`/`*.bin`~~ | **REMOVED from the image** (#54) — no referrer left once `libax_*` went | — |
| `libax_*.so` | **PURGED from the image** (#25) — nothing we ship links or `dlopen`s them | BSD-3, redistributable |
| `libsns_dummy.so` | **from source** (`pkgs/libsns-dummy.nix`, #30) | ours |
| Rootfs base | **pinned** vendor Ubuntu 22.04 arm64 (from the v1.0.15 base `.axp`) | mixed |

The design goal is a **zero-vendor-blob device** (ISP included). The video path
is there — capture and encode are blob-free down to the kernel drivers, and
since #54 no closed kernel module or media library ships at all; what's left is
the aic8800 Wi-Fi/BT firmware. See [docs/architecture.md](docs/architecture.md#from-source-vs-pinned-blobs)
and [docs/provenance.md](docs/provenance.md) for the full, current blob audit.

> **Deliberately excluded:** the vendor's closed **mini-display app `kvm_ui`**
> (no source published). The built-in screen is instead driven by our own open
> stack — from-source kernel drivers + a small Python status daemon with
> sleep/wake on the knob button
> ([details](docs/mini-display.md)).

---

## How it's put together

Cross-compiled from `x86_64-linux` (the only supported build system — the
vendor `ax_gzip` packer is an x86-64-only static ELF) via nixpkgs
`pkgsCross.aarch64-multiplatform` (stock aarch64 glibc GCC — **no exotic
toolchain**); the firmware target is always aarch64.

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
              ├── kvm-encoder   → libkvm.so   (V4L2 capture → dma-buf → open VC8000E)
              ├── vc8000-vcmd   → ax630c_venc_vcmd.ko    (open encode driver, replaces ax_venc/jenc)
              ├── open-vin-csi2 → open_vin_csi2.ko       (open MIPI CSI-2 / D-PHY receiver)
              ├── open-vin-capture → open_vin_capture.ko (open VIN capture → V4L2 /dev/video0)
              ├── kernel        → /lib/modules + lt6911_manage.ko
              └── ax-ko-blobs   → prebuilt ax_*.ko (pinned reference for the bench harness; NOT shipped)
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
**our** [GitHub Releases](https://github.com/GoogleBot42/open-nanokvm-pro/releases)
instead of `cdn.sipeed.com`. The GitHub repo is a public, read-only downstream
mirror of the Gitea source of truth: bump `VERSION`, push, and run
`tools/release` — it tags on Gitea, the mirror carries the tag to GitHub, and
GitHub Actions builds the `.axp` image **and** a web-update package and
publishes both as release assets. Every device then sees the new version in
the web UI's **update** button and pulls it from us. Full design + setup is
in [docs/updates.md](docs/updates.md).

---

## Recovery

The AX630C's mask-ROM USB **download mode is unbrickable**: hold `User` ~10 s to
enter it, then re-flash any `.axp` (ours or the stock vendor image) with
`nix run .#axdl`. Make a full backup first — see
[docs/flashing-and-recovery.md](docs/flashing-and-recovery.md#backup-and-restore).

---

## License

[GPL-3.0](LICENSE) — Copyright (C) 2026 GoogleBot42.

Some bundled and pinned components keep their own licenses: the Ubuntu rootfs
base is its own mix, and the aic8800 Wi-Fi/BT firmware is redistributable
vendor firmware. The Axera `libax_*.so` (BSD-3) and `ax_*.ko` (GPL-tagged,
source unpublished) no longer ship at all — `axera-libs` / `ax-ko-blobs` remain
only as pinned build-time and bench-harness references. See the
[table above](#whats-from-source-vs-pinned).
