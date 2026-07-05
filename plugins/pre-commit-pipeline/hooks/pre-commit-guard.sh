#!/usr/bin/env bash
# pre-commit-guard.sh — PreToolUse (Bash) hook for Claude Code.
# Blocks `git commit` until the commit-gate markers (see pipeline-steps.json)
# are present, fresh, and not batch-ticked. The git-native commit-msg guard
# (hooks/git-commit-msg-guard.sh, wired via ~/.config/husky/init.sh) is the
# cross-agent backstop; this hook adds earlier/inline blocking inside Claude.
#
# WIP: / wip: / backup: commit messages bypass the gate.
#
# Exit codes:
#   0 → allow
#   2 → block tool call (stderr shown to Claude)
set -euo pipefail

PAYLOAD=$(cat)
COMMAND=$(echo "$PAYLOAD" | jq -r '.tool_input.command // ""')

# Fast exit: not a git commit
case "$COMMAND" in
  *"git commit"*) ;;
  *) exit 0 ;;
esac

# Explicit bypass token (consistent with the git-native layer): the user/agent
# ran `PIPELINE_SKIP=1 git commit ...`. The env var lives in the command string
# (not this hook's environment), so match it textually.
if printf '%s' "$COMMAND" | grep -qE '(^|[[:space:];&])PIPELINE_SKIP=1([[:space:]]|$)'; then
  echo "[pre-commit-pipeline] pipeline skipped (PIPELINE_SKIP=1)" >&2
  exit 0
fi

# Exclude git commit-tree / commit-graph
if printf '%s' "$COMMAND" | grep -qE 'git commit-(tree|graph)'; then
  exit 0
fi

# WIP escape hatch — `-m "WIP: ..."` or a heredoc body line starting with WIP:
PATTERN_M='-m[[:space:]]+["'\'']?(WIP|wip|backup):'
PATTERN_LINE='^(WIP|wip|backup):'
if printf '%s' "$COMMAND" | grep -qE -- "$PATTERN_M" \
   || printf '%s\n' "$COMMAND" | grep -qE -- "$PATTERN_LINE"; then
  echo "[pre-commit-pipeline] pipeline skipped (WIP commit)" >&2
  exit 0
fi

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
[ -z "$REPO_ROOT" ] && exit 0   # not a git repo — let git fail naturally

LIB="$(cd "$(dirname "$0")" && pwd)/../scripts/pipeline-lib.sh"
# shellcheck source=/dev/null
. "$LIB"

if ! pipeline_eval_gate "commit" "pre-commit-pipeline"; then
  echo "If this is a WIP commit, prefix message with 'WIP:' to bypass." >&2
  exit 2
fi

# Evidence + fix-regression hard checks (dual-loop B-2). The git-native
# commit-msg stage only fires in repos with a .husky/commit-msg anchor, so
# this PreToolUse layer detects fix commits from the command string instead
# (-m flag or heredoc body first line).
MSG_GUESS=""
if printf '%s' "$COMMAND" | grep -qE -- '-m[[:space:]]+["'\'']?fix([(:! ]|$)' \
   || printf '%s\n' "$COMMAND" | grep -qE '^fix([(:! ]|$)'; then
  MSG_GUESS="fix"
fi
if ! pipeline_check_evidence "pre-commit-pipeline" "$MSG_GUESS"; then
  exit 2
fi

exit 0
