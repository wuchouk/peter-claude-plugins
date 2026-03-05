#!/usr/bin/env bash
# milestone-detector.sh — Stop hook for devlog auto-suggestion
# Detects development milestones and suggests /devlog recording.
# Uses command hook (not prompt hook) to avoid LLM token cost.

set -euo pipefail

CONFIG_FILE="$HOME/.claude/devlog-auto.local.md"
SESSION_FLAG="/tmp/devlog-suggested-$$"

# Check if auto-detection is enabled
if [[ ! -f "$CONFIG_FILE" ]]; then
  exit 0
fi

if ! grep -q "enabled: true" "$CONFIG_FILE" 2>/dev/null; then
  exit 0
fi

# Prevent duplicate suggestions in same session
# Use parent PID to identify the Claude session
PPID_FLAG="/tmp/devlog-suggested-${PPID}"
if [[ -f "$PPID_FLAG" ]]; then
  exit 0
fi

# Read hook input from stdin
INPUT=$(cat)

# Extract transcript/stop reason from hook input
TRANSCRIPT=$(echo "$INPUT" | jq -r '.transcript // .stop_reason // empty' 2>/dev/null || echo "")

if [[ -z "$TRANSCRIPT" ]]; then
  exit 0
fi

# Check for milestone keywords in recent content
MILESTONE_PATTERN="git commit|git tag|git push|deploy|上線|做完了|搞定|完成了|功能完成|bug 修好|已部署|merged|PR merged|pull request"

if echo "$TRANSCRIPT" | grep -qiE "$MILESTONE_PATTERN"; then
  # Mark as suggested for this session
  touch "$PPID_FLAG"

  # Output approval with system message (does not block Claude from stopping)
  echo '{"decision":"approve","systemMessage":"[devlog] 偵測到開發里程碑！如果這次的工作值得記錄，可以用 /devlog 建立開發日誌。"}'
fi
