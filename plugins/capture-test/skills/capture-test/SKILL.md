---
description: >
  通用測試情境建構工具。當使用者想記錄測試情境、記錄測試結果、整併優化測試時觸發。
  觸發詞：capture-test、測試情境、記錄測試、test scenario、test log、測一下、怎麼測、測試紀錄、整併測試、optimize test。
  支援三種模式：record（記錄情境）、log（記錄結果）、optimize（整併優化）。
---

# /capture-test — 測試情境建構與管理

## 概覽

這是一個**通用** skill，不綁定特定專案。它在任何專案目錄下都能使用，透過「專案積木」(primitives.yaml) 適配不同專案的驗證需求。

核心理念：**不問「你怎麼測」，而是用選單分解驗證需求**。

## 模式判斷

根據使用者輸入的 `$ARGUMENTS` 決定模式：

| 輸入 | 模式 |
|------|------|
| 無參數 / `record` | 模式 A — 記錄測試情境 |
| `log` | 模式 B — 記錄測試結果 |
| `optimize` | 模式 C — 整併優化 |

---

## Phase 0 — 專案定位與初始化

### 0.1 找到專案根目錄

用 Glob 檢查當前目錄是否有專案標記（`.git`、`package.json`、`VERSION`、`.clasp.json`、`Makefile`、`docs/`）。

- **找到** → `PROJECT_ROOT` = 當前目錄
- **沒找到** → 往上一層找，或問使用者

### 0.2 檢查 tests/ 目錄

檢查 `{PROJECT_ROOT}/tests/` 是否存在：

- **存在** → 讀 `tests/primitives.yaml`（如果有）
- **不存在** → 執行首次初始化流程

### 0.3 首次初始化（僅第一次執行時）

1. 建立 `{PROJECT_ROOT}/tests/scenarios/` 目錄
2. 建立 `{PROJECT_ROOT}/tests/test-log.md`（空的，含標題）
3. 建立 `{PROJECT_ROOT}/tests/scenario-index.md`（空索引）
4. **偵測專案類型** — 用 Glob 掃描專案檔案，判斷技術棧：
   - `.clasp.json` → Apps Script
   - `package.json` → Node.js（檢查 dependencies 判斷前後端）
   - `requirements.txt` / `pyproject.toml` → Python
   - `index.html` / React/Vue 設定 → 前端
   - `Makefile` / `bin/` → CLI
5. **讀取** `${CLAUDE_PLUGIN_ROOT}/skills/capture-test/references/starter-primitives.md` 取得通用積木清單
6. **根據偵測結果**，列出建議的積木，問使用者：

   > 偵測到這是 {技術棧} 專案。建議以下驗證積木：
   > {積木清單}
   >
   > 這個專案還有什麼特殊的驗證方式？

7. 使用者確認後，讀取 `${CLAUDE_PLUGIN_ROOT}/skills/capture-test/assets/primitives-template.yaml` 作為模板
8. 生成 `{PROJECT_ROOT}/tests/primitives.yaml`，填入選定的積木

### 0.4 自動提醒整併

每次執行時檢查：
- `tests/scenarios/` 中的檔案數量 > 15 → 提醒「建議執行 `/capture-test optimize` 整併」
- `tests/test-log.md` 中的記錄筆數 > 20 → 同上

提醒一次即可，不要阻斷流程。

---

## 模式 A — 記錄測試情境（`record`）

### A.1 預填上下文

- 讀 `TODO.md` Active section（如果存在）
- 從對話上下文推斷使用者剛做了什麼改動
- 問：「你剛改了什麼 / 想測什麼？」

如果能自動推斷，提供預設值讓使用者確認。

### A.2 驗證分解

讀取 `${CLAUDE_PLUGIN_ROOT}/skills/capture-test/references/interview-guide.md` 取得完整引導流程。

核心流程：
1. 從 `tests/primitives.yaml` 動態生成驗證選單（依 category 分組）
2. 使用者選擇要驗證的項目（可多選）
3. 對每個選中的 primitive，追問具體參數
4. 盡量從上下文自動推斷預設值

### A.3 前置條件 + 失敗模式

- 問前置條件（選單式）
- 問預期失敗模式（至少 2 個：一個前置條件問題、一個邏輯錯誤）
- 如果 `TODO.md` 或既有 scenarios 中有已知問題，自動建議

### A.4 儲存

1. 用 `date` 取得當天日期
2. 讀取 `${CLAUDE_PLUGIN_ROOT}/skills/capture-test/assets/scenario-template.md` 取得模板
3. 生成 scenario file → `tests/scenarios/{YYYY-MM-DD}-{slug}.md`
   - `slug` 從情境標題生成（英文 kebab-case，簡短）
4. 更新 `tests/scenario-index.md`，追加一行：

   ```
   | {日期} | [{標題}](scenarios/{檔名}) | {狀態} | {關聯改動} |
   ```

5. 問使用者：「要現在轉成自動化測試嗎？」
   - **是** → 進入轉換流程（A.5）
   - **否** → 完成

### A.5 轉換為自動化測試（可選）

1. 讀取 `${CLAUDE_PLUGIN_ROOT}/skills/capture-test/templates/test-definition.md` 取得模板
2. 根據 scenario 中的 primitives，生成具體的測試步驟
3. 判斷整合方式：
   - 專案有 `/test-*` skill → 建議加入該 skill 的測試清單
   - 專案有 test framework → 建議轉為 test case
   - 否則 → 保留為手動 checklist
4. 更新 scenario-index.md 中該情境的狀態為「已自動化」

---

## 模式 B — 記錄測試結果（`log`）

### B.1 識別測試類型

問使用者或從上下文判斷：

- **手動測試** — Peter 自己跑，提供結果
- **自動化測試** — 某個 test skill 跑完的結果
- **混合** — 部分自動 + 部分手動確認

### B.2 收集結果

- 如果有關聯的 scenario → 讀取該 scenario 的驗證項目作為 checklist
- 如果沒有特定 scenario → 讓使用者自由描述
- 對每個驗證項，記錄：通過 ✅ / 失敗 ❌ / 未測 ⏭️

### B.3 寫入 test-log.md

追加到 `tests/test-log.md`，格式：

```markdown
## {YYYY-MM-DD HH:MM} — {VERSION_OR_CHANGE} {簡述}

**類型**: {手動測試 | 自動化測試 | 混合}
**範圍**: {測試範圍描述}
**觸發**: `{觸發指令或方式}`

### 檢查項目
- [x] {項目} → ✅ {結果}
- [ ] {項目} → ❌ {失敗描述}
- [ ] {項目} → ⏭️ 未測

### 發現
- {測試過程中的新發現}

### 關聯情境
- [{情境名}](scenarios/{檔名})
```

分隔線 `---` 隔開不同次的記錄。

### B.4 發現新情境

如果測試過程中有新發現（unexpected behavior、edge case），自動問：

> 你提到 {新發現}。要記錄這個為新的測試情境嗎？

**是** → 切換到模式 A，pre-fill 改動描述。
**否** → 只在 test-log 的「發現」section 記錄。

---

## 模式 C — 整併優化（`optimize`）

### C.1 分析

- 讀 `tests/test-log.md` 全部記錄
- 讀 `tests/scenario-index.md` 所有情境
- 依需要讀個別 scenario files
- 找出：
  - **重複測試**：不同日期測同一件事
  - **可合併情境**：驗證項目高度重疊的 scenarios
  - **已被涵蓋的舊情境**：新情境包含舊情境的所有驗證
  - **穩定測試**：連續 N 次通過，可降低執行頻率

### C.2 建議

輸出分析報告：

```
分析結果：

🔄 重複測試（建議合併）
  - "{A}" 和 "{B}" → 合併為 "{新名}"

📦 可合併的驗證步驟
  - N 個情境都檢查 {X} → 抽成共用 primitive

🗂️ 建議的測試組織
  - 回歸測試（每次必跑）：{列表}
  - 功能測試（相關修改時跑）：{列表}
  - 已穩定（可降頻）：{列表}

🗑️ 可廢棄
  - "{C}" — 已被 "{D}" 完全涵蓋
```

### C.3 執行

使用者確認後：
1. 合併 scenario files（保留歷史：舊檔標記為 `已廢棄`，不刪除）
2. 更新 `tests/scenario-index.md`
3. 如果有新的共用 primitive → 加入 `tests/primitives.yaml`
4. 如果有自動化測試 → 更新相關 test definitions

---

## 參考文件

執行各階段時，讀取對應的參考文件取得詳細指引：

| 用途 | 路徑 |
|------|------|
| 引導式問題流程 | `${CLAUDE_PLUGIN_ROOT}/skills/capture-test/references/interview-guide.md` |
| 通用積木清單 | `${CLAUDE_PLUGIN_ROOT}/skills/capture-test/references/starter-primitives.md` |
| 情境檔模板 | `${CLAUDE_PLUGIN_ROOT}/skills/capture-test/assets/scenario-template.md` |
| 專案積木模板 | `${CLAUDE_PLUGIN_ROOT}/skills/capture-test/assets/primitives-template.yaml` |
| 自動化測試模板 | `${CLAUDE_PLUGIN_ROOT}/skills/capture-test/templates/test-definition.md` |

---

## 注意事項

- **繁體中文**溝通
- 保留使用者原話描述，不改寫
- scenario file 的 slug 用英文（方便 git、URL）
- 測試日誌的時間用 24 小時制
- 不要自動執行測試，只記錄和組織
- primitives.yaml 是專案層檔案，跟 code 一起 git 版控
