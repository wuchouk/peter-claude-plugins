# 驗證策略

## 工具選擇優先順序

1. **HTTP trigger**（最可靠）— 用 `curl ?action=getSheetData` / `getDriveFiles` / `getLastLog`
2. **Gmail MCP**（結構化資料）— 用 `gmail_list_labels` / `gmail_search_messages` / `gmail_read_message`
3. **claude-in-chrome**（視覺確認）— 只在需要截圖或上述方法不足時使用

## HTTP 驗證

### Sheet 資料讀取
```bash
curl -sL --max-time 60 "${WEBAPP_URL}?action=getSheetData&tab={TAB_NAME}&range={RANGE}"
```
回傳：`{"tab":"...","range":"...","data":[[...]]}`

常用 tab 名稱：
- `處理紀錄` — 主要處理紀錄
- `Sender 名單` — sender email → 角色對應
- `分類規則` — 學習整理後的規則
- `黃金測試集` — 評估測試用
- `評估紀錄` — 評估結果
- `修正統計` — 修正統計數據

### Drive 檔案列表
```bash
curl -sL --max-time 60 "${WEBAPP_URL}?action=getDriveFiles&folderId={FOLDER_ID}"
```
回傳：`{"folder":"...","files":[{"name":"...","size":123,"date":"..."}]}`

### 執行 Log
```bash
curl -sL --max-time 60 "${WEBAPP_URL}?action=getLastLog&search={KEYWORD}"
```
回傳：儲存在 PropertiesService 或 Sheet 隱藏 tab 的 log 內容。

**注意**：此功能需要在核心函式中加入 log capture 機制。如果尚未實作，會回傳 `{"note":"Log capture requires modification to core functions"}`。此時改用 claude-in-chrome 查看 Apps Script Execution Log。

## Gmail MCP 驗證

### 標籤結構驗證
```
gmail_list_labels → 過濾 name 以 "AI/" 開頭的標籤
```
預期的三層結構：
- `AI/收發碼/FC`、`AI/收發碼/FA`、`AI/收發碼/TA`、`AI/收發碼/TC`、`AI/收發碼/垃圾`
- `AI/狀態/待確認`、`AI/狀態/已確認`、`AI/狀態/自動辨識來源`
- `AI/收發碼/[失敗:1]` 等

### 標籤顏色驗證
`gmail_list_labels` 回傳的 label 物件含 `color` 欄位：
```json
{
  "id": "Label_xxx",
  "name": "AI/收發碼/垃圾",
  "color": {
    "textColor": "#666666",
    "backgroundColor": "#cccccc"
  }
}
```

### 信件標籤驗證
```
gmail_search_messages(q="label:AI/狀態/自動辨識來源 from:{sender}")
gmail_read_message(messageId) → 檢查 labelIds 陣列
```

## claude-in-chrome 驗證（降級方案）

只在以下情況使用：
1. 需要截圖存證
2. 需要驗證 dropdown 選項（Sheet data validation）
3. 需要查看 Apps Script Execution Log（getLastLog 未實作時）
4. HTTP 驗證結果不明確，需要視覺確認

### Sheet 操作模式
```
1. tabs_create_mcp → 開新分頁
2. navigate → SHEET_URL
3. javascript_tool → document.querySelector(...) 或直接讀取頁面內容
4. get_page_text → 搜尋特定文字
```

### Drive 操作模式
```
1. navigate → DRIVE_ROOT_URL 或特定資料夾 URL
2. get_page_text → 讀取檔案列表
3. 確認檔案存在/不存在
```

## 驗證結果判定

| 結果 | 標記 | 條件 |
|------|------|------|
| PASS | ✅ | 所有驗證點都符合預期 |
| FAIL | ❌ | 任何驗證點不符合預期 |
| SKIP | ⏭️ | 前置條件不滿足（如：找不到符合條件的信件） |
| TIMEOUT | ⏱️ | HTTP 呼叫超過 60 秒 |
| ERROR | 💥 | 系統錯誤（curl 失敗、MCP 斷線等） |
