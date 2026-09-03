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
| **The `rc.local` glue** | Not just the module loader: `axemac.sh`, `npu_set_bw_limiter.sh`, a bare `devmem` poke, and **`S99checkboot`, which writes the A/B slot-bootable register on every boot**. All need units, and the register writes need the script text read off the device first. |
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

- ~~The prebuilt Axera media modules pin `vermagic`.~~ **No longer binding for
  the video path (#55 M3, 2026-09-02):** capture and encode run on three
  from-source modules and no `ax_*.ko` is loaded, so nothing in the shipped
  stack demands `4.19.125 SMP preempt mod_unload aarch64`. Our own drivers are
  written against 4.19 APIs and would need porting, and the vendor blobs are
  still on the image as rollback — but the hard vermagic wall is gone.
- Config changes to the *same* kernel are not free either. The vendor defconfig
  has `# CONFIG_NAMESPACES is not set` and **no cgroup controllers at all**
  (`CGROUP_SCHED`, `MEMCG`, `BLK_CGROUP`, `CGROUP_PIDS`, `CGROUP_FREEZER`,
  `CGROUP_DEVICE`, `CGROUP_BPF` all off), plus no `TMPFS_XATTR`,
  `TMPFS_POSIX_ACL`, `OVERLAY_FS` or `SQUASHFS`. Turning options on to please a
  newer systemd is dangerous: `CONFIG_MEMCG` alone adds a pointer to
  `struct page`, and `ax_cmm` is a contiguous-memory manager that does page
  arithmetic. Any config change that shifts a struct the blobs touch is a
  silent memory-corruption bug, not a build error (`MODVERSIONS` is off, so
  nothing checks).

So: kernel 4.19.125 with the vendor defconfig is fixed for as long as the media
blobs are, and the rootfs has to live with it.

### What that config costs at runtime

Measured on the running device (`zcat /proc/config.gz`, then probing the live
systemd 249 with `systemd-run --wait --property=…​ /bin/true`):

- `cgroup2` **is** mounted unified at `/sys/fs/cgroup`, but
  `cgroup.controllers` is **empty** and `/proc/cgroups` lists nothing. So
  `MemoryMax=`, `TasksMax=`, `CPUQuota=` are accepted and **silently
  unenforceable**. Don't write units that depend on them for correctness.
- `/proc/self/ns/` contains only `cgroup` and `mnt`.
- `PrivateTmp=`, `ProtectSystem=strict`, `ProtectHome=`, `PrivateDevices=`,
  `ProtectKernelTunables=` and even `PrivateNetwork=` all return 0 — mount
  namespaces are unconditional in Linux regardless of `CONFIG_NAMESPACES`, and
  the rest degrade rather than fail. This is why the vendor's systemd 249
  sandboxing works today.
- **`PrivateUsers=yes` hard-fails**: `217/USER`, *"Failed to set up user
  namespacing: Invalid argument"*. `nixos/appliance.nix` asserts no unit sets
  it, because a NixOS module added later might.
- Two consequences worth writing down so nobody reaches for them:
  **`pkgs.buildFHSEnv` cannot work on this board at all** (both the bubblewrap
  and the chroot variant need user/PID namespaces), and
  **`system.etc.overlay.enable` is permanently off-limits** (needs EROFS +
  overlayfs, neither present).

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
| 2 | `/boot` must be in `fstab` and **writable**: the server writes `/boot/eth.nodhcp`, `/boot/hostname`, `/boot/usb.disk0`, `/boot/usb.ncm`, `/boot/usb.uac2`, `/boot/usb.disk1.{sd,emmc}` and reads `/boot/ver`; the module loader sources `/boot/configs`. On the device it is `vfat`, `umask=000`. |

The MAC/hostname derivation in step 7 also fixes the interface name: the vendor
rootfs is **ifupdown** (`/etc/network/interfaces`, `allow-hotplug eth0`,
`iface eth0 inet dhcp`, plus the sed-injected `hwaddress ether`). There is no
netplan; `systemd-networkd` and NetworkManager are both inactive. The interface
is **`eth0`**, and the derived hostname on the test unit is `kvm-6d73`.

### 2. Init system — and the SysV layer nobody documented

systemd 249, non-negotiably: the app service model (`nanokvm.service` with its
`ExecStartPre` tmpfs copy), the mini-display and ATX-GPIO units, and the vendor
`wifi.service` are all systemd units, and `systemd-modules-load` is what loads
`lt6911_manage` and the mini-display drivers.

```ini
# /etc/systemd/system/nanokvm.service, as it runs on the device
ExecStartPre=/kvmapp/scripts/nanokvm_pre.sh
ExecStart=/dev/shm/kvmapp/scripts/nanokvm.sh
Type=simple  Restart=on-failure  RestartSec=1  KillMode=control-group
```

**But systemd is not the whole boot.** `rc-local.service` is active, and
`/etc/rc.local` is the vendor's real boot glue — none of it has a NixOS
equivalent yet:

```bash
bash /etc/init.d/axemac.sh                      # eth0 RPS/RFS + ethtool -A rx on
bash /soc/scripts/auto_load_all_drv.sh          # THE ax_*.ko loader (ours, #39)
bash /soc/scripts/npu_set_bw_limiter.sh start
devmem 0x10030028 32 0x000006A0                 # undocumented register poke
bash /etc/init.d/axsyslogd start ; bash /etc/init.d/axklogd start
bash /etc/init.d/S99checkboot start
bash /etc/init.d/S99checkota start
systemctl is-active --quiet sysdev.service || systemctl enable --now sysdev.service
```

Two things here matter more than they look:

- **`S99checkboot` is load-bearing, confirmed.** It reads `bootsystem=` with
  `fw_printenv` and then writes the **A/B slot-bootable register** — `devmem
  0x2390028 32 0x10` for slot A, `0x20` for slot B — on **every boot**.
  `S99checkota` clears `upgrade_slot{a,b}_available` with `fw_setenv`. Neither
  has an `rc?.d` symlink; `rc.local` invokes them directly. A rootfs that drops
  them stops confirming the boot slot.
- **The `/soc/scripts/*.sh` shebang lie.** All 13 declare `#!/bin/sh` but use
  bash-only syntax (`function`, `[ == ]`). They work today *only* because
  `rc.local` invokes them with `bash`. Our curated `auto_load_all_drv.sh` is in
  that set. Anything running them must use bash explicitly.

Units the appliance actually needs: `nanokvm`, `nanokvm-display`,
`nanokvm-gpio`, the module loader, `sshd`, DHCP, `avahi`, time sync, log
rotation — plus NixOS replacements for the `rc.local` items above.

**Dead weight worth deleting rather than porting** (all present and mostly
enabled on the vendor rootfs): `sysdev.service` (a 14-line no-op sleep loop),
`isc-dhcp-server{,6}` (enabled *and* failed), the `rc2.d` `udhcpd` pointed at
**eth0** with a `192.168.0.20-254` pool — a latent rogue DHCP server on the LAN
— `bluetooth`, `cua.service` and its ~1 GB of Python ML packages, the twelve
leftover **PiKVM** accounts (`kvmd`, `kvmd-vnc`, `kvmd-janus`, …) and
`99-kvmd*.rules`, `/opt/etc`'s 173 MB of sensor tuning `.ini` files, `nginx`,
`apt-daily*` and `motd-news`. This is the actual size of the provenance win.

### 3. Userland the app depends on

- **Dynamic loader.** Vendor binaries request `/lib/ld-linux-aarch64.so.1`;
  NixOS has no such path until `environment.ldso` creates it.
- **`/opt/lib` AND `/opt/usr/lib` — the trap that would have shipped.** The
  exact link metadata, read off our own builds:

  | Object | Tag | Value |
  |---|---|---|
  | `NanoKVM-Server` | `DT_RUNPATH` | `$ORIGIN/dl_lib:/opt/lib:/opt/usr/lib` — **no store path at all** |
  | `libkvm.so.0` | `DT_RPATH` | `/opt/lib:<axera-libs store path>` |
  | `libax_*.so` | *(none)* | bare `DT_NEEDED libc.so.6 / libstdc++.so.6 / libax_engine.so` |

  `libkvm.so.0` `DT_NEEDED`s **`libopus.so.0` and `libasound.so.2`**, and
  *neither* is in the Axera lib set. On the vendor rootfs they resolve anyway —
  `libopus` from `/opt/usr/lib` (via the server's own RUNPATH), `libasound`
  from Ubuntu's default `/lib/aarch64-linux-gnu`. **NixOS has no default loader
  path**, so on a naive Nix rootfs the server dies at startup with
  `libasound.so.2: cannot open shared object file` — the same class of failure
  as the `DT_RPATH`-vs-`DT_RUNPATH` trap in
  [architecture.md](architecture.md#the-videoaudio-pipeline-our-libkvm), and
  just as invisible until the service crash-loops. The appliance module
  therefore stages `libopus` and `libasound` (from `crossPkgs`, the exact
  builds libkvm and the server were linked against) into `/opt/lib`, and points
  `/opt/usr/lib` at the same directory so every RUNPATH entry resolves.

  The `libax_*.so` themselves must be `autoPatchelf`'d (the scaffold does this)
  or reached through `nix-ld`. `libsns_dummy.so` is `dlopen`'d by bare name and
  needs the FHS path present.
- **`/soc/ko` + `/soc/scripts/auto_load_all_drv.sh`.** The loader (three
  from-source modules since #55 M3; no rollback copy ships since #54, the
  vendor `/soc/ko` blobs are purged) must keep insmod-by-path-with-parameters
  semantics; `ax_cmm` without
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
- **Python 3** for the mini-display daemon. Note the server also execs bare
  **`python`** (not `python3`) for user-uploaded scripts.
- **`/bin/bash`.** The vendor scripts are `#!/bin/bash` or
  `#!/usr/bin/env bash`; NixOS materialises only `/bin/sh` and `/usr/bin/env`.
  The Go server also execs `/bin/sh` by absolute path (twice).
- **`configfs` mounted at `/sys/kernel/config`** before any USB-gadget,
  mass-storage, NCM or UAC2 route works.
- **A PATH contract**, because the server and the vendor scripts shell out by
  bare name. From the live device: `awk basename cat chmod cp cut date devmem
  echo find fw_printenv fw_setenv grep head hostapd ifconfig insmod ip iptables
  kill ln lsmod mkdir mount openssl pgrep pkill printf rm rmmod sed sleep stat
  sync systemctl tail touch tr udhcpc udhcpd wc wpa_supplicant ethtool`, plus
  from the Go source `bash sh systemctl timedatectl reboot ip passwd pgrep ps
  grep touch rm wpa_cli chronyc aplay ether-wake python`. A missing entry is a
  feature that silently stops working, not a build error.
- **Debian systemd unit names.** The server drives units over D-Bus
  (`org.freedesktop.systemd1`) by literal name: `ssh.service`, `ssh.socket`,
  `avahi-daemon.service`, `kvm-sleep.service`, `tailscaled.service`. NixOS
  calls sshd `sshd.*`, so the web UI's SSH toggle would silently do nothing.
  The appliance module runs sshd as a **persistent daemon**
  (`services.openssh.startWhenNeeded = false`) and aliases `ssh.service` onto
  the real `sshd.service`. It does **not** alias `ssh.socket`: with a persistent
  daemon there is no `sockets.sshd` to alias, and the server's `ssh.socket`
  operations are all best-effort (`_ = …`, errors ignored) while `isSSHRunning`
  tolerates the socket lookup failing — so the toggle works end to end through
  `ssh.service` alone, and a fabricated ListenStream-less socket (which systemd
  refuses to load) would be strictly worse. `startWhenNeeded = true` was the
  original scaffold value and was a real defect: 24.11's sshd module then
  defines only `services."sshd@"` + `sockets.sshd`, so the `ssh.service` alias
  fabricated an empty ExecStart-less unit and the enable path failed.
- **The web bundle must sit beside the binary.** `router/router.go` serves
  `dirname(os.Executable())/web`, which is why `/kvmapp/server/` has that
  layout and why the tmpfs copy preserves it.

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
  derivation, which would otherwise be lost. It is pulled by `multi-user.target`
  with `wants = ["network-pre.target"]` (not `wantedBy = network-pre.target`,
  which is passive and never fires in this closure — a fixed defect).
- `nanokvm-grow-rootfs.service` grows the root online instead of relying on
  `/opt/e2fs-static`.
- `nanokvm-checkboot.service` reproduces `S99checkboot`'s A/B slot register
  write, gated on `/etc/fw_env.config` (see gap below).
- `nanokvm.service` carries an explicit **`path` (`serverPath`)** — the full
  bare-name command contract the server and its script children exec through
  (`environment.systemPackages` does not set a unit's PATH), plus
  `Environment=LD_LIBRARY_PATH=/opt/lib` for the bare-name dlopen chain.
- The curated module loader runs **verbatim** (`writeShellApplication` with
  `bashOptions = []`): the default `set -u` would kill it on the vendor script's
  own `$OS_MEM_MIN_SIZE`/`OS_MEM_MIN_SZIE` typo, taking `ax-modules.service` and
  therefore `nanokvm.service` down with it.
- `nix.enable = false` — no Nix on the appliance; the rootfs is a fixed closure
  produced by the build host.

**Four defects found in review, all fixed (2026-08-29):** the `ssh.service`
alias over a socket-activated sshd (fabricated an empty unit); the passive
`nanokvm-identity` `wantedBy` (random MAC every boot); the strict-mode module
loader (no capture, no web UI); and `nanokvm.service`'s missing PATH (every
bare-name `exec.Command` unresolved). Each is documented at its call site in
`nixos/appliance.nix`.

The image build asserts the `switch_root` contract (`/sbin/init` is a symlink,
the system profile resolves, stage 2 is in the closure) before it installs,
because that class of failure is invisible on a board with `bootdelay=0`.

Current output: **~2 GiB system closure → 2.9 GiB raw ext4 → 2.0 GiB sparse**,
against a 29 GB `p17`. For comparison the vendor rootfs **actually uses
4.5 GB** on the device — 3.1 GB of it `/usr`, including **965 MB of
`/usr/local/lib/python3.13` site-packages** (scipy, transformers, sympy,
onnxruntime, numpy, openai) that exist only for the disabled `cua.service` AI
assistant. So the Nix rootfs is not a size regression; it deletes roughly a
gigabyte of unused ML stack outright. Trimming further (`python3Minimal`,
dropping `usbutils`/`pciutils`) is a follow-up, not a blocker.

### The `boot.initrd.systemd.enable` trap

24.11's `nixos/modules/system/activation/top-level.nix` decides what
`<system>/init` is by branching on **`boot.initrd.systemd.enable` alone** — it
never consults `boot.initrd.enable`. With it on, `$out/init` stops being the
stage-2 shell script and becomes a copy of the **systemd ELF**, intended to run
as an initrd PID 1. The vendor initramfs would `switch_root` straight into
that, systemd would come up in initrd mode as the real PID 1, and the board
would die with no console.

It defaults `false`, so `boot.initrd.enable = false` is *not* what is
protecting us — and the trap is live, because 24.11's
`profiles/image-based-appliance.nix` sets it `mkDefault true`, and that profile
is exactly what someone would reach for next (it also turns off `nix.enable`
and `system.switch.enable`). It is therefore guarded twice: an assertion in
`nixos/appliance.nix` on the option, and a check in `nixos/rootfs.nix` that
`<system>/init` in the built image actually starts with `#!`.

### Reaching a bare-name `dlopen()` — the fallback ladder

If a vendor `.so` ever fails to resolve, two obvious fixes are dead on NixOS
and should not be attempted:

- **`ldconfig` / `/etc/ld.so.cache` does not exist.** nixpkgs patches glibc
  (`dont-use-system-ld-so-cache.patch`) so `LD_SO_CACHE` points inside glibc's
  own immutable store path. No cache can ever be written there, and `/lib` and
  `/usr/lib` are not on a Nix glibc's search path at all — dropping a `.so`
  into `/lib` accomplishes nothing.
- **`programs.nix-ld` does not help here.** nix-ld works by *being* the
  interpreter at `/lib/ld-linux-aarch64.so.1`, so it only intercepts a vendor
  **executable** whose `PT_INTERP` is that path. A `.so` dlopened from an
  already-running Nix-built process (`NanoKVM-Server` → `libkvm.so` →
  `libax_*.so`) is resolved by the Nix loader already in that process; nix-ld
  is never consulted. It also *sets* `environment.ldso` itself, so it conflicts
  with our direct glibc symlink, and its `NIX_LD_LIBRARY_PATH` ships via
  `/etc/profile`, which systemd services never source.

What actually works, in order:

1. **`patchelf` / `autoPatchelfHook` on the calling object** — what the
   scaffold does.
2. **`LD_LIBRARY_PATH` in the unit's `serviceConfig.Environment`** — the real
   fallback, and the only mechanism that reliably reaches a bare-name `dlopen`
   inside a running service. One line: `Environment = "LD_LIBRARY_PATH=/opt/lib"`
   on `nanokvm.service`. (`environment.variables` /
   `environment.sessionVariables` will *not* do this.)
3. `systemd.tmpfiles` `L+` to materialise the FHS path — necessary but not
   sufficient alone; `/opt/lib` is only searched because libkvm's `DT_RPATH`
   names it.
4. `/etc/ld-nix.so.preload` — nixpkgs moves the preload file to this real path,
   so a system-wide `LD_PRELOAD` does survive. Niche, but it is the one global
   loader hook that still exists.

### `libsns_dummy.so` has nowhere to come back from

Small but load-bearing: the MSP repo `pkgs/axera-libs.nix` pins ships **no
`libsns_dummy.so`** — only `libsns_dummy_bittrue.so`. (That derivation's
`WARN: libsns_dummy.so not found` has always been firing.) On the vendor rootfs
the file exists because the retained vendor image carries a prebuilt copy at
`/opt/lib`, which `pkgs/rootfs.nix` step `[5a1]` then overwrites with our
from-source build. A pure-Nix rootfs has no vendor image to inherit from, so
there the from-source `libsns-dummy` is not an override — it is the only
source, and the blob cannot silently return.

### Two glibcs, one loader — do not "fix" this

The image contains two glibcs: the 24.11 rootfs pin's, and the unstable pin's,
which our cross-built `NanoKVM-Server` / `libkvm` / `libsns_dummy` carry as
their `PT_INTERP`. That is fine and deliberate — but it constrains the
`autoPatchelf` step on the Axera libs:

`autoPatchelfHook` gives `libax_proton.so` an rpath for `libstdc++.so.6`
(gcc-lib) and **no rpath entry for `libc.so.6`/`libm`/`libpthread`**. That is
correct. Those resolve through the *running process's* loader, which for the
server is the unstable glibc's `ld-linux-aarch64.so.1`, whose built-in default
search path is its own matching `lib`. **Adding an explicit `${glibc}/lib` to
the Axera libs' rpath would pin the 24.11 `libc.so.6` under an unstable
`ld.so`** — a mismatched loader/libc pair, which is a crash, not a warning.
Verify this in the [chroot smoke test](#validation-ladder), do not "harden" it
at build time.

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
2. **`/kvmapp/scripts/usbdev.sh` is missing — no keyboard, no mouse.** 21.6 KB
   of `#!/bin/bash` that builds the entire USB gadget under
   `/sys/kernel/config/usb_gadget/g0`: three HID functions (`hid.GS0` keyboard
   8-byte, `hid.GS1` relative mouse 4-byte, `hid.GS2` absolute mouse 6-byte,
   each with an inline report descriptor), NCM with Microsoft OS descriptors,
   mass storage, UAC2, and the `udhcpd` instance on the `usb0` link. It is
   **not** in the public `NanoKVM-Pro` repo — verified by full-tree search — and
   ships only in the vendor rootfs. The Go source references it at **three
   distinct literal paths** (`/kvmapp/scripts/usbdev.sh` twice, and
   `/dev/shm/kvmapp/scripts/usbdev.sh` in `service/storage/image.go`); fix all
   three. Every gadget feature is also gated on a flag file on the vfat
   `/boot` (`usb.ncm`, `usb.rndis`, `usb.disk0`, `usb.disk1.{sd,emmc}`,
   `usb.uac2`, `usb.acm`, `usb.udisp`, `ncm.dhcp`, `eth.nodhcp`), with every
   descriptor value overridable by `/boot/usb.{vid,pid,serialnumber,…}`.
   Either vendor the script (small, auditable, still vendor-derived text) or
   reimplement the configfs setup from source.

   > **TODO (device capture, HID-critical).** The whole `/kvmapp/scripts/`
   > directory is vendor-only and absent from our `kvmapp` derivation — this
   > also blocks the `nanokvm.sh`/`nanokvm_pre.sh` supervisor (gap 1). Capture
   > it host-side once, e.g. `tools/kvmscp device:/kvmapp/scripts
   > pkgs/rootfs/kvmapp-scripts/`, review + license-note the text, then stage it
   > into `kvmapp` at `server/../scripts` so all three literal paths
   > (`/kvmapp/scripts/usbdev.sh` ×2, `/dev/shm/kvmapp/scripts/usbdev.sh`)
   > resolve after the tmpfs copy. Cannot be done from the build host alone.
3. **The remaining `rc.local` items.** `S99checkboot` now HAS an equivalent —
   `nanokvm-checkboot.service` writes the A/B slot register
   (`devmem 0x2390028 32 0x10|0x20`, chosen from `fw_printenv bootsystem`), the
   register semantics transcribed verbatim from the RE. It is **gated on
   `/etc/fw_env.config`** and inert until that file is present, because
   libubootenv's `fw_printenv` needs it to find the U-Boot env on eMMC and its
   contents (env device/offset/size) are not recoverable host-side — writing a
   guessed slot could break A/B fallback.
   > **TODO (device capture).** Read `/etc/fw_env.config` off the device (or
   > derive it from the eMMC env partition) and ship it, then `nanokvm-checkboot`
   > becomes live with no code change. Verify `fw_printenv bootsystem` returns
   > `a`/`b` on the unit before trusting the register write.

   Still unimplemented, and deliberately so (each needs the exact script text /
   register intent read off the device first): `axemac.sh` (eth0 RPS/RFS +
   `ethtool -A eth0 rx on`), `npu_set_bw_limiter.sh start`, and the bare
   `devmem 0x10030028 32 0x000006A0` SoC poke. `S99checkota` (the OTA-commit
   `fw_setenv` clears) belongs with the OTA redesign (gap 5), not here.
4. **WiFi is lost.** `aic8800_{bsp,fdrv,btlpm}.ko` are built from the SDK kernel source (the vendor
   `/soc/ko` copies are purged since #54, so the NixOS rootfs needs its own build
   into our modules tree), and their firmware is 28 files under `/opt/firmware/aic8800/`.
   Needs its own pinned derivation, or WiFi is dropped — it is already listed
   as "approve if wanted" in [provenance.md](provenance.md).
5. **OTA.** `pkgs/update-package.nix` and [updates.md](updates.md) assume a
   file-overlay rootfs. Unresolved.
6. **Timezone reporting is subtly wrong** (display-only; `timedatectl
   set-timezone` still works). `service/vm/datetime.go` reads the zone by
   `os.Readlink("/etc/localtime")` and slicing on the literal
   `"/usr/share/zoneinfo/"`. On NixOS the link target is `/etc/zoneinfo/<TZ>`,
   the slice misses, and the fallback returns `../../../etc/zoneinfo/UTC`. The
   module materialises `/usr/share/zoneinfo` (necessary, not sufficient). Left
   as a TODO because the two clean fixes both have a catch: a `tmpfiles L+
   /etc/localtime → /usr/share/zoneinfo/<TZ>` is rewritten back to the
   `/etc/zoneinfo` form by the next runtime `timedatectl set-timezone`, and
   patching the slice literal in `datetime.go` is a `pkgs/nanokvm-server.nix`
   change (server lane, not rootfs). Recommended fix: teach the Go slice to also
   accept `/etc/zoneinfo/`.
7. **Wake-on-LAN — FIXED.** The server runs `ether-wake -b <MAC>`; nixpkgs has
   no `ether-wake`, so the appliance ships a one-line `ether-wake` shim
   (`etherWakeShim`) that maps it onto `wakeonlan` (same magic packet, broadcast
   by default). On `serverPath` and `systemPackages`. Untested on hardware.
8. **`/opt/etc`** (173 MB of Axera sensor tuning `.ini` files) is unaudited.
   The ISP is bypassed on the KVM path, so the sensor tuning data is probably
   dead weight — and since #54 it is deleted from the image
   (the whole `/opt/etc` tuning set plus the model data; `ax_proton` itself
   is gone). (**`/kvmcomm/edid/*`** is no longer a
   question: the whole set is generated from source by `pkgs/edid` — just
   install the `edid` derivation's bins under `/kvmcomm/edid` with the vendor
   filenames.)
9. **Hot patching changes shape.** `/kvmapp` becomes an immutable store
   symlink, so on-device patches only apply to `/dev/shm/kvmapp` and vanish on
   reboot. The `deploy-iterate` skill assumes a writable `/kvmapp`.
10. **`environment.ldso` alone is not an FHS.** See
    [the fallback ladder](#reaching-a-bare-name-dlopen--the-fallback-ladder).

---

## Validation ladder

Strictly in this order. Nothing here should touch eMMC until the step before it
has passed.

1. **Build.** `nix build .#nixos-rootfs` — no hardware.
2. **Offline inspection.** `debugfs` the raw image: `/sbin/init` resolves,
   `/opt/lib` and `/soc/ko` land, the closure is complete.
3. **Chroot smoke test on the running device — the important one.**

   ```bash
   tools/nixos-chroot-test            # ship, loop-mount ro, chroot, check
   tools/nixos-chroot-test --cleanup  # undo everything
   ```

   It writes exactly one file (`/root/nixos-rootfs-test/rootfs.ext4`),
   loop-mounts it read-only, and **never touches a block device** — not
   `mmcblk0`, not `mmcblk1`. `CONFIG_BLK_DEV_LOOP=y` in the vendor defconfig.
   Inside the chroot, on the real 4.19.125 kernel, it checks: `systemd
   --version`; `systemd --test --system` (does the unit graph parse?);
   `udevadm --version`; `ld.so --list` on `NanoKVM-Server` and `libkvm.so.0`,
   which walks the whole `DT_NEEDED`/`DT_RPATH` chain **without executing
   anything**; and a `ctypes` `dlopen` of the patchelf'd `libax_*.so`.

   Note that everything it touches is addressed by absolute store path: `/etc`
   inside the image is empty (NixOS builds it during activation) and `/opt/lib`,
   `/soc/ko` and `/kvmapp` are `tmpfiles` symlinks that only exist after boot.

   **What this cannot prove: PID 1.** systemd running as a chrooted child is a
   materially weaker test than systemd running as init. The device already
   proves 249 survives this kernel; the 249 → 256 delta is the genuine unknown,
   and only a real boot closes it. Treat a green run as "nothing is obviously
   broken", not as clearance to flash eMMC.
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
