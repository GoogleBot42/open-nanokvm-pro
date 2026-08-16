---
name: kvm-device
description: SSH/SCP access and health-check for the NanoKVM-Pro test device — use whenever a task needs to reach, inspect, or copy files to the device.
---

Validated 2026-08-15 (both the connection helper and the health-check one-liner below were run read-only against the live device).

# Reaching the device

Use the wrapper scripts, never raw `ssh`/`scp`, so credentials never end up
typed into a tracked file or a shell history line that gets pasted somewhere
public:

- `tools/kvmssh '<remote command>'` — run a command on the device.
- `tools/kvmscp <local-files...> <remote-path>` — copy files to the device
  (remote path is a path on the device, e.g. `/tmp/`; the script adds the
  `root@<ip>:` prefix itself).

Both scripts read credentials from `~/.config/nanokvm/device.env` (chmod
600). Never inline the IPs or passwords into any tracked file — if you find
yourself typing an IP or password literal into a commit, stop and use the
wrapper instead.

# Health check

Proven one-liner (run via `tools/kvmssh '<the whole thing>'`):

```
uname -r; systemctl is-active kvmcomm nanokvm; curl -sk -o /dev/null -w "%{http_code}\n" https://127.0.0.1/; [ -b /dev/mmcblk1 ] && echo present || echo absent
```

What each part tells you:
- `uname -r` — kernel is up and SSH works at all.
- `systemctl is-active kvmcomm nanokvm` — exactly one of these two should be
  `active` and the other `inactive`. `nanokvm` active is the healthy state
  for our from-source stack; if `kvmcomm` is active instead, the web UI will
  not be reachable (see Gotchas below).
- `curl ... https://127.0.0.1/` — expect HTTP `200` from the web UI once
  `nanokvm.service` is up.
- `[ -b /dev/mmcblk1 ]` — whether an SD card is currently inserted. Absent is
  normal when the device is running from eMMC with no card in the slot.

# Targeted diagnostics (all validated on device 2026-08-15)

**USB HID / gadget path** ("keyboard/mouse not reaching the host"):

```
cat /sys/class/udc/8000000.dwc3/state; cat /sys/class/usb_role/8000000.dwc3-role-switch/role
```

`configured` + `device` = host enumerated us, gadget healthy — the problem is
elsewhere. `not attached` (with role `device`) = the host never enumerated:
almost always cable/port/host-side (reseat, suspect charge-only cables), not
firmware — gadget config under `/sys/kernel/config/usb_gadget/g0` being bound
to the UDC is normal even in this state. Writes to `/dev/hidg*` block forever
while unattached; guard test writes with `timeout`.

**Mini-display** (status screen, `nanokvm-display.service`):

- Panel asleep is the norm (3-min idle blank): `bl_power=1` in
  `/sys/class/backlight/backlight/` and `/dev/fb0` reads all-zero.
- Wake it with a synthetic knob press (gpio_keys = `/dev/input/event0`,
  KEY_ENTER=28; struct is `qqHHi` on aarch64):

  ```
  python3 -c "
  import struct
  ev=lambda t,c,v: struct.pack('qqHHi',0,0,t,c,v)
  with open('/dev/input/event0','wb') as f:
      f.write(ev(1,28,1)+ev(0,0,0)+ev(1,28,0)+ev(0,0,0))"
  ```

- See what the panel shows without eyes on it: dump `/dev/fb0` (RGB565,
  172x320, 110080 bytes) via `dd | base64` over kvmssh, decode locally, then
  render with the **verified physical mapping `phys(x,y) = fb[319-x][y]`**
  (320x172 output; PIL loop over `px[(319-x)*172 + y]`, e.g. via `nix shell
  --impure --expr '(import <nixpkgs> {}).python3.withPackages (p:
  [p.pillow])'`). Do NOT judge orientation from a plain
  `ffmpeg -vf transpose=2` render — verified 2026-08-16 to come out 180°
  rotated vs. the physical panel; only the explicit mapping is trustworthy.
  The dump contains device IPs — never commit the image.
- Never `rmmod`/live-swap `fb_jd9853`: teardown deadlock hard-hangs the
  device (docs/mini-display.md).

# Gotchas

- **Two IPs.** The device is reachable over Tailscale or plain LAN; which one
  answers depends on network state at the moment. `tools/kvmssh`/`kvmscp`
  already try Tailscale first, then LAN — you don't need to pick.
- **Two passwords.** The device normally uses a configured password, but
  right after a fresh reflash it reverts to the vendor factory default. Both
  scripts try the configured password first, then the factory default — you
  don't need to know which state the device is in.
- **Web KVM requires `nanokvm.service`, NOT vendor `kvmcomm.service`.** The
  two stacks are mutually exclusive and fight over the same capture
  hardware; only one is ever meant to be active. Full comparison table and
  why the vendor default is wrong for us: `docs/architecture.md`,
  section "The two app stacks: nanokvm vs kvmcomm".
