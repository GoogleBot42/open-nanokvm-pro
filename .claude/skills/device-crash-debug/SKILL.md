---
name: device-crash-debug
description: Capture and bisect kernel crashes on the NanoKVM-Pro test device without serial — oops-trace capture via panic_on_oops=0, dmesg taps, reboot discipline, and the control-experiment method. Use whenever the device "spontaneously reboots" during a test, or a kernel-side bug needs isolating.
---

# Device crash debugging (no serial)

Proven end-to-end during the #50 diagnosis (2026-08-30, six controlled
reproductions; see docs/blob-replacement.md "#50 ROOT-CAUSED"). This unit has
no serial console (see the no-serial memory), so every technique here works
over SSH only.

## Why the device "reboots"

The shipping kernel runs `panic_on_oops=1` and `panic=5`: any ordinary kernel
oops — even one in process context that Linux would normally survive —
panics, waits 5 s, and hard-reboots. A "spontaneous reboot" during testing is
almost always a plain oops you can capture.

No pstore/ramoops is wired (CONFIG_PSTORE_RAM=y but no reserved region — a
DT/cmdline change, i.e. kernel-flash territory) and CONFIG_NETCONSOLE is not
set. Don't re-derive this; it was checked 2026-08-30.

## Capture procedure

1. **Disarm the escalation** (runtime, reversible, reset by reboot):
   `echo 0 > /proc/sys/kernel/panic_on_oops`
   A process-context oops now lands fully in dmesg and the device survives.
2. `dmesg -C` to clear, then reproduce.
3. Read the full trace: `dmesg | grep -B4 -A40 "Unable to handle"` (or
   `Internal error`). You get pc/lr, the module list, registers, call trace.
4. Optionally run a live tap from the host in parallel —
   `tools/kvmssh 'dmesg -w' > tap.log &` — as insurance for the
   panic_on_oops=1 case: it streams the oops header until the connection
   dies, but the tail (pc + call trace) is usually LOST with the panic, so
   prefer step 1 whenever you control the reproduction.

## Discipline (each rule cost real time)

- **Reboot after every oops, before any further systemd work.** An oopsed
  task dies mid-`do_exit` ("Fixing recursive fault but reboot is needed") and
  stays as an unkillable cgroup member: the next `systemctl stop`/`restart`
  of its unit hangs forever. Never chain a second experiment after an oops.
- **`sync` before every deliberate crash.** Rootfs is ext4 rw on eMMC;
  journaling has held across many hard reboots (empirically safe on this
  unit), but don't push luck.
- **Every reboot wipes /tmp** — re-scp all staged artifacts (test binaries,
  .ko files, scripts) after each one.
- **Restore `panic_on_oops=1`** (or just reboot) when done — the shipped
  default is deliberate.
- Verify restoration at the end: service active, `https://127.0.0.1/` = 200,
  expected libkvm md5 in BOTH app trees, expected lsmod set.
- In orchestrating scripts, don't bury interim output behind `| tail` on the
  whole ssh invocation — a hang leaves you blind. Echo phase markers and
  read the task output file mid-run.

## Bisection method

Change ONE variable per cycle and always run the stock control:

- **`kill -9` vs graceful stop** separates kernel-side fd-release cleanup
  (SIGKILL: no userspace teardown runs at all) from userspace teardown
  sequences (SIGTERM → the app's deinit path).
- **Component swaps**: vendor lib + vendor modules (control) / open lib +
  open modules / mixed builds. The `.#kvm-encoder-openvenc-axsysprobe`
  package pattern (a one-flag diagnostic variant) is the template for
  isolating a single linked library.
- Wild fault addresses that decode as ASCII bytes = freed/garbage memory
  walked as pointers, not a specific corrupted object.
- Fault addresses in 0x73800000–0x7FFFFFFF are CMM-derived values; check
  `/proc/ax_proc/mem_cmm_info` live before theorizing about carveout
  collisions (it shows every block with name + phys range).

## Known kernel-side traps (don't rediscover)

- **#50 (FIXED 2026-08-31)**: the `vin_model_manager_deinit+0x44` teardown oops
  was armed by our own capture issuing AINR ioctl `0xc008708a` (proton nr138),
  now gated off — not an ax_venc requirement (venc presence only masked it
  data-dependently). Current openvenc builds tear down clean. Note the
  bisection lesson: the oops is **data-dependent** (fires only when a reused CMM
  count byte is nonzero), so a live repro is a flaky control — a fresh CMM block
  can hide it. And the oops faults before ax_proton nulls its global, so one
  crash poisons the global for later processes; **reboot to a clean baseline
  before trusting any "does it still crash?" result.** Coexistence of the open
  VCMD driver with vendor venc is still impossible (venc holds the VCMD MMIO
  region + IRQ SPI 93) — unrelated to #50.
- Standalone `ewl_*` tools never touch VIN and are safe to crash/exit freely.
