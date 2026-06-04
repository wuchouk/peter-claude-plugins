---
description: >
  This skill should NOT auto-trigger. It is only invoked via /test-email-processor command.
  Do NOT trigger for general testing discussions, code reviews, or non-email-processor tasks.
allowed-tools: AskUserQuestion, Read, Write, Edit, Glob, Grep, Bash(curl:*), Bash(date:*), Bash(mkdir:*), Bash(jq:*), mcp__claude_ai_Gmail__gmail_search_messages, mcp__claude_ai_Gmail__gmail_read_message, mcp__claude_ai_Gmail__gmail_list_labels, mcp__claude_ai_Gmail__gmail_read_thread, mcp__claude-in-chrome__tabs_context_mcp, mcp__claude-in-chrome__tabs_create_mcp, mcp__claude-in-chrome__navigate, mcp__claude-in-chrome__get_page_text, mcp__claude-in-chrome__read_page, mcp__claude-in-chrome__javascript_tool, mcp__claude-in-chrome__find, mcp__claude-in-chrome__form_input, mcp__claude-in-chrome__computer, mcp__claude-in-chrome__read_console_messages, mcp__claude-in-chrome__gif_creator
---

# Email Processor 自動化測試 — 主邏輯

## 概覽

Email processor 的自動化測試系統。核心原理：
1. **執行**：透過 HTTP trigger（doGet Web App）呼叫 Apps Script 函式
2. **驗證**：用 Gmail MCP（標籤/信件查詢）+ claude-in-chrome（Sheet/Drive 讀取）確認結果
3. **報告**：生成 Markdown 報告 + 截圖存證

所有 server-side 操作（函式執行、Gmail 標籤增刪、Sheet 修改、Drive 管理）都透過 HTTP trigger 完成。
瀏覽器（claude-in-chrome）只用於**唯讀驗證和截圖**。

---

## Phase 0: 前置檢查

每次執行必須先完成以下檢查：

### 0.1 讀取專案設定
```
Read ${CLAUDE_PLUGIN_ROOT}/skills/test-email-processor/references/project-urls.md
```
取得 `CLIENT_NAME`、`WEBAPP_URL`、`SHEET_URL`、`DRIVE_ROOT_URL`。若任何必填欄位為空，提示使用者填入後再繼續。

### 0.2 測試 Web App 連線
```bash
curl -sL "${WEBAPP_URL}?action=ping"
```
預期回應：`{"status":"ok","version":"...","_action":"ping","_duration_ms":...}`

若失敗：提示使用者檢查 Web App 部署狀態。

### 0.3 確認 claude-in-chrome 可用
呼叫 `mcp__claude-in-chrome__tabs_context_mcp` 確認瀏覽器可連線。
若失敗：提示使用者啟動 Chrome + 安裝 Claude-in-Chrome extension。

### 0.4 建立報告目錄
```bash
mkdir -p /Users/cubie/Desktop/email-processor/test-reports
```

---

## Phase 1: 解析測試項目

### 引數處理

根據 `$ARGUMENTS` 決定模式：

| 引數 | 模式 | 動作 |
|------|------|------|
| （空） | 互動模式 | 列出所有可用測試組，讓使用者選擇 |
| `v3.2` / `v3.1` / `v3.3` | 版本篩選 | 只跑該版本的測試 |
| `--verify-only` | 純驗證 | 跳過函式執行，只驗證當前狀態 |
| `--cleanup` | 清理 | `curl ?action=cleanup` |
| `--reset` | 重置 | `curl ?action=fullReset` |
| `--ping` | 連線測試 | 只跑 Phase 0.2 |

### 測試組定義

以下是所有測試組。每組包含 setup → execute → verify 步驟。

---

#### 測試組：v3.2 垃圾信標籤 + 自動辨識 + Sender 學習

**Test 1: 新 sender 廣告信**
- Setup: 確認 inbox 有未知 sender 的廣告信
- Execute: `curl ?action=trialRun`
- Verify:
  - Gmail MCP: `gmail_search_messages(q="label:AI/狀態/自動辨識來源")` → 目標信件在結果中
  - HTTP: `curl ?action=getDriveFiles&folderId={未分類垃圾資料夾ID}` → EML 存在、無附件
  - HTTP: `curl ?action=getSheetData&tab=處理紀錄&range=...` → 來源確認狀態=pending

**Test 2: 已知 Spam sender**
- Setup: `curl ?action=setSenderRole&email={sender}&role=S`
- Execute: `curl ?action=trialRun`
- Verify:
  - Gmail MCP: `gmail_read_message` → labelIds 不含 `AI/狀態/自動辨識來源`
  - HTTP: `curl ?action=getDriveFiles&folderId={垃圾資料夾ID}` → 無該 sender 的新 EML
  - HTTP: `curl ?action=getSheetData&tab=處理紀錄&range=...` → 來源確認狀態=na

**Test 3: 有案號廣告信**
- Setup: 用 Gmail MCP 搜尋有案號的廣告信（需 Claude 判斷）
- Execute: `curl ?action=trialRun`
- Verify:
  - Gmail MCP: 標籤是 FX 不是垃圾
  - HTTP: `curl ?action=getDriveFiles` → EML 在正確案號資料夾

**Test 4: 確認垃圾回授**
- Setup: `curl ?action=removeLabel&messageId={id}&label=AI/狀態/自動辨識來源`
- Execute: `curl ?action=runFeedback`
- Verify:
  - HTTP: `curl ?action=getSheetData&tab=Sender 名單` → 出現該 sender 角色=S
  - HTTP: `curl ?action=getSheetData&tab=處理紀錄` → 來源確認狀態=confirmed

**Test 5: 修正垃圾回授**
- Setup: `curl ?action=swapLabels&messageId={id}&remove=AI/收發碼/垃圾&add=AI/收發碼/FC` + `curl ?action=removeLabel&messageId={id}&label=AI/狀態/自動辨識來源`
- Execute: `curl ?action=runFeedback`
- Verify:
  - HTTP: `curl ?action=getSheetData&tab=Sender 名單` → 角色=C
  - HTTP: `curl ?action=getDriveFiles` → EML 從未分類/垃圾搬到正確資料夾
  - HTTP: `curl ?action=getDriveFiles` → 附件已下載
  - HTTP: `curl ?action=getSheetData&tab=處理紀錄` → 資料夾連結已更新

**Test 6: Sender 名單 dropdown**
- Execute: `curl ?action=migrateSenderDropdown`
- Verify: claude-in-chrome 開 Sheet → 點 B 欄 → 確認下拉有 C/A/G/S

**Test 7: 標籤顏色**
- Execute: `curl ?action=setLabelColors`
- Verify: Gmail MCP `gmail_list_labels` → `AI/收發碼/垃圾` 有 color 欄位且為灰色系

---

#### 測試組：v3.1 Bug 修復

**Fix 1: 收發碼方向衝突**
- Setup: 在處理紀錄找同 thread 有 FA+TA 的 pending rows
- Execute: `curl ?action=runFeedback`
- Verify:
  - HTTP: `curl ?action=getSheetData` → TA rows 來源確認狀態=confirmed
  - HTTP: `curl ?action=getSheetData` → 最終收發碼欄位沒有 FA

**Fix 2: 碼改名**
- Setup: `curl ?action=swapLabels&messageId={id}&remove=AI/收發碼/FX&add=AI/收發碼/FA`
- Execute: `curl ?action=runFeedback`
- Verify:
  - HTTP: `curl ?action=getDriveFiles` → EML 檔名收發碼從 FX 變 FA
  - HTTP: `curl ?action=getLastLog&search=碼改名` → 有 `📄 碼改名:` 訊息

**Fix 3: 簽名圖片過濾**
- Execute: `curl ?action=processEmails`
- Verify:
  - HTTP: `curl ?action=getLastLog&search=過濾簽名圖片` → 有 `🗑️ 過濾簽名圖片:` 訊息
  - HTTP: `curl ?action=getDriveFiles` → 無 <5KB jpg/png

**Fix 4: thread_context 污染**
- Setup: Gmail MCP 搜尋主旨只有 1 個案號的信
- Execute: `curl ?action=processEmails`
- Verify:
  - HTTP: `curl ?action=getDriveFiles` → 只存到 1 個案號資料夾

---

#### 測試組：v3.1 新功能

**公司名稱查詢**
- Setup: HTTP 找 pending + 自動辨識來源的 rows
- Execute: `curl ?action=runFeedback`
- Verify:
  - HTTP: `curl ?action=getSheetData` → 備註欄 `AI推斷確認-{公司名}` 格式

---

#### 測試組：部署全面驗證

**Step 1: Gmail 標籤系統**
- Execute: `curl ?action=resetAllAILabels`
- Verify:
  - Gmail MCP: `gmail_list_labels` → 確認 AI/收發碼/FC、AI/狀態/待確認 等三層巢狀結構
- Execute: `curl ?action=setLabelColors`
- Execute: `curl ?action=trialRun`
- Verify:
  - Gmail MCP: `gmail_read_message` → labelIds 路徑含 `AI/收發碼/` 前綴

**Step 2: 回饋機制**
- Setup: Gmail 標籤修正 → `curl ?action=swapLabels`
- Execute: `curl ?action=runFeedback`
- Verify: HTTP getSheetData → Sender 名單更新
- Setup: HTTP setCorrectedName
- Execute: `curl ?action=runFeedback`
- Verify: HTTP getDriveFiles → 檔案改名
- Setup: HTTP setFinalCode
- Execute: `curl ?action=runFeedback`
- Verify: HTTP getSheetData → Sender 名單更新

**Step 3: 學習整理 Pipeline**
- Setup: HTTP 填 3+ 筆修正
- Execute: `curl ?action=runFeedback` then `curl ?action=consolidateLearning`
- Verify:
  - HTTP: `curl ?action=getSheetData&tab=分類規則` → 底部有新 L{nn} 規則
  - Execute: `curl ?action=trialRun` → HTTP getLastLog 搜尋 prompt 內容
  - HTTP: `curl ?action=getSheetData` → `+consolidated` 標記

**Step 4: SYSTEM_PROMPT 微調**
- Execute: `curl ?action=trialRun`
- Verify: HTTP getSheetData → Sheet 語義名改善（需 Claude 判斷）
- Execute: `curl ?action=exportPromptDoc`
- Verify: HTTP getDriveFiles → Doc 存在

**Step 5: 回授評估系統**
- Execute: `curl ?action=seedGoldenSet`
- Verify: HTTP getSheetData → 黃金測試集有新列
- Execute: `curl ?action=runEvaluation`
- Verify: HTTP getSheetData → 評估紀錄有 detail + summary rows
- Setup: HTTP modifyGoldenSet（修改預期值）
- Execute: `curl ?action=runEvaluation`
- Verify: HTTP getSheetData → 標紅 + email 通知
- Execute: `curl ?action=updateCorrectionStats`
- Verify: HTTP getSheetData → 修正統計有本週數據
- Execute: `curl ?action=consolidateLearning`
- Verify: HTTP getSheetData → 自動觸發 runEvaluation

---

#### 測試組：v3.3 Excel V22 規則同步

- Execute: `curl ?action=trialRun`（暫時案/CA案/CIP案信件）
- Verify: HTTP getSheetData + getDriveFiles → 正確分類
- Execute: `curl ?action=trialRun`（一般信件回歸）
- Verify: 基本功能正常

---

## Phase 1.5: 測試計畫 Review

解析完測試項目後，**必須先讓使用者 review 測試計畫，確認後才進入 Phase 2**。

### 1.5.1 從 TODO.md 提取測試資訊

讀取專案 TODO.md 的 Active section，提取每個待測項目的結構化欄位：
- 背景、修正、測試方法、✅ 預期、❌ 可能錯誤

若 TODO 項目缺少結構化欄位（舊格式），根據測試組定義和 Code.gs 函式邏輯自行補充。

### 1.5.2 產出 Review 表格

對每個即將執行的測試，輸出：

---

**{測試名稱}**（🤖 自動 / 👤 手動）

| 項目 | 內容 |
|------|------|
| **背景** | 為什麼改、之前錯什麼（從 TODO 拉） |
| **測試方法** | 觸發什麼函式、用什麼工具驗證 |
| **✅ 預期正確結果** | 具體欄位值、標籤狀態、檔案位置 |
| **❌ 可能的錯誤情況** | 2-3 種失敗狀況和原因 |
| **非預期結果處理** | 🛑 暫停找使用者 / 🔧 可自行嘗試 |

---

### 1.5.3 「非預期結果處理」預設標記

- **🛑 暫停找使用者**（預設）— 結果不在預期正確或已列出的錯誤情況中
- **🔧 可自行嘗試** — 僅限明確的環境/前置條件問題（找不到測試資料、curl timeout）

使用者在 review 時可調整標記。

### 1.5.4 Review 流程

1. 輸出所有測試的 review 表格
2. 使用 `AskUserQuestion` 請使用者確認或修改
3. 使用者確認後才進入 Phase 2
4. 若使用者修改了預期或標記，更新內部測試定義

---

## Phase 2: 部署（除非 --verify-only）

### MANUAL 項目提示

如果測試組包含部署步驟，輸出以下提示：

```
🔴 手動操作需要你完成：
1. 複製 Code.gs 到 Apps Script Editor
2. 如果是新部署：部署 → 新增部署 → 網頁應用程式 → 執行身分「我」→ 存取權限「只有自己」
3. 如果是更新：管理部署 → 更新版本號
4. 完成後告訴我「好了」繼續
```

使用 `AskUserQuestion` 等待使用者確認。

### 自動 Setup
```bash
curl -sL "${WEBAPP_URL}?action=setupAll"
```

---

## Phase 3: 測試執行

### 執行策略

1. 按測試組順序執行
2. 每個測試項：
   - 輸出測試名稱和步驟
   - 執行 setup（如有）
   - 執行函式（curl doGet）
   - 等待回應（檢查 `status` 欄位）
   - 執行驗證
   - 記錄 PASS / FAIL + 原因
3. **遇到失敗不中斷**，記錄後繼續下一項
4. 每個測試組完成後輸出小結
5. **非預期結果處理**：
   - 結果符合「✅ 預期」→ PASS
   - 結果符合「❌ 可能錯誤」→ FAIL，記錄對應原因
   - 結果不在以上兩者中 → 檢查該測試的處理標記：
     - 🛑 → 立即暫停，向使用者報告實際結果 vs 預期結果，等待指示
     - 🔧 → 嘗試一次修正/重試，若仍非預期則暫停

### HTTP 呼叫模式

所有函式呼叫使用同一模式：
```bash
curl -sL "${WEBAPP_URL}?action={ACTION}&{PARAMS}" | jq .
```

**重要**：
- 必須加 `-L`（follow redirects，Apps Script Web App 會 302）
- 回應是 JSON，用 `jq` 格式化
- 檢查回應的 `status` 欄位：`success` 或 `error`
- 如果 `error`，記錄 `error` 和 `stack` 欄位
- curl timeout 設為 60 秒：`curl -sL --max-time 60`

### Gmail MCP 驗證模式

```
gmail_list_labels → 驗證標籤結構（名稱、顏色、層級）
gmail_search_messages(q="label:XXX") → 驗證信件有/無特定標籤
gmail_read_message(messageId) → 驗證信件詳細資訊（labelIds, snippet）
```

### Sheet/Drive 驗證模式（優先用 HTTP）

盡量用 HTTP trigger 的 `getSheetData` / `getDriveFiles` 取得結構化資料。
只在需要視覺確認或截圖時才用 claude-in-chrome。

> **Dropbox 部署（v3.38+）**：`getDriveFiles` 會根據 `CONFIG.STORAGE_PROVIDER` 自動
> dispatch 到 Drive 或 Dropbox。回傳格式新增 `provider` 欄位（`'drive'` 或 `'dropbox'`）。
> Dropbox 時 `folderPath` 可傳相對路徑（相對 `DROPBOX_ROOT_PATH`）或絕對路徑（`/...`）；
> `folderId` 被忽略。檔案物件多一個 `path` 欄位（Dropbox 完整路徑）。
> 子資料夾不含 `id`，改用 `path`。

claude-in-chrome 驗證步驟：
1. `tabs_create_mcp` 開新分頁
2. `navigate` 到目標 URL
3. 等頁面載入（2-3 秒）
4. `get_page_text` 或 `javascript_tool` 讀取資料
5. 截圖存證（選擇性）

---

## Phase 4: 報告生成

測試完成後，讀取報告模板：
```
Read ${CLAUDE_PLUGIN_ROOT}/skills/test-email-processor/templates/report.md
```

填入以下資訊：
- 客戶名稱、測試時間、版本、模式
- 每個測試項的 PASS/FAIL + 詳細資訊
- 失敗項的 error message 和可能原因
- 統計摘要（通過/失敗/跳過）

報告存到：
```
/Users/cubie/Desktop/email-processor/test-reports/report-{date}-{time}.md
```

同時在 terminal 輸出摘要。

---

## Phase 4.5: 更新 TODO.md

測試報告生成後，自動更新專案的 `TODO.md`。

### 4.5.1 讀取 TODO.md
```
Read {PROJECT_ROOT}/email-processor/TODO.md
```
其中 `{PROJECT_ROOT}` 從 `project-urls.md` 的 `PROJECT_ROOT` 取得，若未定義則用 `~/Desktop/IPWinner`。

### 4.5.2 比對測試結果與 TODO 項目

掃描 TODO.md 的 `## Active` 區段，用以下邏輯比對：

1. **找到對應的版本區塊**：測試組名稱（如 `v3.2`、`v3.1`）→ 比對 TODO 中的 `### v3.2 ...`、`### v3.1 ...` 區塊
2. **比對測試項**：每個 PASS/FAIL 的測試項 → 比對 TODO 中相關的 `- [ ]` 項目。比對邏輯用**語義匹配**（不要求精確字串相同），例如：
   - 測試 "已知 Spam sender" PASS → 勾選 TODO 中提到 "已知 Spam sender" 或 "角色=S" 的項目
   - 測試 "標籤顏色" PASS → 勾選 TODO 中提到 "標籤顏色" 或 "setLabelColors" 的項目
3. **部署項目**：若 Phase 2 部署成功完成（setupAll 回應 success），勾選對應區塊的部署項目

### 4.5.3 更新規則

| 測試結果 | TODO 更新動作 |
|----------|--------------|
| ✅ PASS | `- [ ]` → `- [x]` |
| ❌ FAIL | 保留 `- [ ]`，在該項後面加上 `⚠️ FAIL: {錯誤摘要}`（同一行或下一行） |
| ⏭️ SKIP | 保留 `- [ ]` 不動 |
| ⏱️ TIMEOUT | 保留 `- [ ]`，加上 `⚠️ TIMEOUT` |
| 💥 ERROR | 保留 `- [ ]`，加上 `⚠️ ERROR: {錯誤訊息}` |

### 4.5.4 整個區塊完成處理

如果某個 `### 版本區塊` 下的**所有** `- [ ]` 項目都被勾選（變成 `- [x]`）：
1. 將該區塊的標題從「待部署測試」改為「✅ 已通過（{日期}）」
2. 將整個區塊搬到 `## Completed` 區段（保留原內容）

### 4.5.5 新增失敗修復項目

如果有任何 FAIL/ERROR 測試項，在 `## Active` 頂部新增一個修復區塊：

```markdown
### 🔧 測試失敗待修復（{日期}）

- [ ] {失敗測試 1 的描述} — {錯誤摘要}
- [ ] {失敗測試 2 的描述} — {錯誤摘要}
```

### 4.5.6 寫回 TODO.md

使用 Edit 工具更新 TODO.md，保持其餘內容不變。

完成後在 terminal 輸出：
```
📋 TODO.md 已更新：
   ✅ {N} 項標記完成
   ⚠️ {M} 項標記失敗（待修復）
   ⏭️ {K} 項跳過（未變更）
```

---

## Phase 5: 清理

測試結束後詢問使用者：
```
測試完成。要清理測試資料嗎？
- cleanup：清理 Drive/Sheet/Gmail 標籤
- reset：清理 + 重建環境
- 跳過：保留現狀（下次測試前手動清理）
```

清理命令：
```bash
curl -sL "${WEBAPP_URL}?action=cleanup"   # 清理
curl -sL "${WEBAPP_URL}?action=fullReset" # 清理 + 重建
```

---

## 錯誤處理

| 情況 | 處理 |
|------|------|
| Web App 無回應 | 提示檢查部署狀態，中斷測試 |
| curl 回傳 `error` | 記錄錯誤，繼續下一項 |
| Gmail MCP 搜不到信件 | 記錄為 SKIP（前置條件不滿足），繼續 |
| claude-in-chrome 無法連線 | 降級為只用 HTTP 驗證，記錄受影響項目 |
| 函式執行超過 60 秒 | curl timeout，記錄為 TIMEOUT |

---

## 擴展性

新測試只需要：
1. 在 Code.gs 的 doGet switch 加一行（新函式）
2. 更新此 SKILL.md 的測試組定義

三種測試模式完整覆蓋：
- **跑函式 → 驗證結果**
- **改 Sheet → 跑函式 → 驗證結果**
- **改 Gmail 標籤 → 跑函式 → 驗證結果**

未來新客戶：複製 `project-urls.md` 填入該客戶的 URL，測試組定義按該客戶的 Code.gs 調整。
