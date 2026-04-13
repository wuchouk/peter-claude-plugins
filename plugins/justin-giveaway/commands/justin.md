---
description: JUSTIN投資日記 giveaway 自動化（YouTube 留言 + X 分享 + Google Form 上傳）
allowed-tools: AskUserQuestion, Read, Write, Edit, Glob, Grep, Bash(date:*), Bash(mkdir:*), Bash(jq:*), Bash(screencapture:*), Bash(open:*), Bash(node:*), Bash(cd:*), Bash(ls:*), Bash(cat:*), Bash(rm:*), mcp__chrome-devtools__list_pages, mcp__chrome-devtools__select_page, mcp__chrome-devtools__new_page, mcp__chrome-devtools__close_page, mcp__chrome-devtools__navigate_page, mcp__chrome-devtools__take_snapshot, mcp__chrome-devtools__take_screenshot, mcp__chrome-devtools__click, mcp__chrome-devtools__fill, mcp__chrome-devtools__type_text, mcp__chrome-devtools__press_key, mcp__chrome-devtools__evaluate_script, mcp__chrome-devtools__wait_for, mcp__chrome-devtools__upload_file, mcp__plugin_telegram_telegram__reply, mcp__plugin_telegram_telegram__edit_message, mcp__plugin_telegram_telegram__react
---

# /justin — JUSTIN 每週 giveaway 自動化

使用者輸入的參數：$ARGUMENTS

解析參數（如果有的話）：
- `--scheduled`：launchd 觸發的 Playwright headless 模式（用 Telegram 確認）
- `--headless`：同 scheduled（Playwright headless + Telegram 確認）
- `--dry-run`：只偵測不留言/不分享/不送 form
- 無參數：互動模式（預設 chrome-devtools 操控真實 Chrome）

跑 JUSTIN投資日記 (@justin-fu) 的每週 giveaway 流程：偵測新影片 → 留言「謝謝J大」→ X 分享 → 填 Google Form 上傳兩張截圖 → 等使用者最終確認後送出。

## 流程概要

詳細流程在主 SKILL.md，先讀以下參考檔再執行：

| 用途 | 路徑 |
|------|------|
| 主流程（決策樹 + 所有 Steps） | `${CLAUDE_PLUGIN_ROOT}/skills/justin-giveaway/SKILL.md` |
| chrome-devtools 操作（互動模式） | `${CLAUDE_PLUGIN_ROOT}/skills/justin-giveaway/references/chrome-mode.md` |
| Playwright 操作（scheduled/headless） | `${CLAUDE_PLUGIN_ROOT}/skills/justin-giveaway/references/playwright-mode.md` |
| Telegram 訊息模板 | `${CLAUDE_PLUGIN_ROOT}/skills/justin-giveaway/references/telegram-prompts.md` |

## 前置需求

1. **互動模式**（chrome-devtools）：Chrome 已開啟（port 9222）、需點 Allow remote debugging
2. **Scheduled/headless 模式**（Playwright）：`~/.claude/justin-storage-state.json` 存在（Google + X cookies）
3. **Telegram 確認回路**：telegram plugin 已 configure，bot token 設定好
4. **TradingView name**：sku772003
5. **帳號**：YouTube = ororov888@gmail.com (Cubie @Cubie-p2z)、X = @diamondhanddie

## 截圖存放

截圖固定存在 `~/Library/Logs/justin-giveaway/screenshots/`：
- `comment-{date}.png` — YouTube 留言截圖（含置頂留言 + 自己的留言）
- `x-share-{date}.png` — X 分享截圖
- `form-filled-{date}.png` — Google Form 填寫驗證截圖

下次 scheduled run 開始時（Step 0），先清掉上週的截圖再開始新的。
Peter 可以在 Telegram 要求查看本週截圖。
