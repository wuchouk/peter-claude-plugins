---
description: >
  分析當前 staged diff，判斷該跑哪些測試（unit / integration / e2e / skip），輸出建議清單後寫進
  `.claude/pipeline-state.json` 的 `tests` marker。pre-commit-pipeline plugin 的核心 skill。
  觸發時機：
  (1) 使用者輸入 /verify-tests；
  (2) pre-commit-guard hook 失敗訊息指出 tests marker 缺失/過期；
  (3) Claude 完成 code 改動準備 commit 前，主動跑一次確保測試覆蓋。
  Do NOT trigger for: 純文件 commit (.md only) 且使用者已說「不用測試」、純 config 改動且無 logic 影響。
allowed-tools: Bash, Read, Glob, Grep
---

# verify-tests — 測試決策 skill

職責：根據 staged diff 客觀判斷該跑哪些測試，把決策寫進 marker。**不自動跑測試**——只決策、寫 marker、詢問使用者要不要跑。

## Step 1 — 讀取 staged diff

```bash
git diff --cached --name-status
git diff --cached --stat
```

如果沒有 staged 內容 → 告訴使用者「沒有 staged 改動，先 `git add` 後再跑」，結束。

## Step 2 — 分類每個改動檔案

對每個改動檔案，照下列規則歸到一個 bucket：

### Bucket A：unit test
觸發條件：
- 改 `src/**/*.{ts,tsx,js,jsx,py,rb,go}` 且**有對應的 test file**
- 找 test file 的位置（按優先順序）：
  1. 同目錄：`src/foo.ts` → `src/foo.test.ts` / `src/foo.spec.ts`
  2. 平行 tests 目錄：`tests/foo.test.*`、`__tests__/foo.test.*`
  3. Python: `tests/test_foo.py`
- 用 `Glob` / `Bash find` 找

### Bucket B：integration test
觸發條件：
- 改 `app/api/**`、`routes/**`、`endpoints/**`、`server/**`、`pages/api/**`
- 改 DB schema（`schema.sql`、`migrations/**`、`prisma/schema.prisma`）→ **強制** integration + e2e

### Bucket C：e2e test
觸發條件：
- 改 UI 元件（`.tsx`/`.vue`/`.svelte` in `components/`、`app/`、`pages/`）且專案有 e2e test list
- E2E test list 位置（按優先順序找）：
  1. `docs/e2e-tests.md`
  2. `e2e/tests.json`
  3. `tests/e2e/` 目錄
  4. `playwright.config.*` 存在 → e2e infra ready
- 從 list 挑跟改動相關的測試（用元件名 / route 比對）

### Bucket D：skip（標記原因）
觸發條件：
- 純 `.md` / `.txt` / docs 改動
- `.gitignore`、`.editorconfig`、`prettier`/`eslint` config（不影響 runtime）
- comment-only 改動（用 `git diff --cached` 比對只有 `+//` / `+#`）

如果無法歸類 → 歸到 unit + 標 `confidence: low` 讓使用者確認。

## Step 3 — 輸出建議清單

格式：

```
[verify-tests] staged diff: 3 files, 47 lines

Recommended tests:
  ✅ unit  → tests/auth.test.ts (covers src/auth/login.ts)
  ✅ unit  → tests/session.test.ts (covers src/auth/session.ts)
  ⚠️  e2e   → e2e/login.spec.ts (UI component LoginForm.tsx changed)
  ⏭️  skip  → docs/CHANGELOG.md (pure docs)

Migration changes detected → e2e is REQUIRED, not optional.
```

如果有 missing test file（改了 source 但找不到對應 test）→ 提出來：

```
⚠️ src/auth/oauth.ts changed but no test file found.
   Suggest creating tests/oauth.test.ts before committing.
```

## Step 4 — 詢問使用者

```
要跑哪些？
  [a] 全部跑
  [u] 只跑 unit
  [s] skip 全部（標記為 manual smoke OK）
  [c] 取消（不寫 marker，hook 會繼續擋 commit）
```

如果使用者選 skip，**要求一個原因**（例如：「manual smoke OK」、「only docs」、「reverting prior commit」）。寫進 decisions[].reason。

## Step 5 — 跑選中的測試（如果使用者選了）

用該專案的 test runner（`npm test`、`pytest`、`go test ./...`、`bun test` 等）。從 `package.json` / `pyproject.toml` / `Makefile` 偵測。

跑完抓 pass/fail 數，寫進每個 decision 的 status 欄位。

## Step 6 — 寫 marker

跑這兩行：

```bash
# Step 1: 寫基本 done_at + staged_hash
bash ~/peter-claude-plugins/plugins/pre-commit-pipeline/scripts/pipeline-mark-done.sh verify-tests

# Step 2: 把 decisions[] 補進 marker（保留 done_at + staged_hash）
STATE_FILE="$(git rev-parse --show-toplevel)/.claude/pipeline-state.json"
jq --argjson decisions '<把上面的決策 array 序列化成 JSON>' \
  '.tests.decisions = $decisions' "$STATE_FILE" > "$STATE_FILE.tmp" \
  && mv "$STATE_FILE.tmp" "$STATE_FILE"
```

Decisions array 範例：

```json
[
  {"type": "unit", "target": "tests/auth.test.ts", "status": "passed"},
  {"type": "e2e",  "target": "e2e/login.spec.ts",   "status": "skipped", "reason": "manual smoke OK"},
  {"type": "skip", "target": "docs/CHANGELOG.md",   "reason": "pure docs"}
]
```

`status` 欄位值：`passed` / `failed` / `skipped`。

## Evidence 規則（雙迴路 B-2）

讀 `docs/verification/config.yaml`（不存在則本節全部跳過，marker 不含 evidence 欄位）：

1. staged diff 有檔案 match `layers.ui.paths` → `evidence_required` 加 `"render"`。
   render 證據 = 真實 render 過的具體產物路徑：跑過的 Playwright spec（附 pass 輸出）或 walkthrough 截圖檔路徑。
2. staged diff 有檔案 match `layers.real_sample_pipeline.paths` → `evidence_required` 加 `"real_sample"`。
   real_sample 證據 = runner 對 corpus 的執行結果摘要路徑（測試報告或輸出檔）。
   跑哪一支 runner 用反查：schema v3 的 `runners[]` 逐支比對 `covers` glob，都沒命中就取 `default: true` 那支；
   schema v2 的單數 `runner: '<指令>'` 仍相容（等價於單一免費 runner）。
   命中多支時 `sum(cost_usd)` 超過 `budget_usd`（未設視為 US$1）→ 只跑 `cost_usd: 0` 的，並註明哪幾支因預算沒跑。
   **判定綠紅不要只看 exit code** —— 多數 eval runner 分數再爛也 exit 0，要比對它印出的指標。
3. commit 訊息將以 `fix` 開頭（conventional commit）→ marker 必須含 `regression`：
   `{"test": "<新增/更新的 regression test 路徑>"}` 或 `{"skip_reason": "<為何無法自動化>"}`。

Marker payload 範例（在既有欄位之外新增）：

```json
{
  "tests": {
    "staged_hash": "…",
    "done_at": "2026-07-05T12:00:00Z",
    "evidence_required": ["render"],
    "evidence": { "render": "docs/test-report/verify-2026-07-05-foo.md" },
    "regression": { "test": "apps/reader/tests/download-retry.test.ts" }
  }
}
```

證據必須真實存在（guard 只驗欄位非空，誠實是你的責任——附假路徑等同繞過 gate）。
無法提供時照舊走 `[s]` skip + 理由。

## Step 7 — 回報

跟使用者確認 marker 寫好，告訴他下個 commit 應該不會被 hook 擋（除非 staged diff 又變了）。

---

## 重要原則

- **不自動 commit**——這個 skill 只做測試決策，commit 由 hook 守門 + 使用者決定
- **不主動修 bug**——測試 fail 只回報，由使用者決定要不要修
- **判斷理由要透明**——每個決策都附 reason，讓 marker 可以被審視
- **找不到 test file 時主動提**——missing coverage 比 false-pass 還危險
