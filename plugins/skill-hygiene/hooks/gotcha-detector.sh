#!/usr/bin/env bash
# gotcha-detector.sh — Stop hook
# 偵測使用者回應中的修正模式（「不對」「錯了」「應該是」），建議執行 /gotcha
# 輸入：stdin 接收 hook payload (JSON)
# 輸出：stdout 輸出 {"decision":"approve"} 或含 systemMessage

set -euo pipefail

# 防止同一 session 重複提醒
FLAG_DIR="$HOME/.claude/skill-hygiene"
mkdir -p "$FLAG_DIR"
FLAG_FILE="$FLAG_DIR/.gotcha-suggested-$$"

# 如果這個 session 已經提醒過，直接放行
if [ -f "$FLAG_FILE" ]; then
    echo '{"decision":"approve"}'
    exit 0
fi

# 讀取 hook payload
PAYLOAD=$(cat)

# 檢查最近使用者訊息是否有修正模式
# 從 transcript 中取最後一條 user message
LAST_USER_MSG=$(echo "$PAYLOAD" | jq -r '
  .transcript
  | map(select(.role == "user"))
  | last
  | .content
  // ""
' 2>/dev/null || echo "")

# 修正模式關鍵字（中英文）
if echo "$LAST_USER_MSG" | grep -qiE '不對|錯了|應該是|不是這樣|wrong|incorrect|should be|that.s not right|搞錯|弄錯'; then
    # 檢查最近是否有 skill 被使用（usage.log 最後一筆在 30 分鐘內）
    USAGE_LOG="$HOME/.claude/skill-hygiene/usage.log"
    if [ -f "$USAGE_LOG" ]; then
        LAST_SKILL=$(tail -1 "$USAGE_LOG" | cut -f2)
        if [ -n "$LAST_SKILL" ] && [ "$LAST_SKILL" != "unknown" ]; then
            # 標記已提醒
            touch "$FLAG_FILE"
            echo "{\"decision\":\"approve\",\"systemMessage\":\"偵測到修正模式。如果是 skill 行為問題，可以用 /gotcha 記錄，讓 ${LAST_SKILL} 下次表現更好。\"}"
            exit 0
        fi
    fi
fi

echo '{"decision":"approve"}'
