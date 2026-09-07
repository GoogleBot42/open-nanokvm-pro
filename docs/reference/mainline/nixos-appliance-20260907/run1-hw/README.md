# Run 1 on hardware — the NixOS appliance on the AX630C, 2026-09-07

**A NixOS 26.11 system on mainline Linux 7.1.3 booted this board from slot B,
reached `multi-user.target` with zero failed units in 20.05 s, and served
NanoKVM-Server over HTTPS.** Root was an ext4 image FILE on the vendor rootfs,
loop-mounted by NixOS stage 1 — nothing on the eMMC was overwritten.

Procedure: `.claude/skills/mainline-boot-test/SKILL.md`, "Variant: booting the
NixOS appliance from slot B". Artifacts: `.#nixos-appliance-loop` and
`.#kernel-mainline-appliance-loop-slot-image`, both merged with #81 and #82.

## The files

| File | What it is |
|---|---|
| `state.txt` | The state sweep: root filesystem, identity, `fw_printenv`, slot register, watchdog, GPIO, the LT6911 `/proc` ABI, units, boot time, HTTPS. |
| `dmesg.txt` | Kernel log of the run, taken live over SSH from the appliance. |
| `journal.txt` | `journalctl -b -o short-monotonic`, the whole userspace boot. |

## What it establishes

**The boot contract works.** The NixOS stage-1 initrd embedded in the kernel
Image mounted the carrier, attached the image file, `switch_root`ed to `/init`
on it — with no `init=` on a command line we do not control — and systemd came
up. `findmnt /` reads `/dev/loop0 ext4 rw,noatime`, `losetup -a` reads
`/dev/loop0: [45841]:471 (/nanokvm-host/nixos-root.img)`, and the carrier is
bind-mounted at `/vendor-root`.

**The identity derivation is proven on silicon, end to end.** The values are
redacted (see "Redaction"), which costs the proof nothing: every claim below is
an *equality between two readings*, and an equality survives redacting both
sides. Read from the vendor kernel before the test, and again from the appliance
during it:

```
/proc/ax_proc/uid          ax_uid: 0x<uid-hi><uid-lo>   the vendor kernel's own node
devmem 0x788 / 0x78c       <uid-lo> / <uid-hi>          THE SAME two words, both kernels
devmem 0x780 / 0x784       0x00000005 / 0x00000004      board_id / chip_type
/device_key                <uid-hi><uid-lo>             written by the appliance;
                                                        `cmp` says byte-identical to
                                                        the one the vendor /init wrote
sha512sum /device_key      <uid-hash>  -- its first four hex chars are the MAC's
                                          low two octets, as the vendor derives them
derived MAC                48:da:35:xx:xx:xx            (the Sipeed OUI is public)
/vendor-root/etc/network/interfaces   hwaddress ether <the same MAC>
end0                       <the same MAC>   1Gbps full duplex
```

So: the two words the appliance pulled out of `misc_info` through `/dev/mem` on
the mainline kernel are the same two words the vendor kernel prints from
`/proc/ax_proc/uid`; the `/device_key` it wrote is byte-identical to the vendor's;
and the MAC it derived is byte-identical to the `hwaddress ether` line sitting in
the vendor rootfs it was booted beside.

`chip_type` reading `0x4` is `AX630C_CHIP` in the vendor's own enum, which
confirms the whole `misc_info_t` layout rather than just the two words that
were wanted — `pub_key_hash[8]`, `aes_key[8]`, `board_id`, `chip_type`,
`uid_l`, `uid_h`. **IRAM0 is at physical 0**: the offsets the vendor driver
ioremaps as bare constants are the physical addresses, as #78 derived from
source and as this measures.

**`/etc/fw_env.config` is right, and it is now proven by use rather than by a
hexdump.** `fw_printenv` on the appliance reads the live U-Boot environment:

```
/dev/mmcblk0 0x4C0000 0x100000
bootsystem=B      bootdelay=0      bootcmd=axera_boot
```

`bootsystem=B` because this *was* the slot-B boot, and uppercase, which is the
form `nanokvm-checkboot` accepts. The value was computed by
`nixos/emmc-partitions.nix` from the `blkdevparts=` clause, never captured.

**#81's tool ran on hardware for the first time**, which #81 itself could not
do because it had no mainline userspace. All four ATX lines resolve by their
device-tree name across four gpiochips, read-only:

```
atx-power 0   atx-reset 0   atx-power-led 0   atx-hdd-led 0
```

No line was driven: pressing `atx-power` presses a button on someone's machine.
The LT6911UXC `/proc` ABI is complete under a real userspace — 15 entries, and
`chip_id` reads `lt6911uxc`.

**The safety property held.** The slot register read `0x00000018` from the
appliance: SLOTB set, `SLOTB_BOOTABLE` consumed, nothing re-armed it — the loop
variant does not build `nanokvm-checkboot`. `systemctl reboot` from the
appliance landed on slot A, the vendor Ubuntu system, at its usual address.

**306 lines of `clk_summary`**, watchdog `AX630C watchdog`, state `inactive`,
timeout 60 (the kernel is petting the dog U-Boot armed; nothing opened
`/dev/watchdog`).

## The one defect, and its diagnosis

The board came up as `nanokvm` at a NEW DHCP address, not as `kvm-<derived>` at
the address it has always had. Both halves are the same class of bug, and both
are in the journal:

```
hostnamectl[496]: Could not set static hostname: /etc/hostname is in a
                  read-only filesystem.
```

`hostnamectl set-hostname` sets the STATIC hostname, which means writing
`/etc/hostname` — a read-only store symlink on NixOS. `nanokvm-identity` was
written specifically because the vendor's `sed` into `/etc/network/interfaces`
and `/etc/hostname` cannot work here, and its replacement walked into the same
trap for the hostname half. The MAC half, `ip link set … address`, worked.

The address moved for a second, independent reason:

```
DHCPv4 Client ID: IAID:<iaid>/DUID
```

**The same MAC is not enough to get the same lease.** systemd-networkd defaults
to `ClientIdentifier=duid`, so DHCP option 61 carried a DUID the server had
never seen and it allocated a new address. The vendor stack runs `udhcpc`
through ifupdown, which sends the MAC. On a board reached only over the network
that is most of the way to invisible — the appliance was eventually found by
sweeping the subnet for a TLS certificate whose CN only this appliance
generates.

Fixes: `hostnamectl --transient set-hostname`, and
`dhcpV4Config.ClientIdentifier = "mac"`.

## Redaction

`state.txt` and `journal.txt` are raw device output with network and device
identity replaced, using the vocabulary the rest of `docs/reference/mainline/`
already uses. The device's usual LAN address is `<device-ip>`, the new lease it
took in this run `<device-ip-new>`, the router/DHCP server `<router>`, the
workstation driving the test `<lan-host>`; the board's provisioned MAC is
`<redacted-mac>` and its MAC-derived link-local `<redacted-ipv6-ll>`; the SoC
UID and its two halves are `<uid-hi><uid-lo>`, the `sha512sum` of `/device_key`
`<uid-hash>`, the derived hostname `kvm-<derived>`; and the image's machine-id
and DHCP IAID are `<machine-id>` and `<iaid>`. `dmesg.txt` needed none.

Register values, offsets, timings, unit names, partition numbers, speeds and
every fact the proof rests on are untouched. The two random MACs stmmac assigns
at probe, before `nanokvm-identity` overrides them, are left as captured — they
are not the board's, and they are what makes the DHCP finding legible.
