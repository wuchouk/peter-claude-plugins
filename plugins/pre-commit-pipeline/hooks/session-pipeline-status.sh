#!/usr/bin/env bash
# session-pipeline-status.sh — SessionStart hook
# 靜默版：只在 dirty diff + stale/missing marker 時印一行提示
# 乾淨 repo 或 marker 新 → 完全靜默
set -euo pipefail

# 不在 git repo → 靜默
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
if [ -z "$REPO_ROOT" ]; then
  exit 0
fi

cd "$REPO_ROOT"

# Working tree 完全乾淨（沒 staged、沒 modified、沒 untracked）→ 靜默
if [ -z "$(git status --porcelain 2>/dev/null)" ]; then
  exit 0
fi

STATE_FILE="$REPO_ROOT/.claude/pipeline-state.json"
NOW_EPOCH=$(date +%s)

# 沒 marker 檔 → 提示需要跑哪些
if [ ! -f "$STATE_FILE" ]; then
  cat <<EOF
[pre-commit-pipeline] uncommitted changes detected, no pipeline markers yet.
  next commit will require: /simplify, /review, /verify-tests
  (and /document-release before /ship)
EOF
  exit 0
fi

# 有 marker 檔 → 算最新 marker 時間
LATEST_EPOCH=0
for step in simplify review tests document_release; do
  TS=$(jq -r --arg s "$step" '.[$s].done_at // .[$s].verified_at // empty' "$STATE_FILE" 2>/dev/null || true)
  if [ -n "$TS" ]; then
    EPOCH=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$TS" +%s 2>/dev/null || echo 0)
    if [ "$EPOCH" -gt "$LATEST_EPOCH" ]; then
      LATEST_EPOCH=$EPOCH
    fi
  fi
done

# 全沒 marker
if [ "$LATEST_EPOCH" -eq 0 ]; then
  echo "[pre-commit-pipeline] uncommitted changes, no markers yet — see README for pipeline."
  exit 0
fi

AGE=$((NOW_EPOCH - LATEST_EPOCH))
if [ "$AGE" -gt 86400 ]; then
  AGE_DAYS=$((AGE / 86400))
  echo "[pre-commit-pipeline] uncommitted changes, last pipeline run ${AGE_DAYS}d ago (stale)."
  echo "  next commit will re-run: /simplify, /review, /verify-tests"
fi
# marker 新 → 靜默（即使 dirty diff 也不亂講話）
