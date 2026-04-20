---
name: justin-giveaway
description: 自動執行 JUSTIN投資日記 的每週 giveaway 流程（YouTube 留言「謝謝J大」+ X 分享 + Google Form 上傳兩張截圖）。支援互動模式（chrome-devtools）和 scheduled 模式（Playwright headless）。
---

# JUSTIN Weekly Giveaway

執行 JUSTIN投資日記 (@justin-fu) 的每週 giveaway 申請流程。

## 帳號資訊

```
YOUTUBE_ACCOUNT = ororov888@gmail.com (Cubie @Cubie-s1l)
X_ACCOUNT = @diamondhanddie (Cookie Monster)
GOOGLE_FORM_ACCOUNT = ororov888@gmail.com
TRADINGVIEW_NAME = sku772003
STORAGE_STATE = ~/.claude/justin-storage-state.json
```

## 變數（可改）

```
YOUTUBE_CHANNEL_URL = https://www.youtube.com/@justin-fu/videos
YOUTUBE_CHANNEL_NAME = JUSTIN投資日記
COMMENT_TEXT = 謝謝J大
GIVEAWAY_TITLE_KEYWORDS = ["送指標", "免費送", "留言抽", "giveaway", "留言免費", "送分", "免費指標", "免費分享"]
FORM_URL_PATTERNS = ["docs.google.com/forms", "forms.gle/"]
TIMEZONE = America/Los_Angeles
LOG_DIR = ~/Library/Logs/justin-giveaway
STATE_FILE = ~/Library/Logs/justin-giveaway/state.json
```

## 模式 (mode)

讀取使用者輸入的 flag 決定 mode：

| Flag | Mode | 瀏覽器 | 確認方式 | Telegram 發訊息 |
|------|------|--------|---------|---------------|
| （無） | `interactive` | chrome-devtools（操控真實 Chrome） | AskUserQuestion | （不用）|
| `--scheduled` | `scheduled` | **Playwright headless**（用 storageState cookies） | Telegram | **`scripts/telegram-send.sh`（curl）** |
| `--headless` | `headless` | Playwright headless（同 scheduled） | Telegram | **`scripts/telegram-send.sh`（curl）** |
| `--dry-run` | + dry_run flag | 同上述 mode | 只偵測 + 報告 | — |

> ⚠️ **Scheduled mode 絕對不要呼叫 `mcp__plugin_telegram_telegram__*` 工具**。`run-justin.sh` 啟動 `claude -p` 時已經用 `--strict-mcp-config --mcp-config mcp-empty.json` 把所有 MCP server 關掉（避免 plugin 的 grammy 和 `wait-reply.sh` 搶 Telegram getUpdates）。送訊息一律用 `scripts/telegram-send.sh`，收回覆一律用 `scripts/wait-reply.sh`。

選好 mode 後，依 mode 讀對應的 reference：

- `interactive` → 讀 `${CLAUDE_PLUGIN_ROOT}/skills/justin-giveaway/references/chrome-mode.md`
- `scheduled` 或 `headless` → 讀 `${CLAUDE_PLUGIN_ROOT}/skills/justin-giveaway/references/playwright-mode.md`
- 任何 mode 都讀 `${CLAUDE_PLUGIN_ROOT}/skills/justin-giveaway/references/telegram-prompts.md`

### 為什麼 scheduled 用 Playwright 而不是 chrome-devtools？

chrome-devtools 連本地 Chrome 時，Chrome 會跳「Allow remote debugging?」dialog，需要人點 Allow。
Scheduled mode（launchd 觸發）沒人在電腦前，沒人點 Allow → 連不上。
Playwright 自己開 Chromium，用 storageState JSON 載入 cookies，完全不需要人。

## 主流程

### Step 0: Setup

1. `mkdir -p ~/Library/Logs/justin-giveaway/screenshots`
2. **清掉上週的截圖**：`rm -f ~/Library/Logs/justin-giveaway/screenshots/*.png`
3. 開啟 log file `$LOG_DIR/$(date +%Y-%m-%d-%H%M).log`，所有 stage 寫入時間戳 + 動作
4. 讀 `state.json`（若存在）：取得 `last_processed_video_id`，避免重複處理同一支影片
5. 依 mode 初始化瀏覽器（chrome-devtools 或 Playwright）

### Step 1: 找最新影片

照當前 mode 的 reference 操作：

1. 開 `YOUTUBE_CHANNEL_URL`
2. 抓最新一支影片的 title、video_id、發佈時間、URL
3. 比對 `state.json.last_processed_video_id`
   - 若相同 → Telegram 通知「上次已處理過 {title}，跳過避免重複」→ cleanup → 結束
4. **不要用發佈時間做硬性 48 小時篩選** — JUSTIN 的 giveaway 截止日不固定，有時超過 48 小時仍有效。時間只做「參考提示」，不做 gate。

### Step 2: 判斷是否為 giveaway

**⚠️ 重要：pinned comment 的 form 連結是 definitive signal，title 關鍵字只是 hint。**

**即使 title 不含任何 giveaway 關鍵字，也必須進入影片頁檢查 pinned comment。**

1. 進入最新影片頁
2. 滾動載入留言區
3. 抓 pinned 留言（最上方有「📌」「Pinned by」標記的）
4. 從 pinned 留言全文搜尋 `FORM_URL_PATTERNS` 任一模式：
   - `docs.google.com/forms/...`
   - `forms.gle/...`（Google Form 短網址，JUSTIN 常用這個）
5. 同時抓 title 是否含 `GIVEAWAY_TITLE_KEYWORDS` 任一關鍵字（僅做標記，不做決策）

決策樹（**以 form 連結為準**）：
- **pinned 有 form 連結** → **是 giveaway**，記錄 `form_url`，前往 Step 3（不管 title 有沒有關鍵字）
- **pinned 沒有 form 連結 + title 有關鍵字** → 通知 + 暫停等使用者手動貼 form 連結（互動模式）或結束（scheduled）
- **pinned 沒有 form 連結 + title 也沒關鍵字** → 通知「本週影片『{title}』非 giveaway，跳過」→ cleanup → 結束
- **沒有 pinned 留言** → 同上

**dry-run 模式也要走到這一步**（進影片頁、讀 pinned comment），不能只看 title 就判定。Dry-run 在 Step 2 判斷完後報告結果 + cleanup 結束，不繼續 Step 3+。

### Step 3: 確認點 #1（影片偵測完）

依 mode 用對應方式詢問：
- `interactive`：`AskUserQuestion`「找到 giveaway 影片『{title}』，要繼續嗎？」
- `scheduled` / `headless`：**用 `bash scripts/telegram-send.sh send ...`**（不是 `mcp__plugin_telegram_telegram__*`，因為 scheduled session 是用 `--strict-mcp-config --mcp-config mcp-empty.json` 啟動，plugin 根本沒載入）。等 Peter 回 yes/no 用 `bash scripts/wait-reply.sh <chat_id> 300`。詳細模板和指令見 `telegram-prompts.md`。

若 `--dry-run`：列印偵測結果到 log 後直接 cleanup 結束。

若使用者拒絕：cleanup 後結束。

### Step 4: 留言「謝謝J大」

依 mode 的 reference 操作：
1. 滾到留言區
2. 點留言輸入框，輸入 `COMMENT_TEXT`
3. 按 Submit
4. 等 2-3 秒讓留言出現
5. **截圖（重要！）**：
   - 滾動到讓 **pinned comment（置頂留言）和自己剛留的留言都在畫面中**
   - 截 **viewport screenshot**（不是單一留言元素），這樣截圖同時包含：
     a. 置頂留言（證明是對的影片 / 有 form 連結）
     b. 自己的留言「謝謝J大」（證明有留言）
   - 存 `~/Library/Logs/justin-giveaway/screenshots/comment-$(date +%s).png`
   - **不要只截單一留言元素** — Google Form 需要看到留言在影片下方的上下文
6. log: `[Step 4] commented + screenshot saved to ...`

### Step 5: X 分享

1. 開新 tab/page 到 `https://x.com/intent/post?url={video_url}`（X 的官方分享 endpoint，自動帶連結，不加額外文字）
2. 點 Post 按鈕送出
3. 等 2-3 秒讓 tweet 完成
4. 導向到剛發的 tweet 頁面（X 送出後通常會顯示 "Your post was sent" 或跳到 tweet 頁）
5. **截圖**：截 tweet 元素（包含帳號名 + 影片連結），存 `~/Library/Logs/justin-giveaway/screenshots/x-share-$(date +%s).png`
6. log: `[Step 5] X share posted + screenshot saved to ...`

### Step 6: 確認點 #2（commit 完成）

把兩張截圖傳給 Telegram + 訊息：「留言和 X 分享都完成，截圖如附。準備填 form (TradingView: {TRADINGVIEW_NAME})，OK？」
等 Peter 回 yes 才繼續。

- `interactive`：用 `AskUserQuestion`（用 `Read` tool 讓截圖在 Claude Code UI 顯示即可）
- `scheduled` / `headless`：用 `bash scripts/telegram-send.sh photo` 各送一張截圖 + `send` 送文字，然後 `bash scripts/wait-reply.sh <chat_id> 300` 等 reply（指令見 `telegram-prompts.md`）

### Step 7: Google Form（用 Playwright fill-form.mjs）

> ⚠️ **所有 mode 都用 fill-form.mjs 填 form。** Google Form 的 file upload 用 Drive picker（cross-origin iframe），只有 Playwright 的 `setInputFiles` 能繞過。

呼叫 `fill-form.mjs` 腳本完成 form 填寫 + 上傳：

```bash
cd ~/Projects/justin-giveaway/scripts && node fill-form.mjs \
  --form-url "{form_url}" \
  --tv-name "{TRADINGVIEW_NAME}" \
  --comment-screenshot "~/Library/Logs/justin-giveaway/screenshots/comment-*.png" \
  --share-screenshot "~/Library/Logs/justin-giveaway/screenshots/x-share-*.png"
```

**不加 `--submit`** — 先讓腳本填好 form + 上傳截圖，但不送出。
腳本完成後會存驗證截圖到 `~/Library/Logs/justin-giveaway/screenshots/form-filled.png`。

**前置條件：**
- `~/.claude/justin-storage-state.json` 存在（Google + X 登入 cookies）
- 如果 cookies 過期（form 顯示未登入），重跑 bootstrap：
  ```bash
  cd ~/Projects/justin-giveaway/scripts && node bootstrap-auth.mjs
  ```

**fill-form.mjs 會自動處理：**
- Dismiss Google Forms 的 "Autosave your work" 彈窗
- 偵測 autosave draft（如果有之前上傳的檔案就跳過）
- 在 Drive picker iframe 內找 `input[type=file]` 直接用 `setInputFiles`（繞過 Browse 按鈕）
- 等待上傳完成

### Step 8: 確認點 #3（最終送出）

依 mode 詢問：
- `interactive`：展示 `~/Library/Logs/justin-giveaway/screenshots/form-filled.png` 給 Peter 看，用 `AskUserQuestion`「Form 已填好，截圖已上傳。要送出嗎？」
- `scheduled` / `headless`：`bash scripts/telegram-send.sh photo <chat_id> ~/Library/Logs/justin-giveaway/screenshots/form-filled.png "Form 已填好"` → `bash scripts/telegram-send.sh send <chat_id> "要送出嗎？回 yes 送出，回 no 取消"` → `bash scripts/wait-reply.sh <chat_id> 600`

收到 yes → 再跑一次 fill-form.mjs 加上 `--submit` flag：
```bash
cd ~/Projects/justin-giveaway/scripts && node fill-form.mjs \
  --form-url "{form_url}" \
  --tv-name "{TRADINGVIEW_NAME}" \
  --comment-screenshot "~/Library/Logs/justin-giveaway/screenshots/comment-*.png" \
  --share-screenshot "~/Library/Logs/justin-giveaway/screenshots/x-share-*.png" \
  --submit
```

收到 no 或 timeout → log + 不送出，告知 Peter「form 已填好但未送出，手動到 Chromium 視窗處理」

### Step 9: Cleanup + 寫 state

1. 不論成功或失敗：close tabs（chrome mode）/ close browser context（playwright mode）
2. 若 Step 8 成功送出：更新 `state.json`：
   ```json
   {
     "last_processed_video_id": "...",
     "last_processed_at": "ISO timestamp",
     "last_form_url": "...",
     "last_status": "submitted"
   }
   ```
3. **不刪截圖** — 保留在 `~/Library/Logs/justin-giveaway/screenshots/`，Peter 可以在 Telegram 要求查看。下次 run 的 Step 0 會自動清掉上週的
4. Telegram 最終結算訊息：「✅ JUSTIN giveaway 處理完成 / ⚠️ 中斷在 Step X」
5. 寫入 log file 「[done]」

## 失敗處理原則

- 任何 step fail → log 詳細錯誤 + Telegram 通知 + cleanup tabs/context + 不重試
- 重複動作風險（已留言/已分享/已送 form）大於失敗的價值，**禁止自動重試**
- 瀏覽器連不上 → 立刻 fail + Telegram 通知，請 Peter 手動補跑

## Cookies 維護

storageState cookies 的有效期：
- Google 登入 cookies（LSID 等）：**約 13 個月**
- X cookies：待觀察
- 建議每半年跑一次 `bootstrap-auth.mjs` 更新 cookies
- 如果某次 scheduled run 失敗且錯誤是「未登入」，就是 cookies 過期，重跑 bootstrap

## 時區處理

所有日期/時間運算用 `America/Los_Angeles`：
```bash
TZ=America/Los_Angeles date
```
JUSTIN 是 SF 作者，發片時間以 SF 為準，48 小時 window 也以 SF 為準。
