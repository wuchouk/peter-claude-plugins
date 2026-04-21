---
description: "檢查所有 skill + plugin 安裝健康度。觸發詞：skill-health、skill 健康檢查、檢查 skill 安裝、plugin health、plugin 檢查、install verify、audit skills"
allowed-tools: Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/skill-health.sh:*)
---

# /skill-health — Skill + Plugin 安裝健康度檢查

跑 `${CLAUDE_PLUGIN_ROOT}/scripts/skill-health.sh`。

## 檢查項目

1. **全域 skills**（`~/.claude/skills/*/SKILL.md`）
   - SKILL.md 是 regular file（不是 broken symlink）
   - 非空檔
   - Frontmatter 有 `name:` + `description:`
2. **Peter's plugins**（`~/peter-claude-plugins/plugins/*`）
   - `.claude-plugin/plugin.json` 存在且 valid JSON
   - 每個 skill 的 SKILL.md 同上檢查
3. **Plugin cache drift**
   - 比對 source vs `~/.claude/plugins/cache/`，不一致 → 建議 `claude plugins install`
   - cache 缺失 → 建議 reinstall
4. **Enabled 對齊 installed**
   - `~/.claude/settings.json` 的 `enabledPlugins: true` 但沒 cache dir → 報錯

## 輸出

- ✅ 全通過：顯示檢查的 SKILL.md 數量
- ⚠/❌ 有問題：列出每個問題的 location + 建議修法，exit 2

## 背景

2026-04-21 踩到 insforge plugin 裝了但 SKILL.md 其實是 broken symlink 的坑（`claude plugins list` 顯示 `✔ enabled` 但 description 從未進 context）。這個指令專抓這類 silent failure。
