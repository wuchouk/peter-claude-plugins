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
| `--retry-last` | + retry flag | 不開 YouTube/X（跳過 Step 1-5），只用 Playwright 跑 form | AskUserQuestion 或 Telegram 確認 retry | 視搭配 mode |

> ⚠️ **Scheduled mode 絕對不要呼叫 `mcp__plugin_telegram_telegram__*` 工具**。`run-justin.sh` 啟動 `claude -p` 時已經用 `--strict-mcp-config --mcp-config mcp-empty.json` 把所有 MCP server 關掉（避免 plugin 的 grammy 和 `wait-reply.sh` 搶 Telegram getUpdates）。送訊息一律用 `scripts/telegram-send.sh`，收回覆一律用 `scripts/wait-reply.sh`。

選好 mode 後，依 mode 讀對應的 reference：

- `interactive` → 讀 `${CLAUDE_PLUGIN_ROOT}/skills/justin-giveaway/references/chrome-mode.md`
- `scheduled` 或 `headless` → 讀 `${CLAUDE_PLUGIN_ROOT}/skills/justin-giveaway/references/playwright-mode.md`
- 任何 mode 都讀 `${CLAUDE_PLUGIN_ROOT}/skills/justin-giveaway/references/telegram-prompts.md`

### 為什麼 scheduled 用 Playwright 而不是 chrome-devtools？

chrome-devtools 連本地 Chrome 時，Chrome 會跳「Allow remote debugging?」dialog，需要人點 Allow。
Scheduled mode（launchd 觸發）沒人在電腦前，沒人點 Allow → 連不上。
Playwright 自己開 Chromium，用 storageState JSON 載入 cookies，完全不需要人。

## Retry mode (`--retry-last`)

**用途：** 上次跑完 `last_status` 是 `submitted_uncertain`，Peter 手動到 Google Form 確認**沒**送到，想用既有的留言/分享截圖**重新送一次 form**。也適用於 form 因為網路問題 / Drive 暫時掛掉等原因送出失敗的情況。

**前置條件**（不滿足直接 exit + 告知原因）：
- `state.json` 存在且有 `last_processed_video_id` + `last_form_url`
- `~/Library/Logs/justin-giveaway/screenshots/` 內至少 1 個 `comment-*.png` 和 1 個 `x-share-*.png`（從上次的執行留下）

**Flow**（取代主流程 Step 1-5）：

1. **Step 0 修改版** — 同主流程 Step 0 但**跳過清截圖步驟**（截圖是這次要用的素材）
2. 從 state.json 讀 `last_processed_video_id`、`last_form_url`、`last_status`
3. Glob `screenshots/comment-*.png` 和 `screenshots/x-share-*.png`，各取最新一個。找不到 → exit 1 + 告知「沒有可重用的截圖，請改跑完整 /justin」
4. **Retry 確認**（取代主流程 Step 3 的 Confirm #1）：
   - `interactive`：`AskUserQuestion` 「要重送 form 給影片 `{video_id}` 嗎？上次 status: `{last_status}`，會用截圖 `{comment_path}` + `{x_share_path}`」
   - `scheduled` / `headless`：Telegram 訊息 + `wait-reply.sh` 等 yes/no
   - 拒絕 / timeout → cleanup + exit
5. **跳過主流程 Step 4 (留言) 和 Step 5 (X 分享)** — 已經做過了
6. 跑主流程 **Step 6** (fill-form.mjs `--submit`)，用 `last_form_url` 當 `--form-url`，剛 glob 到的截圖路徑當 `--comment-screenshot` / `--share-screenshot`
7. **Step 7** 結算 — 同主流程，依 exit code 更新 state.json + 發 Telegram。**注意**：retry 成功會把 `last_status` 從 `submitted_uncertain` 蓋成 `submitted`

**`--retry-last --dry-run`**：印出「會用 video={id}, form={url}, comment={path}, x-share={path}」後直接 exit，不跑 fill-form.mjs。

**不會做的事**：
- 不重新偵測影片（影片從 state.json 拿）
- 不重新留言、不重新 X 分享（避免重複動作）
- 不清舊截圖（要拿來重用）
- 不檢查影片是不是「上次處理過」（這就是 retry 的目的，bypass 該檢查）

## 主流程

### Step 0: Setup

1. `mkdir -p ~/Library/Logs/justin-giveaway/screenshots`
2. **清掉上週的截圖**：`rm -f ~/Library/Logs/justin-giveaway/screenshots/*.png`  ← **如果是 `--retry-last`，跳過這步**
3. 開啟 log file `$LOG_DIR/$(date +%Y-%m-%d-%H%M).log`，所有 stage 寫入時間戳 + 動作
4. 讀 `state.json`（若存在）：取得 `last_processed_video_id`，避免重複處理同一支影片
5. 依 mode 初始化瀏覽器（chrome-devtools 或 Playwright）。**Retry mode 一律用 Playwright**（fill-form.mjs 跑在 Playwright）

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

### Step 3: 確認點（**唯一一個**）

⚠️ **整個流程只有這一個確認點。** Peter 回 yes 後，後續 Step 4–Step 6（留言 + X 分享 + form 填寫 + form submit）**全部自動執行，不再詢問**。Submit 不可逆，失敗時靠 Step 7 的 Telegram 結算訊息發現並手動補救。

依 mode 用對應方式詢問：
- `interactive`：`AskUserQuestion`「找到 giveaway 影片『{title}』，要繼續嗎？」
- `scheduled` / `headless`：**用 `bash scripts/telegram-send.sh send ...`**（不是 `mcp__plugin_telegram_telegram__*`，因為 scheduled session 是用 `--strict-mcp-config --mcp-config mcp-empty.json` 啟動，plugin 根本沒載入）。等 Peter 回 yes/no 用 `bash scripts/wait-reply.sh <chat_id> 300`。詳細模板和指令見 `telegram-prompts.md`。

若 `--dry-run`：列印偵測結果到 log 後直接 cleanup 結束。

若使用者拒絕或 timeout：cleanup 後結束。

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

### Step 6: Google Form（fill + submit 一次到位）

> ⚠️ **所有 mode 都用 fill-form.mjs 填 form。** Google Form 的 file upload 用 Drive picker（cross-origin iframe），只有 Playwright catch Browse 按鈕觸發的 native fileChooser event 才能繞過。

**（選用）進度訊息**：scheduled / headless mode 可以先送一個不等回覆的進度訊息，讓 Peter 看得到當前狀態：
```bash
bash ~/Projects/justin-giveaway/scripts/telegram-send.sh send <chat_id> "✅ 留言 + X 分享完成，開始填 form 並送出..."
```

呼叫 `fill-form.mjs` 直接帶 `--submit`，**一次完成填寫 + 上傳 + 送出**：

```bash
cd ~/Projects/justin-giveaway/scripts && node fill-form.mjs \
  --form-url "{form_url}" \
  --tv-name "{TRADINGVIEW_NAME}" \
  --comment-screenshot "~/Library/Logs/justin-giveaway/screenshots/comment-*.png" \
  --share-screenshot "~/Library/Logs/justin-giveaway/screenshots/x-share-*.png" \
  --submit \
  --headless
```

腳本內部流程：
1. 用 storageState cookies 開 Chromium（無頭）
2. 偵測並清掉 autosave draft（如果有上一次未完成的殘留）
3. 填 TradingView 名稱
4. 對每個 file field：click "Add file" → wait for Drive picker iframe → click "Browse" → intercept Playwright fileChooser event → setFiles → 等上傳完成
5. 等 picker 自動關閉；不關就按 Escape，再不關就點 picker 右上角 X
6. 截 verification screenshot 到 `/tmp/justin-form-filled.png`
7. Click Submit
8. 偵測「Your response has been recorded」/「您的回應已記錄」/「已記錄你的回覆」確認文字

**Exit code 語意**（重要 — Step 7 依此決定要不要寫 state.json）：
- **exit 0** = 確認文字偵測到 → form 確實送出。最後一行 log `✅ Form submitted successfully!`
- **exit 2** = Submit 按了但確認文字沒偵測到 → 狀態**不確定**（form 多半送出了，少數可能沒）。寫 `/tmp/justin-form-submit-result.png`，stderr 帶警告
- **exit 1** = 確定失敗（找不到 form / 上傳 throw / submit click 被擋等）。stderr 帶 error message

**不重試**（避免重複送 form）。exit 2 預設**當作已送出**處理 state.json，避免下次跑時誤判為未處理然後重複留言 + 分享 + 送 form。

**前置條件：**
- `~/.claude/justin-storage-state.json` 存在（Google + X 登入 cookies）
- 如果 cookies 過期（form 顯示未登入），重跑 bootstrap：
  ```bash
  cd ~/Projects/justin-giveaway/scripts && node bootstrap-auth.mjs
  ```

### Step 7: Cleanup + 寫 state + 結算訊息

1. 不論成功或失敗：close tabs（chrome mode）/ close browser context（playwright mode 由 fill-form.mjs 自己處理）
2. **依 Step 6 exit code 寫 `state.json`**：

   | exit code | state.json `last_status` | 行為 |
   |-----------|--------------------------|------|
   | 0 (確認送出) | `submitted` | 寫入 state.json，下次跳過 |
   | 2 (不確定) | `submitted_uncertain` | **仍寫入** state.json（避免重複送），但欄位明確標記不確定 |
   | 1 (確定失敗) | （不寫入） | 下次仍會處理 |

   ```json
   {
     "last_processed_video_id": "...",
     "last_processed_at": "ISO timestamp",
     "last_form_url": "...",
     "last_status": "submitted" | "submitted_uncertain"
   }
   ```
3. **不刪截圖** — 保留在 `~/Library/Logs/justin-giveaway/screenshots/`，Peter 可以在 Telegram 要求查看。下次 run 的 Step 0 會自動清掉上週的
4. Telegram 最終結算訊息（**附截圖**讓 Peter 自己驗收）：
   - **exit 0**：「✅ JUSTIN giveaway 完成」+ 附 `comment-*.png` + `x-share-*.png` + `/tmp/justin-form-filled.png` + submit 時間
   - **exit 2**：「⚠️ JUSTIN giveaway 已 Submit 但確認文字沒偵測到 — 請手動到 Google Form 確認是否真的送出。如果**沒**送到，跑 `/justin --retry-last` 用既有截圖只重送 form（不重複留言/分享）」+ 附 3 張截圖 + `/tmp/justin-form-submit-result.png`。state.json 已標記避免重複，**不會再自動跑這支影片**
   - **exit 1**：「⚠️ JUSTIN giveaway 中斷在 Step X」+ error 摘要 + log 路徑 + 已有的截圖
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
