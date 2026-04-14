# 自動化測試定義：{SCENARIO_TITLE}

> 從情境檔 `{SCENARIO_FILE}` 轉換而來

---

## 測試元資料

- **情境來源**：`tests/scenarios/{SCENARIO_FILE}`
- **轉換日期**：{DATE}
- **測試類型**：{TEST_TYPE} <!-- unit | integration | e2e | manual-assisted -->

## 測試步驟

### 前置準備

```
{SETUP_COMMANDS}
```

### 執行

```
{EXECUTION_COMMANDS}
```

### 驗證

{VERIFICATION_STEPS}

<!-- 每個驗證步驟格式：

#### Step {N}: {PRIMITIVE_ID} — {描述}

**指令/工具**：
```
{COMMAND_OR_TOOL}
```

**預期結果**：
- {EXPECTED_OUTCOME}

**失敗處理**：
- {ON_FAILURE}

-->

### 清理

```
{CLEANUP_COMMANDS}
```

## 整合指引

將此測試整合進專案自動化時：
- 若專案有 `/test-*` skill → 加入該 skill 的測試清單
- 若專案用 test framework → 轉換為對應的 test case
- 若為純手動 → 保留為 checklist，在 `/capture-test log` 記錄結果
