---
name: deploy-iterate
description: Build a component with Nix and hot-deploy it to the running NanoKVM-Pro device for fast iteration, then verify the service came back up.
---

Validated 2026-08-15 for the **web-bundle** variant (build → tar → both
trees → restart → HTTP 200 with the new bundle hash), and 2026-08-16 for
the **libkvm** variant below plus the **server binary** (same dual-tree
copy: `cp NanoKVM-Server` into `<root>/server/` for both roots, `chmod
755`, restart, verify — used repeatedly for the mini-display preview and
openCapture work).

# The loop

Package names below are confirmed against `flake.nix`
(`packages` output). Example throughout: `kvm-encoder`, which builds
`libkvm.so` (see `pkgs/kvm-encoder.nix`).

1. **Build.** From the repo root: `nix build .#<package>`, e.g.
   `nix build .#kvm-encoder`. This produces `result/lib/libkvm.so` and
   `result/lib/libkvm.so.0` — both are real files (not one a symlink to the
   other), and the Go server's DT_NEEDED entry is specifically
   `libkvm.so.0` (the build sets `-Wl,-soname,libkvm.so.0`). Deploy both
   files even though only one is directly referenced by name.

2. **Copy to the device.** `tools/kvmscp result/lib/libkvm.so result/lib/libkvm.so.0 /tmp/`
   stages the artifacts in `/tmp` on the device first (see
   `.claude/skills/kvm-device/SKILL.md` for the connection helper).

3. **Install into BOTH trees.** Copy the staged files into `/kvmapp/...`
   (the persistent, on-disk tree) AND `/dev/shm/kvmapp/...` (the live tmpfs
   copy the running service actually reads from). The boot scripts copy
   `/kvmapp` into `/dev/shm/kvmapp` fresh at every boot (`nanokvm_pre.sh`,
   an `ExecStartPre` of `nanokvm.service`), so:
   - writing only `/dev/shm/kvmapp` takes effect immediately but is wiped on
     the next reboot;
   - writing only `/kvmapp` does not take effect until the next reboot (the
     already-running server keeps using the old tmpfs copy).
   For a hot-iteration loop you generally want both: `/dev/shm/kvmapp` so
   the restart in step 4 picks it up now, `/kvmapp` so it survives a later
   reboot. Background: `docs/architecture.md`, section
   "Runtime service model".

   **NEVER `cp` onto a file the running server has open — stage + `mv`,
   always, for EVERY file (binaries AND shared libraries).** `mv` is
   `rename(2)`: it makes a NEW inode and leaves the old one (and every
   mapping of it) intact, so the running process is untouched.
   ```
   cp /tmp/<f> $root/server/<f>.new && mv $root/server/<f>.new $root/server/<f>
   ```
   Always md5sum-verify all deployed copies against the staged file.

   Two distinct traps, both real:
   - `cp` onto the RUNNING `NanoKVM-Server` binary fails with **ETXTBSY**
     and the old file silently stays (cost a deploy cycle 2026-08-17).
   - `cp` onto a mapped **shared library** (`libkvm.so`, `libkvm.so.0`)
     does NOT fail — and that is worse. `cp` opens `O_TRUNC`; truncation
     zaps the running process's pages of that mapping **including its
     private, relocated RELRO/GOT page**. The victim re-faults the NEW
     file image, so its GOT reverts to the un-relocated on-disk values
     (every PLT slot = the `.plt` base) and the next PLT call branches to
     a tiny unmapped address. This was Gitea **#40**: `SIGSEGV ...
     PC=0x24b0` in `kvmv_deinit`, where `0x24b0` is exactly libkvm.so's
     `.plt` base. Idle-suspend only hid it: no libkvm call happened
     between the `cp` and the shutdown, so `kvmv_deinit` faulted first.

4. **Restart and verify.** `tools/kvmssh 'systemctl restart nanokvm'`, then
   poll for up to ~30 seconds:
   - `tools/kvmssh 'pgrep -a NanoKVM-Server'` — process is up.
   - `tools/kvmssh "ss -tlnp | grep -E ':(80|443) '"` — it's actually
     listening.
   - `tools/kvmssh 'curl -sk -o /dev/null -w "%{http_code}" https://127.0.0.1/'`
     — expect `200`.
   Do not skip this step (see Failure modes).

# Variant: web bundle (`nanokvm-web`)

Proven flow (2026-08-15, deploying the dead-extensions patch):

1. `nix build .#nanokvm-web --out-link <scratch>/result-web` — output is the
   static `dist/` (index.html + assets/). The bundle filename hash
   (`assets/index-<hash>.js`) changes with content — note it; it's the
   deploy-verification token.
2. `tar czf web-dist.tar.gz -C result-web .` and `tools/kvmscp` it to `/tmp/`
   (~700 KB, quick).
3. Install into BOTH trees with an atomic-ish swap; the web root is
   `<root>/server/web`:
   ```
   for root in /kvmapp /dev/shm/kvmapp; do
     mkdir -p $root/server/web.new && tar xzf /tmp/web-dist.tar.gz -C $root/server/web.new
     mv $root/server/web $root/server/web.old && mv $root/server/web.new $root/server/web
     rm -rf $root/server/web.old
   done
   ```
4. `systemctl restart nanokvm`, then verify as in step 4 above **plus** check
   the served bundle is the new one:
   `curl -sk https://127.0.0.1/ | grep -oE 'assets/index-[A-Za-z0-9_-]+\.js'`
   must print the hash from step 1.

# Variant: mini-display daemon (`nanokvm-display`)

Proven flow (2026-08-16, deploying the #20/#35 knob-latency + control-page
work). This one does NOT live in the `/kvmapp` trees — no dual-tree dance:

1. `nix build .#nanokvm-display` — output is
   `result/opt/nanokvm-display/{nanokvm_display.py,font_data.py}` plus the
   systemd units. `font_data.py` only changes if the font generation
   changed; usually only the daemon file needs shipping.
2. `tools/kvmscp result/opt/nanokvm-display/nanokvm_display.py /tmp/`, then
   `tools/kvmssh 'cp /tmp/nanokvm_display.py /opt/nanokvm-display/ &&
   systemctl restart nanokvm-display'`. `/opt` is the persistent rootfs —
   the copy survives reboot; new/changed units go to
   `/etc/systemd/system/` + `systemctl daemon-reload`.
3. Verify: `systemctl is-active nanokvm-display` and
   `journalctl -u nanokvm-display -n 5` — expect
   `input devices: ['gpio_keys', 'rotary@0']` and no `refresh failed`.
4. **Visual verification** (proves the daemon is actually drawing):
   `dd if=/dev/fb0 bs=110080 count=1` on the device, pull the dump, convert
   RGB565→PNG off-device with the orientation mapping
   `phys(x,y) = fb[319-x][y]` (script pattern: scratchpad `fb2png_all.py`
   from the 2026-08-16 session; PIL via
   `nix shell --impure --expr '(import <nixpkgs> {}).python3.withPackages
   (p: [p.pillow])'`) and view the image.
5. **Exercising the knob UI without hands on the device**: root can inject
   real input by writing `struct input_event` (`qqHHi`, zeroed timestamps)
   to the evdev nodes — EV_REL/REL_X/±1 + SYN to the `rotary@0` node for a
   twist, EV_KEY/28/1,0 + SYNs to the `gpio_keys` node for a press. Pair
   each injection with an fb dump to walk and screenshot every UI state.
   NEVER "test" the control page's final confirm press on the real device
   — it pulses the attached host's ATX power/reset lines (via
   `POST /api/vm/gpio`); firing real pulses is Jeremy's call.

# Failure modes

- **Silent crash-loop.** `nanokvm.service`'s `ExecStart` is a supervisor
  loop that restarts the server on crash but gives up (`exit 1`) after
  **3** crash-loops. If you restart the unit and move on without checking,
  a broken deploy can leave the device with no running server at all and no
  obvious signal that anything is wrong (`systemctl restart` itself
  reports success — it only starts the supervisor, not the server staying
  up). Always run the step-4 verification.

- **Works interactively, crash-loops under systemd.** If a rebuilt
  `libkvm.so` runs fine when you `LD_LIBRARY_PATH=... ./NanoKVM-Server` by
  hand over SSH but crash-loops as `nanokvm.service`, suspect the
  DT_RPATH-vs-DT_RUNPATH transitive-dependency trap: `libkvm` needs
  `DT_RPATH` (which is inherited by its own transitive dependencies, e.g.
  `libax_proton` → `libax_engine`), not `DT_RUNPATH` (searched only for a
  library's own direct deps). Under systemd there's no `LD_LIBRARY_PATH` or
  `ldconfig` entry to fall back on, so the transitive lookup fails with
  `libax_engine.so: cannot open shared object file`. This is already
  handled by `patchelf --force-rpath` in `pkgs/kvm-encoder.nix`
  (see the comment block there, and the "Load-bearing linker detail"
  paragraph under "Capture lifecycle & idle power-down" in
  `docs/architecture.md`) — do not re-investigate this from
  scratch; if it resurfaces, check that the patchelf step ran and that
  `readelf -d libkvm.so` shows `RPATH` (not `RUNPATH`).

# Variant: open-encoder test cycle (vc8000-vcmd + vcenc-ewl)

The iteration loop for open VC8000E encoder work (#25 family) — used
repeatedly and validated 2026-08-30. This swaps kernel modules, not app
files, so it is its own cycle:

**Since 2026-08-31 the SHIPPED default already loads the open VCMD driver**
(the curated loader insmods `ax630c_venc_vcmd.ko` instead of `ax_venc`/
`ax_jenc` — #25). So on a current-image device the swap below is usually a
no-op (vcmd already loaded, vendor venc/jenc already absent) — check
`lsmod | grep -E 'ax630c_venc_vcmd|ax_venc'` first. The rmmod/insmod dance
is only needed when testing a *rebuilt* `.ko` against a device still on an
old (vendor-encode) image. **Since #54 (2026-09-03) a flashed image carries no
vendor `.ko` at all** — `/soc/ko` holds only our three open modules and no
rollback loader ships, so the "restore vendor" branch below applies only to a
device flashed with the vendor `.axp` (the bench harness).

1. `nix build .#vcenc-ewl .#vc8000-vcmd`
2. `tools/kvmscp <ewl bin(s)> <.ko> /tmp/`
3. On the device (one `tools/kvmssh` invocation, so a failure mid-script
   still leaves you a shell to recover from). If the device is on an OLD
   vendor-encode image:
   `systemctl stop nanokvm && rmmod ax_jenc ax_venc && insmod /tmp/ax630c_venc_vcmd.ko`
   → run the test binary → restore vendor:
   `rmmod ax630c_venc_vcmd && insmod /soc/ko/ax_venc.ko && insmod /soc/ko/ax_jenc.ko && systemctl start nanokvm`.
   On a CURRENT-image device: `systemctl stop nanokvm && rmmod
   ax630c_venc_vcmd && insmod /tmp/ax630c_venc_vcmd.ko` → test →
   `rmmod ax630c_venc_vcmd && insmod /soc/ko/ax630c_venc_vcmd.ko &&
   systemctl start nanokvm` (swap the rebuilt .ko for the shipped one).
4. Pull outputs with `tools/kvmssh 'cat /tmp/out.h264' > local` and verify
   on the host (`ffmpeg -i out.h264 -frames:v 1 out.png`); never leave the
   device with nanokvm stopped.

   **md5-verify TEST binaries too, not just deployed app files** (cost a
   cycle 2026-08-31): the Bash tool resets cwd between calls, so a
   `nix build --out-link result-X` can land the fresh symlink in the WRONG
   directory while a stale `result-X` from an earlier session sits at the
   repo root — the scp then ships the old binary and the "fixed" test
   reproduces the old failure byte-identically. Always
   `md5sum result-X/bin/<tool>` locally + on-device before interpreting a
   test result.

Full bring-up rationale: docs/vcmd-cma-unblock.md ("Bring-up procedure").

**#50 (FIXED 2026-08-31, docs/blob-replacement.md "#50 FIXED"):** the openvenc
teardown-oops trap is fixed — `kvm_capture_open.c` no longer issues the AINR
nr138 ioctl that armed it, so a current `.#kvm-encoder-openvenc` build tears
down cleanly (graceful stop AND `kill -9`) with venc absent. Two things still
matter for openvenc test cycles:
- **Start from a clean boot.** The oops faulted before ax_proton nulled its
  global, so a prior nr138-issuing process (any pre-fix build, or one with
  `OPENKVM_NR138=1`) leaves it dangling and a later clean process inherits the
  crash. Reboot first; then only run no-nr138 builds.
- Still keep `echo 0 > /proc/sys/kernel/panic_on_oops` as a safety net when a
  build's provenance is uncertain; an oopsed task wedges `do_exit` and hangs
  later `systemctl stop` — reboot after any oops, never chain experiments.
- To reproduce the old crash deliberately, set `OPENKVM_NR138=1` in the server
  env. Standalone ewl_* runs never touch VIN and are always safe.

**tmpfs-wipe trap (cost a cycle 2026-08-31):** `nanokvm_pre.sh`
(`ExecStartPre`) unconditionally `rm -rf /dev/shm/kvmapp && cp -av /kvmapp
/dev/shm/kvmapp` on EVERY `systemctl start`/`restart` — so a `/dev/shm`-only
deploy is clobbered the moment you restart the unit. For a swap that must
survive a unit restart, deploy into `/kvmapp` too (persistent) so ExecStartPre
propagates it. A `/dev/shm`-only hot patch only sticks if you respawn the
server child WITHOUT a unit restart (e.g. `pkill NanoKVM-Server`, letting the
nanokvm.sh supervisor loop respawn it — ExecStartPre does not re-run).

**Variant: openvenc libkvm (fully blob-free video).** Build
`.#kvm-encoder-openvenc`; deploy libkvm.so/.so.0 into BOTH trees (stage+mv);
module swap as above (our ko replaces venc+jenc — coexistence is impossible,
vendor venc holds the VCMD MMIO + IRQ). Headless end-to-end verification of
the real web path: on-device
`curl -sk -X POST -d "mode=h264-direct" https://127.0.0.1/api/stream/mode`
(localhost bypasses auth) then `python3 tools/wsgrab.py out.h264 120 30`
(scp it over; stdlib-only) — it prints per-NAL type/size lines and writes a
decodable Annex-B stream; `grep -c libax /proc/$(pgrep NanoKVM-Server)/maps`
should read 0. MJPEG (soft-JPEG path, #51): `curl -sk --max-time 10
https://127.0.0.1/api/stream/mjpeg > /tmp/mj.bin`, count `\xff\xd8\xff` SOI
markers for fps (expect ~9 at 1080p q80), pull one frame and decode it
off-device; `[openvenc] MJPEG up:` must appear in
/var/log/nanokvm/NanoKVM-Server.log (the unit's stderr goes there, NOT to
journalctl). Restore = vendor libkvm back into both trees + vendor module
insmod + restart (or reboot, which restores modules via the boot loader).

# Variant: the shipped OPEN stack (V4L2 libkvm + three open modules, #60)

Since 2026-09-02 the image default is `.#kvm-encoder-v4l2` over the open
capture drivers: the loader insmods exactly `ax630c_venc_vcmd.ko`,
`open_vin_csi2.ko start_on_probe=1` and `open_vin_capture.ko` (carveout
params from `/run/openkvm-memmap.env`) and NO vendor `ax_*.ko` -- `lsmod |
grep -E '^ax_'` must print nothing on a healthy boot. Since #54 (2026-09-03)
the vendor blobs are not even on disk: `/soc/ko` holds exactly those three
modules, and no rollback loader ships. The #50 ax_proton caveats above apply
only to the bench-only `ax-load-drv.openvenc.sh` + `.#kvm-encoder-openvenc`
(the raw-ioctl replay backend), which need a device flashed with the vendor
`.axp` -- not to this stack.

Module iteration (validated 2026-09-02): `open_vin_capture.ko` is
reload-safe -- `systemctl stop nanokvm; rmmod open_vin_capture; insmod
/tmp/open_vin_capture.ko carveout_base=$OPENKVM_CAPTURE_BASE
carveout_size=$OPENKVM_CAPTURE_SIZE` (source the env file first) -- but
register STATE persists across a reload, so any test that depends on
reset-vs-programmed values (a golden-table change) needs a fresh boot.
`ax630c_venc_vcmd.ko` swaps the same way with `coherent_*`/`framebuf_*` from
the env. libkvm: stage+`mv` into both trees as above; success markers in
`/var/log/nanokvm/NanoKVM-Server.log` are `[openkvm-v4l2] capture up WxH ...
bus[0]=0x7c000000 (V4L2 + dma-buf, blob-free)` and `[openvenc] MJPEG up:`.
Bench-only geometry override: `systemctl set-environment
OPENKVM_FORCE_GEOM=1920x1080` before the restart makes libkvm capture a
top-left crop (the open driver's SIF window crops) -- the only way to drive
the 1920-wide H.264 path from the 4K-pinning bench source; `systemctl
unset-environment OPENKVM_FORCE_GEOM` afterwards. A ready-made run script
lives on the device at `/root/axbring/m3/h264run.sh` (uses `tools/wsgrab.py`).
