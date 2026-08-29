# Pure-Nix rootfs (issue #26)

Feasibility study and scaffold for replacing the pinned vendor Ubuntu 22.04 arm64
rootfs (`pkgs/base-axp.nix` → `pkgs/rootfs.nix`) with a rootfs built entirely
from nixpkgs.

**Status: scaffold. `nix build .#nixos-rootfs` produces a NixOS ext4 image. It
has never been booted, on any medium.**

- [Verdict](#verdict)
- [The systemd ceiling](#the-systemd-ceiling)
- [Why the kernel cannot move](#why-the-kernel-cannot-move)
- [The rootfs contract](#the-rootfs-contract)
- [Approaches weighed](#approaches-weighed)
- [What is scaffolded](#what-is-scaffolded)
- [Known gaps](#known-gaps)
- [Validation ladder](#validation-ladder)

---

## Verdict

**Take approach (a): a full NixOS system — but evaluated against a *second*,
older nixpkgs pin, not this flake's `nixos-unstable`.**

The single fact that decides the design: **systemd declares a hard minimum
kernel version, and from v258 on that minimum is above 4.19.** This flake's
`nixos-unstable` pin ships systemd 261, whose README says kernels below 5.10
"are not supported at all". A NixOS rootfs built from the main pin cannot boot
this board, today or at any point in the future unless the kernel moves — and
the kernel cannot move (below).

So the rootfs rides `nixpkgs-rootfs` → `nixos-24.11` (systemd 256.10), the
newest release whose systemd still lists 4.19 as *above* its recommended
baseline. The rest of the flake is untouched and stays on unstable; our own
aarch64 packages continue to be cross-built from the unstable pin and are
dropped into the image as self-contained ELF.

This is worth doing. It removes the whole Ubuntu surface at once: `apt`
(`ports.ubuntu.com`), `motd-news`, `chrony`'s hardcoded
`time.{windows,apple,google}.com`, the retained closed `kvmcomm` tree, and the
whole "the running media stack is vendor-origin, not our pin" nuance in
[provenance.md](provenance.md) — on a Nix rootfs the `ax_*.ko` and `libax_*.so`
that execute come from `pkgs/ax-ko-blobs.nix` and `pkgs/axera-libs.nix`, the
derivations we already pin.

It is not free, and the costs are real:

| Cost | Detail |
|---|---|
| **Frozen rootfs pin** | `nixos-24.11` is EOL. The rootfs stops getting upstream security fixes, including for `sshd`. Today the vendor base *does* get them — `apt-daily-upgrade.timer` is enabled and approved. Mitigation: overlay the network-facing leaves (`openssh`, `glibc`) from the unstable pin onto the 24.11 rootfs; leaf overlays across pins normally work. |
| **OTA redesign** | `pkgs/update-package.nix` overlays *files* into `/kvmapp`, `/opt/lib`, `/usr/lib/modules`. A NixOS rootfs is a store closure; an update becomes "import a closure, `switch-to-configuration`". [updates.md](updates.md) has to be rewritten. |
| **Vendor scripts** | `/kvmapp/scripts/usbdev.sh` (the whole USB-gadget HID / mass-storage / NCM / UAC2 path the server shells out to) exists **only in the shipped vendor rootfs** — it is not in the public `NanoKVM-Pro` repo. See [known gaps](#known-gaps). |
| **WiFi** | `aic8800_*.ko` + `/opt/firmware/aic8800/*.bin` also come only from the vendor rootfs; `pkgs/ax-ko-blobs.nix` does not carry them. |
| **Boot risk** | The rootfs is the one thing between U-Boot and a working device, `bootdelay=0` means there is no serial break-in, and recovery is physical AXDL. |

**Exit condition for the frozen pin:** the rootfs can move back to
`nixos-unstable` the day the board runs a kernel ≥ 5.10. That is gated on the
encoder/capture de-blobbing track (#44–47) removing the `ax_*.ko` vermagic
constraint — the two efforts are coupled, and it is worth saying so out loud
rather than re-deriving it later.

---

## The systemd ceiling

systemd's `README` states a hard floor and a soft floor. Both moved recently.
Fetched from upstream tags:

| nixpkgs branch | systemd | minimum baseline | recommended baseline | 4.19.125 |
|---|---|---|---|---|
| `nixos-24.05` | 255.9 | 3.15 | 4.15 | OK |
| **`nixos-24.11`** | **256.10** | **3.15** | **4.15** | **OK — above recommended** |
| `nixos-25.05` | 257.10 | 3.15 | 5.4 | supported, but tainted `old-kernel` |
| `nixos-25.11` | 258.7 | **5.4** | 5.7 | **unsupported** |
| `nixos-26.05` | 260.2 | **5.10** | 5.14 | **unsupported** |
| `nixos-unstable` (main pin) | 261.2 | **5.10** | 5.14 | **unsupported** |

> ⛔ Kernel versions below 5.10 ("minimum baseline") are not supported at all,
> and are missing required functionality as listed above.
> — systemd v261 `README`

The functionality between 4.19 and 5.4 that systemd ≥258 assumes is not
cosmetic: `pidfd` (5.4), the new mount API `fsopen`/`fsmount`/`move_mount`
(5.2), cgroup-v2 freezer (5.2), `close_range()` (5.9), `CLONE_INTO_CGROUP`
(5.7).

`nixos-24.11` is the pick because 4.19 sits **above** its recommended baseline,
which is a different risk class from "supported but untested". `nixos-25.05`
(systemd 257) is a one-line change in `flake.nix` if a newer package set is
ever needed and the `old-kernel` taint is acceptable.

Nothing else in nixpkgs blocks 4.19: glibc is configured
`--enable-kernel=3.10.0` (`pkgs/development/libraries/glibc/common.nix`), so
even the unstable glibc 2.42 runs here. **systemd is the only wall.**

### The empirical floor

The vendor rootfs runs Ubuntu 22.04's **systemd 249** on this exact kernel
today, so ≤249 is hardware-proven. 24.11's 256 is seven releases above the
proven floor and one release below the first that upstream disowns. That gap is
the actual risk being taken, and it is what the [chroot smoke
test](#validation-ladder) exists to close before anything is flashed.

---

## Why the kernel cannot move

"Just run a newer kernel" is the obvious escape and it is closed:

- The prebuilt Axera media modules (`ax_venc`, `ax_proton`, `ax_mipi_rx`,
  `ax_cmm`, …) load only into a kernel whose `vermagic` matches
  `4.19.125 SMP preempt mod_unload aarch64` — [building.md](building.md#ax_ko-vermagic).
  Source for them is GPL-owed but unpublished. Without them there is no capture
  and no encode.
- Config changes to the *same* kernel are not free either. The vendor defconfig
  has `# CONFIG_NAMESPACES is not set` and **no cgroup controllers at all**
  (`CGROUP_SCHED`, `MEMCG`, `BLK_CGROUP`, `CGROUP_PIDS`, `CGROUP_FREEZER`,
  `CGROUP_DEVICE`, `CGROUP_BPF` all off). systemd copes — mount namespaces are
  unconditional in the kernel regardless of `CONFIG_NAMESPACES`, which is why
  the vendor's systemd 249 sandboxing works today — but turning options on to
  please a newer systemd is dangerous: `CONFIG_MEMCG` alone adds a pointer to
  `struct page`, and `ax_cmm` is a contiguous-memory manager that does page
  arithmetic. Any config change that shifts a struct the blobs touch is a
  silent memory-corruption bug, not a build error (`MODVERSIONS` is off, so
  nothing checks).

So: kernel 4.19.125 with the vendor defconfig is fixed for as long as the media
blobs are, and the rootfs has to live with it.

---

## The rootfs contract

What the running system actually needs *from* the rootfs, gathered from
`pkgs/rootfs.nix`, the vendor initramfs `/init`, the server source, and the
running device.

### 1. The `switch_root` handshake

The kernel embeds the **vendor initramfs** (`pkgs/kernel.nix`,
`CONFIG_INITRAMFS_SOURCE`) and it, not the kernel, mounts root. Its `/init`
(SDK `build/projects/<project>/initramfs/init`):

1. mounts `/proc`, `/sys`, `/dev`; parses `root=` from `/proc/cmdline`;
2. mounts `/dev/mmcblk0p16` (or `mmcblk1p1`) at `/boot`;
3. drops into USB mass-storage recovery if `/boot/rec` exists or `boot_key=1`;
4. if `/boot/check_resize2fs` exists, grows the rootfs — **by copying
   `/realroot/opt/e2fs-static/{tune2fs,resize2fs}` out of the rootfs**;
5. mounts the rootfs rw at `/realroot`, `e2fsck`ing it on failure;
6. writes `/realroot/device_key` from `/proc/ax_proc/uid`;
7. derives a stable MAC `48:da:35:6d:HH:LL` from `sha512(/device_key)` and
   **sed-edits it into `/realroot/etc/network/interfaces`**; on a first boot
   also writes `/realroot/etc/hostname` = `kvm-HHLL`;
8. `exec switch_root /realroot /sbin/init`.

Consequences for a NixOS rootfs, in order of how easy they are to miss:

| Step | Consequence |
|---|---|
| 8 | **`/sbin/init` must exist** and must be NixOS stage 2. This is the only hard contract. |
| 7 | Both writes target ifupdown/Ubuntu files that on NixOS are read-only store symlinks, so **both silently fail** → random MAC per boot, fixed hostname. Must be reproduced in the running system. |
| 6 | `/device_key` is a plain file at the rootfs root, written before pivot; the server reads it (`service/vm/info.go`). Works unchanged, but is outside NixOS's model. |
| 4 | `/opt/e2fs-static/` does not exist on a Nix rootfs, so the grow silently no-ops (benignly — the initramfs clears the flag and boots on). Since `make-ext4-fs` shrinks to fit, the rootfs **must** grow itself later or sit at ~1 GB in a ~30 GB partition. |
| 2 | `/boot` must be in `fstab` and **writable**: the server writes `/boot/eth.nodhcp`, `/boot/hostname`, `/boot/usb.disk0`, `/boot/usb.ncm`, `/boot/usb.uac2`, `/boot/usb.disk1.{sd,emmc}` and reads `/boot/ver`. |

### 2. Init system

systemd, non-negotiably: the app service model (`nanokvm.service` with its
`ExecStartPre` tmpfs copy), the mini-display and ATX-GPIO units, and the vendor
`wifi.service` are all systemd units, and `systemd-modules-load` is what loads
`lt6911_manage` and the mini-display drivers today.

Units the appliance actually needs: `nanokvm`, `nanokvm-display`,
`nanokvm-gpio`, module loading, `sshd`, DHCP, `avahi`, time sync, log rotation.
Everything else on the vendor rootfs (`apt-daily*`, `motd-news`, `chrony`,
`kvmcomm`, vendor `swupdate`) is surface we are trying to delete.

### 3. Userland the app depends on

- **Dynamic loader.** Vendor binaries request `/lib/ld-linux-aarch64.so.1`;
  NixOS has no such path until `environment.ldso` creates it.
- **`/opt/lib`.** `libkvm`'s `DT_RPATH` is `/opt/lib:<axera-libs store path>`,
  so *libkvm itself* resolves from the store even with no `/opt/lib` — but the
  `libax_*.so` are shipped byte-for-byte with **no rpath** and bare
  `DT_NEEDED libc.so.6 / libstdc++.so.6`, resolved on Ubuntu through the
  loader's default `/lib` search path. On NixOS they must be `autoPatchelf`'d
  (the scaffold does this) or reached through `nix-ld`.
  `libsns_dummy.so` is `dlopen`'d by bare name and needs the FHS path present.
- **`/soc/ko` + `/soc/scripts/auto_load_all_drv.sh`.** The curated 12-module
  loader must keep insmod-by-path-with-parameters semantics; `ax_cmm` without
  `cmmpool=` is the panic that bricked a device. It is bash (`function`, `[ ==
  ]`) despite its `#!/bin/sh`, reads `/sys/bus/iio/devices/iio:device0/in_voltage0_raw`,
  `/proc/cmdline` and optionally `/boot/configs`.
- **`/kvmapp`.** `server/{NanoKVM-Server,web/,dl_lib/}` plus `version`, copied
  to `/dev/shm/kvmapp` at boot and executed from there — **and**
  `/kvmapp/scripts/usbdev.sh`, which is vendor-only (see gaps).
- **`/etc/kvm`.** Writable, persistent: `server.yaml`, `server.crt`/`server.key`,
  `pwd`, `leader-key`, `shortcuts.json`, `cache/wol`, `edid/`, `scripts/`,
  `menubar`, `web-title`, `terminal_auth`, `mouse-jiggler`, `server.txt`,
  `preview_updates`.
- **`/var/log/nanokvm/`.** The server's redirected stdout; rotation needs
  `copytruncate` (#41).
- **`/proc/lt6911_info/*`.** From our `lt6911_manage.ko` — a kernel-module
  contract, not a rootfs one, but the module must be loaded at boot.
- **Python 3** for the mini-display daemon.

### 4. Kernel modules

`/lib/modules/4.19.125` with our from-source modules, `depmod`'d, and
**without** the vendor `ax_*.ko` — a merged tree gets `of:` modaliases, udev
coldplug autoloads `ax_cmm` parameter-less, and the device panic-loops. nixpkgs'
`kmod` is patched to search `/run/booted-system/kernel-modules/lib/modules`
instead of `/lib/modules`, so the tree has to be spliced into the system closure
rather than dropped in the filesystem.

---

## Approaches weighed

**(a) Full NixOS — RECOMMENDED.**
`nixos/lib/eval-config.nix` → system closure → rootless ext4 via
`nixos/lib/make-ext4-fs.nix` (`fakeroot mkfs.ext4 -d`, same no-root constraint
that forced the `debugfs` surgery in `pkgs/rootfs.nix`). Gets the module system,
so `services.openssh`, `services.avahi`, `services.logrotate`, journald limits
and the unit definitions are declarative one-liners instead of overlay files
poked into an ext4. Costs the frozen pin.

**(b) Hand-rolled Nix rootfs, no systemd.**
The one genuine advantage: it dodges the systemd ceiling entirely and could
stay on `nixos-unstable`, because *we* would choose the init (busybox/s6/runit)
and `eudev` for device nodes. But it throws away the module system, and we would
be reimplementing the service model, udev integration, journald, network
configuration and sshd wiring by hand — for a system whose service list is
short but whose failure mode is an unreachable appliance. It also loses the
"NixOS" property Jeremy actually asked for. **Rejected**, but recorded: if the
24.11 pin ever becomes untenable *and* the kernel still cannot move, this is
the fallback, not "newer systemd".

**(c) Staged — keep the vendor base, replace pieces.**
This is what the repo already does, incrementally, and it has taken the easy
wins (`libkvm`, modules, the module loader, the app, motd, wifi override,
removal of the closed `kvmcomm` binaries). What remains in the vendor base is
exactly the part that cannot be replaced piecemeal: glibc, systemd, the init
layout, `apt`. **Rejected as an endpoint**, though it stays the shipping
configuration until (a) is hardware-proven.

---

## What is scaffolded

```
nixos/appliance.nix   NixOS module: the NanoKVM-Pro appliance
nixos/rootfs.nix      eval-config -> system closure -> rootless ext4 (+ sparse)
flake.nix             new input nixpkgs-rootfs; new output .#nixos-rootfs
```

```bash
nix build .#nixos-rootfs
# result/nixos_rootfs.ext4            raw (dd / inspection / chroot)
# result/ubuntu_rootfs_sparse.ext4    Android-sparse, the .axp member name
# result/system                       symlink to the NixOS system closure
```

Build model: the appliance is evaluated as a **native `aarch64-linux` system**
and built through binfmt/qemu-user (`extra-platforms = aarch64-linux` on the dev
box). Nearly the whole closure substitutes prebuilt from `cache.nixos.org`, so
emulation only pays for a handful of tiny system derivations. Cross-compiling a
full NixOS closure is the alternative and is materially worse.

Notable decisions inside `nixos/appliance.nix`:

- `boot.loader.*.enable = false`, `boot.initrd.enable = false`,
  `boot.kernel.enable = false` — the AX630C boot chain owns all of it.
- `system.systemBuilderCommands` splices our depmod'd 4.19.125 modules tree in
  as `<system>/kernel-modules`, which is where the patched `kmod` looks.
- `environment.ldso` materialises `/lib/ld-linux-aarch64.so.1`.
- `axera-libs` is re-derived with `autoPatchelfHook` against this system's
  glibc/libstdc++; `/opt/lib`, `/soc/ko`, `/soc/scripts` and `/kvmapp` are
  `systemd.tmpfiles` symlinks into store paths.
- `nanokvm-identity.service` reproduces the initramfs's MAC/hostname
  derivation, which would otherwise be lost.
- `nanokvm-grow-rootfs.service` grows the root online instead of relying on
  `/opt/e2fs-static`.
- `nix.enable = false` — no Nix on the appliance; the rootfs is a fixed closure
  produced by the build host.

The image build asserts the `switch_root` contract (`/sbin/init` is a symlink,
the system profile resolves, stage 2 is in the closure) before it installs,
because that class of failure is invisible on a board with `bootdelay=0`.

---

## Known gaps

Ordered by how much they block a boot-test.

1. **`nanokvm.service` is not the vendor service.** The vendor `ExecStart`
   (`nanokvm.sh`) is a supervisor that regenerates the HTTPS cert+key under
   `/etc/kvm` and gives up after three crash-restarts; `ExecStartPre`
   (`nanokvm_pre.sh`) does the tmpfs copy. Those scripts live only in the
   vendor rootfs. The scaffold's unit approximates them and is **unverified**;
   the cert-generation step in particular has no replacement yet, so a fresh
   boot would have no HTTPS cert.
2. **`/kvmapp/scripts/usbdev.sh` is missing.** The server shells out to it for
   USB HID, mass-storage image mount, NCM and UAC2
   (`service/hid/status.go`, `service/storage/image.go`,
   `service/vm/virtual_devices.go`). It is not in the public `NanoKVM-Pro`
   repo — it ships only in the vendor rootfs. Either vendor the script into
   this repo (small, auditable, still vendor-derived text) or reimplement the
   configfs gadget setup from source. **Without it there is no keyboard/mouse.**
3. **WiFi is lost.** `aic8800_*.ko` and `/opt/firmware/aic8800/*.bin` come only
   from the vendor rootfs; `pkgs/ax-ko-blobs.nix` carries 22 `ax_*.ko` and no
   aic8800. Needs its own pinned derivation, or WiFi is dropped (it is already
   listed as "approve if wanted" in [provenance.md](provenance.md)).
4. **OTA.** `pkgs/update-package.nix` and [updates.md](updates.md) assume a
   file-overlay rootfs. Unresolved.
5. **`/kvmcomm/edid/*` and the rest of `/kvmapp`** (`cua/`, any other scripts)
   are unaudited for live dependencies on a Nix rootfs.
6. **`/etc/init.d/S99checkboot`** runs from the vendor `rc.local` and uses
   `fw_printenv`/`fw_setenv`. Whether it is load-bearing for A/B slot
   confirmation is unverified; if it is, it needs a NixOS equivalent.
7. **Hot patching changes shape.** `/kvmapp` becomes an immutable store
   symlink, so on-device patches only apply to `/dev/shm/kvmapp` and vanish on
   reboot. The `deploy-iterate` skill assumes a writable `/kvmapp`.
8. **`environment.ldso` alone is not an FHS.** Anything that `dlopen`s a bare
   `libfoo.so` from a path we have not materialised will still fail;
   `programs.nix-ld` is the bigger hammer if the patchelf approach proves
   insufficient.

---

## Validation ladder

Strictly in this order. Nothing here should touch eMMC until the step before it
has passed.

1. **Build.** `nix build .#nixos-rootfs` — no hardware.
2. **Offline inspection.** `debugfs` the raw image: `/sbin/init` resolves,
   `/opt/lib` and `/soc/ko` land, the closure is complete.
3. **Chroot smoke test on the running device — the important one.** Copy the
   system closure onto the live device (eMMC has room, or use the SD card),
   `chroot` into it and, on the real 4.19.125 kernel:
   - `systemd --version`, then `systemd --test --system` (does systemd 256 even
     start-analyse here?);
   - run `systemd-udevd --daemon` and confirm it produces device nodes;
   - run `sshd -t`, `resize2fs -P`, and `python3` on the display daemon;
   - `dlopen` the patchelf'd `libax_*.so` (a trivial C or `python3 ctypes`
     stub) and load `libkvm.so`.
     This is what turns "systemd 256 claims 4.19 support" into evidence, at
     zero boot risk.
4. **SD-card boot** (`docs/flashing-and-recovery.md`) — non-destructive, eMMC
   untouched. **Caveat: the SD image itself has never been hardware-verified**,
   so a failure here is ambiguous. Prove the SD path with the current Ubuntu
   rootfs *first*, then swap in the NixOS rootfs, or the two unknowns
   compound.
5. **eMMC.** Only after 3 and 4, and only with a stock vendor `.axp` on hand.

### Human-only actions

These need Jeremy; nothing above can be done by an agent alone.

- Hold `User` while powering on for the SD-boot test, and release immediately.
- Watch the **network** for a successful SD boot, not serial: every stage logs
  to UART0 on hidden pads (`docs/architecture.md`).
- Hold `User` ~10 s for AXDL download mode and re-flash a stock `.axp` if a
  boot fails. This is the only recovery path.
- Attach serial to UART0 if a boot fails silently and the cause is not obvious
  from the network behaviour — an FT232, not a CH340.

### Risks

- **`bootdelay=0`.** No autoboot interrupt window, so a rootfs that fails to
  reach userspace cannot be debugged from a U-Boot prompt. Diagnosis is serial
  or nothing.
- **AXDL is the whole safety net.** It lives in mask ROM and cannot be bricked,
  and Jeremy has exercised it — but it needs hands on the board, so a failed
  eMMC flash costs a physical trip, not a reboot.
- **Silent-failure modes are the norm here.** The `/lib`-symlink bug in
  `pkgs/rootfs.nix` shipped once precisely because a missing file produced a
  dead capture path rather than a build error. The image builder's contract
  asserts exist for that reason; extend them rather than trusting inspection.
- **`ax_cmm` without `cmmpool=` panic-loops.** Any change to how `/soc/ko` is
  loaded must preserve insmod-by-path-with-parameters. The curated loader is
  carried into the Nix rootfs verbatim for this reason.
