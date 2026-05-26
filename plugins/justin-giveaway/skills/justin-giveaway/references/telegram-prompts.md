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

skill 第一次啟動時呼叫一次 telegram 的 status / configure 取得 Peter 的 chat_id，cache 在 working memory 裡。**不要寫死在 SKILL.md**（每個 user 不同）。

或：等 Peter 主動丟一個 `/justin start` 之類的 trigger 訊息到 bot，從那則訊息抽 `chat_id`。

> 簡化方案：第一次跑時讓 Peter 提供 chat_id，存到 `~/Library/Logs/justin-giveaway/state.json` 的 `telegram_chat_id` 欄位。

## 訊息模板

### #1 啟動通知（所有 mode 都發）

```
🎬 JUSTIN giveaway 流程啟動 [{mode}]
時間：{SF time}
影片偵測中...
```

### #2 沒新影片 / 非 giveaway

```
ℹ️ 本週無新影片（最新影片發佈於 {hours}h 前，超過 48h window）
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

## Polling 邏輯（等 reply）— 2026-04-20 已換成純 curl 架構

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

`wait-reply.sh` 的 race condition（之前跟 grammy plugin 搶 getUpdates）在這個架構下**完全解決**，因為 scheduled session 裡根本沒 plugin 在 poll。

**互動模式（舊 polling 邏輯僅供參考）：**

```python
# 舊偽碼（只適用 interactive mode，不再適用 scheduled）
def wait_for_telegram_reply(chat_id, timeout_seconds=300):
    start = time.time()
    while time.time() - start < timeout_seconds:
        # 互動模式下 plugin 把 inbound 訊息送進 conversation（<channel> tag）
        # 下一輪 turn 會看到 Peter 的 reply
        time.sleep(5)
        # 檢查 conversation 是否有來自 chat_id 的新 inbound message
        ...
    return None  # timeout
```

> ⚠️ Telegram plugin 的 API 是「user → bot」單向 inbound，bot 收到訊息會透過 system reminder 進到 conversation。Skill 要等 reply 的方式：發訊息後**結束 turn 等待 user input**，等 user 在 Telegram 回覆後再繼續下一個 turn。
>
> 這代表 scheduled mode 下 `claude -p` 不能完成單一 prompt 包整個流程 —— 要分多個 turn。實作 alternative：
> - **A. 拆 stage**：每個 commit 點是一次 `claude -p` 呼叫，state 存 `state.json`，由外層 `run-justin.sh` 串起來
> - **B. 同 prompt 內 sleep + poll**：用 `Bash` 讀 telegram updates API（curl），需要 bot token + offset
>
> 推薦 B：在 SKILL.md 的 polling 步驟用 `Bash(curl)` 讀 `https://api.telegram.org/bot{TOKEN}/getUpdates?offset={last_id}`，每 5 秒 poll 一次直到 timeout。
>
> 此細節 v0.1.0 先用方案 B 預留，第一次實測時驗證可行性。
