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
echo "=== I) ship gate：document_release / tidy_docs 仍綁內容 ==="
new_repo ship
add_lines app.py 10 A
for s in simplify review verify-tests document-release tidy-docs; do bash "$MARK" "$s" >/dev/null; done
{ gate_run ship; [ "$GATE_RC" = "0" ]; } && pass "全部同內容 → ship 放行" || fail "ship 被擋：$(printf "%s" "$GATE_OUT" | head -5)"
add_lines app.py 3 B
for s in simplify review verify-tests; do bash "$MARK" "$s" >/dev/null; done
{ gate_run ship; [ "$GATE_RC" != "0" ]; } && pass "document_release 過期 → ship 擋下" || fail "尾端文件步驟被放寬了"
printf '%s' "$GATE_OUT" | grep -qE 'document.release' && pass "訊息指出 document-release" || fail "訊息沒提 document-release：$GATE_OUT"

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
