# Flashing & recovery

How to get a built image onto a NanoKVM-Pro, how to try changes without touching
eMMC, and how to get back to a known-good state. Read
[backup-and-restore](#backup-and-restore) **before** your first eMMC flash.

- [The `User` button](#the-user-button)
- [AXDL USB flashing (eMMC)](#axdl-usb-flashing-emmc)
- [Backup and restore](#backup-and-restore)
- [SD-card boot (non-destructive)](#sd-card-boot)
  - [Flashing the SD card remotely](#flashing-the-sd-card-remotely-no-card-reader)
- [First boot & the web UI](#first-boot--the-web-ui)
- [Serial console](#serial-console)

---

## The `User` button

The AX630C latches its **boot source from the `CHIP_MODE` strap at reset**, and on
the NanoKVM-Pro that strap is the **`User` button**. It has three behaviours:

| Action | Result |
|---|---|
| Power on **normally** | Boot **eMMC** (installed firmware). Always — regardless of SD presence. |
| Hold `User` **while applying power**, release right after | Boot the **SD card** (if a valid card is present). |
| Hold `User` **~10 s** | Enter **USB download mode** (AXDL) — the mask-ROM flasher. |

Because a normal power-on always boots eMMC, the SD path and download mode are
**both manually triggered** — there is no unattended "insert card to boot" and no
way to accidentally boot the wrong source. eMMC is never written unless you flash
it. This also makes recovery reliable: download mode lives in **mask ROM**, so it
**cannot be bricked** by a bad eMMC image.

> **No U-Boot autoboot interrupt window.** The shipped U-Boot environment has
> `bootdelay=0` — there is no autoboot countdown to break into, even with a
> working serial console, until you deliberately set one
> (`fw_setenv bootdelay 3` from a running system). Consequence: a bad
> kernel/boot-chain flash **cannot be caught at the U-Boot prompt** — you can't
> interrupt boot and load a known-good kernel manually. Recovery after a bad
> flash is the physical path above: hold `User` ~10 s for AXDL download mode,
> not a serial break-in.

---

## AXDL USB flashing (eMMC)

AXDL is Axera's USB download protocol. This flake packages the open
[`ciniml/axdl-rs`](https://github.com/ciniml/axdl-rs) flasher as `.#axdl`.

```bash
# 1. Build (or obtain) an image.
nix build .#firmware-image        # result/…-selfbuilt.axp

# 2. Put the device in download mode: hold `User` ~10 s while powering on.
#    It enumerates as USB VID:PID 32c9:1000.
#    (Use the device's USB-C/data port that maps to the SoC USB — on the Desk,
#     the HID/OTG port. If it doesn't enumerate, try the other port.)

# 3. Flash. --wait-for-device blocks until the device appears.
nix run .#axdl -- --file result/*-selfbuilt.axp --wait-for-device
```

The same command flashes **any** `.axp` — our image, or a **stock vendor** `.axp`
from the [NanoKVM-Pro releases](https://github.com/sipeed/NanoKVM-Pro/releases) to
return to factory. Keep a stock `.axp` on hand as your ultimate fallback.

> If you prefer, the user can run the flasher themselves in an interactive shell;
> from a Claude Code session, prefix with `!` to run it inline
> (`! nix run .#axdl -- --file … --wait-for-device`).

---

## Flashing the NixOS appliance image

```bash
nix build .#nixos-firmware-image       # result/AX630C_…-nixos.axp, ~458 MiB
nix run .#axdl -- --file result/*-nixos.axp --wait-for-device
```

Same tool, same download mode, same partition table as the vendor image. What
differs is everything inside it.

### What it contains

**A different system, on a different kernel.** Mainline Linux 7.1.3 with the
NixOS stage-1 initrd inside the Image, and a NixOS 26.11 rootfs in place of the
vendor's Ubuntu 22.04 — [nixos-rootfs.md](nixos-rootfs.md). The `.axp` is built
from scratch rather than overlaid on Sipeed's bundle, so **every partition it
stores comes from this flake**: boot chain, environment, logo, `/boot`, dtb,
kernel and rootfs. Only two members are not stored on the eMMC at all — FDL1 and
FDL2, the download agents the flasher pushes into BootROM RAM, and those are
ours as well. The per-member table is in
[provenance.md](provenance.md#the-nixos-appliance-image-nixos-firmware-image).

**Both kernel slots get the same appliance kernel.** There is no such thing as
a slot-A image: every A/B pair in the vendor bundle is byte-identical, and the
1 KB Axera signed header carries no slot field. A slot image is bound to its
slot by the partition it lands in and by `bootsystem`, nothing else.

**The boot chain is still the vendor-derived one** — Axera's bl1, their TF-A
2.7 fork and their U-Boot 2020.04 fork, all built from source by
`pkgs/boot.nix`. `.#nixos-firmware-image-mainline` builds the same appliance
with **mainline TF-A 2.15 and mainline U-Boot 2026.07** above the SPL, booting
the kernel with `sysboot` from `/boot/extlinux/extlinux.conf` (#89). That chain
has booted this board (rung 3) but **takes anywhere from three to twenty-five
minutes to reach SSH** because of #91, so it is not what
`.#nixos-firmware-image` flashes. Rung 4 is where the vendor-derived U-Boot
goes away for good; [mainline-port.md](mainline-port.md) §11.10 has the state
of it, and §11.11 has the timing — a dark board ten minutes after a mainline
flash is a normal boot, not a failed one (#94).

### Three differences from flashing the vendor bundle

**It writes the `env` partition; the vendor bundle does not.** Sipeed's `.axp`
carries no environment image at all, so a stock flash leaves whatever the board
had. This one overwrites p7 with a freshly generated environment
([nixos-rootfs.md](nixos-rootfs.md#the-environment-the-logo-and-boot)). Any
`fw_setenv` state on the device is gone after a flash. That is the intent — a
known environment rather than an inherited one — but do not expect a variable
you set by hand to survive.

**The download agents are ours, and have never run.** FDL1 and FDL2 come from
`pkgs/boot.nix` rather than from Sipeed's bundle, and `.#firmware-image` has
always used the vendor's, so this is their first exercise. FDL2 is the on-device
programmer: it consumes the partition table and expands the sparse ext4. If a
flash fails in a way that looks like a manifest or protocol problem, **suspect
FDL2 before the manifest.** The failure is benign — the agents run from RAM and
nothing has been written yet — so the recovery is to re-run the flasher with a
stock vendor `.axp`.

**Do not use `--exclude-rootfs`.** On the vendor bundle it was a "keep my data"
flag. Here it would install a mainline kernel, a mainline dtb and a NixOS
`/boot` over whatever rootfs is already on the device, which boots nothing.

### First boot

Stage 1 fsck's `p17` and `switch_root`s to `/init`; systemd then grows the
filesystem to the partition (the packed image is ~1.3 GiB inside a ~29 GiB
partition — there is no partition table to resize, only the filesystem).
Userspace derives the board's identity from the SoC UID exactly as the vendor
`/init` did, so:

- the MAC is the one this unit has always had (`48:da:35:…`),
- `ClientIdentifier=mac` gets it **the same DHCP lease**, so
  `tools/kvmssh` reaches it at the address it already knows,
- the hostname is `kvm-XXXX`, the first four hex chars of `sha512sum
  /device_key`,
- sshd is a persistent daemon with root login and password auth, and root's
  password is **`sipeed`** — the vendor image's documented default (#32).
  Change it on first boot.
- the web UI answers on `:80` and `:443` (self-signed cert, generated on first
  boot).

Boot takes about 26 s. All of the above was proven on this board in #78, from a
loop-image root: `docs/reference/mainline/nixos-appliance-20260907/HARDWARE.md`.

Until 2026-09-09 that first boot also ended `degraded`, with
`nanokvm-mark-good.service` failed: it clears the boot counter and then writes
`/boot/extlinux/extlinux-fallback.conf`, and the vendor layout has no extlinux
directory — its U-Boot loads the kernel from a signed partition by byte offset.
The unit now skips the promotion when the directory is not there, which also
closes the quieter half of the same bug: `/boot` is mounted `nofail`, so an
unmounted `/boot` used to get a fallback written into the root filesystem and
reported as promoted (#94).

### What is NOT there yet

**This is a booting appliance with a web UI, not a working KVM.**

| Missing | Issue |
|---|---|
| Video — no `/dev/video0`; the UI loads and streams nothing | #83 |
| USB HID — no keyboard, no mouse, no mass storage | #82 (the gadget policy half) |
| Mini-display and audio | #84 |
| WiFi | #85 |
| Self-update on hardware | #86 — the mechanism is built and proven offline, but no board has installed a bundle yet |

ATX power/reset works in principle (`nanokvm-gpio`, #81) but has never been
pulsed on hardware.

### Rollback, and what it costs

**Flashing this overwrites the vendor system.** Keep a stock `.axp` on hand;
AXDL re-flashing it is the way back, and it needs hands on the board.

**Rollback is live and it covers the kernel.** U-Boot counts boot attempts in
`0x02390030`; the fourth runs `altbootcmd`, which boots
`/boot/extlinux/extlinux-fallback.conf` instead of `extlinux.conf`. Those two
files carry the same per-generation labels and differ only in which one
`DEFAULT` selects; the kernel, initrd and dtb belong to the generation since
#99, so an entry that names a generation names its kernel. `nanokvm-mark-good`
promotes the generation that booted healthy. So a generation that does not come
up, *including one with a new kernel*, is undone unattended.
[nixos-rootfs.md §4b](nixos-rootfs.md#4b-rollback--two-config-files-a-register-and-a-health-gate)
and [updates.md](updates.md).

What still has no rollback is the **boot chain**: one `spl`, one `atf`, one
`uboot`, no twins. A U-Boot candidate goes through the one-shot chainload slot
(`nanokvm-uboot-test`), never a partition write, and a bad SPL is an AXDL trip.

**There is no deadman in the product image.** The #78 hardware harness carried a
900 s keepalive that returned the board to slot A on its own; that is a
test-variant module (`nixos/loop-test.nix`), deliberately not shipped. On the
flashed appliance a boot that comes up without reaching the network has no way
out but AXDL. That is the accepted trade — an appliance is supposed to stay up.

### Slot-B kernel testing still works, from the appliance

The A/B harness below is unchanged by this image, and everything it needs is in
the appliance's `PATH`: `devmem` (busybox), `dd` and `sha256sum` (coreutils),
`fw_printenv`/`fw_setenv` (ubootTools), `e2fsprogs`, `util-linux`. Slot A
carries the shipped appliance kernel and **slot B is free for test kernels**.

One difference from testing on the vendor system, and it matters:
`nanokvm-checkboot.service` re-arms **whichever slot actually booted**. A test
kernel that never reaches userspace consumes its BOOTABLE bit and falls back to
slot A by itself, as always — but one that *does* reach userspace re-arms slot
B and stays there. Disarm it deliberately (`devmem 0x2390028 32 0x10`) or stop
the unit before rebooting. The procedure is in the `mainline-boot-test` skill,
"Variant: from a flashed NixOS appliance".

---

## Backup and restore

**Do this before flashing eMMC the first time.** With SSH access to a
stock/working device, dump every partition so you can byte-restore later.

### The eMMC partition map

**There are two, and which one a board has is decided by its SPL.**

**The minimal layout (#89 rung 4)** — what
`.#nixos-firmware-image-mainline` flashes and what `tools/migrate-layout.sh`
converts a running board to. The eMMC is two logical devices: `spl`, the first
768 KiB, which the BootROM reads and which is deliberately outside every
partition table; and `disk`, everything after it, which carries an ordinary GPT
at its own LBA 0 (protective MBR at physical LBA 1536, header at 1537, array at
1538–1569, alternate header in the eMMC's last sector).

| GPT # | Name | Physical offset | Size |
|---|---|---|---|
| — | (`spl`) | `0x0` | 768 K |
| — | (GPT primary) | `0xC0000` | 17408 B |
| 1 | `atf` | `0x1C0000` | 1 M |
| 2 | `uboot` | `0x2C0000` | 2 M |
| 3 | `env` | `0x4C0000` | 1 M |
| 4 | `boot` | `0x5C0000` | 272 M, ext4 |
| 5 | `rootfs` | `0x115C0000` | rest, less the last 33 LBAs |
| — | (GPT alternate) | last 16896 B | |

On the running board Linux reaches it through
`blkdevparts=mmcblk0:768K(spl),-(disk)` plus a loop device stage 1 puts over
`/dev/mmcblk0p2`, so the partitions are `/dev/loop0p1..5` and carry PARTLABELs.
To read the table by hand, from the board or from a dumped image:

```bash
losetup -r -o 786432 -P /dev/loop9 /dev/mmcblk0
sgdisk -p /dev/loop9        # or: lsblk /dev/loop9; blkid /dev/loop9p5
losetup -d /dev/loop9
```

**The vendor layout** — seventeen partitions, no on-disk table at all, the map
being the `blkdevparts=` clause of the kernel command line. This is what a stock
Sipeed `.axp` and `.#nixos-firmware-image` (the vendor boot chain) flash, and
therefore what an AXDL recovery restores.

| # | Name | # | Name | # | Name |
|---|---|---|---|---|---|
| 1 | `spl` | 7 | `env` | 13 | `dtb_b` |
| 2 | `ddrinit` | 8 | `logo` | 14 | `kernel` |
| 3 | `atf` | 9 | `logo_b` | 15 | `kernel_b` |
| 4 | `atf_b` | 10 | `optee` | 16 | `boot` |
| 5 | `uboot` | 11 | `optee_b` | 17 | `rootfs` |
| 6 | `uboot_b` | 12 | `dtb` | | |

Both maps are generated from one definition, `nixos/lib/emmc-layout.nix`;
`nix build .#checks.x86_64-linux.emmc-partition-map` prints them with offsets.

Plus the two eMMC boot hardware areas, `mmcblk0boot0`/`mmcblk0boot1` — 4 MiB
each, blank on this board, and not reachable as a boot source without changing
the `chip_mode` strap. Dump them separately, as below.

```bash
# On the device: list the eMMC partitions and their names.
cat /proc/partitions
ls -l /dev/disk/by-partlabel/ 2>/dev/null   # minimal layout only

# Pull each partition + the boot areas (see the partition map above for names).
for p in /dev/mmcblk0p*; do
  n=$(basename "$p")
  ssh root@<device> "cat $p" | gzip > "backup/${n}.img.gz"
done
ssh root@<device> "cat /dev/mmcblk0boot0" > backup/mmcblk0boot0.img
ssh root@<device> "cat /dev/mmcblk0boot1" > backup/mmcblk0boot1.img
ssh root@<device> "cat /proc/cmdline"     > backup/cmdline.txt
```

Verify sizes look sane and the rootfs image gunzips + `debugfs`-stats cleanly.
The rootfs is the large one — ~30 GB, gzipped ~1.8 GB — back it up separately
with streaming gzip as the loop above already does; budget the time/disk for it.
To restore a single partition later, `dd` the raw image back onto the same
device; to fully recover, re-flash a stock `.axp` over AXDL (above).

### Changing the layout on a running board

`nix build .#migrate-layout` builds a self-contained kit — the script with every
offset substituted from `nixos/lib/emmc-layout.nix`, the four signed images
padded to 4 KiB, the generated GPT, and the 272 MiB `/boot` filesystem
compressed for the copy over. Untar it on the board and run:

```bash
migrate-layout backup    # the whole 277.75 MiB pre-rootfs span + the device's
                         # last 32 KiB + /boot as files, each verified against
                         # the medium
migrate-layout write     # GPT, atf, uboot, env, boot at their new offsets
migrate-layout spl --i-have-the-go    # the one-way step
migrate-layout restore   # puts every backed-up byte back
```

Two things to understand before starting.

**The rootfs never moves.** Both layouts start it at byte `0x115C0000`, which is
what makes an in-place conversion of a running system possible at all; the
layout module asserts it and the script re-checks it on the device.

**Between `write` and `spl` the board cannot boot.** The new `atf` and `uboot`
land on top of the old ones — both A/B copies — so the vendor SPL still in the
first 768 KiB would read its next stages from addresses that no longer hold
them. `restore` is the way back and it needs a running shell, so do not
power-cycle in that window. After `spl` the only way back is AXDL: flash
`.#nixos-firmware-image` (vendor boot chain, vendor SPL, seventeen partitions)
or a stock Sipeed `.axp`, both of which restore the vendor layout wholesale.
That needs `User` held ~10 s at power-on and a USB cable — a bench trip, not a
brick.

### Quick integrity check for signed-partition backups

The signed boot-chain images (`spl`, `atf`/`atf_b`, `uboot`/`uboot_b`,
`optee`/`optee_b`, `dtb`/`dtb_b`, `kernel`/`kernel_b`) all carry a 1 KB header
with magic bytes `0x55543322` at offset 4 (little-endian). A well-formed
backup of, say, the `kernel` partition (`p14`) should show:

```bash
zcat backup/mmcblk0p14.img.gz | xxd -s 4 -l 4 -
# 00000004: 2233 5455                                ".3TU"
```

If that doesn't match, the dump is truncated/corrupt, or it's the wrong
partition — re-pull it before trusting the backup as a restore point.

---

## SD-card boot

`nix build .#sd-image` produces a `dd`-able raw microSD image that boots the
**entire from-source stack from the SD/TF slot, leaving eMMC untouched** — the
safe way to test changes.

```bash
nix build .#sd-image
lsblk                                  # find the removable card, e.g. /dev/sdX
sudo dd if=result/AX630C_emmc_arm64_k419_sipeed_nanokvm-sdcard.img \
        of=/dev/sdX bs=4M oflag=direct conv=fsync status=progress
sync
# Insert the card, then HOLD `User` while applying power, release right away.
# Revert: power on WITHOUT holding `User` (and/or remove the card) -> stock eMMC.
```

### Flashing the SD card remotely (no card reader)

In this dev setup the SD card lives in the device's **own TF slot**, not a
reader on the workstation — the image is streamed **over SSH** into
`/dev/mmcblk1` on the running device instead of `dd`'d locally.

```bash
# 1. Safety guard FIRST, by exact sector count -- eMMC is mmcblk0, NEVER write
#    it during SD testing.
ssh root@<device> 'cat /sys/block/mmcblk1/size'
# Compare that number against the known card's sector count before doing
# anything else. If it doesn't match what you expect, stop.

# 2. Unmount any mounted mmcblk1 partitions on the device.
ssh root@<device> 'umount /dev/mmcblk1p* 2>/dev/null; true'

# 3. Stream the image over SSH straight onto the card.
dd if=result/AX630C_..._sdcard.img bs=4M | \
  ssh root@<device> 'dd of=/dev/mmcblk1 bs=4M conv=fsync && sync'

# 4. Verify. Drop the device's page cache first, or you hash cached pages
#    instead of what actually landed on the card.
ssh root@<device> 'echo 3 > /proc/sys/vm/drop_caches'
size=$(stat -c%s result/AX630C_..._sdcard.img)
ssh root@<device> "head -c $size /dev/mmcblk1 | sha256sum"
sha256sum result/AX630C_..._sdcard.img
# The two digests must match.
```

**How SD boot works (from the SDK source, confirmed against the official image):**
the BootROM's SD path is *file-based*, not raw-offset. Held at power-on, the
`User`-button strap makes the ROM read the MBR, mount the first **FAT32**
partition, and load **`boot.bin`** (the `boot/bl1/sd` SPL variant, which links
FatFS + the SD mmc driver). That SPL loads `atf.img` and `uboot.bin` as *named
files*; U-Boot's `sd_boot` command then `fatload`s `dtb.img` + `kernel.img` from
the same partition and sets `root=/dev/mmcblk1p2` (the card's ext4 p2). The
`sd-image` derivation is **byte-matched to the official v1.0.15 SD image** and
built with **no root** (mtools + `sfdisk` + the raw ext4 from `rootfs.nix`).

Two things worth knowing:

- **Console on UART0 (like the official image).** Every stage logs to
  `ttyS0` / `0x4880000`, which is on **hidden pads** — the exposed UART1 header
  pin is silent by design, even on a *successful* boot. So watch the **network**
  (DHCP → web UI → SSH), not serial. (An earlier attempt redirected the whole
  chain to UART1; that hung the SPL — touching UART1 MMIO while its clock is still
  gated — and produced total silence. That variant was removed; `sd-image` now
  builds the proven UART0 chain, the same binaries that boot this unit from eMMC.)
- **`sd_update` is a different thing.** U-Boot's `sd_update` command is an
  eMMC/flash *writer* — the FAQ's optional "flash eMMC after booting from SD"
  step — not the live-boot path above.

> **Caveat:** SD boot needs the button hold — it is *not* auto-on-insert (HIGH
> confidence, [Sipeed wiki](https://wiki.sipeed.com/hardware/en/kvm/NanoKVM_Pro/faq.html)).
> This is a manually-triggered test/recovery path, not an appliance boot.

### If the card does not boot

> **Status:** the `sd-image` was rebuilt to match the official card byte-for-byte
> on every inspectable axis (MBR, FAT boot sector, file set/names, `boot.bin`
> format) after the first attempt failed. It has not yet been re-verified on
> hardware; the one unprovable residue is our from-source SD-SPL binary's first
> hardware run.

Diagnose in this order:

1. **Confirm the button procedure.** Hold `User` while applying power, release
   immediately. A normal power-on always boots eMMC; holding too long enters USB
   download mode. Success = DHCP within ~60 s → web UI at `https://<ip>/` → SSH
   (`root` / `sipeed`) → `cat /proc/cmdline` shows `root=/dev/mmcblk1p2`.
2. **Serial is on UART0, not UART1.** If you probe serial, it's the hidden UART0
   pads (`0x4880000`, 115200 8N1) — an FT232 is more reliable than a CH340 for the
   SPL's non-standard early baud. `enter spl` then silence → the SD SPL's built-in
   DDR auto-training is the next suspect.
3. **Control test: the official Sipeed SD image** (`..._sdcard.img.xz` from
   [sipeed/NanoKVM-Pro releases](https://github.com/sipeed/NanoKVM-Pro/releases)).
   If it boots and ours doesn't, re-diff the two (ours is built to match; a
   remaining difference is a bug):

   ```bash
   sfdisk -d vendor.img; sfdisk -d result/AX630C_..._sdcard.img   # MBR
   dd if=vendor.img bs=512 skip=2048 count=1 | xxd                 # FAT boot sector
   mdir -i vendor.img@@1M ::/                                      # file set
   ```
4. ~~**Secure-boot check.**~~ **Ruled out (2026-07):** the dev-key-signed
   `.#firmware-image` boots from eMMC on this unit, so the `SECURE_BOOT_EN` efuse
   is open and signing cannot be what blocks the SD path.

---

## First boot & the web UI

On a clean boot our image auto-starts `nanokvm.service` (see
[architecture.md](architecture.md#the-two-app-stacks-nanokvm-vs-kvmcomm)). Once up:

- Open **`https://<device-ip>/`** and complete account setup / set a password.
- SSH is available as `root` (default password `sipeed` on the from-source image
  until you change it).
- The on-device **mini-display comes up from source** (`nanokvm-display.service`
  drawing the status screen: hostname, IPs, video state, fw version). If it stays
  dark past boot, run the post-flash checklist in
  [mini-display.md](mini-display.md#hardware-verification).

If the web UI is unreachable but the device pings, check the service:

```bash
ssh root@<device> 'systemctl status nanokvm; ss -tlnp | grep -E ":(80|443)"; \
  tail -20 /var/log/nanokvm/NanoKVM-Server.log'
```

---

## Slot-B kernel testing (proven procedure, 2026-08-30)

The A/B machinery gives a fully reversible, serial-free way to boot-test a
kernel from the running system. Everything below was proven on hardware
during the #49 bring-up (good kernel → boots slot B; bad kernel → dies,
watchdog fires, SPL auto-fails-over to slot A, device back on SSH in ~40s;
slot A never written).

**How slot selection actually works.** `TOP_CHIPMODE_GLB_BACKUP0`
(`0x02390024`, `_SET` +4 / `_CLR` +8) holds `SLOTA=BIT(2)`, `SLOTB=BIT(3)`,
`SLOTA_BOOTABLE=BIT(4)`, `SLOTB_BOOTABLE=BIT(5)`. The SPL's
`select_slot_ab()` (boot/bl1/core/boot/boot.c; the flashed p1 SPL was
disassembled and matches) treats the BOOTABLE bit as **consume-once**: a
slot bit whose BOOTABLE bit is clear means "that slot already failed once" →
fall back to the other slot. On every successful boot,
`/etc/init.d/S99checkboot start` re-arms the *current* slot's BOOTABLE bit
(steady state on slot A: `0x14`). The register survives warm reboot, raw
chip reset (`COMM_ABORT_CFG` = `0x023400A8` bit 0), and the whole boot chain
(verified with a canary bit).

**Procedure:**

1. Back up + write the test kernel to `kernel_b` = `/dev/mmcblk0p15`
   (`.#kernel-slot-image` packaging is hardware-proven; hash-verify with
   drop_caches as always). Never touch p14 (slot A).
2. Arm slot B **with the vendor script** — NOT a raw `SLOTB` poke, which
   leaves `SLOTB_BOOTABLE` clear and silently falls back to A:
   ```
   /etc/init.d/S99checkboot systemB     # sets SLOTB|SLOTB_BOOTABLE, clears SLOTA
   reboot
   ```
3. Verify over SSH (**no serial exists on this unit** — the console is
   hidden-pad UART0). Make the test kernel self-identifying (a config
   fingerprint in `/proc`, `uname -v`, …) and check `fw_printenv bootsystem`
   → `B` plus the fingerprint. Three outcomes:
   - fingerprint + `bootsystem=B` → slot B booted the test kernel;
   - SSH back but `bootsystem=A` → the test kernel died and failover worked
     (register shows the consumed pattern, e.g. `0x14`);
   - no SSH in ~4 min → power-cycle (never observed; failover handled every
     bad kernel tested).
4. A successful slot-B boot re-arms `SLOTB_BOOTABLE`, so the device *stays*
   on B across reboots. Return with `/etc/init.d/S99checkboot systemA` +
   `reboot`, and restore p15's content if you wrote a scratch kernel.

### Testing a MAINLINE kernel on slot B (proven 2026-09-06, #75)

The procedure above assumes a vendor-derived kernel that reaches a rootfs and
an SSH server. A mainline kernel does not — it has no storage driver until #76
— so two things change.

**Flash BOTH slots-B partitions.** A mainline kernel needs its own device tree:
`dtb_b` = `/dev/mmcblk0p13` as well as `kernel_b` = p15. Back up both first
(`dd` to `/root/`), and hash-verify each from the medium after `drop_caches`.
Read back with `head -c <exact image size> /dev/mmcblk0pN | md5sum` and take
the size from `stat -c%s` on the image you just built — the image size changes
between builds, and reusing a previous byte count silently compares the wrong
range.

**`bootsystem` cannot be the oracle.** Reaching a shell to read it means being
on slot A, and a kernel that re-armed `SLOTB_BOOTABLE` to prove it lived would
strand the board on a slot with no rootfs. So: do **not** re-arm. The SPL
consumed the bit on the way in, which means every exit path — clean reboot,
panic, hang, watchdog reset — returns the next boot to slot A on its own, and
the whole run is unattended.

The evidence comes back in memory instead. `.#kernel-mainline`'s bring-up
initramfs writes milestone bits 12–15 of `TOP_CHIPMODE_GLB_BACKUP0`, a verbatim
kernel log at `0x480e8000`, and a ramoops console zone at `0x480e0000` — all
three read from slot A afterwards, all three described in
[mainline-port.md](mainline-port.md#what-exists-now-75-2026-09-06--booted).

```
# clear stale milestone bits, arm slot B, go
devmem 0x0239002C 32 0xF000
/etc/init.d/S99checkboot systemB
reboot
# ~3 min later, back on slot A:
devmem 0x02390024                                   # expect 0x0000f014
dd if=/dev/mem bs=4096 skip=$((0x480e8000/4096)) count=8 | tail -c +33
dd if=/dev/mem bs=4096 skip=$((0x480e4000/4096)) count=4 | tail -c +13
```

`0xf014` is all four milestones plus slot A re-armed. Fewer bits set says how
far it got; no bits at all means it never reached userspace, and the ramoops
console zone is then the thing to read.

**Put slot B back when you are done.** Restore p13 and p15 from the backups and
hash-verify, so the board keeps a bootable rescue slot.

`kernel_b` (p15) currently holds the boot-proven current default kernel, so
slot B is a valid rescue/test slot at rest.

## Serial console

- **UART0 / `ttyS0` @ `0x4880000`** is the primary console, on hidden pads. **Both**
  the eMMC `firmware-image` and the microSD `sd-image` log here (the SD image
  matches the official card, which is also UART0). This is why a successful SD
  boot is silent on the exposed header pin — watch the network instead.
- **UART1 / `ttyS1` @ `0x4881000`** is the exposed header pin (U1) but nothing in
  the shipped images logs to it (an early attempt to redirect the SD chain here
  hung the SPL; see the SD-card boot section).
- The UART clock gives an unusual `base_baud` of 13000000. Boot stages other than
  the SD-SPL run at 115200-8N1 once the 208 MHz clock is up; the very early SD-SPL
  differs. A plain CH340-class adapter may not lock the non-standard early rate —
  an FT232 (which supports arbitrary bauds) is more reliable for the earliest
  logs. Serial is optional for normal use; it matters mainly when debugging the
  boot chain itself.
