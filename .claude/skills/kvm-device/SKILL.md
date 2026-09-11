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
  done`); a mainline boot is **71 s to SSH** and anything past ~3 minutes
  is worth investigating (`bootcount`, below). A warm reboot is a watchdog
  reset and does NOT reset the USB2 PHY — only a cold power cycle does.
  It boots whatever generation `/boot/extlinux/extlinux.conf` selects, so
  a `switch-to-configuration boot` takes effect here and nowhere else.
- `tools/kvmscp <local-files...> <remote-path>` — copy files to the device
  (remote path is a path on the device, e.g. `/tmp/`; the script adds the
  `root@<ip>:` prefix itself).
  **Copy first, verify, then edit — never chain a device edit after the copy in
  one `set -e` script:** a mis-invoked `kvmscp` (e.g. with a `root@…:` prefix)
  fails silently, and a following `cat /root/new > <target>` still TRUNCATES
  the target to 0 bytes before `set -e` aborts (2026-09-03). Land the file,
  `sha256sum` it on the device, then install it in a separate command.
  (Repeated 2026-09-04 — the `root@…:` prefix mistake again. Read the usage line.)
  **It can also exit 0 having copied nothing** (2026-09-06: a leading bare
  `:` on the remote path). Never treat `kvmscp`'s exit status as proof —
  always `md5sum` the landed file against the local one.
- **Pulling a file from the device:** `kvmscp` is push-only. Use
  `tools/kvmssh 'cat /path/on/device' > local-file` — binary-safe, works for
  register dumps and `.ko`s alike.
- **`cp -n` / `cp -an` exits 1 when it skips an existing file** (coreutils ≥ 9.2
  on the device) and silently aborts a `set -e` script at that line. Use plain
  `cp -a` or drop `set -e`.
- **Almost nothing on the appliance is writable.** It is NixOS: `/etc`, `/bin`
  and the whole system are read-only store symlinks, and `/nix/store` is a
  read-only bind mount (`boot.readOnlyNixStore`). `/root`, `/tmp`, `/var` and
  `/boot` are writable; everything else is a configuration change
  (nixos/appliance.nix) and a generation switch, not an edit.

Both scripts read credentials from `~/.config/nanokvm/device.env` (chmod
600). Never inline the IPs or passwords into any tracked file — if you find
yourself typing an IP or password literal into a commit, stop and use the
wrapper instead.

# Health check

Proven one-liner (run via `tools/kvmssh '<the whole thing>'`):

```
uname -r; systemctl is-system-running; systemctl is-active nanokvm; curl -sk -o /dev/null -w "%{http_code}\n" https://127.0.0.1/; devmem 0x02390030 32; readlink -f /run/booted-system
```

What each part tells you:
- `uname -r` — kernel is up and SSH works at all. Mainline 7.1.x.
- `systemctl is-system-running` — `running` is healthy; `degraded` means a
  unit failed, and `systemctl --failed` names it.
- `systemctl is-active nanokvm` — the Go server. `active` is the healthy
  state; without it the web UI is down.
- `curl ... https://127.0.0.1/` — expect HTTP `200` once `nanokvm.service`
  is up.
- `devmem 0x02390030 32` — `bootcount`. `0xB0010000` is healthy (cleared by
  `nanokvm-mark-good` ~60 s in); `0xB001000N` means N boot attempts since the
  last healthy boot, and anything above 1 is worth investigating. The fourth
  attempt runs `altbootcmd` and boots the fallback generation.
- `readlink -f /run/booted-system` — which generation is actually running.
  Compare it with `/nix/var/nix/profiles/system`: they differ after a
  `switch-to-configuration boot` that has not been rebooted into yet, and
  after a rollback.

# Targeted diagnostics (all validated on device 2026-08-15)

**USB HID / gadget path** ("keyboard/mouse not reaching the host"). On the
appliance the gadget is a STUB: #82 landed the dwc3 glue and the configfs
function drivers, but the POLICY half — the script that builds the three HID
report descriptors, the Microsoft OS descriptors and the NCM link — was vendor
rootfs and is not reimplemented (`nanokvm-usb.service` says so in the journal).
Everything below still decodes the CONTROLLER's state; the `usbdev.sh`
escalations were the vendor image's and no longer exist.

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
  (`.../usb_gadget/g0/UDC`), `soft_connect` toggle, and — the one a gadget
  rebuild misses — rebind the Axera GLUE, which re-runs USB clock init:
  `echo "soc:axera_dwc3" > "/sys/bus/platform/drivers/axera dwc3/unbind"`
  (the space in the directory name is real), then `bind`. Stop
  `nanokvm.service` before a glue rebind and start it afterwards.
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
  **mmap works** — use python3 `mmap.mmap(fd, LEN, offset=BASE)`. This is how
  the comm_pool block layout was proven (docs/blob-replacement.md,
  2026-08-17 section); the vendor's `/proc/ax_proc/*` pool listing is gone
  with the vendor stack, so the carveout bases now come from the device tree
  and the open drivers' own dmesg. Zero-run analysis of a dump discriminates
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
  `rmmod` says "in use". Only a reboot clears it (refcnt 0 afterwards). Check
  it BEFORE any module experiment, not after one half-fails.
- Pull bitstreams to the host (`tools/kvmssh 'cat f' > f`, a 75 MB tar pulled
  fine) and decode with `nix shell nixpkgs#ffmpeg-full`. Only add a tool to
  the appliance by adding it to `environment.systemPackages` in
  nixos/appliance.nix and switching a generation — there is no package
  manager on the board.

# Gotchas

- **Two IPs.** The device is reachable over Tailscale or plain LAN; which one
  answers depends on network state at the moment. `tools/kvmssh`/`kvmscp`
  already try Tailscale first, then LAN — you don't need to pick.
- **Two passwords.** The device normally uses a configured password, but
  right after a fresh reflash it reverts to the vendor factory default. Both
  scripts try the configured password first, then the factory default — you
  don't need to know which state the device is in.
- **There is no vendor app stack any more (#97).** `kvmcomm.service` went with
  the 4.19 image; `nanokvm.service` is the only thing that serves the web UI.
  The PATH `/kvmcomm/scripts/wifi.sh` still exists, as a compat shim the Go
  server execs (`nixos/modules/wifi.nix`) — a path, not a service.
- **One capture channel serves every viewer**, gated by the global
  `KvmVision.StreamType`. A second viewer in another mode — another tab, a
  `curl /api/stream/mjpeg`, a stray mode POST — takes the stream and starves
  the first, which the page reports as "inconsistent video mode". That is
  arbitration, not a bug; `service/stream/claims.go` hands the stream back to
  whoever still has clients when a consumer empties.

## Power-cycling the board yourself (2026-09-09)

The board is on the zigbee plug **`nanokvm switch`** (user-level `power-switch`
skill). A stranded slot-B boot, a hung AXI bus, or a NixOS stage 1 stuck on its
interactive prompt no longer needs Jeremy:

```sh
SW=~/.claude/skills/power-switch/switch.sh
$SW "nanokvm switch" state          # {"state":"ON","power":3.4,...}  idle appliance ≈ 3.5 W
$SW "nanokvm switch" off; sleep 5; $SW "nanokvm switch" state   # power 0, state OFF
$SW "nanokvm switch" on             # SSH back in ~90 s (#91 fixed 2026-09-10;
                                    # it was 3-18 min before)
```

Rules: read every volatile channel first (milestone register
`devmem 0x02390024`, `bootcount` `devmem 0x02390030 32`, the chainload oracle
`CHLD` at `0x480EE000`, the U-Boot pre-console ring at `0x480E8000`,
ramoops/pstore) — a cold cycle clears DRAM and the
register. Confirm with `state`, not with the publish. Do not cycle during a
block write (`dd` to an eMMC partition) — wait for the hash-verify. One cycle per
failed boot. Since #91 was fixed (2026-09-10, the eMMC node asks for 200 MHz)
SSH is back ~90 s after `on`; still poll **30 minutes** before calling a board
dark, because a candidate that hangs costs a 300 s watchdog cycle and ten
minutes of patience is what made #94 look like a bad flash.

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
and none of them is ours. **Hardware-proven 2026-09-11** — 7 paths in 4.5 s,
valid in the board's database on arrival — and **this board is already
bootstrapped**, so the recipe below it is history unless you are looking at a
freshly flashed pre-#100 image.

`nix copy` drives `ssh` itself, so it needs **key** auth: `tools/kvmssh`'s
password does not reach it. Put a public key in `/root/.ssh/authorized_keys`
(the file does not exist by default; `/root/.ssh` is writable, and
`PasswordAuthentication yes` stays on) and point `NIX_SSHOPTS` at the private
half. Remove the key when you are done.

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

**Register every generation the boot configs name, not just the new one.** A
pre-#100 board's generations were unpacked by `tar`, so they are directories no
database knows about — and an unregistered path is not a store path: `nix-env
--set` on one **fails** ("no substituter that can build it") and
`nix-collect-garbage` **deletes** it, gc root or no gc root (both measured). The
one that matters is whatever `extlinux-fallback.conf` names, because that is the
generation the rollback boots. `nanokvm-update gc` refuses to run at all while a
boot config names an unregistered generation, which is the backstop, not the
plan.

```sh
# 1. Which store paths are missing on the board?
NEW=$(nix build .#appliance-toplevel --no-link --print-out-paths)
nix-store -qR "$NEW" > /tmp/req.txt
cat /tmp/req.txt | tools/kvmssh 'cat > /root/req.txt;
  while read -r p; do [ -e "$p" ] || echo "$p"; done < /root/req.txt'

# 2. Ship them as a plain tar, plus the registration for EVERY generation the
#    two boot configs name. Read those off the board first:
#      tools/kvmssh 'grep -h "init=" /boot/extlinux/*.conf'
#    then, for the new toplevel AND each one still named (they are all paths
#    this build host has, because it built them):
cd /nix/store && tar -czf /tmp/newsys.tar.gz <the missing basenames>
nix-store --dump-db $(nix-store -qR "$NEW" "$OLD_DEFAULT" "$OLD_FALLBACK") \
  > /tmp/registration
tools/kvmscp /tmp/newsys.tar.gz /tmp/registration /root/
# /nix/store IS a read-only bind mount (boot.readOnlyNixStore). Without the
# flip, tar exits 2 with nothing useful on stderr; `remount,ro` alone would be
# a silent no-op on a bind, hence `remount,bind,ro` to put it back.
tools/kvmssh 'mount -o remount,rw /nix/store
              tar -C /nix/store -xzf /root/newsys.tar.gz
              mount -o remount,bind,ro /nix/store'

# 3. Set the profile the way `nix-env --set` would, then activate.
#    BY HAND, because `nix-env --set` cannot do it yet: there is no nix on this
#    board, and after the reboot the path would still be unregistered.
#    `boot`, not `switch`: the reboot is what arms the rollback, and it is also
#    what makes a new kernel take effect. switch-to-configuration itself needs
#    no database — it is a program on disk, and NixOS's extlinux builder only
#    does readlink/cp.
tools/kvmssh "ln -sfn $NEW /nix/var/nix/profiles/system-5-link
              ln -sfn system-5-link /nix/var/nix/profiles/system
              $NEW/bin/switch-to-configuration boot && reboot"

# 4. AFTER the reboot, register everything — the new system has nix now, and
#    this is what makes the tarred-in paths real. NOT OPTIONAL, and it must
#    come before any collection.
tools/kvmssh 'nix-store --load-db < /root/registration
              nix-store --verify --check-contents          # THE oracle
              nix path-info -r /run/current-system | wc -l
              nanokvm-update status'                        # what /boot pins

# 5. Once nanokvm-mark-good has promoted the fallback to a REGISTERED
#    generation (journalctl -u nanokvm-mark-good), retire the pre-nix ones:
tools/kvmssh 'nix-env -p /nix/var/nix/profiles/system --list-generations
              nix-env -p /nix/var/nix/profiles/system --delete-generations 1 2 3
              nanokvm-update gc'
```

Step 4 is not optional, and step 5 must not run before the fallback names a
generation the database knows. A flashed image needs neither —
`nixos/lib/appliance-artifacts.nix` builds the database into the image.

**What needs the database and what does not** (measured, not assumed):

| | Needs a valid db? |
|---|---|
| `switch-to-configuration boot` | **No.** A program on disk; the extlinux builder only `readlink`s and `cp`s. |
| the profile symlinks, written by hand | **No.** They are symlinks. |
| `nix-env --set` | **Yes.** It `ensurePath`s and fails: "no substituter that can build it" — and writes no generation. |
| `nix-collect-garbage` | **Yes**, and this is the dangerous one: it deletes unregistered paths, gc root or not. |

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
