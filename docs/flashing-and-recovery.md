# Flashing & recovery

How to get a built image onto a NanoKVM-Pro, how to try changes without touching
eMMC, and how to get back to a known-good state. Read
[backup-and-restore](#backup-and-restore) **before** your first eMMC flash.

- [The `User` button](#the-user-button)
- [AXDL USB flashing (eMMC)](#axdl-usb-flashing-emmc)
- [Backup and restore](#backup-and-restore)
- [SD-card boot (non-destructive)](#sd-card-boot)
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

```bash
# On the device: list the eMMC partitions and their names.
cat /proc/partitions
ls -l /dev/disk/by-partlabel/ 2>/dev/null   # or parse the GPT

# Pull each partition + the boot areas. Example (adjust to the real table):
for p in /dev/mmcblk0p*; do
  n=$(basename "$p")
  ssh root@<device> "cat $p" | gzip > "backup/${n}.img.gz"
done
ssh root@<device> "cat /dev/mmcblk0boot0" > backup/mmcblk0boot0.img
ssh root@<device> "cat /dev/mmcblk0boot1" > backup/mmcblk0boot1.img
ssh root@<device> "cat /proc/cmdline"     > backup/cmdline.txt
```

Verify sizes look sane and the rootfs image gunzips + `debugfs`-stats cleanly.
The rootfs is the large one (`…p17`, gzipped ~1.8 GB). To restore a single
partition later, `dd` the raw image back onto the same `/dev/mmcblk0pN`; to fully
recover, re-flash a stock `.axp` over AXDL (above).

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

**How SD boot works (from the SDK source):** the BootROM's SD path is
*file-based*, not raw-offset. It reads an MBR table, mounts the first **FAT32**
partition, and loads **`boot.bin`** (the `boot/bl1/sd` SPL variant, which links
FatFS + the SD mmc driver). That SPL then loads each later stage as a *named file*
from the same FAT partition (`ddrinit.img`, `atf.img`, `uboot.bin`, `optee.img`,
`dtb.img`, `kernel.img`); the rootfs is MBR p2 (ext4). The `sd-image` derivation
builds this MBR/FAT32+ext4 layout with **no root** (mtools + `sfdisk` + the raw
ext4 from `rootfs.nix`).

Two SD-specific build details, both handled in the flake:

- **Console on UART1.** `sd-image` uses the `boot-sd` / `dtb-sd` variants that
  redirect every boot stage + the kernel console to `ttyS1` (`0x4881000`, the
  exposed header pin), so an SD boot is watchable on serial. The eMMC
  `firmware-image` stays on `ttyS0`.
- **SD-SPL size.** The FatFS-linked SD SPL overflowed the sign tool's hard
  **50 K** slot under newer GCC; `boot.nix` builds it with
  `-ffunction-sections -fdata-sections --gc-sections` (drops it well under the
  limit) with a build-time guard if it ever creeps back over 51200 B.

> **Caveat:** SD boot needs the button hold — it is *not* auto-on-insert (HIGH
> confidence, [Sipeed wiki](https://wiki.sipeed.com/hardware/en/kvm/NanoKVM_Pro/faq.html)).
> This is a manually-triggered test/recovery path, not an appliance boot.

---

## First boot & the web UI

On a clean boot our image auto-starts `nanokvm.service` (see
[architecture.md](architecture.md#the-two-app-stacks-nanokvm-vs-kvmcomm)). Once up:

- Open **`https://<device-ip>/`** and complete account setup / set a password.
- SSH is available as `root` (default password `sipeed` on the from-source image
  until you change it).
- The on-device **mini-display is intentionally off**: it was driven by the
  vendor's closed-source `kvm_ui` binary, which we don't ship. The panel itself is
  a standard `/dev/fb0` framebuffer and could be reclaimed by open code later —
  see [architecture.md](architecture.md#the-built-in-mini-display).

If the web UI is unreachable but the device pings, check the service:

```bash
ssh root@<device> 'systemctl status nanokvm; ss -tlnp | grep -E ":(80|443)"; \
  tail -20 /var/log/nanokvm/NanoKVM-Server.log'
```

---

## Serial console

- **UART1 / `ttyS1` @ `0x4881000`** is the exposed header pin (U1) and is what the
  `sd-image` boot chain logs to.
- **UART0 / `ttyS0` @ `0x4880000`** is the primary console but on hidden pads; it's
  what the eMMC `firmware-image` uses.
- The UART clock gives an unusual `base_baud` of 13000000. Boot stages other than
  the SD-SPL run at 115200-8N1 once the 208 MHz clock is up; the very early SD-SPL
  differs. A plain CH340-class adapter may not lock the non-standard early rate —
  an FT232 (which supports arbitrary bauds) is more reliable for the earliest
  logs. Serial is optional for normal use; it matters mainly when debugging the
  boot chain itself.
