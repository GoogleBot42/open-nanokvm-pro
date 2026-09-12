---
name: campaign
description: Run a multi-item work campaign on this repo as a coordinator — one Opus subagent per item in its own worktree, the single test device serialized by hand-off, every branch verified before it is merged, long-context agents retired through a written handoff. Use whenever more than one issue is being worked at once, or one issue needs more than ~6 hardware rounds.
---

Distilled from the 2026-09-05..14 campaigns (#78/#81/#82, then #89's 17 rungs
plus #90-#95). The session model coordinates and verifies; it does not
implement. Everything below was learned by paying for it at least once.

# 1. Launch

- **One `Agent` per item, `model: opus`, `isolation: "worktree"`.** Always
  Opus (Jeremy, 2026-09-11); never Fable, never the session model.
- **A helper an agent spawns reports to YOU, not to it.** Its task
  notifications land in the coordinator's turn; relay the decision it asks
  for to the parent agent by `SendMessage`, or it stalls.
- **The prompt is the whole brief.** Give: the issue number (`tea issues N`),
  the exact docs to read *in order* (CLAUDE.md first, then the section of
  `docs/mainline-port.md` or the doc that owns the topic, then the skill),
  the scope as a checklist, the rules (clean-room, device tripwires, hash
  verification, bounded polling), the git contract (branch name, commit
  trailer, push the branch, never `main`), and the report format with a
  word cap. An agent that has to discover the rules re-derives them wrong.
- **Say who owns the device.** Exactly one agent owns it at a time. Every
  other agent is told "no device access until messaged" and does its offline
  half first, then stops at **"ready for hardware"**. Hand the device over
  with `SendMessage` only after you have read the previous owner's end state
  *from the device yourself* (slot register, services, web, partition hashes).
- **Budget rounds explicitly** ("≤6 hardware rounds, then report"). A rung
  without a budget runs until the context is gone.

# 2. While they run

- **A subagent that ends its turn "waiting on my watcher" is dead.** Its
  background monitor never wakes it. When a report says "in flight" or
  "waiting", arm your own `run_in_background` poll (SSH port open → read the
  oracle), then `SendMessage` the agent with the values and "continue; poll
  in the foreground". Tell every agent this rule up front.
- **Background Bash caps at 10 minutes.** A 30-minute wait is three armed
  windows; re-arm on each `failed` notification.
- **Poll 30 minutes for a mainline boot** before calling a board dark
  (#94 cost a bench trip to a 10-minute window). Power draw tells you nothing;
  only SSH does.
- **Chase merges in the order that avoids conflicts:** when two branches touch
  the same tables/docs, message the *later* agent to merge `origin/main` into
  its branch, recount from a compiled artefact, rebuild, push — then
  fast-forward. Conflicts you resolve by hand should be keep-both additions
  only (flake outputs, doc sections); anything else goes back to the agent.
- **Give the device to the agent whose branch already contains the others**,
  so hardware evidence covers the whole tree.

# 3. Verify before merging (every branch, no exceptions)

```sh
git fetch origin <branch>
git merge-base --is-ancestor main origin/<branch> && echo ff-able
git diff main...origin/<branch> | grep -E '^\+' \
  | grep -o -E '\b192\.168\.[0-9]+\.[0-9]+\b|([0-9a-f]{2}:){5}[0-9a-f]{2}|<uid-words>' | sort -u
cd .claude/worktrees/agent-<id> && nix flake check --no-build && nix build .#<the checks and outputs the branch touches>
```

- **Check the SHAPE against the standing directives before checking the
  claims** — NixOS-native (kernel in the generation, official scripts write
  `/boot`, nix on the device), blob policy, mainline-everything, tags only.
  #86's tar-bundle transport and content-addressed `/boot` kernels passed
  every claim check and were the wrong shape; Jeremy caught it, not the
  review, and it cost #99 and #100. A design that reimplements what NixOS
  already does is a finding, not a feature.
- **A brick-class bug an agent finds in `main` is fixed on `main` first**,
  by you, as its own commit (reproduce it on the host, then patch, build the
  generated script, push), and the agent is told to take main's hunk on its
  next merge. Do not leave it in `main` while a device round is pending
  (the mark-good `sed` delimiter, 2026-09-10).
- **Identifier scan is mandatory**: device IPs, the board MAC, the UID words.
  One agent in three redacts on its own. The LAN IP had been on `main` since
  August before anyone looked.
- **Re-derive one load-bearing number from a different artefact** than the
  agent's (a count from `nm`/`od`/the built binary, not a re-read of its
  source; a store path compared against the *base* commit, not against a
  moved `main`).
- **Spot-read the one code path the claim rests on** (the reset ordering, the
  gate condition, the `case` pattern). Two of the campaign's worst bugs — the
  stage-1 panic token that never matched, the arming state a power cycle
  cleared — were one-line reads away.
- **Never run the merge from inside the agent's worktree.** Bash `cd`
  persists; `cd /home/.../nix-nanokvm-pro &&` prefixes every git chain, and
  `git worktree remove` comes *after* you have left it. (Doing it wrong
  merged into the wrong branch and deleted a remote branch before `main`
  had the commits.)
- Merge → `git push origin main` → `git push origin --delete <branch>` →
  `git worktree remove -f -f` → `git branch -D` → `git worktree prune`.
  Then `nix build` the merged kernel/dtb/uboot once more from `main`.

# 4. Retire and hand off

- **A long-context agent (>~500k tokens, or >~8 rungs) gets retired**, not
  continued. Before its last report, have it write a "Handoff for <next>"
  section at the end of the doc it owns: device state and paths, build
  outputs and their roles, the test loop step by step, the oracles, the
  traps, what is left vs parked — imperative, ≤120 lines, no history. The
  next agent is launched fresh with *only* main and that section as inputs.
- **Bank every lesson that cost a round in CLAUDE.md's trap list** the same
  day, with the issue and date. The memory files get a one-line pointer, not
  the narrative.
- **Close issues with a comment that names the evidence path and the
  residuals**; residuals that are real work become their own issues.
- After a milestone, run `/reflect`.

# 5. The device, specifically

- Read the slot register, U-Boot pre-console buffer and
  `/var/lib/systemd/pstore/` **before** any power cycle; the cycle destroys
  them (`/sys/fs/pstore` is empty on healthy boots — read the archive).
- Cycle with `~/.claude/skills/power-switch/switch.sh "nanokvm switch"
  off|on|state`, ≥15 s off; one cycle per failed boot.
- A one-way write (the SPL, or the single `uboot` partition) is gated on the
  coordinator's explicit go, with the AXDL fallback image path named in the
  report and Jeremy reachable. U-Boot candidates go through the one-shot
  chainload slot (`nanokvm-uboot-test`), never into the partition.
- An arming condition for a dangerous test must not live in state the
  recovery action clears. Ask "what clears this?" of every guard.
- **An offline half never flips a boot-chain default.** The AXDL recovery
  image is whatever `.#nixos-firmware-image-mainline` builds; if an unproven
  SPL/TF-A/U-Boot becomes its default before a board has booted it, the
  recovery for a failed write is the same failed write. Unproven chains ship
  as `-raw`/`-candidate` variants with their own checks, and a follow-up
  commit flips the default after the round (#95, 2026-09-11).
- **A peripheral unit must never gate the boot counter.** WiFi and the
  panel each failed on a board that was otherwise healthy, `is-system-running`
  went `degraded`, mark-good withheld the clear, and three reboots later the
  rollback would have landed on the same generation. Optional units exit 0
  with a journal line; `nanokvm.markGood.tolerateFailed` is the backstop
  (#85, #84, 2026-09-11).
- **A pure refactor has a free oracle: the toplevel store path.** #87 split a
  2,100-line module into nine and proved it changed nothing by the path being
  identical; two regressions (list-option ordering, a comment inside a build
  string) were found by that diff alone. Demand it of every "no functional
  change" branch.

# 6. When the host changes under you

- **A rebooted or rebuilt build host is a new host.** On 2026-09-12 the
  container came back with an empty Nix store and no user profile: every
  artefact needed a from-source rebuild, `tea`/`sshpass` were gone, and one
  `Agent` launch with `isolation: "worktree"` silently got NO worktree and
  pushed to `main`. After any restart: check `command -v tea sshpass nix`,
  `git worktree list`, and the store (`nix path-info` of yesterday's toplevel)
  before launching; and tell every agent to `git worktree list` first and to
  REFUSE to commit if its branch is `main`. A branch that did land on `main`
  is verified after the fact exactly as a branch would be (identifier scan,
  flake check, artefact hashes against the device), never waved through.
