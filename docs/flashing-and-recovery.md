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

## Backup and restore

**Do this before flashing eMMC the first time.** With SSH access to a
stock/working device, dump every partition so you can byte-restore later.

### The eMMC partition map

`/proc/partitions` and `ls /dev/disk/by-partlabel/` don't surface names on
this device (no partlabels are written) — the map below is the vendor layout,
recovered from the `blkdevparts=` string this project's DTB embeds
(`pkgs/dtb.nix`) and matching the signed-partition slot numbers used
throughout `pkgs/*.nix`:

| # | Name | # | Name | # | Name |
|---|---|---|---|---|---|
| 1 | `spl` | 7 | `env` | 13 | `dtb_b` |
| 2 | `ddrinit` | 8 | `logo` | 14 | `kernel` |
| 3 | `atf` | 9 | `logo_b` | 15 | `kernel_b` |
| 4 | `atf_b` | 10 | `optee` | 16 | `boot` |
| 5 | `uboot` | 11 | `optee_b` | 17 | `rootfs` |
| 6 | `uboot_b` | 12 | `dtb` | | |

Plus the two eMMC boot hardware areas, `mmcblk0boot0`/`mmcblk0boot1`, which
aren't GPT partitions at all — dump them separately, as below.

```bash
# On the device: list the eMMC partitions and their names.
cat /proc/partitions
ls -l /dev/disk/by-partlabel/ 2>/dev/null   # or parse the GPT

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
`p17` (`rootfs`) is the large one — ~30 GB, gzipped ~1.8 GB — back it up
separately with streaming gzip as the loop above already does; budget the
time/disk for it. To restore a single partition later, `dd` the raw image back
onto the same `/dev/mmcblk0pN`; to fully recover, re-flash a stock `.axp` over
AXDL (above).

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
