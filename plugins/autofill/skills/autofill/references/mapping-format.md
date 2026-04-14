# Mapping JSON Format Reference

## Overview

映射 JSON 定義「表單欄位 → 資料 key」的對應關係。Claude 產生映射，本機腳本用映射來填值。
**映射中永遠只有 key（路徑），不含實際值。**

## Web Form Mapping

```json
[
  {"selector": "#firstName", "key": "identity.first_name_en"},
  {"selector": "input[name='email']", "key": "emails[0].address"},
  {"selector": "#birthDate", "key": "identity.birth_date", "transform": "date_format:MM/DD/YYYY"},
  {"selector": "#gender", "key": "identity.gender", "transform": "select_map:{M:Male,F:Female}"}
]
```

### Selector 格式
- CSS selector：`#id`、`.class`、`input[name='x']`、`select[id='x']`
- 優先順序：id > name > aria-label > placeholder > position

## Multi-Key Composition（`keys` + `join`）

當一個表單欄位需要合成多個資料欄位時，使用 `keys` 陣列 + `join` 分隔符：

```json
{"selector": "#fullName", "keys": ["identity.first_name_en", "identity.last_name_en"], "join": " "}
{"selector": "#fullNameZh", "keys": ["identity.last_name_zh", "identity.first_name_zh"], "join": ""}
{"selector": "#phone", "keys": ["phones[0].country_code", "phones[0].number"], "join": "", "transform": "phone_international"}
```

### 規則
- `keys` 和 `key` 互斥，不可同時出現
- `join` 預設為 `" "`（一個空格）
- 所有 key 的值會按順序用 `join` 串接
- 值為 `null` 的 key 會被跳過（不會產生多餘分隔符）
- `transform` 套用在合成後的結果上

### 常見用法

| 場景 | keys | join |
|------|------|------|
| 英文全名 | `["identity.first_name_en", "identity.last_name_en"]` | `" "` |
| 中文全名 | `["identity.last_name_zh", "identity.first_name_zh"]` | `""` |
| 英文全名含中間名 | `["identity.first_name_en", "identity.middle_name_en", "identity.last_name_en"]` | `" "` |
| 國際電話 | `["phones[0].country_code", "phones[0].number"]` | `""` + transform `phone_international` |

## PDF Form Mapping

```json
[
  {"field": "LastName[0]", "key": "identity.last_name_en"},
  {"field": "BirthDate[0]", "key": "identity.birth_date", "transform": "date_format:MM/DD/YYYY"},
  {"field": "Gender[0]", "key": "identity.gender", "transform": "select_map:{M:/Male,F:/Female}"},
  {"field": "Married[0]", "key": "marriage.status", "transform": "select_map:{Married:/Yes,*:/Off}"},
  {"field": "FullName[0]", "keys": ["identity.first_name_en", "identity.last_name_en"], "join": " "}
]
```

### PDF 特殊值
- Checkbox/Radio：`/Yes` (勾選)、`/Off` (不勾)
- 有些 PDF 用 `/1`、`/0` 或自訂名稱

## Excel Form Mapping

```json
[
  {"sheet": "Sheet1", "cell": "C5", "keys": ["identity.first_name_en", "identity.last_name_en"], "join": " "},
  {"sheet": "Sheet1", "cell": "C6", "key": "identity.birth_date", "transform": "date_format:YYYY/MM/DD"},
  {"sheet": "基本資料", "cell": "D10", "key": "phones[0].number"}
]
```

### Excel 欄位識別
- Claude 掃描每個 sheet，找空白儲存格旁的 label（左邊或上方的文字）
- `sheet` 用 sheet 名稱（非 index）
- `cell` 用 A1 notation

## Word Document Mapping

### Table Mode
```json
[
  {"type": "table", "table_idx": 0, "row": 2, "col": 1, "keys": ["identity.first_name_en", "identity.last_name_en"], "join": " "},
  {"type": "table", "table_idx": 0, "row": 3, "col": 1, "key": "identity.birth_date", "transform": "date_format:YYYY/MM/DD"}
]
```

### Placeholder Mode
```json
[
  {"type": "placeholder", "text": "{{full_name}}", "keys": ["identity.first_name_en", "identity.last_name_en"], "join": " "},
  {"type": "placeholder", "text": "____", "key": "id_documents.tw_national_id", "context": "身份證字號"}
]
```

- `table_idx`：文件中第幾個 table（0-based）
- `context`：當 placeholder 不唯一時，用附近的文字來定位

## Value Transforms

| Transform | 說明 | 範例 |
|-----------|------|------|
| `date_format:FMT` | 日期格式轉換 | `date_format:MM/DD/YYYY` → `03/24/2026` |
| `date_part:PART` | 擷取日期部分 | `date_part:year` → `2026` |
| `select_map:{K:V,...}` | 值對應 | `select_map:{M:Male,F:Female}` |
| `uppercase` | 轉大寫 | `PETER KUO` |
| `lowercase` | 轉小寫 | `peter kuo` |
| `phone_format` | 電話格式化 | 移除空格和破折號 |
| `phone_international` | 國際電話格式 | `+8860912345678` → `+886912345678`（去掉國碼後的 leading 0）|
| `truncate:N` | 截斷至 N 字 | `truncate:20` |

### phone_international

搭配 `keys`+`join` 使用，將 country_code 和 number 合成後，移除 number 部分的 leading 0：

```json
{"selector": "#phone", "keys": ["phones[0].country_code", "phones[0].number"], "join": "", "transform": "phone_international"}
```

結果：`+886` + `0912345678` → `+8860912345678` → `+886912345678`

### date_format 支援的 token
- `YYYY` → 四位年
- `YY` → 兩位年
- `MM` → 兩位月
- `DD` → 兩位日
- `month_name` → January, February, ...
- `month_abbr` → Jan, Feb, ...

### date_part 支援的值
- `year`, `month`, `day`, `month_name`, `month_abbr`

## Array Access

陣列欄位用 `[index]` 存取：

```
phones[0].number               → 第一筆電話的號碼
phones[1].country_code         → 第二筆電話的國碼
emails[0].address              → 第一個 email 地址
id_documents.passports[0].number → 第一本護照號碼
visa_history[0].country        → 第一筆簽證的國家
addresses.history[1].full_en   → 第二筆歷史地址（英文）
education[0].school_en         → 第一筆學歷的學校（英文）
```

### 用 label 找正確的 index

phones 和 emails 是有 label 的陣列。Claude 應該根據表單需求選擇正確的 index：

```
phones[0] → label: "taiwan_mobile"  → 台灣手機
phones[1] → label: "us_mobile"      → 美國手機
emails[0] → label: "personal"       → 個人 email
emails[1] → label: "work"           → 工作 email
```

## Saving Mappings

映射可儲存至 `~/.claude-autofill/mappings/` 供重複使用：
- 檔名建議用表單名稱：`ds-160-page1.json`、`tw-passport-renewal.json`
- Claude 在產生映射時會詢問是否儲存
