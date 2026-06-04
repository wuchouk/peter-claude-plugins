---
description: "分析 staged diff，判斷該跑哪些測試（unit / integration / e2e），寫進 .claude/pipeline-state.json marker。觸發詞：verify-tests、要不要測、該跑哪些測試、tests needed、pipeline tests marker"
allowed-tools: Bash, Read, Glob, Grep
---

# /verify-tests — 測試決策

讀取 `${CLAUDE_PLUGIN_ROOT}/skills/verify-tests/SKILL.md` 取得完整邏輯，然後執行。

使用者輸入：
$ARGUMENTS
