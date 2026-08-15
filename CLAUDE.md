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
  commit, or tag on GitHub. Releases: bump `VERSION`, push, `tools/release`
  (tags on Gitea; the mirror + GitHub Actions do the rest — docs/updates.md).
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
- The device must run `nanokvm.service`, not the vendor `kvmcomm.service`, or the web
  UI is down — `docs/architecture.md` ("The two app stacks").
- The app tree is copied to tmpfs at boot: hot patches must land in BOTH `/kvmapp`
  and `/dev/shm/kvmapp` — see the deploy-iterate skill.

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
| SG2002 project (dormant) | `docs/plan-sg2002-research.md` |

## Working with Jeremy

- Concise, confident prose — no hedging, no over-explaining (applies to docs, READMEs,
  commit messages).
- On hardware: prefer the reversible method first, even if it's "only short-term";
  ask before irreversible/destructive operations.
- Prefer re-implementing against documented/open APIs over reverse-engineering a
  vendor-internal seam.
- Record findings and rationale even for rejected paths, so decisions can be revisited.
- Questions get direct answers before (or instead of) action.
- Delegate to subagents with an explicit `model: opus` or `model: sonnet` override
  wherever the task allows it (searching, mining, bulk writing, verification); don't
  let subagents inherit a Fable/Mythos-tier session model.
- After substantial work, run the reflect skill.
