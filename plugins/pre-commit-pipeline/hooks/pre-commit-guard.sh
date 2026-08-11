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

# Resolve the repo the command actually targets, not just the session cwd.
# Agents overwhelmingly write `cd <repo> && git commit ...`; evaluating the
# session cwd's repo instead gated the WRONG repo (observed: a commit into a
# plugin repo blocked by the home directory repo's stale pipeline state).
# Only a leading `cd <path> &&`/`;` prefix is parsed — anything fancier falls
# back to cwd, which is the pre-existing behaviour.
TARGET_DIR=$(printf '%s' "$COMMAND" | sed -nE \
  's/^[[:space:]]*cd[[:space:]]+("([^"]*)"|'\''([^'\'']*)'\''|([^ ;&|]+))[[:space:]]*(&&|;).*/\2\3\4/p' | head -1)
if [ -n "$TARGET_DIR" ] && [ -d "$TARGET_DIR" ]; then
  cd "$TARGET_DIR" || true
fi

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
[ -z "$REPO_ROOT" ] && exit 0   # not a git repo — let git fail naturally

# Opt-in by convention (mirrors git-commit-msg-guard.sh): only guard repos that
# participate in the pipeline — those with a .claude/ directory. Without this,
# the PreToolUse layer gated EVERY git repo the session touched, including ones
# the git-native layer deliberately leaves alone.
[ -d "$REPO_ROOT/.claude" ] || exit 0

LIB="$(cd "$(dirname "$0")" && pwd)/../scripts/pipeline-lib.sh"
# shellcheck source=/dev/null
. "$LIB"

if ! pipeline_eval_gate "commit" "pre-commit-pipeline"; then
  echo "NOTE: this hook blocks the ENTIRE command string before ANY of it runs — if this" >&2
  echo "command bundled staging/marker steps ahead of 'git commit', those did NOT run." >&2
  echo "Run them as their own command first, then run 'git commit' by itself." >&2
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
