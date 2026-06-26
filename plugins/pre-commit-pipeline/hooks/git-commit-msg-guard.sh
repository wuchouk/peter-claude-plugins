#!/usr/bin/env bash
# git-commit-msg-guard.sh — git-native pipeline gate guard.
#
# Unlike pre-commit-guard.sh (a Claude Code PreToolUse hook), this runs from
# git itself, so it enforces the pipeline for EVERY committer — Claude, Codex,
# Fugu, Conductor, or a human at the terminal — regardless of which agent (if
# any) drove the commit. Wired in globally via ~/.config/husky/init.sh, which
# invokes it at the pre-commit stage (the husky hook that always fires).
#
# Arg: $1 = commit message file, IF available (only the commit-msg stage passes
# it). At pre-commit there is no message, so the WIP:/backup: prefix bypass is
# skipped there — use PIPELINE_SKIP=1 instead.
#
# Exit codes: 0 = allow, 1 = block.
set -euo pipefail

MSG_FILE="${1:-}"

# Manual escape hatch for scripted/edge cases.
[ "${PIPELINE_SKIP:-}" = "1" ] && exit 0

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
[ -z "$REPO_ROOT" ] && exit 0   # not a git repo — nothing to guard

# Opt-in by convention: only guard repos that participate in the pipeline,
# i.e. those with a .claude/ directory. Random/cloned repos are never blocked.
[ -d "$REPO_ROOT/.claude" ] || exit 0

# WIP escape hatch — first non-comment line starts with WIP:/wip:/backup:
if [ -n "$MSG_FILE" ] && [ -f "$MSG_FILE" ]; then
  FIRST_LINE=$(grep -vE '^[[:space:]]*#' "$MSG_FILE" | grep -vE '^[[:space:]]*$' | head -1 || true)
  if printf '%s' "$FIRST_LINE" | grep -qE '^(WIP|wip|backup):'; then
    echo "[pre-commit-pipeline] pipeline skipped (WIP commit)" >&2
    exit 0
  fi
fi

LIB="$(cd "$(dirname "$0")" && pwd)/../scripts/pipeline-lib.sh"
# shellcheck source=/dev/null
. "$LIB"

if pipeline_eval_gate "commit" "pre-commit-pipeline"; then
  exit 0
fi

echo "To save incomplete work without the pipeline, bypass with:" >&2
echo "  PIPELINE_SKIP=1 git commit -m \"...\"" >&2
exit 1
