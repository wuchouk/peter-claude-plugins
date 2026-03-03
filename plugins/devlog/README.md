# Devlog Plugin

透過引導式訪談，把完成的開發專案記錄成結構化的 markdown 日誌。

## Commands

### `/devlog [客戶名稱]`

啟動開發日誌記錄流程。可選帶入客戶名稱作為參數。

**功能**：
1. 偵測是否已有該客戶的日誌（支援更新或新建）
2. 引導式訪談收集專案資訊、技術困難點、教訓
3. 產生結構化 markdown 日誌，存入 `~/Documents/給Peter的檔案/devlogs/`
4. 更新 INDEX.md 索引
5. 將教訓寫入 OpenMemory（如可用）

**用法**：
```
/devlog
/devlog IP Winner
```

## Author

Peter (local plugin)

## Version

1.0.0
