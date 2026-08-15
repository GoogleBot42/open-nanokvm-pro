---
name: fetch-work
description: Pull a ranked list of candidate work for this project when the user asks "what should we work on" or tells you to find something useful to do.
---

# Fetch work

Surfaces candidate work for this project (this repo
active, `docs/plan-sg2002-research.md` SG2002 dormant) from live issues plus the docs/memory
scan already done for you in the sources file.

## Modes

Read the user's request and pick one:

1. **User names a kind of work** ("find a bug to fix", "any docs work?",
   "something in blob-replacement") — filter the sources to that kind
   (label, doc section, or theme) and present matches.
2. **Agent-choose** ("pick something and do it", "find something useful")
   — pick the single highest-value item using the ranking below and
   propose it before starting (don't silently start work the user hasn't
   seen).
3. **Suggest** ("what should we work on?") — present the top 3–5 ranked,
   one-line rationale each.

## Procedure

1. Read the sibling file `../work-sources.md` (full path:
   `.claude/skills/work-sources.md`) —
   it enumerates where work comes from and the known inconsistencies to
   watch for.
2. Pull live Gitea issues:
   `tea issues list --repo zuckerberg/open-nanokvm-pro` (add `--labels
   <label>` to filter per the taxonomy in the sources file). This is the
   most current source — prefer it over anything cited from docs/memory
   when both describe the same item.
3. Cross-check any docs-derived or memory-derived TODOs the sources file
   lists against the current tree — files move and sections get rewritten;
   re-grep the cited file/section before treating an item as still open
   (see Failure modes).
4. Rank surviving candidates by, in order: **user-stated priorities**
   (if the user gave one, it wins outright) > **unblocking-power** (does
   finishing this let other work proceed — e.g. anything the
   GitHub-vs-Gitea release-pipeline mismatch is currently blocking,
   or a `needs-human` item that once resolved unblocks agent follow-through)
   > **effort** (prefer cheaper wins when other factors tie).

## Output

A ranked list. For each item: what it is, one-line rationale for its rank,
and a source citation (issue number + URL/index, or `doc:section`, or
`memory:file`). If proposing to start work (mode 2), say so explicitly and
wait for confirmation unless the user already said to just go.

## Failure modes

- **The sources file can be stale.** It was accurate as of its last
  edit, but docs get rewritten and issues get closed. Before proposing a
  docs-or-memory-derived item, confirm it's still true: re-grep the cited
  file/section, or re-pull the specific Gitea issue
  (`tea issues <index> --repo zuckerberg/open-nanokvm-pro`) to check it's
  still open and the body still matches reality.
- **Don't propose work the user deliberately dropped.** The SG2002 project
  (`docs/plan-sg2002-research.md`) was explicitly deferred by user decision, and the SD-boot
  chase for the Pro build was explicitly dropped after four failed device
  boots (see `nanokvm-pro-blob-audit.md` memory, "SD-BOOT CHASE ... DROPPED
  by user"). Surfacing these as *known* dormant/dropped context is fine;
  proposing to resume them as if newly discovered is not — flag it and let
  the user decide.
- **Don't conflate file-issues.sh with live work.** It's a historical seed
  script (see sources file) targeting a GitHub repo that isn't the real
  forge — never treat its contents as a to-do list distinct from the Gitea
  issues that already absorbed most of it.
