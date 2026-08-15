---
name: deploy-iterate
description: Build a component with Nix and hot-deploy it to the running NanoKVM-Pro device for fast iteration, then verify the service came back up.
---

Validated 2026-08-15 for the **web-bundle** variant (build → tar → both
trees → restart → HTTP 200 with the new bundle hash). The libkvm variant
below follows the same shape but has not itself been exercised via this
skill yet.

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
