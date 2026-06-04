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

# Step alias → marker key
case "$STEP" in
  simplify)         KEY="simplify" ;;
  review)           KEY="review" ;;
  verify-tests|tests) KEY="tests" ;;
  document-release|document_release) KEY="document_release" ;;
  tidy-docs|tidy_docs) KEY="tidy_docs" ;;
  *)
    echo "Unknown step: $STEP" >&2
    echo "Valid: simplify | review | verify-tests | document-release | tidy-docs" >&2
    exit 1
    ;;
esac

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
if [ -z "$REPO_ROOT" ]; then
  echo "Not in a git repo — marker not written" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
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

# Merge (preserve other keys in the entry like decisions[] for tests)
NEW_STATE=$(echo "$STATE" | jq \
  --arg key "$KEY" \
  --arg done_at "$NOW" \
  --arg hash "$STAGED_HASH" \
  '.[$key] = ((.[$key] // {}) + {done_at: $done_at, staged_hash: $hash})')

echo "$NEW_STATE" > "$STATE_FILE"
echo "✓ pipeline-mark-done $STEP — staged_hash=${STAGED_HASH:0:12}... at $NOW"
