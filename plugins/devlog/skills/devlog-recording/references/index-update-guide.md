# 索引更新指引

## INDEX.md

讀取 `/Users/cubie/Documents/給Peter的檔案/devlogs/INDEX.md`，在表格末尾加入新的一行。

### 格式

```markdown
# Development Log Index

| 客戶/專案 | 檔案 | 建立日期 | 一句摘要 |
|-----------|------|----------|----------|
| {客戶名} | {檔名} | {日期} | {一句摘要} |
```

如果 INDEX.md 不存在，建立新檔並包含上述表頭。

### 更新現有日誌

如果是更新現有日誌（而非新建），只需更新對應行的摘要欄位（如有變更）。

---

## projects.yaml

讀取 `/Users/cubie/Documents/給Peter的檔案/devlogs/projects.yaml`。

### 檔案不存在時

建立新檔：

```yaml
# projects.yaml — 專案結構化描述（供記憶系統及工具查詢）
projects:
  - client: "{客戶名}"
    project_name: "{專案名稱}"
    description: "{使用者在訪談第 3 題的回答}"
    tech_stack: [{技術列表}]
    status: "{專案狀態}"
    devlog_file: "{日誌檔名}"
    created: "{今天日期}"
    updated: "{今天日期}"
```

### 檔案已存在時

1. 搜尋同 `client` + `project_name` 的條目
2. **已存在**：更新 `description`、`tech_stack`、`status`、`devlog_file`、`updated`
3. **不存在**：在 `projects:` 列表末尾新增條目

`description` 直接使用使用者在訪談第 3 題的回答。
