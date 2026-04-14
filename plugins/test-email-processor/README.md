# test-email-processor Plugin

Email processor 自動化測試 — 透過 HTTP trigger (doGet Web App) + Gmail MCP + claude-in-chrome 驗證。

## 目前狀態

- [x] Plugin 骨架建立完成（plugin.json, marketplace.json, settings.json）
- [x] Command: `/test-email-processor`
- [x] Skill: SKILL.md（含所有測試組定義）
- [x] References: project-urls.md, verification.md, doget-code.md
- [x] Template: report.md
- [x] Plugin 已註冊到 `installed_plugins.json` 和快取
- [ ] **Code.gs 加入 doGet 程式碼**（需手動貼到 Apps Script）
- [ ] **部署 Web App**（一次性）
- [ ] **填入 project-urls.md**（Web App URL、Sheet URL、Drive URL）
- [ ] 重啟 Claude Code 驗證 `/test-email-processor` 出現
- [ ] 跑第一個測試驗證

## 檔案結構

```
plugins/test-email-processor/
├── .claude-plugin/
│   └── plugin.json                          # Plugin 中繼資料
├── README.md                                # 本文件
├── commands/
│   └── test-email-processor.md              # /test-email-processor 指令入口
└── skills/
    └── test-email-processor/
        ├── SKILL.md                         # 主邏輯：5 Phase + 所有測試組
        ├── references/
        │   ├── doget-code.md                # ★ doGet 程式碼（需貼到 Code.gs）
        │   ├── project-urls.md              # 客戶 URL 設定（需填入）
        │   └── verification.md              # 驗證策略文件
        └── templates/
            └── report.md                    # 測試報告模板
```

## 架構

```
使用者：/test-email-processor v3.2
    │
    ├─ Phase 0: 前置檢查
    │   ├─ 讀 project-urls.md 取得 URL
    │   ├─ curl ?action=ping 測連線
    │   └─ 確認 claude-in-chrome 可用
    │
    ├─ Phase 1: 解析測試項目（按版本篩選）
    ├─ Phase 2: 部署（MANUAL 提示 + curl setupAll）
    ├─ Phase 3: 測試執行
    │   ├─ Setup: curl ?action=setSenderRole / addLabel / ...
    │   ├─ Execute: curl ?action=trialRun / runFeedback / ...
    │   └─ Verify: Gmail MCP 查標籤 + curl ?action=getSheetData / getDriveFiles
    ├─ Phase 4: 報告（Markdown + 存檔）
    └─ Phase 5: 清理（curl ?action=cleanup / fullReset）
```

## 核心設計決策

### 為什麼用 HTTP trigger 而不是瀏覽器自動化

原本計畫用 claude-in-chrome 操作 Apps Script Editor（選函式→Run）和 Gmail UI（改標籤）。
改為 doGet Web App 後，所有 server-side 操作都用 curl 完成：

| 操作 | 原本方案 | 現在方案 |
|------|---------|---------|
| 跑 Apps Script 函式 | chrome 開 Editor → 選函式 → Run | `curl ?action=trialRun` |
| Gmail 改標籤 | chrome 開 Gmail → 點標籤選單 | `curl ?action=swapLabels&...` |
| Sheet 填資料 | chrome 開 Sheet → 點格子 → 打字 | `curl ?action=setSenderRole&...` |
| 驗證 Sheet 資料 | chrome 讀頁面 | `curl ?action=getSheetData&...` |

瀏覽器（claude-in-chrome）只用於唯讀截圖和 dropdown 驗證。

### trialRun 的 UI 繞過

Code.gs 的 `trialRun()` 用 `SpreadsheetApp.getUi().prompt()` 取得搜尋條件，Web App 下會失敗。
doGet 的 `trialRun` action 直接呼叫底層 `_processEmailBatch(query, limit, true)`，query 從 URL 參數傳入。

### Sheet 欄位對應（處理紀錄，0-based）

```
0: messageId    4: AI收發碼     8: AI語義名      12: 資料夾連結
1: 日期         5: AI推斷角色   9: AI信心         13: 最終收發碼
2: 原始標題     6: 歸檔案號    10: AI案件類別     14: 修正後名稱
3: sender       7: 內文案號    11: 來源確認狀態   15: 修正原因
```

### Sender 名單欄位

```
Col 0: Email 或 Domain
Col 1: 角色（C/A/G/S）
Col 2: 名稱備註
```

## 下一步

### 第一階段：讓 doGet 跑起來
1. 打開 `references/doget-code.md`
2. 複製「程式碼」區塊（從 `// ===================== doGet` 開始）
3. 貼到 Code.gs 最後面
4. Apps Script Editor → 部署 → 新增部署 → 網頁應用程式 → 我 / 只有自己
5. 複製 URL → 填入 `references/project-urls.md`
6. 測試：`curl -sL "{URL}?action=ping"`

### 第二階段：驗證 Plugin
1. 關閉所有 Claude Code session
2. 重新開 terminal → `claude`
3. `/skills` 確認 `test-email-processor` 出現
4. `/test-email-processor --ping` 測試連線

### 第三階段：跑測試
1. `/test-email-processor` 互動模式
2. 先跑最簡單的「標籤顏色驗證」（只用 Gmail MCP，不需 chrome）
3. 再跑完整 v3.2 測試
