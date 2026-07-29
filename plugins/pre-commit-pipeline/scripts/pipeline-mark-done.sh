#!/usr/bin/env bash
# pipeline-mark-done.sh — Claude 跑完 skill 後手動呼叫，寫 marker
# Usage: pipeline-mark-done.sh <step>
# Step: simplify | review | verify-tests | document-release
set -euo pipefail

STEP="${1:-}"
if [ -z "$STEP" ]; then
  cat >&2 <<EOF
Usage: pipeline-mark-done.sh <step>
  step: simplify | review | verify-tests | document-release
EOF
  exit 1
fi

# Step alias → marker key (single source: pipeline-steps.json via pipeline-lib.sh)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/pipeline-lib.sh"

KEY="$(pipeline_resolve_alias "$STEP")"
if [ -z "$KEY" ]; then
  echo "Unknown step: $STEP" >&2
  echo "Valid aliases: $(jq -r '.aliases | keys | join(" | ")' "$PIPELINE_STEPS_JSON")" >&2
  exit 1
fi

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
if [ -z "$REPO_ROOT" ]; then
  echo "Not in a git repo — marker not written" >&2
  exit 1
fi

STAGED_HASH=$(bash "$SCRIPT_DIR/compute-staged-hash.sh")
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

STATE_DIR="$REPO_ROOT/.claude"
STATE_FILE="$STATE_DIR/pipeline-state.json"
mkdir -p "$STATE_DIR"

if [ -f "$STATE_FILE" ]; then
  STATE=$(cat "$STATE_FILE")
else
  STATE='{}'
fi

# Ensure .gitignore has the marker file
GITIGNORE="$REPO_ROOT/.gitignore"
GITIGNORE_LINE=".claude/pipeline-state.json"
if [ ! -f "$GITIGNORE" ]; then
  echo "$GITIGNORE_LINE" > "$GITIGNORE"
elif ! grep -qxF "$GITIGNORE_LINE" "$GITIGNORE"; then
  [ -n "$(tail -c 1 "$GITIGNORE")" ] && echo "" >> "$GITIGNORE"
  echo "$GITIGNORE_LINE" >> "$GITIGNORE"
fi

# first_marked_at — the EARLIEST time this step was ticked in the current round,
# carried over on a re-mark instead of being overwritten.
#
# Why it exists: a marker is bound to the staged diff's hash, so touching any
# file after the pipeline ran invalidates all of them and they must be re-marked
# together. That re-mark is one continuous action, so every done_at lands in the
# same second and the batch-tick check reads it as fabricated. But editing files
# after the pipeline is the NORMAL case, not an anomaly — review finds something
# and you fix it, you log a TODO, document-release adds docs. Keeping the first
# tick time lets the gate tell "re-marked" apart from "three ticks appeared out
# of nowhere", which is the question it actually meant to ask.
#
# Bound to HEAD, not just to a time window. Without that binding the carried
# timestamp outlives the work it vouches for: run a real pipeline, commit, then
# start unrelated work and tick all three at once — each marker takes the new
# staged hash but keeps the old spread-out times, and the gate waves through
# exactly what the previous logic would have blocked. HEAD moves on commit, so
# comparing it IS the "still the same round?" test. The 24h cap stays as a
# backstop for a round left open overnight; a first_marked_at in the future is
# refused outright, since a hand-edited one would otherwise never age out and
# would seed a permanent bypass.
CUR_HEAD=$(git rev-parse HEAD 2>/dev/null || echo "no-head")
PREV_FIRST=$(echo "$STATE" | jq -r --arg key "$KEY" '.[$key].first_marked_at // ""')
PREV_HEAD=$(echo "$STATE" | jq -r --arg key "$KEY" '.[$key].first_marked_head // ""')
FIRST="$NOW"
if [ -n "$PREV_FIRST" ] && [ "$PREV_HEAD" = "$CUR_HEAD" ]; then
  PREV_EPOCH=$(_pipeline_iso_to_epoch "$PREV_FIRST")
  NOW_EPOCH=$(date +%s)
  AGE=$((NOW_EPOCH - PREV_EPOCH))
  # epoch 0 = the stored value did not parse; AGE < 0 = it sits in the future.
  # Neither is trustworthy, so fall through and start this step's clock now.
  if [ "$PREV_EPOCH" -gt 0 ] && [ "$AGE" -ge 0 ] && [ "$AGE" -le 86400 ]; then
    FIRST="$PREV_FIRST"
  fi
fi

# Merge (preserve other keys in the entry like decisions[] for tests)
NEW_STATE=$(echo "$STATE" | jq \
  --arg key "$KEY" \
  --arg done_at "$NOW" \
  --arg first "$FIRST" \
  --arg first_head "$CUR_HEAD" \
  --arg hash "$STAGED_HASH" \
  '.[$key] = ((.[$key] // {}) + {done_at: $done_at, first_marked_at: $first, first_marked_head: $first_head, staged_hash: $hash})')

echo "$NEW_STATE" > "$STATE_FILE"
echo "✓ pipeline-mark-done $STEP — staged_hash=${STAGED_HASH:0:12}... at $NOW"
