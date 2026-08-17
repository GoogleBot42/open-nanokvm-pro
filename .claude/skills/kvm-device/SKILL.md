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

Deeper decode (worked out 2026-08-17, issue #42) when state is neither of
those:

- `state=default` + `current_speed=high-speed` + debugfs
  `/sys/kernel/debug/8000000.dwc3/link_state` = `Suspend` = the host's bus
  reset and HS chirp COMPLETED but no ep0 transfer ever succeeded, then the
  host gave up. Confirm with `grep dwc3 /proc/interrupts` sampled twice
  (frozen counter = no traffic) and the `SOFFN` field in DSTS via debugfs
  `regdump` (safe to read once `link_state` reads instantly). This pattern
  is a physical-link / host-port problem, not gadget config — chirp is
  robust low-speed signaling; HS data at 400 mV fails first on a marginal
  cable.
- Enumeration history: `journalctl -k -b <N> | grep 'config #1'` — each
  line is one successful SET_CONFIGURATION. A cluster of them without
  matching gadget rebuilds = the HOST was re-enumerating (link flapping or
  host suspend/resume). They co-time with udhcpd re-ACKs on the NCM usb0
  link in the nanokvm journal.
- Escalation ladder, all tried-and-safe: UDC unbind/rebind
  (`.../usb_gadget/g0/UDC`), `soft_connect` toggle, vendor full rebuild
  `usbdev.sh restart` (NOTE: rebinds only the dwc3 CORE), then the one
  usbdev.sh misses — rebind the Axera GLUE (re-runs USB clock init):
  `echo "soc:axera_dwc3" > "/sys/bus/platform/drivers/axera dwc3/unbind"`
  (space in dir name is real), then `bind`, then `usbdev.sh start`.
  Descriptor A/B: `usbdev.sh hid-only` drops NCM + OS descriptors.
  Stop nanokvm.service before glue rebind / hid-only; `usbdev.sh restart` +
  `systemctl start nanokvm` restores the normal stack.
- Board facts (from source, issue #42): no VBUS sense (VBUSVALID is
  force-set in device mode), the USB ID pad is a never-muxed floating mic
  pad, and NO software path pulses the USB2 PHY reset — only a cold power
  cycle resets the PHY analog block. Warm `reboot` = watchdog reset.

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

**Capture pipeline / video quality** (all validated 2026-08-17):

- Quickest "is video sane" probe, no auth needed on localhost:
  `curl -sk --max-time 6 "https://127.0.0.1/api/stream/mjpeg" | head -c 3000000 > /tmp/mj.bin`
  — also wakes/starts capture as a side effect. Split frames on the
  `\xff\xd8\xff` JPEG SOI marker, base64 one over kvmssh, and view it
  locally. Two consecutive frames of a static screen should be
  byte-identical — a per-frame differing offset means a capture-address
  bug, not encoder noise.
- Physical-memory inspection: `read()` on `/dev/mem` fails (EFAULT) but
  **mmap works** — use python3 `mmap.mmap(fd, LEN, offset=BASE)` to dump
  CMM regions (pool bases from `/proc/ax_proc/mem_cmm_info`). This is how
  the comm_pool block layout was proven (docs/blob-replacement.md,
  2026-08-17 section). Zero-run analysis of a dump discriminates
  meta/unwritten pages from live YUYV (real video is never long zero runs;
  YUV zeros decode green).
- libkvm can be exercised WITHOUT the Go server via python3 ctypes
  (service stopped first): dlopen `/dev/shm/kvmapp/server/dl_lib/libkvm.so`,
  `kvmv_init(0)`, then `kvmv_read_img(w, h, type, qlty, byref(u8ptr),
  byref(u32))` (type 0=MJPEG, 3=H264; see kvm_vision.h). Used to prove the
  fps=0 rebuild fix by replaying the exact web-UI call sequence. Restart
  nanokvm afterwards.
- LT6911 live source truth: `/proc/lt6911_info/{width,height,fps}`.

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
