# Email Processor 測試報告

## 基本資訊

- **客戶**: {CLIENT_NAME}
- **測試時間**: {DATE} {TIME}
- **測試模式**: {MODE}
- **版本篩選**: {VERSION_FILTER}
- **Web App 版本**: {WEBAPP_VERSION}

## 測試摘要

| 指標 | 數值 |
|------|------|
| 總測試項 | {TOTAL} |
| ✅ 通過 | {PASS} |
| ❌ 失敗 | {FAIL} |
| ⏭️ 跳過 | {SKIP} |
| ⏱️ 超時 | {TIMEOUT} |
| 💥 錯誤 | {ERROR} |
| **通過率** | **{PASS_RATE}%** |

---

## 測試結果

### {TEST_GROUP_NAME}

| # | 測試項 | 結果 | 耗時 | 備註 |
|---|--------|------|------|------|
| {N} | {TEST_NAME} | {RESULT} | {DURATION} | {NOTES} |

#### 失敗項詳情

**{TEST_NAME}**
- 預期: {EXPECTED}
- 實際: {ACTUAL}
- 錯誤訊息: {ERROR_MESSAGE}
- 可能原因: {PROBABLE_CAUSE}

---

## MANUAL 項目提醒

以下項目需要手動驗證：

- [ ] {MANUAL_ITEM_1}
- [ ] {MANUAL_ITEM_2}

---

## 測試環境

- Gmail MCP: {GMAIL_MCP_STATUS}
- claude-in-chrome: {CHROME_STATUS}
- Web App 連線: {WEBAPP_STATUS}

---

*報告生成時間: {GENERATED_AT}*
