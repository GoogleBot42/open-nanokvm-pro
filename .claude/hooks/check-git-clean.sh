#!/usr/bin/env bash
# Stop hook: enforce "commit as you work; push after committing" in this repo.
# Blocks the stop once (with a reminder) if the repo has uncommitted or unpushed work.
input=$(cat)
case "$input" in
  *'"stop_hook_active":true'*) exit 0 ;;
esac

# Repo root = two levels up from this script (.claude/hooks/).
repo=$(cd "$(dirname "$0")/../.." && pwd)
cd "$repo" 2>/dev/null || exit 0

msgs=""
if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
  msgs="the repo has uncommitted changes."
fi
if [ -n "$(git log --oneline @{u}..HEAD 2>/dev/null)" ]; then
  msgs="$msgs the repo has unpushed commits."
fi
msgs="${msgs# }"

if [ -n "$msgs" ]; then
  printf '{"decision":"block","reason":"%s Standing rule: commit as you work and push after committing. Commit and push now if the work is done; if it is genuinely mid-task work-in-progress, say so briefly and stop."}\n' "$msgs"
fi
exit 0
