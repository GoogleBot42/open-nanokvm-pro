# Pure-Nix rootfs — the NixOS appliance (#26, #78)

The vendor Ubuntu 22.04 arm64 rootfs (`pkgs/base-axp.nix` → `pkgs/rootfs.nix`)
replaced by a system built entirely from nixpkgs, on the mainline kernel.

**Status (2026-09-07, #78): implemented, and it boots — under QEMU.**
`nixos/appliance.nix` evaluates against the flake's one `nixos-unstable` pin and
runs on `pkgs/kernel-mainline` (Linux 7.1.3), with the NixOS stage-1 initrd
embedded in the kernel Image. Two `qemu-system-aarch64 -M virt` boots are banked
in [`docs/reference/mainline/nixos-appliance-20260907/`](reference/mainline/nixos-appliance-20260907/README.md):
the second reaches `multi-user.target` with **zero failed units** and
`NanoKVM-Server` listening on `:80` and `:443`.

**It has not been booted on the device.** Nothing in #78 has touched hardware.
Everything below that concerns the AX630C itself — the identity derivation, the
loop-image root, `/etc/fw_env.config` against the real U-Boot environment, the
A/B slot re-arm — is derived from source and unproven on silicon.

- [Verdict](#verdict)
- [The boot contract](#the-boot-contract)
- [The blob-policy assertion](#the-blob-policy-assertion)
- [Approaches weighed](#approaches-weighed)
- [What is built](#what-is-built)
- [Known gaps](#known-gaps)
- [Validation ladder](#validation-ladder)
- [History: the systemd ceiling](#history-the-systemd-ceiling)

---

## Verdict

**A full NixOS system, on the flake's single `nixos-unstable` pin, booting the
from-source mainline kernel.**

The second nixpkgs pin is gone. `nixpkgs-rootfs` (`nixos-24.11`) existed for
exactly one reason — systemd's declared minimum kernel had risen to 5.4 and then
5.10 while the `ax_*.ko` vermagic contract held this board on Linux 4.19.125 —
and both halves of that argument are dead: the image has carried no vendor
kernel module since #54, and the appliance now runs 7.1.3, far above the floor.
The input is removed from `flake.nix`; the appliance evaluates against the same
pin as every other output. The whole argument is kept as
[history](#history-the-systemd-ceiling), because it is why the second pin ever
existed and because the version table is a useful record.

This removes the Ubuntu surface at once: `apt` (`ports.ubuntu.com`),
`motd-news`, `chrony`'s hardcoded `time.{windows,apple,google}.com`, the
retained closed `kvmcomm` tree, and the last of the "the running stack is
vendor-origin, not our pin" nuance in [provenance.md](provenance.md). On this
image nothing closed executes at all — see
[the blob-policy assertion](#the-blob-policy-assertion).

The costs that remain:

| Cost | Detail |
|---|---|
| **OTA redesign** | `pkgs/update-package.nix` overlays *files* into `/kvmapp`, `/opt/lib`, `/usr/lib/modules`. A NixOS rootfs is a store closure; an update becomes "import a closure, `switch-to-configuration`". [updates.md](updates.md) has to be rewritten — #86. |
| **Vendor scripts** | `/kvmapp/scripts/usbdev.sh` (the whole USB-gadget HID / mass-storage / NCM / UAC2 path the server shells out to) exists **only in the shipped vendor rootfs** — it is not in the public `NanoKVM-Pro` repo. See [gap 2](#known-gaps). |
| **WiFi** | `aic8800_*.ko` + `/opt/firmware/aic8800/*.bin`. Needs its own build against the mainline kernel — #85. |
| **The `rc.local` glue** | `S99checkboot` is now a unit and is live (below). `axemac.sh`, `npu_set_bw_limiter.sh` and a bare `devmem` poke are not. |
| **No hardware yet** | Video (#83) and USB HID (#82) are stubs on this kernel, and the mini-display (#84) has no framebuffer to draw on. ATX works in principle — #81 landed, and the appliance ships `nanokvm-gpio` and the libgpiod server build — but has never been exercised on the board. The appliance boots, serves the web UI and answers SSH; it is not yet a working KVM. |
| **Boot risk** | The rootfs is the one thing between U-Boot and a working device, `bootdelay=0` means there is no serial break-in, and recovery is physical AXDL. |

---

## The boot contract

What the running system owes the boot chain, and what it needs *from* the
rootfs. Sources: `nixos/appliance.nix`, `nixos/rootfs.nix`,
`pkgs/kernel-mainline.nix`, the server source, the QEMU runs, and
[mainline-port.md](mainline-port.md) §5–6.

### 1. Stage 1 is embedded in the kernel Image

There is no bootloader in the NixOS sense. BootROM → SPL → ATF → OP-TEE →
U-Boot (all `pkgs/boot.nix`), and `do_axera_boot()` raw-reads the `kernel`/`dtb`
partitions **by name**, decompresses them and calls
`booti 0x40200000 - 0x40001000`. The `-` is the ramdisk argument: **U-Boot
passes no initrd**, and no partition holds one. So the initrd has exactly one route onto this board —
`CONFIG_INITRAMFS_SOURCE`, baked into the Image.

`pkgs/kernel-mainline.nix` therefore takes the cpio as a parameter and builds
two variants:

| Variant | Initramfs | Compression |
|---|---|---|
| `bringup` (#75–#77) | the static-musl boot-evidence `/init` | `NONE` (100 KB, byte-for-byte reproducible) |
| `appliance` (#78) | the NixOS stage-1 initrd | `ZSTD` — 25 MB of cpio → 6.8 MB; the signed slot image is 23.5 MB against the 64 MiB partition |

The compression choice `depends on INITRAMFS_SOURCE != ""`, so it is set from
the Nix build *before* the config fragment is merged; merging it into a config
with no source silently drops it and the next `olddefconfig` picks the choice's
first member, gzip. The build asserts that both the source path and the
requested compression survived.

`boot.initrd.compressor = "cat"` in the appliance is the other half of this:
`nixos/rootfs.nix` checks the initrd really is a plain `newc` cpio (magic
`070701`) before handing it over, because `usr/Makefile` embeds a single `.cpio`
source verbatim and then compresses it once. Compress it in NixOS as well and
the Image just gets bigger.

### The `/dev/console` trap

**The kernel always unpacks a built-in initramfs.** With
`CONFIG_INITRAMFS_SOURCE` empty it unpacks `usr/default_cpio_list`, whose entire
content is `/dev`, `/dev/console` and `/root`. On an ordinary machine the
bootloader hands the initrd over separately, that default list still runs, and
`/dev/console` exists before PID 1 starts — which is why a NixOS initrd has
never had to carry device nodes.

Setting `INITRAMFS_SOURCE` **replaces** that list. PID 1 then starts with fd
0/1/2 closed, and NixOS stage 1 dies on its first `exec 8>&1` before it can
redirect anything to `/dev/kmsg`:

```
[    0.577414] Warning: unable to open an initial console.
[    0.612187] Run /init as init process
[    0.935491] Kernel panic - not syncing: Attempted to kill init! exitcode=0x00000100
```

Nothing in between. On the real board that is a kernel which reaches userspace,
prints nothing and resets — through the #75 milestone channel it is
**indistinguishable from a kernel that hung** (`0x00000014` either way).

`nixos/rootfs.nix` appends a three-entry cpio (`dev`, `dev/console`, `dev/null`)
after the NixOS archive, built under `fakeroot` because the build sandbox cannot
`mknod`. The kernel's unpacker resets at each `TRAILER!!!` and keeps going,
which is exactly how concatenated initramfs images are supported.

### 2. No `init=`, and why `/init` is the generation switch

The command line comes from the **U-Boot environment**. `booti` →
`image_setup_libfdt()` → `fdt_chosen()` writes env `bootargs` over
`/chosen/bootargs`, so the device tree's copy loses
([mainline-port.md](mainline-port.md) §5, trap 2). We do not write that
environment, so there is no `init=` on the command line and there cannot be one.

NixOS stage 1 falls back to its built-in default, `stage2Init=/init`, and
`switch_root`s to `$targetRoot/init`. The image ships:

```
/init      -> /nix/var/nix/profiles/system/init
/sbin/init -> /nix/var/nix/profiles/system/init
```

`/sbin/init` costs a symlink and is what the vendor initramfs would exec if this
image were ever booted by the 4.19 kernel. `/init` is the live contract:
**updating the system profile is the whole of a generation switch** — no
bootloader, no config file, no partition write. `boot.loader.external` owns
"install" for the kernel/dtb half and is deliberately inert until #79 puts a
health gate in front of the A/B slot flip; it prints what it did rather than
failing a switch.

`nixos/rootfs.nix` asserts all of this offline, with `debugfs` against the built
ext4: both symlinks are symlinks, the profile resolves, stage 2 is in the
closure, and `<toplevel>/init` starts with `#!`.

### 3. fsck and grow

Stage 1 does both, so the vendor `/init`'s static-e2fsprogs dance is gone.
`fileSystems."/"` sets `autoResize` (partition root only), which pulls
`resize2fs` into the initrd and grows the filesystem to the partition — the
image is packed by `make-ext4-fs`, which shrinks it to its contents, so an
unresized partition root sits at ~1 GB inside a ~29 GB `p17`. The fsck is stage
1's ordinary `fsck.ext4 -a`; the QEMU log shows both
(`NANOKVM: clean, 47190/151088 files, 333469/601663 blocks`, then
`EXT4-fs (vda): resizing filesystem`).

### What the vendor `/init` did, for reference

Kept only because it is what you are reading when you read a *vendor* boot. The
script is `[SDK]/build/projects/<project>/initramfs/init`, carried verbatim by
`pkgs/initramfs.nix` (extractable from `.#initramfs`). It mounted `/proc`,
`/sys`, `/dev`; parsed `root=`; mounted `/boot`; offered USB-mass-storage
recovery on `/boot/rec`; grew the rootfs if `/boot/check_resize2fs` existed, by
copying `/realroot/opt/e2fs-static/{tune2fs,resize2fs}` out of the rootfs it was
about to mount; `e2fsck`'d and mounted the real root at `/realroot`; wrote
`/realroot/device_key`; derived the MAC and sed-edited it into
`/realroot/etc/network/interfaces`; and `exec switch_root /realroot /sbin/init`.
Every one of those jobs is now a NixOS mechanism or a unit.

### 4. `/boot` — p16, vfat, and it must stay writable

This contract is unchanged and is not optional. `NanoKVM-Server` writes
`/boot/eth.nodhcp`, `/boot/hostname`, `/boot/usb.disk0`, `/boot/usb.ncm`,
`/boot/usb.uac2`, `/boot/usb.disk1.{sd,emmc}` and reads `/boot/ver`; the module
loader sources `/boot/configs`; the vendor boot path uses `/boot/rec`,
`/boot/first_time_boot` and `/boot/check_resize2fs`. Every USB-gadget feature is
gated on a flag file there.

The appliance mounts it `nofail,noatime,umask=000` on `parts.bootfs.device`
(p16, derived — see below). `nofail` so a missing or corrupt vfat cannot hold
up a boot; `umask=000` matches the device.

Mounting FAT needs kernel config that a minimal fragment does not get by
default, so `pkgs/kernel-mainline/ax630c.config` pins `CONFIG_VFAT_FS`,
`CONFIG_NLS_CODEPAGE_437` and `CONFIG_NLS_ISO8859_1` (plus `NLS_UTF8`). Without
the NLS tables the mount fails with `-EINVAL` and every USB-gadget flag silently
reads as absent.

### 5. Identity — the MAC is derived on every boot, not stored

**This is the biggest correction in this document.** A note written during #77
said the MAC was a provisioning-time literal in `/etc/network/interfaces`. It is
not. The vendor `/init` **recomputes it on every single boot** from
`/proc/ax_proc/uid` and sed-writes the `hwaddress ether …` line back into that
file. The file is a *cache*; the SoC UID is the source. The artifact that
settles it is the vendor `/init` script itself, carried verbatim by
`pkgs/initramfs.nix` and extractable from `.#initramfs`.

The derivation, which `nanokvm-identity.service` now reproduces byte for byte:

```
device_key = field 2 of /proc/ax_proc/uid, with the leading "0x" stripped,
             written to /device_key WITH a trailing newline
HHLL       = first 4 hex chars of `sha512sum /device_key`   (the hash is OF THE FILE)
MAC        = 48:da:35:6d:HH:LL
hostname   = kvm-HHLL
```

Two small divergences, both deliberate: the vendor writes the hostname only when
`/boot/first_time_boot` exists, ours sets it unconditionally (same input, same
output, no first-boot state to lose); and the vendor's two writes target
ifupdown files that on NixOS are read-only store symlinks, so a straight port
would silently fail and leave a kernel-random MAC — breaking the DHCP
reservation and the address `tools/kvmssh` knows. The unit sets the hostname
with `hostnamectl` and the MAC with `ip link set … address`, ordered `before
network-pre.target` and `systemd-networkd.service` but pulled by
`multi-user.target` (a bare `wantedBy = network-pre.target` is passive and never
fires in this closure — a defect fixed in the scaffold and kept fixed).

**Where the UID comes from on mainline.** There is no `/proc/ax_proc/uid`: that
node is a vendor kernel patch. The UID lives in the `misc_info_t` structure the
bootloader leaves in IRAM0, and the gap that closed here is *where IRAM0 is*.
[mainline-port.md](mainline-port.md) §10 listed it as "the `0x740` offset is
verified, the IRAM0 base is not". The vendor's own GPL driver settles it:
`drivers/soc/axera/ax_hwinfo/ax_hwinfo.c` does
`ioremap(MISC_INFO_ADDR, sizeof(misc_info_t))` with `#define MISC_INFO_ADDR 0x740`
and **no base added**, so IRAM0 is at physical 0 and `misc_info` is at physical
`0x740`. The struct (`include/linux/soc/axera/ax_boardinfo.h`) is
`pub_key_hash[8]`, `aes_key[8]`, `board_id`, `chip_type`, `uid_l`, `uid_h` — so
`uid_l` is at `0x788` and `uid_h` at `0x78c`, and the UID string is
`printf '%08x%08x' uid_h uid_l`.

**How it is read, and why `CONFIG_DEVMEM` stays on.** The unit reads those two
words with `busybox devmem`, which `mmap()`s `/dev/mem`. `read(2)` on `/dev/mem`
cannot work here: it goes through `xlate_dev_mem_ptr()`, a linear-map
translation that is meaningless for a page that is not System RAM. `mmap` is the
only route and `devmem` is the tool that takes it. That makes `/dev/mem` a
deliberate policy decision on the appliance rather than a bring-up leftover, and
`pkgs/kernel-mainline/ax630c.config` records it with its three consumers: this
identity read, `nanokvm-checkboot`'s A/B slot-register write, and the whole
vendor script layer (plus every debugging session this project has had on this
board). `STRICT_DEVMEM` and `IO_STRICT_DEVMEM` stay off; the appliance's only
account is root.

The unit tries `/proc/ax_proc/uid` first and `/dev/mem` second — the first path
exists so the derivation can be validated against the value the device has
always used, by running the same script on a vendor boot. If neither yields a
plausible UID (zero or all-ones is rejected) it leaves the kernel's MAC in place
and logs loudly rather than inventing one.

**Unproven on hardware.** QEMU has no `misc_info` at `0x740`, so the run-2 log
shows the "no SoC UID available" path taken and `device_key: (none)`. The
arithmetic is exercised nowhere yet.

### 6. The eMMC map, and `/etc/fw_env.config`

This eMMC has **no on-disk partition table at all**. Its layout is the
`blkdevparts=mmcblk0:…` clause of the kernel command line: U-Boot's
`get_part_info()` parses it to find `kernel`/`dtb`/`rootfs` by name, and Linux
turns it into `/dev/mmcblk0pN` via `CONFIG_CMDLINE_PARTITION`.

`nixos/emmc-partitions.nix` parses that same clause out of
`dts/ax630c-nanokvm-pro.dts` and folds it once into partition numbers and byte
offsets. Three numbers that used to be hand-copied into three different files —
p16, p17, and the U-Boot environment offset — now come from the one string the
bootloader itself reads, and the module `assert`s the shape it expects: 17
partitions, `rootfs` at p17, `boot` at p16, and `env` at offset `0x4C0000` size
`0x100000` (the sum of the six partitions before it: `spl`, `ddrinit`, `atf`,
`atf_b`, `uboot`, `uboot_b`). The A/B slot pairs come from the same parse, so
nothing downstream has to remember which number is which.

**Gap 3's `fw_env.config` TODO is closed.** `environment.etc."fw_env.config"` is
`/dev/mmcblk0 0x4C0000 0x100000` — computed, asserted, and neither a guess nor a
device capture. `nanokvm-checkboot.service` is therefore **live for the first
time**; it was inert in the scaffold for want of this file. It reads `fw_printenv
-n bootsystem` and re-arms the current slot (`devmem 0x2390028 32 0x10` for A,
`0x20` for B). `bootsystem` is written **uppercase** `A`/`B` by U-Boot's
`set_slot_ab`, while the vendor's own script writes lowercase in places, so both
are accepted; anything else refuses to write the register. The QEMU run took
exactly that path (`bootsystem='' not a/b — refusing to write the slot
register`), which is the behaviour the code was written for.
`nanokvm.checkboot.enable` turns the unit off for exactly one case — the reversible slot-B test, where not
re-arming is the whole safety argument (step 4 of the
[validation ladder](#validation-ladder)).

`nix flake check` gains **`emmc-partition-map`**, a pure-eval text file printing
all 17 partitions with offsets and sizes plus the resulting `fw_env.config`.
That map also settles a documentation error: **OP-TEE is p10/p11; p8/p9 are
`logo`/`logo_b`.** `pkgs/boot.nix`'s header comment said OP-TEE was p8/p9 and
[updates.md](updates.md) had `logo` at p10/11; both are corrected.
(`pkgs/image.nix` already had it right.)

Two caveats that remain owed:

- **The env location has never been hexdumped against the real device.** Verify
  before the first `fw_setenv`, not after.
- **U-Boot rewrites the environment twice per boot** (`set_slot_ab`,
  `update_cmdline`), so a userspace `fw_setenv` must not race a reboot.

### 7. Init system — and the SysV layer nobody documented

systemd, and now nothing else. The vendor image ran a live `rc-local.service`
whose `/etc/rc.local` was the real boot glue:

```bash
bash /etc/init.d/axemac.sh                      # eth0 RPS/RFS + ethtool -A rx on
bash /soc/scripts/auto_load_all_drv.sh          # THE ax_*.ko loader
bash /soc/scripts/npu_set_bw_limiter.sh start
devmem 0x10030028 32 0x000006A0                 # undocumented register poke
bash /etc/init.d/axsyslogd start ; bash /etc/init.d/axklogd start
bash /etc/init.d/S99checkboot start
bash /etc/init.d/S99checkota start
systemctl is-active --quiet sysdev.service || systemctl enable --now sysdev.service
```

What survives on the appliance:

- **`S99checkboot` → `nanokvm-checkboot.service`**, live (above). The SPL
  *consumes* the current slot's BOOTABLE bit on the way in, so a boot that never
  re-arms it is a boot that falls back next time. #79 is what puts a health gate
  in front of that instead of re-arming unconditionally the way the vendor does.
- **`S99checkota`** (the OTA-commit `fw_setenv` clears) belongs with the OTA
  redesign, #86.
- **The module loader is gone**, along with `/soc/ko` and `/soc/scripts`. There
  are no modules to load (below). The `#!/bin/sh`-but-actually-bash trap in the
  vendor `/soc/scripts/*.sh` set therefore no longer applies to anything the
  appliance runs; it still applies to anything you run by hand on a vendor boot.
- `axemac.sh`, `npu_set_bw_limiter.sh` and the `0x10030028` poke are still
  unimplemented — [gap 3](#known-gaps).

The units the appliance actually declares: `nanokvm-appdir`, `nanokvm-cert`,
`nanokvm`, `nanokvm-identity`, `nanokvm-checkboot`, `nanokvm-display`, and the
two hardware stubs `nanokvm-video` (#83) and `nanokvm-usb` (#82), plus `sshd`,
`avahi`, `systemd-networkd`, `timesyncd` and `logrotate`. The stubs succeed and
name the issue that owns the hardware they cannot touch — so the ordering edges
stay real and a boot log says which pipeline is missing instead of leaving a
silent black stream.

**There is deliberately no GPIO unit** (#81, landed 2026-09-07). The 4.19 image
had one: it poked the VI_D7 pad mux with `devmem` and exported gpio 7/35/74/75
through `/sys/class/gpio`. Neither half has anything to do here. Nothing to
export, because consumers address lines by their device-tree name (`atx-power`,
`atx-reset`, `atx-power-led`, `atx-hdd-led`); nothing to mux, because
requesting a line runs through `gpio-ranges` → `gpio_request_enable()` and the
pin controller programs the pad — the SW_PWR trap fixed at the root. The
appliance instead takes the `gpioBackend = "libgpiod"` server build
(`nanokvm-server-libgpiod`, because global GPIO numbers are not stable on
mainline) and carries `nanokvm-gpio` in `environment.systemPackages`; the server
reaches it by absolute store path, not through `PATH`.

**Dead weight deleted rather than ported**, all present and mostly enabled on
the vendor rootfs: `sysdev.service` (a 14-line no-op sleep loop),
`isc-dhcp-server{,6}` (enabled *and* failed), the `rc2.d` `udhcpd` pointed at
**eth0** with a `192.168.0.20-254` pool — a latent rogue DHCP server on the LAN
— `bluetooth`, `cua.service` and its ~1 GB of Python ML packages, the twelve
leftover **PiKVM** accounts (`kvmd`, `kvmd-vnc`, `kvmd-janus`, …) and
`99-kvmd*.rules`, `/opt/etc`'s 173 MB of sensor tuning `.ini` files, `nginx`,
`apt-daily*` and `motd-news`.

### 8. Userland the app depends on

- **Dynamic loader.** Vendor-shaped binaries request
  `/lib/ld-linux-aarch64.so.1`; NixOS has no such path until
  `environment.ldso` creates it.
- **`/opt/lib` and `/opt/usr/lib`.** `NanoKVM-Server`'s `DT_RUNPATH` is the
  bare, store-free `$ORIGIN/dl_lib:/opt/lib:/opt/usr/lib`, so both FHS paths
  must exist. They are `tmpfiles` `L+` symlinks to one store directory holding
  **three open libraries and nothing else**: `libopus.so.0` and `libasound.so.2`
  (libkvm `DT_NEEDED`s both — HDMI audio capture through ALSA into Opus) and
  `libjpeg.so.8` for the soft-MJPEG path (#51). All three come from `crossPkgs`,
  the exact builds libkvm was linked against. The build fails if any of the
  three is missing from the directory.
- **`/kvmapp`.** `server/{NanoKVM-Server,web/,dl_lib/}` plus `version`, an
  immutable store symlink, copied to `/dev/shm/kvmapp` at boot by
  `nanokvm-appdir.service` and executed from there. `router/router.go` serves
  `dirname(os.Executable())/web`, which is why the layout is what it is and why
  the tmpfs copy preserves it.
- **`/etc/kvm`.** Writable, persistent, mode 0700: `server.yaml`,
  `server.crt`/`server.key`, `pwd`, `leader-key`, `shortcuts.json`, `cache/wol`,
  `edid/`, `scripts/`, `menubar`, `web-title`, `terminal_auth`, `mouse-jiggler`,
  `server.txt`, `preview_updates`.
- **`/var/log/nanokvm/`.** The server's redirected stdout; rotation is
  `copytruncate`, mandatory because the fd is held open for the process lifetime
  (#41).
- **`/device_key`.** A plain file at the root of the rootfs, read by
  `service/vm/info.go`. Outside NixOS's model, written by
  `nanokvm-identity.service`.
- **Python 3** for the mini-display daemon. The server also execs bare
  **`python`** (not `python3`) for user-uploaded scripts.
- **`/bin/bash`.** The vendor scripts are `#!/bin/bash`; NixOS materialises only
  `/bin/sh` and `/usr/bin/env`, so `/bin/bash` is a `tmpfiles` symlink. The Go
  server also execs `/bin/sh` by absolute path (twice).
- **`configfs` at `/sys/kernel/config`** before any USB-gadget route works —
  currently moot, #82.
- **A PATH contract.** `environment.systemPackages` does *not* set a unit's
  PATH, so `nanokvm.service` carries an explicit `path` derived from a full grep
  of the server's Go source: coreutils, bash, grep/sed/awk, procps, util-linux,
  kmod, iproute2, nettools, iptables, openssl, ethtool, wpa_supplicant, hostapd,
  alsa-utils, shadow, systemd, python3, `ubootTools` (`fw_printenv`/`fw_setenv`)
  and busybox last, for `devmem` and `udhcpc`/`udhcpd`, so the real tools win.
  The server is the parent of `usbdev.sh` and `wifi.sh`, so those inherit it.
  Known-absent and accepted: `chronyc` (we run `timesyncd`), `dpkg` and
  `tailscale`. A missing entry is a feature that silently stops working, not a
  build error.
- **Debian systemd unit names.** The server drives units over D-Bus by literal
  name: `ssh.service`, `ssh.socket`, `avahi-daemon.service`, `kvm-sleep.service`,
  `tailscaled.service`. sshd therefore runs as a **persistent daemon**
  (`services.openssh.startWhenNeeded = false`) with `ssh.service` aliased onto
  `sshd.service`. `ssh.socket` is deliberately *not* aliased: with a persistent
  daemon there is no socket unit to alias, the server's socket operations are
  all best-effort (`_ = …`) and `isSSHRunning` tolerates the lookup failing, so
  the toggle works end to end through `ssh.service` alone — and a fabricated
  `ListenStream`-less socket, which systemd refuses to load, would be strictly
  worse.

### 9. Kernel modules: there are none

`boot.kernel.enable = false`, and the mainline kernel builds **no modules at
all** — every driver this board has is built in. There is no `/lib/modules` tree
on the image and none in the closure.

That has one non-obvious consequence in stage 1. `boot.initrd.kernelModules` and
`availableKernelModules` must be `lib.mkForce [ ]`, not `[ ]`: option lists
merge, and `nixos/modules/tasks/filesystems/ext.nix` adds `ext2 ext4` to
`availableKernelModules` for the root filesystem's type. A merge leaves those
two in place, and `makeModulesClosure` over an empty tree with a non-empty
module list is a hard build failure ("Can not derive a closure of kernel
modules").

The first thing that will need a modules tree is the video stack, #83 — see
[gap 11](#known-gaps).

---

## The blob-policy assertion

`nixos/rootfs.nix` walks the whole system closure and **fails the build** if any
store path matches `axera-libs`, `ax-ko-blobs` or `libsns-dummy`. This is the
blob policy from CLAUDE.md turned into a build error at the one point where the
entire closure is visible, rather than a provenance audit finding six months
later.

It exists because it already caught something. `pkgs/kvm-encoder.nix` sets
libkvm's `DT_RPATH` to `/opt/lib:<axera-libs>/lib` so the same artifact also
works in the vendor-encoder configuration. On an overlay rootfs that store path
is a dead string. **In a Nix closure it is a reference**, and it dragged the
entire closed Axera library set into an image whose whole point is to contain
none of it. The V4L2/openVenc build links no vendor library at all, so the
appliance re-RPATHs libkvm at the three open libraries it actually needs.

Two traps inside that fix:

- **Both copies.** `pkgs/kvm-encoder.nix` installs `libkvm.so` and `libkvm.so.0`
  as two real files, not a symlink pair. Patch one and the store path survives in
  the other and the closure is dragged in anyway. The `kvmapp` derivation patches
  both and then `grep`s both plus `NanoKVM-Server` for the string `axera-libs`
  as a belt-and-braces check.
- **`--force-rpath`.** `DT_RPATH`, not `DT_RUNPATH`. libkvm is `dlopen`'d by the
  server and only `DT_RPATH` is inherited down the dependency chain — the trap in
  [architecture.md](architecture.md#the-videoaudio-pipeline-our-libkvm).

`libsns-dummy` is in the reject list even though it is our own from-source build
(#30): it exists only to serve the closed-capture backend, which this image does
not contain, and it compiles against the `axera-libs` headers.

**The `lib.getLib` trap.** The three `/opt/lib` libraries are taken as
`lib.getLib crossPkgs.<pkg>`, not as the bare derivation. libjpeg-turbo's
**first** output is `bin`, so `"${kvm-encoder.libjpeg8}/lib"` is a directory that
does not exist — and the only symptom is a `cp` with no source operand.

---

## Approaches weighed

Recorded because the reasoning outlived the constraint that produced it.

**(a) Full NixOS — TAKEN.** `nixos/lib/eval-config.nix` → system closure →
rootless ext4 via `nixos/lib/make-ext4-fs.nix` (`fakeroot mkfs.ext4 -d`, the
same no-root constraint that forced the `debugfs` surgery in
`pkgs/rootfs.nix`). Gets the module system, so `services.openssh`,
`services.avahi`, `services.logrotate`, journald limits and the unit definitions
are declarative one-liners instead of overlay files poked into an ext4. Its one
real cost — the frozen `nixos-24.11` pin — is gone with the kernel move.

**(b) Hand-rolled Nix rootfs, no systemd.** Its only genuine advantage was
dodging the [systemd ceiling](#history-the-systemd-ceiling) while staying on
`nixos-unstable`. That ceiling no longer exists, so the argument for (b) is
empty and its costs (reimplementing the service model, udev, journald, network
configuration and sshd wiring by hand, for a system whose failure mode is an
unreachable appliance) stand undiminished. **Rejected, now unconditionally.**

**(c) Staged — keep the vendor base, replace pieces.** What the repo has done
incrementally, and it took every easy win: `libkvm`, the modules, the module
loader, the app, motd, the wifi override, the closed `kvmcomm` binaries, and
finally the whole closed media stack (#54/#55/#60). What remains in the vendor
base is exactly the part that cannot be replaced piecemeal: glibc, systemd, the
init layout, `apt`. **Rejected as an endpoint**, and it stays the shipping
configuration until (a) is hardware-proven.

---

## What is built

```
nixos/appliance.nix        NixOS module: the NanoKVM-Pro appliance
nixos/emmc-partitions.nix  the blkdevparts= parser: p16/p17, A/B slots, fw_env
nixos/rootfs.nix           eval-config -> closure -> rootless ext4 (+ sparse, + initrd)
nixos/qemu-test.nix        the same appliance retargeted at qemu-system-aarch64
nixos/loop-test.nix        the reversible on-device root: loop image, no re-arm
```

```bash
nix build .#nixos-appliance        # root = the eMMC rootfs partition (p17)
nix build .#nixos-appliance-loop   # root = an image FILE loop-mounted off p17
nix run   .#nixos-appliance-qemu-run

# result/nixos_rootfs.ext4          raw (dd / debugfs / QEMU)
# result/ubuntu_rootfs_sparse.ext4  Android-sparse, the .axp member name
# result/system                     symlink to the NixOS system closure
# result/initramfs.cpio             uncompressed, for CONFIG_INITRAMFS_SOURCE
# result/NOTES.txt                  variant, pin, root device, init contract
```

Each rootfs variant has a matching kernel, because the initrd is inside the
Image: `.#kernel-mainline-appliance`, `.#kernel-mainline-appliance-loop`,
`.#kernel-mainline-appliance-qemu`, and slot-B images for the first two
(`.#kernel-mainline-appliance{,-loop}-slot-image`). The appliance is also a
first-class NixOS system:
`nix build .#nixosConfigurations.nanokvm-pro.config.system.build.toplevel`.

Build model: evaluated as a **native `aarch64-linux` system** and built through
binfmt/qemu-user (`extra-platforms = aarch64-linux` on the dev box). Nearly the
whole closure substitutes prebuilt from `cache.nixos.org`, so emulation only
pays for a handful of tiny system derivations. Cross-compiling a full NixOS
closure is the alternative and is materially worse.

Notable decisions inside `nixos/appliance.nix`:

- `boot.kernel.enable = false`, every in-tree bootloader off (`grub`,
  `systemd-boot`, `generic-extlinux-compatible`), and
  `boot.loader.external.enable = true` — the AX630C boot chain owns all of it,
  and "install" means "write the inactive A/B slot" (#79).
- `boot.initrd.enable = true` with `boot.initrd.systemd.enable = false`: classic
  script stage 1. Two board-specific reasons — every byte of the initrd is
  charged against a 64 MiB partition shared with the kernel, and a stage 1 that
  dies here is silent. A shell script that mounts one ext4 is the smaller, more
  inspectable thing. All three of these are `assertions`, not conventions.
- `environment.ldso` materialises `/lib/ld-linux-aarch64.so.1`.
- `nanokvm.rootImage.enable` switches root to a loop-mounted image file:
  `postDeviceCommands` mounts the carrier filesystem read-**write** (`losetup`
  opens the backing file `O_RDWR`; a read-only loop cannot carry a writable
  root) and attaches `/dev/loop0`, leaving the carrier mounted for the life of
  the system. `CONFIG_BLK_DEV_LOOP=y` in the kernel fragment exists for this.
- `nix.enable = false` — no Nix on the appliance; the rootfs is a fixed closure
  produced by the build host. An update is a new closure, not a `nixos-rebuild`
  on the device (#86).
- `networking.firewall.enable = false` (appliance on a trusted LAN; 22/80/443),
  `services.journald` capped at 32M/16M because eMMC is the only writable medium
  and an unbounded journal is what chewed ~100 MB/week during the
  `wifi.service` restart loop (#43).
- `users.users.root.initialPassword = "sipeed"` — parity with the vendor image's
  documented default. Change on first boot.

**Defects fixed, and where they were caught.** Four came out of review of the
4.19 scaffold (2026-08-29): the `ssh.service` alias over a socket-activated
sshd, the passive `nanokvm-identity` `wantedBy`, a strict-mode module loader,
and `nanokvm.service`'s missing PATH. Two more came out of the **first QEMU
boot**, and both would have fired on hardware:

1. `nanokvm.service` had the tmpfs copy as an `ExecStartPre` while
   `WorkingDirectory=/dev/shm/kvmapp/server`. systemd applies `WorkingDirectory`
   to every `Exec*` line, so the command that *creates* the directory was
   chdir'd into it first and died `200/CHDIR` on every boot. The copy is now its
   own unit, `nanokvm-appdir.service`.
2. With that fixed, `NanoKVM-Server` wrote its default config, bound both ports,
   and exited 1 on `open /etc/kvm/server.crt: no such file or directory` — the
   cert half of the vendor supervisor. `nanokvm-cert.service` now generates it.

Size: the QEMU variant's first fsck reports `333469/601663` 4 KiB blocks used —
about **1.3 GiB of content**. For comparison the vendor rootfs *actually uses*
4.5 GB on the device, 3.1 GB of it `/usr`, including **965 MB of
`/usr/local/lib/python3.13` site-packages** (scipy, transformers, sympy,
onnxruntime, numpy, openai) that exist only for the disabled `cua.service` AI
assistant. The Nix rootfs is not a size regression; it deletes roughly a
gigabyte of unused ML stack outright.

### The `boot.initrd.systemd.enable` trap

`nixos/modules/system/activation/top-level.nix` decides what `<system>/init` is
by branching on whether the initrd is systemd-based. With it on, `$out/init`
stops being the stage-2 shell script and becomes a copy of the **systemd ELF**,
intended to run as an initrd PID 1. Stage 1 would `switch_root` straight into
that, systemd would come up in initrd mode as the real PID 1, and the board
would die with no console.

The appliance needs `boot.initrd.enable = true` — nothing else mounts root — so
`boot.initrd.systemd.enable = false` is the only thing keeping `<system>/init` a
script. It defaults false, but the trap is live: nixpkgs'
`profiles/image-based-appliance.nix` sets it `mkDefault true`, and that profile
is exactly what someone would reach for next. It is therefore guarded twice: an
assertion in `nixos/appliance.nix` on the *option*, and a check in
`nixos/rootfs.nix` that `<toplevel>/init` in the built image actually starts
with `#!` — the *artifact*, because an imported profile could re-enable the
option under the assertion's nose.

### Reaching a bare-name `dlopen()` — the fallback ladder

If a `.so` ever fails to resolve, two obvious fixes are dead on NixOS and should
not be attempted:

- **`ldconfig` / `/etc/ld.so.cache` does not exist.** nixpkgs patches glibc
  (`dont-use-system-ld-so-cache.patch`) so `LD_SO_CACHE` points inside glibc's
  own immutable store path. No cache can ever be written there, and `/lib` and
  `/usr/lib` are not on a Nix glibc's search path at all — dropping a `.so` into
  `/lib` accomplishes nothing.
- **`programs.nix-ld` does not help here.** nix-ld works by *being* the
  interpreter at `/lib/ld-linux-aarch64.so.1`, so it only intercepts a vendor
  **executable** whose `PT_INTERP` is that path. A `.so` dlopened from an
  already-running Nix-built process (`NanoKVM-Server` → `libkvm.so`) is resolved
  by the Nix loader already in that process; nix-ld is never consulted. It also
  *sets* `environment.ldso` itself, so it conflicts with our direct glibc
  symlink, and its `NIX_LD_LIBRARY_PATH` ships via `/etc/profile`, which systemd
  services never source.

What actually works, in order:

1. **`patchelf --force-rpath` on the calling object** — what the `kvmapp`
   derivation does.
2. **`LD_LIBRARY_PATH` in the unit's `serviceConfig.Environment`** — the real
   fallback, and the only mechanism that reliably reaches a bare-name `dlopen`
   inside a running service. One line:
   `Environment = "LD_LIBRARY_PATH=/opt/lib"` on `nanokvm.service`.
   (`environment.variables` / `environment.sessionVariables` will *not* do
   this.) Note it adds only `/opt/lib` and never a glibc — an explicit
   `${pkgs.glibc}/lib` there would be a mismatched loader/libc pair, which is a
   crash, not a warning.
3. `systemd.tmpfiles` `L+` to materialise the FHS path — necessary but not
   sufficient alone; `/opt/lib` is only searched because a RPATH/RUNPATH names
   it.
4. `/etc/ld-nix.so.preload` — nixpkgs moves the preload file to this real path,
   so a system-wide `LD_PRELOAD` does survive. Niche, but it is the one global
   loader hook that still exists.

---

## Known gaps

Numbering is stable: other documents and `nixos/appliance.nix` cite these by
number, so closed gaps keep their slot and new ones are appended.

1. **`nanokvm.service` is not the vendor service — SPLIT AND MOSTLY CLOSED.**
   The vendor `nanokvm.sh` did three things, and all three are now declared
   units rather than a shell script that lives only in the vendor rootfs:
   the tmpfs copy (`nanokvm-appdir.service`), the restart-with-give-up loop
   (`Restart=on-failure`, `RestartSec=3`; the give-up is now systemd's default
   start rate limit rather than a counter in a script), and HTTPS cert
   generation (`nanokvm-cert.service` — self-signed,
   `/etc/kvm/server.{crt,key}`, CN and SANs from the hostname, generated only if
   `/etc/kvm/server.crt` is absent, ordered after `nanokvm-identity` so the CN
   is the final hostname). Both were found by the first QEMU boot; see
   [what is built](#what-is-built).
2. **`/kvmapp/scripts/usbdev.sh` is missing — no keyboard, no mouse.** Still
   open, and it is **#82's**. The KERNEL half stopped being a gap while #78 was
   in flight: `pkgs/kernel-mainline/tree/drivers/usb/dwc3/dwc3-axera.c` is the
   glue, `pkgs/kernel-mainline/ax630c.config` builds `USB_CONFIGFS` in along
   with all five function drivers the script needs — HID, mass storage, NCM,
   UAC2 and ACM — and #82's bring-up initramfs got a host to enumerate each one
   off this board. What is still missing is the script's *policy*: the report
   descriptors, the flag files, the Microsoft OS descriptors and the `udhcpd`
   instance. 21.6 KB of `#!/bin/bash`
   that builds the entire USB gadget under `/sys/kernel/config/usb_gadget/g0`:
   three HID functions (`hid.GS0` keyboard 8-byte, `hid.GS1` relative mouse
   4-byte, `hid.GS2` absolute mouse 6-byte, each with an inline report
   descriptor), NCM with Microsoft OS descriptors, mass storage, UAC2, and the
   `udhcpd` instance on the `usb0` link. It is **not** in the public
   `NanoKVM-Pro` repo — verified by full-tree search — and ships only in the
   vendor rootfs. The Go source references it at **three distinct literal paths**
   (`/kvmapp/scripts/usbdev.sh` twice, and `/dev/shm/kvmapp/scripts/usbdev.sh`
   in `service/storage/image.go`); fix all three. Every gadget feature is gated
   on a flag file on the vfat `/boot` (`usb.ncm`, `usb.rndis`, `usb.disk0`,
   `usb.disk1.{sd,emmc}`, `usb.uac2`, `usb.acm`, `usb.udisp`, `ncm.dhcp`,
   `eth.nodhcp`), with every descriptor value overridable by
   `/boot/usb.{vid,pid,serialnumber,…}`. Either vendor the script (small,
   auditable, still vendor-derived text) or reimplement the configfs setup from
   source.

   > **TODO (device capture, HID-critical).** The whole `/kvmapp/scripts/`
   > directory is vendor-only and absent from our `kvmapp` derivation. Capture
   > it host-side once, e.g. `tools/kvmscp device:/kvmapp/scripts
   > pkgs/rootfs/kvmapp-scripts/`, review + license-note the text, then stage it
   > into `kvmapp` at `server/../scripts` so all three literal paths resolve
   > after the tmpfs copy. Cannot be done from the build host alone.
3. **The remaining `rc.local` items — the `fw_env` half is CLOSED.**
   `/etc/fw_env.config` ships, derived from the `blkdevparts=` clause, and
   `nanokvm-checkboot.service` is live
   ([above](#6-the-emmc-map-and-etcfw_envconfig)). A hexdump check of the real
   U-Boot environment at `0x4C0000` is still owed before the first `fw_setenv`.
   Still unimplemented, each needing the exact script text or register intent
   read off the device first: `axemac.sh` (eth0 RPS/RFS + `ethtool -A eth0 rx
   on`), `npu_set_bw_limiter.sh start`, and the bare
   `devmem 0x10030028 32 0x000006A0` SoC poke. `S99checkota` belongs with the
   OTA redesign (gap 5).
4. **WiFi is lost.** `aic8800_{bsp,fdrv,btlpm}.ko` need their own build against
   the mainline kernel, and their firmware is 28 files under
   `/opt/firmware/aic8800/` — the only closed content the blob policy still
   allows. Needs its own pinned derivation, or WiFi is dropped. **#85.**
5. **OTA.** `pkgs/update-package.nix` and [updates.md](updates.md) assume a
   file-overlay rootfs. Unresolved — **#86**.
6. **Timezone reporting is subtly wrong** (display-only; `timedatectl
   set-timezone` still works). `service/vm/datetime.go` reads the zone by
   `os.Readlink("/etc/localtime")` and slicing on the literal
   `"/usr/share/zoneinfo/"`. On NixOS the link target is `/etc/zoneinfo/<TZ>`,
   the slice misses, and the fallback returns `../../../etc/zoneinfo/UTC`. The
   module materialises `/usr/share/zoneinfo` (necessary, not sufficient). Left
   as a TODO because both clean fixes have a catch: a `tmpfiles L+
   /etc/localtime → /usr/share/zoneinfo/<TZ>` is rewritten back to the
   `/etc/zoneinfo` form by the next runtime `timedatectl set-timezone`, and
   patching the slice literal is a `pkgs/nanokvm-server.nix` change (server
   lane, not rootfs). Recommended fix: teach the Go slice to also accept
   `/etc/zoneinfo/`.
7. **Wake-on-LAN — shimmed, untested.** The server runs `ether-wake -b <MAC>`;
   nixpkgs has no `ether-wake`, so the appliance ships a one-line shim mapping it
   onto `wakeonlan` (same magic packet, broadcast by default), on both
   `serverPath` and `systemPackages`. Never exercised on hardware.
8. **`/opt/etc` — moot.** The 173 MB of Axera sensor tuning `.ini` files was the
   question on an overlay rootfs. The appliance stages **no vendor tree at all**,
   so there is nothing to audit. (`/kvmcomm/edid/*` is likewise settled: the
   whole set is generated from source by `pkgs/edid`.)
9. **Hot patching changes shape.** `/kvmapp` is an immutable store symlink, so
   on-device patches only apply to `/dev/shm/kvmapp` and vanish on reboot. The
   `deploy-iterate` skill assumes a writable `/kvmapp`.
10. **`environment.ldso` alone is not an FHS.** See
    [the fallback ladder](#reaching-a-bare-name-dlopen--the-fallback-ladder).
11. **No kernel module tree at all.** Every driver is built into the Image and
    the closure has no `/lib/modules`. That is the right answer today and it
    stops being one the moment something needs a module: the first such thing is
    the video stack (#83), which will need `boot.kernel.enable` to stay false
    while a modules tree is spliced into the system closure by hand — nixpkgs'
    `kmod` is patched to search `/run/booted-system/kernel-modules/lib/modules`,
    not `/lib/modules`, so it cannot simply be dropped into the filesystem.
12. **The two hardware stubs, and what each costs the product.**
    `nanokvm-video` (**#83**) — no `/dev/video0`: the web UI loads and streams
    nothing. The three open drivers are 4.19 out-of-tree code and need porting to
    current V4L2/dma APIs. `nanokvm-usb` (**#82**) — no keyboard, no mouse, no
    mass storage, no NCM. The mini-display daemon (**#84**) is
    `ConditionPathExists=/dev/fb0` and simply does not run. Both stubs exit 0 and
    print which issue owns them. ATX is **not** on this list any more: #81 landed
    and the appliance drives it through `nanokvm-gpio` — but that tool has still
    never executed on hardware, because it targets this appliance and #81's own
    runs had no mainline userspace. QEMU gets as far as proving it is on the
    system PATH and resolving lines by name (`no gpiochip names line
    'atx-power'`); the pulse itself is hardware-only, and pressing `atx-power`
    presses a button on someone's machine.
13. **The identity path is unproven on hardware.** The `/dev/mem` read of
    `misc_info` at physical `0x740`, the `sha512sum` derivation and the
    `ip link set … address` write have never run on the board. QEMU took the "no
    SoC UID" branch. If the read is wrong the board comes up with a
    kernel-random MAC and the DHCP reservation — the address `tools/kvmssh`
    knows — does not match. Validate by running the same script on a *vendor*
    boot, where `/proc/ax_proc/uid` exists, and comparing the derived MAC with
    the one the device already has.

---

## Validation ladder

Strictly in this order. Nothing here touches eMMC until the step before it has
passed.

1. **Build.** `nix build .#nixos-appliance` (and `-loop`, and the matching
   `.#kernel-mainline-appliance*`). No hardware.
2. **Offline contract assertions — already in the build.** `nixos/rootfs.nix`
   checks with `debugfs`, on the packed image, that `/init` and `/sbin/init` are
   symlinks, that the system profile resolves, that stage 2 is in the closure
   and is a `#!` script, and that **no closed Axera store path is in the
   closure**. `nixos/emmc-partitions.nix` asserts the partition map it parsed.
   `nix flake check` builds `emmc-partition-map`, which prints all 17 partitions
   with offsets and the resulting `fw_env.config`. Every one of these would
   otherwise be a silent non-boot on a board with `bootdelay=0` and no console.
3. **QEMU boot — this is where the NixOS half is proven.**

   ```bash
   nix run .#nixos-appliance-qemu-run
   ```

   Boots `.#kernel-mainline-appliance-qemu` on a throwaway copy of the rootfs
   under `qemu-system-aarch64 -M virt`. `nixos/qemu-test.nix` adds a self-test
   unit that runs after `multi-user.target`, dumps the state of everything #78
   owns — root filesystem, `/etc/fw_env.config`, identity, `/kvmapp` and
   `/opt/lib`, every `nanokvm*` unit, failed units, the server log,
   `nanokvm-checkboot` — and powers the machine off, so a run is a diff-able
   artifact rather than a login prompt. Two runs are banked in
   [`docs/reference/mainline/nixos-appliance-20260907/`](reference/mainline/nixos-appliance-20260907/README.md).

   **What it proves:** the embedded-initrd boot contract with no `init=` on the
   command line, that the closure reaches multi-user with zero failed units,
   that the server binds `:80`/`:443`, and that the units behave when the
   hardware they want is absent. **What it cannot prove:** anything about the
   AX630C — the device tree, clocks, pinctrl, eMMC, Ethernet, the watchdog and
   the A/B slot register are all QEMU's here, or absent.

   *(The old `tools/nixos-chroot-test` — systemd 256 chrooted on the running
   4.19 device — is superseded. It existed to probe the systemd-kernel floor,
   which no longer exists, and a real boot is strictly stronger. The script is
   still in the tree.)*
4. **The reversible on-device test: the loop-image root.** The eMMC is the
   device's only writable medium and `p17` carries the running vendor system, so
   the first hardware boot writes nothing it cannot take back:

   - `dd` `.#kernel-mainline-appliance-loop-slot-image` to `/dev/mmcblk0p15`
     (`kernel_b`, slot B — p14 is slot A and the shipped 4.19 kernel), plus the
     matching mainline dtb to p13;
   - drop `.#nixos-appliance-loop`'s `nixos_rootfs.ext4` on the vendor rootfs as
     `/nixos-root.img`;
   - stage 1 mounts p17, `losetup`s the image and boots a real NixOS root off
     it. Nothing is overwritten.

   `nixos/loop-test.nix` is the module that variant carries, and it is where the
   harness's safety property lives: **`nanokvm.checkboot.enable = false`**. The
   SPL treats `SLOTB_BOOTABLE` as consume-once, so as long as nothing in the
   slot-B image re-arms it, every exit path — clean boot, panic, hang, watchdog
   reset — lands the *next* boot on slot A by itself. `nanokvm-checkboot` is
   precisely the unit that would re-arm it, so on this variant it is not built.
   The same module bind-mounts the carrier filesystem across the `switch_root`
   at `/vendor-root` (stage 1 mounts it at `/nanokvm-host`, which `switch_root`
   leaves alive but unreachable), which buys two things a test boot needs: root's
   password hash is harvested from the vendor `/etc/shadow` at boot rather than
   built into the image — no credential in the store or the repo, and
   `tools/kvmssh` reaches the system with the password it already knows — and
   the derived MAC can be compared against the `hwaddress ether` line the vendor
   `/init` last wrote there, which is the one comparison
   [gap 13](#known-gaps) exists to pass.

   Rollback is `rm /nixos-root.img` plus a slot-B restore. The proven slot-B
   harness and the boot-evidence channel are in
   [flashing-and-recovery.md](flashing-and-recovery.md#slot-b-kernel-testing-proven-procedure-2026-08-30)
   and [mainline-port.md](mainline-port.md) §8; the `mainline-boot-test` skill
   runs the loop ("Variant: booting the NixOS appliance from slot B").
5. **SD-card boot — blocked.** There is **no SD card in the device**, which also
   blocks root-on-SD in #76. Needs Jeremy.
6. **eMMC `p17`.** Last, and only after 4, and only with a stock vendor `.axp`
   on hand. This is the step that overwrites the vendor system.

### Human-only actions

These need Jeremy; nothing above can be done by an agent alone.

- **Power-cycle the device** for any slot-B test (the slot register does not
  survive a cold boot, so a stuck board is recovered by pulling power).
- **Put an SD card in the unit** — it unblocks step 5 and the rest of #76.
- Hold `User` ~10 s for AXDL download mode and re-flash a stock `.axp` if a boot
  fails. This is the only recovery path.
- Attach serial to UART0 (hidden pads; an FT232, not a CH340) if a boot fails
  silently and the cause is not obvious from the network behaviour.

### Risks

- **`bootdelay=0`.** No autoboot interrupt window, so a rootfs that fails to
  reach userspace cannot be debugged from a U-Boot prompt.
- **A silent userspace looks exactly like a dead kernel.** The `/dev/console`
  failure is the canonical case: through the milestone register, "reached
  userspace and printed nothing" and "hung in the kernel" read the same. Assume
  any new stage-1 change can produce it, and prove the change in QEMU first.
- **AXDL is the whole safety net.** It lives in mask ROM and cannot be bricked,
  and Jeremy has exercised it — but it needs hands on the board, so a failed
  eMMC flash costs a physical trip, not a reboot.
- **The A/B slot register does not survive a power cycle.** Every cold boot lands
  on slot A with `SLOTA_BOOTABLE` clear; rollback state is warm-reset-only
  ([mainline-port.md](mainline-port.md) §6).
- **Silent-failure modes are the norm here.** The `/lib`-symlink bug in
  `pkgs/rootfs.nix` shipped once precisely because a missing file produced a dead
  capture path rather than a build error. The build-time contract assertions
  exist for that reason; extend them rather than trusting inspection.

---

## History: the systemd ceiling

Kept because it is why a second nixpkgs pin existed for six months, and because
the table is a useful record of where systemd's kernel floor actually sits.

**The constraint.** systemd declares a hard minimum kernel version, and from
v258 on that minimum is above 4.19. The flake's `nixos-unstable` pin ships
systemd 261, whose README says kernels below 5.10 "are not supported at all". So
while the board was pinned to Linux 4.19.125 by the `ax_*.ko` vermagic contract,
a NixOS rootfs built from the main pin could not boot it, and the rootfs rode a
second input, `nixpkgs-rootfs` → `nixos-24.11` (systemd 256.10) — the newest
release whose systemd still listed 4.19 as *above* its recommended baseline.

| nixpkgs branch | systemd | minimum baseline | recommended baseline | 4.19.125 |
|---|---|---|---|---|
| `nixos-24.05` | 255.9 | 3.15 | 4.15 | OK |
| **`nixos-24.11`** | **256.10** | **3.15** | **4.15** | **OK — above recommended** |
| `nixos-25.05` | 257.10 | 3.15 | 5.4 | supported, but tainted `old-kernel` |
| `nixos-25.11` | 258.7 | **5.4** | 5.7 | **unsupported** |
| `nixos-26.05` | 260.2 | **5.10** | 5.14 | **unsupported** |
| `nixos-unstable` (main pin) | 261.2 | **5.10** | 5.14 | **unsupported** |

The functionality between 4.19 and 5.4 that systemd ≥258 assumes is not
cosmetic: `pidfd` (5.4), the new mount API `fsopen`/`fsmount`/`move_mount`
(5.2), cgroup-v2 freezer (5.2), `close_range()` (5.9), `CLONE_INTO_CGROUP`
(5.7). Nothing else in nixpkgs blocked 4.19 — glibc is configured
`--enable-kernel=3.10.0`, so even the unstable glibc runs there. systemd was the
only wall.

**The exit condition was "the board runs a kernel ≥ 5.10", and it has been met.**
The appliance boots mainline 7.1.3 (#75 proved the kernel on hardware; #78 put
NixOS on top of it), so the pin, its EOL-security cost and the whole staging
argument are retired. `nixpkgs-rootfs` is removed from `flake.nix`.

Four consequences that this document used to assert and that are now **false**,
listed so nobody re-derives them from the table above:

- **User namespaces exist.** `CONFIG_USER_NS=y` in the mainline fragment, so
  `PrivateUsers=` works instead of failing `217/USER`. The appliance no longer
  needs an assertion forbidding it.
- **`pkgs.buildFHSEnv` can work** — both the bubblewrap and the chroot variant
  needed user/PID namespaces the vendor defconfig did not have.
- **`system.etc.overlay.enable` is no longer off-limits**: `CONFIG_OVERLAY_FS=y`.
- **The "two glibcs, one loader" hazard is gone.** It existed because the rootfs
  pin's glibc and the unstable pin's glibc (the `PT_INTERP` of our cross-built
  binaries) coexisted in one image. There is one pin now, so there is one glibc.
  Do not add an explicit `${pkgs.glibc}/lib` to anything's RPATH out of habit —
  a mismatched loader/libc pair is still a crash, not a warning.

The rest of the 4.19 config indictment stands as a record of what the vendor
defconfig lacked and what `pkgs/kernel-mainline/ax630c.config` now sets on
purpose: `# CONFIG_NAMESPACES is not set`, **no cgroup controllers at all**
(`cgroup.controllers` empty on the live device, so `MemoryMax=`, `TasksMax=` and
`CPUQuota=` were accepted and silently unenforceable), no `TMPFS_XATTR`,
`TMPFS_POSIX_ACL`, `OVERLAY_FS` or `SQUASHFS`. Turning any of those on *in
place* was the dangerous move, because `CONFIG_MEMCG` alone adds a pointer to
`struct page` and `ax_cmm` did page arithmetic — a config change that shifts a
struct the blobs touch is a silent memory-corruption bug, not a build error
(`MODVERSIONS` was off, so nothing checked). That whole class of hazard died
with the last vendor `.ko` (#54).
