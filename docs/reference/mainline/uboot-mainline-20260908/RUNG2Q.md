# Rung 2q -- the evidence channel was never broken; the reader was (#89)

2026-09-08/09. Rung 2p concluded from an empty `/sys/fs/pstore` that the kernel
"dies before ramoops probes". That inference was wrong, and every conclusion
built on it has to be re-taken.

## `/sys/fs/pstore` is empty on a HEALTHY boot too

The control experiment costs nothing and was never run: warm-reboot slot A --
which boots the same appliance, same kernel, same rootfs -- and look.
`/sys/fs/pstore` is empty there as well.

`systemd-pstore.service` is enabled by default in NixOS. It **archives every
pstore record into `/var/lib/systemd/pstore/` and unlinks it from
`/sys/fs/pstore`**, about ten seconds into every boot. The records are real;
they are just not where rung 2p looked:

```
/var/lib/systemd/pstore/console-ramoops-0
/var/lib/systemd/pstore/dmesg-ramoops-0
/var/lib/systemd/pstore/dmesg-ramoops-1
```

The names are fixed, so **each boot overwrites the previous boot's archive**.
Read them before rebooting again, or bank them first.

## The channel itself is sound

Three properties, all measured on hardware rather than assumed:

- **DRAM survives a warm reboot.** A magic string written to the `bringup-log`
  region at `0x480e8000` through `/dev/mem` was still there, byte for byte,
  after `systemctl reboot`.
- **ramoops captures from the first printk.** `pstore_register_console()` sets
  `CON_PRINTBUFFER`, so when `[ramoops-1]` is enabled at 0.268 s the whole
  buffered log from t=0 is replayed into the console zone.
- **The console zone is written continuously** -- the live zone header at
  `0x480e4000` (sig `DBGC`, then start/size) advances by about forty bytes per
  `/dev/kmsg` line.

One artefact worth knowing: unlinking a record calls `ramoops_pstore_erase()`,
which calls `persistent_ram_zap()` on the **live** console zone. So a slot-A
archived console log always starts around 15 s -- systemd-pstore zeroed the
ring on its way past. On a slot-B excursion no userspace runs, nothing unlinks
anything, and the zone holds the log from t=0.

## The device tree is not the suspect

`/sys/firmware/fdt` on the running slot-A appliance is what the vendor-derived
U-Boot actually hands the kernel. Decompiled and diffed against the
`.#dtb-mainline` output, **the only difference in the entire tree is
`/chosen/bootargs`**. No memory-node rewrite, no `/memreserve/` entries, no
extra reserved region, no `boot_logo_reserved` -- the vendor loader sets the
command line and nothing else.

So the DT mainline U-Boot delivers can differ only by U-Boot's own generic
fixups (`fdt_fixup_memory_banks` with the same 1 GiB the DT already declares,
`fdt_fixup_ethernet`, `fdt_chosen`). Whatever kills the slot-B kernel is not
in the tree; it is in the command line, the load address, or the state the
loader leaves the hardware in.

## Why "dark and stays dark" was never the watchdog going quiet by accident

`ax630c_wdt` does not simply stop U-Boot's dog. It stops it at the head of
probe, then re-arms it at the tail with a 60 s timeout and sets
`WDOG_HW_RUNNING`. With `CONFIG_WATCHDOG_HANDLE_BOOT_ENABLED=y` and
`CONFIG_WATCHDOG_OPEN_TIMEOUT=0` -- both already in `ax630c.config` -- the
watchdog core then pets the hardware **forever** from kernel context, because
nothing in the appliance ever opens `/dev/watchdog` (`RuntimeWatchdogUSec=0`).
A kernel that reaches the watchdog probe and then hangs is therefore petted
into silence for as long as it is powered.

The fix needs no code: `watchdog.open_timeout=<seconds>` on the kernel command
line. `watchdog_set_open_deadline()` runs at registration, and
`watchdog_worker_should_ping()` stops petting once the deadline passes unless
userspace has opened the device. A boot that never reaches userspace resets
itself, with its console log already in ramoops.

## An unrelated bug, found in the banked dumps

The appliance **oopses on every `reboot`**, on slot A, on the vendor chain:

```
[ 6181.488481] shutdown[1]: Rebooting.
[ 6181.504275] reboot: Restarting system
[ 6181.508013] Unable to handle kernel NULL pointer dereference at virtual address 0
[ 6181.553007] Internal error: Oops: 0000000086000004 [#1]  SMP
[ 6181.581341] pc : 0x0
[ 6181.583537] lr : atomic_notifier_call_chain+0x5c/0x88
```

`do_kernel_restart()` walks the restart-handler chain and calls a NULL
`notifier_call`. The reset still happens, so it has been invisible; it is a
real defect in the restart path and gets its own issue.
