# Devlog Plugin v2

透過引導式訪談，把完成的開發專案記錄成結構化的 markdown 日誌。

## What's New in v2

- **Skill auto-trigger**：對話中提到完成開發工作時自動建議記錄
- **Milestone detection hook**（Claude Code）：偵測 git commit/deploy 等里程碑時友善提醒
- **Progressive disclosure**：核心流程精簡，訪談指引、模板、OpenMemory 流程拆為獨立參考文件

## Commands

### `/devlog [客戶名稱]`

啟動開發日誌記錄流程。可選帶入客戶名稱作為參數。

**流程**：
1. 前置檢查 — 偵測現有日誌，支援更新或新建
2. 基本資訊 — 收集開發工具、狀態、repo
3. 深入訪談 — 11 題引導式訪談，技術困難點深入追問
4. 產生日誌 — 結構化 markdown，存入 `~/Documents/給Peter的檔案/devlogs/`
5. 更新索引 — INDEX.md + projects.yaml
6. OpenMemory — 寫入日誌指標和教訓（含驗證）

## Structure

```
plugins/devlog/
├── .claude-plugin/plugin.json
├── commands/devlog.md              # 簡化入口（~80 行）
├── skills/devlog-recording/
│   ├── SKILL.md                    # 核心 skill，支援 auto-trigger
│   └── references/
│       ├── interview-guide.md      # 訪談題目 + 追問策略
│       ├── openmemory-workflow.md   # OpenMemory 寫入流程
│       └── index-update-guide.md   # 索引更新規則
│   └── assets/
│       └── devlog-template.md      # 日誌 markdown 模板
├── hooks/
│   ├── hooks.json                  # Stop hook（Claude Code 專用）
│   └── milestone-detector.sh       # 里程碑關鍵字偵測
└── README.md
```

## Cross-platform

| Feature | Claude Code | Claude Desktop |
|---------|:-:|:-:|
| `/devlog` command | ✅ | ✅ |
| Skill auto-trigger | ✅ | ✅ |
| Stop hook (milestone) | ✅ | ❌ |

## Author

Peter Kuo

## Version

2.0.0
