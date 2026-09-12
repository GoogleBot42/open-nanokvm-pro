# Flashing & recovery

There is one image — the mainline NixOS appliance — and one way to write it:
AXDL over USB. Everything else on this page is how to try a change *without*
writing flash, and how to get a board back when a change goes wrong.

- [The `User` button](#the-user-button)
- [AXDL USB flashing](#axdl-usb-flashing)
- [First boot](#first-boot)
- [Testing a kernel or a whole system](#testing-a-kernel-or-a-whole-system)
- [Testing a U-Boot candidate](#testing-a-u-boot-candidate)
- [Rollback](#rollback)
- [The eMMC map](#the-emmc-map)
- [Backup and verification](#backup-and-verification)
- [Hardware tripwires](#hardware-tripwires)
- [Serial console](#serial-console)

---

## The `User` button

The AX630C latches its boot source from the `CHIP_MODE` strap at reset, and on
the NanoKVM-Pro that strap is the `User` button.

| Action | Result |
|---|---|
| Power on **normally** | Boot **eMMC** — the installed firmware. Always, regardless of SD presence. |
| Hold `User` **while applying power**, release right after | Boot the **SD card**, if a valid one is present. |
| Hold `User` **~10 s** | Enter **USB download mode** (AXDL), the mask-ROM flasher. |

All three are manual: there is no unattended "insert a card to boot", and eMMC
is never written unless you flash it. Download mode lives in mask ROM, so it
cannot be bricked by a bad eMMC image — every recovery on this board is another
AXDL flash, a bench trip and never a brick. Keep a stock Sipeed `.axp` on hand
as the ultimate fallback.

The SD path is hardware and still works, but **this repo builds no SD image**:
`.#sd-image` was the vendor-layout one and went out with #97. Building one for
the appliance is #7/#9.

> **No U-Boot autoboot interrupt window.** `bootdelay=0`, so there is no
> countdown to break into, even with a working serial console. A bad boot-chain
> flash cannot be caught at a U-Boot prompt.

---

## AXDL USB flashing

AXDL is Axera's USB download protocol. This flake packages the open
[`ciniml/axdl-rs`](https://github.com/ciniml/axdl-rs) flasher as `.#axdl`.

```bash
# 1. Build. This is also `packages.default`, so a bare `nix build` does it.
nix build .#nixos-firmware-image-mainline
ls result/     # AX630C_emmc_arm64_k419_sipeed_nanokvm-nixos_mainline.axp

# 2. Put the device in download mode: hold `User` ~10 s while powering on.
#    It enumerates as USB VID:PID 32c9:1000, on the USB-C data port that maps
#    to the SoC USB (on the Desk, the HID/OTG port).

# 3. Flash. --wait-for-device blocks until the device appears.
nix run .#axdl -- --file result/*.axp --wait-for-device
```

The same command flashes any `.axp`, including a stock Sipeed bundle from the
[NanoKVM-Pro releases](https://github.com/sipeed/NanoKVM-Pro/releases) if you
ever want the factory firmware back.

### What the image is

Packed from scratch by `nixos/axp-image.nix` + `nixos/lib/make-axp-image.nix`.
There is no vendor bundle behind it, and the packer fails the build if a store
path from one appears. Five stored partitions, all from this flake: the SPL
(`.#spl-minimal`, blob-free since #90), mainline TF-A BL31, mainline U-Boot, the
U-Boot environment, the `/boot` ext4 tree and the NixOS rootfs. Two members ride
along without ever being stored on the eMMC — FDL1 and FDL2, the download agents
the flasher pushes into BootROM RAM, both built by `pkgs/boot.nix`.

**It writes the `env` partition.** Any `fw_setenv` state on the board is gone
after a flash. That is the intent: a known environment, not an inherited one.

**Do not use `--exclude-rootfs`.** It would leave whatever rootfs is on the
device under a new kernel and a new `/boot`, which boots nothing.

---

## First boot

Stage 1 fsck's the root partition and `switch_root`s; systemd then grows the
filesystem to fill it. Userspace derives the board's identity from the SoC UID,
so:

- the MAC is derived from the SoC UID, so a unit keeps the MAC it has always
  had across a reflash,
- `ClientIdentifier=mac` gets it the **same DHCP lease**, so `tools/kvmssh`
  reaches it at the address it already knows,
- the hostname is `kvm-XXXX`, from `sha512sum /device_key`,
- sshd accepts root with password auth, and root's password is `sipeed`
  (`users.users.root.initialPassword`) — change it on first boot,
- the web UI answers on `:80` and `:443` with a self-signed cert generated on
  first boot.

**A mainline boot is 71 seconds to SSH** (#91, fixed 2026-09-10). Longer means
U-Boot needed more than one attempt; `journalctl -u nanokvm-mark-good` prints
`bootcount`, and anything above 1 is worth investigating rather than shrugging
at. **Still poll 30 minutes before calling a board dark** — a candidate that
hangs costs a 300 s watchdog cycle, and ten minutes of silence is what made #94
look like a bad flash.

---

## Testing a kernel or a whole system

Do not flash to test. The kernel, the modules, the server, the web UI and the
whole system are one thing here — a NixOS generation — and the kernel, initrd
and dtb belong to the generation since #99. So build it, copy it, install it,
reboot:

```bash
nix build .#appliance-toplevel
nix copy --to ssh://root@<device> ./result
tools/kvmssh 'nanokvm-update install-toplevel /nix/store/<...>-nixos-system-…'
tools/kvmssh reboot
```

`install-toplevel` makes that path the next generation and writes
`/boot/extlinux/extlinux.conf`, leaving the previous generation named by the
fallback config. A generation that does not come up is undone by the rollback
below, unattended — including one with a new kernel. Stage 1 is armed to panic
rather than block (`boot.panic_on_fail` and `stage1panic=1` on the command line,
with `preDeviceCommands` setting the variable directly because upstream's parser
matches those words whole), so a root filesystem that never appears is a reset,
and therefore a counted boot attempt.

`nixos-rebuild switch --flake .#nanokvm-pro --target-host root@<device>` works
too, for a change you do not intend to keep across a reboot.

---

## Testing a U-Boot candidate

**Never by writing the `uboot` partition.** There is one copy and no B twin.

`nanokvm-uboot-test` stages a candidate on `/boot` and arms a one-shot token in
the head of the unused `env` partition. `bootchain` **spends the token before it
jumps**, so a candidate runs exactly once even if it hangs at its first
instruction — WDT0 resets, and the boot after it runs the production U-Boot from
flash. Hardware-proven both ways, 2026-09-10.

```bash
# On the board. Stage the RAW image (images/u-boot.bin, device tree appended),
# NOT the signed container -- the tool checks _TEXT_BASE at offset 8 and
# refuses anything that is not 0x5C000400.
nanokvm-uboot-test stage /tmp/u-boot.bin
reboot
# After it comes back:
nanokvm-uboot-test status
```

**Read the oracle before any power cycle.** A chip reset keeps these; power loss
does not.

| Address | Meaning |
|---|---|
| `0x480EE000` | `0x43484C44` (`CHLD`) — this boot chainloaded; `+4` is the address it jumped to |
| `0x480EE008` | `chainstat`: `1` the gate opened and the load was tried, `2` all three loads failed, `3` the load succeeded and `chainload` ran |
| `0x480EE00C` | what U-Boot thought `bootcount` was |
| `0x02390030` | `bootcount` at the health gate — this is what separates "the candidate booted" from "it hung and the slot recovered" |
| `0x480E8000` | the pre-console ring |

Milestone bit 28 is **not** a post-hoc oracle: the recovery attempt's own
`preboot` sets it too.

`nanokvm-uboot-test clear` removes the file and the token, and the appliance
clears the slot on the boot after a staged attempt, so it is strictly one-shot
whichever way the attempt went.

A magic compared as a word must be written as that word: the token is four ASCII
bytes `43 48 54 4B`, and U-Boot's `itest.l` is a native `*(u32 *)`, so the
constant is `0x4B544843`. Spelled the way a hexdump reads it, the gate builds,
boots and silently never opens.

---

## Rollback

U-Boot counts boot attempts in `TOP_CHIPMODE_GLB_BACKUP1`, a register that
survives a warm reboot and a chip reset.

```bash
devmem 0x02390030 32
# 0xB0010000  healthy
# 0xB001000N  N attempts since the last healthy boot
```

`bootlimit` is 3, so the **fourth** attempt runs `altbootcmd`: it sets milestone
bit 30 and boots `/boot/extlinux/extlinux-fallback.conf` instead of
`extlinux.conf`. The two files name two generations through a pinned `init=`.
`nanokvm-mark-good` (timer, `OnBootSec=60s`) clears the counter and regenerates
the fallback from `/run/booted-system` once the system is `running`, routed and
serving.

To exercise it by hand — **this is the way to test the rollback, not a broken
generation**:

```bash
devmem 0x02390030 32 0xB001000A
reboot
```

That proves `bootcount_error()`, `altbootcmd`, bit 30 and the fallback config in
one boot, and it cannot strand the board. Hardware-proven unattended 2026-09-09.
Details: [nixos-rootfs.md §4b](nixos-rootfs.md#4b-rollback--two-config-files-a-register-and-a-health-gate).

**The boot chain has no rollback.** One `spl`, one `atf`, one `uboot`. A U-Boot
candidate goes through the chainload slot; a bad SPL is an AXDL trip.

---

## #95: the raw boot chain — DONE, on hardware 2026-09-12

**The boot chain stores every stage uncompressed.** `.#spl-minimal` is compiled
`SUPPPORT_GZIPD=FALSE`, so it reads `atf` and `uboot` straight from flash to
their load addresses instead of through the SoC's gzipd hardware, and
`.#atf-mainline` / `.#uboot-mainline` store their payloads raw behind the same
1 KiB signed header. That retired `ax_gzip`, the last prebuilt x86-64 host tool
in this build. `.#nixos-firmware-image-mainline` carries the same trio, so the
AXDL recovery image and the board's chain are the same chain again.

**The three are one artefact.** The container carries no "compressed" flag, so
each SPL reads only the format it was compiled for and neither mismatch is
detected: a raw SPL reading a gzipped image passes the checksum (it is taken
over the stored bytes) and jumps into axgzip data; a gzipped SPL reading a raw
image fails and spins. Both are a dark board.
[mainline-port.md §11.12](mainline-port.md#1112-95-the-stages-go-raw-and-ax_gzip-is-retired-on-hardware-2026-09-12)
has the citations. **Never change one of `pkgs/spl-minimal.nix`,
`pkgs/atf-mainline.nix` and `pkgs/uboot-mainline.nix` without the other two.**

### How it was written, and how to write it again

The `spl` region has no A/B twin and no chainload slot, so this is a one-way
write with AXDL as the only way back. It was done from the running appliance,
and the procedure below is the one that worked.

```bash
# ---- build, on the dev box -------------------------------------------------
nix build .#spl-minimal .#atf-mainline .#uboot-mainline
nix build .#checks.x86_64-linux.no-x86-blobs \
          .#checks.x86_64-linux.atf-mainline \
          .#checks.x86_64-linux.uboot-mainline

# ---- confirm the numbering ON THE BOARD, never from this table -------------
tools/kvmssh 'lsblk /dev/loop0; blkid; ls -l /dev/disk/by-partlabel/'
#   p1 = atf (1 MiB)   p2 = uboot (2 MiB)   p3 = env   p4 = boot   p5 = rootfs

# ---- save what is there ----------------------------------------------------
tools/kvmssh 'mkdir -p /root/pre95
  dd if=/dev/mmcblk0 of=/root/pre95/spl.bin bs=1K count=768
  dd if=/dev/disk/by-partlabel/atf   of=/root/pre95/atf.bin
  dd if=/dev/disk/by-partlabel/uboot of=/root/pre95/uboot.bin
  sync; echo 3 > /proc/sys/vm/drop_caches
  md5sum /root/pre95/*.bin | tee /root/pre95/MD5'
```

Copy `/root/pre95/` off the board as well (`tools/kvmssh 'cat …' > file`;
`kvmscp` is push-only): it lives on `rootfs`, which an AXDL recovery
overwrites. **Verify the backup against a build before trusting it** — the
2026-09-12 run confirmed all three regions were byte-identical to what the tree
then built, which is what made the rollback reproducible from source rather
than dependent on the dump.

```bash
# ---- push and write --------------------------------------------------------
tools/kvmscp result-atf/images/atf_bl31_mainline_signed.bin  /root/pre95/new/
tools/kvmscp result-ub/images/u-boot_mainline_signed.bin     /root/pre95/new/
tools/kvmscp result-spl/images/spl_*_signed.bin              /root/pre95/new/
tools/kvmssh 'sync; echo 3 > /proc/sys/vm/drop_caches; md5sum /root/pre95/new/*'

tools/kvmssh '
  set -e
  dd if=/root/pre95/new/atf_bl31_mainline_signed.bin of=/dev/loop0p1 conv=fsync
  dd if=/root/pre95/new/u-boot_mainline_signed.bin   of=/dev/loop0p2 conv=fsync
  dd if=/root/pre95/new/spl_*_signed.bin of=/dev/mmcblk0 bs=512 conv=fsync
  sync; echo 3 > /proc/sys/vm/drop_caches'
```

`spl` goes **last**, the same order the `.axp` uses: an interrupted write then
leaves a board that falls into AXDL rather than one whose loader runs with
nothing behind it.

### Verify from the medium, then reboot

```bash
tools/kvmssh 'echo 3 > /proc/sys/vm/drop_caches
  for p in "spl /dev/mmcblk0 spl_*_signed.bin" \
           "atf /dev/loop0p1 atf_bl31_mainline_signed.bin" \
           "uboot /dev/loop0p2 u-boot_mainline_signed.bin"; do
    set -- $p; f=/root/pre95/new/$3
    n=$(stat -c%s $f)
    echo "$1 $(head -c $n "$2" | md5sum | cut -d" " -f1) $(md5sum $f | cut -d" " -f1)"
  done'
```

Both hashes on a line must match. Then, and only then, `reboot`.

### Oracles

| What | Where | Expected |
|---|---|---|
| it booted | SSH | back within **90 s**; poll 30 minutes before calling it dark |
| how many attempts | `journalctl -u nanokvm-mark-good`, or `devmem 0x02390030 32` | `0xB0010001` at the gate, `0xB0010000` after — one attempt |
| how far the chain got | `devmem 0x02390024 32` | bits 28+29 (`0x30000000`). **Bits 2-5 are the SPL's own A/B slot bookkeeping**, rewritten by `select_slot_ab()` every boot, so the low nibble changes between boots and means nothing |
| what U-Boot printed | the pre-console ring at `0x480E8000` | only if something went wrong |

What the 2026-09-12 run measured: SSH answered with the board at **47 s**
uptime, one attempt, `is-system-running` = `running`, `systemctl --failed`
empty, web 200, `psci: PSCIv1.1 detected in firmware`, and all three regions
still md5-correct read back off the eMMC.

A first-stage failure prints nothing and reaches nothing: no milestone bits, no
`bootcount`, no ring. **Dark plus a flat ~3.3 W is the signature**, and the only
answer is AXDL:

```bash
nix build .#nixos-firmware-image-mainline
nix run .#axdl -- --file result/*.axp --wait-for-device
```

Hold `User` ~10 s at power-on to enter AXDL.

### Rolling the board back

The gzip chain is no longer buildable from this tree, so the `/root/pre95/`
dumps are the only copy of it. Restoring them is the same three writes in the
same order:

```bash
dd if=/root/pre95/atf.bin   of=/dev/loop0p1  conv=fsync
dd if=/root/pre95/uboot.bin of=/dev/loop0p2  conv=fsync
dd if=/root/pre95/spl.bin   of=/dev/mmcblk0  bs=512 conv=fsync
```

In practice there is nothing to roll back to: the current chain is what every
image builds and what the board has booted.


---

## The eMMC map

The eMMC is two logical devices. `spl` is the first 768 KiB — the BootROM's
image, deliberately outside every partition table, because the ROM reads byte 0
of the user area. `disk` is everything after it, and it carries an ordinary,
spec-conformant GPT at **its own** LBA 0: protective MBR at physical LBA 1536,
header at 1537, array at 1538–1569, alternate header in the device's last
sector.

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

Linux is told only `blkdevparts=mmcblk0:768K(spl),-(disk)`; stage 1 then does
`losetup -P /dev/loop0 /dev/mmcblk0p2` and the in-kernel EFI parser creates
`/dev/loop0p1..5`, so root is `/dev/loop0p5` and `/boot` is `/dev/loop0p4`.
U-Boot reads the same table through `CONFIG_EFI_PARTITION_BASE_LBA=1536`
(patch `0023`).

To read the table by hand, from the board or from a dumped image:

```bash
losetup -r -o 786432 -P /dev/loop9 /dev/mmcblk0
sgdisk -p /dev/loop9        # or: lsblk /dev/loop9; blkid /dev/loop9p5
losetup -d /dev/loop9
```

**The layout and the first-stage loader are one artefact.** `.#spl-minimal` is
compiled for these byte offsets, so changing the map means rebuilding the SPL
and flashing it — and a bad SPL is a bench trip. `rootfs` is pinned at
`0x115C0000` by an assertion in `nixos/lib/emmc-layout.nix`, the single
definition every consumer is derived from;
`nix build .#checks.x86_64-linux.emmc-partition-map` prints the map with
offsets.

Plus the two eMMC boot hardware areas, `mmcblk0boot0`/`mmcblk0boot1` — 4 MiB
each, blank on this board, and not reachable as a boot source without changing
the `chip_mode` strap.

---

## Backup and verification

```bash
# The two raw eMMC devices the kernel command line creates, plus the boot areas.
tools/kvmssh 'cat /dev/mmcblk0p1' | gzip > backup/spl.img.gz
tools/kvmssh 'cat /dev/mmcblk0p2' | gzip > backup/disk.img.gz
tools/kvmssh 'cat /dev/mmcblk0boot0' > backup/mmcblk0boot0.img
tools/kvmssh 'cat /dev/mmcblk0boot1' > backup/mmcblk0boot1.img
tools/kvmssh 'cat /proc/cmdline'     > backup/cmdline.txt
```

`disk` is the large one — ~29 GB raw; budget the time and the disk. To restore
one partition, `dd` its image back at the same offset. To recover fully,
re-flash over AXDL.

**Hash-verify every firmware or block-device write, and drop the device's page
cache before the read-back** — otherwise you verify the page cache, not the
medium.

```bash
tools/kvmssh 'echo 3 > /proc/sys/vm/drop_caches'
size=$(stat -c%s image.bin)
tools/kvmssh "head -c $size /dev/<target> | sha256sum"
sha256sum image.bin
```

Take the byte count from `stat` on the image you just built. Reusing a previous
build's size silently compares the wrong range.

The signed boot-chain images (`spl`, `atf`, `uboot`) carry a 1 KB header with
magic `0x55543322` at offset 4, little-endian, so a well-formed dump shows:

```bash
xxd -s 4 -l 4 backup/atf.img
# 00000004: 2233 5455                                ".3TU"
```

If that does not match, the dump is truncated or it is the wrong range.

---

## Hardware tripwires

- **eMMC is `/dev/mmcblk0`; the SD card is `/dev/mmcblk1`.** Never write
  `mmcblk0` during SD-card work.
- **Power is agent-controllable** through the zigbee plug named
  `nanokvm switch` (the `power-switch` skill). **Leave it off at least 15 s** —
  an 8-second cycle came back into the same dark state the cycle was meant to
  clear. SSH is back ~90 s after `on`.
- **A flat ~3.3 W with no open port is the hang signature**, but a healthy idle
  board draws the same. Only SSH tells you anything.
- **Read the slot register, the chainload record, the console ring and pstore
  BEFORE cycling power.** A chip reset keeps them; power loss does not.
- **`/sys/fs/pstore` is empty on a healthy boot.** `systemd-pstore` archives
  every record into `/var/lib/systemd/pstore/` and unlinks it ~10 s in. Read the
  archive; an empty `/sys/fs/pstore` proves nothing about the previous kernel.
- **Dump only what you have proven clocked.** Reading a block whose clock is off
  hangs the AXI bus and costs a watchdog reboot — a U-Boot dump of the cardless
  SD slot at `0x104E0000` cost a power cycle.

---

## Serial console

- **UART0 / `ttyS0` @ `0x4880000`** is the console, and it is on **hidden pads**.
  This unit has no serial. Every boot has to be judged over the network.
- **UART1 / `ttyS1` @ `0x4881000`** is the exposed header pin, and nothing logs
  to it.
- The UART clock gives an unusual `base_baud` of 13000000; stages run 115200
  8N1. An FT232 handles arbitrary bauds more reliably than a CH340-class
  adapter.

Because there is no console, a serial-less boot is made observable by other
means: milestone bits of `0x02390024`, ramoops, the pre-console ring at
`0x480E8000` and a verbatim kernel-log copy in the tail of the pstore window.
[mainline-port.md](mainline-port.md) §8 documents that channel and its two traps
— the vendor kernel zaps every pstore zone it owns ~1.5 s into a boot, and
`/dev/kmsg` writes are ratelimited to ten records per five seconds unless
`printk_devkmsg` is `on`.
