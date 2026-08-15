---
name: reflect
description: End-of-work harness review — run after completing substantial work to keep CLAUDE.md, skills, and memory accurate.
---

# Reflect

**"No changes needed" is the expected common outcome for most of these
steps on most sessions — say so plainly at the top of your report rather
than manufacturing a change to look useful.** State up front, per step,
whether anything actually needs to change before making any edit.

Run this after completing substantial work in this repo, not after
every small action.

## Procedure

1. **CLAUDE.md drift.** Did this session contradict or outgrow anything in
   `CLAUDE.md` (if it
   exists), or in any skill under `.claude/skills/`? If yes, patch the file
   minimally — don't rewrite around it.
2. **Skill under-coverage.** Did you have to re-derive steps a skill should
   have already spelled out (e.g. you worked out a `tea` invocation, a
   build/flash sequence, or a ranking rule from scratch because the skill
   was silent on it)? Extend that skill's procedure with what you learned.
3. **Missing skill.** Did you re-derive a multi-step procedure this
   session that has **no** skill covering it at all? Propose creating one
   — describe what it would cover — and ask before creating it. Don't
   create it unprompted.
4. **Memory hygiene.** Check
   `/home/googlebot/.claude/projects/-home-googlebot-workspace-nanokvm-nix-nanokvm-pro/memory/`:
   - Entries that are now codified in `CLAUDE.md`, a doc under
     `docs/`, or a skill get pruned in `MEMORY.md` to a
     one-line "codified in `<path>`" pointer — don't leave the full detail
     duplicated in two places.
   - Delete facts that are now stale — but **verify against the live tree
     first**, don't delete on suspicion. Known stale example to check on
     each pass: `nanokvm-pro-ota-updates.md` still describes a
     "push to GitHub, no `gh` CLI in this env, repo not yet pushed" state,
     but the project has since moved fully to Gitea (`zuckerberg/
     open-nanokvm-pro`, 30 issues filed via `tea`). Reconcile or prune
     this once, then it's done — don't re-flag it every session.
5. **Sources file.** If any blocker in
   `.claude/skills/work-sources.md`
   changed this session (an issue closed, a hardware test finally ran, the
   GitHub-vs-Gitea release-pipeline split got resolved, VERSION/versioning
   got reconciled), update that entry. Otherwise leave it alone.

## Output

Lead with a one-line verdict per numbered step: changed / no change
needed. Only elaborate on the steps where something changed. If literally
nothing changed, say that in one sentence and stop — don't pad the report.
