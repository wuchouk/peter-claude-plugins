---
name: autofill
description: "加密個資自動填表 — 安全地自動填寫 Web/PDF/Excel/Word 表單"
arguments:
  - name: action
    description: "動作：setup / web / pdf / excel / docx / edit / schema"
    required: true
  - name: path
    description: "檔案路徑（pdf/excel/docx 模式需要）"
    required: false
---

# /autofill Command

將使用者的請求轉交給 autofill skill 處理。

## 指令對應

根據 `$ARGUMENTS.action` 執行對應動作：

- **setup** → 首次設定：啟動 Web 編輯 UI 填寫個人資料，完成後自動加密
- **web** → 偵測 Chrome 當前頁面的表單欄位，產生映射，執行填表
- **pdf `$ARGUMENTS.path`** → 讀取 PDF 欄位名稱，產生映射，執行填表
- **excel `$ARGUMENTS.path`** → 讀取 Excel 欄位結構，產生映射，執行填表
- **docx `$ARGUMENTS.path`** → 讀取 Word 欄位結構，產生映射，執行填表
- **edit** → 啟動 Web 編輯 UI 修改已加密的個人資料，完成後重新加密
- **schema** → 顯示 schema-keys.txt 的可用欄位列表

### Web 編輯 UI

`setup` 和 `edit` 都使用 Web UI (`127.0.0.1:9876`) 讓使用者在瀏覽器中填寫/編輯資料。
- 資料只在本機處理，不經過 Claude API
- server 在使用者儲存後自動關閉
- Claude 不可讀取任何解密後的資料

請用 autofill skill 的邏輯來執行。
