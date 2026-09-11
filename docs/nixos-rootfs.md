# Pure-Nix rootfs — the NixOS appliance (#26, #78)

The vendor Ubuntu 22.04 arm64 rootfs (`pkgs/base-axp.nix` → `pkgs/rootfs.nix`)
replaced by a system built entirely from nixpkgs, on the mainline kernel.

**Status (2026-09-07, #78): it boots this board.** `nixos/appliance.nix`
evaluates against the flake's one `nixos-unstable` pin and runs on
`pkgs/kernel-mainline` (Linux 7.1.3), with the NixOS stage-1 initrd embedded in
the kernel Image. Six slot-B hardware runs are banked in
[`docs/reference/mainline/nixos-appliance-20260907/HARDWARE.md`](reference/mainline/nixos-appliance-20260907/HARDWARE.md);
the last is a NixOS 26.11 system on the AX630C with **the board's own MAC, its
own DHCP lease and its derived hostname**, zero failed units, `NanoKVM-Server`
serving HTTPS, 26.3 s to multi-user. Two `qemu-system-aarch64 -M virt` boots are
banked alongside them.

**Two things are still unproven.** Every hardware run used the **loop-image**
root — a file on the vendor rootfs — which is what kept them reversible; root on
`p17` itself has not been booted. And no KVM hardware works on this kernel yet:
video (#83), USB HID policy (#82), the mini-display (#84) and WiFi (#85).

`.#nixos-firmware-image` packs all of it into a flashable `.axp`
([below](#the-image-builder--nixos-firmware-image)); flashing it is
[flashing-and-recovery.md](flashing-and-recovery.md#flashing-the-nixos-appliance-image),
and it overwrites the vendor system.

- [Verdict](#verdict)
- [The boot contract](#the-boot-contract)
- [The blob-policy assertion](#the-blob-policy-assertion)
- [What is built](#what-is-built)
- [The image builder](#the-image-builder--nixos-firmware-image)
- [Approaches weighed](#approaches-weighed)
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
| ~~**OTA redesign**~~ — **done (#86, nix-native since #100)** | An update is a **signed system closure**: the release names a toplevel store path, the device substitutes it from our binary cache with `require-sigs` against its own keys, sets the system profile and runs `switch-to-configuration boot`. The 4.19 overlay path is deleted, not ported. [updates.md](updates.md). |
| **Vendor scripts** | `/kvmapp/scripts/usbdev.sh` (the whole USB-gadget HID / mass-storage / NCM / UAC2 path the server shells out to) exists **only in the shipped vendor rootfs** — it is not in the public `NanoKVM-Pro` repo. See [gap 2](#known-gaps). |
| ~~**WiFi**~~ — **packaged (#85), not hardware-proven** | `pkgs/aic8800.nix` builds the two SDIO modules out of tree from `radxa-pkg/aic8800` against this kernel; `pkgs/aic8800-firmware.nix` MD5-pins the radio firmware; `nixos/wifi.nix` is the option, the loader unit, the supplicant and the `/kvmcomm/scripts/wifi.sh` the server's WiFi routes exec. **The radio scans on hardware (2026-09-11)** — [mainline-port.md](mainline-port.md) "ON HARDWARE: THE RADIO SCANS". |
| **The `rc.local` glue** | `S99checkboot` is now a unit and is live (below). `axemac.sh`, `npu_set_bw_limiter.sh` and a bare `devmem` poke are not. |
| **No hardware yet** | Video (#83) and USB HID (#82) are stubs on this kernel, and the mini-display (#84) has no framebuffer to draw on. ATX works in principle — #81 landed, and the appliance ships `nanokvm-gpio` and the libgpiod server build — but has never been exercised on the board. The appliance boots, serves the web UI and answers SSH; it is not yet a working KVM. |
| **Boot risk** | The rootfs is the one thing between U-Boot and a working device, `bootdelay=0` means there is no serial break-in, and recovery is physical AXDL. |

---

## The boot contract

What the running system owes the boot chain, and what it needs *from* the
rootfs. Sources: `nixos/appliance.nix`, `nixos/rootfs.nix`,
`pkgs/kernel-mainline.nix`, the server source, the QEMU runs, and
[mainline-port.md](mainline-port.md) §5–6.

### 1. The kernel, the initrd and the dtb are part of the generation

**NixOS's own bootloader writes `/boot`, and nothing else does** (#99). U-Boot's
`bootcmd` runs `sysboot mmc 0:4 any $scriptaddr /extlinux/extlinux.conf`, and
that file is written by
`nixos/modules/system/boot/loader/generic-extlinux-compatible`'s builder —
the same script every NixOS SBC uses. `boot.kernelPackages` is
`pkgs/kernel-mainline`, `hardware.deviceTree` is the blob compiled from `dts/`,
and `switch-to-configuration boot` copies this generation's kernel, initrd and
dtbs into `/boot/nixos/` and rewrites the config. A kernel change is a
generation change: it rolls back with everything else.

What the flashed image carries is that same builder's output, run against the
image's toplevel at build time (`nixos/lib/appliance-artifacts.nix`,
`mkBootDir`) — the way nixpkgs' `sd-image` does it in `populateRootCommands`.
So a freshly flashed board and one that has switched once have a `/boot` of
identical shape, and there is no second generator to keep in step.

One entry, as the image ships it:

```
DEFAULT nixos-default
TIMEOUT 1

LABEL nixos-default
  MENU LABEL NixOS - Default
  LINUX ../nixos/<hash>-…-appliance-…-Image
  INITRD ../nixos/<hash>-initrd-…-initrd
  APPEND init=/nix/store/<hash>-nixos-system-…/init mem=512M console=ttyS0,115200n8 …
  FDT ../nixos/<hash>-…-dtb-…-dtb/ax630c-nanokvm-pro.dtb
```

Sizes, measured: `Image` 42.3 MiB, `initrd` 7.6 MiB, `dtb` 16.1 KiB — 50 MB per
generation in `/boot/nixos/`, against a 272 MiB partition.
`boot.loader.generic-extlinux-compatible.configurationLimit` is 3, and
`pkgs/bootfs.nix` asserts the partition can hold four sets: the builder writes
the new one *before* it collects the obsolete one, so the peak is the whole menu
plus the set being replaced.

Three things about that config are load-bearing on this board, and each is
asserted at build time:

- **No top-level `MENU` keyword.** `parse_pxefile_top()` (`boot/pxe_utils.c`)
  does `case T_MENU: cfg->prompt = 1;` for *any* of them, and `menu_get_choice()`
  (`common/menu.c`) then takes `menu_interactive_choice()`, which calls
  `cli_readline_into_buffer("Enter choice: ", …)`. This board's console is a
  hidden, unterminated UART pad: a character of line noise is an unmatched key,
  the loop prints `<junk> not found` and asks again, and the timeout resets each
  time — forever. `boot.loader.timeout = 0` makes the builder emit no `MENU
  TITLE`; the per-`LABEL` `MENU LABEL` lines go to `parse_label_menu()`, which
  does not touch `cfg->prompt`. `mkBootDir` fails the build on any line starting
  in column 1 with `MENU`.
- **`FDT`, not `FDTDIR`.** `hardware.deviceTree.name` makes the builder name the
  file outright. An `FDTDIR` is resolved in `label_boot()` through `$fdtfile`,
  or `$soc-$board.dtb` if that is unset — which would put the filename in the
  U-Boot environment, where nothing in this repo maintains it.
- **`INITRD` needs `ramdisk_addr_r`, `FDT` needs `fdt_addr_r`.**
  `get_relfile_envaddr()` returns `-ENOENT` for a missing variable and
  `label_boot()` then *skips the whole label* ("Skipping … for failure
  retrieving initrd"). Both are compiled into our U-Boot
  (`0x4e000000` / `0x49200000`) and `checks.uboot-mainline` §7 asserts it.
  The gap between `kernel_addr_r` (`0x4a000000`) and `ramdisk_addr_r` is what
  caps the Image at 64 MiB — asserted in `pkgs/kernel-mainline.nix`.

Paths in the config are relative to the config's own directory
(`ctx->bootdir` in `get_relfile()`), which is `/extlinux` — hence `../nixos/…`.
U-Boot's ext4 walker resolves `..` as an ordinary directory entry.

### History: the initrd used to live inside the Image

Until #99 the appliance kernel embedded the NixOS stage-1 initrd through
`CONFIG_INITRAMFS_SOURCE`, because the *vendor* U-Boot called
`booti 0x40200000 - 0x40001000` — the `-` is the ramdisk argument — and no
partition held one. That reason died with #89 rung 3, when the mainline chain
started reading extlinux; the embedding outlived it by two issues. The
`bringup` variant (#75–#77) still embeds, and always will: its `/init` is the
only userspace that can exist, because there is no rootfs to switch to.

Embedding also replaced the kernel's built-in `usr/default_cpio_list`, which is
the only thing that creates `/dev/console` before PID 1 — so the appliance's
initrd had to carry a hand-built three-entry cpio appended after it, or stage 1
died on its first `exec 8>&1` with no output at all. With
`CONFIG_INITRAMFS_SOURCE` empty that default list is back and both the appendix
and the trap are gone.

### 2. `init=`, `/init`, and which one is the generation switch

Two mechanisms, and the first one is what a switch actually uses.

**Every `LABEL` pins its generation.** The command line comes from the extlinux
`APPEND` line, which `sysboot` copies into `bootargs` before `booti` (the device
tree's copy always loses to `fdt_chosen()`,
[mainline-port.md](mainline-port.md) §5, trap 2), and NixOS's builder writes
`init=<toplevel>/init` into each entry. That is what lets `extlinux.conf` and
`extlinux-fallback.conf` select two different generations out of the same set
of labels.

**The image also ships a profile symlink**, as a backstop for a command line
that carries no `init=`:

```
/init      -> /nix/var/nix/profiles/system/init
/sbin/init -> /nix/var/nix/profiles/system/init
```

`/sbin/init` costs a symlink and is what the vendor initramfs would exec if this
image were ever booted by the 4.19 kernel. `/init` is stage 1's built-in
default (`stage2Init=/init`, `switch_root`ed into `$targetRoot`), so a board
whose `/boot` was hand-written during a hardware round still boots whatever the
profile points at.

**Pinning `init=` is what makes the rollback possible at all.** U-Boot's
`altbootcmd` boots a second config, `extlinux-fallback.conf`, and the only thing
that distinguishes the two files is which `LABEL` their `DEFAULT` selects. With
the profile symlink deciding instead, both entries would resolve to the same
userspace at boot time and the fallback would be a copy of the thing that just
failed. See "Rollback" below.

`nixos/lib/appliance-artifacts.nix` asserts both halves offline, with `debugfs`
against the built ext4: the symlinks are symlinks, the profile resolves, stage 2
is in the closure, `<toplevel>/init` starts with `#!`, and `<toplevel>/kernel`,
`/initrd` and `/dtbs` are all in the image — without them the extlinux builder
has nothing to copy and `/boot` names files that do not exist.

### 3. fsck and grow

Both happen, and the vendor `/init`'s static-e2fsprogs dance is gone — but they
happen in **different stages**, which is worth knowing before reading a boot log.

The fsck is stage 1's ordinary `fsck.ext4 -a`, before the root is mounted. The
**grow is stage 2's**: on this nixpkgs `fileSystems."/".autoResize` no longer
puts `resize2fs` in the initrd — it adds the `x-systemd.growfs` mount option,
and `systemd-growfs@-.service` does the work after systemd is up. The QEMU log
shows the two seconds apart:

```
[  3.155] stage-1-init: [fsck.ext4 (1) -- /mnt-root/] fsck.ext4 -a /dev/vda
[ 12.176] EXT4-fs (vda): resizing filesystem from 605322 to 605322 blocks
          Finished Grow Root File System.
```

That also settles the question this eMMC raises: **there is no partition table
to grow.** `systemd-growfs` only ever grows the *filesystem* to the size of the
block device it is on — partition geometry is `systemd-repart`'s business, and
nothing here runs it. `/dev/mmcblk0p17` exists because the kernel's
`blkdevparts=` parser made it, and to `systemd-growfs` it is an ordinary block
device of a known size. The QEMU run makes the same point from the other end: it
grows a root on `/dev/vda`, a whole disk with no partition table at all.

The image is packed by `make-ext4-fs`, which shrinks it to its contents, so an
unresized root sits at ~1.3 GiB inside a ~29 GiB `p17`.

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

### 4. `/boot` — the boot payload, and it must stay writable

This contract is unchanged and is not optional. `NanoKVM-Server` writes
`/boot/eth.nodhcp`, `/boot/hostname`, `/boot/usb.disk0`, `/boot/usb.ncm`,
`/boot/usb.uac2`, `/boot/usb.disk1.{sd,emmc}` and reads `/boot/ver`; the module
loader sources `/boot/configs`; the vendor boot path uses `/boot/rec`,
`/boot/first_time_boot` and `/boot/check_resize2fs`. Every USB-gadget feature is
gated on a flag file there. Since #89 rung 3 it is also the BOOT PAYLOAD, and
since #99 that payload is NixOS's own: `extlinux/extlinux.conf`,
`extlinux/extlinux-fallback.conf`, and one `nixos/<hash>-…-{Image,initrd,dtb}`
set per generation in the menu. `switch-to-configuration boot` is the only
writer of all of it.

**It is ext4 since #89 rung 4, and 272 MiB.** The kernel needs ext4 for root
anyway, so putting `/boot` on it retires a trap worth remembering: mounting FAT
needs kernel config a minimal fragment does not get by default, and without
`CONFIG_NLS_CODEPAGE_437` / `CONFIG_NLS_ISO8859_1` the mount fails `-EINVAL` and
every USB-gadget flag silently reads as absent. Those symbols are still pinned in
`pkgs/kernel-mainline/ax630c.config` because the vendor-layout recovery image
still carries a vfat `/boot`.

The appliance mounts it `nofail,noatime` on `parts.bootfs.device` — GPT
partition 4, `/dev/loop0p4` (see below). `nofail` so a missing or corrupt
filesystem cannot hold up a boot. `umask=000` was a vfat-only accommodation and
is gone with the vfat.

### 4b. Rollback — two config files, a register, and a health gate

**The mechanism, end to end (#89 rung 5; this is what closed #79).** There are
no A/B twins and no slot register any more. There are two files in `/boot`:

| file | who writes it | what it names |
|---|---|---|
| `extlinux/extlinux.conf` | **NixOS's own extlinux builder**, run by `switch-to-configuration boot` | every generation in the menu, with `DEFAULT nixos-default` — the one being installed |
| `extlinux/extlinux-fallback.conf` | `nanokvm-mark-good`, only after a boot has proven healthy | **the same file with one line changed**: `DEFAULT nixos-<N>-default`, the generation that booted |

U-Boot's `bootcmd` boots the first; its `altbootcmd` boots the second.
`sysboot` boots a config's `DEFAULT` entry and cannot be told to pick a `LABEL`
from the command line, so **choosing a generation is choosing a file** — but
since #99 the two files carry the *same* labels and differ only in which one
`DEFAULT` selects. That is why the fallback is a derivation of the official
config rather than a second generator: nothing in this repo renders an
extlinux.conf any more.

**The refusal is the safety property.** `menu_default_choice()` returns
`-ENOENT` when `DEFAULT` names a label the file does not define, and
`handle_pxe_menu()` then falls through to `boot_unattempted_labels()`, which
boots the **first** label — `nixos-default`, the generation the rollback exists
to escape. So `nanokvm-mark-good` checks for `LABEL nixos-<N>-default` in the
official config before it writes anything, and on failure exits 1 with the
reason in the journal and the previous fallback untouched. It also refuses to
write a fallback that differs from `extlinux.conf` in more than its `DEFAULT`
line. `nix flake check`'s `nanokvm-mark-good-fallback` runs both paths for real
against a fake `/boot`.

`configurationLimit` is 3, and that is a floor as much as a budget: an update
can put the default one generation ahead of the fallback (and no further —
`nanokvm-update` refuses to install over a boot that has not been marked good),
so the menu has to name at least two, and the third is a spare.
`nixos/appliance.nix` asserts it.

**The counter is a register, not the environment.** `bootcount` lives in
`TOP_CHIPMODE_GLB_BACKUP1` (`0x02390030`) behind U-Boot's
`DM_BOOTCOUNT_SYSCON`, because patch `0020` stopped U-Boot reading the
environment off the eMMC at all. The word holds the magic `0xB001` in bits
31..16 and the count in bits 15..0, so:

```
0xB0010000   healthy, counter cleared
0xB0010001   one boot attempt since the last healthy boot
```

It survives a warm reboot and a chip reset and clears on power loss — the right
lifetime for a boot counter, and the reason a cold-started board always begins
at zero. `bootlimit` is 3 and the test is `bootcount > bootlimit`, so **three
attempts run `bootcmd` and the fourth runs `altbootcmd`**, which also sets
milestone bit 30 (`0x40000000`) in the neighbouring register `0x02390024` — the
serial-less evidence that a rollback happened.

**Marking a boot good.** `nanokvm-mark-good.service`, started by a timer at
`OnBootSec` (60 s by default), polls until all three of these hold or
`markGood.timeoutSec` (240 s) runs out:

- `systemctl is-system-running` is `running`,
- there is a default IPv4 route,
- the web server answers `https://127.0.0.1/`.

Then it writes `0xB0010000` to the counter and derives
`extlinux-fallback.conf` from `extlinux.conf`.

Four details in that are load-bearing:

- **A timer, not `WantedBy=multi-user.target`.** `is-system-running` only
  reaches `running` when the boot's initial transaction is empty, so a unit
  inside that transaction polling for it would be waiting for itself.
- **`/run/booted-system`, not a copy of `extlinux.conf`.** A `nixos-rebuild
  switch` between boot and now has already rewritten `extlinux.conf` to name a
  generation that has never booted; copying it wholesale would promote an
  untested system on the strength of a different one's health. The booted
  system is mapped to its `nixos-<N>-default` label through the highest
  `/nix/var/nix/profiles/system-N-link` that resolves to it — the same place
  the extlinux builder enumerates.
- **It deletes nothing.** The extlinux builder collects its own obsolete
  kernels, keyed on the generations it just wrote entries for; anything this
  script removed would be something that builder had decided to keep. (The
  collector it replaced got this wrong once, with a `sed` whose `\|` was a
  literal bar under a `|` delimiter: the keep-list came out empty and it
  deleted the live dtb.)
- **`/proc/uptime`, not `date +%s`.** timesyncd jumps the clock months forward
  the moment DHCP lands, and a wall-clock deadline expires instantly when it
  does.

**The failure mode is the safe one.** Nothing here can strand the board: if the
gate does not run, or runs and finds the system unhealthy, the counter is simply
not cleared and the next boot counts one higher. Only *not* rolling back
requires something to work.

**ONE FAILED UNIT IS ENOUGH TO WITHHOLD THE COUNTER CLEAR**, and that is the gate
working, not a bug — but it does not look like one from a distance. A unit that
fails at boot makes `is-system-running` `degraded` forever, so `mark-good` polls
for four minutes and gives up, `bootcount` stays `0xB001000N`, and three more
reboots roll the board back. Worse, the wait is self-worsening: while it polls,
`nanokvm-update-reboot.timer` fires a service ordered `After=nanokvm-mark-good`,
which queues a job and turns `degraded` into **`starting`** — so by the time the
gate reports, the reason it names is no longer the reason the check returns
false. Read its own log, which prints both (`is-system-running=…` and the failed
units) before exiting; seen on hardware 2026-09-11 with `nanokvm-wifi.service`
failing on a board with no enumerable SDIO card. The repair, once the unit is
fixed or its failure accepted, is `systemctl reset-failed <unit>` and then
`systemctl restart nanokvm-mark-good` (**restart**: the unit is a
`RemainAfterExit` oneshot, so `start` is a no-op).

**systemd's runtime watchdog is armed at 60 s** (`RuntimeWatchdogSec`), so a
PID 1 that stops running resets the board into that count instead of leaving it
dark. Without it the ax630c watchdog is petted from kernel context for as long
as the kernel schedules, which protects against nothing a user would call a
hang.

**Forcing a fallback by hand**, e.g. to check what it would boot:

```sh
devmem 0x02390030 32 0xB001000A   # counter well past bootlimit
reboot                            # next boot takes altbootcmd
```

and to see where things stand:

```sh
devmem 0x02390030 32                          # 0xB0010000 = healthy
devmem 0x02390024 32                          # bit 30 set = rolled back
head -4 /boot/extlinux/extlinux.conf          # DEFAULT nixos-default
head -4 /boot/extlinux/extlinux-fallback.conf # DEFAULT nixos-<N>-default
nanokvm-update status                         # both DEFAULTs, resolved to generations
nanokvm-mark-good --no-wait                   # re-derive the fallback by hand
```

**The kernel half — closed by #99.** It used to be true that a rollback was a
*userspace* rollback: the kernel and device tree were flake artefacts in
`/boot`, outside any generation. #86 content-addressed them
(`Image-<16 hex of its sha256>`) so two configs could name two kernels, at the
cost of a bespoke naming scheme, a `nanokvmboot=` command-line token so
`nanokvm-mark-good` could tell which kernel `sysboot` had loaded, a copier in
the updater and a collector in the health gate. All four are gone. The kernel,
the initrd and the dtbs are store paths inside the generation, the official
builder copies them under their store names, and the entry that names a
generation names its kernel by construction.

Still not a kernel rollback: the boot chain itself. `spl`, `atf` and `uboot` are
single copies with no twins, and a U-Boot candidate is tried through the
one-shot chainload slot ([mainline-port.md](mainline-port.md) §11.10), never by
writing the partition.

**Rejected designs, and why.**

- *One config file, two `LABEL`s, and let U-Boot choose.* `sysboot` takes no
  label argument, so the selection would have to come from `pxe_label_override`
  in the U-Boot environment — and patch `0020` stopped this U-Boot reading the
  environment off the eMMC at all, precisely so a userspace `fw_setenv` could
  not race a reboot. Two files and one `DEFAULT` line needs no bootloader state.
- *Keep the `nanokvmboot=` token.* It answered "which kernel did U-Boot load",
  which was only a question while the kernel was outside the generation.
  `/run/booted-system` now answers it completely.
- *Keep the content-addressed `Image-<hash>` copy.* It is the same idea as the
  store path, implemented twice: `/boot/nixos/<store hash>-…-Image` is already
  content-addressed, already deduplicated across generations, and already
  collected by the builder that wrote it.

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
MAC        = 48:da:35:xx:HH:LL
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

### 6. The eMMC map: `spl` + `disk`, and a real GPT

**Why the eMMC is presented as two devices.** The AX630C BootROM reads its
first-stage loader from byte 0 of the eMMC **user area**. Which area it reads is
a pin strap on `chip_mode`, not a setting, and this board is strapped to the
user area; its two eMMC boot partitions (`mmcblk0boot0`, `mmcblk0boot1`, 4 MiB
each) are blank and unreachable without changing that strap. Both facts were
measured on the device, 2026-09-09. So byte 0 belongs to the ROM, and neither an
MBR (LBA 0) nor a GPT (LBA 0 for the protective MBR, 1–33 for the header and
entry array) can live where the standard puts it.

Until #89 rung 4 the answer was to have no table at all: the layout was the
`blkdevparts=mmcblk0:…` clause of the kernel command line, seventeen partitions,
parsed by U-Boot on one side and `CONFIG_CMDLINE_PARTITION` on the other. It
worked, and it cost every tool that speaks GPT.

**The layout now splits the card in two.**

| | | |
|---|---|---|
| `spl` | the first 768 KiB | the ROM's image and nothing else; never inside a partition table |
| `disk` | everything after it | carries a spec-conformant GPT at ITS OWN LBA 0 |

`disk`'s protective MBR is at physical LBA 1536, its header at 1537, its entry
array at 1538–1569, its first usable LBA at 1570, and its alternate header in
the last sector of the eMMC — exactly where the UEFI specification puts each of
them, measured from `disk`'s own start. Five partitions with names, type GUIDs
from the Discoverable Partitions Specification and pinned partition GUIDs:

```
p1 atf     1M    phys 0x1C0000    p4 boot    272M  phys 0x5C0000   (ext4)
p2 uboot   2M    phys 0x2C0000    p5 rootfs  rest  phys 0x115C0000
p3 env     1M    phys 0x4C0000
```

`sgdisk`, `sfdisk`, `parted`, `blkid` and `lsblk` all read it as an ordinary
disk. `blkid` on the running board reports `PARTLABEL="rootfs"` and a stable
`PARTUUID`.

**How each side reaches it.**

- **Linux** cannot be told to parse a table at an offset, so it is told the one
  thing it can do without a table: `blkdevparts=mmcblk0:768K(spl),-(disk)`,
  which yields `/dev/mmcblk0p1` and `/dev/mmcblk0p2`. Stage 1 then runs
  `losetup -P /dev/loop0 /dev/mmcblk0p2` in `preLVMCommands` — after udev has
  settled, before anything is mounted — and the in-kernel EFI parser brings up
  `/dev/loop0p1..5`. Root is `loop0p5`, `/boot` is `loop0p4`.
  `CONFIG_EFI_PARTITION` and `CONFIG_BLK_DEV_LOOP` are therefore both on the
  root path: without either, the loop comes up bare and there is no root.
- **U-Boot** reads the same table directly, through
  `CONFIG_EFI_PARTITION_BASE_LBA=1536` (patch `0023`, upstream-shaped, with a
  `gpt_base_lba` environment override). Inside `disk/part_efi.c` every LBA stays
  table-relative; only a read and a partition's reported start translate. So
  `sysboot mmc 0:4` finds `boot` by GPT partition number and `part list` prints
  the device sectors `ext4load` will actually read.

**One definition, seven consumers.** `nixos/lib/emmc-layout.nix` holds the list
and renders three views of it — the GPT (disk-relative LBAs, handed to `sgdisk`
by `pkgs/gpt-image.nix`), the flash view (physical byte offsets, for the `.axp`
manifest and for `dd`), and the two-entry `blkdevparts=` clause. From those come
the SPL's compiled-in `ATF_HEADER_FLASH_BASE` / `UBOOT_HEADER_FLASH_BASE`,
U-Boot's `gpt_base_lba` and `bootpart`, `/etc/fw_env.config`, the NixOS
`fileSystems` devices, the extlinux `APPEND`, and `tools/migrate-layout.sh`'s
`dd seek=`. The module asserts they agree, and asserts the invariant the whole
migration rests on: **`rootfs` starts at the same byte, 0x115C0000, as it did
under the vendor's 17-partition map.**

**`/etc/fw_env.config` is `/dev/mmcblk0 0x4C0000 0x100000`** — the `env`
partition's PHYSICAL offset, so `fw_printenv`/`fw_setenv` address the raw eMMC
and need no loop device. It is the same number `CONFIG_ENV_SIZE` is set from and
the same one the stored environment image is built to.

`nanokvm-checkboot.service` still re-arms the A/B slot bits of `0x02390024`.
Under the minimal layout **those bits select nothing** — the rebuilt SPL has
both `_BAK` bases equal to the A bases, so slot A and slot B are the same two
partitions. It is kept because it keeps bits 2–5 in a deterministic state, which
is what makes `0x300000x5` a readable oracle rather than a value that alternates
every boot, and because it still chooses on a vendor-layout system. Rung 5
replaces it with U-Boot's `bootcount`/`altbootcmd`.

`nix flake check`'s **`emmc-partition-map`** prints both layouts — the vendor
seventeen and the minimal six — with offsets, sizes and the resulting
`fw_env.config`.

**The one-time shrink.** A GPT reserves the last 33 LBAs of the device for the
alternate header. The old table ran `rootfs` to the last byte of the eMMC and
the filesystem had been grown to fill it, so after the migration the filesystem
is 16896 bytes larger than its partition — and ext4 refuses to mount rather than
truncating (`bad geometry: block count … exceeds size of device`). Stage 1 runs
`resize2fs` with no size argument, which resizes to the device, shrinking
included; it demands a check only when it has to, so every boot after the first
is one command and no fsck.

**Rejected alternative: a hybrid SPL header carrying the GPT (2026-09-12).**
Since we sign the SPL ourselves, its 1 KB header could carry a protective MBR
and the GPT header in place: the RSA signature field occupies header bytes
444–827, which covers the MBR partition table (446–509), its `0x55AA`
(510–511) and the GPT header (512–603), and that signature is only verified
when the efuse `SECURE_BOOT_EN` bit is set (`boot/bl1/core/boot/boot.c`
`is_secure_enable()`; unburned here). The partition array can live at any
LBA the header names, so LBA 2 onward stays the SPL payload. Linux and U-Boot
would then see a spec-conformant GPT at LBA 1 with no `blkdevparts` split, no
loop mapping and no base-LBA patch. It was not done because the header's
word checksum (`verify_img_header`: `calc_word_chksum` over everything after
`magic_data`) covers those same bytes: every GPT header rewrite — any
`sgdisk`/`parted` edit, since the header CRC changes — silently invalidates
the SPL header, and the next boot is an AXDL trip. An additive checksum could
be compensated with a fix-up word, but only by a step every partition tool
would have to know about. The split keeps the SPL out of every writer's path,
which is the property that matters.

**And the ROM's window is not narrower — measured on hardware, #93,
2026-09-12.** The open question was whether the BootROM mirrors the SPL's own
`verify_img_header`, or whether it skips the checksum over that region with
`SECURE_BOOT_EN` unburned. It does not skip it. The signed container's header is
written twice (offset 0 and `0x20000`, `IMG_BAK_ENABLE` set in
`capability = 0x54FAFE`), so **both** copies were given the same one-byte flip
at header offset `0x300` — inside `signature[]`, exactly where the pMBR and GPT
header would sit — with `check_sum` deliberately left stale. That image was
written to p1 and verified from the medium after `drop_caches`. The board never
came back: 16 minutes after a warm reboot and 10 more after a cold power cycle,
no SSH, no ping, plug draw flat at 2.9 W, against a normal 2–3.5 min to SSH.
Two bytes, nothing else on the eMMC touched. Recovery was AXDL.

So the header is not a place any other tool can write, and the split layout
stands. The follow-up experiment — the same flip with `check_sum` recomputed,
which would separate "the ROM checks the checksum" from "the ROM also verifies
RSA without the efuse" — is academic for this decision: a checksum-only ROM
still means a `sgdisk` run bricks the board unless every writer knows to emit a
fix-up word. Evidence, images and the checksum tooling:
`docs/reference/mainline/spl-header-20260912/`.

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
- **`S99checkota`** (the OTA-commit `fw_setenv` clears) has nothing to commit
  any more: the vendor-shaped OTA is gone, an update is a signed store closure
  (#86, #100), and what vouches for one here is `nanokvm-mark-good` clearing
  `bootcount`, not an environment variable.
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

### 9. Kernel modules: almost none

`boot.kernel.enable` is **true** since #99 — the kernel, its initrd and its dtb
are part of the generation — but NixOS's own module machinery still has nothing
to work with: every driver this board needs to boot is built in, and stage 1
carries no `/lib/modules` tree.

The one exception is the video stack (#83): six modules — the three open
drivers (`open_vin_csi2`, `open_vin_capture`, `ax630c_venc_vcmd`) and the three
videobuf2 modules they import — copied out of the kernel derivation into
`nanokvm.video-modules` (`pkgs/video-modules.nix`) as a `/lib/modules/<release>`
tree. They are a store path in the closure like everything else, not a
NixOS-managed module set, and since #99 they and the kernel they load into come
from the same generation: `boot.kernelPackages` names the derivation they were
copied from, so the pair cannot disagree.

That has one non-obvious consequence in stage 1. `boot.initrd.kernelModules` and
`availableKernelModules` must be `lib.mkForce [ ]`, not `[ ]`: option lists
merge, and `nixos/modules/tasks/filesystems/ext.nix` adds `ext2 ext4` to
`availableKernelModules` for the root filesystem's type. A merge leaves those
two in place, and `makeModulesClosure` over an empty tree with a non-empty
module list is a hard build failure ("Can not derive a closure of kernel
modules").

`system.modulesTree` stays empty all the same: `nanokvm-video.service` loads the
six by `insmod` in the order that ships beside them, so nothing asks NixOS's
module machinery for a tree it does not have.

### 10. Nix — the appliance has a real store

`nix.enable = true` (#100). This is a NixOS system, so an update is what an
update is on any NixOS machine: `nix copy` a signed closure from our binary
cache, `nix-env --set` the system profile, `switch-to-configuration boot`. The
#78 appliance shipped `nix.enable = false` and had to rebuild every consequence
of that by hand — a tar transport, a list of which store paths belonged to which
generation, and a collector that refused to run whenever that list was missing.
All three are gone.

**Single-user, not the daemon.** There is one user here and it is root, and
nothing on this board ever builds, so the daemon is a socket, a unit, 32
`nixbld` accounts and a second process in the update path for nothing:
`systemd.sockets.nix-daemon.wantedBy = lib.mkForce []`, `nix.nrBuildUsers = 0`,
and `store = auto` resolves to the local store. It is also the **stricter** of
the two — signature checking on a direct `LocalStore` has no trusted-user
bypass, so `nix copy` cannot be talked into accepting an unsigned NAR the way a
trusted client of a daemon can. `nix.channel.enable = false` and
`system.disableInstallerTools = true`: nothing here evaluates nixpkgs, and a
channel would be a second, mutable source of truth for a system whose whole
point is that its generation came from a tagged release. `max-jobs = 0`,
`sandbox = false`, `auto-optimise-store = false` (eMMC), `require-sigs = true`.

**The image ships a registered store, not a directory of store paths.** A path
on disk that the database does not know is not a store path: `nix-env --set` on
one tries to *download* it, and `nix-collect-garbage` would delete it. See
[the image builder](#the-image-builder--nixos-firmware-image).

**What it costs, measured 2026-09-11:** the system closure is 748 paths /
1,379,028,112 bytes with nix and the updater, against 696 paths /
1,348,307,520 bytes for the same configuration with `nix.enable = false` and the
updater removed — **52 store paths and ~29.3 MiB, about 2.2%**. That is less
than the workarounds it replaced cost in complexity, and it bought the one
property the tar transport could never have: an update is authenticated by an
ed25519 signature the device checks against its own keys.

Design, trust model, garbage collection and the hardware plan:
[updates.md](updates.md).

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

## The image builder — `.#nixos-firmware-image`

A flashable `.axp`, built **from scratch**. The shipping 4.19 `.#firmware-image`
takes Sipeed's release bundle and rewrites members inside it; this one takes no
vendor bundle at all, and the packer fails the build if a `nanokvm-pro-base`
store path turns up among its inputs. Per-member provenance:
[provenance.md](provenance.md#the-nixos-appliance-image-nixos-firmware-image).
How to flash it and what to expect:
[flashing-and-recovery.md](flashing-and-recovery.md#flashing-the-nixos-appliance-image).

### Shape

Modelled on the way nixpkgs builds images (`sd-image.nix`, `image/repart.nix`):
a partition spec, a per-partition source, and the image exposed as
`system.build.<image>` on the configuration it images.

```
nixos/lib/make-axp-image.nix   the container: manifest + ZIP, board-agnostic
nixos/axp-image.nix            the member list: which derivation feeds which partition
nixos/image-axp.nix            a module: system.build.axpImage
```

`.#nixos-firmware-image` **is**
`.#nixosConfigurations.nanokvm-pro.config.system.build.axpImage` — one
derivation, reached two ways, so the image can never describe a system other
than the one it contains.

### The manifest is derived, not written

`<Partitions>` and every `<Block id=>` come from
[`nixos/emmc-partitions.nix`](#6-the-emmc-map-and-etcfw_envconfig), which parses
the single `blkdevparts=mmcblk0:` clause in `dts/ax630c-nanokvm-pro.dts` — the
same string U-Boot parses to find `kernel`/`dtb`/`rootfs` by name and the kernel
turns into `/dev/mmcblk0pN`. The flasher's partition table and the kernel command
line therefore cannot disagree; there is one source and it is the device tree.

The container format was learned from the SDK's own packer
(`tools/mkaxp/make_axp_v2.py`), from the vendor bundle's central directory, and
from `axdl-rs` — the open host flasher this flake ships. It is a flat deflate
ZIP: one XML manifest, one member per image, `<File>` naming the member exactly.
Facts worth keeping, all of them read out of the flasher rather than assumed:

- **FDL1 and FDL2 are found by their `name` ATTRIBUTE**, not by `<Type>` or
  `<ID>`, and their `<Block>` must carry no `id` so it resolves to an absolute
  RAM address.
- **`select="0"` does not skip an image.** It is parsed and discarded — an
  unwanted image is *removed*, not deselected. `flag` is likewise dead.
- **Only `Type=CODE` images are written.** `INIT`, `EIP` and `ERASEFLASH`
  entries are never used, which is why this image ships no `eip_ax620e.bin`.
- **Every `<Img>` needs all of** `flag`, `name`, `select`, `<ID>`, `<Type>`,
  `<Block>` with both `<Base>` and `<Size>`, `<File>` (may be empty),
  `<Auth algo=>` and `<Description>`: the deserializer declares no defaults, so
  an omission is a hard parse error. An unknown `<Type>` gets past serde and
  then panics on an `unwrap`.
- **`<Base>` and `<Size>` are always parsed as hex**, with or without `0x`.
- **`<Partition size>` is passed to the device unscaled**; `unit="2"` is the
  only thing that makes it KiB.
- The write size comes from the ZIP member's uncompressed size, not from
  `<Block><Size>`.

### Adding a partition

Add it to the `blkdevparts=` clause in the DTS (which is the real change — it
is the partition table), then give `nixos/axp-image.nix` a `partitionImages`
entry naming a member and a file, and put the partition name in `imgOrder`
where it should be written. Nothing else needs editing: the manifest, the
size assertions and the check all follow from the map.

### The rootfs carries a Nix database

The image ships `/nix/var/nix/db` (#100), because **a directory of store paths
is not a store**. `nix copy`, `nix-env --set` and `nix-collect-garbage` all ask
the database what is valid, and a path that is on disk but unregistered does not
exist as far as nix is concerned — `nix-env --set` on one tries to *download*
it, which on a board whose only cache is our own release cache means an update
that reinstalls the system it is already running.

`nixos/lib/appliance-artifacts.nix`'s `mkStoreDb` builds it at **image-build**
time: `nix-store --load-db` over `closureInfo`'s registration into a private
`NIX_STATE_DIR`, `PRAGMA wal_checkpoint(TRUNCATE)` so no `-wal` is left for a
first boot to recover, and a sqlite assertion that `ValidPaths` is **exactly**
the closure — a db claiming a path the image lacks fails `nix-store --verify`,
and a path the db lacks is one the collector would delete out from under the
running system. `mkRootImage` copies it in beside the two profile symlinks, and
the packed ext4 is then asserted with `debugfs` to carry
`/nix/var/nix/db/db.sqlite` and its `schema`.

nixpkgs' image builders do this on **first boot** instead (a
`register-nix-paths` unit over `/nix-path-registration`). We do not: on this
board that first boot is the one the `bootcount` rollback is judging, and a
first boot that has to build a database before it can be a NixOS system is one
more way to fail on a board with no console.

The image no longer carries `/var/lib/nanokvm/closures` — the per-generation
closure lists the #86 collector needed, now that `nix-collect-garbage` computes
reachability itself.

### What is asserted

At pack time: every member fits its partition; the Axera 1 KB signed header is
present and its `img_size` fits (`<=`, not `==` — the SPL is padded to its flash
slot and the DDR-init image is a header with no payload); each A/B pair is one
image and is bound to the right partition; no input comes from the vendor
bundle.

At `nix flake check` time, `nixos-axp-manifest` opens the finished `.axp` and
re-checks all of it against the partition map and the flasher's parsing rules —
written from `axdl-rs` rather than from the packer, so the two failing to agree
is a build failure.

**A/B slots carry no slot identity.** Every A/B pair in the vendor v1.0.15
bundle is byte-identical — kernel, dtb, OP-TEE, U-Boot and ATF alike — and the
signed header has no slot field. A slot image is bound to its slot by the
partition it lands in and by `bootsystem`; there is nothing else to get right,
and `pkgs/slot-image.nix`'s `kernel_b.bin` file name is cosmetic.

### The environment, the logo and `/boot`

Three stored partitions had never been built from source, because the overlay
image inherited them. All three now are, and each turned out to be simpler than
expected:

- **`env` is not a member of the vendor bundle at all.** Its only env entry is a
  disabled `ERASEENV`, so a stock flash leaves the partition as it found it and
  U-Boot repopulates it — the download engine writes `bootargs` after the
  repartition step, and `set_slot_ab`/`update_cmdline` write the rest on every
  boot. Ours is `mkenvimage` over three committed lines, plus `bootargs` lifted
  verbatim out of the `u-boot.bin` this flake builds. `bootdelay=0` and
  `baudrate=115200` are U-Boot's *entire* compiled-in default environment (no
  `CONFIG_USE_BOOTARGS`, no `CONFIG_BOOTCOMMAND`), asserted against that same
  binary. A wrong env self-heals: `get_part_info()` falls back to the compiled-in
  `BOOTARGS_EMMC` whenever `bootargs` is missing or has no `blkdevparts`, and a
  bad CRC just loads the default. An all-zero env partition boots this board to
  slot A.
- **The logo is a plain BMP** — no Axera header, no signature. U-Boot's loader
  checks `BM`, the bit depth, and a whitelist of six geometries, computes the
  stride with no row padding, and **discards its own return value at the call
  site**. So a bad logo costs a console line, the ` logomode=` cmdline suffix and
  a reserved-memory node, nothing more; and the board's actual front panel (the
  172×320 JD9853 SPI TFT) is painted from an array compiled into U-Boot and
  never touches this partition.
- **`/boot` ships `ver` and nothing else.** The vendor's other four files are a
  MaixPy settings file and three flags consumed by the vendor `/init`. It must
  stay writable — every USB-gadget feature is a flag file there —
  [see the contract](#4-boot--p16-vfat-and-it-must-stay-writable).

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

**(d) No nix on the appliance — TAKEN in #78, SUPERSEDED by #100.** The
reasoning was that a package manager, a SQLite database and a daemon are the
opposite of "the system is exactly what the flake says"; that the image had to
fit beside a kernel in a fixed layout; and that a KVM's root account should not
carry a general-purpose build tool. The cost of *not* having it was supposed to
be one shell script.

It was reversed on measurement. The workarounds came to a 460 MB tar transport,
a hand-rolled store unpack, a per-generation closure list that was a database
reimplemented badly, and a collector that refused to run whenever one of those
lists was missing — against **52 store paths and ~29.3 MiB** for nix itself.
And the tar could not authenticate anything: a SHA-512 out of our own manifest
is integrity, not authenticity, where a signed NAR checked against the device's
own keys is the real thing. Two of the three original objections also turned out
not to apply — there is no daemon ([§10](#10-nix--the-appliance-has-a-real-store))
and the board builds nothing (`max-jobs = 0`).

---

## What is built

```
nixos/appliance.nix           NixOS module: the NanoKVM-Pro appliance
nixos/emmc-partitions.nix     the blkdevparts= parser: p16/p17, A/B slots, fw_env
nixos/rootfs.nix              eval-config -> closure -> rootless ext4 (+ sparse, + /boot)
nixos/lib/appliance-artifacts.nix  those two artifacts, as pure functions of the closure
nixos/qemu-test.nix           the same appliance retargeted at qemu-system-aarch64
nixos/loop-test.nix           the reversible on-device root: loop image, no re-arm
nixos/image-axp.nix           system.build.axpImage
nixos/axp-image.nix           the .axp's member list, per partition
nixos/lib/make-axp-image.nix  the .axp packer (manifest + ZIP)
nixos/lib/verify-axp.py       reads the finished .axp back -- `nix flake check`
```

```bash
nix build .#nixos-appliance        # root = the eMMC rootfs partition (p17)
nix build .#nixos-appliance-loop   # root = an image FILE loop-mounted off p17
nix build .#nixos-firmware-image   # the flashable .axp of the first one
nix run   .#nixos-appliance-qemu-run

# result/nixos_rootfs.ext4          raw (dd / debugfs / QEMU)
# result/ubuntu_rootfs_sparse.ext4  Android-sparse, the .axp member name
# result/system                     symlink to the NixOS system closure
# result/boot                       the extlinux tree this generation's /boot carries
# result/NOTES.txt                  variant, pin, root device, init contract
```

**One kernel for every root variant** since #99: it embeds no initrd, so it is a
function of its own sources alone. `.#kernel-mainline-appliance` is it, and
`.#checks.nanokvm-boot-dir` is the `/boot` tree built around it. The appliance
is also a first-class NixOS system:
`nix build .#nixosConfigurations.nanokvm-pro.config.system.build.toplevel`.

Build model: evaluated as a **native `aarch64-linux` system** and built through
binfmt/qemu-user (`extra-platforms = aarch64-linux` on the dev box). Nearly the
whole closure substitutes prebuilt from `cache.nixos.org`, so emulation only
pays for a handful of tiny system derivations. Cross-compiling a full NixOS
closure is the alternative and is materially worse.

Notable decisions inside `nixos/appliance.nix`:

- `boot.kernelPackages = pkgs.linuxPackagesFor <kernel-mainline>` and
  `boot.loader.generic-extlinux-compatible.enable = true` with
  `boot.loader.timeout = 0` and `configurationLimit = 3` — the kernel, the
  initrd and the dtb belong to the generation, and NixOS's own builder is the
  only writer of `/boot` (#99).
- `boot.initrd.enable = true` with `boot.initrd.systemd.enable = false`: classic
  script stage 1. A stage 1 that dies on this board is silent, a shell script
  that mounts one ext4 is the smaller and more inspectable thing, and the
  `panicOnFail` deadman is a property of *that* script. `top-level.nix` also
  swaps `<system>/init` for a copy of the systemd binary when it is on, which
  breaks the `/init` contract the rootfs asserts.
- All of the above are `assertions`, not conventions — including that the
  bootloader timeout stays 0 (a non-zero one makes the builder emit a top-level
  `MENU TITLE`, and U-Boot then reads a console nobody can reach) and that
  `hardware.deviceTree.name` is set.
- `environment.ldso` materialises `/lib/ld-linux-aarch64.so.1`.
- `nanokvm.rootImage.enable` switches root to a loop-mounted image file:
  `postDeviceCommands` mounts the carrier filesystem read-**write** (`losetup`
  opens the backing file `O_RDWR`; a read-only loop cannot carry a writable
  root) and attaches `/dev/loop0`, leaving the carrier mounted for the life of
  the system. `CONFIG_BLK_DEV_LOOP=y` in the kernel fragment exists for this.
- `nix.enable = true`, single-user, no daemon (#100) — the store is a real
  store with a real database, and an update is `nix copy` + `nix-env --set` +
  `switch-to-configuration boot`. Still never a `nixos-rebuild`: nothing on the
  board evaluates nixpkgs or builds anything. See [§10](#10-nix--the-appliance-has-a-real-store).
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
`nixos/lib/appliance-artifacts.nix` that `<toplevel>/init` in the built image
actually starts with `#!` — the *artifact*, because an imported profile could
re-enable the option under the assertion's nose.

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
   `devmem 0x10030028 32 0x000006A0` SoC poke. `S99checkota` has nothing to do
   here — see gap 5.
4. **WiFi — WORKING (#85, 2026-09-11).** `aic8800_bsp`
   and `aic8800_fdrv` are built out of tree from `radxa-pkg/aic8800` against
   this kernel (`pkgs/aic8800.nix`, vermagic asserted from the finished `.ko`),
   and the firmware — the only closed content the blob policy allows — is 62
   files MD5-pinned to AICsemi's own manifest (`pkgs/aic8800-firmware.nix`).
   `nanokvm.wifi.enable` is on by default; turning it off drops both from the
   closure. `aic8800_btlpm` is deliberately not built: Bluetooth is out of
   scope. The radio scans on the board; joining a network needs credentials —
   see [mainline-port.md](mainline-port.md) "ON HARDWARE: THE RADIO SCANS".
5. **OTA — CLOSED (#86, nix-native since #100).** An update is a **signed system
   closure**: `.#system-manifest` publishes ~200 bytes naming a toplevel store
   path, the release pushes that closure to our binary cache, and
   `nanokvm-update` substitutes it with `require-sigs` against the keys this
   system was built with, sets the profile and runs `switch-to-configuration
   boot`. `nanokvm-update gc` pins every generation a boot config's `DEFAULT`
   names — the rollback one above all — and then lets `nix-collect-garbage`
   compute the rest. The 4.19 overlay OTA is deleted with no replacement and no
   migration path — a vendor-layout board is reflashed over AXDL. Two
   placeholders remain (#96): the cache URL and its trusted key. Design, offline
   proof and the hardware plan: [updates.md](updates.md).
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
11. **Modules are loaded by us, not by NixOS — CLOSED (#83, #99).** Every
    driver but six is built in, and the six the video stack needs ride in the
    closure as `nanokvm.video-modules`, which `nanokvm-video.service` loads with
    `insmod` off the `load-order` file that ships beside them (section 9 above).
    `system.modulesTree` stays empty, so nothing consults
    nixpkgs' `kmod` — which is patched to search
    `/run/booted-system/kernel-modules/lib/modules`, not `/lib/modules`, and was
    the reason a modules tree could not simply be dropped into the filesystem.
    Anything that ever needs `modprobe` semantics — a second modular subsystem,
    or udev autoloading — reopens this.
12. **The one hardware stub left, and what it costs the product.**
    `nanokvm-usb` (**#82**) — no keyboard, no mouse, no mass storage, no NCM.
    The controller and the configfs function drivers are here and a host has
    enumerated a gadget off this board; what is missing is the POLICY, because
    `usbdev.sh` — the script that builds the gadget, its three HID report
    descriptors and the Microsoft OS descriptors — exists only in the vendor
    rootfs and is uncaptured (gap 2). The stub exits 0 and prints that. The
    mini-display daemon (**#84**) is `ConditionPathExists=/dev/fb0` and simply
    does not run. `nanokvm-video` is **not** on this list any more: #83 landed
    2026-09-10 and the board streams H.264 on mainline. ATX is not either: #81
    landed and the appliance drives it through `nanokvm-gpio` — but that tool has still
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

14. **The appliance runs on half its RAM, and `mem=512M` is not ours to drop
    yet.** The kernel command line the flashed board boots with carries
    `mem=512M` -- `free -m` reports a total of **428 MB** on a 1 GiB board. It is
    a vendor leftover for media carveouts the open stack does not use, and the
    appliance never chose it: the **vendor-derived U-Boot injects it from its own
    bootargs**, so it arrives with the kernel rather than from
    `nixos/appliance.nix`.

    Once the appliance kernel is loaded by **mainline** U-Boot the argument is
    ours to set, and it should go -- but not blindly. Removing it was measured on
    2026-09-08 (#89 rung 2p) and the board **hung past WDT0**, where the
    identical boot with `mem=512M` reset itself at 337 s every time; a hang that
    also defeats the watchdog is the AXI-stall signature on this SoC. Every
    `reserved-memory` node is inside the first 512 MB (atf `0x40040000`, optee
    `0x44200000`, vendor-pstore `0x48000000`, ramoops `0x480e0000`, bringup-log
    `0x480e8000`), so whatever is above it is **not described in the device
    tree** -- a TrustZone or TZASC-protected window would not be.

    So: find where the vendor U-Boot injects `mem=`, and what the region above
    512 MB is, before deleting it. Recorded for rung 3 of #26.

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

   Boots the generation's own `kernel` and `initrd` — the same two files U-Boot
   loads off `/boot` on the board (#99) — on a throwaway copy of the rootfs
   under `qemu-system-aarch64 -M virt`. `nixos/qemu-test.nix` adds a self-test
   unit that runs after `multi-user.target`, dumps the state of everything #78
   owns — root filesystem, `/etc/fw_env.config`, identity, `/kvmapp` and
   `/opt/lib`, every `nanokvm*` unit, failed units, the server log,
   `nanokvm-checkboot` — and powers the machine off, so a run is a diff-able
   artifact rather than a login prompt. Two runs are banked in
   [`docs/reference/mainline/nixos-appliance-20260907/`](reference/mainline/nixos-appliance-20260907/README.md).

   **What it proves:** that a kernel with no embedded initramfs, handed a
   separate initrd and a pinned `init=`, reaches multi-user with zero failed
   units; that the server binds `:80`/`:443`; and that the units behave when
   the hardware they want is absent (#99 run: clean, `videoStack` off because
   the six modules load on a virt machine and then nothing probes).
   **What it cannot prove:** anything about the
   AX630C — the device tree, clocks, pinctrl, eMMC, Ethernet, the watchdog and
   the A/B slot register are all QEMU's here, or absent.

   *(The old `tools/nixos-chroot-test` — systemd 256 chrooted on the running
   4.19 device — is superseded. It existed to probe the systemd-kernel floor,
   which no longer exists, and a real boot is strictly stronger. The script is
   still in the tree.)*
4. **The reversible on-device test: the loop-image root.** The eMMC is the
   device's only writable medium and `p17` carries the running vendor system, so
   the first hardware boot writes nothing it cannot take back:

   - `dd` an appliance kernel slot image to `/dev/mmcblk0p15` (`kernel_b`,
     slot B — p14 is slot A and the shipped 4.19 kernel), plus the matching
     mainline dtb to p13. **Historical:** this harness predates #99 and needed
     an initrd inside the Image. The board has run the mainline chain on the
     minimal layout since #89 rung 4, so a slot-B test now means the chainload
     slot for U-Boot and an ordinary generation switch for everything else;
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
6. **eMMC `p17`, by flashing `.#nixos-firmware-image`.** Last, and only after 4,
   and only with a stock vendor `.axp` on hand. This is the step that overwrites
   the vendor system, and from here the way back is AXDL with hands on the
   board. The image and its first-boot expectations are in
   [flashing-and-recovery.md](flashing-and-recovery.md#flashing-the-nixos-appliance-image);
   `nix flake check`'s `nixos-axp-manifest` is what stands between a build and
   that flash.

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
- **The boot counter does not survive a power cycle**, by design: it is a
  scratch register in the always-on chipmode block, so a cold start always
  begins at zero. A board that fails three warm attempts rolls back; a board
  power-cycled between each failure never reaches the limit. The fallback
  *config* is on disk and does survive, so the state that matters is durable —
  only the count is not.
- **A rollback rolls back userspace only.** One kernel `Image` in `/boot`,
  shared by both entries; a kernel change has no automatic fallback.
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
