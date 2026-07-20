# Architecture

How the from-source NanoKVM-Pro firmware fits together, from power-on to a live
web KVM. For build mechanics see [building.md](building.md); for flashing see
[flashing-and-recovery.md](flashing-and-recovery.md).

- [Hardware](#hardware)
- [Boot chain](#boot-chain)
- [Partition layout](#partition-layout)
- [Root filesystem](#root-filesystem)
- [The video/audio pipeline (our libkvm)](#the-videoaudio-pipeline-our-libkvm)
- [The two app stacks: nanokvm vs kvmcomm](#the-two-app-stacks-nanokvm-vs-kvmcomm)
- [Runtime service model](#runtime-service-model)
- [From-source vs pinned blobs](#from-source-vs-pinned-blobs)

---

## Hardware

- **SoC:** Axera **AX630C** — 2× ARM Cortex-A53 (aarch64), a VeriSilicon
  **Hantro VC8000E** hardware video encoder (H.264/H.265/MJPEG), MIPI-CSI RX, and
  an Axera ISP.
- **HDMI-in:** a **Lontium LT6911UXC** HDMI→MIPI-CSI bridge converts the captured
  host HDMI signal to MIPI. An open in-tree driver, `lt6911_manage.ko`, polls it
  and exposes resolution/format under `/proc/lt6911/*`.
- **Storage:** eMMC (installed firmware) + a microSD/TF slot (non-destructive
  boot path).
- **Console UARTs:** `ttyS0` @ `0x4880000` (primary console, hidden pads),
  `ttyS1` @ `0x4881000` (exposed header pin U1), `ttyS2` @ `0x4882000`. The clock
  gives a `base_baud` of 13000000 (208 MHz / 16).
- **`User` button:** the reset-time `CHIP_MODE` strap. Hold while powering on to
  boot the SD card; hold ~10 s to enter USB download mode. A normal power-on
  always boots eMMC. See [flashing-and-recovery.md](flashing-and-recovery.md).

---

## Boot chain

All stages are built **from source** (`pkgs/boot.nix`, one shared build; the
`boot-fsbl/atf/optee/uboot` selectors expose subsets):

```
BootROM (mask ROM, unbrickable)
  └─► SD-SPL / bl1  (DDR init + training, from-source C)
        └─► ATF / bl31   (TF-A 2.7)
              └─► OP-TEE / bl32 (3.21)
                    └─► U-Boot 2020.04 (bl33)
                          └─► Linux 4.19.125  + DTB
                                └─► vendor initramfs /init
                                      └─► switch_root → /realroot → systemd
```

- The BootROM latches its boot source (eMMC vs SD vs USB) from the `CHIP_MODE`
  strap (the `User` button) at reset — it does not probe. The SD path is
  **file-based** (FAT32 + named images), not raw-offset; see
  [flashing-and-recovery.md](flashing-and-recovery.md#sd-card-boot).
- The kernel embeds the **vendor initramfs**, whose `/init` reads `root=` from the
  cmdline and does `switch_root /realroot /sbin/init`. Removing it breaks the root
  mount — it must stay (`INITRAMFS_SOURCE`).
- **Secure boot** is gated on the efuse `SECURE_BOOT_EN`
  (`COMM_SYS_BOND_OPT @ 0x02340098`, bit 26). On the units checked it reads **0
  (off)**, so self-signed/unsigned firmware boots. Boot derivations default to the
  unsigned path.

The console UART is a build parameter. The eMMC image uses `ttyS0` (`0x4880000`);
the `sd-image` uses a `boot-sd` variant that redirects **every** stage
(SPL/ATF/OP-TEE/U-Boot + kernel) to `ttyS1` (`0x4881000`, the accessible header
pin) so an SD boot is watchable end-to-end.

---

## Partition layout

The firmware is an Axera **`.axp`** (a ZIP of signed partition images). The eMMC
carries a 17-partition A/B layout. Our `image.nix` does a **streaming zip-rewrite**
of the pinned vendor base `.axp`, swapping in our from-source members by basename:

| `.axp` member(s) | Source | Notes |
|---|---|---|
| SPL / DDR-init / ATF / OP-TEE / U-Boot | `pkgs/boot.nix` | signed basenames match `make_axp_v2.py` |
| `boot_signed.bin` (+ A/B `.1`) | `pkgs/kernel-fip.nix` | `Image` → `ax_gzip -9` + 1 KB signed header |
| `dtb.img` (+ A/B) | `pkgs/dtb-fip.nix` | patched DTB → `ax_gzip -9` + signed header |
| `ubuntu_rootfs_sparse.ext4` | `pkgs/rootfs.nix` | overlaid rootfs (below) |
| everything else | vendor base `.axp` | kept as-is |

The rootfs on eMMC is partition **p17** (`/dev/mmcblk0p17`); the kernel `root=`
cmdline points there for an eMMC boot, or `/dev/mmcblk1p2` for an SD boot.

---

## Root filesystem

`pkgs/rootfs.nix` starts from the **vendor Ubuntu 22.04 arm64** rootfs (extracted
from the base `.axp`) and overlays our bits **without root/mount privileges**,
editing the ext4 in place with `debugfs -w` (a Nix sandbox has no loop mount):

1. **`libkvm.so`** → `/kvmapp/server/dl_lib/` (our capture/encode backend).
2. **Kernel modules** → `/lib/modules/4.19.125/`: our from-source modules
   (incl. `lt6911_manage.ko`) **merged** with the prebuilt `ax_*.ko`, then
   `depmod`'d on a host staging tree so autoloading works with no on-device depmod.
3. **Service selection** (see below): disable `kvmcomm.service`, enable
   `nanokvm.service` in `multi-user.target.wants`.
4. **Mini-display**: `/opt/nanokvm-display/` (status daemon + generated fonts)
   plus the enabled `nanokvm-display.service`; `/etc/modules-load.d/nanokvm.conf`
   also loads the from-source display/input modules
   (`fb_jd9853`→`fbtft`, `gpio_keys`, `rotary_encoder`). See
   [mini-display.md](mini-display.md).

`debugfs`'s `sif … uid/gid 0` restores root ownership after each write. The build
asserts our `libkvm.so` matches byte-for-byte and that the service symlinks are
correct before re-sparsing the image.

---

## The video/audio pipeline (our libkvm)

`pkgs/kvm-encoder.nix` cross-builds **`libkvm.so`**, our open reimplementation of
Sipeed's withheld glue. It implements the `kvm_vision.h` ABI that the Go server
links against (`kvmv_init` / `kvmv_read_img` / `kvmv_read_audio` / `kvmv_set_fps` /
`kvmv_hdmi_control` / …) and drives the **documented Axera MPI** path end-to-end:

```
LT6911UXC HDMI→CSI-2
  └─► MIPI_RX  (DPHY 4-lane, 600 Mbps, LaneCombo MODE_0, RAW/RAW16, BGGR)
        └─► VIN dev
              └─► VIN pipe  (ISP_BYPASS_MODE — dummy sensor via libsns_dummy.so)
                    └─► VIN chn  (YUV420 SP)
                          └─► AX_VENC  (H.264 chn7 / MJPEG chn6)   → web stream
        └─► ALSA capture (LT6911 audio card) ─► Opus encode         → web audio
```

The host HDMI is captured as already-formed YUV (the LT6911 bridge does the
conversion), so the ISP is **bypassed** — no ISP/3A algorithm blobs are needed on
the KVM path. `libkvm` links the Axera libs directly (`-lax_venc -lax_sys
-lax_proton -lax_mipi -lax_ivps`) plus `libopus`/`libasound` for audio.

**Load-bearing linker detail:** `libkvm` needs `DT_RPATH` (transitive), **not**
`DT_RUNPATH`. It `DT_NEEDED`s `libax_proton`, which in turn needs `libax_engine`.
`DT_RUNPATH` is searched only for a library's *own* direct deps, so the transitive
`libax_engine` would fail to resolve under systemd (which has neither `/opt/lib`
on `LD_LIBRARY_PATH` nor in `ld.so.cache`) — the server would crash-loop with
`libax_engine.so: cannot open shared object file`. `kvm-encoder.nix` therefore
uses `patchelf --force-rpath` to emit `DT_RPATH`, which is inherited down the whole
dependency chain. This is self-contained: no `ldconfig` entry or `LD_LIBRARY_PATH`
is needed on the target.

---

## The two app stacks: nanokvm vs kvmcomm

The pinned vendor base ships **two independent, mutually exclusive KVM
application stacks**, and enables the one that is useless to us. This is the single
most surprising thing about the platform, so it's worth stating plainly:

| | **kvmapp** (we use this) | **kvmcomm** (vendor default) |
|---|---|---|
| systemd unit | `nanokvm.service` | `kvmcomm.service` |
| web server | `NanoKVM-Server` (Go) on :80/:443 | hands web to PiKVM's `kvmd` |
| capture/encode | **our open `libkvm.so`** | `kvm_vin` + `kvm_ui`, straight to the Axera libs (no libkvm) |
| built-in mini-display | **our open `nanokvm-display` daemon** (from-source drivers) | closed `kvm_ui` drives it |
| web UI on this base | **works** | **`kvmd` ships disabled + inactive → no web UI at all** |

Both stacks are full capture pipelines and **contend for the single MIPI_RX/VENC
hardware** if run together, so exactly one must be active. The vendor enables
`kvmcomm` by default — so an *unmodified* flash of our image boots into a stack
with no reachable web UI (this was the "web interface is down" symptom during
bring-up).

`pkgs/rootfs.nix` fixes this: it drops the `kvmcomm.service` symlink from
`multi-user.target.wants` and adds `nanokvm.service`. For an open, from-source web
KVM, `nanokvm` is the correct stack.

### The built-in mini-display

On the vendor stack the small on-device screen is driven by `kvm_ui` (+
`frameforge`), **closed-source vendor binaries** we neither ship nor run. On our
firmware the display is instead driven **entirely from source**:

- **Drivers:** `fbtft` + `fb_jd9853` (panel → `/dev/fb0`), `gpio_keys` (knob
  button) and `rotary_encoder` (knob rotation) — all built by our own kernel
  build (their sources ship in the SDK kernel tree and the vendor defconfig
  already sets them `=m`), loaded at boot via `/etc/modules-load.d/nanokvm.conf`.
  No `/kvmcomm/ko` blob copies are used (they are deleted from the image).
- **UI:** `nanokvm-display.service` runs `/opt/nanokvm-display/nanokvm_display.py`
  (`pkgs/nanokvm-display.nix`) — a small pure-stdlib-Python status screen
  (hostname, IP, live-stream state, HDMI input, firmware version, uptime) with
  inactivity sleep (backlight off after 3 min) and wake on the knob button.
  Fonts are generated at build time from source-built `terminus_font` — no new
  binary assets.

Full panel details, the blob-free story, and the sleep/wake behavior are in
[mini-display.md](mini-display.md).

---

## Runtime service model

`nanokvm.service` (and its `kvmcomm` sibling) follow the same vendor pattern:

- **`ExecStartPre` (`nanokvm_pre.sh`)** copies `/kvmapp` → `/dev/shm/kvmapp`
  (tmpfs) at boot. **Consequence:** on-device edits must go to the *persistent*
  `/kvmapp` to survive a reboot; the tmpfs copy is regenerated from it.
- **`ExecStart` (`nanokvm.sh`)** is a supervisor: it verifies/regenerates the
  HTTPS cert+key under `/etc/kvm/`, then `while true` restarts
  `/dev/shm/kvmapp/server/NanoKVM-Server` if it exits. After a target crash-loops
  **3×** it gives up (`exit 1`) — which is why a broken `libkvm` silently took the
  whole service down during bring-up.
- The server serves the React web UI + a JSON/WebRTC API on :80/:443, reads frames
  from `libkvm`, and exposes keyboard/mouse HID, storage/image mount, and the
  update flow.
- **`nanokvm-display.service`** (ours, independent of the two stacks above) runs
  the mini-display status daemon from `/opt/nanokvm-display`; it only reads
  `/dev/fb0`, the backlight sysfs, the knob evdev devices, and the server's
  loopback `/api/streamer/local` endpoint — see [mini-display.md](mini-display.md).

---

## From-source vs pinned blobs

The project's stance (from the blob audit) is: build everything we reasonably can,
and **link** Axera's redistributable media blobs rather than chase a blob-free
build that the AX630C doesn't support.

- **From source:** boot chain, kernel + DTS, `lt6911_manage.ko`, our `libkvm`, the
  Go server, the React web UI.
- **Pinned blobs, unavoidable on this SoC:**
  - `libax_*.so` / `libsns_dummy.so` — Axera userspace media libs. **BSD-3,
    redistributable.** Staged to `/opt/lib`.
  - `ax_*.ko` — Axera media kernel modules (venc/mipi/proton/ivps/…). GPL-tagged
    but source not published. They must `insmod` into our from-source kernel, so
    the kernel's `vermagic` (defconfig + GCC) must match — see
    [building.md](building.md#ax_ko-vermagic).
- **Pinned base:** the vendor Ubuntu 22.04 arm64 rootfs (v1 decision — matches the
  on-device ABI/systemd layout at lowest risk). A pure nix-built rootfs is the
  long-term north star.

The authoritative, enforceable list of every pinned blob (shipped and build-time)
and every runtime network endpoint — each with an explicit approval status — is
[provenance.md](provenance.md).
