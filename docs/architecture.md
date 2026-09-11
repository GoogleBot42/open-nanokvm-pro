# Architecture

How the NanoKVM-Pro appliance fits together, from power-on to a live web KVM.
The product is a **mainline NixOS appliance**: mainline TF-A, mainline U-Boot
and mainline Linux behind a blob-free first-stage loader, with a NixOS
generation on `/boot` and a blob-free video pipeline. For build mechanics see
[building.md](building.md); for flashing see
[flashing-and-recovery.md](flashing-and-recovery.md).

- [Hardware](#hardware)
- [Boot chain](#boot-chain)
- [eMMC layout](#emmc-layout)
- [Generations and `/boot`](#generations-and-boot)
- [Rollback](#rollback)
- [The video pipeline](#the-video-pipeline)
- [Load-bearing linker detail](#load-bearing-linker-detail)
- [Service model](#service-model)
- [Updates](#updates)
- [What is from source, and what is not](#what-is-from-source-and-what-is-not)

---

## Hardware

- **SoC:** Axera **AX630C** — 2× ARM Cortex-A53 (aarch64), a VeriSilicon
  **Hantro VC8000E** hardware video encoder (H.264/H.265/MJPEG), MIPI-CSI RX,
  and an Axera ISP (unused — see below).
- **HDMI-in:** a **Lontium LT6911UXC** HDMI→MIPI-CSI bridge converts the
  captured host HDMI signal to MIPI CSI-2 and recovers the embedded audio. Our
  `drivers/misc/lt6911-manage.c` (built in, `CONFIG_LT6911_MANAGE=y`) programs
  it over I2C and publishes resolution/format through `/proc/lt6911_info/`.
- **Storage:** eMMC, 31 272 730 624 bytes (29.1 GiB), measured 2026-09-09. The
  two 4 MiB eMMC boot partitions are blank and unreachable — which area the
  BootROM reads is a pin strap, and this board is strapped to the user area.
  There is also a microSD slot; nothing in the product uses it.
- **Console UARTs:** `ttyS0` @ `0x4880000` (the boot console, on hidden pads),
  `ttyS1` @ `0x4881000` (exposed header pin U1), `ttyS2` @ `0x4882000`. Every
  stage runs its console on `ttyS0`, which no cable on this unit reaches — so
  the boot is made observable through the slot register, ramoops and U-Boot's
  pre-console ring instead ([mainline-port.md](mainline-port.md)).
- **`User` button:** the reset-time `CHIP_MODE` strap. Hold ~10 s while
  powering on to enter USB download mode, which is how AXDL flashes the board.
  A normal power-on always boots eMMC.
- **Ethernet PHY:** a Realtek **RTL8211F** (PHYID `0x001cc916`, read over MDIO
  2026-09-06), not the JLSemi part the vendor device tree names. Both 2 ns RGMII
  delays are pin-strapped on, so `phy-mode` is `rgmii-id`.

---

## Boot chain

```
BootROM (mask ROM, unbrickable)
  └─► SPL  .#spl-minimal          blob-free, compiled for our layout
        └─► TF-A 2.15 BL31  .#atf-mainline    plat/axera/ax630c, ours
              └─► U-Boot 2026.07  .#uboot-mainline    our AX630C board port
                    └─► sysboot /boot/extlinux/extlinux.conf
                          └─► Linux 7.1.x  .#kernel-mainline-appliance
                                └─► NixOS stage 1 → stage 2 → systemd
```

**SPL** (`pkgs/spl-minimal.nix`). The AX630C BootROM reads the first-stage
loader from byte 0 of the eMMC user area, so byte 0 belongs to the ROM. The SPL
is the vendor bl1/SPL source recompiled for our layout: it finds BL31 and BL33
by **compile-time byte offsets**, generated from `nixos/lib/emmc-layout.nix`,
which is why the layout and the first-stage loader are one artefact — a layout
change is an SPL rebuild, and a bad SPL is an AXDL bench trip. OP-TEE and the
DDR-init partition are compiled out; both `*_BAK_FLASH_BASE` point at the A
bases, so the slot register's SLOT bits select between two identical addresses.

It is **blob-free** (#90): signed with an *empty* firmware member, so the closed
EIP-130 crypto-engine firmware is not spliced into the container at all. Nothing
documented said the BootROM would accept a header declaring `fw_size = 0`; it
does, proven across two warm reboots and a cold power cycle. `.#spl-minimal-eip`
rebuilds the vendor-shaped container with the firmware, kept as the fallback a
`dd` away should a unit ever refuse the empty one.

**BL31** (`pkgs/atf-mainline.nix`). Upstream TF-A v2.15.0 plus a new
`plat/axera/ax630c` platform carried as an upstream-shaped patch series. BL31
only: no SPD, no BL32, no secure services beyond PSCI `CPU_ON` / `CPU_OFF` /
`SYSTEM_RESET`. The SPL hands it a stock `bl_params_t` v2 chain, so it is an
ordinary loaded (non-`RESET_TO_BL31`) platform and the SPL needs no change to
boot it. Packaged exactly like the vendor's `atf_bl31_signed.bin`: `ax_gzip -9`
plus a 1 KiB signed header, 256 KiB, entered at `0x40040000`.

**BL33** (`pkgs/uboot-mainline.nix`). Upstream U-Boot 2026.07 plus the AX630C
board port in `pkgs/uboot-mainline/patches/`, 25 patches. The board support
proper is small: mainline already ships the two drivers the vendor forked
(`sdhci-cadence` for the eMMC's Cadence SD4HC, `ns16550` for the DesignWare
UART), and the SPL hands BL33 a SoC whose clocks, muxes and pads are already
programmed. The rest of the series is this board's own — the milestone and
`bootcount` registers, the GPT base LBA, the chainload slot. `bootcmd` runs
`sysboot` on `/boot/extlinux/extlinux.conf`. Signed and axgzip'd like BL31,
links at `0x5C000400`.

`bootdelay` is 0: there is no autoboot interrupt window, even over serial.

**A U-Boot candidate is tried through the one-shot chainload slot, never by
writing the `uboot` partition** — there is one copy and no B twin. U-Boot patch
0025 gives that partition its A/B property back as a *file*:
`nanokvm-uboot-test stage <raw u-boot.bin>` puts the candidate on `/boot` and
arms a token in flash which `bootcmd` **spends before it jumps**, so a candidate
runs exactly once even if it hangs at its first instruction (WDT0 then resets
into the production copy). Hardware-proven both ways, 2026-09-10.

**Kernel** (`pkgs/kernel-mainline.nix`, appliance variant). Linux 7.1.x from the
kernel.org tree our nixpkgs pin carries, with our config fragment
(`pkgs/kernel-mainline/ax630c.config`), our drivers grafted into
`pkgs/kernel-mainline/tree/`, and our device tree compiled from `dts/` by
`.#dtb-mainline`. No vendor SDK tree, no vendor defconfig, no vermagic contract,
no prebuilt `.ko` to stay ABI-compatible with. The version ceiling is 7.2,
asserted at build time: the out-of-tree aic8800 WiFi driver does not build above
it.

The appliance kernel embeds **nothing** — the initrd is the generation's. Almost
everything is built in; the only modules are the video stack's six and the
panel's two.

---

## eMMC layout

One layout, defined once in `nixos/lib/emmc-layout.nix` and derived everywhere
else (the SPL's compile-time offsets, the `blkdevparts=` clause, `fw_env.config`,
the NixOS `fileSystems`, the `.axp` manifest). Two logical devices:

| Region | Physical offset | Size | What |
|---|---|---|---|
| `spl` | `0x0` | 768 KiB | the BootROM's image. Outside every partition table |
| `disk` | `0xC0000` | rest of the device | carries a real GPT at **its own** LBA 0 |

Inside `disk`, a spec-conformant GPT — protective MBR at disk LBA 0 (physical
LBA 1536), header at disk LBA 1, entry array at LBA 2–33, alternate header at
the last LBA — with five partitions:

| # | Name | Size | Contents |
|---|---|---|---|
| 1 | `atf` | 1 MiB | signed BL31 |
| 2 | `uboot` | 2 MiB | signed BL33 |
| 3 | `env` | 1 MiB | the stored U-Boot environment (`.#uboot-env`) |
| 4 | `boot` | 272 MiB | ext4: `extlinux/`, `nixos/`, `ver` |
| 5 | `rootfs` | to `last_usable_lba` | the NixOS appliance ext4 |

`rootfs` starts at `0x115C0000` and an assertion in `emmc-layout.nix` keeps it
there — the SPL is compiled for the offsets in front of it.

**How each consumer reaches the table.** Linux cannot be told to parse a
partition table at an offset, so the kernel command line carries
`blkdevparts=mmcblk0:768K(spl),-(disk)` — two entries, whose only job is to hand
back `disk` as a block device — and stage 1 then runs `losetup -P /dev/loop0
/dev/mmcblk0p2`, at which point the in-kernel EFI parser creates
`/dev/loop0p1..5`. Root is `/dev/loop0p5`, `/boot` is `/dev/loop0p4`. U-Boot
reads the same GPT through `CONFIG_EFI_PARTITION_BASE_LBA=1536` (patch 0023).
`fw_setenv` addresses the `env` partition by physical byte offset and needs
neither.

**The eMMC is not reliably `mmcblk0`.** The three SD4HC instances probe
concurrently, and the `blkdevparts=` clause binds the split to a device *name* —
lose the race and the table lands on the empty SD slot while the eMMC comes up
with no partitions at all (two boots in five, measured in #78). Fixed by
`aliases { mmc0 = &emmc; ... }` in `dts/ax630c.dtsi`.

There are **no A/B twins**. The vendor map's pairs were always byte-identical,
and the slot register only ever chose between two copies of one image.

---

## Generations and `/boot`

`nixos/appliance.nix` is the system definition; `nixos/rootfs.nix` evaluates it
into a closure and packs a rootless ext4; `nixos/axp-image.nix` assembles the
flashable `.axp` from the same closure, so `.#nixos-firmware-image-mainline` and
the system it images cannot disagree.

**The kernel, the initrd and the device tree are part of the generation.**
`boot.kernelPackages` names `.#kernel-mainline-appliance` and
`hardware.deviceTree` names `.#dtb-mainline`, so a kernel change is a generation
change: it rolls back with everything else and needs no out-of-band copy.

**NixOS's own `boot.loader.generic-extlinux-compatible` builder is the only
writer of `/boot`.** Nothing in this repo renders an `extlinux.conf`. Run by
`switch-to-configuration boot`, it writes `/boot/extlinux/extlinux.conf` and
copies each generation's kernel, initrd and dtb into `/boot/nixos/`. `/boot` is
~51 MB of 245 MB usable at `configurationLimit = 3` and roughly 50 MB per
generation; `pkgs/bootfs.nix` asserts room for `configurationLimit + 1` at the
moment of a switch.

Two invariants, both load-bearing:

- **`boot.loader.timeout` must stay 0.** Any other value makes the builder emit
  a top-level `MENU TITLE`, U-Boot's `parse_pxefile_top()` then sets
  `cfg->prompt = 1`, and U-Boot waits forever on this board's unreachable
  console.
- **`init=` comes from the bootloader, per entry.** Each `LABEL`'s `APPEND`
  pins `init=<generation>/init`, which is what lets two config files name two
  different generations. The rootfs's `/init` symlink is a backstop, not the
  mechanism.

Stage 1 is classic (script) stage 1, not systemd-in-initrd: the failure mode of
a stage 1 that dies here is a board with no console and no autoboot window, and
a shell script that maps one loop device and mounts one ext4 is the smaller,
more inspectable thing. It sets `panicOnFail=1` from `preDeviceCommands` —
upstream's `fail()` is interactive and would otherwise block in `read` forever
while the kernel pets U-Boot's watchdog. The command line carries the bare
`boot.panic_on_fail` and `stage1panic=1` tokens as well; **`boot.panic_on_fail=1`
matches nothing**, because upstream's parser is a shell `case` over whole words.

A mainline boot is **71 seconds to SSH** (2026-09-10, one U-Boot attempt).

---

## Rollback

U-Boot increments `bootcount` in `TOP_CHIPMODE_GLB_BACKUP1` (`0x02390030`,
readable with `devmem 0x02390030 32`) on every boot: `0xB0010000` is healthy,
`0xB001000N` is N attempts since the last healthy boot. `bootlimit` is 3, so the
**fourth** attempt runs `altbootcmd`, which sets milestone bit 30 and boots
`/boot/extlinux/extlinux-fallback.conf` instead of `extlinux.conf`.

Both files carry the **same labels** — one per generation, each with its own
kernel and pinned `init=` — and differ only in which one `DEFAULT` selects.
`sysboot` boots a config's `DEFAULT` entry and cannot be told a label, so the
choice of generation is made by choosing a file.

`nanokvm-mark-good` (timer, `OnBootSec=60s`) is the health gate. It polls until
`systemctl is-system-running` says `running` and the system is routed and
serving, then clears the counter and **derives** the fallback by copying
`extlinux.conf` and setting `DEFAULT` to the label of the generation
`/run/booted-system` resolves to. It refuses, loudly, leaving the previous
fallback, if that label is not in the file — a `DEFAULT` U-Boot cannot match
falls through to the *first* label, which is the generation the rollback exists
to escape. It deletes nothing; the extlinux builder collects its own obsolete
kernels.

The failure mode is the safe one: if the unit does not run, the counter is not
cleared and the next boot counts one higher.

To exercise the rollback: `devmem 0x02390030 32 0xB001000A; reboot`. That proves
`bootcount_error()`, `altbootcmd`, bit 30 and the fallback config in one boot and
cannot strand the board — which is why it, and not a deliberately broken
generation, is the way to test it. Hardware-proven unattended 2026-09-09. Full
detail: [nixos-rootfs.md](nixos-rootfs.md) §4b.

---

## The video pipeline

Blob-free end to end, down to the kernel drivers.

```
LT6911UXC HDMI→CSI-2   (drivers/misc/lt6911-manage.c, built in)
  └─► open_vin_csi2.ko        D-PHY 4-lane, 600 Mbps, CSI-2 receiver
        └─► open_vin_capture.ko   VIN/IFE, ISP bypassed
              └─► V4L2 /dev/video0   (YUYV, mmap + EXPBUF dma-buf)
                    └─► ax630c_venc_vcmd.ko   open VC8000E, dma-buf zero-copy
                          ├─► H.264 register program   → web stream
                          ├─► H.265 register program   → web stream
                          └─► from-source software JPEG (MJPEG) → web stream
        └─► ALSA capture (LT6911 audio card) ─► Opus encode → web audio
```

The host HDMI arrives as already-formed YUV — the LT6911 bridge does the
conversion — so the ISP is **bypassed** and no ISP/3A algorithm blob is needed
on the KVM path.

**The three drivers live in the kernel tree**, at
`pkgs/kernel-mainline/tree/drivers/media/platform/axera/`, and come out of the
appliance kernel build as `.#video-modules`: six `.ko` (`videobuf2-common`,
`videobuf2-memops`, `videobuf2-v4l2`, `open_vin_csi2`, `open_vin_capture`,
`ax630c_venc_vcmd`), ~280 KB, laid out as `/lib/modules/<release>` with a
`load-order` file beside them. They are modular because the capture and encode
stack is the part still being brought up on hardware, and a driver fix should be
a file copy and an `insmod` rather than a reboot into a kernel with no automatic
rollback. Because `boot.kernelPackages` names the derivation `.#video-modules`
is built from, a generation carries the drivers it was built with by
construction.

**`libkvm.so`** (`.#kvm-encoder`, `pkgs/kvm-encoder.nix`) is the userspace half:
our open reimplementation of Sipeed's withheld glue, implementing the
`kvm_vision.h` ABI the Go server links against (`kvmv_init` / `kvmv_read_img` /
`kvmv_read_audio` / `kvmv_set_fps` / `kvmv_hdmi_control` / …). There is **one
build** and it links no vendor library at all — only `-ljpeg -lopus -lasound`.
Capture is plain V4L2 (`S_FMT` YUYV → `REQBUFS` mmap → `EXPBUF` → `STREAMON` →
`poll`/`DQBUF`); each buffer's dma-buf is imported once through the VCMD driver's
`HANTRO_IOCH_IMPORT_DMABUF` ioctl, which resolves it to the bus address the
encoder register program consumes, so frames reach the encoder zero-copy. The
same mmap is the CPU view for the software-JPEG MJPEG path and the mini-display
preview.

The pipeline is **lazy**: nothing is initialized until the first
`kvmv_read_img`, which opens `/dev/video0`, sets the format from the live
geometry in `/proc/lt6911_info`, starts streaming and brings the encoder up.
Every streamer loop in the Go server exits when its client count reaches zero.
After `videoIdleTimeout` seconds with no read (`/etc/kvm/server.yaml`; unset =
300 s, negative = disabled) the server calls `kvmv_video_suspend()`, which tears
down the encoder, the capture buffers and the ALSA/Opus capture. The **LT6911
receiver stays powered** on purpose: its only power control cuts the whole chip
including the EDID/HPD it presents to the attached host, which would make the
host see its monitor unplug. Resume is synchronous on the next read and re-reads
the live geometry, so an HDMI mode change while suspended is absorbed like a
fresh start. State shows as `"video_state"` in `GET /api/streamer/local`.

**One capture channel serves every viewer**, gated by the global
`KvmVision.StreamType`. A second viewer in another mode takes the stream and
starves the first; `service/stream/claims.go` hands it back to whoever still has
clients when a consumer empties. Two viewers at once still means one is starved
— that is arbitration, not a bug.

**The Go server** (`.#nanokvm-server`) is upstream Sipeed's `server/` plus
nix-time patches (`pkgs/nanokvm-server.nix`): it links `libkvm.so` through cgo,
drives the ATX lines through `nanokvm-gpio`, serves the web bundle from
`<execdir>/web` with our own static handler (hashed `assets/` `immutable` for a
year, `index.html` and every other non-hashed file `no-cache` with a strong
content ETag), and hands the web UI's update button to `nanokvm-update`.

**The web UI** is our fork of Sipeed's `NanoKVM-Pro/web`, vendored in-tree at
`web/` (upstream `8d0557b`, GPL-3.0 — `web/FORK.md`) and built by
`.#nanokvm-web`. It has two players: **WebCodecs direct**, a `VideoDecoder` in a
worker drawing onto an `OffscreenCanvas` (lowest latency), and **MSE**
(`mse-player.tsx`), which remuxes each message into fragmented MP4 and appends it
to a `SourceBuffer` on a `<video>`. On Linux both Firefox and Chrome play HEVC in
`<video>` but reject every HEVC configuration in WebCodecs'
`isConfigSupported`, so H.265 reaches them only through MSE. Never assert
browser codec support without measuring it.

Capture-pipeline internals and the reverse-engineering history are in
[blob-replacement.md](blob-replacement.md) and
[deblob-capture.md](deblob-capture.md); the encoder driver's bring-up is
[vcmd-cma-unblock.md](vcmd-cma-unblock.md).

### Load-bearing linker detail

`libkvm.so` must carry **`DT_RPATH`, not `DT_RUNPATH`**. `DT_RUNPATH` is
searched only for a library's *own* direct dependencies; `DT_RPATH` is inherited
down the whole dependency chain. A `libkvm` whose transitive dependencies are
not on `ld.so`'s path resolves fine from an SSH shell (which has
`LD_LIBRARY_PATH`) and crash-loops under systemd (which does not) — that
signature is always this.

Both places that produce a `libkvm.so` therefore use `patchelf --force-rpath`:

- `pkgs/kvm-encoder.nix` sets `/opt/lib:<axera-libs>/lib`. The second entry is a
  leftover of the era when the same source built a vendor-backend variant; the
  build links no `libax_*` any more, so nothing resolves through it.
- `nixos/appliance.nix`'s `kvmapp` derivation **re-rpaths it** to
  `/opt/lib:<opus>/lib:<alsa>/lib:<jpeg>/lib`. That is not cosmetic: in a Nix
  closure the `axera-libs` store path is a *reference*, and leaving it would drag
  the entire closed Axera library set into an image that is supposed to contain
  none of it. Both `libkvm.so` and `libkvm.so.0` are patched — they are two real
  files, not a symlink pair — and the derivation greps both, plus the server
  binary, for `axera-libs` and fails the build if any survives.

`/opt/lib` exists on the appliance because `NanoKVM-Server`'s own `DT_RUNPATH` is
the bare, store-free `$ORIGIN/dl_lib:/opt/lib:/opt/usr/lib`. It holds exactly
three open libraries: `libopus.so.0`, `libasound.so.2`, `libjpeg.so.8`.

---

## Service model

Everything is declared in `nixos/appliance.nix`. There is no vendor
`kvmcomm.service` on this image and no vendor `nanokvm.sh` supervisor; the three
things that script did — the tmpfs copy, the restart loop, the HTTPS cert — are
three units.

| Unit | What it does |
|---|---|
| `nanokvm-video` | `insmod`s the six video modules in `load-order`, then waits for `/dev/video0`. The oracle is not a formality: every module can load cleanly and still leave no pipeline |
| `nanokvm-panel` | same shape for the two panel modules (`fbtft`, `fb_jd9853`), oracle `/dev/fb0`. A separate unit on purpose — a panel that did not come up must not read as a capture failure |
| `nanokvm-appdir` | copies `/kvmapp` → `/dev/shm/kvmapp` (tmpfs). Its own unit, not an `ExecStartPre`: systemd applies `WorkingDirectory=` to every `Exec*` line |
| `nanokvm-cert` | generates the self-signed per-device HTTPS cert under `/etc/kvm` if absent. Without it the server binds both ports and exits 1 |
| `nanokvm` | the Go server, `WorkingDirectory=/dev/shm/kvmapp/server`, `Restart=on-failure`, stdout appended to `/var/log/nanokvm/NanoKVM-Server.log` |
| `nanokvm-display` | the mini-display status daemon — [mini-display.md](mini-display.md) |
| `nanokvm-identity` | derives the MAC and the transient hostname from the SoC UID, ordered before `network-pre.target` |
| `nanokvm-checkboot` | re-arms the A/B slot register. Under this layout the slot bits select nothing; the unit keeps them deterministic, which is what makes the milestone register a readable oracle instead of a value that alternates every boot |
| `nanokvm-mark-good` | the rollback health gate (timer, `OnBootSec=60s`) — see [Rollback](#rollback) |
| `nanokvm-uboot-test-clear` | consumes the one-shot U-Boot chainload slot |
| `nanokvm-update`, `nanokvm-update-reboot`, `nanokvm-gc` | the update path, each with its own timer — see [Updates](#updates) |
| `nanokvm-wifi` | loads the two aic8800 modules (`nixos/wifi.nix`, only with `nanokvm.wifi.enable`) |
| `nanokvm-usb` | **stub**. The dwc3 glue and the configfs function drivers are in the kernel, but `usbdev.sh` — the script that builds the gadget — is vendor-only and not captured yet: no HID, no mass storage |

**There is no ATX GPIO unit**, and that is a result rather than a gap. Consumers
address lines by their device-tree name (`atx-power`, `atx-reset`,
`atx-power-led`, `atx-hdd-led`), and requesting a line runs through
`gpio-ranges` → `gpio_request_enable()` so the pin controller programs the pad.
The tool is `nanokvm-gpio` (libgpiod v2), which the server reaches by absolute
store path. This retires the vendor-era sysfs export, the `devmem` pad poke and
the server's per-press pinmux re-assert.

**`serverPath`** is the appliance's most easily missed contract:
`environment.systemPackages` does *not* set a unit's PATH, so `nanokvm.service`
carries an explicit one derived from a full grep of the server's `exec.Command`
calls. The server is the parent of the shell helpers it execs, `wifi.sh` among
them, so they inherit it. Known-absent and documented: `chronyc` (we run
timesyncd) and `dpkg`/`tailscale`.

**WiFi** has three pieces, each somewhere a reader would not guess
(`nixos/wifi.nix`): the modules are out-of-tree from `radxa-pkg/aic8800`, built
against the appliance kernel and loaded by `nanokvm-wifi`; the firmware goes
through `hardware.firmware` with `firmwareCompression` off, because the driver
builds with `CONFIG_USE_FW_REQUEST=n` and `filp_open`s a literal compiled-in
path; and the web UI's WiFi page drives `/kvmcomm/scripts/wifi.sh` with the verbs
`try_scan` / `connect_start` / `connect_stop` / `ap_stop`, a path the server
compiles in, which the appliance provides as a shim rather than inventing a new
one. AP mode is not implemented.

---

## Updates

An update is a **signed Nix closure**. A release publishes ~200 bytes —
`.#system-manifest`, naming a toplevel store path — and pushes that closure to a
binary cache. The device runs `nix copy --from <cache>` with `require-sigs` and
its **own** `trusted-public-keys` (passed on the command line, never read from
`/etc/nix/nix.conf`), then `nix-env -p /nix/var/nix/profiles/system --set`, then
`switch-to-configuration boot`. Only what the board is missing crosses the wire,
and a NAR nobody trusted signed does not install. Nix runs single-user; the image
ships a **registered** store, because a directory of store paths is not a store.
Unattended updates are a web-UI checkbox and reboot only when the server's
loopback `/api/update/idle` route says nobody is connected. The cache URL and its
key are placeholders until #96. Hardware-proven end to end 2026-09-11. Full
detail — trust, GC, the manifest, local testing — is
[updates.md](updates.md); cutting a release is [releasing.md](releasing.md).

---

## What is from source, and what is not

Everything on the image is built from source except the **aic8800 radio
firmware**, which is the only closed content the blob policy permits and is only
present with `nanokvm.wifi.enable`. Two build-time assertions keep it that way:
`nixos/appliance.nix`'s `kvmapp` derivation fails if `libkvm.so` or the server
still references `axera-libs` after the re-rpath, and
`nixos/lib/appliance-artifacts.nix` fails if any `axera-libs`, `ax-ko-blobs` or
`libsns-dummy` path appears in the image closure at all.

Three vendor-derived *inputs* are still read at build time, and these are all of
them:

- **`maix_ax620e_sdk`** — for the bl1/SPL source `.#spl-minimal` recompiles, the
  `imgsign` signing tool `pkgs/ax-sign.nix` drives, and the two FDL download
  agents the AXDL flasher pushes into BootROM RAM (`pkgs/boot.nix` builds both
  from SDK sources). Nothing out of this tree boots, and only the FDLs ride in
  the `.axp` — flash-time only, never stored on the eMMC.
- **`maix_ax620e_sdk_msp`** — for the Axera `ax_*.h` **headers** the blob-free
  `libkvm` compiles against, for the SDK's frame and stream types. No library
  from it is linked or shipped.
- **`nanokvm-pro-src`** — upstream Sipeed's Go server (GPL-3.0). Source, patched
  at nix time.

The enforceable list of every pinned input and every runtime network endpoint,
each with an approval status, is [provenance.md](provenance.md).
