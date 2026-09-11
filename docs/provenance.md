# Provenance & approval baseline

The authoritative list of everything in the firmware that is **not** built from
source in this repo, and every network endpoint the device contacts at runtime.
The rule it enforces: nothing ships as a blob, and nothing phones out, without a
line here that approves it.

Since #97 there is one product — the mainline NixOS appliance — and the list is
short. Re-run the audit when a flake input is re-pinned.

- [The blob policy](#the-blob-policy)
- [The one closed payload on the image](#the-one-closed-payload-on-the-image)
- [Build-time-only vendor inputs](#build-time-only-vendor-inputs)
- [What the image stores](#what-the-image-stores)
- [What used to be here](#what-used-to-be-here)
- [Runtime network endpoints](#runtime-network-endpoints)
- [Verified absent](#verified-absent)

---

## The blob policy

**Approved 2026-09-04 (Jeremy, #28): the aic8800 wireless firmware is the ONLY
closed content permitted on the image. No closed userspace, no closed `.ko`,
ever.**

Everything else on the device is compiled from pinned sources: the boot chain
(the SPL, mainline TF-A BL31, mainline U-Boot), the mainline kernel and its
device tree, the open video stack (`ax630c_venc_vcmd.ko`, `open_vin_csi2.ko`,
`open_vin_capture.ko` — all in `pkgs/kernel-mainline/tree/`), our `libkvm.so`
(`pkgs/kvm-encoder/src/`), the Go server (pinned upstream `NanoKVM-Pro/server`,
patched at build), the React web UI (our in-tree fork, `web/FORK.md`), the
mini-display stack, the EDID set (`pkgs/edid/mkedid.py` — no vendor bytes), the
`aic8800_bsp`/`aic8800_fdrv` GPL drivers, and the `axdl` host flasher. The whole
rootfs is nixpkgs.

The closure is asserted blob-free at build time: `nixos/modules/server.nix` fails the
build if `libkvm.so`, `libkvm.so.0` or `NanoKVM-Server` still carries an
`axera-libs` store path, which is what would drag the closed Axera media
libraries into an image that is supposed to contain none of them.

---

## The one closed payload on the image

| Blob | Origin | License | Why approved |
|---|---|---|---|
| **aic8800 radio firmware** | `pkgs/aic8800-firmware.nix` (#85) — 62 `.bin` files, ~5.1 MB, from `radxa-pkg/aic8800` at `516e3b0`. Shipped through `hardware.firmware`, reachable at `/run/current-system/firmware/aic8800_fw/SDIO/<chip>/`. Loaded by our from-source GPL `aic8800_bsp.ko` (`pkgs/aic8800.nix`), which opens the path with `filp_open` — the SDK builds with `CONFIG_USE_FW_REQUEST = n`, so the package opts out of `hardware.firmwareCompression`. | closed firmware, redistributable | **APPROVED (#28).** It executes on the radio's own core, never on the A53s. **Hardware-proven 2026-09-11**: the part is an AIC8801 and the driver loads these files from `/run/current-system/firmware/aic8800_fw/SDIO/aic8800/` — see [mainline-port.md](mainline-port.md) "ON HARDWARE: THE RADIO SCANS". Gated by `nanokvm.wifi.enable`; turning that off drops the firmware and the drivers from the closure entirely, which is what the QEMU harness does. |

**Pinned by per-file MD5, both ways.** `src/firmware_version.md` in the driver
tree is AICsemi's own manifest. Every `.bin` shipped is checked against it at
build time, and every row for a directory we ship must have a file — a manifest
row with no file and a file with no row are each a failed build, asserted by
count (62) as well as by sum. A firmware swap upstream is a broken build, not a
silent change in what runs on the radio.

---

## Build-time-only vendor inputs

**None of these is closed content on the image.** They shape outputs, or they
run on the host, or they run from RAM during a flash and are never stored.

One of them is still a binary — `ax_gzip` — and #95 has built its replacement
without yet flipping to it. `.#checks.<sys>.no-x86-blobs` asserts that the
`-raw` boot chain and `pkgs/boot.nix`'s FDL agents carry no `EM_X86_64` ELF
and no `ax_gzip`; the default chain still does use it, deliberately, until a
board has booted the raw one.

| Input | Origin | Role | Status |
|---|---|---|---|
| `ax_gzip` | `maix_ax620e_sdk` `tools/ax_gzip_tool/` — an Axera **x86-64 static ELF** | `-9` compresses each signed boot payload into the "axgzip" LZ77 the SPL's gzipd hardware decompresses. Driven by `pkgs/ax-sign.nix` and `pkgs/atf-mainline.nix` for the DEFAULT boot chain. | **The only closed binary left in the build, and its retirement is built but not yet proven (#95).** `pkgs/boot.nix` no longer runs it at all: the FDL agents are built with `SUPPPORT_GZIPD=FALSE`, and the tool is deleted from that build tree. The `-raw` package variants (`.#spl-minimal-raw`, `.#atf-mainline-raw`, `.#uboot-mainline-raw`, `.#nixos-firmware-image-mainline-raw`) drop it from the boot chain too — `.#checks.<sys>.no-x86-blobs` asserts they carry no x86-64 ELF — but they are **not the default**, because `.#nixos-firmware-image-mainline` is the AXDL recovery image and the raw chain has not booted a board. **Pending #95 hardware: when the raw chain boots, the defaults flip, the gzip variants go, and this row goes with them.** |
| `imgsign` + its keys | `maix_ax620e_sdk` `build/tools/imgsign/`, `tools/imgsign/{public,private}.pem`, `aes-256.key` | Wraps each payload in the 1 KiB container the SPL loads: magic `0x55543322`, header and payload checksums, a capability word, an RSA-2048 key/signature pair. `pkgs/ax-sign.nix` drives it for anything built outside the vendor makefiles. | Python, not a binary. The keys are the SDK's **committed dev/test keys** (the public modulus is a visible repeating pattern; `aes-256.key` is ASCII zeros). Enforcement is a runtime decision the SPL makes from the `SECURE_BOOT_EN` efuse, which is unburned on retail units — so the signature satisfies a check that never runs. |
| bl1/SPL C source | `maix_ax620e_sdk` `boot/bl1/` | `.#spl-minimal` recompiles it for our eMMC layout's byte offsets (#89 rung 4). | Source, built here. **Blob-free since #90** — see below. |
| Axera `ax_*.h` headers | `maix_ax620e_sdk_msp` | Our blob-free `libkvm.so` compiles against them for the SDK's frame and stream types. | Headers only. **No library out of this tree is linked or shipped**, and the image closure is asserted to contain none of it. |
| FDL1 / FDL2 download agents | built from SDK source by `pkgs/boot.nix` | The AXDL flasher pushes them into BootROM RAM (`0x3000000` and `0x5C000000`) to get a programmer running. FDL2 **is** a U-Boot build. | Compiled here, from source. **Never stored on the eMMC.** Nothing out of `pkgs/boot.nix` ever boots on the board; the `atf-mainline` check additionally reads the vendor `atf_bl31_signed.bin` out of that derivation only to compare header fields. |
| `@esbuild/linux-x64`, `@rollup/rollup-linux-x64-gnu` (+ siblings) | `nanokvm-web` `pnpmDeps` FOD, hash-pinned | Vite bundler/minifier | Standard JS build tooling. The shipped `dist/` is static JS/CSS/HTML — no native code enters the bundle. |

### The EIP-130 firmware is gone (#90, closed 2026-09-09)

The closed EIP-130 crypto-engine firmware (78528 B) used to be spliced into the
SPL *package* at `fw_flash_addr` `0xCC00` and `fw_bak_flash_addr` `0x2CC00`,
with the signed header declaring its `fw_size`/`fw_check_sum`. That is a BootROM
contract, not a build option — but the sign tool's `-fw` argument takes a
*file*, and an **empty** file gives `fw_size = 0`, `fw_check_sum = 0` and
nothing spliced. The BootROM accepts it: hardware-proven across two warm reboots
and a cold power cycle. `.#spl-minimal` is build-asserted to carry **zero**
copies; `.#spl-minimal-eip` rebuilds the vendor-shaped container with exactly
two at exactly those offsets, kept only as a fallback should a unit ever refuse
the empty one. U-Boot and FDL2 lost their own copies in the same change
(`CONFIG_CMD_AXERA_CIPHER` and `CONFIG_AXERA_SECURE_BOOT` are `is not set`), and
mainline U-Boot never had the question at all.

---

## What the image stores

`.#nixos-firmware-image-mainline` is packed from scratch by
`nixos/lib/make-axp-image.nix`. There is no vendor bundle behind it and the
packer fails the build if a store path from one appears. Five stored partitions,
in the GPT order (`nixos/lib/emmc-layout.nix`; full offsets in
[flashing-and-recovery.md](flashing-and-recovery.md#the-emmc-map)):

| GPT # | Partition | Source |
|---|---|---|
| 1 | `atf` | `pkgs/atf-mainline.nix` — **mainline TF-A 2.15** with our own `plat/axera/ax630c`, signed |
| 2 | `uboot` | `pkgs/uboot-mainline.nix` — **mainline U-Boot 2026.07** plus this repo's AX630C patch series, signed |
| 3 | `env` | `pkgs/uboot-env.nix` — `mkenvimage` over U-Boot's own compiled-in default environment plus the delta in `pkgs/uboot-env.txt`. U-Boot itself does not read it (`CONFIG_ENV_IS_NOWHERE`); `fw_printenv`/`fw_setenv` on the appliance do |
| 4 | `boot` | `pkgs/bootfs.nix` — ext4 carrying the extlinux tree, the kernel, the initrd and the dtb of each generation |
| 5 | `rootfs` | `nixos/modules/` → `nixos/lib/appliance-artifacts.nix` — the NixOS system, sparse ext4 |

Plus the `spl` region in front of the GPT: `pkgs/spl-minimal.nix`, written last,
deliberately. And two members that are **flash-time only, never stored**: FDL1
and FDL2, above.

There is no `kernel`, `dtb`, `optee`, `logo` or `ddrinit` partition and no `_b`
twin. The kernel is loaded by `sysboot` from `/boot/extlinux/extlinux.conf` and
belongs to the generation (#99).

`atf`, `uboot` and `spl` carry the SDK dev-key RSA signature; `env`, `boot` and
`rootfs` are raw formats with no header.

---

## What used to be here

This document used to run to several hundred lines of vendor inventory. That
content described the 4.19 Ubuntu-derived image, which no longer exists. In
order:

**#25 (2026-08-31)** purged all 33 `/opt/lib/libax_*.so` (~8.3 MB) and Sipeed's
closed `libkvm.so.0.1.0` once our `libkvm.so` `DT_NEEDED`ed zero vendor
libraries. **#60 / #55 M3 (2026-09-02)** stopped the loader insmod'ing the
vendor media modules. **#54 (2026-09-03)** deleted the rest of the closed media
payload from the image rather than merely unloading it: all 22 `ax_*.ko`
(~32 MB with the vendor aic8800/hynitron copies), the 13 vendor `libsns_*.so`
(~24 MB), the NPU/AI-ISP `.axmodel` model data (~167 MB) and the ISP
sensor-tuning set (~26 MB). **#90 (2026-09-09)** removed the EIP-130 crypto
firmware from U-Boot, FDL2 and finally the SPL itself. **#97 (2026-09-11)**
deleted the 4.19 build outright — the vendor Ubuntu rootfs base
(`pkgs/base-axp.nix`), the vendor-fork TF-A/U-Boot/OP-TEE chain, the A/B slot
packaging, the logo BMP, the SD-card image and the `ax-ko-blobs` / `libsns-dummy`
/ `ax-stub` derivations went with it.

Rolling back to the vendor stack means flashing a stock Sipeed `.axp`. Nothing
in this repo keeps a copy for that purpose.

---

## Runtime network endpoints

Everything the device contacts. All of it fires on boot, on a timer, or on an
explicit user action.

### Updates — one channel, ours

| Endpoint | Trigger | Status |
|---|---|---|
| `github.com/GoogleBot42/open-nanokvm-pro/releases/latest/download/nanokvm_pro_sys_latest.json` | `nanokvm-update check`/`update`, and the web UI's version route and update button, which both go through that tool | **APPROVE** — `nanokvm.update.stableUrl`, the **only channel this device knows** since #101. The Gitea source of truth is Tailscale-only, so devices poll the public GitHub mirror's releases. |
| `nanokvm.update.cacheUrl` — our Nix binary cache | user clicks update, or the daily timer fires on a device whose owner ticked **Automatic updates** (`/etc/kvm/auto_updates`, absent by default) | **APPROVE** — where the payload comes from since #100: `nix copy --from <cache>` fetches only the NARs the device is missing, with `require-sigs = true` and an explicit `trusted-public-keys`, so a NAR this device's own keys did not sign is refused. The cache is a transport, not a trust root. Empty by default (#96) — empty means no update egress at all. |
| preview channel (`…/releases/download/preview/…`) | only if `/etc/kvm/preview_updates` exists (absent) | **APPROVE (dormant)** — leave the flag file absent. |

**No channel URL is compiled into `NanoKVM-Server` any more.** `pkgs/nanokvm-server.nix`
step 1 replaces `service/application/version.go` wholesale so the version route
asks the updater; step 2 deletes the two `cdn.sipeed.com/nanokvm` base URLs and
then **greps to prove it** — a surviving reference fails the build.

### User-triggered, third-party

| Endpoint | Route | Status |
|---|---|---|
| `stun.l.google.com:19302` | WebRTC stream mode (upstream `server.yaml` default) | **APPROVED (kept)** — needed for NAT traversal. Leaks the reflexive IP to Google only when a user opens WebRTC mode. |
| `pkgs.tailscale.com/stable/tailscale_<ver>_arm64.tgz` | POST `/api/tailscale/install` | **APPROVED (kept)** — official upstream, opt-in mesh VPN. |
| ~~`cdn.sipeed.com/nanokvm/resources/kvmadmin.tar.gz`~~ | ~~POST `/api/kvmadmin/install`~~ | **REMOVED** — `pkgs/nanokvm-server.nix` step 4 overwrites `extensions.go` and drops the route. It fetched and ran the closed NanoKVM-Admin binary. |
| ~~`dashscope.aliyuncs.com`, `cdn.jsdelivr.net`, `cdnjs.cloudflare.com`~~ | ~~POST `/api/assistant/start`~~ | **REMOVED** — same step; the assistant route is gone. |

### System services

| Endpoint | Unit | Status |
|---|---|---|
| `*.pool.ntp.org` (nixpkgs default) | `systemd-timesyncd` | **APPROVED** — replaces the vendor chrony and its `time.{windows,apple,google}.com` host list. |
| mDNS `224.0.0.251` (LAN only) | `avahi-daemon`, publishing addresses + workstation | **APPROVED** — LAN-local discovery, no internet egress. |

The whole vendor-Ubuntu egress set — `motd.ubuntu.com`, `ports.ubuntu.com` and
its `apt-daily` timers, chrony's four-vendor host list — went with the rootfs in
#97. A NixOS appliance runs no apt and no cron.

The web UI's external URLs are all `href` links the user clicks (wiki, GitHub,
socials) — no page-load egress.

---

## Verified absent

Checked for and **not** found in our server, the web bundle or the enabled
units: telemetry/analytics (Sentry, PostHog, Google Analytics/`gtag`, Umami),
Google Fonts or any external web font, frp/frpc, ngrok, ZeroTier, raw WireGuard
tunnels, any boot-time phone-home, and any hardcoded `cdn.sipeed.com` in the
update path.
