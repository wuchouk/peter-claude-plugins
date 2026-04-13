# Telegram 訊息模板 + 確認回路

`scheduled` 和 `headless` 模式下的 commit 點都用 Telegram 發訊息給 Peter，等 reply。互動模式下只有最終「送出 form」前會用 Telegram（其他確認用 AskUserQuestion）。

## 用到的 tool

- `mcp__plugin_telegram_telegram__reply` — 送訊息（可帶 `files: ["/tmp/...png"]` 附圖）
- `mcp__plugin_telegram_telegram__edit_message` — 進度更新（同一條訊息改內文）
- `mcp__plugin_telegram_telegram__react` — 用 emoji 反應（簡單狀態變更）

> Telegram 不會主動 push 給 skill，要等 Peter 回的訊息進到 conversation。Skill 用 polling 模式：發訊息後 wait + 監聽 inbound channel message。實作上 timeout 5-10 分鐘，超時 fallback。

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

### #4 留言 + X 分享完成，等確認 (#2)

```
✅ 留言「謝謝J大」已發出
✅ X 分享已 post

附上兩張截圖，準備填 form：
- TradingView name: sku772003
- 上傳截圖 1: YouTube 留言
- 上傳截圖 2: X 分享

OK？回 yes 繼續填 form
```

附 `files: ["/tmp/justin-comment-*.png", "/tmp/justin-x-share-*.png"]`

⏳ Timeout 5 分鐘 → 通知並停止。

### #5 Form 已填好，等最終送出 (#3)

```
📝 Google Form 已填好：
- TradingView: sku772003 ✅
- YouTube 截圖: 已上傳 ✅
- X 截圖: 已上傳 ✅

⚠️ 即將送出表單。回 yes 送出，no 取消（form 會留著讓你手動處理）
```

⏳ Timeout 10 分鐘 → 不送出，告知 Peter form 還開著。

### #6 完成

```
🎉 JUSTIN giveaway 處理完成
影片：{title}
Form 已送出時間：{ISO timestamp}
Log：~/Library/Logs/justin-giveaway/{filename}.log
```

### #7 失敗 / 中斷

```
⚠️ JUSTIN giveaway 中斷
階段：{step name}
原因：{error message}
Log：~/Library/Logs/justin-giveaway/{filename}.log

請手動補完，或重跑 /justin
```

## Polling 邏輯（等 reply）

```python
# 偽碼
def wait_for_telegram_reply(chat_id, timeout_seconds=300):
    start = time.time()
    while time.time() - start < timeout_seconds:
        # Telegram bot API 沒有 long poll for skill，靠 telegram plugin 把 inbound 訊息送進 conversation
        # 實作上：用 mcp__plugin_telegram_telegram__... 沒有 read，要等 user 訊息透過 hook 進來
        # 替代方案：用 react 標記等待狀態（⏳），讓使用者知道 bot 在等
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
