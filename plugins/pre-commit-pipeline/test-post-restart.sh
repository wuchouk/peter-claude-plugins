#!/usr/bin/env bash
# test-post-restart.sh — 全棧驗證腳本（在新 Claude session 重啟後跑）
#
# 用途：驗證 plugin 真的被 Claude Code 載入、hooks 真的會在 git commit 時觸發。
# 這個 script 模擬 hook 從各種 payload 接收的情境，**不靠 Claude harness**。
#
# 使用：bash ~/peter-claude-plugins/plugins/pre-commit-pipeline/test-post-restart.sh
set -euo pipefail

# 外掛位置由腳本自身推導，所以在 worktree 裡跑測到的是你正在改的那份，而不是主
# checkout 的舊版（先前寫死 $HOME 路徑，在 worktree 改完跑這支會看到假的綠燈）。
PLUGIN="${PIPELINE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
COMMIT_HOOK="$PLUGIN/hooks/pre-commit-guard.sh"
SESSION_HOOK="$PLUGIN/hooks/session-pipeline-status.sh"
MARK="$PLUGIN/scripts/pipeline-mark-done.sh"

D="/tmp/pipeline-postrestart-$$"
# .claude/ 是納管的 opt-in 條件（pre-commit-guard.sh 與 git-commit-msg-guard.sh 檢查它）。
# 少了它整個工作區不受 commit gate 管，前兩個 case 會拿到
# exit 0 而不是預期的擋下 —— 這支腳本從 opt-in 條件加入後就一直在 Test 2 紅著，
# 沒人跑也就沒人發現（和 Test 3/5 是同一類漏更新）。
mkdir -p "$D/.claude" && cd "$D"
git init -q
echo "v1" > app.py
git add app.py

pass() { echo "  ✓ $1"; }
fail() { echo "  ✗ $1"; exit 1; }

echo "=== Test 1: WIP commit 放行 ==="
out=$(echo '{"tool_input":{"command":"git commit -m \"WIP: dev\""}}' | bash "$COMMIT_HOOK" 2>&1 ; echo "rc=$?")
[[ "$out" == *"pipeline skipped"* && "$out" == *"rc=0"* ]] && pass "WIP allowed" || fail "WIP not allowed: $out"

echo ""
echo "=== Test 2: 無 marker 被擋（commit） ==="
rc=$(echo '{"tool_input":{"command":"git commit -m \"feat: x\""}}' | bash "$COMMIT_HOOK" 2>/dev/null ; echo "$?")
[ "$rc" = "2" ] && pass "no marker blocks" || fail "expected exit 2, got $rc"

echo ""
echo "=== Test 3: 3 marker 齊全 → 放行 ==="
# 同秒連打是「工作做完後把章補齊」的正常形狀，不再視為造假（README 有專節）。
bash "$MARK" simplify > /dev/null
bash "$MARK" review > /dev/null
bash "$MARK" verify-tests > /dev/null
rc=$(echo '{"tool_input":{"command":"git commit -m \"feat: x\""}}' | bash "$COMMIT_HOOK" 2>/dev/null ; echo "$?")
[ "$rc" = "0" ] && pass "complete markers pass" || fail "expected exit 0, got $rc"

echo ""
echo "=== Test 4: staged diff 改變 marker 失效 ==="
echo "v2" >> app.py
git add app.py
rc=$(echo '{"tool_input":{"command":"git commit -m \"feat: x\""}}' | bash "$COMMIT_HOOK" 2>/dev/null ; echo "$?")
[ "$rc" = "2" ] && pass "stale hash invalidates" || fail "expected exit 2, got $rc"

echo ""
echo "=== Test 5: 對新內容重蓋 3 marker → 放行 ==="
# Test 4 讓章過期；對目前內容重蓋後要能再次放行。
# （原本的 Test 5/6 測 /ship gate，2026-09-23 隨 pre-ship-guard.sh 一起移除。）
bash "$MARK" simplify > /dev/null
bash "$MARK" review > /dev/null
bash "$MARK" verify-tests > /dev/null
rc=$(echo '{"tool_input":{"command":"git commit -m \"chore: bump version\""}}' | bash "$COMMIT_HOOK" 2>/dev/null ; echo "$?")
[ "$rc" = "0" ] && pass "re-marked commit passes" || fail "expected exit 0, got $rc"

echo ""
echo "=== Test 7a: SessionStart 在 dirty repo + 新 marker 靜默 ==="
out=$(bash "$SESSION_HOOK" 2>&1)
# 剛跑完 Test 5 寫進 marker，AGE < 24h，dirty 但靜默
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
echo "=== Test 8-9: marker 判讀（PreToolUse 層）==="
# 直接構造 state.json —— 測的是 gate 的判讀，不是 mark-done 的寫入路徑。
echo "v2" > app.py && git add app.py
HASH=$(bash "$PLUGIN/scripts/compute-staged-hash.sh")
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
# 一次呼叫同時取得輸出與 rc，兩者都要驗：
#  - rc 不能漏。只比對輸出字串會放過「以非 0 退出、訊息裡卻沒有 BLOCKED」的回歸
#    （實例：plugin 檔案缺失時 guard 以 rc=5 帶著 jq 錯誤退出，commit 其實被擋）。
#  - `&& GATE_RC=0 || GATE_RC=$?` 是必要的。直接寫 GATE_OUT=$(...) 的話，腳本開頭的
#    set -e 會在 hook 擋下時終止整個測試 —— 沒有任何訊息，看起來就像測試跑完了。
gate_run() {
  GATE_OUT=$(echo '{"tool_input":{"command":"git commit -m \"feat: x\""}}' | bash "$COMMIT_HOOK" 2>&1) && GATE_RC=0 || GATE_RC=$?
}

# 8 — 三個章的 hash 都對得上目前 staged 內容 → 放行。只有 done_at + staged_hash，
#     沒有 first_marked_*：gate 不再讀時間戳以外的欄位，這就是判定需要的全部。
cat > .claude/pipeline-state.json <<JSON
{
  "simplify": {"done_at":"$NOW","staged_hash":"$HASH"},
  "review":   {"done_at":"$NOW","staged_hash":"$HASH"},
  "tests":    {"done_at":"$NOW","staged_hash":"$HASH"}
}
JSON
gate_run
{ [ "$GATE_RC" = "0" ] && [[ "$GATE_OUT" != *"BLOCKED"* ]]; } \
  && pass "hash 全相符 → 放行" || fail "hash 全相符卻被擋（rc=$GATE_RC）: $GATE_OUT"

# 9 — 只有 staged_hash、沒有任何時間戳：既非 missing 也非 stale，曾能整個通過
#      （fail-open）—— 手寫一份 state 就能清空整條 pipeline。
cat > .claude/pipeline-state.json <<JSON
{
  "simplify": {"staged_hash":"$HASH"},
  "review":   {"staged_hash":"$HASH"},
  "tests":    {"staged_hash":"$HASH"}
}
JSON
gate_run
# 也驗擋下的「理由」：只比對 BLOCKED 的話，之後 hash 邏輯一變它會因為錯的原因繼續綠。
{ [ "$GATE_RC" = "2" ] && [[ "$GATE_OUT" == *"Missing markers"* ]]; } \
  && pass "無時間戳的 marker → 以 missing 擋下" || fail "無時間戳 marker 沒被當成 missing 擋下: $GATE_OUT"

echo ""
echo "=== Test 10: pipeline-mark-done.sh 的寫入路徑 ==="
# 這四項之前零覆蓋：Test 3/5 雖然呼叫 mark-done，但斷言只看 guard 的 exit code，
# 從沒讀過寫出來的 state 檔，所以把 merge 改成直接覆寫、或整個不寫欄位，測試都全綠。
MD="$D/markdone"
mkdir -p "$MD/.claude" && cd "$MD" && git init -q . \
  && git config user.email t@t && git config user.name t
echo one > f.txt && git add f.txt && PIPELINE_SKIP=1 git commit -q -m "init" --no-verify
echo two >> f.txt && git add f.txt
bash "$MARK" simplify > /dev/null
FIRST_1=$(jq -r '.simplify.first_marked_at' .claude/pipeline-state.json)
echo three >> f.txt && git add f.txt
bash "$MARK" simplify > /dev/null
[ "$(jq -r '.simplify.first_marked_at' .claude/pipeline-state.json)" = "$FIRST_1" ] \
  && pass "同輪重蓋 → first_marked_at 沿用" || fail "同輪重蓋卻重設了 first_marked_at"

# 換輪：commit 推進 HEAD，沿用的時間戳必須失效（用一個遠古值才看得出差別）
jq '.simplify.first_marked_at = "2020-01-01T00:00:00Z"' .claude/pipeline-state.json > .claude/s.tmp \
  && mv .claude/s.tmp .claude/pipeline-state.json
PIPELINE_SKIP=1 git commit -q -m "WIP: 上一輪" --no-verify
echo four >> f.txt && git add f.txt
bash "$MARK" simplify > /dev/null
{ [ "$(jq -r '.simplify.first_marked_at' .claude/pipeline-state.json)" != "2020-01-01T00:00:00Z" ] \
  && [ "$(jq -r '.simplify.first_marked_head' .claude/pipeline-state.json)" = "$(git rev-parse HEAD)" ]; } \
  && pass "換輪（HEAD 變）→ first_marked_at 重設、head 跟上" || fail "跨輪的時間戳被沿用了"

# .tests 的既有 payload 不能被蓋掉：evidence_required 消失會讓證據硬檢查靜默放行
jq '.tests = {"done_at":"2020-01-01T00:00:00Z","staged_hash":"x","decisions":[{"k":"v"}],"evidence_required":["render"],"evidence":{"render":"a.png"}}' \
  .claude/pipeline-state.json > .claude/s.tmp && mv .claude/s.tmp .claude/pipeline-state.json
bash "$MARK" verify-tests > /dev/null
[ "$(jq -c '[.tests.decisions, .tests.evidence_required, .tests.evidence]' .claude/pipeline-state.json)" \
  = '[[{"k":"v"}],["render"],{"render":"a.png"}]' ] \
  && pass "重蓋 tests 保留 decisions/evidence 等既有欄位" || fail "既有 payload 被覆寫了"

# 0 byte 的 state 檔：jq 讀空輸入會輸出空字串，寫回去等於清空檔案，而腳本照樣印 ✓
: > .claude/pipeline-state.json
bash "$MARK" review > /dev/null 2>&1 || true
jq -e '.review.staged_hash | length > 10' .claude/pipeline-state.json >/dev/null 2>&1 \
  && pass "空的 state 檔 → 寫出合法 marker（不靜默清空）" || fail "空 state 檔後 marker 沒寫進去"
cd "$D"

echo ""
echo "=== Test 11-18: 非-husky repo 的 git hook installer ==="
# 這幾個要各自獨立的 repo（安裝狀態不同），所以不用上面那個共用工作區。
INS="$PLUGIN/scripts/install-git-hook.sh"
ID="/tmp/pipeline-installer-$$"
mkrepo() { mkdir -p "$ID/$1" && cd "$ID/$1" && git init -q . && git config user.email t@t && git config user.name t; }

# 11 — 全新 repo：安裝 → 重複安裝要 idempotent → 真的擋得住未跑 pipeline 的 commit
mkrepo plain && mkdir -p .claude && echo x > a.txt && git add a.txt
bash "$INS" >/dev/null
[ -x .git/hooks/pre-commit ] && pass "installer 裝上 pre-commit hook" || fail "hook 沒被建立"
out=$(bash "$INS" 2>&1 || true)
[[ "$out" == *"已經安裝過"* ]] && pass "重複安裝 idempotent" || fail "重複安裝行為不符: $out"
git commit -q -m "feat: x" 2>/dev/null && fail "未跑 pipeline 卻 commit 成功" || pass "git 層擋下未跑 pipeline 的 commit"
PIPELINE_SKIP=1 git commit -q -m "feat: x" 2>/dev/null && pass "PIPELINE_SKIP=1 放行" || fail "PIPELINE_SKIP 沒放行"

# 12 — uninstall 收得乾淨
bash "$INS" --uninstall >/dev/null
[ -f .git/hooks/pre-commit ] && fail "uninstall 後 hook 還在" || pass "uninstall 移除乾淨"

# 13 — 既有 hook 絕不覆蓋（靜默蓋掉別人的 hook 比不裝還糟）
mkrepo existing && mkdir -p .claude .git/hooks
printf '#!/bin/sh\necho "someone elses hook"\n' > .git/hooks/pre-commit && chmod +x .git/hooks/pre-commit
rc=0; err=$(bash "$INS" 2>&1 >/dev/null) || rc=$?
grep -q "someone elses hook" .git/hooks/pre-commit && pass "既有 hook 內容未被動過" || fail "既有 hook 被覆蓋了"
[ "$rc" != "0" ] && pass "偵測到既有 hook 時以非 0 退出" || fail "應該以非 0 退出"
[[ "$err" == *"要納管的話"* ]] && pass "印出手動合併指引" || fail "沒有指引: $err"

# 14 — husky repo 且有 user hook：已被 ~/.config/husky/init.sh 涵蓋，裝了會跑兩遍
mkrepo husky && mkdir -p .claude .husky && touch .husky/pre-commit
out=$(bash "$INS" 2>&1 || true)
[[ "$out" == *"已由"* ]] && pass "husky repo（有 user hook）正確跳過" || fail "husky repo 沒跳過: $out"
[ -f .git/hooks/pre-commit ] && fail "husky repo 不該被裝 hook" || pass "husky repo 未安裝 hook"

# 15 — 有 .husky/ 但沒有 user hook：husky loader 在該 hook 沒有 user 檔時會提前
#      結束、根本不 source 全域 init，所以這種 repo 其實沒被涵蓋，必須安裝。
#      只看目錄存在會誤判成「已涵蓋」而讓它裸奔。
mkrepo husky_empty && mkdir -p .claude .husky
out=$(bash "$INS" 2>&1 || true)
{ [[ "$out" == *"仍需安裝"* ]] && [ -x .git/hooks/pre-commit ]; } \
  && pass "有 .husky/ 但無 user hook → 判定未涵蓋並安裝" || fail "誤判為已涵蓋: $out"

# 16 — core.hooksPath：git 只從那裡讀 hook，寫到 .git/hooks 等於白裝
mkrepo hookspath && mkdir -p .claude myhooks && git config core.hooksPath myhooks
bash "$INS" >/dev/null 2>&1
[ -x myhooks/pre-commit ] && pass "安裝到 core.hooksPath 指定的目錄" || fail "沒裝進 hooksPath"
[ -f .git/hooks/pre-commit ] && fail "誤裝進 .git/hooks" || pass "未誤裝進 .git/hooks"
echo x > a.txt && git add a.txt
git commit -q -m "feat: x" 2>/dev/null && fail "hooksPath 情境下沒擋住" || pass "hooksPath 情境下端到端擋住"

# 17 — 標記碰撞：他人的 hook 剛好含有本工具的標記字串。靠標記判斷所有權會
#      (a) install 誤報已安裝而實際沒有 guard、(b) uninstall 刪掉別人的檔案。
mkrepo collide && mkdir -p .claude .git/hooks
printf '#!/bin/sh\n# pre-commit-pipeline gate\necho "actually someone elses"\n' > .git/hooks/pre-commit
chmod +x .git/hooks/pre-commit
out=$(bash "$INS" 2>&1 >/dev/null || true)
[[ "$out" == *"不是本工具寫的內容"* ]] && pass "標記碰撞時 install 仍拒絕" || fail "install 誤判: $out"
out=$(bash "$INS" --uninstall 2>&1 >/dev/null || true)
grep -q "actually someone elses" .git/hooks/pre-commit \
  && pass "標記碰撞時 uninstall 不刪他人 hook" || fail "他人 hook 被刪除"

# 18 — guard 失蹤時必須 fail closed。一個靜默消失的 gate 比會抱怨的危險得多。
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
