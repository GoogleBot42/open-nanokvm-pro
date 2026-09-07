---
name: mainline-boot-test
description: Boot-test a mainline kernel on the NanoKVM-Pro from slot B and read the result back — the reversible, unattended, serial-less loop every #26 child issue (#76-#87) runs. Use whenever a change to .#kernel-mainline or dts/ needs proving on hardware.
---

Validated 2026-09-06 on #75 (three consecutive runs, the first mainline kernel
ever to run on this SoC). Every step below was executed; nothing here is
inferred.

The device has **no serial console** — the UART0 pads are hidden. A mainline
kernel also has no storage, no network and no shell until #76 lands, so it
cannot tell you anything while it runs. This loop is how it tells you
afterwards.

Background and the register-level "why": `docs/mainline-port.md` §8 ("What
exists now (#75)") and `docs/flashing-and-recovery.md` → "Testing a MAINLINE
kernel on slot B". Read those before changing the mechanism; read this to run it.

## Why it is safe to run unattended

The SPL treats `SLOTB_BOOTABLE` as consume-once, and **nothing in the mainline
image re-arms it**. So whatever happens on slot B — clean reboot, panic, hang,
watchdog reset — the next boot goes to slot A, the vendor system, on its own.
Slot A and the rootfs are never written.

That is also why `fw_printenv bootsystem` is NOT the oracle, despite what #75's
original issue text said: re-arming to make `bootsystem` read B would strand the
device on a rootfs-less slot forever, and you can only read the variable from
slot A anyway. **Do not add a re-arm.** The evidence comes back in memory.

# Procedure

## 1. Build

```
nix build .#kernel-mainline-slot-image -o result-mainline
nix build .#dtb-mainline-slot-image    -o result-mainline-dtb
```

The kernel build asserts its own config contract (fragment survived
`olddefconfig`, release string stable, `Image` fits the partition, the embedded
initramfs is ours). If you added a file under `pkgs/kernel-mainline/tree/`,
**`git add` it first** — the flake only sees tracked paths, and an untracked
driver fails evaluation rather than being silently skipped.

## 2. Back up both slot-B partitions (first run only)

A mainline kernel needs its own device tree, so this touches **two**
partitions, not one: `dtb_b` = `/dev/mmcblk0p13` and `kernel_b` =
`/dev/mmcblk0p15`. Never `p12`/`p14` — those are slot A.

```
tools/kvmssh 'mkdir -p /root/pre75; cd /root/pre75
  dd if=/dev/mmcblk0p13 of=p13-dtb_b.bak    bs=1M count=1  2>/dev/null
  dd if=/dev/mmcblk0p15 of=p15-kernel_b.bak bs=1M count=64 2>/dev/null
  sync; echo 3 > /proc/sys/vm/drop_caches; md5sum *.bak'
```

Record those two md5s — step 6 restores from them. As of 2026-09-06 they are
`0a19b720189baad4aec9375931ad9c95` (p13) and `e3b8750012fab3dbd8201a818459987a`
(p15); re-derive rather than trusting these if slot B has been rewritten since.

## 3. Copy and flash

Stage into your scratchpad directory first with `install -m644` (`$SP` below)
— Nix store outputs are mode 444, so a plain `cp` over a previously-staged copy
fails with permission denied.

```
install -m644 result-mainline/kernel_b.bin  "$SP/kernel_b.bin"
install -m644 result-mainline-dtb/*.dtb     "$SP/dtb_b.bin"
tools/kvmscp "$SP/kernel_b.bin" "$SP/dtb_b.bin" /root/pre75/
```

**`kvmscp` can exit 0 having copied nothing** — always `md5sum` the landed
files against the local ones before flashing (see the kvm-device skill).

```
tools/kvmssh 'cd /root/pre75
  dd if=dtb_b.bin    of=/dev/mmcblk0p13 bs=1M conv=fsync
  dd if=kernel_b.bin of=/dev/mmcblk0p15 bs=1M conv=fsync
  sync; echo 3 > /proc/sys/vm/drop_caches'
```

Verify **from the medium**, after `drop_caches`, with the exact image size:

```
SZ=$(stat -c%s result-mainline/kernel_b.bin)
tools/kvmssh "head -c $SZ /dev/mmcblk0p15 | md5sum"
```

`head -c <size>` is the reliable form. Take the size from `stat -c%s` on the
image you just built every time — **it changes between builds**, and reusing a
previous byte count compares the wrong range and reports a spurious mismatch
(this wasted a cycle on 2026-09-06).

## 4. Arm slot B and go

```
tools/kvmssh 'devmem 0x0239002C 32 0x1FFF000
  /etc/init.d/S99checkboot systemB
  sync'
tools/kvmssh 'sync; reboot'
```

The first write clears every milestone bit from any previous run — **skip it
and you will read a stale result and believe it**. `S99checkboot systemB` is
mandatory: a raw `SLOTB` poke leaves `SLOTB_BOOTABLE` clear and the SPL falls
straight back to A. Expect `0x00000038` after arming.

**Reboot in the foreground.** An earlier version of this skill used
`nohup sh -c "sleep 2; reboot" >/dev/null 2>&1 &`, and it is a race: the
backgrounded shell has to survive session teardown for two seconds, which it
did on 2026-09-06 for one run and did not for the next. The failure is
expensive to read, because a board that never rebooted looks exactly like a
board that rebooted and hung — same unreachable SSH, same absent milestones.
`reboot` signals init and returns, so the foreground form is deterministic; the
connection drops underneath it and a non-zero exit is normal.

**If a run comes back with no milestone bits, prove the board actually
rebooted before debugging the kernel.** Three independent checks, any one of
which settles it:

```
tools/kvmssh 'cut -d" " -f1 /proc/uptime'   # less than the test round trip?
tools/kvmssh 'dmesg | tail -5'              # anything after your drop_caches?
tools/kvmssh 'devmem 0x02390024'            # still 0x38 = armed, never consumed
```

A slot register still reading `0x00000038` means the SPL never consumed
`SLOTB_BOOTABLE` — that is "no reboot happened", not "the kernel failed".

**The mask grows as milestones are added.** It was `0xF000` for #75's four bits
and is `0x1FFF000` since #76 added two, #77 four and #82 three more. The register's bits 12–29 are all
free (nothing in the SPL, ATF, U-Boot, the RISC-V companion or the vendor
kernel writes them), so there is room — but a stale mask silently leaves old
bits set, which reads as a success that did not happen.

Then wait. Round trip is roughly `20 s + the storage probe + the network and
USB probes + the initramfs dwell` (300 s as shipped) — about 6 min. The storage
probe adds anything from a fraction of a second to its 10 s partition-wait
timeout and logs the elapsed figure (`found after ms:`) precisely so a creeping
delay is visible rather than absorbed; the USB step adds up to 15 s more when
no host answers. Wait with a background until-loop, not a sleep:

```
until timeout 60 tools/kvmssh 'true' >/dev/null 2>&1; do sleep 5; done
```

**Give each attempt at least 60 s.** `kvmssh` tries the Tailscale IP before the
LAN IP, and when the Tailscale route is dead the connect has to time out before
the fallback is even attempted. A 20 s budget kills `kvmssh` mid-fallback, so
every iteration fails and a perfectly healthy board looks hung — which cost a
diagnosis on 2026-09-06, when the device turned out to have no `tailscale`
binary at all. Check the route directly before believing the loop:

```
source ~/.config/nanokvm/device.env
for ip in "$KVM_IP_TAILSCALE" "$KVM_IP_LAN"; do
  printf '%-18s ' "$ip"
  timeout 5 bash -c "cat < /dev/null > /dev/tcp/$ip/22" 2>/dev/null \
    && echo "port 22 OPEN" || echo "no route"
done
```

If SSH really does not return, the board is hung with the watchdog disarmed —
that needs Jeremy to power-cycle it. It has not happened yet; both apparent
cases so far were this timeout artefact or a reboot that never fired.

## 5. Read the result

Three channels, in increasing order of detail.

```
tools/kvmssh 'devmem 0x02390024'
```

| Value | Meaning |
|---|---|
| `0x01fff014` | every milestone + slot A re-armed — full success |
| `0x00???014` with fewer bits | got that far and died; see the table below |
| `0x00000014` | never reached userspace — go straight to the ramoops console |

| Bit | Set when |
|---|---|
| 12 | `/init` is running and `/dev/mem` works |
| 13 | the kernel log was stashed |
| 14 | the dwell completed — this is the watchdog proof |
| 15 | `reboot(2)` was called |
| 16 | the eMMC produced a partitioned block device (#76) |
| 17 | ext4 on it mounted read-only and was read (#76) |
| 18 | `eth0` exists and the PHY negotiated carrier (#77) |
| 19 | a DHCP lease was taken and configured (#77) |
| 20 | an ICMP round trip to another host on the LAN succeeded (#77) |
| 21 | dropbear started (#77) |
| 22 | a USB device controller registered — the dwc3 glue and core bound (#82) |
| 23 | all five gadget function drivers present, HID keyboard gadget bound to the UDC (#82) |
| 24 | the UDC reached state `configured` — a host enumerated us (#82) |

**Bit 24 is the only one that depends on a cable.** 22 and 23 set with 24
clear means the port works and the physical link does not — that unit's USB
link has been unreliable since 2026-09-05 (#42 was a physical fault). Check it
from the bench host the KVM's USB-C is plugged into: `lsusb -d 1d6b:0104`
should show "NanoKVM-Pro mainline bring-up", and a `hidraw`/`input` device
should appear in its `dmesg`. **We have no shell on that machine**, so the
practical pre-flight is to read the VENDOR system's own
`/sys/class/udc/8000000.dwc3/state` before arming slot B: `configured` there
means a host is attached and working, and bit 24 coming back clear is then a
real failure rather than an unplugged cable.

**debugfs is not mounted in the bring-up initramfs.** `clk_summary` and
everything else under `/sys/kernel/debug` silently returns nothing until you
`mount -t debugfs none /sys/kernel/debug` from the mainline shell.

Note the storage, network and USB bits are all set *before* the dwell, so
`0x01ff3014` — everything up to USB good, dwell and reboot missing — means the
board died during the dwell, which is a watchdog problem and not a storage,
network or USB one. The questions are independent by construction.

Since #77 the board is also **reachable while it dwells**: `/init` gives eth0
the MAC it reads out of the vendor rootfs, so DHCP hands back the same lease
and `tools/kvmssh` works unchanged. `uname -r` is the oracle for which slot
answered — `7.1.3-nanokvm` is the mainline kernel, `4.19.125` is slot A. The
dwell is 300 s; `touch /run/keepalive` from that shell extends it to a
one-hour cap, and nothing extends it past that. **That extension is one-way**:
`/init` latches the limit the first time it sees the file, so deleting the file
does not shorten the dwell — touch it only if you are willing to wait out the
full hour, or to end the run yourself from the mainline shell.

```
# the whole kernel log, verbatim, as /init copied it (record format)
tools/kvmssh 'dd if=/dev/mem bs=4096 skip=$((0x480e8000/4096)) count=8 2>/dev/null' \
  | tail -c +33 > mainline-dmesg.txt

# the ramoops console zone: plain text, and it covers the WHOLE boot including
# the reboot -- this is the one to read when userspace never ran
tools/kvmssh 'dd if=/dev/mem bs=4096 skip=$((0x480e4000/4096)) count=4 2>/dev/null' \
  | tail -c +13 > mainline-console.txt
```

The stash stops where `/init` copied it (early, by design, so a board that dies
mid-dwell still leaves it); the ramoops zone covers the rest. A panic lands in
the dump zones at `0x480e0000`/`0x480e2000` instead. Each zone begins with a
12-byte header — `DBGC` signature, write pointer, valid byte count — so
`od -Ax -tx4 | grep 43474244` locates them if the layout ever moves.

**What "it worked" looks like** (from #75's banked run, `docs/reference/
mainline/first-boot-20260906/`):

```
ax630c-wdt 4840000.watchdog: instance 0 at 24000000 Hz, timeout 60s, max 357s
Run /init as init process
openkvm: alive 110s/120s, watchdog0 state=inactive timeleft=29
openkvm: rebooting via the restart handler
reboot: Restarting system
```

`timeleft` holding steady across 10 s samples is the watchdog core petting the
dog; if it counts down instead, the driver did not adopt it and the board will
reset mid-dwell. `state=inactive` is correct — nothing opened `/dev/watchdog`.

A full run since #82 also carries (`docs/reference/mainline/usb-gadget-20260907/`):

```
axera-dwc3 soc:usb@8000000: 2 clocks, VBUSVALID set (peripheral mode)
openkvm: usb: UDC is 8000000.usb
openkvm: usb: 5 of 5 usbdev.sh function drivers present
openkvm: usb: HID keyboard gadget bound
openkvm: usb: host enumerated and configured us
```

## 6. Put slot B back

Leave the board with a bootable rescue slot unless you are about to iterate
again immediately.

```
tools/kvmssh 'cd /root/pre75
  dd if=p13-dtb_b.bak    of=/dev/mmcblk0p13 bs=1M conv=fsync
  dd if=p15-kernel_b.bak of=/dev/mmcblk0p15 bs=1M conv=fsync
  sync; echo 3 > /proc/sys/vm/drop_caches'
tools/kvmssh 'devmem 0x0239002C 32 0x1FFF000'  # clear the milestone bits
```

Verify both restores from the medium against the step-2 md5s, and confirm
`devmem 0x02390024` reads `0x00000014` — slot A steady state.

# Variant: booting the NixOS appliance from slot B (#78)

Same loop, three differences. The image under test is a whole operating system
rather than a self-terminating probe, so it does not reboot itself and its
oracle is an SSH shell rather than a register.

**Use the loop-image variant, never the partition one.** `.#nixos-appliance`
puts root on `/dev/mmcblk0p17` — the vendor rootfs, which is the only way back
onto the board. `.#nixos-appliance-loop` puts root in a FILE on that filesystem
and loop-mounts it from stage 1: nothing is overwritten and rollback is `rm`.

```
nix build .#kernel-mainline-appliance-loop-slot-image -o result-appliance
nix build .#dtb-mainline-slot-image                   -o result-mainline-dtb
nix build .#nixos-appliance-loop                      -o result-approotfs
```

Steps 2 and 3 are unchanged except that the rootfs image goes across as well
(~1.9 GB — `tools/kvmscp` it to `/root/nixos-root.img`, then hash-verify it on
the device like any other transfer; it is a plain file, not a block write).
Stage 1 expects it at the root of the carrier filesystem:

```
tools/kvmssh 'mv /root/nixos-root.img /nixos-root.img; sync
  md5sum /nixos-root.img'
```

**Do not let the appliance re-arm the slot.** `nanokvm-checkboot.service` is the
S99checkboot equivalent, and on a successful slot-B boot it would find
`bootsystem=B` and re-arm `SLOTB_BOOTABLE` — which destroys the whole safety
argument above, because the board would then stay on B. `nixos/loop-test.nix`
sets `nanokvm.checkboot.enable = false` for exactly this reason. If you build
your own test module, turn it off yourself.

**Reading the result.** There is no dwell and no self-reboot, so:

- The appliance takes the same MAC (`nanokvm-identity.service` derives it from
  the SoC UID), so it takes the same DHCP lease and `tools/kvmssh` reaches it
  at the address it already knows. It also answers to the same password:
  stage 1 harvests root's hash out of the carrier filesystem's `/etc/shadow`
  and the system uses it via `hashedPasswordFile`, the same trick #77 used and
  for the same reason — no credential belongs in the image or the repo.
- The carrier (the vendor rootfs) is bind-mounted at `/vendor-root`, so the
  comparison that matters is one command:
  `grep hwaddress /vendor-root/etc/network/interfaces` against
  `ip link show eth0`.
- If it never comes up, power-cycle or wait for the watchdog; nothing re-armed
  the slot, so the next boot is slot A and the ramoops console zone at
  `0x480e4000` still holds the whole failed boot. Read it exactly as in step 5.
- `systemctl --failed`, `journalctl -b`, `cat /etc/fw_env.config`,
  `cat /device_key` and `ip link show eth0` are the things worth capturing.
  Compare the derived MAC against `hwaddress ether` in the vendor rootfs's
  `/etc/network/interfaces` — they must be identical, and that is the check the
  identity derivation exists to pass.

**Getting back.** `reboot` from the appliance lands on slot A because nothing
re-armed. Then step 6 as usual, plus `rm /nixos-root.img` on the vendor rootfs.

# Adapting the initramfs for a new child issue

`pkgs/kernel-mainline/initramfs/bringup-init.c` is one static musl binary with
no shell. Reuse it; extend it rather than replacing it.

- **Set `printk_devkmsg` to `on` before logging anything.** `/dev/kmsg` writes
  are ratelimited to ten records per five seconds per open fd; systemd sets
  this on a normal system, an initramfs inherits the default and silently drops
  everything past the tenth line. `/init` already does this — do not remove it.
- **One `write()` per line.** Each write is a separate kmsg record.
- **Keep the dwell longer than 60 s.** It is not a courtesy to whoever is
  watching the LED: U-Boot arms wdt0 at 30 s per stage, so a shorter dwell
  proves only that the board boots and says nothing about the watchdog.
- **Do not move the log regions to the head of the vendor pstore window.** The
  vendor kernel zaps every zone it owns about 1.5 s into the boot that would
  have read yours. The 64 KiB tail at `0x480e0000` works because it lies inside
  the *data* area of the vendor's ftrace zone, which nothing writes.
- New milestone bits: 25–29 are still free. 0–11 and 30–31 belong to the boot
  chain.
- **Split a step into bits that fail for different reasons.** #82 uses three
  (UDC registered / gadget bound / host enumerated) because only the last one
  can be taken away by a bad cable, and one combined bit would have made every
  cable fault look like a driver fault.
