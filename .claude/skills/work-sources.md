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

Issue indices run from #1 (early seed issues #1–#8 included; #1 and #6 look
like duplicate "auto update" asks). Filed by the bot `agent` or by
`zuckerberg` directly. Don't trust any cached count — pull the live list.

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
- **Issue #42 (2026-08-17, `needs-human`): USB HID to the host is dead** —
  ep0 enumeration failure; every software remedy exhausted (ladder in the
  kvm-device skill), and the 2026-08-17 cold power cycle changed nothing —
  KVM-side PHY exonerated, fault is the physical link. Blocked on Jeremy:
  cable SWAP (not replug), different host port, host dmesg. Until
  resolved, keyboard/mouse via the web KVM does not work; video is
  unaffected.
- **`docs/mini-display.md`, "Hardware verification" section:** RESOLVED
  2026-08-15 — the from-source stack was proven end-to-end on the device
  running v2.0.0 (modules at boot, fb registration, daemon drawing, idle
  blank + knob-press wake; fb dump rendered legibly off-device). Issue #11
  closed. Durable trap retained in the doc: never unload/live-swap
  `fb_jd9853` — teardown deadlock hard-hangs the device; test at boot.
- **`docs/blob-replacement.md`:** the RE narrative log for de-blobbing
  capture/encode. The `openCapture` flag (`pkgs/kvm-encoder.nix`, default
  **off**) landed and was **device-validated 2026-07-21** for the capture
  half (real decodable 1080p H.264, teardown+re-init both clean). The
  **encoder is explicitly called out as the remaining blob gate** (near the
  end of the file): the open build still links `libax_venc`/`sys`/`ivps`/
  `proton` because the closed encoder pins them; only `libax_mipi` was
  dropped. Matches the epic issue #25 ("blob-free video encoder — port the
  open VC8000E VCMD driver"). Issue #17 (1080p-only payloads) implemented
  2026-08-17: geometry is now parametric (`kvm_capture_geom.c`), guarded by
  a mechanical 1080p byte-identity check (`nix build
  .#checks.<system>.open-capture-geometry`); **non-1080p is still untested
  on hardware — needs a non-1080p source**. Issue #16 (isp_model phys
  derivation, teardown validation, pool-block leak) was closed 2026-08-16
  with on-device warm suspend/resume validation. 2026-08-17: the first
  real-use bugs of the open backend (frame-phys off by the pool's meta
  pages → green bar + horizontal scroll; web-UI fps=0 wedging VENC
  rebuilds → black screen on refresh; 120 Hz retry storms) were fixed,
  device-verified, and released as v2.1.0-alpha.2 (commit 26ce865; doc
  section "2026-08-17" in blob-replacement.md). Follow-ups resolved
  2026-08-17: #41 (log rotation) fixed in e485d02 + hot on device; #40
  root-caused as a deploy-tooling artifact (cp onto the mapped .so zapped
  the GOT — not a firmware bug; hardening + skill fix in b95c8ba). #43
  (wifi.service crash loop) FIXED + CLOSED 2026-08-17: Restart=no drop-in
  via rootfs + OTA (97507e3), hot-applied and verified on device. #39
  (module curation) DONE + CLOSED 2026-08-17: curated 12-of-22 loader
  shipped (a553f55), device-proven over 3 warm reboots; keep/drop table in
  blob-replacement.md ("Module curation"); cold-cycle datapoint rides #42.
  2026-08-22: the ENCODER line advanced substantially. §8 device-tracing
  complete (items 1–5): VCMD ABI hardware-confirmed 1:1 with the public
  driver, hw_version_id/AsicConfig pinned, CBR rate control characterized as
  stock VCEnc one-pass RC. A device-grounded feasibility study of a fully-open
  VCEnc reimpl returned **GO for H.264 (medium-high)** (docs stages
  "2026-08-22 …" + reference data in `docs/reference/vcenc-open/`). Epic #25
  broken into children: **#44** (port the open VCMD kernel driver — the first
  buildable step, priority/high), **#45** (EWL/CMM glue), **#46** (from-scratch
  CBR controller), **#47** (VCEnc-core licensing decision — `needs-human`, the
  gate on whether "fully blob-free" is the target). Also this
  session: **#27** (kernel initramfs rebuild) reprioritized priority/low →
  **priority/high** per Jeremy (high priority for his blob-free goals).
  2026-08-23: **Stages 0 and 1 both done** (docs stages "2026-08-23 …",
  data under `docs/reference/vcenc-open/stage0|stage1/`). Stage 0 closed the
  old "main gap" — P-frame/DPB register state is now decoded (swreg18/19 =
  prev-frame recon; IDR WREG order + kick swreg5 pinned). **Stage 1 PoC
  ACHIEVED on hardware:** an open, externally-supplied VC8000E register
  program drives the encoder to a decodable, QP-controllable 1080p IDR (via a
  LINK-time cmdbuf hijack — the effective-QP control surface is swreg7/37/
  105–107/125–132). The register-program half of a from-source encoder is
  proven; remaining encoder work is submission (#44/#45) + program generation
  (#46/#47). Note: a fully-blob-free raw-ioctl submit hits the vendor `.ko`'s
  nr70/nr83 EFAULT seam — that's #44's job, not a bug. Path B (the hijack) is
  now a validated on-hardware test harness for candidate open programs.
- **`docs/architecture.md`:** no pending/TODO/unverified markers found in
  this scan — it currently reads as settled. Don't assume that stays true;
  re-grep before trusting it stale.

Idle video power-down (`kvmv_video_suspend`/`resume`, commit `bfa823e`):
**fully observed live on device 2026-08-15** — suspend engages when idle
(mini-display reads "video asleep (power save)") and resume-on-viewer
worked in real use (Jeremy opened the web KVM from the suspended state;
video and HID both functional). No longer a pending validation item.

## 3. Memory dir (transient session state)

`/home/googlebot/.claude/projects/-home-googlebot-workspace-nanokvm-nix-nanokvm-pro/memory/`

Contains `MEMORY.md` (the index) plus four project memory files:
`nanokvm-nix-rebuild-project.md` (SG2002), `nanokvm-pro-blob-audit.md`,
`nanokvm-pro-runtime-stack.md`, `nanokvm-pro-ota-updates.md`. These carry
day-to-day findings that haven't necessarily been codified into docs yet —
check them for recent context. (All four were reconciled against the tree
as of 2026-08-15; no known staleness.)

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

- **Preview/alpha update channel: LIVE + pipeline-proven (issues #19 + #4
  closed 2026-08-16).** Alpha = any `-suffix` semver version via
  cut-release; publishes as a GitHub prerelease + refreshes the rolling
  `preview` release the web-UI toggle polls. Proven by the real
  v2.1.0-alpha.1 cut (openCapture build): prerelease flag set, rolling
  `preview` release refreshed (manifest 2.1.0-alpha.1 + payload,
  hash-verified bit-exact), stable channel untouched (still 2.0.0).
- **Release pipeline: LIVE (issue #37 closed 2026-08-15).** Gitea source
  of truth → push mirror → public GitHub downstream mirror
  (GoogleBot42/open-nanokvm-pro) hosts releases and runs the tag-triggered
  release workflow. v2.0.0 published, verified, and APPLIED on the device
  (2026-08-16) — the full-firmware OTA path incl. partition writes +
  reboot is hardware-proven. A/B *failover* is still unexercised (#10).
  Releases are cut via the `cut-release` workflow in the Gitea web UI
  (dry-run-tested; `tools/release` = fallback). Never propose
  pushing/tagging on GitHub directly; see `docs/updates.md`.
