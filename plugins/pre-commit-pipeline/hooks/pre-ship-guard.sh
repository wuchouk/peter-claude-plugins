#!/usr/bin/env bash
# pre-ship-guard.sh — PreToolUse (SlashCommand) hook
# 攔 /ship，要求 5 marker（simplify / review / tests / document_release / tidy_docs）跑過才放行
# 無 WIP escape hatch——/ship 是正式 release，必須過完整 pipeline
#
# Exit codes:
#   0 → 放行
#   2 → block (stderr 給 Claude)
set -euo pipefail

PAYLOAD=$(cat)

# 嘗試多種 payload 格式（不同版本 Claude Code 可能用不同 key）
COMMAND=$(echo "$PAYLOAD" | jq -r '
  .tool_input.command //
  .tool_input.slash_command //
  .tool_input.name //
  ""
')

# 快速 exit：不是 /ship
case "$COMMAND" in
  "/ship"|"/ship "*) ;;
  *) exit 0 ;;
esac

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
if [ -z "$REPO_ROOT" ]; then
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPERS_DIR="$(dirname "$SCRIPT_DIR")/scripts"
STAGED_HASH=$(cd "$REPO_ROOT" && bash "$HELPERS_DIR/compute-staged-hash.sh")

STATE_FILE="$REPO_ROOT/.claude/pipeline-state.json"
NOW_EPOCH=$(date +%s)

REQUIRED_STEPS=("simplify" "review" "tests" "document_release" "tidy_docs")
declare -a MISSING
declare -a STALE_HASH
declare -a STALE_TIME

if [ ! -f "$STATE_FILE" ]; then
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

if [ "${#MISSING[@]}" -eq 0 ] && [ "${#STALE_HASH[@]}" -eq 0 ]; then
  if [ "${#STALE_TIME[@]}" -gt 0 ]; then
    echo "[pre-ship-pipeline] WARN: markers older than 24h: ${STALE_TIME[*]}" >&2
  fi
  exit 0
fi

{
  echo ""
  echo "[pre-ship-pipeline] BLOCKED — /ship requires full pipeline complete:"
  echo "  staged_hash: ${STAGED_HASH:0:12}..."
  echo ""

  STEP_HELP="bash ~/peter-claude-plugins/plugins/pre-commit-pipeline/scripts/pipeline-mark-done.sh"

  emit_step() {
    local step="$1"
    local prefix="$2"  # "run" or "re-run"
    case "$step" in
      simplify)         echo "  - $prefix /simplify, then: $STEP_HELP simplify" ;;
      review)           echo "  - $prefix /review, then:   $STEP_HELP review" ;;
      tests)            echo "  - $prefix /verify-tests (writes its own marker)" ;;
      document_release) echo "  - $prefix /document-release, then: $STEP_HELP document-release" ;;
      tidy_docs)        echo "  - $prefix /tidy-docs, then: $STEP_HELP tidy-docs" ;;
    esac
  }

  if [ "${#MISSING[@]}" -gt 0 ]; then
    echo "Missing markers:"
    for step in "${MISSING[@]}"; do
      emit_step "$step" "run"
    done
    echo ""
  fi

  if [ "${#STALE_HASH[@]}" -gt 0 ]; then
    echo "Stale markers (staged diff changed since these ran):"
    for step in "${STALE_HASH[@]}"; do
      emit_step "$step" "re-run"
    done
  fi
} >&2

exit 2
