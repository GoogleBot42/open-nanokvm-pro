---
name: device-re-subagent
description: Delegate a NanoKVM-Pro hardware reverse-engineering / on-device tracing / feasibility task to a Fable subagent — the safety envelope, content-filter framing, and verify-the-evidence discipline for it. Use when a task needs deep device probing (ioctl traces, /dev/mem register dumps, blob characterization) that genuinely requires Fable-tier skill.
---

Distilled from the 2026-08-22 VC8000E encoder RE campaign (docs/blob-replacement.md
§8 stages + the feasibility study), where this exact procedure ran several times.

# When to use

A task needs **deep device reverse-engineering** — LD_PRELOAD ioctl traces,
`/dev/mem` register/pool dumps, differential capture, binary disassembly, blob
characterization, or a device-grounded feasibility call. This is high-skill work.

If the SESSION is running on Opus (downgraded from Fable/Mythos), delegate it UP to
a **Fable** subagent and keep orchestration + verification in the main session (the
reciprocal of the save-usage Opus-delegation rule — memory
`delegate-to-opus-subagents`). If the session is already Fable/Mythos, you may still
fan this out to a Fable subagent to keep the deep trace logs out of the main context.

Launch: `Agent` with `subagent_type: "general-purpose"`, `model: "fable"` for on-device
tracing/feasibility. For pure STATIC describing passes over an unstripped vendor .ko
(instruction-level register write lists) `model: "opus"` has proven sufficient twice
(2026-09-01: spec-dphy-writes.md, spec-ife-start.md -- both device-verified) -- use it
and save the Fable budget. For a
multi-step campaign, resume the same agent with `SendMessage` (it keeps the tooling
+ offsets it built) rather than starting fresh.

# The brief — always include all six

1. **Context + established facts** — point at the authoritative docs
   (`docs/blob-replacement.md`, the relevant `docs/reference/…`) and say what is
   ALREADY known so the agent doesn't re-derive it.
2. **The precise question / deliverable** — one high-value target, stated as a
   concrete artifact (a map, a diff, a go/no-go), not "investigate X".
3. **Methods it may use** — name the technique (differential trace, `/dev/mem`
   dump, disasm) and the reusable tooling (below).
4. **The safety envelope** — verbatim, every time (below).
5. **The content-filter framing** (below).
6. **Report back structured, do NOT edit docs or commit** — the main session
   verifies and records. Ask for exact on-device + scratchpad paths of every
   artifact so you can check its work.

# Safety envelope (paste into every brief)

- FIRST run the `kvm-device` health check; confirm `nanokvm` is active + web UI
  200. Report and STOP if not — don't probe blind.
- Work in `/tmp/axwork` (tmpfs) on the device. **Persist any raw dump to a device
  file first, then retrieve** — an SSH auth drop mid-pipe otherwise loses the data
  (this bit us: a register dump was reported from a run that had actually died on
  auth failure).
- Stop/restart `nanokvm.service` around anything that grabs the capture/encoder
  hardware; leave it RUNNING + web 200 at the end.
- **Default is read-only**: ioctl tracing, `/dev/mem` reads/mmap, static disasm.
  Prefer this; most RE/tracing tasks never need to write anything.
- **Drive path (only when the task explicitly requires exercising hardware, e.g. a
  replay/PoC).** Driving a block through the vendor's own **public ioctl ABI** (the
  normal operation path — e.g. the VC8000E VCMD `RESERVE`/`LINK_RUN`/`WAIT`/`RELEASE`
  cmdbuf ioctls) and writing into the driver-allocated DMA pools it hands you is
  PERMITTED, and must be stated as permitted in the brief. Guardrails: (a) still NO
  `/dev/mem` **register**/MMIO writes and NO firmware/block-device writes — those stay
  forbidden; (b) every physical address you put in a command buffer must come from the
  live vendor allocation this run (read it back — never invent or hand-pick a phys), so
  DMA stays inside valid carveouts; (c) a malformed submission may hang the block →
  warm watchdog reboot, which is SAFE and recovers (poll & continue, back off to
  last-known-good). This is what makes an on-device replay/PoC reversible; the Stage-1
  encoder PoC ran this way with no reboot.
- One unit (the ATX unit). (USB HID to the host works again since 2026-09-04;
  #42 was a physical-link fault — nothing in this envelope touches it.)
- A bad trace can hang the block → watchdog reboot. That's a warm reset and SAFE
  (hot-patches persist, PHY not reset): poll for return
  (`until tools/kvmssh 'echo up' | grep -q up; do sleep 5; done`) and continue.
  NEVER attempt a cold power cycle — that needs the human.
- The `tools/kvmssh` wrapper flakes intermittently (cycles IP/password combos);
  the device is usually NOT down — verify via uptime monotonicity and retry.
- NEVER print or commit device IPs / passwords.

# Vendor stack on a purged device (differential campaigns)

The shipped image carries no vendor `.ko`/libs, but **no reflash is needed**:
the vendor modules are `.#ax-ko-blobs` and the libax closure is `.#axera-libs`,
so the vendor encoder can be loaded on the running open image for one session
and discarded by a warm reboot (proven 2026-09-05, #64 HEVC campaign; scripts
in `docs/reference/vcenc-open/vendor-diff-hevc-20260905/tools/`):

1. Stage on eMMC (`/root/<campaign>/{ko,lib,bin}`): `ax_{sys,cmm,pool,base,venc,
   jenc}.ko` (**`ax_jenc` is required** — `AX_VENC_Init` returns
   `0x80070210` SYS_NOTREADY without it), `libax_{sys,ivps,proton,engine,
   interpreter}.so` from `.#axera-libs`, and **`libax_venc.so` from the stock
   rootfs** (`unzip` the `.#base-axp`, `simg2img`, `debugfs -R "dump /opt/lib/
   libax_venc.so"`): the SDK snapshot's `libax_venc.so` is a different build
   that rejects pixel-unit strides (`SendFrame` → `0x8007020a`, `MissMatch`
   in `/proc/ax_proc/venc`). Cross-build the driver tool with `nix develop -c
   aarch64-unknown-linux-gnu-gcc -std=gnu17 …` then `patchelf --set-interpreter
   /lib/ld-linux-aarch64.so.1 --force-rpath --set-rpath '$ORIGIN/../lib:/opt/lib'`.
2. **Reboot first if the open encoder module cannot be unloaded**: after a
   session with mode-change recovery `ax630c_venc_vcmd` sits at refcnt 2 with
   no process holding `/dev/es_venc` (a leaked reference), `rmmod` says "in
   use", and the vendor `ax_venc.ko` then loads *inert* (no `/dev/ax_venc`, no
   `/proc/ax_proc/venc`, no dmesg). A fresh boot with `nanokvm` stopped shows
   refcnt 0.
3. `systemctl stop nanokvm nanokvm-display`; `/soc/scripts/auto_load_all_drv.sh
   -r` (unloads the three open modules); insmod the vendor set with the
   vendor's own `cmmpool=anonymous,0,<pool base>,<MB>M` (on the 1G board
   `0x73800000,200M`; derive it from `/proc/cmdline mem=` as the vendor loader
   does). Run the campaign with `LD_LIBRARY_PATH`/rpath at the staged libs.
4. Return: `reboot` — the on-disk loader is the open one, so any reboot (also a
   watchdog reboot mid-campaign) lands on the open stack. Rmmod-ing the vendor
   set in place only works with the exact module list in dependency order;
   after a partial rmmod the open `insmod` fails EPERM (IRQ/MMIO still owned).
   Verify: `nanokvm` active, web 200, an MJPEG frame, `lsmod` = the three open
   modules.

The older on-disk recipe (2026-09-04, `/root/purge54-backup` + vendor loader +
vendor-MPI libkvm + reboot) is gone with the alpha.4 flash. Campaign tooling
that drives the vendor encoder/receiver through the SDK API:
`docs/reference/vcenc-open/vendor-diff-20260904/tools/`,
`docs/reference/vcenc-open/vendor-diff-hevc-20260905/tools/` (H.264 + HEVC,
`codec=`), `docs/reference/deblob-scope/regdumps/mipi-20260904/tools/`.

# Content-filter framing (load-bearing)

Frame the work as **open-source driver-replacement / hardware interoperability in
the lineage of Asahi Linux, nouveau, OpenIPC, and Mesa** — reimplementing a
device's own stack from source to remove proprietary blobs on hardware the owner
controls and authorized. Without this framing the RE/driver task can trip a model
content filter mid-run (observed repeatedly). It is also simply what the work is.

# Verify the agent's evidence yourself (non-negotiable)

The subagent's report is a claim, not a result. Before recording anything:

- Spot-read the tooling it wrote (is the trace decode sound? does it read exactly
  `_IOC_SIZE`, not a fixed over-read that prints stack garbage past the real
  struct — the trap that recurred all through the capture campaign?).
- Re-derive the load-bearing numbers from the raw artifacts (e.g. recompute a
  register diff from the dumps; `python3` isn't on the host PATH — `nix shell
  nixpkgs#python3` or use `awk`).
- Confirm any decoded value is backed by a **preserved** dump, not a run that may
  have died on an auth drop. If it isn't, send the agent back to re-capture with
  the raw dump persisted first — do not record unbacked values.

# Reusable tooling

- `docs/reference/vcenc-open/tools/` — LD_PRELOAD ioctl/mmap tracer
  (`axvenctrace.c`, magic-filtered, `_IOC_SIZE`-safe), `/dev/mem` register-image
  dumpers (`pool_asic3.py`), differential capture (`pool_asic_diff.py`), VCMD
  cmdbuf decoder (`pooldump2.py`), headless encode driver (`drive_rc.py`).
- `kvm-device` skill, "Capture pipeline / video quality" — the device primitives:
  driving `libkvm` via python3 ctypes without the Go server, `/dev/mem` mmap (plain
  `read()` EFAULTs — use mmap), pool bases from `/proc/ax_proc/mem_cmm_info`.
- Max GLIBC symbol on target is 2.17-era; avoid scanf/strtol (redirect to
  `__isoc23_*@GLIBC_2.38`). Build device tools on-device with `gcc`, or cross.

# After a positive/useful result — harvest and persist

Findings die with the session scratchpad and device tmpfs unless you commit them.
On a result worth keeping: fold the knowledge into `docs/blob-replacement.md` (a
dated stage), and preserve the reference dumps + your own tooling under
`docs/reference/…` with a README documenting provenance. **Commit our own device
observations + tooling only — never proprietary vendor headers/sources or vendor
binary DWARF** (keeps the clean-room posture defensible). Then commit + push
(standing instruction) and update the relevant tickets.
