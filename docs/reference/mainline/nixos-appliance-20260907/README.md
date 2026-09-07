# The NixOS appliance booting on the mainline kernel — #78, 2026-09-07

Two `qemu-system-aarch64 -M virt` boots of `.#kernel-mainline-appliance-qemu`,
which is the appliance kernel — mainline Linux 7.1.3 with the **NixOS stage-1
initrd embedded in the Image** — differing in exactly one thing: whether the
embedded initramfs carries a `/dev/console` node. Run 1 panics 330 ms into
userspace with no output at all; run 2 boots to multi-user with zero failed
units and the KVM server listening on :80/:443.

This is not hardware. The AX630C is not involved: QEMU supplies the device tree,
the clocks, the block device and the console. What these runs prove is the half
of #78 that hardware could never have shown, because this board has no serial
console — that the boot **contract** is right, and which units survive contact
with a first boot.

Reproduce either with `nix run .#nixos-appliance-qemu-run`. The test module is
`nixos/qemu-test.nix`; it adds a self-test unit that dumps the state of
everything #78 owns and then powers the machine off, so a run is an artifact
rather than a login prompt.

## The files

| File | What it is |
|---|---|
| `qemu-boot-no-dev-console.log` | Run 1. The failure this whole harness earned its keep on. |
| `qemu-boot-selftest.log` | Run 2. A clean boot plus the self-test dump. Re-taken after #81 merged, so it covers the merged tree. |

## Run 1 — the missing `/dev/console`

```
[    0.577414] Warning: unable to open an initial console.
[    0.611372] Freeing unused kernel memory: 10048K
[    0.612187] Run /init as init process
[    0.935491] Kernel panic - not syncing: Attempted to kill init! exitcode=0x00000100
```

Nothing between "Run /init" and the panic. Not a single line from NixOS stage 1,
because stage 1 starts with fd 0/1/2 closed and dies on its first `exec 8>&1`
before it can redirect anything to `/dev/kmsg`.

The cause is specific to embedding an initramfs in the Image. The kernel ALWAYS
unpacks a built-in initramfs; with `CONFIG_INITRAMFS_SOURCE` empty it unpacks
`usr/default_cpio_list`, whose entire content is `/dev`, `/dev/console` and
`/root`. On an ordinary machine the bootloader hands the initrd over separately,
that default list still runs, and `/dev/console` exists before PID 1 starts — so
a NixOS initrd has never needed to carry device nodes. Setting
`CONFIG_INITRAMFS_SOURCE` **replaces** the default list, and the node goes away.

`nixos/rootfs.nix` now appends a three-entry cpio (`dev`, `dev/console`,
`dev/null`, built under `fakeroot` because the sandbox cannot `mknod`) after the
NixOS archive. The kernel's unpacker resets at each `TRAILER!!!` and keeps
going, which is exactly how concatenated initramfs images are supported.

**Why this matters beyond QEMU:** on the real board this failure is a kernel
that reaches userspace, prints nothing, and resets. Through the boot-evidence
channel (#75) it is indistinguishable from a kernel that hung — the milestone
bits would read `0x00000014`, the same value a dead kernel leaves.

## Run 2 — a clean boot

```
=== nanokvm appliance self-test (#78) ===
--- root filesystem ---
/dev/vda ext4 rw,noatime
--- /etc/fw_env.config ---
/dev/mmcblk0 0x4C0000 0x100000
--- identity ---
hostname: nanokvm
device_key: (none -- no SoC UID here)
--- nanokvm-gpio (#81) ---
/nix/store/…-nanokvm-gpio-1.0/bin/nanokvm-gpio
nanokvm-gpio: no gpiochip names line 'atx-power'
--- nanokvm units ---
  nanokvm-appdir.service      loaded active exited   Copy /kvmapp to tmpfs
  nanokvm-cert.service        loaded active exited   Generate the HTTPS certificate if absent
  nanokvm-checkboot.service   loaded active exited   Confirm the active A/B boot slot
  nanokvm-identity.service    loaded active exited   MAC and hostname from the SoC UID
  nanokvm-usb.service         loaded active exited   USB HID/storage gadget (stub -- #82)
  nanokvm-video.service       loaded active exited   open video stack (stub -- #83)
  nanokvm.service             loaded active running  NanoKVM-Pro server (open stack)
--- failed units ---
0 loaded units listed.
--- NanoKVM-Server.log ---
2026/09/07 config loaded successfully
2026/09/07 Starting HTTPS server on :80, :443
--- nanokvm-checkboot ---
checkboot: bootsystem='' not a/b -- refusing to write the slot register
```

What that establishes, item by item:

**The boot contract holds with no `init=` on the command line.** The cmdline on
the real board comes from the U-Boot environment, which we do not write, so
stage 1 falls back to its built-in default `stage2Init=/init`. The image ships
`/init` as a symlink to the system profile. Updating that profile is therefore
the whole of a generation switch — no bootloader, no config file, no partition
write.

**`/etc/fw_env.config` ships and is right.** It is not a device capture and not
a guess: `nixos/emmc-partitions.nix` parses the `blkdevparts=` clause out of
`dts/ax630c-nanokvm-pro.dts` — the string U-Boot itself parses, and the only
definition this eMMC has of its own layout — sums the six partitions before
`env`, and asserts the result against the documented `0x4C0000`/`0x100000`. The
same parse supplies p16/p17 and the A/B slot partition numbers.

**`nanokvm-checkboot` is live for the first time.** It was inert in the 4.19
scaffold for want of this file. Here it runs, finds no `bootsystem` (QEMU has no
U-Boot environment), and refuses to write the slot register — which is the
correct behaviour and the one the code was written for.

**Two defects a first boot exposes that a build cannot.** Both were in the 4.19
scaffold and would have fired on hardware:

1. `nanokvm.service` had the tmpfs copy as an `ExecStartPre` while
   `WorkingDirectory=/dev/shm/kvmapp/server`. systemd applies `WorkingDirectory`
   to every `Exec*` line, so the command that CREATES the directory was chdir'd
   into it first and died `200/CHDIR` on every boot. The copy is now its own
   unit (`nanokvm-appdir`).
2. With that fixed, `NanoKVM-Server` got as far as writing its default
   `/etc/kvm/server.yaml`, binding both ports, and exiting 1 on
   `open /etc/kvm/server.crt: no such file or directory`. That was gap 1 in
   `docs/nixos-rootfs.md` — the vendor `nanokvm.sh` generates the cert and lives
   only in the vendor rootfs. `nanokvm-cert.service` now generates a self-signed
   per-device cert if absent, and the server runs.

**The two hardware stubs behave.** `nanokvm-video` and `nanokvm-usb` succeed and
say which issue owns the hardware they cannot touch (#83, #82). They exist so
the ordering edges are real and so a boot log names the missing pipeline instead
of leaving a silent black stream.

**#81 is wired in, and there is no GPIO stub.** This run was re-taken after #81
merged. There is no `nanokvm-gpio.service` at all — nothing to export and
nothing to mux by hand, because a GPIO request now runs through `gpio-ranges` →
`gpio_request_enable()` and the pin controller programs the pad. Instead the
appliance takes the `gpioBackend = "libgpiod"` server build and carries the
`nanokvm-gpio` tool on the system PATH, which the self-test resolves and runs:

```
/nix/store/…-nanokvm-gpio-1.0/bin/nanokvm-gpio
nanokvm-gpio: no gpiochip names line 'atx-power'
```

That error is the correct QEMU answer and is the point of the probe — the tool
addresses lines by their device-tree name, so "no gpiochip names line" says the
binary is present and looking, which is a different fact from the binary being
absent. Driving an ATX line is hardware-only, and pressing `atx-power` presses a
button on someone's machine.

## What this does NOT prove

Anything about the AX630C: the device tree, clocks, pinctrl, eMMC, Ethernet, the
watchdog and the A/B slot register are all QEMU's here, or absent. In particular
the identity derivation took its "no SoC UID" path — QEMU has no `misc_info` at
physical `0x740` — so the MAC/hostname arithmetic is unexercised. That, and the
loop-image root, are the hardware half.
