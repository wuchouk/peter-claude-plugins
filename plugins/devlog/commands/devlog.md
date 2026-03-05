---
description: 建立開發日誌（記錄完成的開發專案）
allowed-tools: AskUserQuestion, Write, Read, Edit, Glob, Bash(date:*), Bash(mkdir:*), mcp__openmemory__add_memories, mcp__openmemory__search_memory
---

# /devlog — 開發日誌記錄系統

透過引導式訪談，把完成的開發專案記錄成結構化的 markdown 日誌。

## 重要原則

- **繁體中文**，保留使用者原話和技術細節
- 每次只問一個問題，等回答後再繼續
- 技術困難點要深入追問（症狀→原因→解法→學到什麼）
- **提問可見性**：用 AskUserQuestion 前，先用一般文字輸出完整問題。AskUserQuestion 的 question 參數只放簡短提示（某些環境文字顏色太淡）

## 日誌存放

`/Users/cubie/Documents/給Peter的檔案/devlogs/`（INDEX.md、projects.yaml、個別日誌）

## 參考資源

執行各階段時，讀取對應的參考文件取得詳細指引：

| 階段 | 參考文件 |
|------|----------|
| 訪談題目 | `${CLAUDE_PLUGIN_ROOT}/skills/devlog-recording/references/interview-guide.md` |
| 日誌模板 | `${CLAUDE_PLUGIN_ROOT}/skills/devlog-recording/assets/devlog-template.md` |
| 索引更新 | `${CLAUDE_PLUGIN_ROOT}/skills/devlog-recording/references/index-update-guide.md` |
| OpenMemory | `${CLAUDE_PLUGIN_ROOT}/skills/devlog-recording/references/openmemory-workflow.md` |

## 流程

### Stage 0 — 前置檢查

1. **取得客戶名稱**：`$ARGUMENTS` 不為空則直接使用，否則用 AskUserQuestion 詢問
2. **搜尋現有日誌**：Glob 掃描 devlogs 目錄（`*.md`），排除 INDEX.md，模糊匹配客戶名
3. **分流**：
   - 找到匹配 → 列出日誌，問「更新現有」或「建立新的」
   - 更新 → 讀取日誌顯示摘要，用 Edit 修改，完成後跳到 Stage 4
   - 新建 / 沒找到 → 繼續 Stage 1

### Stage 1 — 基本資訊

用 AskUserQuestion 收集（可合併 1-2 題）：開發工具、專案狀態、GitHub repo

### Stage 2 — 深入訪談

讀取 `interview-guide.md` 取得完整題目和追問策略，逐題引導

### Stage 3 — 產生日誌

1. `date +%Y-%m-%d` 取得日期
2. 讀取 `devlog-template.md` 取得模板
3. 檔名：`{Client}_{YYYY-MM-DD}.md`（Client 英文，空格用 `-`）
4. 寫入 devlogs 目錄
5. 顯示給使用者確認，有修改再調整

### Stage 4 — 更新索引

讀取 `index-update-guide.md`，更新 INDEX.md 和 projects.yaml

### Stage 5 — 寫入 OpenMemory

讀取 `openmemory-workflow.md`，執行去重檢查、寫入日誌指標和獨立教訓、驗證

### 完成

顯示摘要：日誌路徑、索引更新狀態、OpenMemory 寫入結果（含逐條驗證狀態）
