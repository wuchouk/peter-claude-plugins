# 通用驗證積木起始集

本文件定義各種專案類型常見的驗證積木（primitives），供首次初始化 `primitives.yaml` 時選用。

---

## 積木格式說明

每個 primitive 包含：
- `id` — 唯一識別碼（kebab-case）
- `category` — 歸類（用於選單分組）
- `description` — 一句話說明
- `params` — 需要使用者填入的參數
- `detect` — 專案偵測條件（有哪些檔案/特徵時自動建議）

---

## HTTP API 類

### api-response-check
- **描述**：驗證 API 回傳的 JSON 欄位值
- **參數**：`url`, `method`, `field_path`, `expected_value`, `match_type`
- **偵測**：有 `package.json` (server) / `requirements.txt` (flask/fastapi) / `.clasp.json` (Apps Script webapp)
- **範例**：`GET /api/users → response.data.length == 5`

### api-status-code
- **描述**：驗證 HTTP 回傳的 status code
- **參數**：`url`, `method`, `expected_status`
- **偵測**：同上
- **範例**：`POST /api/login → 200`

### api-error-response
- **描述**：驗證錯誤情況的 API 回應
- **參數**：`url`, `method`, `payload`, `expected_status`, `expected_error_message`
- **偵測**：同上

---

## 資料庫 / 試算表類

### db-row-exists
- **描述**：驗證特定 row 存在
- **參數**：`table_or_tab`, `query_or_range`, `identifier`
- **偵測**：有 DB config / Google Sheets API / `.clasp.json`

### db-column-value
- **描述**：驗證特定欄位值
- **參數**：`table_or_tab`, `row_identifier`, `column`, `expected_value`, `match_type`
- **偵測**：同上

### db-row-count
- **描述**：驗證 row 數量
- **參數**：`table_or_tab`, `filter`, `expected_count`, `comparison` (eq/gt/lt)
- **偵測**：同上

### db-no-data
- **描述**：驗證資料不該出現
- **參數**：`table_or_tab`, `query_or_range`, `description`
- **偵測**：同上

---

## 檔案系統 / 雲端儲存類

### file-exists
- **描述**：驗證檔案存在或不存在
- **參數**：`path_or_folder`, `filename_pattern`, `should_exist` (true/false)
- **偵測**：所有專案

### file-content-match
- **描述**：驗證檔案內容符合條件
- **參數**：`path`, `pattern` (regex), `match_type` (contains/exact/not-contains)
- **偵測**：所有專案

### file-name-format
- **描述**：驗證檔名格式符合規範
- **參數**：`folder`, `format_regex`, `sample_count`
- **偵測**：有檔案輸出的專案

### cloud-storage-check
- **描述**：驗證雲端儲存（Drive/S3）的檔案
- **參數**：`folder_id_or_bucket`, `filename_pattern`, `should_exist`
- **偵測**：有 Google Drive API / AWS SDK

---

## Email / 訊息類

### email-label-check
- **描述**：驗證信件有/無特定標籤
- **參數**：`message_identifier`, `label_name`, `should_have` (true/false)
- **偵測**：有 Gmail API / `mcp__claude_ai_Gmail__*`

### email-content-check
- **描述**：驗證信件內容
- **參數**：`message_identifier`, `field` (subject/body/from), `expected_value`, `match_type`
- **偵測**：同上

---

## UI / 瀏覽器類

### page-element-exists
- **描述**：驗證頁面元素存在
- **參數**：`url`, `selector`, `should_exist`
- **偵測**：有 `index.html` / React/Vue/Svelte 設定

### page-text-content
- **描述**：驗證頁面文字內容
- **參數**：`url`, `selector`, `expected_text`, `match_type`
- **偵測**：同上

### page-visual-check
- **描述**：視覺截圖比對
- **參數**：`url`, `viewport`, `description`
- **偵測**：同上

---

## 批次驗證類

### bulk-consistency
- **描述**：N 筆資料一致性驗證
- **參數**：`data_source`, `count`, `check_fields`, `consistency_rule`
- **偵測**：有批次處理邏輯的專案

### idempotent-rerun
- **描述**：重跑結果相同（冪等性）
- **參數**：`trigger_command`, `check_primitives` (其他 primitive IDs), `run_count`
- **偵測**：有批次處理邏輯的專案

---

## CLI / 指令類

### cli-exit-code
- **描述**：驗證指令的 exit code
- **參數**：`command`, `expected_exit_code`
- **偵測**：有 `Makefile` / `bin/` / CLI 入口

### cli-output-match
- **描述**：驗證指令的 stdout/stderr
- **參數**：`command`, `stream` (stdout/stderr), `pattern`, `match_type`
- **偵測**：同上

---

## 專案類型偵測 → 建議積木對照表

| 專案特徵 | 偵測檔案 | 建議積木 |
|----------|----------|----------|
| Apps Script webapp | `.clasp.json` | api-response-check, api-status-code, db-column-value, db-row-exists |
| Google Sheets 整合 | `.clasp.json` + Sheet 操作 | db-column-value, db-row-count, db-no-data |
| Google Drive 整合 | Drive API 使用 | cloud-storage-check, file-name-format, file-exists |
| Gmail 整合 | Gmail API / MCP | email-label-check, email-content-check |
| Node.js API | `package.json` + server | api-response-check, api-status-code, api-error-response |
| Python API | `requirements.txt` + flask/fastapi | api-response-check, api-status-code, api-error-response |
| 前端 Web App | `index.html` / React | page-element-exists, page-text-content, page-visual-check |
| CLI 工具 | `bin/` / `Makefile` | cli-exit-code, cli-output-match, file-exists |
| 批次處理 | 有 loop/batch 邏輯 | bulk-consistency, idempotent-rerun |
