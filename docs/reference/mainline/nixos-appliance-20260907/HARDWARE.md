# The NixOS appliance on hardware — #78, 2026-09-07

Six slot-B boots. The last one is the result: **a NixOS 26.11 system on mainline
Linux 7.1.3, booting the AX630C from an image file on the vendor rootfs, with
the device's own MAC, its own DHCP lease, its own derived hostname, zero failed
units and NanoKVM-Server serving HTTPS.** Nothing on the eMMC was overwritten;
slot A, the boot chain and `p16` were never written.

```
Linux kvm-<derived> 7.1.3-nanokvm  aarch64
/                 /dev/loop0 ext4 rw,noatime  ->  /nanokvm-host/nixos-root.img
end0              <redacted-mac>  1Gbps full  <device-ip>/21
DHCPv4 Client ID  <redacted-mac>
BACKUP0           0x0E000018      bits 25/26/27 + slot B
0 failed units    boot 26.3 s     https 200
```

Evidence: `run4-hw/` and `run6-hw/` (state sweep, dmesg, journal — redacted, see
the parent README). Procedure: `.claude/skills/mainline-boot-test/SKILL.md`,
"Variant: booting the NixOS appliance from slot B".

## The runs

| # | Image | Outcome |
|---|---|---|
| 1 | both identity fixes absent | booted, reached the LAN at a NEW address as `nanokvm`; rebooted by hand |
| 2 | both fixes present | **went dark and stranded the board** — needed a power cycle |
| 3 | fixes absent, exit machinery added | booted, reached the LAN; **deadman fired** and returned to slot A unprompted |
| 3b | same, deadman made monotonic | lost the mmc enumeration race; **stage-1 `panicOnFail` fired**, back on slot A in 37 s |
| 4 | both fixes present | booted at `<device-ip>`, the usual address; **deadman fired at its full 900 s dwell** |
| 5 | + empty `networking.hostName` | lost the enumeration race again; panicked back to slot A in 60 s |
| 6 | + `mmc` aliases in the DT | **everything correct**, and the run quoted above |

## What run 2 actually was

Not the identity fixes. Run 4 carries both and comes up on the address the unit
has always had. Run 2 lost a race that runs 3b and 5 then reproduced twice:

**The eMMC is not reliably `mmcblk0`, and when it loses it has no partitions at
all.** The AX630C has three SD4HC instances that probe concurrently. The eMMC's
layout comes from the `blkdevparts=mmcblk0:...` clause of the U-Boot command
line — there is no on-disk partition table — and that clause binds the table to
a device **name**. When the eMMC enumerates as `mmc1`/`mmcblk1`, the table is
applied to `mmcblk0`, which is the empty SD slot, and the eMMC comes up with
zero partitions:

```
run 5:  mmc1: new HS200 MMC card at address 0001
        mmcblk1: mmc1:0001 AT3SFB 29.1 GiB          <- no pN children at all
        nanokvm: no mmcblk*p17 appeared -- no carrier

run 6:  mmc0: new HS200 MMC card at address 0001
        mmcblk0: mmc0:0001 AT3SFB 29.1 GiB
         mmcblk0: p1(spl) p2(ddrinit) ... p16(boot) p17(rootfs)
```

Two of five boots lost it. #76 and #77 never saw it because they happened to
win, and the #75 bring-up init located its partition by name out of
`/proc/partitions` rather than assuming a number — which hid the deeper problem,
because *nothing* is named when the race is lost.

The fix is three lines of device tree: `aliases { mmc0 = &emmc; mmc1 = &sd;
mmc2 = &sdio; }`. `mmc_of_parse()` takes the alias id as the host index, so the
eMMC is always `mmc0`, and the cmdline table always lands on it. This affects
every mainline boot of this board, not just #78's.

Run 2 then went dark rather than recovering because stage 1 had no way out: the
NixOS stage-1 `fail()` is interactive — it blocks in `read -n 1 reply` on a
console whose pads nobody can reach — and the kernel pets the watchdog U-Boot
armed for as long as userspace does not open `/dev/watchdog`. With
`panicOnFail=1` the same failure now panics, and `CONFIG_PANIC_TIMEOUT=5`
restarts onto slot A. Measured twice: 37 s and 60 s from power to a vendor login.

## The exit machinery, both halves proven

A slot-B *appliance* is not a bring-up initramfs. The #75 `/init` always ended in
`reboot(2)`, so every path out of it landed on slot A within the dwell; an
appliance is supposed to stay up. `nixos/loop-test.nix` gives it two ways back,
and hardware exercised both:

- **Stage 1 — `panicOnFail=1`.** Runs 3b and 5: mount fails, PID 1 exits, kernel
  panics, board is on slot A about a minute later, no human involved.
- **Userspace — a 900 s deadman.** Run 4: last seen at uptime 877 s, unreachable
  at 914 s, back on slot A 40 s after that. Extendable one hour at a time with
  `touch /run/keepalive`, #77's one-way idiom.

Nothing in the image re-arms `SLOTB_BOOTABLE` (`nanokvm.checkboot.enable =
false` on this variant), so every one of those exits lands on slot A by itself.

The deadman needed a hardware run to get right. Its first version used
`date +%s`, and the image boots with its clock at the build epoch — timesyncd
then jumps it months forward the moment DHCP lands ("Initial clock
synchronization to ... 22:22:44 UTC" in run 3's journal), so the deadline was
instantly in the past and it fired at 62 s. It is `/proc/uptime` now. That bug
was lucky: a safety net that fires early still proves the net.

## Identity, proven end to end

Every value below agreed, on silicon, in run 6:

```
/proc/ax_proc/uid    ax_uid: 0x<uid-hi><uid-lo>    the vendor kernel's node
devmem 0x788 / 0x78c <uid-lo> / <uid-hi>           THE SAME two words, both kernels
devmem 0x780 / 0x784 0x00000005 / 0x00000004       board_id / chip_type = AX630C_CHIP
/device_key          <uid-hi><uid-lo>              byte-identical to the vendor's (`cmp`)
sha512sum            <uid-hash>, first 4 chars -> the MAC's low two octets
MAC                  48:da:35:xx:xx:xx  == the vendor rootfs's `hwaddress ether`
hostname             kvm-<derived>      == sha prefix
address              <device-ip>        == the lease this unit has always had
```

Three things had to be right at once, and each was wrong on its own run:

1. **`hostnamectl --transient`.** The plain call sets the *static* hostname,
   which means writing `/etc/hostname` — a read-only store symlink. Run 1:
   `Could not set static hostname: /etc/hostname is in a read-only filesystem.`
2. **`networking.hostName = ""`.** With a static hostname present,
   systemd-hostnamed refuses the transient one outright — run 4:
   `Hint: static hostname is already set, so the specified transient hostname
   will not be used.` The `--transient` fix alone only turned an error into a
   polite refusal; all of runs 1–5 came up as `nanokvm`.
3. **`dhcpV4Config.ClientIdentifier = "mac"`.** The same MAC is not enough to
   get the same lease: systemd-networkd defaults to a DUID in DHCP option 61,
   which the server reads as a new client. The vendor's udhcpc sends the MAC.
   Runs 1 and 3 took a new address; runs 4 and 6 took the usual one.

## Also confirmed on this hardware

- **`/etc/fw_env.config` works**, and by use rather than by hexdump:
  `fw_printenv` on the appliance read `bootsystem=B` (uppercase, the form
  `nanokvm-checkboot` accepts) out of the live U-Boot environment at the offset
  `nixos/emmc-partitions.nix` computed from the `blkdevparts=` clause.
- **The milestone channel survives the reboot.** `0x0E000018` live on slot B,
  `0x0E000014` read back from slot A. The arming clear-mask is **`0xFFFF000`** —
  `0x7FFF000` misses bit 27 and leaves it stale, which cost one confusing read.
- **#81's `nanokvm-gpio` runs on hardware**, resolving all four ATX lines by
  device-tree name across four gpiochips (read-only; no line was driven,
  because pressing `atx-power` presses a button on someone's machine). The
  LT6911UXC `/proc` ABI is complete, `chip_id` = `lt6911uxc`.
- Boot is **26.3 s** (7.1 s kernel + 19.1 s userspace), zero failed units.

## Not proven

Video (#83), USB gadget policy (#82), the mini-display (#84). Root on the eMMC
`p17` partition itself — every run here used the loop-image root, which is what
kept them reversible. And the `mmc` alias fix has one successful boot behind it,
not a series; it is correct by construction, but the race it closes was only
ever visible statistically.
