---
description: >
  分析既有專案的模組化程度，找出耦合過高的區域，產出重構建議報告。
  Use when the user says "模組化分析", "分析結構", "重構建議", "modularize",
  "check modularity", "structure review", "耦合分析", "拆模組",
  "看一下結構", "這個專案該怎麼拆", "refactor check",
  or when the user wants to understand the current project structure
  before refactoring for better collaboration.
  Do NOT trigger for new projects (use /plan-eng-review instead).
  Do NOT auto-refactor — only produce analysis and recommendations.
allowed-tools: Read, Glob, Grep, Bash(wc:*), Bash(find:*), Agent
---

# Modularize — 專案模組化分析

## 目的

分析既有專案的檔案結構和依賴關係，找出耦合過高的區域，產出可行動的重構建議報告。
**只分析、不自動重構**——報告產出後由使用者和合作者討論再執行。

## 分析流程

### Phase 1 — 專案掃描

1. 用 Glob 掃描專案的檔案結構，建立目錄樹概覽
2. 辨識專案類型和技術棧（前端/後端/全端、語言、框架）
3. 統計各目錄的檔案數量和大小分佈

### Phase 2 — 耦合分析

用 Grep 和 Read 分析以下面向：

**檔案層級問題：**
- 🔴 **混合職責檔案**：單一檔案超過 200 行，且包含多種職責（route + logic + DB）
- 🟡 **過大檔案**：超過 300 行的檔案，可能需要拆分
- 🟡 **命名不明確**：`utils.js`、`helpers.ts`、`misc.py` 等萬用桶檔案

**模組層級問題：**
- 🔴 **循環依賴**：A import B 且 B import A（或更長的循環鏈）
- 🔴 **深度 import**：外部直接 import 模組內部檔案（例如 `import { x } from '../archive/internal/parser'`）
- 🟡 **扇出過高**：單一檔案 import 超過 8 個不同模組
- 🟡 **缺乏入口**：資料夾沒有 `index.ts` / `__init__.py` 作為統一出口

**協作層級問題：**
- 🔴 **共用混雜**：共用 utilities 散落在各功能目錄，而不是集中在 `shared/` 或 `lib/`
- 🟡 **無明確邊界**：看不出哪些目錄是獨立模組、哪些是內部實作

### Phase 3 — 產出報告

產出結構化的 markdown 報告，包含：

```markdown
# 模組化分析報告 — {專案名稱}

## 概覽
- 專案類型：{type}
- 技術棧：{stack}
- 檔案總數：{count}
- 分析日期：{date}

## 現有結構
{目錄樹，標注每個目錄的職責}

## 問題發現

### 🔴 高優先（建議優先處理）
{列出 critical issues，每項含：位置、問題描述、影響}

### 🟡 中優先（有空時處理）
{列出 medium issues}

## 建議目標結構
{重構後的理想目錄結構，標注每個模組的職責和 interface}

## 重構步驟建議
{按優先順序排列的具體步驟，每步驟含：}
1. 做什麼
2. 為什麼
3. 影響範圍（哪些檔案會動到）
4. 風險（可能壞掉什麼）

## 模組邊界定義（可直接貼入 engineering plan）
{每個模組的職責、對外 interface、建議負責人分工}
```

報告寫入 `docs/modularize-report.md`。

## 互動原則

- 使用繁體中文
- 分析完成後先展示摘要，讓使用者確認再寫入檔案
- 如果專案很小（< 10 個檔案），直接告知「目前結構合理，暫不需要重構」
- 對每個問題都解釋「為什麼這是問題」——使用者可能沒有軟體工程背景
- 重構步驟要具體到檔案層級，不要只給原則性建議

## 注意事項

- 這是分析工具，**絕對不要自動修改任何程式碼**
- 如果使用者想執行重構，建議先建立 git branch 再開始
- 報告中的「建議目標結構」是方向性建議，需要根據實際情況調整
