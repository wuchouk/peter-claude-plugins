#!/usr/bin/env bash
# track-skill-usage.sh — PreToolUse (Skill) hook
# 記錄每次 skill 被呼叫的時間、名稱、專案目錄
# 輸入：stdin 接收 hook payload (JSON)
# 輸出：stdout 輸出 {"decision":"approve"} (永遠放行)

set -euo pipefail

USAGE_LOG="$HOME/.claude/skill-hygiene/usage.log"
mkdir -p "$(dirname "$USAGE_LOG")"

# 讀取 hook payload
PAYLOAD=$(cat)

# 提取 skill name（從 tool_input.skill 欄位）
SKILL_NAME=$(echo "$PAYLOAD" | jq -r '.tool_input.skill // "unknown"' 2>/dev/null || echo "unknown")

# 取得時間戳和工作目錄
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
PROJECT_DIR=$(pwd)

# 追加到 usage log
echo -e "${TIMESTAMP}\t${SKILL_NAME}\t${PROJECT_DIR}" >> "$USAGE_LOG"

# 永遠放行
echo '{"decision":"approve"}'
