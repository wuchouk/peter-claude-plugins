---
name: autofill
description: "加密個資自動填表 — 偵測表單欄位、建立映射、執行本機加密填表。觸發詞：autofill、填表、自動填寫、fill form、表單。當使用者說「幫我填這個表」「自動填入」「fill this form」時觸發。"
---

# Autofill Skill — 加密個資自動填表

## SECURITY RULES（最高優先級）

1. Claude **永遠不可以**讀取 `~/.claude-autofill/data.enc` 或任何解密後的檔案
2. Claude **永遠不可以**直接執行 `openssl enc -d` 或任何解密指令
3. Claude 只能透過 `fill-web.sh` / `fill-pdf.py` / `fill-excel.py` / `fill-docx.py` 間接觸發解密
4. 腳本的 stdout 只輸出狀態訊息，Claude **不可以**讀取任何資料值
5. 映射 JSON 只包含 selector/key 對應，**不包含實際值**
6. Claude 可以讀取 `schema-keys.txt`（只有欄位路徑名稱，沒有值）
7. Claude 可以讀取 `config.yaml`（設定檔，不含機密）

## 檔案位置

- Plugin: `${CLAUDE_PLUGIN_ROOT}/`
- Scripts: `${CLAUDE_PLUGIN_ROOT}/scripts/`
- Data: `~/.claude-autofill/`
- Schema keys: `~/.claude-autofill/schema-keys.txt`（Claude 可讀）
- Config: `~/.claude-autofill/config.yaml`（Claude 可讀）
- Mappings: `~/.claude-autofill/mappings/`（Claude 可讀寫）
- References: `${CLAUDE_PLUGIN_ROOT}/skills/autofill/references/`

## Multi-Entry Fields

v2 schema 的 phones、emails、passports 是陣列，可能有多筆資料。

### 建立映射時的選擇邏輯

1. **phones**：讀取 schema-keys.txt 中的 phones 結構。如果使用者有多筆電話（透過 label 區分，如 `taiwan_mobile`、`us_mobile`），且表單需要電話號碼時：
   - 只有一筆 → 直接使用 `phones[0]`
   - 有多筆 → 詢問使用者要用哪一筆（列出 label），再決定 index
   - 國際格式 → 使用 `keys`+`join` 合成 country_code + number，搭配 `phone_international` transform

2. **emails**：同上邏輯。有 `personal` 和 `work` 時詢問使用者。

3. **passports**：有多本護照時（不同國家），詢問使用者要用哪本。

4. **addresses**：`current` 是目前地址，`history[]` 是歷史地址。根據表單需求選擇。地址有 `format` 欄位（US/TW）決定哪些子欄位有資料。

### Full Name 合成

v2 移除了 `full_name_zh`/`full_name_en`，改用 `keys`+`join` 合成：

```json
{"selector": "#fullName", "keys": ["identity.first_name_en", "identity.last_name_en"], "join": " "}
{"selector": "#fullNameZh", "keys": ["identity.last_name_zh", "identity.first_name_zh"], "join": ""}
```

注意：中文姓名是姓在前，英文是名在前。有中間名時加入 `identity.middle_name_en`。

## Phase: SETUP（`/autofill setup`）

### 前置檢查
1. 檢查 `~/.claude-autofill/data.enc` 是否存在
   - 若存在：告知使用者已有加密資料，詢問是否要重新設定
   - 若不存在：繼續設定流程
2. 檢查 `age` 是否安裝：`which age`，若無則 `brew install age`

### 設定流程
1. 複製 `${CLAUDE_PLUGIN_ROOT}/assets/data-template.yaml` 到 `~/.claude-autofill/data.yaml`
2. 啟動 Web 編輯 UI：
   ```bash
   python3 ${CLAUDE_PLUGIN_ROOT}/scripts/edit-server.py --init
   ```
   這會：
   - 從 `data-template.yaml` 建立空白資料
   - 啟動本機 Web server (`127.0.0.1:9876`)
   - 自動開啟瀏覽器
   - 使用者在瀏覽器中填入個人資訊
   - 按「儲存並加密」→ server 寫入 YAML → 加密 → 完成
3. 告知使用者：
   ```
   🌐 已開啟 Web 編輯器: http://127.0.0.1:9876

   請在瀏覽器中填入你的個人資訊，完成後按「儲存並加密」。

   ⚠️ 資料只在你的本機處理，不會經過任何外部服務。
   ⚠️ 我不會讀取你填入的任何資料。
   ```
4. Server 會在使用者儲存後自動處理加密（呼叫 `encrypt.sh --init` + `encrypt.sh <file>`）
5. 確認 `data.enc` 存在、`data.yaml` 已刪除、`recipient.pub` 存在

## Phase: WEB（`/autofill web`）

### 前置檢查
- 確認 `~/.claude-autofill/data.enc` 存在
- 讀取 `~/.claude-autofill/schema-keys.txt` 取得可用欄位列表
- 讀取 `~/.claude-autofill/config.yaml` 取得密碼模式

### 偵測欄位
1. 用 `claude-in-chrome` 的 `read_page` 讀取當前 Chrome 頁面
2. 識別所有表單欄位（input, select, textarea）
3. 記錄每個欄位的：selector, type, label, placeholder, name

### 建立映射
1. 比對 schema-keys.txt 的欄位名稱與頁面欄位
2. 產生映射 JSON：`[{"selector": "...", "key": "...", "transform": "..."}, ...]`
   - 需要合成的欄位用 `keys`+`join`
3. 顯示映射給使用者確認
4. 詢問是否要儲存映射（供下次重複使用）
   - 是：儲存到 `~/.claude-autofill/mappings/<name>.json`

### 執行填表
1. 將映射寫入暫存 JSON 檔
2. `bash ${CLAUDE_PLUGIN_ROOT}/scripts/fill-web.sh <mapping.json>`
3. 回報填表結果（欄位數、錯誤數）
4. 刪除暫存映射檔（除非已儲存）

### 重複使用已儲存映射
- 如果使用者指定映射名稱，直接載入：
  `bash ${CLAUDE_PLUGIN_ROOT}/scripts/fill-web.sh ~/.claude-autofill/mappings/<name>.json`

## Phase: PDF（`/autofill pdf <path>`）

### 前置檢查
- 確認 PDF 檔案存在
- 確認 `~/.claude-autofill/data.enc` 存在
- 讀取 schema-keys.txt 和 config.yaml

### 偵測欄位
1. 用 Python 讀取 PDF 欄位名稱（**不讀值**）。優先用 `get_fields()`，失敗時 fallback 到 page annotations：
   ```python
   from pypdf import PdfReader
   from pypdf.generic import ArrayObject
   reader = PdfReader(pdf_path)

   # 方法 1: get_fields()（標準 AcroForm）
   try:
       fields = reader.get_fields()
       if fields:
           for name, field in fields.items():
               print(f"{name}: {field.get('/FT', 'unknown')}")
   except Exception:
       pass

   # 方法 2: Page annotations（XFA-style, USCIS 等政府表單）
   for page_idx, page in enumerate(reader.pages):
       annots = page.get('/Annots')
       if not annots:
           continue
       resolved = annots.get_object() if hasattr(annots, 'get_object') else annots
       if not isinstance(resolved, (list, ArrayObject)):
           continue
       for annot_ref in resolved:
           try:
               annot = annot_ref.get_object()
               if annot is None:
                   continue
               name = str(annot.get('/T', ''))
               ft = str(annot.get('/FT', ''))
               if name:
                   print(f"P{page_idx+1:02d}  {name}  [{ft}]")
           except:
               continue
   ```
2. 列出所有欄位名稱和類型
3. 映射時使用完整欄位路徑或短名（最後一段），`fill-pdf.py` 會自動嘗試兩種匹配

### 建立映射
1. 比對欄位名稱與 schema keys
2. 產生映射 JSON：`[{"field": "...", "key": "...", "transform": "..."}, ...]`
3. 顯示映射給使用者確認

### 執行填表
1. 將映射寫入暫存 JSON 檔
2. `python3 ${CLAUDE_PLUGIN_ROOT}/scripts/fill-pdf.py <pdf_path> <mapping.json>`
3. 回報結果和輸出檔案路徑（`_filled.pdf`）

## Phase: EXCEL（`/autofill excel <path>`）

### 前置檢查
- 確認 xlsx 檔案存在
- 確認 `~/.claude-autofill/data.enc` 存在
- 讀取 schema-keys.txt 和 config.yaml

### 偵測欄位
1. 用 Python 讀取 Excel 結構（**不讀儲存格值，只讀 label**）：
   ```python
   from openpyxl import load_workbook
   wb = load_workbook(xlsx_path)
   for ws in wb.worksheets:
       # 掃描每個儲存格，找 label + 空白欄的配對
       for row in ws.iter_rows():
           for cell in row:
               # 找非空白儲存格（label）旁的空白儲存格（待填）
   ```
2. 列出偵測到的 label → cell 對應

### 建立映射
1. 比對 label 文字與 schema keys
2. 產生映射 JSON：`[{"sheet": "...", "cell": "...", "key": "...", "transform": "..."}, ...]`
3. 顯示映射給使用者確認

### 執行填表
1. 將映射寫入暫存 JSON 檔
2. `python3 ${CLAUDE_PLUGIN_ROOT}/scripts/fill-excel.py <xlsx_path> <mapping.json>`
3. 回報結果和輸出檔案路徑（`_filled.xlsx`）

## Phase: DOCX（`/autofill docx <path>`）

### 前置檢查
- 確認 docx 檔案存在
- 確認 `~/.claude-autofill/data.enc` 存在
- 讀取 schema-keys.txt 和 config.yaml

### 偵測欄位
1. 用 Python 讀取 Word 結構（**不讀填入值，只讀 label 和佔位符**）：
   ```python
   from docx import Document
   doc = Document(docx_path)

   # 模式 A: 表格 — 找 label cell 旁的空白 cell
   for i, table in enumerate(doc.tables):
       for r, row in enumerate(table.rows):
           for c, cell in enumerate(row.cells):
               # 偵測 label + 空白欄配對

   # 模式 B: 佔位符 — 找 {{...}} 或 ____
   for para in doc.paragraphs:
       if '{{' in para.text or '____' in para.text:
           # 提取佔位符
   ```
2. 列出偵測到的欄位

### 建立映射
1. 比對欄位與 schema keys
2. 產生映射 JSON（table 或 placeholder 格式）
3. 顯示映射給使用者確認

### 執行填表
1. 將映射寫入暫存 JSON 檔
2. `python3 ${CLAUDE_PLUGIN_ROOT}/scripts/fill-docx.py <docx_path> <mapping.json>`
3. 回報結果和輸出檔案路徑（`_filled.docx`）

## Phase: EDIT（`/autofill edit`）

### 流程
1. 確認 `data.enc` 存在
2. 啟動 Web 編輯 UI：
   ```bash
   python3 ${CLAUDE_PLUGIN_ROOT}/scripts/edit-server.py
   ```
   這會：
   - 解密現有資料
   - 啟動本機 Web server (`127.0.0.1:9876`)
   - 自動開啟瀏覽器（載入現有資料供編輯）
   - 使用者編輯後按「儲存並加密」→ 重新加密
   - 暫存檔自動安全刪除
3. 告知使用者：
   ```
   🌐 已開啟 Web 編輯器: http://127.0.0.1:9876

   你的資料已載入，請在瀏覽器中編輯。
   完成後按「儲存並加密」，暫存檔會自動清除。

   ⚠️ 我不會讀取你的任何資料。
   ```

## Phase: SCHEMA（`/autofill schema`）

### 流程
1. 讀取 `~/.claude-autofill/schema-keys.txt`
2. 格式化顯示所有可用欄位
3. 按分類分組顯示（identity, id_documents, phones, emails, addresses, ...）

## Value Transforms（參考文件）

詳見 `${CLAUDE_PLUGIN_ROOT}/skills/autofill/references/mapping-format.md`

## 錯誤處理

- `data.enc` 不存在 → 引導執行 `/autofill setup`
- 密碼錯誤 → 腳本回報 `❌ 解密失敗`，建議使用者確認密碼
- Chrome 未開啟 → 提示開啟 Chrome
- PDF 無 AcroForm → 告知此 PDF 沒有可填寫的表單欄位
- 映射確認後使用者要求修改 → 重新產生映射
