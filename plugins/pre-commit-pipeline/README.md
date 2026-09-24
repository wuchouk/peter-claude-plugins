# pre-commit-pipeline

Commit 守門員 plugin。用 hook 機制強制驗證以下 skill 在 commit 前都跑過：

| Hook 觸發點 | 檢查的 marker |
|------------|---------------|
| `git commit`（PreToolUse Bash，Claude only） | `simplify`、`review`、`verify-tests` |
| `git commit`（**git-native, 所有 agent**） | 同上（見下方 git-native 層） |

Hook 失敗會 block 並透過 stderr 告訴你該跑哪個 skill。補跑 + 用 `pipeline-mark-done` helper 寫 marker 後即可放行。

**純文件的 commit 完全免章**（見下方「純文件免審」）。

原本還有一道 `/ship` gate，2026-09-23 移除，理由見下方「為什麼拿掉 /ship gate」。

## 強制是 git-native 的（跨 agent）

PreToolUse hook 只在 Claude Code 內生效；Codex/Fugu/Conductor 不會跑它。為了讓 commit gate 對**所有 committer**（Claude、Codex、Fugu、Conductor、人手）都生效，真正的地板放在 **git 層**：

- `~/.config/husky/init.sh` — husky v9.1 loader 在每個 husky repo 每次 hook 前都會 source 它。掛在 `pre-commit`（一定存在的 hook），呼叫 git-native guard。
- `hooks/git-commit-msg-guard.sh` — git-native guard 本體。**只在 repo 有 `.claude/` 目錄時納管**（opt-in，別人的 repo 不受影響）。
- **單一清單**：`pipeline-steps.json` 是所有 gate step 的唯一 source of truth；`scripts/pipeline-lib.sh` 是共用 reader/evaluator。要加/減一道關卡只改 `pipeline-steps.json`。
- **步驟有順序，綁定方式跟著順序走**：`gates` 陣列的順序就是步驟順序，`binding` 決定每個步驟的章怎麼算數。見下方「步驟順序與綁定規則」。
- **防批次打勾（anti-gaming）**：2026-09-20 移除，理由見下方專節。
- **沒有 husky 的 repo** → 跑一次 `bash scripts/install-git-hook.sh`，它放一支呼叫 guard 的 stub，讓該 repo 也在 git 層受管（`--uninstall` 移除）。四個要點：
  - **hook 目錄問 git，不寫死 `.git/hooks`**：repo 若設了 `core.hooksPath`，git 只從那裡讀 hook，裝錯地方等於沒裝卻以為有裝。
  - **絕不動不是本工具寫的 hook**。所有權以「內容與本工具會生成的**完全相同**」判定，不靠標記字串或行數——他人的 hook 只要湊巧含有相同字樣，靠標記判斷就會誤報已安裝（實際沒有 guard），uninstall 更會直接刪掉別人的檔案。
  - **guard 路徑在安裝當下解析成絕對路徑寫死**，不留 `$HOME` 讓執行期展開（換使用者、GUI 帶不同 HOME、plugin 搬家都會讓它找不到 guard）；而且找不到時 **fail closed**——一個靜默消失的 gate 比一個會抱怨的危險得多。
  - **husky repo 看的是 user hook 檔案，不是 `.husky/` 目錄**：husky loader 在該 hook 沒有對應 user 檔時會提前結束、根本不 source 全域 init，所以「有 `.husky/` 但沒有 `pre-commit`」的 repo 其實沒被涵蓋，仍需安裝。
  - 沒裝的話那個 repo 只剩 Claude PreToolUse hook 守著，而那層有兩個結構性限制：只在 Claude Code 內生效（Codex / Fugu / 人手 commit 沒守），且它必須從**命令字串**猜這是不是 commit —— 任何提到 `git commit` 的命令都會被誤攔，即使它根本不碰 git（實例：把一段解釋 commit gate 的說明餵給 `codex exec` 時被擋下）。從 git 自己觸發沒有這兩個問題。
- 繞過：`PIPELINE_SKIP=1 git commit …`（通用）；`WIP:`/`backup:` 訊息前綴在拿得到訊息的層（Claude PreToolUse、或有 `.husky/commit-msg` 的 repo）也可繞過。

## 步驟順序與綁定規則

`pipeline-steps.json` 的 `gates` 陣列順序**就是**步驟順序（simplify → review → tests），`binding` 決定每個步驟的章要用哪種方式對上目前的 staged 內容：

| binding | 意思 | 誰是這種 |
|---------|------|---------|
| `content`（預設，沒列到的一律是這種） | 章的 `staged_hash` 必須**等於**目前 staged hash | review、tests |
| `round` | 上面那條成立就算數；否則只要是**同一輪**做的、**後面**有綁內容的步驟替最終內容背書、且它沒看過的變動量在上限內，也算數 | simplify |

### 為什麼需要 round

這個閘門原本只有 `content` 一種判定，而它有個設計上的死結：步驟是有先後的，**照 review
意見修東西必然發生在 simplify 蓋章之後**，內容一改，simplify 的章就過期。要老實過關就得對新
內容重跑 simplify；simplify 再改一點，換 review 的章過期，如此循環。**只要最後一個動作改了任何
東西，前面步驟的章必然失效**，於是 agent 只剩兩條路：請使用者授權 `PIPELINE_SKIP=1`（閘門形同
虛設），或為了過關重跑一次沒有實質意義的步驟。2026-09-20 的 platform PR #1190 就是這樣被擋下、
最後靠繞過才 commit 進去的。

`round` 解開的就是這個結。核心觀察是：**真正看過最終內容的是排在後面的步驟**。review 排在
simplify 後面、而且它的章對得上最終 hash，就代表最終內容至少被 review 看過；唯一沒人保證的是
「review 之後那段修正本身有沒有被 simplify 過」，而變動量上限負責把這件事的範圍框住。

### round 要同時滿足的五個條件

1. `first_marked_head` 等於目前 HEAD。**HEAD 一變就是新的一輪**（commit、WIP commit、rebase、
   merge main 都算），上一輪的章不能替這一輪背書。不用 merge-base／ancestor 判定，那會讓前一個
   commit 的章替下一個 commit 掛保證。
2. 章在 24 小時內，且時間戳解析得出來。
3. 同一個 gate 裡，它**後面**有綁 `content` 的步驟，且那個步驟對得上目前 hash。
   排在 gate 最後的步驟後面沒有人，就算設成 `round` 也會退回 `content`——尾端步驟沒有下游
   能替它背書（情境 H）。
4. 章裡有 `staged_tree`（見下方 Marker 檔）。沒有就沒辦法算變動量。
5. 變動量在上限內。

**任何一條不成立都退回嚴格的 hash 比對**，也就是改動前的行為。換句話說，新規則只會比舊規則
**寬**，不存在「以前過得了、現在過不了」的情況。

### 變動量怎麼算

> 「simplify 沒看過多少內容」＝ 從它的 `staged_tree` 到目前 staged 內容之間的**新增側行數**。

- 只算新增側：被刪掉的行是 simplify **看過**、而且現在已經不存在的內容，不需要再看一次。
- `round_drift.exclude_paths` 裡的路徑**不計入**（預設 `docs/*.md`、`TODOS.md`、`tasks/todo.md`、
  `CHANGELOG.md`；`docs/*.md` 已經涵蓋巢狀，因為非 glob 的 pathspec 裡 `*` 會跨 `/`）。TODO 帳本與驗證文件依全域規則本來就要跟程式碼同一個 commit 更新，計進去
  等於讓帳本自己觸發重跑。**清單要窄**：第一版寫的是整批 `*.md`，結果讓閘門對「產品本身就是
  markdown」的 repo（就是這一個：`SKILL.md`、各 plugin 的 README）完全失明——簡化完再重寫
  300 行 SKILL.md，drift 算出來是 0。
- 上限 `= min( max(floor_lines, ratio_percent% × staged diff 總行數), max_lines )`（總行數同樣不含
  排除路徑），
  三個值都在 `pipeline-steps.json` 的 `round_drift`，現值 40 行 / 30% / 200 行。
- 超過上限會擋下，並印出實際行數與上限，此時重跑 `/simplify` 是有意義的——它確實有一大塊沒看過。

**校準依據（2026-09-20，用當天與近兩週的真實 session 紀錄）**：simplify 蓋章後到 review 蓋章前
的實際變動，中位數約 29 行、p90 約 136 行，觸發這次修正的 PR #1190 本身只有約 8–25 行（程式碼
部分）。唯一的大案例是 390 行，那是「simplify 之後又寫了一大段新功能」，本來就該重跑。所以 200
行的絕對上限能容納觀察到的所有正常 review 修正，又擋得住 390 那種。要調整就改 `round_drift`。

### pre-commit formatter（lint-staged／prettier）

commit 當下 formatter 改寫 staged 檔案 → hash 變 → **review 與 tests 的章過期並擋下**，和改動前
一樣，緩解方式仍是 `pipeline-mark-done.sh` 蓋章前先跑一次同一個 formatter。

注意 simplify 在這個情境下**也會被擋**，而且不是因為它自己過期：它的背書人（review）同時失效，
round 的條件 3 不成立，於是退回嚴格比對。round 幫得上的是「review 之後**刻意**改了東西」，不是
「所有人同時被 formatter 掃到」。

## 純文件免審（`docs_only`）

staged 的**每一個**路徑都命中 `docs_only.paths`、且**沒有**任何一個命中
`docs_only.instruction_paths` 時，commit gate 直接放行，**不需要任何章**。只要有一個不符合，
就照常走完整判定。空的 staged diff 不豁免。

放行時會在 stderr 印一行 `docs-only staged diff — gate skipped（沒有任何檔案落在 docs_only.paths 之外）`，因為一個安靜的
豁免和一個壞掉的閘門長得一模一樣。差一點就免審時（全部是文件形狀、但其中有指令類）也會印出
是**哪些檔**讓它不算純文件。

**豁免同時短路 evidence 硬檢查**，這是刻意的：否則 `fix(docs): 錯字` 仍會被要求補 regression
test，舊的 `.tests` marker 也仍會要求它的證據檔案存在——那就等於沒豁免。短路只發生在「已經
判定為純文件」之後，非純文件的 commit 沒有任何路徑能跳過 evidence。

這個順序（豁免 → marker gate → evidence）住在 `pipeline_enforce()` 一個地方，兩支 guard 只呼叫
它、各自保留自己的 exit code 與後續建議。之前是三支各自照順序呼叫兩三個函式＋註解提醒，靠的是
「記得」。兩層測試守著：情境 R 用 grep 斷言 `hooks/` 底下不再直接出現 `pipeline_eval_gate`／
`pipeline_check_evidence`（擋「繞過單一入口」），S1–S3 則讓 evidence 真的執行並斷言三種結果
（擋「順序被改壞」）。R 單獨擋不住順序問題——把 evidence 搬到豁免之前，R 照樣綠。

### 這不是舊的 `^docs/` 規則

改版前 `pipeline_eval_gate` 有一個 `docs_only` 判斷，用的是 regex `^docs/|\.md$`，而且它只豁免
5 秒批次檢查、不是免章（實務效果是純文件一口氣連蓋三個章就過——形式上要求、實質上不檢查）。
2026-09-20 改成誠實的規則時**沒有沿用那個 regex**，因為它有兩個洞：

- `^docs/` 把 `docs/` 底下的**所有**檔案都當文件。platform 的 `docs/` 底下有 644 個非 `.md`
  檔案，包含 16 個 `.ts` 與 59 個 `.json`——其中 `docs/verification/config.yaml` 正是驅動
  evidence 規則的設定檔。豁免掉 5 秒檢查無傷大雅，完全免章就是洞。
- `\.md$` 把**所有** markdown 都當文件，包括 `CLAUDE.md`、`SKILL.md` 這些「就是 agent 指令」
  的檔案。改 agent 的行為規則正是最該被審的那種改動。

所以 `paths` 只收 markdown 加惰性素材（圖片、PDF），`instruction_paths` 再把指令類扣掉。

`*.txt` 進過初稿又拿掉了：`requirements.txt` 是依賴清單，不是文件。抓到它的是
`test-post-restart.sh` 的 installer 情境——它拿 `a.txt` 當一般檔案，於是「未跑 pipeline 卻
commit 成功」突然變紅。情境 Q15 現在守著這條。

### 指令類清單（寧可寬，不可窄）

| 樣式 | 為什麼 |
|---|---|
| `:(glob,icase)**/CLAUDE.md`、`:(glob,icase)**/AGENTS*.md`、`:(glob,icase)**/GEMINI.md` | agent 規則本身；`AGENTS*.md` 才蓋得到 `AGENTS-reference.md`。用 `:(glob)` 而不是 `*CLAUDE.md`，後者會連 `NOTCLAUDE.md` 一起命中 |
| `:(glob,icase)**/SKILL.md` | 外掛 repo 的 59 個 `.md` 裡有 13 個是它 |
| `:(glob,icase)**/skills/**` | `:(glob)` magic 下 `**/` 可以匹配零層目錄，一條就同時蓋頂層與巢狀；`icase` 是因為 macOS 把 `Claude.md` 與 `CLAUDE.md` 當同一個檔，而 git pathspec 預設分大小寫。不加 `:(glob)` 的話 `**/skills/**` 命中不到頂層 `skills/`（`~/.agents` 就是這種結構），要寫成兩條 |
| `:(glob,icase)**/commands/**`、`agents/**`、`hooks/**` | slash command、subagent、hook 的定義；也涵蓋 `skills/*/references/*.md` 這種被 skill 載入的參考檔 |
| `:(glob,icase)**/.claude/**`、`.agents/**`、`.codex/**` | 專案層級的 agent 設定。`:(glob)` 在這裡不只是精簡：舊的 `.claude/**` 只命中頂層，monorepo 的 `apps/x/.claude/skills/**` 會整個漏掉 |
| `:(glob,icase)**/prompts/**`、`:(glob,icase)**/.cursor/**` | 其他 agent 生態的指令目錄 |
| `:(glob,icase)**/.github/copilot-instructions.md`、`.github/instructions/**`、`.github/prompts/**`、`.cursorrules`、`.windsurfrules` | 目前沒有，先納管。單檔收了、同族的目錄形式也要收 |

### 與 `round_drift.exclude_paths` 的差別

兩份清單長得像，問的問題不同，所以**刻意分開**：

| | 問的問題 | 例子 |
|---|---|---|
| `docs_only.paths` | 這個 commit 整體需不需要被審？ | 只改 `TODOS.md` → 免審 |
| `round_drift.exclude_paths` | 算「simplify 沒看過多少」時，這些行算不算？ | 程式碼 commit 附帶的 `TODOS.md` → 不計入 |

所以 `*.md` 在前者是文件、在後者**絕不能**整批排除（那正是 2026-09-20 修掉的 `SKILL.md` 盲點）。
反過來，`exclude_paths` 原本的 `docs/**` 也有同一個洞的小型版——simplify 蓋章後改 300 行
`docs/tools/gen.ts`，drift 會算成 0。同批收窄成 `docs/*.md`。

**但要誠實記一筆**：兩份清單問的問題不同，**盲點卻是共用的**。「markdown 不等於文件」這個教訓
在這裡修了兩次（2026-09-20 的 `SKILL.md`、這次的 `docs/**`），因為同一個判斷散在兩份資料裡。
長期該做的是一份路徑分類（`doc` / `asset` / `instruction`），兩個政策各自選集合——見 Roadmap B。

### 豁免自己的防線

這個判定的工作是**把閘門關掉**，所以每一種「讀不出來」都必須當成「不豁免」：

- **git 或 jq 失敗一律不豁免**。三個探針都檢查退出碼而不是只看輸出是否為空。少了這層，
  `instruction_paths` 裡放一個非字串會讓 jq 的 `@tsv` 中途 abort、指令清單看起來是空的，
  於是只改 `CLAUDE.md` 也會被豁免。
- **git 太舊（不支援 `:(exclude)`／`:(glob)`，< 1.9）也不豁免**。那種 git 會拒絕每一條
  pathspec，「沒有輸出」若被讀成「沒有非文件檔」，純程式碼的 commit 會被判成純文件並整個放行。
  退出碼檢查已經擋得住這條，開頭的 magic 探針是第二層。
- **PreToolUse 層遇到 `-a`／`--amend`／`-i`／`-p`／尾隨 pathspec 時不豁免**。那一層在 git
  之前執行、只看得到 index，而這些形式會把 index 以外的內容放進 commit：docs-only 的 index
  加上 `git commit -am` 曾經讓帶著程式碼的 commit 整個免審。git-native 層看到的是 git 已經
  更新過的 index，不受影響。

情境 T1–T5 守著這五條，每一條都做過突變驗證。

## 為什麼拿掉 /ship gate

原本 `hooks.json` 用 PreToolUse matcher `SlashCommand` 呼叫 `pre-ship-guard.sh`，要求
`gates.ship` 的五個章（commit 的三個 + `document_release` + `tidy_docs`）才放行 `/ship`。
2026-09-23 的 prompt audit 查 transcript 發現：現在的 Claude Code 是透過 Skill tool
（`{"skill":"ship"}`）呼叫 `/ship`，transcript 裡沒有任何 `SlashCommand` 呼叫，所以這道 gate
**從來沒觸發過**；而這段期間也沒有感覺到有東西因此漏掉。於是整道刪掉，而不是改接 Skill matcher：

- 刪掉的：`hooks.json` 的 `SlashCommand` 項目、`hooks/pre-ship-guard.sh`、`pipeline-steps.json`
  的 `gates.ship`，以及只在 ship gate 缺章時才會印出的 `help.document_release`／`help.tidy_docs`。
- 留著的：`aliases` 裡的 `document-release`／`tidy-docs`。`tidy-docs` skill 仍會呼叫
  `pipeline-mark-done.sh tidy-docs`，拿掉 alias 會讓那一步報錯。這些章照樣寫得進 state 檔，
  只是目前沒有任何 gate 讀它們。
- commit gate 完全不變：`evidence_gates`、`docs_only.gates` 仍只列 `commit`。

## 為什麼拿掉 5 秒批次規則

原本有一條反作弊規則：同一份 staged diff 的 ≥2 個章若 `first_marked_at` 落在
`batch_window_seconds`（5 秒）內，視為「沒真跑就打勾」並擋下。2026-09-20 移除，三個理由：

1. **在最該管的 repo 裡結構上不會觸發**：platform 有 lint-staged，`pipeline-mark-done.sh` 每次
   蓋章前會先跑一次 formatter（3–6 秒），所以連續蓋三個章天生就超過 5 秒。當天幾個 worktree 的
   章剛好各隔 6 秒，不是因為誰在等，而是 formatter 的耗時——這條規則實際上只擋得到沒有
   formatter 的小 repo，而那裡本來就沒什麼好防的。
2. **誤觸之後在同一輪內解不開**：`first_marked_at` 在同一個 HEAD、24 小時內會一直沿用，重蓋不會
   刷新它。一旦被判成批次，照著訊息「重跑再蓋」仍然被擋，唯一出路是 `PIPELINE_SKIP=1`、手改
   state 檔，或等 HEAD 變動。一條誤觸後只能靠繞過解決的規則，實際效果是在訓練使用者繞過閘門。
3. **它分不清要分的兩件事**：「工作做完後把章補齊」和「沒做就蓋章」在時間軸上長得一模一樣。
   任何時間訊號都有這個問題——把假打勾刻意拉開超過視窗即可，換一個秒數只是換一個要繞過的數字。

**移除後擋不住什麼，說清楚**：`simplify`／`review`「沒跑就蓋章」**現在沒有任何機制擋得住**，
不要以為拿掉之後有別的東西接手了。`tests` 只在兩種情況下有實質防線（`pipeline_check_evidence()`
的證據硬檢查）：repo 有 `docs/verification/config.yaml` 且這次 diff 命中對應 layer，或 commit
訊息以 `fix` 開頭；兩者都不成立時（例如這個 plugin repo 自己）它同樣只是一個時間戳。要真的擋住，
得走 Roadmap 的方案 A。

還有一個沒寫在上面三條裡、但份量最重的代價：誤觸時唯一的出路 `PIPELINE_SKIP=1` 關掉的是**整條
閘門**，包含 `tests` 那些真的有效的硬檢查。也就是說這條規則的淨效果，是用一個擋不到造假的檢查，
換到使用者定期練習繞過所有防線。

`first_marked_at` **繼續寫入但沒有讀者**，`first_marked_head` 則自 2026-09-20 起由 round 判定讀取（上方「步驟順序與綁定規則」條件 1）。`first_marked_at` 留著的理由是升級過渡：
已安裝的 plugin cache 裡那份 `pipeline-lib.sh` 還帶著批次檢查，若連寫入一起停掉，它會退回讀
`done_at`。有差別的情境是**重打**——一輪真的跑開了（三個章先後蓋），之後 diff 又動過所以三個
一起重蓋：沿用的分散時間戳會讓舊 cache 放行，不沿用則被它擋下。（同秒三連打在寫與不寫之下舊
cache 都會擋；docs-only 的 staged diff 則本來就豁免。）把 cache 同步成新版之後這個理由失效，
屆時 `first_marked_at` 可以清掉；`first_marked_head` 不行，round 判定靠它界定「這一輪」。

### 給未來開發者的慣例

- 新增一道關卡 → 只改 `pipeline-steps.json`，所有 guard + `pipeline-mark-done.sh` 自動同步。新步驟預設是 `content`（從嚴），要放寬成 `round` 必須確認它**後面**還有綁內容的步驟。
- 改 gate 規則 → 跑 `tests/gate-scenarios.sh`；改 `promote-plugin.sh` → 跑 `tests/promote-scenarios.sh`。上線見下方。
- 新增收尾/編排類 skill → 不用動本 plugin；git commit gate 自動涵蓋任何 commit。
- 會改 code 的 skill 跑完某關卡 → 呼叫 `pipeline-mark-done.sh <step>` 寫 marker。
- 完整 co-update map 見 `~/.agents/AGENTS-reference.md`。

## 元件

- **`skills/verify-tests/`** — 新 skill。分析 staged diff 判斷該跑哪些 unit / integration / e2e 測試。
- **`hooks/pre-commit-guard.sh`** — 攔 git commit，3-marker 檢查。`WIP:` / `wip:` / `backup:` 開頭的 commit message 自動放行。
- **`hooks/session-pipeline-status.sh`** — SessionStart 靜默提示，dirty diff + stale marker 才印一行。
- **`scripts/pipeline-mark-done.sh`** — Claude 跑完 skill 後手動呼叫，寫 marker 進 `.claude/pipeline-state.json`。
- **`scripts/install-git-hook.sh`** — 讓沒有 husky 的 repo 也在 git 層受管（`--uninstall` 反安裝）。不覆蓋既有 hook。
- **`scripts/promote-plugin.sh`** — 在 worktree 改完後上線：併進主 checkout ＋ 同步 plugin cache ＋ 自我驗證（見下方「上線」）。
- **`tests/gate-scenarios.sh`** — 閘門判定的情境測試（見下方「測試」）。
- **`tests/promote-scenarios.sh`** — `promote-plugin.sh` 的沙箱情境測試（假 HOME，不碰真實 checkout）。

## 安裝

```
claude plugins install pre-commit-pipeline@peter-claude-plugins
```

加入 `~/.claude/settings.json` 的 `enabledPlugins`。

## Marker 檔

`.claude/pipeline-state.json`（per-project，本機狀態，**加進 `.gitignore`**）：

```json
{
  "simplify":         { "done_at": "...", "first_marked_at": "...", "first_marked_head": "...", "staged_hash": "...", "staged_tree": "..." },
  "review":           { "done_at": "...", "first_marked_at": "...", "first_marked_head": "...", "staged_hash": "...", "staged_tree": "..." },
  "tests":            { "verified_at": "...", "first_marked_at": "...", "first_marked_head": "...", "staged_hash": "...", "staged_tree": "...",
                        "decisions": [...], "evidence_required": ["render"], "evidence": {...}, "regression": {...} }
}
```

`staged_hash` = `git diff --cached` 的 SHA256。回答「**還是不是**同一份內容」。

`staged_tree` = `git write-tree` 的結果，也就是蓋章當下 index 的快照。回答「這一步**看過什麼**」——hash 只能回答相同／不同，要算「內容後來走了多遠」需要真的能 diff 的東西。`git write-tree` 只是把既有 index 寫成 tree 物件，不會動到 index 或工作區；index 處於衝突狀態時會失敗，這時這個欄位會被**刪掉**（不是單純不寫——留著上一輪的 tree 會讓 hash 與 tree 描述不同內容，drift 就量到錯的基準），gate 退回嚴格 hash 比對。

`done_at` = 最後一次打勾（含重打）的時間，用於 24 小時陳舊警告。

`first_marked_at` = **這一輪**最早打勾的時間（重打時沿用）。gate 不讀它，留著的理由見上方專節末段。

`first_marked_head` = 寫下它時的 `HEAD`，「這一輪」就是靠它界定的——commit 會推進 HEAD，對不上就是另一輪。**round 判定的條件 1 讀的就是這個欄位**。

`tests` 專屬的三個欄位由 `/verify-tests` 寫入，並受 `pipeline_check_evidence()` 硬檢查（**會擋，不是慣例**）：`evidence_required` 是這次 diff 需要的證據種類（依 `docs/verification/config.yaml` 判定，例如改到 UI 就要 `render`）、`evidence` 是各種類對應的**真實產物路徑**、`regression` 則在 `fix` 開頭的 commit 上必填（`test` 指向回填的迴歸測試，或 `skip_reason` 說明為何無法自動化）。guard 驗每個證據路徑是存在且非空的檔案或目錄；`live` 由 guard 自己從 staged diff 對 `layers.external_sources.paths` 推導（不信 marker 的 `evidence_required`），並驗 probe JSON 的 `pass: true` 與它比命中的 staged 檔案新；無法真連線時在 `decisions[]` 記一筆 `type: live, status: skipped` 附理由。`repro`（`pipeline-mark-done.sh repro --report … --path … --spec|--probe …`，由 triage-report 寫）標記「這個 fix 回答哪個問題回報、使用者描述的路徑是什麼」：之後的 `fix` commit 必須讓那個 spec 在 staged diff 裡新增或修改（或 probe 在改動後 pass），沒有 skip。內容是否真的對應這次改動仍由寫的人負責。

## 工作流程

```
1. 改 code → git add
2. /simplify           → pipeline-mark-done simplify
3. /review             → pipeline-mark-done review
4. /verify-tests       → skill 自帶寫 marker
5. git commit          → pre-commit-guard 放行 ✓
```

第 3 步的 review 如果改了東西（正常情況），**不需要回頭重跑 simplify**：review 與 tests 的章對得上最終內容，simplify 走 `round` 判定即可。只有在 simplify 之後的新增超過 `round_drift` 的上限時才會要求重跑，訊息會印出實際數字與上限。

中間存檔：git 層用 `PIPELINE_SKIP=1 git commit -m "..."` 跳過（husky repo 的 `pre-commit` 階段讀不到訊息，故不能再靠 `WIP:` 前綴）；Claude 內建 PreToolUse hook 仍認 `WIP:`/`backup:` 前綴與 `PIPELINE_SKIP=1`。

## 刻意接受的缺口

這幾件事是想過之後決定不處理的，不是漏掉：

1. **變動量上限之內的內容，simplify 沒看過**（review 看過）。這是 `round` 的定義本身，不是 bug。
   上限就是在框這個缺口的大小。
2. **沒跑步驟就蓋章，完全擋不住**（詳見「為什麼拿掉 5 秒批次規則」與 Roadmap 方案 A）。
3. **二進位檔的變動不計入變動量**（numstat 對二進位檔回報 `-`）。實務上 staged 二進位檔多半是
   截圖／測試素材，不是 simplify 要看的東西。
4. **`*.svg` 被當成惰性素材**，但 SVG 技術上可以內嵌 script。這裡只是「免審」不是「會被執行」，
   風險低；文件配圖是常態，為它加檢查不划算。
5. **`docs_only` 的判定只看路徑，不看內容**。一份 `docs/guide.md` 裡貼滿可執行指令、或一個
   名為 `notes.md` 的 symlink 指向別處，都會被當成文件放行。要再往下收就得讀內容，那不是 hook
   該做的事。
6. **指令類清單是 plugin 全域的**，各 repo 沒辦法補自己的特殊結構（`docs/skill-refs/*.md`
   之類）。要調整只能改 plugin 這份，權威來源下放到各 repo 的想法記在 Roadmap B。
7. **變動量只看行數，不看性質**：30 行的核心邏輯改寫和 30 行的字串常數變動一樣計。要分辨性質
   就得真的理解程式碼，那是 agent 的工作，不是 hook 的工作（hook 內有 120 秒預算，且不能 spawn
   agent CLI）。

## 測試

三支腳本，都不碰任何真實 repo（各自開暫存 git repo／假 HOME），可重跑：

```
bash <這個外掛>/tests/gate-scenarios.sh      # 閘門判定的情境
bash <這個外掛>/tests/promote-scenarios.sh   # 上線腳本（假 HOME 沙箱，含「失敗要還原」）
bash <這個外掛>/test-post-restart.sh          # hook 端點 + mark-done 寫入路徑 + installer
```

三支都從腳本自身位置推導外掛路徑，所以**在 worktree 裡跑測到的是你正在改的那份**
（`PIPELINE_PLUGIN_ROOT` 可覆寫）。`gate-scenarios.sh` 涵蓋的情境：

| | 情境 | 期望 |
|---|------|------|
| A | simplify@舊內容、review+tests@目前內容（2026-09-20 的死結） | 放行，且真實 commit 通過 |
| B | review 仍停在舊 hash | 擋下，且真實 commit 被擋 |
| C | 完全沒蓋 simplify | 擋下 |
| D | HEAD 已換（上一輪的章） | 擋下 |
| E | 舊格式 state（無 `staged_tree`／`first_marked_head`） | 不報錯；hash 相符放行、過期擋下 |
| F | simplify 之後改動超過上限 | 擋下並印出行數與上限 |
| G | simplify 章超過 24 小時 | 擋下 |
| H | round 步驟後面沒有 content 步驟 | 退回嚴格比對 |
| J1 | simplify 之後只動 `exclude_paths` 裡的檔案（`docs/*.md`、`TODOS.md`） | 放行（不計入變動量） |
| J2 | simplify 之後重寫 300 行 `SKILL.md`（沒被排除的產品內容） | 擋下（第一版整批排除 `*.md` 時會放行） |
| M | 以刪除為主的修正（新增 5 行、刪除 248 行） | 放行（只算新增側；改成加總側這條會紅） |
| N | `exclude_paths` 是 `[]`／字串／物件，`round_drift` 的值不是整數 | 退回預設，閘門不能自己炸（bash 3.2 的空陣列展開） |
| O | index 有衝突讓 `git write-tree` 失敗 | `staged_tree` 被刪掉，不沿用上一輪的值 |
| Q1 | 全 `docs/*.md`、零個章 | 放行並印說明 |
| Q2 | 純文件混一個 `.ts` | 照常擋 |
| Q3/4/9 | `CLAUDE.md`／巢狀 `skills/**/SKILL.md`／頂層 `skills/*.md`／`apps/x/.claude/skills/**`／`docs/AGENTS.md` | 都擋，訊息指名該檔 |
| Q5 | 舊 JSON 沒有 `docs_only` 鍵 | 不豁免、不報錯 |
| Q6 | 真實 `git commit` 一正一反 | 純文件過、混程式碼擋 |
| Q7 | PreToolUse 與 git-native 兩條路徑 | 行為一致 |
| Q8/15 | `docs/tools/gen.ts`／`docs/verification/config.yaml`／`requirements.txt` | 都擋（舊 `^docs/` 與 `*.txt` 的洞） |
| Q10 | `.md` 配一張 `.png` | 放行 |
| Q11 | `docs_only.gates` 拿掉 `commit` | 不豁免（證明接線是活的，不是死碼） |
| Q12–Q13 | 2026-09-20 的兩個真實案例（`~/.agents` 改 `AGENTS*.md`／platform 純文件含 svg） | 擋／放行 |
| Q14 | simplify 後改 300 行 `docs/tools/gen.ts` | 計入變動量並擋下 |
| S1–S3 | 讓 evidence 真的有東西可擋：純文件豁免／commit gate／`evidence_gates` 不列 commit | 放行／擋下／放行（證明接線是活的） |
| S4 | 刪掉 `exclude_paths` 鍵 | 什麼都不排除（不得有硬編 fallback） |
| S5 | 空的 staged diff | 不豁免 |
| S6 | `evidence_gates` 型別壞掉 | 仍跑 evidence（fail-closed） |
| T1 | 帶 `-a`／`--amend`／`-i`／尾隨 pathspec 的 commit 形式（index 之外的內容） | 都不吃豁免 |
| T2 | git 不支援 `:(exclude)`／`:(glob)` | 不豁免（fail-closed） |
| T3 | `instruction_paths` 裡有非字串 | 不豁免（不採信半份清單） |
| T4–T5 | `Claude.md` 大小寫變體／`.cursor/rules`、`prompts/`、`.github/instructions` | 都算指令類 |
| R | `hooks/` 直接呼叫 `pipeline_eval_gate`／`pipeline_check_evidence` | 變紅（不得繞過單一入口） |
| U | 不存在的 gate 名稱／`gates.commit` 是空陣列／`pipeline-steps.json` 讀不到（有／沒有 `set -u`，外加真的 PreToolUse hook） | 擋下並說明原因，hook 以 exit 2 結束（修正前三種都會放行） |
| K | 三個章同秒連打 | 放行（5 秒規則已移除） |
| L | `staged_tree` 指向已不存在的物件 | 擋下（算不出變動量就退回嚴格，不 fail open） |

## 上線（在 worktree 改完之後）

```
bash <這個外掛>/scripts/promote-plugin.sh
```

併進主 checkout ＋ rsync 進 `~/.claude/plugins/cache/…`（Claude Code 的 PreToolUse 層讀的是
cache 副本，而它在 git 之前就擋——不同步的話會變成 git 層新規則、Claude 內舊規則）＋ 印出兩處
`pipeline-lib.sh` 的 SHA256 確認一致 ＋ 用主 checkout 的版本重跑情境測試。會先印出要做什麼並等你
輸入 `yes`（非互動請設 `PROMOTE_ASSUME_YES=1`）。

驗證發生在 cache 已經被換掉**之後**，所以它擋不住壞版本上線——腳本改成先把 cache 備份起來，
雜湊不符／檔案有 drift／情境測試沒過時還原回去並明講「已還原」。`tests/promote-scenarios.sh`
的 P7 就在驗這條路徑。

> **這支腳本的前提**：2026-09-20 這次的改動只會讓閘門**變寬**，且新舊 state 格式雙向相容，
> 所以上線時間點不必避開進行中的 session。**日後若改成更嚴的規則，這個假設不成立**——那時要先
> 確認沒有 session 正卡在 commit 中途，或改成分階段上線。

## Roadmap（已知延後項，回來改時看這裡）

> 2026-06-26 把 commit gate 改成 git-native（涵蓋 Codex/Fugu/Conductor）+ 抽 `pipeline-steps.json` 單一清單 + 加批次打勾偵測（該偵測已於 2026-09-20 移除）。當時刻意延後以下兩項：

- **A — 讓「打勾」綁定真實 evidence**（防止「沒跑 review 卻 mark」）。**`tests` 這一步已經做完了，`simplify` / `review` 還沒。**

  **已完成（2026-07-05，`fc81fd1` + `8ae7af3` + `9c02134`）**：
  - `verify-tests` skill 依 `docs/verification/config.yaml` 判定這次 diff 需不需要 `render` / `real_sample` 證據，寫進 marker 的 `evidence_required`。
  - `pipeline_check_evidence()`（`pipeline-lib.sh`）是**會擋的硬檢查**，不只是格式約定：`evidence_required` 裡每個 key 都必須有非空的 `evidence[key]`；`fix` 開頭的 commit 必須有 `regression.test` 或 `regression.skip_reason`。
  - git-native 與 PreToolUse **兩層都接上**了這個檢查。

  **未完成**：`simplify` 與 `review` 的 marker 仍只有時間戳與 hash，沒有任何 evidence 要求 —— **「沒真跑 review 卻打勾」目前沒有任何防線**。2026-09-20 移除批次打勾偵測（C）之後，這件事完全沒有機制在擋（移除理由見上方專節：C 擋不住它要擋的行為，卻會誤擋而且誤擋後只能靠 `PIPELINE_SKIP=1` 脫身）。這一項因此從「有部分防線」升級為 **pipeline 目前最大的漏放面**。

  **回來做時**：`pipeline_check_evidence()` 目前寫死只讀 `.tests`，把它參數化成能檢查任一 step，就能沿用整套機制 —— 缺的是「`simplify`/`review` 的 evidence 由誰寫入」這個決定，不是機制。evidence 定義成「**查了什麼**」而非「找到什麼」即可繞開 `simplify` 可能合法無產出的難題（`tests` 的 `decisions[]` 本來就允許 `skip` 條目）。不要直接改 gstack skill（`review`/`simplify` 是 symlink，升級會被覆蓋）；由 orchestrator（`shipit` 或一支 wrapper）在真的跑完之後寫入。
  - 原本記著「使用者要求 `shipit`/`afk`/`end` 維持現有 scope，故未動」——**該約束 2026-07-29 起已不成立**，`shipit` 當日為了偵測 repo 自有 ship 機制而改過 step 4/7。現在缺的是決定，不是阻礙。
  - 這個 repo 沒有 TODO 帳本，所以這一段就是帳本。為了讓下次回來時不用重新想，缺的決定寫成三個具體選項：(1) **誰寫入**——`shipit` orchestrator，還是一支包住 `/simplify`／`/review` 的 wrapper skill？(2) **evidence 的 schema**——沿用 `tests` 的 `evidence`／`decisions[]` 形狀，記「查了哪些檔案／哪幾條規則」，還是只記一個 agent session id？(3) **無產出時怎麼過**——沿用 `decisions[] {status: skipped, reason}`，還是要求至少列出檢查清單。
- **B — round 綁定的四個已知弱點**（2026-09-20 的 review 提出，當次評估後延後，理由寫在這裡以免下次重新想一遍）：
  - **背書關係是隱含的**：「後面有 content 步驟」靠 `gates` 陣列位置推導；日後往
    `gates.commit` 尾端加一個 `lint`，`lint` 就自動變成 simplify 的背書人，即使它根本不看程式碼品質。更深的做法是把關係寫成資料
    （`"simplify": {"binding":"round","vouched_by":["review"]}`），或抽一份 canonical 的有序
    `steps` 清單、各 gate 只列子集。沒做的理由：目前只有一個 round 步驟、一個背書人，先讓規則
    落地收集實際誤判再改結構。
  - **同一個 lib 裡現在有三套路徑分類**：`round_drift.exclude_paths`（算不算 drift）、
    `docs_only`（要不要審）、以及 `pipeline_check_evidence()` 讀專案 `docs/verification/config.yaml`
    的 `layers.*.paths`（要不要證據）。三套問的是不同政策問題，但分類本身應該只有一份：
    `path_classes: {doc, asset, instruction}`，各政策選自己要的集合。這樣「markdown 不等於文件」
    這種教訓只需要修一個地方（目前修了兩次）。
  - **而且兩套 matcher 語意相反**：drift 與 docs_only 走 git pathspec，evidence 走
    `pipeline_check_evidence()` 裡的 Python `rx()`。同一個字串在兩邊意思不同——`*.md` 在 git
    命中 `docs/a.md`、在 `rx()` 不命中；`**/skills/**` 在 git 不加 `:(glob)` 命中不到頂層、在
    `rx()` 命中。要收斂就全部走 git pathspec（統一加 `:(glob)`），Python 只負責讀 YAML。
  - **`instruction_paths` 硬編在 plugin 層**，對所有 repo 生效。知道 `prompts/`、
    `docs/skill-refs/*.md` 算不算指令的是 repo 不是 plugin；權威來源應該下放到各 repo 的
    `docs/verification/config.yaml`，plugin 這份當**地板**（repo 只能加不能減）。
  - **`staged_tree` 與 `staged_hash` 是同一個概念的兩個欄位**：tree OID 本身就是 index 的正規
    內容雜湊，可比較也可 diff，理論上能取代 `staged_hash` 並讓 `compute-staged-hash.sh` 整支
    消失。沒做的理由：那會改變 marker 格式，而這次的硬性限制是對進行中 session 的舊 state
    雙向相容。要做的話得單獨一輪、配合 cache 同步。
  - **「每個步驟各自負責哪些檔案」缺一等公民**：drift 的排除清單與「文件變動讓 review／tests
    的章過期」是同一個缺概念的兩面。做出 per-step scope 可以一次關掉兩者，但
    **它不會取代 round**——review 之後的修正本身就是程式碼，死結還在。
- **C — 兩支測試腳本的共用樣板**（`mkrepo`／`pass`／`fail`／`gate_run` 各寫兩份）可以抽成
  `tests/lib.sh`；`scripts/read-marker.sh` 全 repo 零引用，是既有死碼，一併處理。
- **D — 壞設定的測試只蓋到 PreToolUse 層**（2026-09-23 PR #4 審查提出）：情境 U 用截斷的
  `pipeline-steps.json` 驗了 lib 與 `hooks/pre-commit-guard.sh`（exit 2），但 git 層的
  `hooks/git-commit-msg-guard.sh` 遇到同樣的壞設定要以非 0（exit 1）結束、擋下 commit，這條沒有測試；
  「設定檔無讀取權限」（`chmod 000`）這種讀不到的形式兩層都沒測。**回來做時**：在 U 裡對
  git-native guard 補一筆截斷設定、兩層各補一筆 `chmod 000`（測完要 `chmod` 回來，否則暫存目錄清不掉）。
- **E — `promote-plugin.sh` 不支援「PR 已經 squash merge」**（2026-09-23 PR #4 上線時遇到）：
  第 1 步把 worktree 分支 `merge --ff-only` 進主 checkout，但 squash merge 之後 main 已經有等價內容、
  分支的 commit 卻永遠不會是 main 的祖先，第 1 步必定以「無法 fast-forward」中止；錯誤訊息說
  「完成後重跑會偵測到已經併好」，在 squash 的情況下重跑也一樣卡住。當次改成手動只做第 2 步
  （`rsync -a --delete --exclude='.in_use/'` 主 checkout → cache）。**回來做時**：偵測「分支內容
  已在 main」（例如 `git diff main <branch> -- $REL` 為空）就跳過第 1 步、直接從主 checkout 同步。
  順帶：正向同步（第 106 行）已排除 `.in_use`，但失敗時的還原（`restore_cache`，第 99 行）是用
  備份整份 `rsync --delete` 回寫，會把同步期間 Claude Code 新建或移除的 `.in_use` 標記換回備份時的狀態；
  還原時也該 `--exclude='.in_use'`。
- ~~**非-husky repo 的一鍵 installer**~~ —— **2026-07-29 完成**，見 `scripts/install-git-hook.sh`（上方「強制是 git-native 的」一節）。
  - 當初記的兩條路裡，「由 installer **設定** `core.hooksPath`」沒有採用：那是整個 hooks 目錄的替換而非疊加，會讓 repo 既有的 `.git/hooks/` 全部失效。改用塞 stub。但**讀取**既有的 `core.hooksPath` 是必要的——repo 自己設了的話，git 只從那裡找 hook。
