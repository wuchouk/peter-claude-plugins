---
description: "Skill 使用量報告與健康度檢查。觸發詞：skill-stats、使用量、skill usage、哪些 skill、統計"
allowed-tools: Read, Glob, Grep, Bash(date:*), Bash(wc:*), Bash(sort:*), Bash(uniq:*), Bash(awk:*), Bash(head:*)
---

# /skill-stats — Skill 使用量報告

讀取 `~/.claude/skill-hygiene/usage.log` 和 `~/.claude/skill-hygiene/gotchas.yaml` 生成報告。

## 報告內容

1. **最近 7 / 30 天各 skill 使用次數**（排序）
2. **有 pending gotchas 的 skills**（需要關注）
3. **從未被觸發的 skills**（description 可能需要改善）
4. **高頻 gotcha skills**（品質需要提升）

## 執行方式

1. 讀取 `~/.claude/skill-hygiene/usage.log`
2. 解析每行格式：`{ISO_TIMESTAMP}\t{SKILL_NAME}\t{PROJECT_DIR}`
3. 按時間窗口統計
4. 讀取 `~/.claude/skill-hygiene/gotchas.yaml` 交叉比對
5. 用 Glob 掃描所有已安裝 plugin 的 skill 清單（`~/peter-claude-plugins/plugins/*/skills/*/SKILL.md`）
6. 找出從未出現在 usage.log 中的 skills
7. 輸出表格化報告

使用者輸入：
$ARGUMENTS
