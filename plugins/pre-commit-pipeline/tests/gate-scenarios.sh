#!/usr/bin/env bash
# gate-scenarios.sh — 閘門判定的情境測試（可重跑，不碰任何真實 repo）
#
# 每個情境開一個全新的暫存 git repo，製造特定的 marker / staged 內容形狀，
# 直接呼叫 pipeline_eval_gate 斷言放行或擋下；情境 A、B 另外裝上 git hook
# 走真正的 `git commit` 端到端驗證（確認 lib 的改動確實傳導到 git 層）。
#
# 跑法：bash <這個外掛>/tests/gate-scenarios.sh
# 外掛位置由腳本自身推導，所以在 worktree 裡也能跑（不會誤用主 checkout 的版本）。
set -uo pipefail

# 帶著 PIPELINE_SKIP=1 進來（README 教的繞過方式，很容易殘留在同一個 shell 裡）會讓
# 端到端斷言變成假綠／假紅：A 是靠繞過而不是閘門放行，B 的「應該被擋」則永遠失敗。
# promote-plugin.sh 會跑這支，所以剛用過繞過的 shell 直接上線就會踩到。
unset PIPELINE_SKIP

PLUGIN="${PIPELINE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
MARK="$PLUGIN/scripts/pipeline-mark-done.sh"
HASH_SH="$PLUGIN/scripts/compute-staged-hash.sh"
WORK="${TMPDIR:-/tmp}/pipeline-gate-scenarios-$$"
mkdir -p "$WORK"

FAILED=0
pass() { echo "  ✓ $1"; }
fail() { echo "  ✗ $1"; FAILED=$((FAILED + 1)); }

# 每個情境一個乾淨 repo。lint-staged 不存在 → mark-done 不會有預先格式化的延遲。
new_repo() {
  local d="$WORK/$1"
  rm -rf "$d"; mkdir -p "$d/.claude"
  cd "$d" || exit 1
  git init -q .
  git config user.email t@t; git config user.name t
  git config commit.gpgsign false
  printf 'line1\nline2\nline3\n' > app.py
  git add app.py
  PIPELINE_SKIP=1 git commit -qm "init" --no-verify
}

# gate 的輸出與回傳碼，一次呼叫同時取得（跟 test-post-restart.sh 的 gate_run 同形狀）。
# 用子 shell 隔離，避免 lib 的變數殘留到下一個情境。
gate_run() {
  local g="${1:-commit}"
  GATE_OUT=$( ( . "$PLUGIN/scripts/pipeline-lib.sh"; pipeline_eval_gate "$g" "test" ) 2>&1 ) \
    && GATE_RC=0 || GATE_RC=$?
}

# 兩條執法路徑各自的結果。純文件豁免住在 guard 裡（在 pipeline_eval_gate 之前），
# 所以只用 gate_run 測不到它——兩條都要各自驗，否則會出現「lib 對了但某條路徑沒接上」。
guard_run() {   # $1 = pretooluse|gitnative
  local layer="$1"
  case "$layer" in
    pretooluse)
      G_OUT=$(echo '{"tool_input":{"command":"git commit -m \"docs: x\""}}' \
        | bash "$PLUGIN/hooks/pre-commit-guard.sh" 2>&1) && G_RC=0 || G_RC=$? ;;
    gitnative)
      G_OUT=$(bash "$PLUGIN/hooks/git-commit-msg-guard.sh" 2>&1) && G_RC=0 || G_RC=$? ;;
  esac
}

# 建一份純文件的 staged diff（不蓋任何章）
stage_files() {
  local f
  for f in "$@"; do mkdir -p "$(dirname "$f")"; echo "內容 $f" >> "$f"; git add "$f"; done
}

# 產生 n 行內容附加到檔案並 stage
add_lines() {
  local file="$1" n="$2" tag="$3" i
  for ((i = 1; i <= n; i++)); do echo "$tag-$i" >> "$file"; done
  git add "$file"
}

echo "=== A) simplify@舊內容、review+tests@目前內容 → 放行（2026-09-20 的死結情境）==="
new_repo incident
add_lines app.py 10 A                      # 版本 A
bash "$MARK" simplify >/dev/null            # simplify 蓋在 A
add_lines app.py 8 B                        # review 指出問題後的修正 → 版本 B
bash "$MARK" review >/dev/null              # review + tests 蓋在 B
bash "$MARK" verify-tests >/dev/null
SIM_H=$(jq -r '.simplify.staged_hash' .claude/pipeline-state.json)
REV_H=$(jq -r '.review.staged_hash' .claude/pipeline-state.json)
[ "$SIM_H" != "$REV_H" ] && pass "前置條件成立：simplify 與 review 的 hash 確實不同" \
  || fail "前置條件不成立，這個情境沒測到東西"
{ gate_run commit; [ "$GATE_RC" = "0" ]; } && pass "gate 放行" || fail "gate 擋下了：$(printf "%s" "$GATE_OUT" | head -6)"
# 端到端：裝 git hook，走真正的 git commit
bash "$PLUGIN/scripts/install-git-hook.sh" >/dev/null 2>&1
if git commit -qm "feat: x" 2>/dev/null; then pass "真實 git commit 通過"; else fail "真實 git commit 仍被擋"; fi

echo ""
echo "=== B) review 仍停在舊 hash → 擋下 ==="
new_repo stale-review
add_lines app.py 10 A
bash "$MARK" review >/dev/null              # review 蓋在 A
add_lines app.py 8 B
bash "$MARK" simplify >/dev/null            # simplify + tests 蓋在 B
bash "$MARK" verify-tests >/dev/null
{ gate_run commit; [ "$GATE_RC" != "0" ]; } && pass "gate 擋下" || fail "gate 放行了（review 沒看過最終內容）"
printf '%s' "$GATE_OUT" | grep -q "review" && pass "訊息指出是 review 要重跑" || fail "訊息沒指出 review：$GATE_OUT"
bash "$PLUGIN/scripts/install-git-hook.sh" >/dev/null 2>&1
if git commit -qm "feat: x" 2>/dev/null; then fail "真實 git commit 沒被擋"; else pass "真實 git commit 被擋"; fi

echo ""
echo "=== C) 完全沒蓋 simplify → 擋下 ==="
new_repo no-simplify
add_lines app.py 10 A
bash "$MARK" review >/dev/null
bash "$MARK" verify-tests >/dev/null
{ gate_run commit; [ "$GATE_RC" != "0" ]; } && pass "gate 擋下" || fail "gate 放行了"
printf '%s' "$GATE_OUT" | grep -q "simplify" && pass "訊息列出缺少的 simplify" || fail "訊息沒提 simplify：$GATE_OUT"

echo ""
echo "=== D) HEAD 已換（章屬於上一輪）→ 擋下 ==="
new_repo head-moved
add_lines app.py 10 A
bash "$MARK" simplify >/dev/null             # simplify 蓋在 HEAD0 / 版本 A
PIPELINE_SKIP=1 git commit -qm "WIP: 上一輪" --no-verify   # HEAD 前進
add_lines app.py 8 B
bash "$MARK" review >/dev/null               # review + tests 蓋在 HEAD1 / 版本 B
bash "$MARK" verify-tests >/dev/null
{ gate_run commit; [ "$GATE_RC" != "0" ]; } && pass "gate 擋下（跨輪的 simplify 章不算數）" || fail "gate 放行了：跨輪的章被採信"
printf '%s' "$GATE_OUT" | grep -q "simplify" && pass "訊息要求重跑 simplify" || fail "訊息沒提 simplify：$GATE_OUT"

echo ""
echo "=== E) 舊格式 state（沒有 first_marked_head / staged_tree）→ 不報錯 ==="
new_repo legacy
add_lines app.py 10 A
H=$(bash "$HASH_SH")
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
cat > .claude/pipeline-state.json <<JSON
{
  "simplify": {"done_at": "$NOW", "staged_hash": "$H"},
  "review":   {"done_at": "$NOW", "staged_hash": "$H"},
  "tests":    {"verified_at": "$NOW", "staged_hash": "$H"}
}
JSON
gate_run commit
printf '%s' "$GATE_OUT" | grep -qiE 'jq: error|parse error|unbound variable|syntax error' \
  && fail "舊格式 state 造成錯誤輸出：$GATE_OUT" || pass "舊格式 state 不報錯"
{ gate_run commit; [ "$GATE_RC" = "0" ]; } && pass "舊格式 + hash 全相符 → 放行（行為與改動前相同）" || fail "舊格式被擋：$GATE_OUT"
# 舊格式 + simplify hash 過期 → 沒有 staged_tree 可算變動量，必須退回嚴格比對
add_lines app.py 3 B
{ gate_run commit; [ "$GATE_RC" != "0" ]; } && pass "舊格式且 simplify hash 過期 → 退回嚴格比對並擋下" || fail "舊格式被放寬了：$GATE_OUT"

echo ""
echo "=== F) simplify 之後的變動量超過上限 → 擋下並印出數字 ==="
new_repo drift
add_lines app.py 10 A
bash "$MARK" simplify >/dev/null
add_lines app.py 400 B                       # 遠超過絕對上限
bash "$MARK" review >/dev/null
bash "$MARK" verify-tests >/dev/null
{ gate_run commit; [ "$GATE_RC" != "0" ]; } && pass "gate 擋下" || fail "gate 放行了 400 行未經 simplify 的內容"
printf '%s' "$GATE_OUT" | grep -qE '[0-9]+ 行' && pass "訊息印出實際行數與上限" || fail "訊息沒有數字：$GATE_OUT"

echo ""
echo "=== G) simplify 章超過 24 小時 → 擋下 ==="
new_repo aged
add_lines app.py 10 A
bash "$MARK" simplify >/dev/null
add_lines app.py 5 B
bash "$MARK" review >/dev/null
bash "$MARK" verify-tests >/dev/null
OLD=$(date -u -r $(( $(date +%s) - 90000 )) +"%Y-%m-%dT%H:%M:%SZ")
jq --arg o "$OLD" '.simplify.done_at = $o | .simplify.first_marked_at = $o' \
  .claude/pipeline-state.json > .claude/s.tmp && mv .claude/s.tmp .claude/pipeline-state.json
{ gate_run commit; [ "$GATE_RC" != "0" ]; } && pass "超過 24 小時的 simplify 章不算數" || fail "過期的章被採信"

echo ""
echo "=== H) round 步驟後面沒有 content 步驟 → 退回嚴格比對 ==="
new_repo lonely
cat > steps.json <<'JSON'
{
  "gates": { "commit": ["simplify"] },
  "aliases": { "simplify": "simplify" },
  "help": { "simplify": "/simplify, then: {MARK} simplify" },
  "binding": { "simplify": "round" },
  "round_drift": { "floor_lines": 40, "ratio_percent": 30, "max_lines": 200 }
}
JSON
add_lines app.py 10 A
bash "$MARK" simplify >/dev/null
add_lines app.py 3 B
rc=$( ( . "$PLUGIN/scripts/pipeline-lib.sh"; PIPELINE_STEPS_JSON="$PWD/steps.json" pipeline_eval_gate commit test >/dev/null 2>&1 ); echo $? )
[ "$rc" != "0" ] && pass "沒有後續 content 步驟時不放寬" || fail "沒人看過最終內容卻放行"


echo ""
echo "=== J) round_drift 的排除路徑不計入變動量 ==="
new_repo docsonly
add_lines app.py 10 A
bash "$MARK" simplify >/dev/null
mkdir -p docs
add_lines docs/notes.md 300 D                # 遠超過上限，但在 exclude_paths 裡
add_lines TODOS.md 50 T                      # 帳本同樣不計（house rule 要求同 commit 更新）
bash "$MARK" review >/dev/null
bash "$MARK" verify-tests >/dev/null
{ gate_run commit; [ "$GATE_RC" = "0" ]; } && pass "exclude_paths 內的變動不計入" || fail "排除路徑被計入了：$(printf "%s" "$GATE_OUT" | head -6)"

# 反面：沒有列在 exclude_paths 裡的 .md 是產品內容，必須計入。第一版把 `*.md` 整批
# 排除，於是「簡化完再重寫 300 行 SKILL.md」drift 算出來是 0 —— 閘門對這個 repo
# 自己的主要檔案型態完全是盲的。
new_repo product-md
add_lines app.py 10 A
bash "$MARK" simplify >/dev/null
add_lines SKILL.md 300 S
bash "$MARK" review >/dev/null
bash "$MARK" verify-tests >/dev/null
gate_run commit
{ { gate_run commit; [ "$GATE_RC" != "0" ]; } && printf '%s' "$GATE_OUT" | grep -q "simplify"; } \
  && pass "沒被排除的 .md（產品內容）計入變動量並擋下" || fail "產品型 .md 沒被計入：$GATE_OUT"

echo ""
echo "=== K) 三個章同秒連打 → 放行（5 秒批次規則已移除）==="
new_repo batch
add_lines app.py 10 A
for s in simplify review verify-tests; do bash "$MARK" "$s" >/dev/null; done
SPREAD=$(jq -r '[.simplify.first_marked_at, .review.first_marked_at, .tests.first_marked_at] | unique | length' .claude/pipeline-state.json)
[ "$SPREAD" = "1" ] && pass "前置條件成立：三個章落在同一秒" || echo "  · 三個章不在同一秒（機器較慢），情境仍有效"
{ gate_run commit; [ "$GATE_RC" = "0" ]; } && pass "gate 放行" || fail "同秒連打仍被擋：$(printf "%s" "$GATE_OUT" | head -6)"

echo ""
echo "=== M) 以刪除為主的修正 → 只算新增側，放行 ==="
# 變動量刻意只算新增側：被刪掉的行是 simplify 看過、而且現在已經不存在的內容。
# 沒有這個情境的話，把度量改成「新增+刪除」整套測試仍然全綠 —— 而那會讓「review 之後
# 刪掉一大段」這種最該鼓勵的修正被擋下。
new_repo deletion
add_lines app.py 300 A
bash "$MARK" simplify >/dev/null
# 刪掉 250 行、只加 5 行：新增側 5（遠低於上限），加總側 255（會超過）
head -55 app.py > app.tmp && mv app.tmp app.py
add_lines app.py 5 B
bash "$MARK" review >/dev/null
bash "$MARK" verify-tests >/dev/null
# 先確認這個情境真的長成「新增側小、刪除側大」，否則它測不到要測的東西
SIM_TREE=$(jq -r '.simplify.staged_tree' .claude/pipeline-state.json)
DRIFT=$(git diff --cached --numstat "$SIM_TREE" -- app.py)
D_ADD=$(echo "$DRIFT" | awk '{print $1+0}'); D_DEL=$(echo "$DRIFT" | awk '{print $2+0}')
{ [ "$D_ADD" -lt 40 ] && [ "$D_DEL" -gt 200 ]; } \
  && pass "前置條件成立：simplify 之後新增 $D_ADD 行、刪除 $D_DEL 行" \
  || fail "前置條件不成立（新增 $D_ADD／刪除 $D_DEL），這個情境沒測到東西"
gate_run commit
[ "$GATE_RC" = "0" ] && pass "刪除為主的修正放行（加總側 $((D_ADD + D_DEL)) 行會超過上限）" \
  || fail "刪除被計入變動量：$(printf '%s' "$GATE_OUT" | head -6)"

echo ""
echo "=== L) staged_tree 指向不存在的物件（被 gc 清掉）→ 退回嚴格比對 ==="
new_repo gone-tree
add_lines app.py 10 A
bash "$MARK" simplify >/dev/null
add_lines app.py 5 B
bash "$MARK" review >/dev/null
bash "$MARK" verify-tests >/dev/null
{ gate_run commit; [ "$GATE_RC" = "0" ]; } && pass "前置條件成立：tree 還在時放行" || fail "前置條件不成立"
jq '.simplify.staged_tree = "0000000000000000000000000000000000000000"' \
  .claude/pipeline-state.json > .claude/s.tmp && mv .claude/s.tmp .claude/pipeline-state.json
{ gate_run commit; [ "$GATE_RC" != "0" ]; } && pass "算不出變動量 → 擋下（不 fail open）" || fail "tree 失蹤卻放行：$GATE_OUT"
printf '%s' "$GATE_OUT" | grep -qiE 'fatal|jq: error' && fail "有裸露的 git/jq 錯誤訊息：$GATE_OUT" || pass "沒有裸露的錯誤訊息"

echo ""
echo "=== N) 設定的邊界值不能讓閘門自己炸掉 ==="
# 這台機器的 /bin/bash 是 3.2，空陣列在 set -u 下展開就是 unbound variable；
# 而「把 exclude_paths 收成 []」是 README 教人調整清單時最自然的一步。
new_repo cfg-edge
add_lines app.py 10 A
bash "$MARK" simplify >/dev/null
add_lines app.py 5 B
bash "$MARK" review >/dev/null
bash "$MARK" verify-tests >/dev/null
for bad in '[]' '"docs/**"' '{}'; do
  jq --argjson v "$bad" '.round_drift.exclude_paths = $v' "$PLUGIN/pipeline-steps.json" > steps-edge.json
  out=$( ( . "$PLUGIN/scripts/pipeline-lib.sh"; PIPELINE_STEPS_JSON="$PWD/steps-edge.json" \
    pipeline_eval_gate commit test ) 2>&1 || true )
  printf '%s' "$out" | grep -q "unbound variable" \
    && { fail "exclude_paths=$bad 讓 lib 噴 unbound variable"; break; }
done
printf '%s' "$out" | grep -q "unbound variable" || pass "exclude_paths 是 []／字串／物件都不會炸"

for bad in '"30.5"' '"abc"' 'null'; do
  jq --argjson v "$bad" '.round_drift.ratio_percent = $v' "$PLUGIN/pipeline-steps.json" > steps-edge.json
  out=$( ( . "$PLUGIN/scripts/pipeline-lib.sh"; PIPELINE_STEPS_JSON="$PWD/steps-edge.json" \
    pipeline_eval_gate commit test ) 2>&1 || true )
  printf '%s' "$out" | grep -qE "syntax error|unbound variable|invalid arithmetic" \
    && { fail "ratio_percent=$bad 讓 lib 噴 bash 錯誤：$out"; break; }
done
printf '%s' "$out" | grep -qE "syntax error|unbound variable|invalid arithmetic" \
  || pass "round_drift 的值不是整數時退回預設，不噴 bash 錯誤"

echo ""
echo "=== O) index 有衝突時 staged_tree 必須被刪掉，不是沿用上一次的 ==="
# README 說「衝突時省略這個欄位，gate 退回嚴格比對」。實作若只是「不寫」，舊的 tree
# 會留在 marker 裡，於是 hash 是新的、tree 是舊的，drift 量到錯的基準。
new_repo conflict-tree
add_lines app.py 10 A
bash "$MARK" simplify >/dev/null
OLD_TREE=$(jq -r '.simplify.staged_tree' .claude/pipeline-state.json)
add_lines app.py 300 B
# 造一個真正未合併的 index（同一路徑三個 stage）
BLOB=$(git hash-object -w app.py)
git rm -q --cached app.py
printf '100644 %s 1\tapp.py\n100644 %s 2\tapp.py\n100644 %s 3\tapp.py\n' "$BLOB" "$BLOB" "$BLOB" \
  | git update-index --index-info
bash "$MARK" simplify >/dev/null 2>&1 || true
HAS_TREE=$(jq -r 'if (.simplify | has("staged_tree")) then "yes" else "no" end' .claude/pipeline-state.json)
NEW_TREE=$(jq -r '.simplify.staged_tree // ""' .claude/pipeline-state.json)
{ [ "$HAS_TREE" = "no" ] || [ "$NEW_TREE" != "$OLD_TREE" ]; } \
  && pass "write-tree 失敗時不會留下上一輪的 staged_tree" \
  || fail "staged_tree 還停在舊值 $OLD_TREE，但 staged_hash 已經換了"

echo ""
echo "=== Q) 純文件的 commit 免三個章 ==="

# Q1 — 全是 docs/*.md、零個章 → 放行並印說明
new_repo docsonly-pass
stage_files docs/guide.md docs/adr/0001-x.md
guard_run pretooluse
{ [ "$G_RC" = "0" ] && printf '%s' "$G_OUT" | grep -q "docs-only"; } \
  && pass "Q1 全 docs/*.md 無章 → 放行並印說明" || fail "Q1 被擋或沒印說明（rc=$G_RC）：$G_OUT"

# Q2 — 純文件混一個 .ts → 照常擋
new_repo docsonly-mixed
stage_files docs/guide.md src/app.ts
guard_run pretooluse
[ "$G_RC" != "0" ] && pass "Q2 混一個 .ts → 照常擋" || fail "Q2 有程式碼卻豁免了"

# Q3/Q4/Q9 — 文件形狀、但內容就是 agent 指令 → 擋，而且訊息要指名是哪個檔。
# 巢狀 .claude/ 那筆是 :(glob) 換掉雙寫樣式後才涵蓋到的：舊的 '.claude/**' 只命中
# 頂層，apps/x/.claude/skills/** 會整個漏掉。
for f in CLAUDE.md plugins/p/skills/x/SKILL.md skills/verify-feature/reference.md \
         apps/x/.claude/skills/d/SKILL.md docs/AGENTS.md; do
  new_repo "docsonly-instr-$(echo "$f" | tr '/.' '--')"
  stage_files "$f"
  guard_run pretooluse
  { [ "$G_RC" != "0" ] && printf '%s' "$G_OUT" | grep -qF "$f"; } \
    && pass "Q3/4/9 指令類 $f → 擋且訊息指名" || fail "Q3/4/9 $f 沒擋或沒指名（rc=$G_RC）：$G_OUT"
done

# Q5 — 舊 JSON 沒有 docs_only 鍵 → 不豁免、不報錯
new_repo docsonly-legacyjson
stage_files docs/guide.md
jq 'del(.docs_only)' "$PLUGIN/pipeline-steps.json" > steps-nodocs.json
out=$( ( . "$PLUGIN/scripts/pipeline-lib.sh"; PIPELINE_STEPS_JSON="$PWD/steps-nodocs.json" \
  pipeline_docs_only_exempt commit test ) 2>&1 ) && rc=0 || rc=$?
{ [ "$rc" != "0" ] && ! printf '%s' "$out" | grep -qiE 'jq: error|unbound|syntax error'; } \
  && pass "Q5 舊 JSON 無 docs_only → 不豁免且不報錯" || fail "Q5 rc=$rc out=$out"

# Q6 — 端到端：真實 git commit 一正一反
new_repo docsonly-e2e-pass
bash "$PLUGIN/scripts/install-git-hook.sh" >/dev/null 2>&1
stage_files docs/guide.md
if git commit -qm "docs: 只改文件" 2>/dev/null; then pass "Q6a 純文件的真實 commit 通過" ; else fail "Q6a 純文件的真實 commit 被擋"; fi
new_repo docsonly-e2e-block
bash "$PLUGIN/scripts/install-git-hook.sh" >/dev/null 2>&1
stage_files docs/guide.md src/app.ts
if git commit -qm "feat: 混程式碼" 2>/dev/null; then fail "Q6b 含程式碼卻 commit 成功"; else pass "Q6b 含程式碼的真實 commit 被擋"; fi

# Q7 — 兩條路徑行為一致（同一份純文件 staged diff）
new_repo docsonly-layers
stage_files docs/guide.md
guard_run pretooluse; RC_PRE=$G_RC
guard_run gitnative;  RC_GIT=$G_RC
{ [ "$RC_PRE" = "0" ] && [ "$RC_GIT" = "0" ]; } \
  && pass "Q7 PreToolUse 與 git-native 兩條路徑都放行" || fail "Q7 兩條路徑不一致（pretooluse=$RC_PRE gitnative=$RC_GIT）"

# Q8/Q15 — 根本不是文件形狀 → 擋。舊的 ^docs/ regex 會把 docs/ 底下的所有東西當文件，
# 而 platform 的 docs/ 底下有 16 個 .ts、59 個 json（含驅動 evidence 規則的 config.yaml）；
# requirements.txt 則是「*.txt 進過初稿又拿掉」的理由。
for f in docs/tools/gen.ts docs/verification/config.yaml requirements.txt; do
  new_repo "docsonly-notdoc-$(echo "$f" | tr '/.' '--')"
  stage_files "$f"
  guard_run pretooluse
  [ "$G_RC" != "0" ] && pass "Q8/15 非文件 $f → 擋" || fail "Q8/15 $f 被當成文件豁免"
done

# Q10 — .md 配一張 .png → 放行（ADR 配圖是常態）
new_repo docsonly-asset
stage_files docs/adr/0002-y.md docs/adr/img.png
guard_run pretooluse
[ "$G_RC" = "0" ] && pass "Q10 md 配惰性素材 → 放行" || fail "Q10 配圖破壞了豁免：$G_OUT"

# Q11 — docs_only.gates 是活的資料：同一份 docs-only diff，把 commit 從 gates 拿掉就不再豁免。
#       沒有這一筆，lib 裡的 gate 比對刪掉測試也不會紅（「改資料就能改行為」變成空話）。
new_repo docsonly-gates
stage_files docs/guide.md
jq '.docs_only.gates = []' "$PLUGIN/pipeline-steps.json" > steps-nogates.json
rc=$( ( . "$PLUGIN/scripts/pipeline-lib.sh"; PIPELINE_STEPS_JSON="$PWD/steps-nogates.json" \
  pipeline_docs_only_exempt commit test >/dev/null 2>&1 ); echo $? )
[ "$rc" != "0" ] && pass "Q11 docs_only.gates 不含 commit → 不豁免（接線是活的）" \
  || fail "Q11 改了 gates 卻沒生效（rc=$rc）"

# Q12 — 今天的真實案例 (a)：~/.agents 只改 AGENTS.md / AGENTS-reference.md / CHANGELOG.md
#       AGENTS*.md 是 agent 規則本身，該審 → 擋
new_repo docsonly-agentsmd
stage_files AGENTS.md AGENTS-reference.md CHANGELOG.md
guard_run pretooluse
{ [ "$G_RC" != "0" ] && printf '%s' "$G_OUT" | grep -q "AGENTS"; } \
  && pass "Q12 只改 AGENTS*.md + CHANGELOG → 擋且指名 AGENTS" || fail "Q12 改 agent 規則卻免審：$G_OUT"

# Q13 — 今天的真實案例 (b)：platform 的純文件形狀 → 放行
new_repo docsonly-platform
stage_files TODOS.md docs/INDEX.md docs/design/plan.md \
  docs/design-system/tokens/README.md docs/design-system/tokens/assets/logo.svg
guard_run pretooluse
[ "$G_RC" = "0" ] && pass "Q13 platform 的純文件形狀（含 svg）→ 放行" || fail "Q13 被擋：$G_OUT"

# Q14 — 變動量的 exclude_paths 也不能把 docs/ 底下的程式碼當文件
new_repo docsonly-driftts
add_lines app.py 10 A
bash "$MARK" simplify >/dev/null
mkdir -p docs/tools
add_lines docs/tools/gen.ts 300 D
bash "$MARK" review >/dev/null
bash "$MARK" verify-tests >/dev/null
gate_run commit
[ "$GATE_RC" != "0" ] && pass "Q14 simplify 後改 300 行 docs/*.ts → 計入變動量並擋下" \
  || fail "Q14 docs/ 底下的程式碼沒計入變動量"

echo ""
echo "=== S) evidence 硬檢查真的有跑（之前整份測試從沒讓它做事）==="
# 整份 gate-scenarios 以前沒有任何情境寫過 .tests 的 evidence 欄位，於是
# pipeline_check_evidence 一律在 `[ -f state ] || return 0` 早退。結果是「豁免要短路
# evidence」這條最要緊的性質零覆蓋：把 evidence 搬到豁免之前、或把 evidence_gates
# 改成空陣列，破壞了測試都照樣全綠。
break_evidence() {   # 讓 .tests 指向一個不存在的證據檔
  jq '.tests.evidence_required = ["render"] | .tests.evidence = {"render": "docs/nope.png"}' \
    .claude/pipeline-state.json > .claude/s.tmp && mv .claude/s.tmp .claude/pipeline-state.json
}

# S1 — 純文件 + 壞掉的證據 + fix(docs) 訊息 → 仍然放行（豁免有短路 evidence）
new_repo evidence-exempt
add_lines app.py 5 A
for s in simplify review verify-tests; do bash "$MARK" "$s" >/dev/null; done
break_evidence
git reset -q HEAD app.py && git checkout -q -- app.py 2>/dev/null || true
stage_files docs/guide.md
out=$(echo '{"tool_input":{"command":"git commit -m \"fix(docs): 錯字\""}}' \
  | bash "$PLUGIN/hooks/pre-commit-guard.sh" 2>&1) && rc=0 || rc=$?
[ "$rc" = "0" ] && pass "S1 純文件豁免時 evidence 不會擋（fix(docs) 也不用補 regression）" \
  || fail "S1 豁免沒有短路 evidence（rc=$rc）：$out"

# S2 — 非純文件 + 章齊全 + 壞掉的證據 → commit 擋下（evidence 確實在跑）
new_repo evidence-commit
add_lines app.py 5 A
for s in simplify review verify-tests; do bash "$MARK" "$s" >/dev/null; done
break_evidence
guard_run pretooluse
{ [ "$G_RC" != "0" ] && printf '%s' "$G_OUT" | grep -q "evidence"; } \
  && pass "S2 commit gate 會跑 evidence 並擋下壞證據" || fail "S2 evidence 沒跑（rc=$G_RC）：$G_OUT"

# S3 — 同一份壞證據，evidence_gates 不列 commit → 放行。證明 evidence_gates 是活的資料：
#      原本靠 ship gate 走到「不跑 evidence」這條分支，/ship gate 移除後改用改資料的方式驗。
jq '.evidence_gates = []' "$PLUGIN/pipeline-steps.json" > steps-noevidence.json
rc=$( ( . "$PLUGIN/scripts/pipeline-lib.sh"; PIPELINE_STEPS_JSON="$PWD/steps-noevidence.json" \
  pipeline_enforce commit test >/dev/null 2>&1 ); echo $? )
[ "$rc" = "0" ] && pass "S3 evidence_gates 不含 commit → 不跑 evidence（接線是活的）" \
  || fail "S3 改了 evidence_gates 卻沒生效（rc=$rc）"

# S4 — 刪掉 exclude_paths 這個鍵 → 不得有硬編 fallback 頂替（上一輪那份 fallback
#      在 JSON 收窄後沒跟上，是「兩份清單各自漂移」的實例）
new_repo exclude-nokey
add_lines app.py 10 A
bash "$MARK" simplify >/dev/null
mkdir -p docs
add_lines docs/notes.md 300 D
bash "$MARK" review >/dev/null
bash "$MARK" verify-tests >/dev/null
jq 'del(.round_drift.exclude_paths)' "$PLUGIN/pipeline-steps.json" > steps-nokey.json
rc=$( ( . "$PLUGIN/scripts/pipeline-lib.sh"; PIPELINE_STEPS_JSON="$PWD/steps-nokey.json" \
  pipeline_eval_gate commit test >/dev/null 2>&1 ); echo $? )
[ "$rc" != "0" ] && pass "S4 沒有 exclude_paths 鍵 → 什麼都不排除（無硬編 fallback）" \
  || fail "S4 有東西頂替了缺少的設定"

# S5 — 空的 staged diff 不豁免（README 明講、但原本零覆蓋）
new_repo empty-staged
guard_run pretooluse
[ "$G_RC" != "0" ] && pass "S5 空的 staged diff 不豁免" || fail "S5 空 diff 被當成純文件放行"

# S6 — evidence_gates 壞掉時要往「多檢查」倒，不能靜默關閉 evidence
new_repo evidence-badcfg
add_lines app.py 5 A
for s in simplify review verify-tests; do bash "$MARK" "$s" >/dev/null; done
break_evidence
for bad in '{}' '"commit"' 'null'; do
  jq --argjson v "$bad" '.evidence_gates = $v' "$PLUGIN/pipeline-steps.json" > steps-badev.json
  rc=$( ( . "$PLUGIN/scripts/pipeline-lib.sh"; PIPELINE_STEPS_JSON="$PWD/steps-badev.json" \
    pipeline_enforce commit test >/dev/null 2>&1 ); echo $? )
  [ "$rc" = "0" ] && { fail "S6 evidence_gates=$bad 讓 evidence 靜默不跑"; break; }
done
[ "$rc" != "0" ] && pass "S6 evidence_gates 型別壞掉時仍會跑 evidence（fail-closed）"

echo ""
echo "=== T) 豁免的 fail-open 面（對抗式審查抓到的四個 P0）==="

# T1 — git commit -a：PreToolUse 在 git 之前評估，只看得到 index；-a 會把 worktree
#      的改動在 commit 當下併進去。docs-only 的 index + `git commit -am` 曾經讓帶著
#      程式碼的 commit 整個免審（改動前是擋的，所以這是新開的洞）。
new_repo exempt-commit-a
stage_files docs/guide.md
echo "function BACKDOOR() {}" >> app.py     # 改了但沒 stage
out=$(echo '{"tool_input":{"command":"git commit -am \"docs: tweak\""}}' \
  | bash "$PLUGIN/hooks/pre-commit-guard.sh" 2>&1) && rc=0 || rc=$?
[ "$rc" != "0" ] && pass "T1 git commit -a 不吃豁免" || fail "T1 -a 讓未 stage 的程式碼免審"
for form in 'git commit --amend' 'git commit -i docs/guide.md' 'git commit -- docs/guide.md'; do
  out=$(echo "{\"tool_input\":{\"command\":\"$form\"}}" \
    | bash "$PLUGIN/hooks/pre-commit-guard.sh" 2>&1) && rc=0 || rc=$?
  [ "$rc" != "0" ] && pass "T1 $form 不吃豁免" || fail "T1 $form 讓 index 以外的內容免審"
done

# T2 — 舊版 git（不支援 :(exclude)/:(glob)）：所有 pathspec 都會被拒絕，而「沒有輸出」
#      若被讀成「沒有非文件檔」，純程式碼的 commit 會被判定成純文件並整個放行。
new_repo exempt-old-git
stage_files src/app.ts
mkdir -p fakebin
cat > fakebin/git <<'SHIM'
#!/bin/bash
for a in "$@"; do case "$a" in ':(exclude)'*|':(glob'*) echo "fatal: unsupported magic" >&2; exit 128 ;; esac; done
exec /usr/bin/git "$@"
SHIM
chmod +x fakebin/git
rc=$( ( export PATH="$PWD/fakebin:$PATH"; . "$PLUGIN/scripts/pipeline-lib.sh"; \
  pipeline_docs_only_exempt commit test >/dev/null 2>&1 ); echo $? )
[ "$rc" != "0" ] && pass "T2 git 不支援 pathspec magic → 不豁免（fail-closed）" \
  || fail "T2 舊版 git 讓純程式碼的 commit 被當成純文件"

# T3 — instruction_paths 裡有一個非字串：jq 的 @tsv 會中途 abort，若只看輸出不看
#      退出碼，指令清單會變成空的 → 只改 CLAUDE.md 也會被豁免。
new_repo exempt-badjson
stage_files CLAUDE.md
jq '.docs_only.instruction_paths = [{"oops":1}, ":(glob,icase)**/CLAUDE.md"]' \
  "$PLUGIN/pipeline-steps.json" > steps-badinstr.json
rc=$( ( . "$PLUGIN/scripts/pipeline-lib.sh"; PIPELINE_STEPS_JSON="$PWD/steps-badinstr.json" \
  pipeline_docs_only_exempt commit test >/dev/null 2>&1 ); echo $? )
[ "$rc" != "0" ] && pass "T3 設定裡有壞元素 → 不豁免（不採信半份清單）" \
  || fail "T3 jq 中途失敗讓指令清單變空"

# T4 — 大小寫：macOS 的 Claude.md 與 CLAUDE.md 是同一個檔，但 git pathspec 預設分大小寫
new_repo exempt-case
stage_files Claude.md
guard_run pretooluse
[ "$G_RC" != "0" ] && pass "T4 Claude.md（大小寫變體）仍算指令類" || fail "T4 改個大小寫就免審"

# T5 — 其他 agent 生態的指令目錄
for f in .cursor/rules/x.md prompts/system.md .github/instructions/y.md .github/prompts/z.prompt.md; do
  new_repo "exempt-eco-$(echo "$f" | tr '/.' '--')"
  stage_files "$f"
  guard_run pretooluse
  [ "$G_RC" != "0" ] && pass "T5 $f 算指令類" || fail "T5 $f 被當成文件免審"
done

echo ""
echo "=== R) 結構不變式：guard 不得自己組合判定順序 ==="
# 「豁免要同時短路 evidence」以前靠三支 guard 各自記得順序＋註解。改成單一入口之後，
# 這條測試讓「忘記」會變紅：hooks/ 底下不該再直接出現那兩個函式。
BAD=$(grep -l -E 'pipeline_eval_gate|pipeline_check_evidence' "$PLUGIN"/hooks/*.sh 2>/dev/null || true)
[ -z "$BAD" ] && pass "hooks/ 只透過 pipeline_enforce 執法" \
  || fail "這些 guard 繞過了單一入口：$(echo "$BAD" | tr '\n' ' ')"

echo ""
echo "=== U) 不存在的 gate／讀不到的設定 → 擋下（fail-closed）==="
# 章齊全、內容相符，只有 gate 名稱或設定檔是壞的。修正前：guard 的 set -u 之下 bash 3.2 會在空的
# required 陣列上以 exit 1 結束（PreToolUse 只認 exit 2，等於放行），沒開 set -u 則直接 return 0。
new_repo unknown-gate
add_lines app.py 5 A
for s in simplify review verify-tests; do bash "$MARK" "$s" >/dev/null; done
jq '.gates.commit = []' "$PLUGIN/pipeline-steps.json" > steps-emptygate.json
printf '{"gates": {"commit": ["simplify"' > steps-truncated.json
enforce_run() {   # $1 = shell 選項, $2 = gate, $3 = steps json（空＝外掛本身那份）
  U_OUT=$(PIPELINE_STEPS_JSON="${3:-$PLUGIN/pipeline-steps.json}" \
    bash -c "$1 . '$PLUGIN/scripts/pipeline-lib.sh'; pipeline_enforce '$2' test" 2>&1) && U_RC=0 || U_RC=$?
}
for opts in "" "set -euo pipefail;"; do
  tag="${opts:-無 set -u}"
  enforce_run "$opts" commit
  [ "$U_RC" = "0" ] && pass "U 前置條件：同一個入口走 commit 放行（$tag）" || fail "U 前置條件不成立（$tag）：$U_OUT"
  enforce_run "$opts" ship
  { [ "$U_RC" = "1" ] && printf '%s' "$U_OUT" | grep -q "unknown gate 'ship'"; } \
    && pass "U 未知 gate 擋下並指名（$tag）" || fail "U 未知 gate 沒被擋（$tag，rc=$U_RC）：$U_OUT"
  enforce_run "$opts" commit "$PWD/steps-emptygate.json"
  { [ "$U_RC" = "1" ] && printf '%s' "$U_OUT" | grep -q "unknown gate 'commit'"; } \
    && pass "U gates.commit 是空陣列 → 擋下（$tag）" || fail "U 空陣列沒被擋（$tag，rc=$U_RC）：$U_OUT"
  enforce_run "$opts" commit "$PWD/steps-truncated.json"
  { [ "$U_RC" = "1" ] && printf '%s' "$U_OUT" | grep -q "cannot read gate steps"; } \
    && pass "U 設定檔壞掉 → 擋下且說是讀不到設定、不是 gate 打錯（$tag）" \
    || fail "U 壞設定的處理不對（$tag，rc=$U_RC）：$U_OUT"
done
# 使用者看得到的症狀在 hook 層：PreToolUse 只有 exit 2 才擋。壞設定修正前是 exit 1（放行）。
out=$(echo '{"tool_input":{"command":"git commit -m \"feat: x\""}}' \
  | PIPELINE_STEPS_JSON="$PWD/steps-truncated.json" bash "$PLUGIN/hooks/pre-commit-guard.sh" 2>&1) && rc=0 || rc=$?
[ "$rc" = "2" ] && pass "U PreToolUse 拿到壞設定 → exit 2 擋下" || fail "U PreToolUse 沒擋（rc=$rc）：$out"

cd "$WORK" || exit 1
echo ""
if [ "$FAILED" -eq 0 ]; then
  echo "=== 全部情境通過 ✓ ==="
  rm -rf "$WORK"
  exit 0
else
  echo "=== 有 $FAILED 項失敗 ✗（工作目錄保留：$WORK）==="
  exit 1
fi
