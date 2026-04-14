---
description: >
  This skill should be used when the user says "記錄開發日誌", "寫 devlog",
  "專案做完了", "record what we built", "log this project", "update devlog",
  or casual phrases like "記錄一下", "紀錄一下", "來記錄", "該記錄了" when
  the conversation context involves completed development work.
  Also trigger when a development milestone is reached (feature complete,
  bug fixed, deployment done) and the user mentions recording/logging in
  any form. When the user says "記錄" or "紀錄" after a development session,
  assume they mean devlog unless context clearly indicates otherwise.
  Do NOT trigger for minor changes, typo fixes, or exploratory research.
allowed-tools: AskUserQuestion, Write, Read, Edit, Glob, Bash(date:*), Bash(mkdir:*), mcp__openmemory__add_memories, mcp__openmemory__search_memory
---

# Devlog — 開發日誌記錄

## 為什麼要記錄

開發日誌不只是文件——它是可搜尋的知識庫。技術困難點的解法、踩過的坑、架構決策的原因，這些在三個月後會忘記。記錄下來讓未來的自己（和 AI 助手）能快速找到答案，避免重複犯錯。

## 流程概覽

### Stage 0 — 前置檢查
取得客戶名稱（從 `$ARGUMENTS` 或詢問使用者）。Glob 掃描 devlogs 目錄找匹配的現有日誌。找到則提供「更新 / 新建」選項；沒找到則進入新建流程。

### Stage 1 — 基本資訊
收集開發工具、專案狀態、GitHub repo。用 AskUserQuestion 合併為 1-2 個問題。

### Stage 2 — 深入訪談
逐題引導式訪談，每次只問一題。技術困難點要追問症狀→原因→解法→學到什麼。
詳細題目和追問策略見 `${CLAUDE_PLUGIN_ROOT}/skills/devlog-recording/references/interview-guide.md`。

### Stage 3 — 產生日誌
用模板產生結構化 markdown 日誌，寫入 `/Users/cubie/Documents/給Peter的檔案/devlogs/`。
模板見 `${CLAUDE_PLUGIN_ROOT}/skills/devlog-recording/assets/devlog-template.md`。
檔名格式：`{Client}_{YYYY-MM-DD}.md`。產生後先顯示讓使用者確認。

### Stage 4 — 更新索引
更新 INDEX.md 表格和 projects.yaml 結構化資料。
詳細格式和規則見 `${CLAUDE_PLUGIN_ROOT}/skills/devlog-recording/references/index-update-guide.md`。

### Stage 5 — 寫入 OpenMemory
寫入日誌指標和獨立教訓到 OpenMemory（如可用）。含去重檢查和寫入驗證。
詳細流程見 `${CLAUDE_PLUGIN_ROOT}/skills/devlog-recording/references/openmemory-workflow.md`。

### 完成
顯示摘要：日誌路徑、索引更新狀態、OpenMemory 寫入結果（含逐條驗證狀態）。

## 自動觸發判斷

**應該觸發**：
- 使用者說完成了一個功能、修好了 bug、部署完成
- 對話中有大量開發工作已完成的跡象
- 使用者明確要求記錄

**不應該觸發**：
- 小修改（typo、formatting、config 調整）
- 純探索性研究（沒有產出）
- 正在進行中、尚未到記錄時機的工作

## 互動原則

- 使用繁體中文
- 保留使用者原話和技術細節，不過度簡化
- 每次只問一個問題，等回答後再繼續
- 技術困難點要深入追問
- **提問可見性**：用 AskUserQuestion 前，先用一般文字輸出完整問題和說明。AskUserQuestion 的 question 參數只放簡短提示。這是因為 AskUserQuestion 在某些環境中文字顏色太淡。

## 日誌存放位置

```
/Users/cubie/Documents/給Peter的檔案/devlogs/
├── INDEX.md              # 索引表
├── projects.yaml         # 專案結構化描述
├── {Client}_{YYYY-MM-DD}.md  # 個別日誌
```
