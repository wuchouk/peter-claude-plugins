# pre-commit-pipeline

Commit/ship 守門員 plugin。用 hook 機制強制驗證以下 skill 在 commit/ship 前都跑過：

| Hook 觸發點 | 檢查的 marker |
|------------|---------------|
| `git commit`（PreToolUse Bash） | `simplify`、`review`、`verify-tests` |
| `/ship`（PreToolUse SlashCommand） | 上面三個 + `document-release` + `tidy_docs` |

Hook 失敗會 block tool call 並透過 stderr 告訴 Claude 該跑哪個 skill。Claude 補跑 + 用 `pipeline-mark-done` helper 寫 marker 後即可放行。

## 元件

- **`skills/verify-tests/`** — 新 skill。分析 staged diff 判斷該跑哪些 unit / integration / e2e 測試。
- **`hooks/pre-commit-guard.sh`** — 攔 git commit，3-marker 檢查。`WIP:` / `wip:` / `backup:` 開頭的 commit message 自動放行。
- **`hooks/pre-ship-guard.sh`** — 攔 `/ship`，5-marker 檢查（加 document-release + tidy_docs）。
- **`hooks/session-pipeline-status.sh`** — SessionStart 靜默提示，dirty diff + stale marker 才印一行。
- **`scripts/pipeline-mark-done.sh`** — Claude 跑完 skill 後手動呼叫，寫 marker 進 `.claude/pipeline-state.json`。

## 安裝

```
claude plugins install pre-commit-pipeline@peter-claude-plugins
```

加入 `~/.claude/settings.json` 的 `enabledPlugins`。

## Marker 檔

`.claude/pipeline-state.json`（per-project，本機狀態，**加進 `.gitignore`**）：

```json
{
  "simplify":         { "done_at": "...", "staged_hash": "..." },
  "review":           { "done_at": "...", "staged_hash": "..." },
  "tests":            { "verified_at": "...", "staged_hash": "...", "decisions": [...] },
  "document_release": { "done_at": "...", "staged_hash": "..." }
}
```

`staged_hash` = `git diff --cached` 的 SHA256。Staged 內容改變後 marker 自動失效。

## 工作流程

```
1. 改 code → git add
2. /simplify           → pipeline-mark-done simplify
3. /review             → pipeline-mark-done review
4. /verify-tests       → skill 自帶寫 marker
5. git commit          → pre-commit-guard 放行 ✓
6. /document-release   → pipeline-mark-done document-release
7. /ship               → pre-ship-guard 放行 ✓
```

中間存檔走 `git commit -m "WIP: ..."` 跳過所有 marker 檢查。
