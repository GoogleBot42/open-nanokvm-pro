# open-nanokvm-pro

An **open, self-built firmware for the Sipeed NanoKVM-Pro** (Axera **AX630C**,
dual Cortex-A53, aarch64), packaged as a Nix flake. Mainline Linux, mainline
TF-A, mainline U-Boot, a NixOS rootfs built entirely from nixpkgs, and a video
stack — capture *and* encode, kernel drivers included — that is ours from
source.

**The only closed content on the image is the aic8800 radio firmware**, which
executes on the radio and not on the CPU. No closed userspace, no closed kernel
module, no vendor rootfs: the whole vendor-derived build was deleted in #97.

---

## Quick start

```bash
# Build the flashable firmware image (aarch64, cross-built from x86_64).
# This is packages.default, so a bare `nix build` does the same thing.
nix build .#nixos-firmware-image-mainline
ls result/     # AX630C_emmc_arm64_k419_sipeed_nanokvm-nixos_mainline.axp

# Put the board in USB download mode: hold `User` ~10 s while powering on.
nix run .#axdl -- --file result/*.axp --wait-for-device
```

First boot is ~71 s to SSH. The board keeps its own MAC and DHCP lease, comes up
as `kvm-XXXX`, and serves the web UI on `:80`/`:443` with a self-signed cert.
SSH is `root` / `sipeed` — change it. Full procedure, including backups and
recovery: [docs/flashing-and-recovery.md](docs/flashing-and-recovery.md).

Flashing **overwrites the eMMC**. The AX630C's mask-ROM download mode cannot be
bricked, so recovery is always another AXDL flash — a bench trip, never a brick.

---

## What you get

**Working on hardware**

- The web KVM over HTTPS, served by NanoKVM-Server (from source) and our fork of
  Sipeed's React UI (in-tree at `web/`).
- HDMI capture and encode with **zero vendor code**: `open_vin_csi2.ko` +
  `open_vin_capture.ko` expose a plain V4L2 `/dev/video0`, `ax630c_venc_vcmd.ko`
  drives the VC8000E, and our `libkvm.so` hands dma-bufs between them
  zero-copy — H.264, H.265 and MJPEG, up to 4K.
- Self-updates: a release publishes a **signed system closure**, the device
  substitutes it, makes it a generation and reboots when nobody is watching.
  Proven end to end against a throwaway signed cache; the public one is #96.
- **Rollback.** U-Boot counts boot attempts in a reset-surviving register; the
  fourth runs `altbootcmd` and boots the previous generation. Proven unattended.

**Built, not yet proven on hardware**: the mini-display and HDMI audio (#84),
WiFi (#85), the ATX power/reset pulse (#81 — the code is live, the GPIO has
never been pulsed).

**Not there yet**: USB HID — no keyboard, no mouse, no mass storage (#82). The
controller and every configfs function driver are in the kernel and a host has
enumerated a gadget off this board; what is missing is the gadget *policy*.

---

## Where to read next

| Doc | What's in it |
|---|---|
| [docs/architecture.md](docs/architecture.md) | Boot chain, partition layout, the video pipeline, our `libkvm` |
| [docs/building.md](docs/building.md) | Every package, the build DAG, pinned hashes, cross-compile notes |
| [docs/flashing-and-recovery.md](docs/flashing-and-recovery.md) | AXDL flashing, backups, the chainload slot, rollback, the tripwires |
| [docs/nixos-rootfs.md](docs/nixos-rootfs.md) | The appliance: boot contract, identity, `/boot`, the known gaps |
| [docs/mainline-port.md](docs/mainline-port.md) | The #26 port — driver inventory, U-Boot/TF-A bring-up, how a serial-less first boot is made observable |
| [docs/provenance.md](docs/provenance.md) | The approval baseline: every blob and every network endpoint |
| [docs/updates.md](docs/updates.md) | How the device updates itself, and how a bad update rolls back |
| [docs/releasing.md](docs/releasing.md) | Cutting a release |
| [docs/mini-display.md](docs/mini-display.md) | The built-in screen, driven fully from source |

---

## How it's put together

Cross-compiled from `x86_64-linux` — the only supported build system, because
the Axera `ax_gzip` packer every signed boot payload passes through is an
x86-64-only static ELF — via nixpkgs `pkgsCross.aarch64-multiplatform`. Stock
aarch64 glibc GCC; no exotic toolchain.

```
nixos-firmware-image-mainline (.axp)   packed from scratch, no vendor bundle
     │
     ├── spl-minimal        BootROM's first stage, recompiled for our layout, blob-free
     ├── atf-mainline       TF-A 2.15 + our plat/axera/ax630c
     ├── uboot-mainline     U-Boot 2026.07 + this repo's AX630C patch series
     ├── uboot-env          U-Boot's own compiled-in default env + a delta
     ├── bootfs             ext4 /boot: extlinux, and each generation's kernel/initrd/dtb
     └── appliance-toplevel the NixOS system
              ├── kernel-mainline-appliance   Linux 7.1 + our AX630C support
              ├── video-modules / display-modules
              ├── kvm-encoder   → libkvm.so   (V4L2 capture → dma-buf → open VC8000E)
              ├── nanokvm-server / nanokvm-web / nanokvm-gpio / nanokvm-display
              └── aic8800 (+ its MD5-pinned firmware)
```

The appliance is also a first-class NixOS system:

```bash
nix build .#nixosConfigurations.nanokvm-pro.config.system.build.toplevel
nixos-rebuild switch --flake .#nanokvm-pro --target-host root@<device>
nix run .#nixos-appliance-qemu-run      # boot it under QEMU, no hardware
```

Hardware-free regression gates live in `nix flake check` — the eMMC partition
map, the mainline DT's boot contract, the signed TF-A and U-Boot headers, the
GPT-at-a-base-LBA parser run against a model of the eMMC, the `.axp` read back
against its own manifest, the update loop and the rollback promotion.

---

## Updates come from us, not Sipeed

The server is built from source with Sipeed's CDN update URLs deleted at build
time — and a build-time grep that fails if one survives. Since #101 the device
knows exactly one channel: `nanokvm.update.stableUrl` in its own NixOS
configuration.

Gitea (`git.neet.dev/zuckerberg/open-nanokvm-pro`) is the source of truth;
GitHub is a **read-only public mirror** that hosts releases. A release pushes
the appliance's system closure to our binary cache and publishes a ~200-byte
manifest naming that closure. The device `nix copy`s only the paths it is
missing, with `require-sigs` against the keys in its own configuration, sets the
system profile, and reboots. The cache endpoint and its key are placeholders
until #96 stands one up. [docs/updates.md](docs/updates.md),
[docs/releasing.md](docs/releasing.md).

---

## License

[GPL-3.0](LICENSE) — Copyright (C) 2026 GoogleBot42.

The aic8800 Wi-Fi firmware is redistributable vendor firmware under its own
terms; see [docs/provenance.md](docs/provenance.md).
