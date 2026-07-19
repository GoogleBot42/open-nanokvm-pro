# Provenance & approval baseline

This is the authoritative list of everything in the firmware that is **not** built
from source in this repo: every pinned binary blob (shipped or build-time) and
every network endpoint the device contacts at runtime. Each entry has an explicit
status. The rule this enforces: nothing ships as a blob, and nothing phones out,
without a line here that approves it.

It is the output of a three-part audit (build provenance, shipped-image
inventory, runtime network behaviour). Re-run the audit when a flake input is
re-pinned or the vendor base `.axp` changes.

- [What builds from source](#what-builds-from-source)
- [Approved binary blobs](#approved-binary-blobs)
- [Blobs pending a decision](#blobs-pending-a-decision)
- [Runtime network endpoints](#runtime-network-endpoints)
- [Verified absent](#verified-absent)

---

## What builds from source

Genuinely compiled from pinned sources — verified, no prebuilt artifact
substituted: the **boot chain** (SPL/ATF/OP-TEE/U-Boot), the **kernel** + DTS +
`lt6911_manage.ko`, our **`libkvm.so`** (`pkgs/kvm-encoder/src/`), the **Go
server**, the **React web UI**, and the **`axdl`** host flasher.

The only `fetch*` calls outside the four pinned flake inputs are
`pkgs/base-axp.nix` (`fetchurl`, sha256-pinned) and `pkgs/axdl.nix`
(`fetchFromGitHub`, rev + `Cargo.lock` pinned). Every other source comes from the
four pinned inputs or `pkgs/kvm-encoder/src/`.

---

## Approved binary blobs

### Ship on the device

| Blob | Origin | License | Why approved |
|---|---|---|---|
| `libax_*.so`, `libsns_dummy.so` (Axera media/NPU userspace) | `maix_ax620e_sdk_msp` → `pkgs/axera-libs.nix`; staged to `/opt/lib` | BSD-3, redistributable | Unavoidable on this SoC; the documented "link, don't rebuild" stance. Our server + `libkvm` link them. |
| `ax_*.ko` (≈22 media kernel modules) | `maix_ax620e_sdk_kernel` `osdrv/.../ko` → `pkgs/ax-ko-blobs.nix` | GPL-tagged, source unpublished | Same stance; must `insmod` into our kernel (vermagic matched — see building.md). |
| Vendor `.axp` overlay base (whole Ubuntu-arm64 rootfs + kept vendor boot members) | `pkgs/base-axp.nix`, sha256-pinned v1.0.15 | mixed (GPL/misc) | v1 low-risk base; a pure-nix rootfs is the long-term goal. Its retained *contents* are inventoried below. |
| **Embedded kernel initramfs**: `busybox` (1.37.0), `e2fsck`, `ld-linux-aarch64.so.1` + `libc.so.6` (glibc 2.35), `libuuid.so.1.3.0` | `maix_ax620e_sdk` `build/projects/.../initramfs/`, packed verbatim into the kernel `Image` by `pkgs/kernel.nix` | GPL-2.0 / LGPL-2.1 / BSD-3 | Load-bearing: busybox `init` does the `switch_root` to the real rootfs, `e2fsck` fscks it. A self-built kernel ships these five. To go blob-free later, rebuild this tree from nixpkgs busybox/e2fsprogs/glibc. |

### Build-time only (do not ship, but shape outputs)

| Blob | Origin | Role | Why approved |
|---|---|---|---|
| `ax_gzip` (Axera x86-64 static ELF) | `maix_ax620e_sdk` `tools/ax_gzip_tool/` | `-9` compresses the kernel/dtb/boot payloads; its "axgzip" LZ77 is what the SPL gzipd HW decompresses. Executed by `pkgs/boot.nix` + `pkgs/slot-image.nix`. | No source available; its format is mandatory for the on-device loader. This is the reason those packages are `x86_64-linux`-only. |
| `@esbuild/linux-x64`, `@rollup/rollup-linux-x64-gnu` (+ cross-platform siblings) | `nanokvm-web` `pnpmDeps` FOD (hash-pinned) | Vite bundler/minifier | Standard JS build tooling; the shipped `dist/` is static JS/CSS/HTML only — **no native code enters the bundle**. Pinned by the `pnpmDeps` hash. |

### Provenance-relevant (not binaries)

- **RSA signing keys** `tools/imgsign/{public,private}.pem` + `aes-256.key` — the
  SDK's committed dev/test keys (public modulus is a visible repeating pattern).
  Used to sign every partition image. Signatures are **not enforced** on retail
  boards (`SECURE_BOOT_EN` efuse unburned; confirmed on our unit). See
  `pkgs/boot.nix`.

---

## Blobs pending a decision

These are **not** in the approved-from-the-start set. They are either closed
vendor code that executes in our stack, or inert closed binaries carried by the
retained base rootfs. Listed here until explicitly approved or removed.

### Closed vendor code that executes today (beyond the approved ax libs/modules)

| Component | Path | Runs when | Note |
|---|---|---|---|
| **aic8800 WiFi/BT** driver + firmware | `/soc/ko/aic8800_*.ko` + `/opt/firmware/aic8800/*.bin` | on-demand (`wifi.sh`) | Closed, but functionally required for wireless. Approve if WiFi is wanted; otherwise removable. |
| **axbox syslog daemon** (`axsyslogd`/`axklogd`) | `/bin/axbox` + `/usr/lib/libax_syslog.so` | at boot (`rc.local`) | Closed Axera syslog multicall. Stock `rsyslogd` already runs alongside it — candidate to drop in favour of rsyslog. |
| `eip_ax620e.bin` | kept vendor member of the `.axp` | flash-time (AXDL agent) | Proprietary Axera download/eFuse-init helper for the USB flasher; not a stored eMMC partition. |

### Inert closed binaries — REMOVED from the image

Decided: these closed binaries from the disabled `kvmcomm` stack are deleted by
the `pkgs/rootfs.nix` debugfs overlay (and won't return — the build fails if any
survive):

| Artifact | Size | Was |
|---|---|---|
| `/kvmcomm/ui/kvm_ui` | 8.5M | closed OSD app, only launched by disabled `kvmcomm.service` |
| `/kvmcomm/vin/kvm_vin` | 792K | closed capture daemon |
| `/kvmcomm/ui/frameforge` | 988K | closed compositor |
| `/kvmcomm/ko/{fbtft,fb_jd9853,f_udisp_drv,gpio_keys,rotary_encoder,wireguard}.ko` | ~2.7M | mini-display / knob / wireguard modules, none loaded |
| `/opt/swupdate/bin/swupdate` | ~500K | vendor OTA binary; its `S99checkota` call is commented out (we replaced OTA) |

**Kept** (live dependencies, not blobs to chase): `/kvmcomm/scripts/*` (wifi,
mount_emmc), `/kvmcomm/edid/*`, `/kvmcomm/ko/lt6911_manage.ko` (until the
from-source module fully supersedes it), and `fw_printenv`/`fw_setenv`
(`S99checkboot` uses them). The `kvm_ui` `srcs/*` bitmaps and the inert
`/kvmapp/cua` Python are harmless non-binaries, left in place.

> **Provenance nuance:** on a running device the `ax_*.ko` and `/opt/lib/libax_*.so`
> that execute are the **vendor base-rootfs copies retained wholesale**, not the
> `ax-ko-blobs`/`axera-libs` derivations (those feed the build/link step). The
> content is the same SDK snapshot, and the base `.axp` is sha256-pinned, so it is
> still reproducible — but the running media stack is vendor-origin, not our pin.

---

## Runtime network endpoints

Everything the device contacts. At idle the flashed unit had **zero** outbound
connections; all of the below fire on boot, a timer, or an explicit user action.

### Our server — approved (patched to our host)

| Endpoint | Trigger | Status |
|---|---|---|
| `github.com/GoogleBot42/open-nanokvm-pro/releases/latest/download/nanokvm_pro_latest.json` | web UI version check | **APPROVE** — our release host; `cdn.sipeed.com` patched out at build (`nanokvm-server.nix`), verified by `--replace-fail`. |
| `…/nanokvm_pro_<ver>.tar.gz` → 302 → `objects.githubusercontent.com` | user clicks update | **APPROVE** — our OTA asset; SHA-512 verified against the manifest. |
| preview channel (`…/download/preview/…`) | only if `/etc/kvm/preview_updates` exists (absent) | **APPROVE (dormant)** — leave the flag file absent. |

### Auto-egress inherited from the retained vendor Ubuntu rootfs

| Endpoint | Unit | Trigger | Status |
|---|---|---|---|
| `motd.ubuntu.com` | `motd-news.timer` | ~daily + login | **REMOVED** — `rootfs.nix` ships `/etc/default/motd-news` with `ENABLED=0`. |
| `ports.ubuntu.com` | `apt-daily{,-upgrade}.timer` | daily | **APPROVED (kept)** — periodic apt index/upgrade left enabled by decision. |
| `time.{windows,apple,google}.com`, `time.cloudflare.com`, `pool.ntp.org` | `chrony.service` | boot + periodic | **APPROVED (kept as-is)** — time sync, host list left unchanged by decision. |
| mDNS `224.0.0.251` (LAN only) | `avahi-daemon` | boot | **APPROVED** — LAN-local discovery, no internet egress. |

### Our server — third-party, user-triggered only

| Endpoint | Route | Status |
|---|---|---|
| `stun.l.google.com:19302` | WebRTC stream mode (`server.yaml` default) | **APPROVED (kept)** — needed for WebRTC NAT traversal. Leaks the reflexive IP to Google only when a user opens WebRTC mode; accepted by decision. |
| `cdn.sipeed.com/nanokvm/resources/kvmadmin.tar.gz` | ~~POST `/api/kvmadmin/install`~~ | **REMOVED** — the `kvmadmin` extension route is dropped in `nanokvm-server.nix`; the endpoint no longer exists. |
| `dashscope.aliyuncs.com` (+ `cdn.jsdelivr.net`, `cdnjs.cloudflare.com`) | ~~POST `/api/assistant/start`~~ | **REMOVED** — the `assistant` extension route is dropped; endpoint gone. `/kvmapp/cua` left inert on disk. |
| `pkgs.tailscale.com/stable/tailscale_<ver>_arm64.tgz` | POST `/api/tailscale/install` | **APPROVED (kept)** — official upstream, opt-in mesh VPN. |

The web UI's external URLs are all `href` links the user clicks (wiki, GitHub,
socials) — no page-load egress.

---

## Verified absent

Checked for and **not** found anywhere in our server, web bundle, or the enabled
vendor services: telemetry/analytics (Sentry, PostHog, Google Analytics/`gtag`,
Umami), Google Fonts / external web fonts, frp/frpc, ngrok, ZeroTier, raw
WireGuard tunnels, any boot-time phone-home in our server, and any hardcoded
`cdn.sipeed.com` in the app-update path (survives only in the opt-in extensions
above). Cron carries only stock Ubuntu jobs (`e2scrub_all`, `apt-compat`,
`logrotate`) with no independent fetch.
