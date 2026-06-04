#!/usr/bin/env bash
# pre-commit-guard.sh — PreToolUse (Bash) hook
# 攔 git commit，要求 3 marker（simplify / review / tests）跑過才放行
# WIP: / wip: / backup: 開頭的 commit message 直接放行
#
# Exit codes:
#   0 → 放行
#   2 → block tool call (stderr 給 Claude)
set -euo pipefail

PAYLOAD=$(cat)
COMMAND=$(echo "$PAYLOAD" | jq -r '.tool_input.command // ""')

# 快速 exit：不是 git commit
case "$COMMAND" in
  *"git commit"*) ;;
  *) exit 0 ;;
esac

# 但是 'git commit-tree' / 'git commit-graph' 排除
if printf '%s' "$COMMAND" | grep -qE 'git commit-(tree|graph)'; then
  exit 0
fi

# WIP escape hatch — 偵測 commit message 開頭是 WIP: / wip: / backup:
# 涵蓋兩種寫法：
#   1. -m "WIP: ..." / -m 'WIP: ...' / -m WIP:...
#   2. HEREDOC body 開頭（多行 command，某一行以 WIP: 開頭）
PATTERN_M='-m[[:space:]]+["'\'']?(WIP|wip|backup):'
PATTERN_LINE='^(WIP|wip|backup):'
if printf '%s' "$COMMAND" | grep -qE -- "$PATTERN_M" \
   || printf '%s\n' "$COMMAND" | grep -qE -- "$PATTERN_LINE"; then
  echo "[pre-commit-pipeline] pipeline skipped (WIP commit)" >&2
  exit 0
fi

# 確認在 git repo
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
if [ -z "$REPO_ROOT" ]; then
  exit 0  # 不在 git repo，let git itself fail naturally
fi

# 算當前 staged hash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPERS_DIR="$(dirname "$SCRIPT_DIR")/scripts"
STAGED_HASH=$(cd "$REPO_ROOT" && bash "$HELPERS_DIR/compute-staged-hash.sh")

STATE_FILE="$REPO_ROOT/.claude/pipeline-state.json"
NOW_EPOCH=$(date +%s)

# 需要檢查的 step → marker key
REQUIRED_STEPS=("simplify" "review" "tests")
declare -a MISSING
declare -a STALE_HASH
declare -a STALE_TIME

if [ ! -f "$STATE_FILE" ]; then
  # 完全沒 marker，全部缺
  for step in "${REQUIRED_STEPS[@]}"; do
    MISSING+=("$step")
  done
else
  STATE=$(cat "$STATE_FILE")
  for step in "${REQUIRED_STEPS[@]}"; do
    ENTRY=$(echo "$STATE" | jq -c --arg s "$step" '.[$s] // null')
    if [ "$ENTRY" = "null" ]; then
      MISSING+=("$step")
      continue
    fi
    MARKER_HASH=$(echo "$ENTRY" | jq -r '.staged_hash // ""')
    MARKER_TIME=$(echo "$ENTRY" | jq -r '.done_at // .verified_at // ""')

    if [ "$MARKER_HASH" != "$STAGED_HASH" ]; then
      STALE_HASH+=("$step")
      continue
    fi

    if [ -n "$MARKER_TIME" ]; then
      MARKER_EPOCH=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$MARKER_TIME" +%s 2>/dev/null || echo 0)
      AGE=$((NOW_EPOCH - MARKER_EPOCH))
      if [ "$AGE" -gt 86400 ]; then
        STALE_TIME+=("$step")
      fi
    fi
  done
fi

# 全過
if [ "${#MISSING[@]}" -eq 0 ] && [ "${#STALE_HASH[@]}" -eq 0 ]; then
  if [ "${#STALE_TIME[@]}" -gt 0 ]; then
    echo "[pre-commit-pipeline] WARN: markers older than 24h: ${STALE_TIME[*]}" >&2
  fi
  exit 0
fi

# 失敗 — 印 stderr + block
{
  echo ""
  echo "[pre-commit-pipeline] BLOCKED — pipeline incomplete for staged diff:"
  echo "  staged_hash: ${STAGED_HASH:0:12}..."
  echo ""

  STEP_HELP="bash ~/peter-claude-plugins/plugins/pre-commit-pipeline/scripts/pipeline-mark-done.sh"

  if [ "${#MISSING[@]}" -gt 0 ]; then
    echo "Missing markers:"
    for step in "${MISSING[@]}"; do
      case "$step" in
        simplify) echo "  - run /simplify, then: $STEP_HELP simplify" ;;
        review)   echo "  - run /review, then:   $STEP_HELP review" ;;
        tests)    echo "  - run /verify-tests (writes its own marker)" ;;
      esac
    done
    echo ""
  fi

  if [ "${#STALE_HASH[@]}" -gt 0 ]; then
    echo "Stale markers (staged diff changed since these ran):"
    for step in "${STALE_HASH[@]}"; do
      case "$step" in
        simplify) echo "  - re-run /simplify, then: $STEP_HELP simplify" ;;
        review)   echo "  - re-run /review, then:   $STEP_HELP review" ;;
        tests)    echo "  - re-run /verify-tests" ;;
      esac
    done
    echo ""
  fi

  echo "If this is a WIP commit, prefix message with 'WIP:' to bypass."
} >&2

exit 2
