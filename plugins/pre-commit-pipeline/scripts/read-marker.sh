#!/usr/bin/env bash
# read-marker.sh — 讀 .claude/pipeline-state.json
# Usage:
#   read-marker.sh <step>          → 整個 entry (JSON) 或 "null"
#   read-marker.sh <step> <field>  → 單一 field 值或 "null"
# step: simplify | review | tests | document_release
set -euo pipefail

STEP="${1:-}"
FIELD="${2:-}"

if [ -z "$STEP" ]; then
  echo "Usage: read-marker.sh <step> [field]" >&2
  exit 1
fi

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
if [ -z "$REPO_ROOT" ]; then
  echo "null"
  exit 0
fi

STATE_FILE="$REPO_ROOT/.claude/pipeline-state.json"
if [ ! -f "$STATE_FILE" ]; then
  echo "null"
  exit 0
fi

if [ -n "$FIELD" ]; then
  jq -r --arg s "$STEP" --arg f "$FIELD" '.[$s][$f] // "null"' "$STATE_FILE"
else
  jq -c --arg s "$STEP" '.[$s] // null' "$STATE_FILE"
fi
