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
| `libax_*.so` (Axera media/NPU userspace) | **shipped** by the retained vendor rootfs at `/opt/lib` (part of the base `.axp`); `pkgs/axera-libs.nix` supplies the ABI-matched headers + link stubs at **build time only** — it stages nothing into the image | BSD-3, redistributable | Unavoidable on this SoC; the documented "link, don't rebuild" stance. Our `libkvm.so` `DT_NEEDED`s exactly **`libax_venc`, `libax_sys`, `libax_proton`, `libax_mipi`, `libax_ivps`** (+ transitive `libax_engine` → `libax_interpreter`) — ~2.99 MB, and the encoder-track blocker. The other ~43 files in `/opt/lib` are dead weight, see below. (`libsns_dummy.so` is no longer in this bucket — built from SDK source since 2026-08-16, `pkgs/libsns-dummy.nix`, issue #30.) |
| `ax_*.ko` (22 media kernel modules **shipped**, **12 loaded**) | shipped by the retained **vendor rootfs at `/soc/ko`** (part of the base `.axp`); `/soc/scripts/auto_load_all_drv.sh` insmods them at boot with their required params — and since issue #39 that loader is **ours** (`pkgs/rootfs/ax-load-drv.sh`), loading only the 12-module dependency closure of `{ax_proton, ax_venc, ax_jenc}` | GPL-tagged, source unpublished | Same stance. The other 10 blobs (`hynitron_touch`, `ax_tdp`/`vo`/`fb`/`vdec`/`mipi_switch`/`audio`/`ddr_dfs`/`ive`/`avs`) are still **present on disk** but never loaded; they stay in `/soc/ko` so restoring the retained `auto_load_all_drv.sh.vendor` + rebooting is a complete rollback. Keep/drop rationale: [blob-replacement.md](blob-replacement.md#module-curation-12-of-22-issue-39). Still NOT overlaid into `/usr/lib/modules` by us — `pkgs/ax-ko-blobs.nix` exists as a pinned reference but is deliberately not merged into the modules tree: doing so made `depmod` emit `of:` aliases that udev autoloaded parameter-less → `ax_cmm` panic → boot loop (bricked a device once; see [provenance nuance](#blobs-pending-a-decision) and the guard in `pkgs/rootfs.nix` step [4]). |
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
| `eip_ax620e.bin` | kept vendor member of the `.axp` | flash-time (AXDL agent) | Proprietary Axera download/eFuse-init helper for the USB flasher; not a stored eMMC partition. |

### Shipped but never loaded — `/opt/lib` dead weight

The retained vendor rootfs ships **50** `.so` files in `/opt/lib` (33.7 MB). Our
runtime needs **7** of them: the `DT_NEEDED` closure of our `libkvm.so`
(`libax_venc`, `libax_sys`, `libax_proton`, `libax_mipi`, `libax_ivps`) plus the
transitive `libax_engine` → `libax_interpreter` — 2.99 MB — and our own
from-source `libsns_dummy.so` (which overwrites the vendor's). The remaining
**42 files / 29.4 MB** (`libax_skel`, `libax_opal`,
`libax_vo`, `libax_vdec`, `libax_audio*`, the 3A libs, every non-dummy
`libsns_*`, …) are **present on disk but never dlopen'd or linked** by anything
our stack runs. Evidence: the `DT_NEEDED` graph over all 50 `.so` (nothing in
the 7-lib closure references anything outside it), and the only `.so`-name
strings in `libax_proton.so` are its own `DT_NEEDED`s plus one soft
`dlopen("/soc/lib/libisp_cjson.so")` — a path that **does not exist** on the
image (`/soc` holds only `ko/` and `scripts/`), so that dlopen already fails
harmlessly today. No 3A or sensor lib is named anywhere in it.

Deleting the 42 is a real blob reduction with no expected functional change,
but it wants one device confirmation (`lsof` / `/proc/<server>/maps` while
streaming) before it ships — its own ticket. `libax_syslog.so` left this bucket
by deletion, below.

### Closed binaries — REMOVED from the image

Decided: these closed binaries are deleted by the `pkgs/rootfs.nix` debugfs
overlay (and won't return — the build fails if any survive):

| Artifact | Size | Was |
|---|---|---|
| `/usr/bin/axbox` (+ `/usr/sbin/{axsyslogd,axklogd}` and `/usr/bin/axdmesg` symlinks, `/etc/init.d/{axsyslogd,axklogd}`) | 44K | closed Axera BusyBox-1.32.0 syslog/klog multicall, started by `/etc/rc.local`. **Replaced by stock `rsyslogd`**, which the base already runs (`rsyslog.service` enabled in `multi-user.target.wants`, `Alias=syslog.service`) with `imuxsock` + `imklog` and `50-default.conf` writing `/var/log/{syslog,kern.log,auth.log}`. We ship `/etc/rc.local` without the two launch lines (`pkgs/rootfs/rc.local`, vendor original byte-pinned as `rc.local.vendor`). The base's other caller, `/etc/init.d/rcS`, is dead — `rcS.service`/`rc.service` are symlinks to `/dev/null`. `axdmesg` is a caller-less third symlink dropped so it doesn't dangle. |
| `libax_syslog.so` (`/usr/lib` 35K + `/opt/lib` 256K) | 291K | axbox's only non-libc `DT_NEEDED`. Nothing else on the image links or dlopens it (checked against every `/opt/lib` `.so`, our `libkvm.so`, and `NanoKVM-Server`). |
| `/usr/bin/kvm_ui_setup` | 6.5M | closed Sipeed C++ (dev-tree RPATH, links the closed `libax_*`/`libsns_dummy` set). A **stray** — not dpkg-owned, not in `kvmcomm.sh`'s target list, its only mention on the image was a string inside `/kvmcomm/ui/kvm_ui` (itself deleted). Zero callers. |
| `/usr/bin/ax_clk`, `/usr/bin/ax_lookat` | 29K | closed Axera diagnostics (clock poke; `/dev/mem` peek/poke). No boot caller; `ax_lookat` is named only by `/soc/scripts/busmonitor.sh`, a manual debug script never run at boot. |
| `/kvmcomm/ui/kvm_ui` | 8.5M | closed OSD app, only launched by disabled `kvmcomm.service` |
| `/kvmcomm/vin/kvm_vin` | 792K | closed capture daemon |
| `/kvmcomm/ui/frameforge` | 988K | closed compositor |
| `/kvmcomm/ko/{fbtft,fb_jd9853,f_udisp_drv,gpio_keys,rotary_encoder,wireguard}.ko` | ~2.7M | mini-display / knob / wireguard module *copies*. All five display/input modules turned out to exist **as source** in the SDK kernel tree and are built by our own kernel (`CONFIG_FB_TFT_JD9853` etc. are `=m` in the defconfig we already use) — the mini-display now runs on those from-source builds ([mini-display.md](mini-display.md)); these prebuilt copies stay deleted. |
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
