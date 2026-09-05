# open-nanokvm-pro

From-source Nix rebuild of the Sipeed NanoKVM-Pro (AX630C) firmware. Start with
`README.md` (build/flash quick start); the `docs/` tree is authoritative and kept
current. Unmodified upstream Sipeed clones live at `../NanoKVM` and `../NanoKVM-Pro`
(reference only, never edit).

A second, DORMANT project shares this history: a from-source SG2002 NanoKVM rebuild,
not started, blocked on packaging a T-Head C906 GCC. Its frozen research log is
`docs/plan-sg2002-research.md` (last substantive entry 2026-07-18 — also covers early
Pro reverse-engineering; current Pro truth is `docs/` and git history, not that log).

## Git

- The source of truth is Gitea: `gitea@git.neet.dev:zuckerberg/open-nanokvm-pro.git`.
  `github.com/GoogleBot42/open-nanokvm-pro` is a **read-only public downstream
  mirror** (release hosting + Actions release builds only) — never push,
  commit, or tag on GitHub. Releases: write the `CHANGELOG.md` section first
  (mandatory), then Gitea web UI → Actions → `cut-release`
  with a version input (`tools/release` is the local fallback); the mirror +
  GitHub Actions do the rest — docs/updates.md.
- **Commit as you work; push after committing.** Never let finished work sit
  uncommitted or unpushed. (Standing instruction from Jeremy; a Stop hook also checks.)
- This repo pushes directly to `main` (Jeremy's explicit instruction, 2026-08-15) —
  an exception to the git-forges skill's general PR-only rule.
- Never commit device IPs, passwords, or other credentials.

## Traps that cost real debugging time (details in docs — don't re-derive)

- `libkvm.so` needs `patchelf --force-rpath` (DT_RPATH, not DT_RUNPATH); a binary that
  works from an SSH shell but crash-loops under systemd is this. See
  `docs/architecture.md` ("Load-bearing linker detail") and `pkgs/kvm-encoder.nix`.
- Vendor `ax_*.ko` modules require an exact vermagic match — `docs/building.md`.
  And vermagic match is NOT ABI safety: config flags can add `#ifdef` fields to
  core structs the blobs touch (CONFIG_DMA_CMA → `struct device.cma_area`;
  CONFIG_CMA → migratetype renumber → `struct zone`) and kill boot when the
  blobs load — audit struct layout per flag. Proven the hard way in #49:
  `docs/vcmd-cma-unblock.md`.
- The device must run `nanokvm.service`, not the vendor `kvmcomm.service`, or the web
  UI is down — `docs/architecture.md` ("The two app stacks").
- The app tree is copied to tmpfs at boot: hot patches must land in BOTH `/kvmapp`
  and `/dev/shm/kvmapp` — see the deploy-iterate skill.
- #50 (FIXED 2026-08-31, closed): a process that brought VIN up and then dies
  oopsed vendor `ax_proton.ko` in `vin_model_manager_deinit+0x44` — but the real
  trigger was **our own** capture replay issuing AINR ioctl `0xc008708a` (proton
  nr138), which `kmalloc`s a `model_manager` whose garbage slot array the teardown
  walks. `ax_venc` presence only masked it data-dependently; it was never a venc
  registration. Fix: `kvm_capture_open.c` gates nr138 behind `getenv("OPENKVM_NR138")`
  (unset in prod) → `model_manager` stays NULL → deinit no-ops. Set `OPENKVM_NR138=1`
  to reproduce the old crash. Caveat: the oops faults before the NULL-store, so a
  crashed nr138 process leaves the global dangling — the fix is clean only from a
  boot where nobody issued nr138. Full analysis + hardware proof: `docs/blob-replacement.md`
  ("#50 FIXED"). `panic_on_oops=1` still turns any oops into a hard reboot, and an
  oopsed task still wedges later `systemctl stop` until reboot.
- "ATX reset works but power doesn't" = the SW_PWR pinmux trap: sysfs GPIO export
  never programs the mux, gpio7 lives on the VI_D7 pad (mux reg `0x02300060`), and
  capture init re-muxes it — the server re-asserts it per press. A GPIO `value`
  read only echoes the output latch, it proves nothing about the ball. Details:
  `docs/mini-display.md` ("The SW_PWR pinmux trap").
- A register-image "golden table" captured from `/dev/mem` must carry the vendor's
  **zero-valued** config words too, or the open driver silently keeps reset values
  (WDMA `0x142f8` = 4 at reset, vendor writes 0 → every pixel word came out `<<4`;
  #59, 2026-09-02). Validate a replay by diffing the open driver's *own* streaming
  register file against the vendor's — `docs/reference/deblob-scope/regdumps/geom/`.
- On an open (base-only) boot the MM/VPP domain is unclocked: **reading `0x04403000`
  (the vendor's rst1 "hold" register block) hangs the AXI bus → watchdog reboot** —
  proven 2026-09-01. Only ax_vpp/production clocks it. And glibc `memset`/`memcpy` on a
  `/dev/mem` mapping SIGBUSes (DC ZVA on Device memory): use word loops. Details:
  `docs/reference/deblob-scope/regdumps/README.md`.
- A bare `platform_device_register_simple()` device on arm64 4.19 gets `dummy_dma_ops`
  (`dma_supported` = 0), so `dma_coerce_mask_and_coherent()` FAILS silently and the
  coherent mask stays 0 (WARN at every `dma_alloc_attrs`). Set `dev.coherent_dma_mask`
  / `dev.dma_mask` directly when the device only uses a declared carveout (#63).
- Deleting from the vendor ext4 with `debugfs`: `ls -p` also lists **ghost (deleted)
  directory entries with inode 0** — filter `$2 != "0"` in every enumeration and
  post-purge count, or the "still present" assertion trips on entries that are not
  files (#54, cost a rebuild). Pattern + helpers: `pkgs/rootfs.nix` step 5d2.

## Hardware tripwires

- eMMC is `/dev/mmcblk0`; the SD card is `/dev/mmcblk1`. **Never write mmcblk0 during
  SD-card testing.** (Deliberate duplication with `docs/flashing-and-recovery.md` — keep both.)
- Hash-verify every firmware/block-device write; drop caches on the device before the
  read-back or you verify the page cache, not the medium.
- U-Boot has `bootdelay=0`: no autoboot interrupt window even over serial. A bad
  boot-chain flash means physical AXDL recovery — which Jeremy has tested and works,
  so bricking is not a concern, but it needs his hands on the device.

## Device access

Use `tools/kvmssh` / `tools/kvmscp`; credentials live in `~/.config/nanokvm/device.env`
(untracked). See the kvm-device skill.

## Docs index — read before working on X

| Task | Read first |
|---|---|
| Anything architectural (boot chain, pipeline, services) | `docs/architecture.md` |
| Building components / hashes / vermagic | `docs/building.md` |
| Flashing, backup, recovery, SD boot | `docs/flashing-and-recovery.md` |
| OTA / releases / versioning | `docs/updates.md` |
| Blob or network-endpoint questions | `docs/provenance.md` |
| Mini-display | `docs/mini-display.md` |
| Capture-pipeline internals / RE history | `docs/blob-replacement.md` |
| Full deblob epic (#55): capture-stack replacement plan + scoping | `docs/deblob-capture.md` |
| Open-encoder driver bring-up / #49 resolution (CMA = blob ABI break; no-flash coherent carveout) | `docs/vcmd-cma-unblock.md` |
| Slot-B kernel boot-testing (proven A/B harness) | `docs/flashing-and-recovery.md` |
| Pure-Nix / NixOS rootfs (feasibility + scaffold, #26) | `docs/nixos-rootfs.md` |
| SG2002 project (dormant) | `docs/plan-sg2002-research.md` |

## Working with Jeremy

- **Blob policy (2026-09-04):** the aic8800 wireless *firmware* is the only closed
  content allowed on the image. No closed userspace, no closed `.ko`, ever. NixOS
  goes **straight to mainline** (no 4.19 NixOS stage; the custom A/B scheme dies with it).
- Concise, confident prose — no hedging, no over-explaining (applies to docs, READMEs,
  commit messages).
- On hardware: prefer the reversible method first, even if it's "only short-term";
  ask before irreversible/destructive operations.
- Prefer re-implementing against documented/open APIs over reverse-engineering a
  vendor-internal seam.
- **Clean-room RE (hard requirement, 2026-08-30):** all RE of vendor binaries
  goes through *describing* subagents that emit behavioral specs; drivers are
  written from the spec only, never from vendor code/disassembly directly.
  On-device observation (register snapshots, traces) is unrestricted.
- Record findings and rationale even for rejected paths, so decisions can be revisited.
- Questions get direct answers before (or instead of) action.
- Delegate aggressively to `model: opus` subagents to save usage — searching, mining,
  bulk writing, analysis, verification, anything that doesn't truly need the session
  model. Reserve Fable/Mythos-tier work for what genuinely requires it; never let
  subagents inherit the session model. Always check the agent's work yourself
  (spot-read the code paths it cites, verify its claims) before acting on it.
- After substantial work, run the reflect skill.
