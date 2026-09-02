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
                                └─► embedded initramfs /init
                                      └─► switch_root → /realroot → systemd
```

- The BootROM latches its boot source (eMMC vs SD vs USB) from the `CHIP_MODE`
  strap (the `User` button) at reset — it does not probe. The SD path is
  **file-based** (FAT32 + named images), not raw-offset; see
  [flashing-and-recovery.md](flashing-and-recovery.md#sd-card-boot).
- The kernel embeds an **initramfs**, whose `/init` reads `root=` from the
  cmdline and does `switch_root /realroot /sbin/init`. Removing it breaks the root
  mount — it must stay (`INITRAMFS_SOURCE`). It is built by `pkgs/initramfs.nix`:
  the vendor `/init` + `/show_iostat` scripts verbatim over a **static busybox +
  `e2fsck` from nixpkgs**, so no vendor binary is packed into the `Image`.
- **Secure boot** is gated on the efuse `SECURE_BOOT_EN`
  (`COMM_SYS_BOND_OPT @ 0x02340098`, bit 26). On the units checked it reads **0
  (off)**, so self-signed/unsigned firmware boots. Boot derivations default to the
  unsigned path.

Every stage — SPL/ATF/OP-TEE/U-Boot and the kernel — runs its console on
`ttyS0` (`0x4880000`), for the SD image as well as eMMC, matching the official
firmware. (An experimental UART1-redirect boot chain for SD was removed in
`86b8c58`: touching the still-clock-gated UART1 hung the SPL before any output.)

---

## Partition layout

The firmware is an Axera **`.axp`** (a ZIP of signed partition images). The eMMC
carries a 17-partition A/B layout. Our `image.nix` does a **streaming zip-rewrite**
of the pinned vendor base `.axp`, swapping in our from-source members by basename:

| `.axp` member(s) | Source | Notes |
|---|---|---|
| SPL / DDR-init / ATF / OP-TEE / U-Boot | `pkgs/boot.nix` | signed basenames match `make_axp_v2.py` |
| `boot_signed.bin` (+ A/B `.1`) | `pkgs/kernel.nix` → `pkgs/slot-image.nix` | `Image` → `ax_gzip -9` + 1 KB signed header |
| `dtb.img` (+ A/B) | `pkgs/dtb.nix` → `pkgs/slot-image.nix` | patched DTB → `ax_gzip -9` + signed header |
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
2. **Kernel modules** → `/lib/modules/4.19.125/`: our from-source modules only
   (incl. `lt6911_manage.ko`), `depmod`'d on a host staging tree so autoloading
   works with no on-device depmod. The prebuilt `ax_*.ko` are **deliberately
   excluded** — the build fails if any appear. Merging them in makes `depmod`
   emit `of:` aliases that udev coldplug autoloads parameter-less at boot;
   `ax_cmm` without its `cmm=` parameter panics and the device boot-loops
   (this bricked a unit on the first OTA). They stay in the vendor rootfs at
   `/soc/ko`, reachable only by `/soc/scripts/auto_load_all_drv.sh`, which
   insmods by path with the required parameters. That loader is **ours** since issue #39
   (`pkgs/rootfs/ax-load-drv.sh`), and since #55 M3 (#60, 2026-09-02) it loads
   **three from-source modules and zero vendor blobs**:
   `ax630c_venc_vcmd.ko` (open VC8000E encode, #25), `open_vin_csi2.ko` (open
   MIPI CSI-2 / D-PHY receiver, #57) and `open_vin_capture.ko` (open VIN/IFE
   bypass capture → V4L2 `/dev/video0`, #59). The vendor `ax_sys`/`ax_cmm`/
   `ax_pool`/`ax_base` base stack and the 10-module `ax_proton` capture closure
   are no longer loaded at all — device-proven from a cold boot. It also
   **splits the DMA pool** (#53): one `compute_mem_map` derives the whole map
   from the board's pool geometry and hands the open encoder
   (`framebuf_base/size`, `coherent_base/size`), the open capture driver
   (`carveout_base/size`) and — for the rollback loader — `ax_cmm`
   (`cmmpool=`) non-overlapping slices, printing the map at boot and exporting
   it to `/run/openkvm-memmap.env`; layout table and derivation rule in
   [vcmd-cma-unblock.md](vcmd-cma-unblock.md#dma-memory-map-53).
   The two vendor encode blobs
   (`ax_venc.ko`, `ax_jenc.ko`) are **removed from the flashed image**; the
   vendor capture blobs still ship, unloaded, purely as rollback material
   (their eviction is #54). Two rollback loaders ship beside ours:
   `auto_load_all_drv.sh.openvenc` (the previous curated set — 10 vendor
   capture blobs + open venc; needs a matching `.#kvm-encoder-openvenc`
   libkvm) and `auto_load_all_drv.sh.vendor` (the pristine 22-blob vendor
   script). Rolling back is `cp <name>.<variant> <name>` + reboot; restoring
   vendor *encode* needs a reflash, since that pair is gone. Keep/drop
   rationale:
   [blob-replacement.md](blob-replacement.md#module-curation-12-of-22-issue-39).
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
`kvmv_hdmi_control` / …) and drives an entirely **from-source** path end-to-end:

```
LT6911UXC HDMI→CSI-2
  └─► open_vin_csi2.ko    (D-PHY 4-lane, 600 Mbps, CSI-2 receiver)
        └─► open_vin_capture.ko  (VIN/IFE, ISP bypassed)
              └─► V4L2 /dev/video0  (YUYV, mmap + EXPBUF dma-buf)
                    └─► ax630c_venc_vcmd.ko  (open VC8000E, dma-buf zero-copy)
                          ├─► H.264 register program              → web stream
                          └─► from-source software JPEG (MJPEG)   → web stream
        └─► ALSA capture (LT6911 audio card) ─► Opus encode       → web audio
```

The host HDMI is captured as already-formed YUV (the LT6911 bridge does the
conversion), so the ISP is **bypassed** — no ISP/3A algorithm blobs are needed on
the KVM path.

**The shipped `libkvm` is the V4L2 build** (`.#kvm-encoder-v4l2`, flags
`openCapture` + `openVenc` + `v4l2Capture`; source `kvm_capture_v4l2.c`), the
default since #55 M3 (2026-09-02). Capture is plain V4L2 — `S_FMT` YUYV →
`REQBUFS` mmap → `EXPBUF` → `STREAMON` → `poll`/`DQBUF`. Each buffer's dma-buf
is imported **once** through the open VCMD driver's `HANTRO_IOCH_IMPORT_DMABUF`
ioctl (nr 38; `RELEASE` is 39), which resolves it to the bus address the
encoder register program consumes, so frames reach the encoder **zero-copy**;
the same mmap is the CPU view for the soft-JPEG MJPEG path and the mini-display
preview. Encode is our from-source open VC8000E path (`kvm_venc_open.c` over
`ax630c_venc_vcmd.ko`: H.264 register program + software MJPEG). The library
links **zero** `libax_*` — only `-ljpeg -lopus -lasound` — and nothing in the
path touches a vendor kernel module. The source format is `V4L2_PIX_FMT_YUYV`,
byte-identical to what the vendor pool used to hand back; the geometry envelope
is 64×64…3840×2160 (even dimensions), 30 fps sustained at both 4K and 1080p.

Earlier backends stay buildable as alternatives:
`.#kvm-encoder-openvenc` (raw-ioctl replay against the vendor `ax_proton`
capture closure — the shipped default from #25 until 2026-09-02, and the
partner of the `.openvenc` rollback loader) and `.#kvm-encoder` (the original
vendor-MPI build, which *did* link `-lax_venc -lax_sys -lax_proton -lax_mipi
-lax_ivps` and drove `AX_VENC`).

### Capture lifecycle & idle power-down

The pipeline is **lazy**: nothing is initialized until the first
`kvmv_read_img` call, which opens `/dev/video0`, sets the format, starts
streaming and brings the encoder up at the
*live* source geometry read from `/proc/lt6911_info` (`init_pipeline_locked`
in `libkvm.c`). Every streamer loop in the Go server (WebRTC, MJPEG, direct
H.264) exits as soon as its client count reaches zero, so frames are only ever
read while somebody is watching.

**Idle suspend (our addition):** the Go server hooks every frame/audio read
(`markVideoActive()` in the patched-in `common/video_power.go`; see
`pkgs/nanokvm-server.nix` + `pkgs/nanokvm-server/video-power.go.in`) and runs
a watcher that, after **`videoIdleTimeout` seconds without any read** (config
key in `/etc/kvm/server.yaml`; `0`/unset = **300 s**, negative = disabled),
calls our libkvm extension `kvmv_video_suspend()`:

- **Torn down:** the encoder instance and its frame buffers, then `STREAMOFF` +
  dma-buf release + `close()` on `/dev/video0` (which frees the capture
  carveout buffers), plus the ALSA/Opus HDMI-audio capture. This is the exact
  `kvmv_deinit` teardown sequence, re-used.
- **Deliberately kept powered:** the **LT6911UXC HDMI receiver**. Its only
  power control (`/proc/lt6911_info/power` → `lt6911_pwr_ctrl()` → the chip's
  PWR GPIO in `drivers/misc/lt6911_manage.c` — this is also what the legacy
  `kvmv_hdmi_control()` toggles) cuts the whole chip, including the EDID/HPD
  it presents to the attached host: the host would see its monitor unplug and
  rearrange the desktop. Partial savings with zero host-visible side effects
  wins.

**Resume** is synchronous and transparent: the first read after a suspend
(first viewer connecting, WebRTC or MJPEG alike) calls `kvmv_video_resume()`,
which re-runs the normal lazy-init path — including re-reading the live
`/proc/lt6911_info` geometry, so an **HDMI mode change while suspended** is
absorbed exactly like a fresh server start. Expected resume latency is the
normal first-frame bring-up (~1–2 s). Even if the explicit resume fails
(e.g. no HDMI signal at that instant), `kvmv_read_img` keeps retrying init on
every read, same as at process start. Suspend state is visible as
`"video_state": "active" | "suspended"` in `GET /api/streamer/local` (the
endpoint keeps working while suspended — it reads only `/proc` and in-memory
state), and in the logs (`video capture suspended after …` /
`OPEN-KVM: video pipeline suspended/resumed`). The mini-display's status poll
uses only that endpoint, never the read path, so it cannot keep capture awake;
it shows `asleep (power save)` while suspended.

No-signal behavior is unchanged: HDMI-unplugged with a viewer attached keeps
the pipeline up (reads continue, frames time out), and with no viewer the
ordinary idle timer suspends anyway.

**Load-bearing linker detail** (moot for the shipped V4L2 build, which links no
vendor library at all — but it bites the instant a `libax_*`-linking variant is
deployed, so it stays recorded): such a `libkvm` needs `DT_RPATH` (transitive),
**not** `DT_RUNPATH`. It `DT_NEEDED`s `libax_proton`, which in turn needs `libax_engine`.
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
  inactivity sleep (backlight off after 3 min), wake on the knob button, a
  knob-driven target power/reset page, and a **live HDMI preview** page fed
  from libkvm's frames (never a second capture pipeline). Fonts are generated
  at build time from source-built `terminus_font` — no new binary assets.

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
- **Logging:** `/var/log/nanokvm/NanoKVM-Server.log` is the server's redirected
  stdout+stderr (`nanokvm.sh` appends `>> $LOG_DIR/$exe_name.log`; `server.yaml`
  sets `logger.file: stdout`, so logrus never opens a file itself) — it carries
  both Go log lines and `libkvm`'s C-side output. Rotated by our
  `/etc/logrotate.d/nanokvm` (size 10M, `copytruncate` — mandatory, the server
  holds the fd open for its lifetime) via the vendor base's daily
  `logrotate.timer`. System logging is stock **`rsyslogd`** only: the vendor's
  closed `axbox` syslog/klog daemon, which `/etc/rc.local` used to start
  alongside it, is removed from the image (`docs/provenance.md`).
- **Vendor `wifi.service`** (`/etc/systemd/system/wifi.service`, `Type=simple`,
  `Restart=on-failure`, `RestartSec=3`) runs `/opt/scripts/wifi.sh start`, which
  `exit 1`s whenever `aic8800_fdrv` is already loaded. That turns "nothing to do"
  into a failure and the restart policy loops it forever — `RestartSec=3` puts 5
  attempts (~12 s) outside systemd's default 10 s `StartLimitIntervalSec` window,
  so the rate limiter never trips. On the device this ran up 2184 restarts and
  ~100 MB/week of journal + syslog churn onto eMMC. We ship
  `/etc/systemd/system/wifi.service.d/override.conf` with `Restart=no` (issue
  #43); the vendor unit and its `multi-user.target.wants` symlink are untouched,
  so the one-shot boot-time module load still happens.
- **`nanokvm-display.service`** (ours, independent of the two stacks above) runs
  the mini-display status daemon from `/opt/nanokvm-display`; it only reads
  `/dev/fb0`, the backlight sysfs, the knob evdev devices, and the server's
  loopback `/api/streamer/local` endpoint — see [mini-display.md](mini-display.md).

---

## From-source vs pinned blobs

The project's stance has shifted with progress: the original v1 goal was to
**link** Axera's redistributable blobs rather than chase a blob-free build. As
of #55 M3 (2026-09-02) the **entire video stack is blob-free down to the kernel
drivers** and the standing direction is a **zero-vendor-blob device, ISP
included** (Jeremy, 2026-08-30). What's pinned has shrunk accordingly:

- **From source:** boot chain, kernel + DTS, `lt6911_manage.ko`, the **open
  VC8000E encode driver** (`ax630c_venc_vcmd.ko`), the **open capture drivers**
  (`open_vin_csi2.ko` + `open_vin_capture.ko`), our `libkvm` (V4L2 capture +
  open encode, **zero `libax_*` linked**), `libsns_dummy.so`, the Go server, the
  React web UI.
- **No longer needed / removed:**
  - `ax_venc.ko` + `ax_jenc.ko` — the vendor **encode** kernel modules,
    **removed from the flashed image**; the open VCMD driver replaces them.
  - `libax_*.so` — the Axera userspace media libs are **purged from the flashed
    image** (`pkgs/rootfs.nix` step 5d1); nothing we ship links or `dlopen`s them.
- **Shipped but never loaded (rollback material, eviction is #54):**
  - the **capture** `ax_*.ko` kernel modules (`ax_proton`/`ax_mipi_rx`/`ax_vin`/
    `ax_ivps`/`ax_sys`/`ax_cmm`/…) — GPL-tagged, source not published. Our open
    drivers replace them outright; they stay on disk only so the `.openvenc` /
    `.vendor` rollback loaders work. While they are still on the image the
    `vermagic` constraint (defconfig + GCC) applies to them — see
    [building.md](building.md#ax_ko-vermagic).
- **Pinned base:** the vendor Ubuntu 22.04 arm64 rootfs (v1 decision — matches the
  on-device ABI/systemd layout at lowest risk). A pure nix-built rootfs is the
  long-term north star; the feasibility study, the systemd-vs-4.19 version wall
  that shapes it, and a buildable (not yet booted) NixOS scaffold are in
  [nixos-rootfs.md](nixos-rootfs.md).

The authoritative, enforceable list of every pinned blob (shipped and build-time)
and every runtime network endpoint — each with an explicit approval status — is
[provenance.md](provenance.md).
