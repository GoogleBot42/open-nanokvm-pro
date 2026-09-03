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
`lt6911_manage.ko`, the **embedded kernel initramfs** (`pkgs/initramfs.nix`),
the **whole open video stack** — `ax630c_venc_vcmd.ko` (`pkgs/vc8000-vcmd/`),
`open_vin_csi2.ko` + `open_vin_capture.ko` (`pkgs/open-vin-{csi2,capture}/`)
and our **`libkvm.so`** (`pkgs/kvm-encoder/src/`) — the **Go server**, the
**React web UI**, and the **`axdl`** host flasher.

The initramfs baked into the `Image` used to be the vendor SDK's prebuilt tree —
five aarch64 blobs (`busybox` 1.37.0, `e2fsck`, `ld-linux-aarch64.so.1`,
`libc.so.6`, `libuuid.so.1.3.0`). Since issue #27 it is built by
`pkgs/initramfs.nix` from **static (musl) nixpkgs busybox 1.37.0 + e2fsprogs
`e2fsck`**; being static, the loader and both libraries are gone rather than
replaced. The vendor `/init` and `/show_iostat` **shell scripts** are still used
byte-for-byte — they encode the board's boot contract (partition numbers, LED
triggers, USB-MSC recovery gadget, `device_key`/MAC derivation), and they are
source, not blobs.

The only `fetch*` calls outside the four pinned flake inputs are
`pkgs/base-axp.nix` (`fetchurl`, sha256-pinned) and `pkgs/axdl.nix`
(`fetchFromGitHub`, rev + `Cargo.lock` pinned). Every other source comes from the
four pinned inputs or `pkgs/kvm-encoder/src/`.

---

## Approved binary blobs

### Ship on the device

| Blob | Origin | License | Why approved |
|---|---|---|---|
| `libax_*.so` (Axera media/NPU userspace) | **shipped** by the retained vendor rootfs at `/opt/lib` (part of the base `.axp`); `pkgs/axera-libs.nix` supplies the ABI-matched headers + link stubs at **build time only** — it stages nothing into the image | BSD-3, redistributable | Unavoidable on this SoC; the documented "link, don't rebuild" stance. **Since #25 (2026-08-31) the shipped `libkvm.so` `DT_NEEDED`s ZERO `libax_*` — 0 vendor libs on the video path**; since #55 M3 (2026-09-02) that build is `.#kvm-encoder-v4l2` (V4L2 capture over our open drivers + open VC8000E encode; only `-ljpeg`/`-lopus`/`-lasound` remain, all on the Ubuntu base). All **33 `/opt/lib/libax_*.so`** (~8.3 MB) are therefore dead weight and are now **PURGED from the flashed image** (`pkgs/rootfs.nix` step 5d1, enumerated + build-asserted empty; device-proven safe — the open stack captures + streams with every libax removed). Sipeed's original closed **`libkvm.so.0.1.0`** (2.3 MB, `DT_NEEDED`s the full libax closure) is likewise removed. The rest of the closed media payload went out in **#54 (2026-09-03, step 5d2)**: the vendor `libsns_*.so` (13 files, ~24 MB), the NPU/AI-ISP model data and the `/opt/etc` ISP sensor-tuning set — see [REMOVED from the image](#closed-binaries--removed-from-the-image). (OTA can't delete, so an OTA-upgraded device keeps all of this until reflash.) (`libsns_dummy.so` is no longer in this bucket — built from SDK source since 2026-08-16, `pkgs/libsns-dummy.nix`, issue #30.) |
| ~~`ax_*.ko` (media kernel modules)~~ — **NO LONGER SHIPS** (#54, 2026-09-03) | was carried by the retained **vendor rootfs at `/soc/ko`** (part of the base `.axp`) | GPL-tagged, source unpublished | The two ENCODE blobs `ax_venc.ko` + `ax_jenc.ko` left the loader (and the image) in **#25**; the loader stopped insmod'ing the rest in **#55 M3 (#60, 2026-09-02)**; **#54 deletes the whole `/soc/ko` vendor set** — all 22 `ax_*.ko` (`sys`/`cmm`/`pool`/`base`/`npu`/`ivps`/`vpp`/`gdc`/`tdp`/`vo`/`fb`/`venc`/`jenc`/`vdec`/`mipi_rx`/`proton`/`mipi_switch`/`audio`/`ddr_dfs`/`ive`/`avs`/`perf_monitor`) and the vendor `/soc/ko` copies of `aic8800_{bsp,btlpm,fdrv}.ko` + `hynitron_touch.ko` (we build those four from the SDK kernel tree into `/usr/lib/modules/4.19.125`, where udev autoloads them — device-proven). `pkgs/rootfs.nix` step 5d2 enumerates them from the vendor image and build-asserts them gone: 26 files, ~32 MB. `/soc/scripts/auto_load_all_drv.sh` is **ours** since issue #39 (`pkgs/rootfs/ax-load-drv.sh`) and insmods exactly three from-source modules — `ax630c_venc_vcmd.ko` (open VC8000E encode), `open_vin_csi2.ko` (open MIPI CSI-2 receiver), `open_vin_capture.ko` (open VIN capture → V4L2) — which are now the entire contents of `/soc/ko`. **No rollback loader ships** (nothing left for one to insmod): reverting to the vendor stack is a reflash of the vendor `.axp`. The autoload guard survives the purge — `ax_*.ko` must never be overlaid into `/usr/lib/modules`; `pkgs/ax-ko-blobs.nix` stays a pinned bench reference and is deliberately not merged into the modules tree, because `depmod` then emits `of:` aliases that udev autoloads parameter-less → `ax_cmm` panic → boot loop (bricked a device once; guard in `pkgs/rootfs.nix` step [4]). Keep/drop history: [blob-replacement.md](blob-replacement.md#module-curation-12-of-22-issue-39). |
| Vendor `.axp` overlay base (whole Ubuntu-arm64 rootfs + kept vendor boot members) | `pkgs/base-axp.nix`, sha256-pinned v1.0.15 | mixed (GPL/misc) | v1 low-risk base; a pure-nix rootfs is the long-term goal — feasibility + scaffold in [nixos-rootfs.md](nixos-rootfs.md) (`.#nixos-rootfs` builds, not yet booted). Its retained *contents* are inventoried below. |

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
| **aic8800 WiFi/BT firmware** | `/opt/firmware/aic8800/*.bin` (~3.5 MB) | loaded by the driver on WiFi/BT bring-up | Closed **firmware**, but functionally required for wireless. Approve if WiFi is wanted; otherwise removable. The **driver** is no longer closed: `aic8800_{bsp,btlpm,fdrv}.ko` are built from the SDK kernel tree into `/usr/lib/modules/4.19.125` and udev-autoloaded; the vendor `/soc/ko/aic8800_*.ko` copies are deleted in #54, and `/opt/scripts/wifi.sh` now `modprobe`s by name instead of insmod'ing by path (`pkgs/rootfs/wifi.sh`, vendor byte-pinned as `wifi.sh.vendor`). |
| `eip_ax620e.bin` | kept vendor member of the `.axp` | flash-time (AXDL agent) | Proprietary Axera download/eFuse-init helper for the USB flasher; not a stored eMMC partition. |

### `/opt/lib` dead weight — cleared

The retained vendor rootfs shipped **50** `.so` files in `/opt/lib`. **Since #25
(2026-08-31) our runtime needs ZERO of them** — the shipped `libkvm.so`
(`.#kvm-encoder-v4l2` since #55 M3: V4L2 capture + open VC8000E encode)
`DT_NEEDED`s no `libax_*` at all (only `libjpeg`/`libopus`/`libasound`, all on
the Ubuntu base). So **all 33 `libax_*.so` were PURGED** in #25
(`pkgs/rootfs.nix` step 5d1) together with Sipeed's leftover closed
`libkvm.so.0.1.0`, and the **13 vendor `libsns_*.so`** (~24 MB) followed in
**#54** (step 5d2) — also unreferenced (our `libsns_dummy.so` is dlopen'd only
on the unshipped closed-capture path). Device-proven safe: with every
`/opt/lib/libax_*.so` moved aside the open stack still captures + streams
(0 libax maps). Historical note (pre-#25): the vendor-MPI `libkvm`
`DT_NEEDED`ed 7 of them (`libax_venc/sys/proton/mipi/ivps` + transitive
`libax_engine` → `libax_interpreter`).

**What is left in `/opt/lib`** is the Ubuntu-base/third-party remainder the
vendor dropped there (opus and friends) plus **our from-source
`libsns_dummy.so`** — the build asserts `libsns_dummy.so` is the *only*
`libsns_*` survivor. `libax_syslog.so` left this bucket by deletion, below.

### Closed binaries — REMOVED from the image

Decided: these closed binaries and closed data sets are deleted by the
`pkgs/rootfs.nix` debugfs overlay (and won't return — each purge is enumerated
from the vendor image, floor-asserted, and asserted gone afterwards; the build
fails if any survive). OTA cannot delete, so an OTA-upgraded device keeps them
until a reflash.

| Artifact | Size | Was |
|---|---|---|
| `/usr/bin/axbox` (+ `/usr/sbin/{axsyslogd,axklogd}` and `/usr/bin/axdmesg` symlinks, `/etc/init.d/{axsyslogd,axklogd}`) | 44K | closed Axera BusyBox-1.32.0 syslog/klog multicall, started by `/etc/rc.local`. **Replaced by stock `rsyslogd`**, which the base already runs (`rsyslog.service` enabled in `multi-user.target.wants`, `Alias=syslog.service`) with `imuxsock` + `imklog` and `50-default.conf` writing `/var/log/{syslog,kern.log,auth.log}`. We ship `/etc/rc.local` without the two launch lines (`pkgs/rootfs/rc.local`, vendor original byte-pinned as `rc.local.vendor`). The base's other caller, `/etc/init.d/rcS`, is dead — `rcS.service`/`rc.service` are symlinks to `/dev/null`. `axdmesg` is a caller-less third symlink dropped so it doesn't dangle. |
| `libax_syslog.so` (`/usr/lib` 35K + `/opt/lib` 256K) | 291K | axbox's only non-libc `DT_NEEDED`. Nothing else on the image links or dlopens it (checked against every `/opt/lib` `.so`, our `libkvm.so`, and `NanoKVM-Server`). |

> The retained base image's `/etc/ld.so.cache` (and `/var/cache/ldconfig/aux-cache`)
> still list the deleted `libax_syslog.so` — harmless (nothing resolves it) and it
> self-heals on the next on-device `ldconfig` run.
| `/usr/bin/kvm_ui_setup` | 6.5M | closed Sipeed C++ (dev-tree RPATH, links the closed `libax_*`/`libsns_dummy` set). A **stray** — not dpkg-owned, not in `kvmcomm.sh`'s target list, its only mention on the image was a string inside `/kvmcomm/ui/kvm_ui` (itself deleted). Zero callers. |
| `/usr/bin/ax_clk`, `/usr/bin/ax_lookat` | 29K | closed Axera diagnostics (clock poke; `/dev/mem` peek/poke). No boot caller; `ax_lookat` is named only by `/soc/scripts/busmonitor.sh`, a manual debug script never run at boot. |
| `/kvmcomm/ui/kvm_ui` | 8.5M | closed OSD app, only launched by disabled `kvmcomm.service` |
| `/kvmcomm/vin/kvm_vin` | 792K | closed capture daemon |
| `/kvmcomm/ui/frameforge` | 988K | closed compositor |
| `/kvmcomm/ko/{fbtft,fb_jd9853,f_udisp_drv,gpio_keys,rotary_encoder,wireguard}.ko` | ~2.7M | mini-display / knob / wireguard module *copies*. All five display/input modules turned out to exist **as source** in the SDK kernel tree and are built by our own kernel (`CONFIG_FB_TFT_JD9853` etc. are `=m` in the defconfig we already use) — the mini-display now runs on those from-source builds ([mini-display.md](mini-display.md)); these prebuilt copies stay deleted. |
| `/opt/swupdate/bin/swupdate` | ~500K | vendor OTA binary; its `S99checkota` call is commented out (we replaced OTA) |
| `/opt/lib/libax_*.so` (33) + `/opt/lib/libkvm.so.0.1.0` | ~10.6M | the Axera userspace media closure + Sipeed's closed libkvm. **#25** (step 5d1); nothing we ship links or `dlopen`s them |
| `/soc/ko/*.ko` — all 22 `ax_*.ko` (incl. `ax_venc`/`ax_jenc`, dropped by the loader in #25, and the never-loaded `ax_perf_monitor`) + `aic8800_{bsp,btlpm,fdrv}.ko` + `hynitron_touch.ko` — 26 files | ~32M | **#54** (step 5d2). The `ax_*` set has been loaded by nothing since #55 M3; the aic8800/hynitron entries were vendor copies of modules we build from the SDK kernel tree into `/usr/lib/modules/4.19.125` (udev autoloads them). `/soc/ko` now holds exactly our three open modules |
| `/opt/lib/libsns_*.so` (13, `libsns_dummy.so` kept) | ~24M | **#54**. Real-sensor ISP libs; the only `libsns_*` any binary on the image names is `libsns_dummy.so`, which is **ours** from source (#30) |
| `/opt/etc/models` (AI-ISP), `/opt/etc/skelModels`, `/opt/data/npu` — 62 files | ~167M | **#54**. NPU / AI-ISP `.axmodel` model data. Inert since the #50 nr138 gate, and its only referrer (`libax_opal.so`) went out with the #25 libax purge |
| `/opt/etc/*.{ini,bin}` — 254 files | ~26M | **#54**. Vendor ISP sensor-tuning tables for ~30 real sensors (os04a10, sc450ai, imx678, …), read only by the purged ISP libs. The `opencc` `*.ocd2` and `*.json` in the same directory are kept |

**Kept** (live dependencies, not blobs to chase): `/kvmcomm/scripts/*` (wifi,
mount_emmc) and `fw_printenv`/`fw_setenv` (`S99checkboot` uses them). (The
vendor `/kvmcomm/ko/lt6911_manage.ko` copy is **deleted** — our from-source
module loads from `/usr/lib/modules` via `/etc/modules-load.d`; `/kvmcomm/ko`
is now empty.)

**`/kvmcomm/edid/*` — fully replaced from source (2026-08-31).** Sipeed's
EDID bins are data, not code, but they carry real defects: all six share
one monitor identity (only the serial LSB, byte 12, differs — the value the
web UI uses as the mode selector), so a host that caches per-display settings
may not re-probe on a mode switch (`E63-Ultrawide` is worse — it carries a
real Philips PnP id); they fail `edid-decode --check`; and `E48-4K39FPS`
declares an HDMI `Max_TMDS_Clock` of 300 MHz while listing a 336 MHz 4K39
DTD. **All six** are now generated from source (`pkgs/edid/mkedid.py`,
E-EDID 1.3 + CTA-861, no vendor bytes — every mode re-derived from
porch/pixel-clock arithmetic; `pkgs/edid.nix` enforces `--check` PASS in the
build) with distinct product-id + serial but the same byte 12 and the same
filename, so `NanoKVM-Server`'s `EDIDMap` and the web UI's mode list keep
naming them; a from-source `NanoKVM-720P60.bin` is added, and both maps gain a
matching entry (`EDIDMap` `0x72` → `NanoKVM-720P60`, plus the dropdown's
"1280 x 720 60Hz") so 720p60 is selectable from the UI like every other mode.
No vendor EDID bytes remain in the image.

`E54-1080P60FPS.bin` and `E18-4K30FPS.bin` are hardware-validated: written to
the LT6911 SPI flash via `/proc/lt6911_info/edid`, served back byte-identical,
accepted by the driver `check_edid`, and the 4K30 bin drives a real 4K30 host
to lock + clean blob-free capture. The four exotic replacements
(`E48-4K39FPS`, `E56-2K60FPS`, `E58-4K16-10`, `E63-Ultrawide`) are
spec-conformant and `--check`-clean but **not yet hardware-validated** — they
need a source that can drive those modes. Two of them deliberately change the
*preferred* timing to the mode their UI label promises (the vendor bins
preferred 4K30 and 1080p60 respectively, making "4K39" and "2K60" no
different from E18/E54); the previously-preferred timing stays as DTD 2, so a
source that cannot reach the headline mode still locks.

The `kvm_ui` `srcs/*` bitmaps and the inert
`/kvmapp/cua` Python are harmless non-binaries, left in place.

> **Provenance nuance:** since #54 nothing vendor-origin *remains* on the media
> path — the `libax_*.so`, the `libsns_*.so`, every `ax_*.ko` and the NPU/ISP
> data sets are deleted, not merely unloaded, so no copies are kept for
> rollback. Rolling back to the vendor stack means reflashing the vendor `.axp`.
> The `ax-ko-blobs` / `axera-libs` derivations still exist, but they only feed
> the build/link step and the bench harness — they stage nothing into the image.
> The base `.axp` is sha256-pinned, so a vendor reflash is still reproducible.

---

## Runtime network endpoints

Everything the device contacts. At idle the flashed unit had **zero** outbound
connections; all of the below fire on boot, a timer, or an explicit user action.

### Our server — approved (patched to our host)

| Endpoint | Trigger | Status |
|---|---|---|
| `github.com/GoogleBot42/open-nanokvm-pro/releases/latest/download/nanokvm_pro_latest.json` | web UI version check | **APPROVE** — our release host (the public downstream mirror of the Gitea source of truth, see `docs/updates.md`); `cdn.sipeed.com` patched out at build (`nanokvm-server.nix`), verified by `--replace-fail`. |
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

## Audited, present-but-inert (not closed blobs to chase)

A full dpkg-ownership diff of the retained rootfs (`/usr/{bin,sbin,lib,libexec}`,
`/usr/local`, `/usr/lib/aarch64-linux-gnu`) found the following. None is a closed
blob our stack executes, so none blocks blobless userspace — recorded so the
audit is reproducible:

- **The entire PiKVM/`kvmd` stack is inert.** The base ships a Sipeed-built
  `pikvm` dpkg package (kvmd + `janus` + µStreamer + `libgpiod`, ~1,900 files).
  It runs **only** if `/etc/kvm/server.txt` says `pikvm`; that file is absent, so
  `kvmcomm.sh` writes the default `nanokvm` and never starts it. No `kvmd*` unit
  has a `.wants` symlink. `janus`/`ustreamer`/`libgpiod` are open source anyway.
  (We disable `kvmcomm.service` outright — see `pkgs/rootfs.nix` 5c.)
- **`/usr/local` CPython 3.13** (built into `/usr/local`, not dpkg-managed) is the
  system `python3` via `/etc/alternatives`. Open source, but unmanaged — a
  supply-chain surface worth replacing when the rootfs goes from-source. Every
  `#!/usr/bin/python3` on the device runs under it.
- **Open dropped-in tools** (not dpkg, but not vendor/closed): `/usr/bin/gdb`,
  `/usr/bin/strace`, `/opt/e2fs-static/*` (e2fsprogs 1.46.6, no caller),
  `/opt/swupdate/*` (SWUpdate + libubootenv `fw_printenv`/`fw_setenv`, GPL/LGPL;
  `S99checkota`'s calls to it are commented out), `/opt/usr/bin/tiny*` (tinyalsa,
  no caller). All are from-source gaps for a fully-blobless build, not runtime
  closed blobs.
- **`/usr/bin/fw_printenv`** (the one that DOES run, via `S99checkboot`) is the
  classic U-Boot 2020.04 tool — GPL, open, kept.
- **Left in `/opt` after the #54 purge** (out of scope, no referrer either):
  `/opt/data/{avs,ives,skel,audio,ivps,uvc}`,
  `/opt/data/mc20e_isp_reg_reset_value.bin`, and `/opt/e2fs-static`. Small,
  inert vendor data; candidates for a later sweep, not blobs that execute.
- `/usr/lib/aarch64-linux-gnu` (1,074 entries): **zero** unowned files — no vendor
  `.so` was hidden there.

---

## Verified absent

Checked for and **not** found anywhere in our server, web bundle, or the enabled
vendor services: telemetry/analytics (Sentry, PostHog, Google Analytics/`gtag`,
Umami), Google Fonts / external web fonts, frp/frpc, ngrok, ZeroTier, raw
WireGuard tunnels, any boot-time phone-home in our server, and any hardcoded
`cdn.sipeed.com` in the app-update path (survives only in the opt-in extensions
above). Cron carries only stock Ubuntu jobs (`e2scrub_all`, `apt-compat`,
`logrotate`) with no independent fetch.
