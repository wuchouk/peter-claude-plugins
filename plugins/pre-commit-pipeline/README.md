# pre-commit-pipeline

Commit/ship 守門員 plugin。用 hook 機制強制驗證以下 skill 在 commit/ship 前都跑過：

| Hook 觸發點 | 檢查的 marker |
|------------|---------------|
| `git commit`（PreToolUse Bash，Claude only） | `simplify`、`review`、`verify-tests` |
| `git commit`（**git-native, 所有 agent**） | 同上（見下方 git-native 層） |
| `/ship`（PreToolUse SlashCommand） | 上面三個 + `document-release` + `tidy_docs` |

Hook 失敗會 block 並透過 stderr 告訴你該跑哪個 skill。補跑 + 用 `pipeline-mark-done` helper 寫 marker 後即可放行。

## 強制是 git-native 的（跨 agent）

PreToolUse hook 只在 Claude Code 內生效；Codex/Fugu/Conductor 不會跑它。為了讓 commit gate 對**所有 committer**（Claude、Codex、Fugu、Conductor、人手）都生效，真正的地板放在 **git 層**：

- `~/.config/husky/init.sh` — husky v9.1 loader 在每個 husky repo 每次 hook 前都會 source 它。掛在 `pre-commit`（一定存在的 hook），呼叫 git-native guard。
- `hooks/git-commit-msg-guard.sh` — git-native guard 本體。**只在 repo 有 `.claude/` 目錄時納管**（opt-in，別人的 repo 不受影響）。
- **單一清單**：`pipeline-steps.json` 是所有 gate step 的唯一 source of truth；`scripts/pipeline-lib.sh` 是共用 reader/evaluator。要加/減一道關卡只改 `pipeline-steps.json`。
- **防批次打勾（anti-gaming）**：同一 staged hash 的 ≥2 marker 若 **`first_marked_at`**（該步驟在**這一輪**最早被打勾的時間，以 `first_marked_head` 界定輪次）落在 `batch_window_seconds` 內，視為「沒真跑就打勾」並擋下。看最早那次而不是 `done_at`，是因為**重打是正常流程的一部分**：marker 綁 staged hash，pipeline 跑完後只要再動任何檔案（review 修東西、補一筆 TODO、document-release 補文件）hash 就變，三個 marker 必須一起重打，`done_at` 必然撞在同一秒。用 `done_at` 判斷會反過來專門擋掉跑得最完整的那些人。
  - 仍然擋不住的：把假打勾刻意拉開超過 `batch_window_seconds` 再打。那要靠 Roadmap 的方案 A（打勾綁真實 evidence），本機制只處理「同秒憑空出現」。
- **沒有 husky 的 repo** → 跑一次 `bash scripts/install-git-hook.sh`，它放一支呼叫 guard 的 stub，讓該 repo 也在 git 層受管（`--uninstall` 移除）。四個要點：
  - **hook 目錄問 git，不寫死 `.git/hooks`**：repo 若設了 `core.hooksPath`，git 只從那裡讀 hook，裝錯地方等於沒裝卻以為有裝。
  - **絕不動不是本工具寫的 hook**。所有權以「內容與本工具會生成的**完全相同**」判定，不靠標記字串或行數——他人的 hook 只要湊巧含有相同字樣，靠標記判斷就會誤報已安裝（實際沒有 guard），uninstall 更會直接刪掉別人的檔案。
  - **guard 路徑在安裝當下解析成絕對路徑寫死**，不留 `$HOME` 讓執行期展開（換使用者、GUI 帶不同 HOME、plugin 搬家都會讓它找不到 guard）；而且找不到時 **fail closed**——一個靜默消失的 gate 比一個會抱怨的危險得多。
  - **husky repo 看的是 user hook 檔案，不是 `.husky/` 目錄**：husky loader 在該 hook 沒有對應 user 檔時會提前結束、根本不 source 全域 init，所以「有 `.husky/` 但沒有 `pre-commit`」的 repo 其實沒被涵蓋，仍需安裝。
  - 沒裝的話那個 repo 只剩 Claude PreToolUse hook 守著，而那層有兩個結構性限制：只在 Claude Code 內生效（Codex / Fugu / 人手 commit 沒守），且它必須從**命令字串**猜這是不是 commit —— 任何提到 `git commit` 的命令都會被誤攔，即使它根本不碰 git（實例：把一段解釋 commit gate 的說明餵給 `codex exec` 時被擋下）。從 git 自己觸發沒有這兩個問題。
- 繞過：`PIPELINE_SKIP=1 git commit …`（通用）；`WIP:`/`backup:` 訊息前綴在拿得到訊息的層（Claude PreToolUse、或有 `.husky/commit-msg` 的 repo）也可繞過。

### 給未來開發者的慣例

- 新增一道關卡 → 只改 `pipeline-steps.json`，所有 guard + `pipeline-mark-done.sh` 自動同步。
- 新增收尾/編排類 skill → 不用動本 plugin；git commit gate 自動涵蓋任何 commit。
- 會改 code 的 skill 跑完某關卡 → 呼叫 `pipeline-mark-done.sh <step>` 寫 marker。
- 完整 co-update map 見 `~/.agents/AGENTS-reference.md`。

## 元件

- **`skills/verify-tests/`** — 新 skill。分析 staged diff 判斷該跑哪些 unit / integration / e2e 測試。
- **`hooks/pre-commit-guard.sh`** — 攔 git commit，3-marker 檢查。`WIP:` / `wip:` / `backup:` 開頭的 commit message 自動放行。
- **`hooks/pre-ship-guard.sh`** — 攔 `/ship`，5-marker 檢查（加 document-release + tidy_docs）。
- **`hooks/session-pipeline-status.sh`** — SessionStart 靜默提示，dirty diff + stale marker 才印一行。
- **`scripts/pipeline-mark-done.sh`** — Claude 跑完 skill 後手動呼叫，寫 marker 進 `.claude/pipeline-state.json`。
- **`scripts/install-git-hook.sh`** — 讓沒有 husky 的 repo 也在 git 層受管（`--uninstall` 反安裝）。不覆蓋既有 hook。

## 安裝

```
claude plugins install pre-commit-pipeline@peter-claude-plugins
```

加入 `~/.claude/settings.json` 的 `enabledPlugins`。

## Marker 檔

`.claude/pipeline-state.json`（per-project，本機狀態，**加進 `.gitignore`**）：

```json
{
  "simplify":         { "done_at": "...", "first_marked_at": "...", "first_marked_head": "...", "staged_hash": "..." },
  "review":           { "done_at": "...", "first_marked_at": "...", "first_marked_head": "...", "staged_hash": "..." },
  "tests":            { "verified_at": "...", "first_marked_at": "...", "first_marked_head": "...", "staged_hash": "...",
                        "decisions": [...], "evidence_required": ["render"], "evidence": {...}, "regression": {...} },
  "document_release": { "done_at": "...", "first_marked_at": "...", "first_marked_head": "...", "staged_hash": "..." }
}
```

`staged_hash` = `git diff --cached` 的 SHA256。Staged 內容改變後 marker 自動失效。

`done_at` = 最後一次打勾（含重打）的時間，用於 24 小時陳舊警告。

`first_marked_at` = **這一輪**最早打勾的時間，重打時沿用不覆蓋，是防批次打勾唯一看的欄位。

`first_marked_head` = 寫下那個時間時的 `HEAD`。「這一輪」就是靠它界定的：commit 會推進 HEAD，所以 HEAD 對不上就代表那個時間戳屬於一個已經結束的輪次。少了這道綁定會出現一個比修之前更鬆的破口——正常跑完一輪、commit，然後在 24 小時內開始不相干的工作並三個一起連打，每個 marker 都會拿到新的 staged hash 卻沿用舊的分散時間，於是通行。`pipeline-mark-done.sh`（決定要不要沿用）與 gate（決定要不要採信）**兩邊都檢查**，所以手寫一份 state 也無法冒充舊輪次。

以下三種情況會拒絕採信 `first_marked_at`、退回讀 `done_at`：HEAD 對不上、時間解析不出來、時間落在未來（手改的未來時間永遠不會過期，等於永久後門）。超過 24 小時同樣重設，作為「一輪開著過夜」的兜底。沒有這兩個欄位的舊 marker 一律退回 `done_at`，行為與改動前相同。

`tests` 專屬的三個欄位由 `/verify-tests` 寫入，並受 `pipeline_check_evidence()` 硬檢查（**會擋，不是慣例**）：`evidence_required` 是這次 diff 需要的證據種類（依 `docs/verification/config.yaml` 判定，例如改到 UI 就要 `render`）、`evidence` 是各種類對應的**真實產物路徑**、`regression` 則在 `fix` 開頭的 commit 上必填（`test` 指向回填的迴歸測試，或 `skip_reason` 說明為何無法自動化）。guard 只驗欄位非空，內容的誠實由寫的人負責 —— 填假路徑等同繞過 gate。

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

中間存檔：git 層用 `PIPELINE_SKIP=1 git commit -m "..."` 跳過（husky repo 的 `pre-commit` 階段讀不到訊息，故不能再靠 `WIP:` 前綴）；Claude 內建 PreToolUse hook 仍認 `WIP:`/`backup:` 前綴與 `PIPELINE_SKIP=1`。

## Roadmap（已知延後項，回來改時看這裡）

> 2026-06-26 把 commit gate 改成 git-native（涵蓋 Codex/Fugu/Conductor）+ 抽 `pipeline-steps.json` 單一清單 + 加批次打勾偵測。當時刻意延後以下兩項：

- **A — 讓「打勾」綁定真實 evidence**（防止「沒跑 review 卻 mark」）。**`tests` 這一步已經做完了，`simplify` / `review` 還沒。**

  **已完成（2026-07-05，`fc81fd1` + `8ae7af3` + `9c02134`）**：
  - `verify-tests` skill 依 `docs/verification/config.yaml` 判定這次 diff 需不需要 `render` / `real_sample` 證據，寫進 marker 的 `evidence_required`。
  - `pipeline_check_evidence()`（`pipeline-lib.sh`）是**會擋的硬檢查**，不只是格式約定：`evidence_required` 裡每個 key 都必須有非空的 `evidence[key]`；`fix` 開頭的 commit 必須有 `regression.test` 或 `regression.skip_reason`。
  - git-native 與 PreToolUse **兩層都接上**了這個檢查。

  **未完成**：`simplify` 與 `review` 的 marker 仍只有時間戳與 hash，沒有任何 evidence 要求 —— 所以「沒真跑 review 卻打勾」目前唯一的防線還是批次打勾偵測（C），而 C 擋得住「同秒憑空出現」，擋不住「故意把假打勾拉開超過 `batch_window_seconds`」。2026-07-29 只修掉 C 的誤擋面（重打被誤判為造假），漏放面沒動。

  **回來做時**：`pipeline_check_evidence()` 目前寫死只讀 `.tests`，把它參數化成能檢查任一 step，就能沿用整套機制 —— 缺的是「`simplify`/`review` 的 evidence 由誰寫入」這個決定，不是機制。evidence 定義成「**查了什麼**」而非「找到什麼」即可繞開 `simplify` 可能合法無產出的難題（`tests` 的 `decisions[]` 本來就允許 `skip` 條目）。不要直接改 gstack skill（`review`/`simplify` 是 symlink，升級會被覆蓋）；由 orchestrator（`shipit` 或一支 wrapper）在真的跑完之後寫入。
  - 原本記著「使用者要求 `shipit`/`afk`/`end` 維持現有 scope，故未動」——**該約束 2026-07-29 起已不成立**，`shipit` 當日為了偵測 repo 自有 ship 機制而改過 step 4/7。現在缺的是決定，不是阻礙。
- ~~**非-husky repo 的一鍵 installer**~~ —— **2026-07-29 完成**，見 `scripts/install-git-hook.sh`（上方「強制是 git-native 的」一節）。
  - 當初記的兩條路裡，「由 installer **設定** `core.hooksPath`」沒有採用：那是整個 hooks 目錄的替換而非疊加，會讓 repo 既有的 `.git/hooks/` 全部失效。改用塞 stub。但**讀取**既有的 `core.hooksPath` 是必要的——repo 自己設了的話，git 只從那裡找 hook。
