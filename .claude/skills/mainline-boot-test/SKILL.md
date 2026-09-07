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
tools/kvmssh 'devmem 0x0239002C 32 0xF000
  /etc/init.d/S99checkboot systemB
  sync'
tools/kvmssh 'nohup sh -c "sleep 2; reboot" >/dev/null 2>&1 &'
```

The first write clears milestone bits 12–15 from any previous run — **skip it
and you will read a stale result and believe it**. `S99checkboot systemB` is
mandatory: a raw `SLOTB` poke leaves `SLOTB_BOOTABLE` clear and the SPL falls
straight back to A. Expect `0x00000038` after arming.

Then wait. Round trip is roughly `20 s + the initramfs dwell` (120 s as
shipped) — about 2 min 45 s. Wait with a background until-loop, not a sleep:

```
until timeout 20 tools/kvmssh 'true' >/dev/null 2>&1; do sleep 5; done
```

If SSH does not return within ~4 minutes, the board is hung with the watchdog
disarmed — that needs Jeremy to power-cycle it. It has never happened.

## 5. Read the result

Three channels, in increasing order of detail.

```
tools/kvmssh 'devmem 0x02390024'
```

| Value | Meaning |
|---|---|
| `0x0000f014` | all four milestones + slot A re-armed — full success |
| `0x0000?014` with fewer bits | got that far and died; see the table below |
| `0x00000014` | never reached userspace — go straight to the ramoops console |

Bits: 12 = `/init` running and `/dev/mem` works, 13 = kernel log stashed,
14 = dwell completed (this is the watchdog proof), 15 = `reboot(2)` called.

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

## 6. Put slot B back

Leave the board with a bootable rescue slot unless you are about to iterate
again immediately.

```
tools/kvmssh 'cd /root/pre75
  dd if=p13-dtb_b.bak    of=/dev/mmcblk0p13 bs=1M conv=fsync
  dd if=p15-kernel_b.bak of=/dev/mmcblk0p15 bs=1M conv=fsync
  sync; echo 3 > /proc/sys/vm/drop_caches'
tools/kvmssh 'devmem 0x0239002C 32 0xF000'   # clear the milestone bits
```

Verify both restores from the medium against the step-2 md5s, and confirm
`devmem 0x02390024` reads `0x00000014` — slot A steady state.

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
- New milestone bits: 16–29 are still free. 0–11 and 30–31 belong to the boot
  chain.
