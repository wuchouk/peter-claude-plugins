# Telegram 訊息模板 + 確認回路

`scheduled` 和 `headless` 模式下流程只有 **1 個 reply 點**（Step 3：是否處理偵測到的 giveaway 影片），跑完 yes 之後 comment + X share + form 填寫 + form submit 全部自動執行，最後送結算訊息。互動模式下唯一的確認用 `AskUserQuestion`。

## 用到的 tool（依 mode 不同）

### Scheduled / Headless mode：**純 curl，不走 plugin**

Scheduled mode 下 `claude -p` 是用 `--strict-mcp-config --mcp-config mcp-empty.json` 啟動的，**沒有載入任何 MCP server**（包含 telegram plugin）。這是為了避免 grammy plugin 和 `wait-reply.sh` 在同一個 bot 上 parallel poll `getUpdates`（Telegram API 明確禁止此行為，會造成訊息隨機被吃掉）。

所以 scheduled mode 下所有 Telegram 動作都用 bash 腳本：

| 動作 | 指令 |
|------|------|
| 送訊息 | `bash ~/Projects/justin-giveaway/scripts/telegram-send.sh send <chat_id> "<text>"` |
| 送照片 | `bash ~/Projects/justin-giveaway/scripts/telegram-send.sh photo <chat_id> <file_path> "<caption>"` |
| 改訊息 | `bash ~/Projects/justin-giveaway/scripts/telegram-send.sh edit <chat_id> <message_id> "<new_text>"` |
| Emoji 反應 | `bash ~/Projects/justin-giveaway/scripts/telegram-send.sh react <chat_id> <message_id> "<emoji>"` |
| 等回覆 | `bash ~/Projects/justin-giveaway/scripts/wait-reply.sh <chat_id> <timeout_seconds>` |

每個 `send` / `photo` 回傳 Telegram API 的 JSON response（stdout），可以從中抽 `result.message_id`（要 edit 或 react 時用）：

```bash
RESP=$(bash scripts/telegram-send.sh send 1780314667 "測試")
MSG_ID=$(echo "$RESP" | python3 -c "import sys,json; print(json.loads(sys.stdin.read())['result']['message_id'])")
```

### Interactive mode：正常用 MCP plugin

在互動（Claude Code session）模式下，唯一的 Step 3 確認用 `AskUserQuestion`，Telegram 只在最終結算（Step 7）時可選擇發訊息給自己備份。用 MCP plugin：

- `mcp__plugin_telegram_telegram__reply` — 送訊息（可帶 `files: ["/path/*.png"]` 附圖）
- `mcp__plugin_telegram_telegram__edit_message` — 進度更新
- `mcp__plugin_telegram_telegram__react` — emoji 反應

> Telegram 不會主動 push 給 skill，要等 Peter 回的訊息進到 conversation。互動模式下訊息會以 `<channel source="telegram">` 進到 conversation。Scheduled 模式下用 `wait-reply.sh` polling getUpdates（因為 plugin 沒載入，沒有 race）。

## chat_id 取得方式

Peter 的 chat_id 是 `1780314667`（下方範例指令用的就是它）。Scheduled mode 沒有載入 telegram plugin，不要嘗試用 plugin 的 status / configure 去查。

## 訊息模板

### #1 啟動通知（所有 mode 都發）

```
🎬 JUSTIN giveaway 流程啟動 [{mode}]
時間：{SF time}
影片偵測中...
```

### #2 已處理過 / 非 giveaway

```
ℹ️ 最新影片『{title}』上次已處理過，跳過避免重複
✅ 流程結束
```

或：

```
ℹ️ 本週影片『{title}』非 giveaway（pinned 留言沒有 form 連結）
✅ 流程結束
```

### #3 找到 giveaway，等確認 (#1)

```
🎯 找到 giveaway 影片
標題：{title}
連結：{video_url}
Form：{form_url}

要繼續嗎？回 yes 繼續，no 取消
```

⏳ 等 Peter reply。Timeout 5 分鐘 → 取消流程。

### #4 進度（**不等回覆**，可選）

留言 + X 分享完成、開始填 form 之前送一個 progress 通知，讓 Peter 從 Telegram 看得到流程跑到哪：

```
✅ 留言「謝謝J大」已發出
✅ X 分享已 post
🔄 開始填 form + 送出（無 pre-submit 確認）...
```

`send` 完就不等 reply，直接跑 Step 6。

### #5 完成（成功）

```
🎉 JUSTIN giveaway 處理完成
影片：{title}
TradingView：sku772003
Form 送出時間：{ISO timestamp}
Log：~/Library/Logs/justin-giveaway/{filename}.log
```

**附 3 張截圖**讓 Peter 自己驗收實際內容：
```bash
bash ~/Projects/justin-giveaway/scripts/telegram-send.sh photo <chat_id> \
  ~/Library/Logs/justin-giveaway/screenshots/comment-*.png "YouTube 留言"
bash ~/Projects/justin-giveaway/scripts/telegram-send.sh photo <chat_id> \
  ~/Library/Logs/justin-giveaway/screenshots/x-share-*.png "X 分享"
bash ~/Projects/justin-giveaway/scripts/telegram-send.sh photo <chat_id> \
  /tmp/justin-form-filled.png "Form 送出前"
```

### #6 失敗 / 中斷

```
⚠️ JUSTIN giveaway 中斷
階段：{step name}
原因：{error message}
Log：~/Library/Logs/justin-giveaway/{filename}.log

請手動補完，或重跑 /justin
```

附上已經產生的截圖（如果有），讓 Peter 知道走到哪一步：
```bash
# 視當下進度附上 comment-*.png / x-share-*.png / /tmp/justin-form-debug.png / /tmp/justin-form-filled.png
```

## Polling 邏輯（等 reply）

**Scheduled mode 下完全不靠 plugin**。`run-justin.sh` 啟動 `claude -p` 時已經用 `--strict-mcp-config --mcp-config mcp-empty.json` 關掉所有 MCP server，所以 grammy plugin 根本不在這個 session 裡 poll，不會跟 `wait-reply.sh` 搶 `getUpdates`。

實作方式：

```bash
# 送確認訊息
RESP=$(bash ~/Projects/justin-giveaway/scripts/telegram-send.sh send 1780314667 "🎯 找到 giveaway 影片...回 yes 繼續")
MSG_ID=$(echo "$RESP" | python3 -c "import sys,json; print(json.loads(sys.stdin.read())['result']['message_id'])")

# 等回覆（最多 5 分鐘）
REPLY=$(bash ~/Projects/justin-giveaway/scripts/wait-reply.sh 1780314667 300)
if [[ "$REPLY" == "__TIMEOUT__" ]]; then
  bash ~/Projects/justin-giveaway/scripts/telegram-send.sh edit 1780314667 "$MSG_ID" "⏱ 5 分鐘內沒收到確認，流程取消。"
  exit 0
fi

# 檢查 REPLY 是不是 yes
if [[ "${REPLY,,}" == "yes" ]] || [[ "${REPLY,,}" == "y" ]]; then
  # 繼續 Step 4
  ...
fi
```
