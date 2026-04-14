# skill-hygiene — Skill 維護與品質追蹤

跨所有 plugin 的維護工具，包含 gotchas 累積和 usage tracking。

## 功能

### /gotcha — 記錄踩坑經驗
引導式記錄 skill 的問題和修正建議，存入 `~/.claude/skill-hygiene/gotchas.yaml`。
可選擇直接注入到對應 skill 的 SKILL.md。

### /skill-stats — 使用量報告
分析 skill 使用頻率、gotcha 狀態、未使用的 skills。

### Hooks（自動化）
- **PreToolUse (Skill)** — 自動記錄每次 skill 呼叫到 `usage.log`
- **Stop** — 偵測使用者修正模式，建議執行 `/gotcha`

## 資料位置

```
~/.claude/skill-hygiene/
├── gotchas.yaml      # 所有 gotchas
├── usage.log         # skill 使用記錄（TSV: timestamp, skill, project）
└── pending-gotchas.md  # 待注入的 gotchas（未來）
```
