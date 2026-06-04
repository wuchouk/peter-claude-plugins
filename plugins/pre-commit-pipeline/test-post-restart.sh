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

echo "=== Test 1: WIP commit 放行 ==="
out=$(echo '{"tool_input":{"command":"git commit -m \"WIP: dev\""}}' | bash "$COMMIT_HOOK" 2>&1 ; echo "rc=$?")
[[ "$out" == *"pipeline skipped"* && "$out" == *"rc=0"* ]] && pass "WIP allowed" || fail "WIP not allowed: $out"

echo ""
echo "=== Test 2: 無 marker 被擋（commit） ==="
rc=$(echo '{"tool_input":{"command":"git commit -m \"feat: x\""}}' | bash "$COMMIT_HOOK" 2>/dev/null ; echo "$?")
[ "$rc" = "2" ] && pass "no marker blocks" || fail "expected exit 2, got $rc"

echo ""
echo "=== Test 3: 3 marker 通過（commit） ==="
bash "$MARK" simplify > /dev/null
bash "$MARK" review > /dev/null
bash "$MARK" verify-tests > /dev/null
rc=$(echo '{"tool_input":{"command":"git commit -m \"feat: x\""}}' | bash "$COMMIT_HOOK" 2>/dev/null ; echo "$?")
[ "$rc" = "0" ] && pass "all 3 markers pass commit hook" || fail "expected exit 0, got $rc"

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

bash "$MARK" document-release > /dev/null
rc=$(echo '{"tool_input":{"command":"/ship"}}' | bash "$SHIP_HOOK" 2>/dev/null ; echo "$?")
[ "$rc" = "0" ] && pass "all 4 markers pass ship hook" || fail "expected exit 0, got $rc"

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
echo "=== All Phase 2 tests passed ✓ ==="
echo "Plugin location: $PLUGIN"
echo "Test workspace: $D (you can /opt/homebrew/opt/trash/bin/trash it now)"
