#!/usr/bin/env bash
# test-post-restart.sh — 全棧驗證腳本（在新 Claude session 重啟後跑）
#
# 用途：驗證 plugin 真的被 Claude Code 載入、hooks 真的會在 git commit / /ship 時觸發。
# 這個 script 模擬 hook 從各種 payload 接收的情境，**不靠 Claude harness**。
#
# 使用：bash ~/peter-claude-plugins/plugins/pre-commit-pipeline/test-post-restart.sh
set -euo pipefail

PLUGIN="$HOME/peter-claude-plugins/plugins/pre-commit-pipeline"
COMMIT_HOOK="$PLUGIN/hooks/pre-commit-guard.sh"
SHIP_HOOK="$PLUGIN/hooks/pre-ship-guard.sh"
SESSION_HOOK="$PLUGIN/hooks/session-pipeline-status.sh"
MARK="$PLUGIN/scripts/pipeline-mark-done.sh"

D="/tmp/pipeline-postrestart-$$"
mkdir -p "$D" && cd "$D"
git init -q
echo "v1" > app.py
git add app.py

pass() { echo "  ✓ $1"; }
fail() { echo "  ✗ $1"; exit 1; }

# 把已寫入的 marker 的 first_marked_at 往回撥成彼此相隔的時刻，模擬「各步驟是先後
# 跑完的」。測試腳本連續呼叫 mark-done 必然讓它們落在同一秒，而那正是批次打勾偵測
# 要擋的形狀 —— 不先撥開的話，任何「marker 齊全 → 放行」的正向案例都無法測。
spread_marks() {
  local base n=0 k
  base=$(date -u +%s)
  for k in $(jq -r 'keys[]' .claude/pipeline-state.json); do
    n=$((n + 1))
    jq --arg k "$k" --arg f "$(date -u -r $((base - n * 120)) +"%Y-%m-%dT%H:%M:%SZ")" \
      '.[$k].first_marked_at = $f' .claude/pipeline-state.json > .claude/s.tmp
    mv .claude/s.tmp .claude/pipeline-state.json
  done
}

echo "=== Test 1: WIP commit 放行 ==="
out=$(echo '{"tool_input":{"command":"git commit -m \"WIP: dev\""}}' | bash "$COMMIT_HOOK" 2>&1 ; echo "rc=$?")
[[ "$out" == *"pipeline skipped"* && "$out" == *"rc=0"* ]] && pass "WIP allowed" || fail "WIP not allowed: $out"

echo ""
echo "=== Test 2: 無 marker 被擋（commit） ==="
rc=$(echo '{"tool_input":{"command":"git commit -m \"feat: x\""}}' | bash "$COMMIT_HOOK" 2>/dev/null ; echo "$?")
[ "$rc" = "2" ] && pass "no marker blocks" || fail "expected exit 2, got $rc"

echo ""
echo "=== Test 3: 3 marker 同秒連打 → 被批次打勾偵測擋下 ==="
# 這個 case 原本期望 exit 0（「marker 齊全就放行」），但 2026-06-26 加入批次打勾
# 偵測之後，同秒連打正是它要擋的東西 —— 防護加了、測試沒跟著更新，於是這支手動
# 腳本從那時起就一直是紅的，沒人跑也就沒人發現。期望值改成反映實際（且正確的）
# 行為；「marker 齊全 → 放行」的正向路徑由下面的 Test 8 覆蓋。
bash "$MARK" simplify > /dev/null
bash "$MARK" review > /dev/null
bash "$MARK" verify-tests > /dev/null
rc=$(echo '{"tool_input":{"command":"git commit -m \"feat: x\""}}' | bash "$COMMIT_HOOK" 2>/dev/null ; echo "$?")
[ "$rc" = "2" ] && pass "same-second triple tick blocked" || fail "expected exit 2, got $rc"

echo ""
echo "=== Test 4: staged diff 改變 marker 失效 ==="
echo "v2" >> app.py
git add app.py
rc=$(echo '{"tool_input":{"command":"git commit -m \"feat: x\""}}' | bash "$COMMIT_HOOK" 2>/dev/null ; echo "$?")
[ "$rc" = "2" ] && pass "stale hash invalidates" || fail "expected exit 2, got $rc"

echo ""
echo "=== Test 5: /ship 需 4 markers ==="
bash "$MARK" simplify > /dev/null
bash "$MARK" review > /dev/null
bash "$MARK" verify-tests > /dev/null
# 故意不寫 document-release
rc=$(echo '{"tool_input":{"command":"/ship"}}' | bash "$SHIP_HOOK" 2>/dev/null ; echo "$?")
[ "$rc" = "2" ] && pass "missing doc-release blocks ship" || fail "expected exit 2, got $rc"

# ship gate 要的是 pipeline-steps.json 的 gates.ship —— 現在是 5 步（多了 tidy_docs）。
# 這裡原本只補到 document-release 就期望放行，是設定加了步驟、測試沒跟上。
bash "$MARK" document-release > /dev/null
bash "$MARK" tidy-docs > /dev/null
spread_marks
rc=$(echo '{"tool_input":{"command":"/ship"}}' | bash "$SHIP_HOOK" 2>/dev/null ; echo "$?")
[ "$rc" = "0" ] && pass "all ship markers pass ship hook" || fail "expected exit 0, got $rc"

echo ""
echo "=== Test 6: ship 內部 commit 過 bash hook ==="
# /ship 內部會跑 git commit，bash hook 只看 3 marker 仍 OK
rc=$(echo '{"tool_input":{"command":"git commit -m \"chore: bump version\""}}' | bash "$COMMIT_HOOK" 2>/dev/null ; echo "$?")
[ "$rc" = "0" ] && pass "ship-internal commit passes" || fail "expected exit 0, got $rc"

echo ""
echo "=== Test 7a: SessionStart 在 dirty repo + 新 marker 靜默 ==="
out=$(bash "$SESSION_HOOK" 2>&1)
# 剛跑完 Test 5/6 寫進 marker，AGE < 24h，dirty 但靜默
[ -z "$out" ] && pass "fresh markers → silent" || fail "expected silent, got: $out"

echo ""
echo "=== Test 7b: SessionStart 在 dirty repo + 無 marker 印提示 ==="
# 清掉 marker 模擬「沒跑過 pipeline」狀態
rm -f .claude/pipeline-state.json
out=$(bash "$SESSION_HOOK" 2>&1)
[[ "$out" == *"pipeline markers"* || "$out" == *"will require"* ]] && pass "no marker → prints hint" || fail "expected hint, got: $out"

echo ""
echo "=== Test 7c: SessionStart 在 clean repo 靜默 ==="
git add -A
git commit -q -m "feat: initial"  # commit all (incl .gitignore)
out=$(bash "$SESSION_HOOK" 2>&1)
[ -z "$out" ] && pass "clean repo → silent" || fail "expected silent, got: $out"

echo ""
echo "=== Test 8-11: first_marked_at（重打 vs 批次打勾）==="
# 這四個情境無法靠實際等待製造（batch window 只有 5 秒，且要模擬跨輪與竄改），
# 所以直接構造 state.json —— 測的是 gate 的判讀，不是 mark-done 的寫入路徑。
echo "v2" > app.py && git add app.py
HASH=$(bash "$PLUGIN/scripts/compute-staged-hash.sh")
HEAD_SHA=$(git rev-parse HEAD)
NOW_E=$(date -u +%s)
iso() { date -u -r "$1" +"%Y-%m-%dT%H:%M:%SZ"; }

# $1=first_marked_head  $2=first_marked_at 相對現在的偏移基數（負=過去，正=未來）
mkstate() {
  local head="$1" sign="$2"
  cat > .claude/pipeline-state.json <<JSON
{
  "simplify": {"done_at":"$(iso "$NOW_E")","first_marked_at":"$(iso $((NOW_E + sign * 600)))","first_marked_head":"$head","staged_hash":"$HASH"},
  "review":   {"done_at":"$(iso "$NOW_E")","first_marked_at":"$(iso $((NOW_E + sign * 300)))","first_marked_head":"$head","staged_hash":"$HASH"},
  "tests":    {"done_at":"$(iso "$NOW_E")","first_marked_at":"$(iso $((NOW_E + sign * 60)))","first_marked_head":"$head","staged_hash":"$HASH"}
}
JSON
}
# `|| true` 是必要的：擋下時 hook 回非 0，而腳本開頭的 set -e 會讓 out=$(...) 的
# 賦值直接終止整個測試 —— 沒有任何訊息，看起來就像測試跑完了。
gate_out() { echo '{"tool_input":{"command":"git commit -m \"feat: x\""}}' | bash "$COMMIT_HOOK" 2>&1 || true; }

# 8 — 真實流程：三步先後跑完（first 分散），之後 diff 又動過所以三個一起重打
#     （done_at 全部同秒）。舊邏輯會把這判成造假，這正是要修的誤擋。
mkstate "$HEAD_SHA" -1
out=$(gate_out)
[[ "$out" != *"BLOCKED"* ]] && pass "同輪重打 → 放行" || fail "同輪重打被誤擋: $out"

# 9 — 跨輪重用：時間戳來自一個已經 commit 收尾的輪次（HEAD 對不上）。
#     若採信就等於「上一輪的努力替這一輪背書」，比修之前更鬆。
mkstate "0000000000000000000000000000000000000000" -1
out=$(gate_out)
[[ "$out" == *"BLOCKED"* ]] && pass "跨輪時間戳 → 擋下" || fail "跨輪重用被放行: $out"

# 10 — 未來時間戳：手改的話永遠不會過期，等於永久後門。
mkstate "$HEAD_SHA" 1
out=$(gate_out)
[[ "$out" == *"BLOCKED"* ]] && pass "未來時間戳 → 擋下" || fail "未來時間戳被採信: $out"

# 11 — 只有 staged_hash、沒有任何時間戳：既非 missing 也非 stale，
#      且不貢獻時間點給批次檢查，曾能整個通過（fail-open）。
cat > .claude/pipeline-state.json <<JSON
{
  "simplify": {"staged_hash":"$HASH"},
  "review":   {"staged_hash":"$HASH"},
  "tests":    {"staged_hash":"$HASH"}
}
JSON
out=$(gate_out)
[[ "$out" == *"BLOCKED"* ]] && pass "無時間戳的 marker → 擋下" || fail "無時間戳 marker 通過了 gate: $out"

echo ""
echo "=== Test 12-19: 非-husky repo 的 git hook installer ==="
# 這幾個要各自獨立的 repo（安裝狀態不同），所以不用上面那個共用工作區。
INS="$PLUGIN/scripts/install-git-hook.sh"
ID="/tmp/pipeline-installer-$$"
mkrepo() { mkdir -p "$ID/$1" && cd "$ID/$1" && git init -q . && git config user.email t@t && git config user.name t; }

# 12 — 全新 repo：安裝 → 重複安裝要 idempotent → 真的擋得住未跑 pipeline 的 commit
mkrepo plain && mkdir -p .claude && echo x > a.txt && git add a.txt
bash "$INS" >/dev/null
[ -x .git/hooks/pre-commit ] && pass "installer 裝上 pre-commit hook" || fail "hook 沒被建立"
out=$(bash "$INS" 2>&1 || true)
[[ "$out" == *"已經安裝過"* ]] && pass "重複安裝 idempotent" || fail "重複安裝行為不符: $out"
git commit -q -m "feat: x" 2>/dev/null && fail "未跑 pipeline 卻 commit 成功" || pass "git 層擋下未跑 pipeline 的 commit"
PIPELINE_SKIP=1 git commit -q -m "feat: x" 2>/dev/null && pass "PIPELINE_SKIP=1 放行" || fail "PIPELINE_SKIP 沒放行"

# 13 — uninstall 收得乾淨
bash "$INS" --uninstall >/dev/null
[ -f .git/hooks/pre-commit ] && fail "uninstall 後 hook 還在" || pass "uninstall 移除乾淨"

# 14 — 既有 hook 絕不覆蓋（靜默蓋掉別人的 hook 比不裝還糟）
mkrepo existing && mkdir -p .claude .git/hooks
printf '#!/bin/sh\necho "someone elses hook"\n' > .git/hooks/pre-commit && chmod +x .git/hooks/pre-commit
rc=0; err=$(bash "$INS" 2>&1 >/dev/null) || rc=$?
grep -q "someone elses hook" .git/hooks/pre-commit && pass "既有 hook 內容未被動過" || fail "既有 hook 被覆蓋了"
[ "$rc" != "0" ] && pass "偵測到既有 hook 時以非 0 退出" || fail "應該以非 0 退出"
[[ "$err" == *"要納管的話"* ]] && pass "印出手動合併指引" || fail "沒有指引: $err"

# 15 — husky repo 且有 user hook：已被 ~/.config/husky/init.sh 涵蓋，裝了會跑兩遍
mkrepo husky && mkdir -p .claude .husky && touch .husky/pre-commit
out=$(bash "$INS" 2>&1 || true)
[[ "$out" == *"已由"* ]] && pass "husky repo（有 user hook）正確跳過" || fail "husky repo 沒跳過: $out"
[ -f .git/hooks/pre-commit ] && fail "husky repo 不該被裝 hook" || pass "husky repo 未安裝 hook"

# 16 — 有 .husky/ 但沒有 user hook：husky loader 在該 hook 沒有 user 檔時會提前
#      結束、根本不 source 全域 init，所以這種 repo 其實沒被涵蓋，必須安裝。
#      只看目錄存在會誤判成「已涵蓋」而讓它裸奔。
mkrepo husky_empty && mkdir -p .claude .husky
out=$(bash "$INS" 2>&1 || true)
{ [[ "$out" == *"仍需安裝"* ]] && [ -x .git/hooks/pre-commit ]; } \
  && pass "有 .husky/ 但無 user hook → 判定未涵蓋並安裝" || fail "誤判為已涵蓋: $out"

# 17 — core.hooksPath：git 只從那裡讀 hook，寫到 .git/hooks 等於白裝
mkrepo hookspath && mkdir -p .claude myhooks && git config core.hooksPath myhooks
bash "$INS" >/dev/null 2>&1
[ -x myhooks/pre-commit ] && pass "安裝到 core.hooksPath 指定的目錄" || fail "沒裝進 hooksPath"
[ -f .git/hooks/pre-commit ] && fail "誤裝進 .git/hooks" || pass "未誤裝進 .git/hooks"
echo x > a.txt && git add a.txt
git commit -q -m "feat: x" 2>/dev/null && fail "hooksPath 情境下沒擋住" || pass "hooksPath 情境下端到端擋住"

# 18 — 標記碰撞：他人的 hook 剛好含有本工具的標記字串。靠標記判斷所有權會
#      (a) install 誤報已安裝而實際沒有 guard、(b) uninstall 刪掉別人的檔案。
mkrepo collide && mkdir -p .claude .git/hooks
printf '#!/bin/sh\n# pre-commit-pipeline gate\necho "actually someone elses"\n' > .git/hooks/pre-commit
chmod +x .git/hooks/pre-commit
out=$(bash "$INS" 2>&1 >/dev/null || true)
[[ "$out" == *"不是本工具寫的內容"* ]] && pass "標記碰撞時 install 仍拒絕" || fail "install 誤判: $out"
out=$(bash "$INS" --uninstall 2>&1 >/dev/null || true)
grep -q "actually someone elses" .git/hooks/pre-commit \
  && pass "標記碰撞時 uninstall 不刪他人 hook" || fail "他人 hook 被刪除"

# 19 — guard 失蹤時必須 fail closed。一個靜默消失的 gate 比會抱怨的危險得多。
mkrepo failclosed && mkdir -p .claude && bash "$INS" >/dev/null 2>&1
grep -q '\$HOME' .git/hooks/pre-commit && fail "stub 內留了 \$HOME（換 HOME 就找不到 guard）" \
  || pass "stub 內寫死絕對路徑"
sed -i '' 's#^_g=.*#_g="/nonexistent/guard.sh"#' .git/hooks/pre-commit
echo x > a.txt && git add a.txt
git commit -q -m "feat: x" 2>/dev/null && fail "guard 缺失卻放行（fail open）" || pass "guard 缺失時擋下（fail closed）"

cd "$D"

echo ""
echo "=== All Phase 2 tests passed ✓ ==="
echo "Plugin location: $PLUGIN"
echo "Test workspace: $D (you can /opt/homebrew/opt/trash/bin/trash it now)"
