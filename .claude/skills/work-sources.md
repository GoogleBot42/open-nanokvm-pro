# Work sources for open-nanokvm-pro

Shared reference for the `fetch-work`, `unblock`, and `reflect` skills. Not a
skill itself — just the ranked list of places candidate work comes from, and
the known inconsistencies to account for when proposing any of it.

Two projects live here:

- This repo — **active.** From-source NanoKVM-Pro (AX630C) firmware,
  a Nix flake. Git remote is Gitea: `zuckerberg/open-nanokvm-pro` on
  `git.neet.dev`, the user's forge, worked via the `tea` CLI (see the
  user-level `git-forges` skill).
- `docs/plan-sg2002-research.md` — **dormant, research-only.** SG2002 NanoKVM
  from-source rebuild. Deferred, not abandoned; see below.

## 1. Gitea issues (primary live source, check this first)

`tea login list` shows one login, `neet` (`https://git.neet.dev`), default,
authenticated as bot user `agent` — confirmed working.

```sh
tea issues list --repo zuckerberg/open-nanokvm-pro
```

As of this writing there are **30 open issues, 0 closed** (indices 7–36;
1–6 don't exist — nothing to worry about, just historical numbering). All
were filed by either `agent` (26 of them) or the user `zuckerberg` directly
(the newest four: #33–#36, feature requests not covered by any doc or
script).

Label taxonomy already in place — filter on these:

| Label | Meaning |
|---|---|
| `bug`, `enhancement`, `documentation`, `security` | kind |
| `blob-replacement` | part of the from-source/blob-removal effort |
| `hardware-validation` | needs verification on real hardware |
| `needs-human` | needs physical hardware, an owner decision, infra, or key custody — **the filter the `unblock` skill uses** |
| `priority/high`, `priority/medium`, `priority/low` | queue order |
| `good first issue`, `help wanted`, `question`, `duplicate`, `invalid`, `wontfix` | defined but unused so far |

Useful filtered pulls:

```sh
tea issues list --repo zuckerberg/open-nanokvm-pro --labels needs-human
tea issues list --repo zuckerberg/open-nanokvm-pro --labels priority/high
```

(A stale `file-issues.sh` seed script once existed — it
targeted GitHub via `gh` and its ~26 issues were long since filed on Gitea as
issues #9–#34. Deleted 2026-08-15 on Jeremy's instruction; the Gitea issues
are the only source of truth.)

## 2. Hardware-validation TODOs recorded in docs

Scanned `docs/{updates,mini-display,architecture,blob-replacement}.md`
for pending/TODO/unverified markers still present in the tree:

- **`docs/updates.md`, "Hardware validation TODO" callout (around line
  163–167):** the SPL→U-Boot A/B slot-B failover path has been reasoned
  from source but **not yet exercised on hardware** — "treat dual-slot
  writes as belt-and-suspenders, not a proven rollback guarantee." Mirrors
  Gitea issue #10 (`hardware-validation`, `needs-human`, `priority/high`).
- **`docs/mini-display.md`, "Hardware verification" section (lines
  195–230):** verified off-device (vermagic + symbol-table match against
  the vendor `.ko`, plus a synthetic-evdev daemon harness including the
  sleep/wake cycle) but the **final on-device boot test is pending** —
  watching `fb_jd9853 frame buffer, 172x320` actually appear and the panel
  light up. Notes a prior swap-in-place attempt hard-hung the dev unit on
  vendor module *unload* (not load), so the safe path is testing at boot,
  not live-swapping on stock firmware. Mirrors issue #11.
- **`docs/blob-replacement.md`:** the RE narrative log for de-blobbing
  capture/encode. The `openCapture` flag (`pkgs/kvm-encoder.nix`, default
  **off**) landed and was **device-validated 2026-07-21** for the capture
  half (real decodable 1080p H.264, teardown+re-init both clean). The
  **encoder is explicitly called out as the remaining blob gate** (near the
  end of the file): the open build still links `libax_venc`/`sys`/`ivps`/
  `proton` because the closed encoder pins them; only `libax_mipi` was
  dropped. Matches the epic issue #25 ("blob-free video encoder — port the
  open VC8000E VCMD driver"). Known residuals noted in the same doc:
  1080p-only payloads (issue #17), hardcoded `ISP_MODEL_PHYS` and an
  unfreed CMM carveout on teardown (issue #16).
- **`docs/architecture.md`:** no pending/TODO/unverified markers found in
  this scan — it currently reads as settled. Don't assume that stays true;
  re-grep before trusting it stale.

A claim that is **not** in the docs but recorded in memory (see below) and
worth surfacing when relevant: idle video power-down
(`kvmv_video_suspend`/`resume`, commit `bfa823e`) is code-complete but has
**never been run on device** — the underlying teardown/re-init mechanism is
device-proven (via the Stage-6 capture validation), but the Go-server idle
watcher and display integration around it are not. Verify this is still
true against the current tree before relying on it; it's a memory claim,
not a doc claim.

## 3. Memory dir (transient session state)

`/home/googlebot/.claude/projects/-home-googlebot-workspace-nanokvm-nix-nanokvm-pro/memory/`

Contains `MEMORY.md` (the index) plus four project memory files:
`nanokvm-nix-rebuild-project.md` (SG2002), `nanokvm-pro-blob-audit.md`,
`nanokvm-pro-runtime-stack.md`, `nanokvm-pro-ota-updates.md`. These carry
day-to-day findings that haven't necessarily been codified into docs yet —
check them for recent context, but see the inconsistency below:
`nanokvm-pro-ota-updates.md` is itself stale (still describes a "push to
GitHub, no `gh` CLI in this env, repo not yet pushed" state) even though the
project has since fully moved to Gitea with 30 issues already filed
there. A `reflect` pass should reconcile or prune this file.

## 4. Dormant SG2002 project

`docs/plan-sg2002-research.md` (~52KB). Latest dated entries are 2026-07-18; the
user's priority decision ("Pro first") deferred — not abandoned — the SG2002
flake in favor of the Pro rebuild, which is where all subsequent work went.
Nothing else in this repo touches SG2002.

Resuming it starts with **packaging a T-Head C906 GCC toolchain**: the
target needs `-mcpu=c906fdv -march=rv64imafdcv0p7xthead -mcmodel=medany
-mabi=lp64d` with musl libc, and stock nixpkgs GCC lacks the `xtheadv0p7`
vector extension (per memory `nanokvm-nix-rebuild-project.md`). Don't
propose SG2002 work without flagging this gap up front.

## 5. Known inconsistencies awaiting work

- **GitHub-vs-Gitea split in the release/OTA pipeline.** The forge is
  Gitea-only (`zuckerberg/open-nanokvm-pro`, confirmed via `tea repos
  list`; `tea releases list --repo zuckerberg/open-nanokvm-pro` returns
  zero releases), but:
  - `flake.nix` line 60 hardcodes
    `updateBaseUrl = "https://github.com/GoogleBot42/open-nanokvm-pro/releases/latest/download"`.
  - `docs/updates.md` lines 51–56 instruct the reader to
    create a **GitHub** repo at `GoogleBot42/open-nanokvm-pro` and bake that
    URL in.
  - `.github/workflows/release.yml` is a GitHub Actions
    workflow start to finish (`gh` CLI, `github.token`,
    `softprops/action-gh-release`) — it does not run on Gitea, and there is
    no Gitea Actions workflow anywhere in the tree. So right now there is
    **no working CI/release path at all** on the actual forge.
  - Migration to Gitea releases (new workflow or manual `tea` release
    flow, plus repointing `updateBaseUrl`) is pending and not tracked by
    any single filed issue as of this scan — worth filing one before
    picking up related work.
- **Version scheme mismatch.** `VERSION` currently reads
  `0.0.5` (a local/dev value), while `docs/updates.md` lines 213–214
  documents a scheme where the *release* line should start at `2.0.0` (so
  it's unambiguously newer than the vendor's `1.2.x`). Since no release has
  ever been cut (`tea releases list` is empty), this hasn't caused a
  problem yet, but it needs reconciling before the first tag — don't file
  or ship a release without checking this first.
