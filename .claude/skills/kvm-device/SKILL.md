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
  **Rebooting:** make `reboot` the LAST thing in the command string and
  expect the call to error ("connection closed by remote host") or, if
  output preceded it, to hang past the tool timeout — both are the reboot
  working, not a failure. Then poll for return with a background
  until-loop (`until tools/kvmssh 'echo up' | grep -q up; do sleep 5;
  done`); SSH is typically back within ~60-90 s. Warm reboots are safe:
  `/kvmapp` hot-patches persist (tmpfs tree is re-copied at boot) and a
  warm reboot is a watchdog reset (does NOT reset the USB2 PHY — only a
  cold power cycle does).
- `tools/kvmscp <local-files...> <remote-path>` — copy files to the device
  (remote path is a path on the device, e.g. `/tmp/`; the script adds the
  `root@<ip>:` prefix itself).
  **Copy first, verify, then edit — never chain a device edit after the copy in
  one `set -e` script:** a mis-invoked `kvmscp` (e.g. with a `root@…:` prefix)
  fails silently, and a following `cat /root/new > /opt/scripts/wifi.sh` still
  TRUNCATES the target to 0 bytes before `set -e` aborts (2026-09-03). Land the
  file, `sha256sum` it on the device, then install it in a separate command.
  (Repeated 2026-09-04 — the `root@…:` prefix mistake again. Read the usage line.)
  **It can also exit 0 having copied nothing** (2026-09-06: a leading bare
  `:` on the remote path). Never treat `kvmscp`'s exit status as proof —
  always `md5sum` the landed file against the local one.
- **Pulling a file from the device:** `kvmscp` is push-only. Use
  `tools/kvmssh 'cat /path/on/device' > local-file` — binary-safe, works for
  register dumps and `.ko`s alike.
- **`cp -n` / `cp -an` exits 1 when it skips an existing file** (coreutils ≥ 9.2
  on the device) and silently aborts a `set -e` script at that line (2026-09-04:
  a vendor-stack restore stopped half-way). Use plain `cp -a` or drop `set -e`.

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
  glibc memset/memcpy on such a mapping SIGBUSes -- DC ZVA on Device memory --
  so zero/copy with plain word loops, and never read 0x04403000 on a base-only
  boot: that VPP/MM block is unclocked there and the read hangs the bus);
  YUV zeros decode green).
- libkvm can be exercised WITHOUT the Go server via python3 ctypes
  (service stopped first): dlopen `/dev/shm/kvmapp/server/dl_lib/libkvm.so`,
  `kvmv_init(0)`, then `kvmv_read_img(w, h, type, qlty, byref(u8ptr),
  byref(u32))` (type 0=MJPEG, 3=H264; see kvm_vision.h). Used to prove the
  fps=0 rebuild fix by replaying the exact web-UI call sequence. Restart
  nanokvm afterwards.
- LT6911 live source truth: `/proc/lt6911_info/{width,height,fps}`.
- **Phantom refcount on the open encoder module (2026-09-05):** after a
  session with capture re-inits, `/sys/module/ax630c_venc_vcmd/refcnt` can
  read 2 with `nanokvm` stopped and no process holding `/dev/es_venc`, so
  `rmmod` says "in use" and `/soc/scripts/auto_load_all_drv.sh -r` cannot
  unload the open stack. Only a reboot clears it (refcnt 0 afterwards). Check
  it BEFORE any module-swap experiment, not after the swap half-fails.
- On-device tools: `gcc`, `python3` (3.13) are present; `ffmpeg`/`ffprobe`
  are NOT — pull bitstreams to the host (`tools/kvmssh 'cat f' > f`, a
  75 MB tar pulled fine) and decode with `nix shell nixpkgs#ffmpeg-full`.

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

## Power-cycling the board yourself (2026-09-09)

The board is on the zigbee plug **`nanokvm switch`** (user-level `power-switch`
skill). A stranded slot-B boot, a hung AXI bus, or a NixOS stage 1 stuck on its
interactive prompt no longer needs Jeremy:

```sh
SW=~/.claude/skills/power-switch/switch.sh
$SW "nanokvm switch" state          # {"state":"ON","power":3.4,...}  idle appliance ≈ 3.5 W
$SW "nanokvm switch" off; sleep 5; $SW "nanokvm switch" state   # power 0, state OFF
$SW "nanokvm switch" on             # mainline chain: SSH in 2-3.5 min (measured
                                    # 2026-09-09 over six boots, cold and warm)
```

Rules: read every volatile channel first (slot register `devmem 0x02390024`,
the U-Boot pre-console buffer, ramoops/pstore) — a cold cycle clears DRAM and the
register. Confirm with `state`, not with the publish. Do not cycle during a
block write (`dd` to an eMMC partition) — wait for the hash-verify. One cycle per
failed boot; give the mainline chain **8 minutes** before deciding it is dark --
most of that is the single-block eMMC read of a 51 MB `Image` (#91), and one
rung-4 boot came back only after a cycle at eight minutes.

**Pre-probe caveat (2026-09-09):** `tools/kvmssh` skips an address whose
`bash -c 'echo > /dev/tcp/$ip/22'` probe fails. In a subagent sandbox that
redirection can be blocked outright, so a healthy board reads as
"tcp/22 unreachable" — one agent power-cycled a live board on that false
negative and lost a finished run's console buffer. When a probe says
unreachable and the board *should* be up, confirm with
`socat - TCP:$ip:22 </dev/null` (prints the SSH banner) before acting.


## Switching the NixOS appliance — `nix copy --to ssh://` (#100)

The appliance has `nix` since #100, so a configuration switch is what it is on
any NixOS machine: copy the closure over SSH and activate it. Three commands,
and none of them is ours.

```sh
NEW=$(nix build .#appliance-toplevel --no-link --print-out-paths)

# 1. The closure, over SSH. Only what the board is missing crosses the wire.
#    --no-check-sigs because the source is YOUR build host, not a cache:
#    this is the one place that flag is right.
nix copy --to "ssh://root@$KVM_HOST" --no-check-sigs "$NEW"

# 2. + 3. The profile and the activation, by the tool that also does the
#    markers and the bootcount gate.
tools/kvmssh "nanokvm-update install-toplevel $NEW"
tools/kvmssh 'nanokvm-update status'
tools/kvmssh 'reboot'
```

`install-toplevel` runs `nix-env --set` and `switch-to-configuration boot`, so
the switch only becomes live on the reboot — which is what arms the rollback
(`bootcount`, `nanokvm-mark-good`). Use `switch-to-configuration switch` by hand
only when you deliberately want an untested userspace live with no way back.

`nix copy --to ssh://` needs the SSH key in the agent and `NIX_SSHOPTS` for
anything `tools/kvmssh` does with options; it also needs nix on BOTH ends.

**Bootstrapping a board that has no nix yet** (any image from before #100, and
the eMMC today): there is nothing on the far end for `nix copy` to talk to, so
the first nix-carrying generation goes over by hand. This is a ONE-TIME recipe
— once it has booted, everything above works.

```sh
# 1. Which store paths are missing on the board?
NEW=$(nix build .#appliance-toplevel --no-link --print-out-paths)
nix-store -qR "$NEW" > /tmp/req.txt
cat /tmp/req.txt | tools/kvmssh 'cat > /root/req.txt;
  while read -r p; do [ -e "$p" ] || echo "$p"; done < /root/req.txt'

# 2. Ship them as a plain tar, plus the registration the new nix will need.
#    (/nix/store may be a READ-ONLY BIND: `remount,bind,ro` to put it back --
#    plain `remount,ro` silently does nothing on a bind mount.)
cd /nix/store && tar -czf /tmp/newsys.tar.gz <the missing basenames>
nix-store --dump-db "$NEW" > /tmp/registration     # or closureInfo's `registration`
tools/kvmscp /tmp/newsys.tar.gz /tmp/registration /root/
tools/kvmssh 'mount -o remount,rw /nix/store 2>/dev/null || true
              tar -C /nix/store -xzf /root/newsys.tar.gz'

# 3. Set the profile the way `nix-env --set` would, then activate.
#    `boot`, not `switch`: on this board the reboot is what arms the rollback,
#    and it is also what makes a new kernel take effect.
tools/kvmssh "ln -sfn $NEW /nix/var/nix/profiles/system-2-link
              ln -sfn system-2-link /nix/var/nix/profiles/system
              $NEW/bin/switch-to-configuration boot && reboot"

# 4. AFTER the reboot, register what the old board could not: the new system
#    has nix, and its store must know about the paths that were tarred in.
tools/kvmssh 'nix-store --load-db < /root/registration
              nix-store --verify --check-contents
              nix path-info -r /run/current-system | wc -l'
```

Step 4 is not optional. A path on disk that the database does not know is not a
store path: `nix-env --set` on one tries to *download* it, and
`nix-collect-garbage` would happily delete it. A flashed image does not need
this — `nixos/lib/appliance-artifacts.nix` builds the database into the image.

**`switch-to-configuration` WRITES `/boot` NOW (#99).** It runs NixOS's
`generic-extlinux-compatible` builder, which copies this generation's kernel,
initrd and dtbs into `/boot/nixos/` and rewrites `/boot/extlinux/extlinux.conf`
— and removes the boot files no menu entry names any more. Three consequences
for a hand switch:

- `/boot` must be mounted, or the builder writes into the rootfs's own `/boot`
  directory and U-Boot sees nothing. `mountpoint -q /boot` first.
- Nothing else has to be copied. A configuration whose kernel changed needs no
  extra step; step 2's tar carries the kernel, because it is a store path in
  the closure.
- `extlinux-fallback.conf` is **not** written by it. That is deliberate — it
  still names whatever last booted healthy, which is the way back if the new
  generation does not come up. `nanokvm-mark-good` promotes it ~60 s after a
  healthy boot; check with `journalctl -u nanokvm-mark-good`.

`/init` is a symlink to `/nix/var/nix/profiles/system/init`, and each extlinux
entry pins `init=` besides, so the profile and the boot config agree.

`nanokvm-update gc` reclaims the old generations afterwards: it pins every
generation a boot config's `DEFAULT` entry names — above all the fallback's —
and refuses to collect anything when a config resolves to no generation.
