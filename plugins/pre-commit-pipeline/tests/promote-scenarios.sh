#!/usr/bin/env bash
# promote-scenarios.sh — promote-plugin.sh 的情境測試（可重跑）
#
# 這支腳本會動使用者的**主 checkout 與 plugin cache**，所以測試必須驗證兩件事：
# 拒絕執行時完全沒動過東西，以及中途失敗時 cache 有還原。全部在假 HOME 的沙箱裡跑，
# 不碰真實的 ~/peter-claude-plugins 或 ~/.claude。
#
# 跑法：bash <這個外掛>/tests/promote-scenarios.sh
set -uo pipefail

unset PIPELINE_SKIP
PLUGIN="${PIPELINE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
WORK="${TMPDIR:-/tmp}/pipeline-promote-scenarios-$$"
FAILED=0
pass() { echo "  ✓ $1"; }
fail() { echo "  ✗ $1"; FAILED=$((FAILED + 1)); }

# 一個沙箱 = 假 HOME + 主 checkout（在 main）+ 一個領先一個 commit 的 worktree + cache。
# cache 裡放一個 sentinel 檔：只要它還在，就代表 rsync --delete 沒跑過（或已還原）。
new_sandbox() {
  SB="$WORK/$1"; rm -rf "$SB"
  export HOME="$SB/home"
  MAIN="$HOME/peter-claude-plugins"
  WT="$SB/wt"
  CACHE="$HOME/.claude/plugins/cache/peter-claude-plugins/pre-commit-pipeline/0.1.0"
  mkdir -p "$MAIN" "$CACHE"
  cp -R "$PLUGIN/../.." /dev/null 2>/dev/null || true   # no-op，保持結構明確
  mkdir -p "$MAIN/plugins"
  cp -R "$PLUGIN" "$MAIN/plugins/pre-commit-pipeline"
  ( cd "$MAIN" && git init -q . && git config user.email t@t && git config user.name t \
    && git config commit.gpgsign false && git add -A \
    && PIPELINE_SKIP=1 git commit -qm "base" --no-verify ) >/dev/null
  # worktree：領先 main 一個 commit
  ( cd "$MAIN" && git worktree add -q -b promote-test "$WT" ) >/dev/null 2>&1
  echo "# promoted change" >> "$WT/plugins/pre-commit-pipeline/README.md"
  ( cd "$WT" && git add -A && PIPELINE_SKIP=1 git commit -qm "feat: 要上線的改動" --no-verify ) >/dev/null
  cp -R "$MAIN/plugins/pre-commit-pipeline/." "$CACHE/"
  echo "sentinel" > "$CACHE/SENTINEL.txt"
  PROMOTE="$WT/plugins/pre-commit-pipeline/scripts/promote-plugin.sh"
}
main_has_change() { grep -q "promoted change" "$MAIN/plugins/pre-commit-pipeline/README.md" 2>/dev/null; }
cache_untouched() { [ -f "$CACHE/SENTINEL.txt" ]; }

run_promote() { PROMOTE_ASSUME_YES=1 bash "$PROMOTE" </dev/null 2>&1; }

echo "=== P1) 正常路徑 → 併入、同步、sentinel 被清掉 ==="
new_sandbox happy
out=$(run_promote); rc=$?
[ "$rc" = "0" ] && pass "exit 0" || fail "exit $rc：$(printf '%s' "$out" | tail -5)"
main_has_change && pass "主 checkout 拿到 worktree 的 commit" || fail "commit 沒併進去"
cache_untouched && fail "cache 沒被同步（sentinel 還在）" || pass "cache 已被同步"
printf '%s' "$out" | grep -q "上線完成" && pass "印出上線完成" || fail "沒有完成訊息"

echo ""
echo "=== P2) 主 checkout 有未提交變更 → 拒絕，且什麼都沒動 ==="
new_sandbox dirty-main
echo "local edit" >> "$MAIN/plugins/pre-commit-pipeline/README.md"
out=$(run_promote); rc=$?
[ "$rc" != "0" ] && pass "拒絕執行" || fail "髒的主 checkout 卻照跑"
main_has_change && fail "竟然併進去了" || pass "沒有併入"
cache_untouched && pass "cache 未被動過" || fail "cache 被動了"

echo ""
echo "=== P3) 主 checkout 不在 main → 拒絕 ==="
new_sandbox not-main
( cd "$MAIN" && git checkout -q -b other ) >/dev/null 2>&1
out=$(run_promote); rc=$?
{ [ "$rc" != "0" ] && printf '%s' "$out" | grep -q "不是 main"; } && pass "拒絕並說明原因" || fail "沒擋下：$out"
cache_untouched && pass "cache 未被動過" || fail "cache 被動了"

echo ""
echo "=== P4) worktree 有未提交變更 → 拒絕 ==="
new_sandbox dirty-wt
echo "uncommitted" >> "$WT/plugins/pre-commit-pipeline/README.md"
out=$(run_promote); rc=$?
[ "$rc" != "0" ] && pass "拒絕執行" || fail "髒的 worktree 卻照跑"
cache_untouched && pass "cache 未被動過" || fail "cache 被動了"

echo ""
echo "=== P5) detached HEAD → 拒絕（不能靜默把 main 併進自己） ==="
new_sandbox detached
( cd "$WT" && git checkout -q --detach ) >/dev/null 2>&1
out=$(run_promote); rc=$?
{ [ "$rc" != "0" ] && printf '%s' "$out" | grep -q "detached"; } \
  && pass "拒絕並指出 detached HEAD" || fail "detached HEAD 下仍報成功：$(printf '%s' "$out" | tail -3)"
main_has_change && fail "main 被動過" || pass "main 未被動過"

echo ""
echo "=== P6) 無法 fast-forward（main 已往前走）→ 拒絕，cache 不動 ==="
new_sandbox no-ff
echo "divergent" >> "$MAIN/plugins/pre-commit-pipeline/README.md"
( cd "$MAIN" && git add -A && PIPELINE_SKIP=1 git commit -qm "main 自己的 commit" --no-verify ) >/dev/null
out=$(run_promote); rc=$?
[ "$rc" != "0" ] && pass "拒絕執行" || fail "無法 ff 卻照跑"
cache_untouched && pass "cache 未被動過（失敗發生在同步之前）" || fail "cache 已被換掉"

echo ""
echo "=== P7) 同步後驗證失敗 → cache 還原成同步前的內容 ==="
new_sandbox rollback
# 讓第 4 步失敗：要上線的分支本身帶著一支必定失敗的情境測試。ff 會成功、cache 會被
# 換掉，然後第 4 步跑主 checkout 的版本時才失敗 —— 這正是需要還原的那條路徑。
printf '#!/usr/bin/env bash\necho "forced failure"\nexit 1\n' \
  > "$WT/plugins/pre-commit-pipeline/tests/gate-scenarios.sh"
( cd "$WT" && git add -A && PIPELINE_SKIP=1 git commit -qm "壞掉的測試" --no-verify ) >/dev/null
out=$(run_promote); rc=$?
[ "$rc" != "0" ] && pass "測試失敗 → 非 0 退出" || fail "測試失敗卻報成功"
cache_untouched && pass "cache 已還原（sentinel 還在）" || fail "壞版本留在 cache 裡"
printf '%s' "$out" | grep -q "還原" && pass "訊息明講已還原" || fail "沒說有還原：$(printf '%s' "$out" | tail -3)"

echo ""
echo "=== P8) cache 不存在 → 略過同步但不失敗 ==="
new_sandbox no-cache
rm -rf "$CACHE"
out=$(run_promote); rc=$?
[ "$rc" = "0" ] && pass "exit 0" || fail "exit $rc：$(printf '%s' "$out" | tail -5)"
main_has_change && pass "仍然併入主 checkout" || fail "沒併入"
printf '%s' "$out" | grep -q "跳過" && pass "說明已略過 cache 同步" || fail "沒說明略過"

echo ""
echo "=== P9) 非互動且沒設 PROMOTE_ASSUME_YES → 明確報錯，不靜默失敗 ==="
new_sandbox no-tty
out=$(bash "$PROMOTE" </dev/null 2>&1); rc=$?
{ [ "$rc" != "0" ] && printf '%s' "$out" | grep -q "PROMOTE_ASSUME_YES"; } \
  && pass "報錯並指出非互動用法" || fail "靜默失敗了：$(printf '%s' "$out" | tail -3)"
cache_untouched && pass "cache 未被動過" || fail "cache 被動了"

echo ""
if [ "$FAILED" -eq 0 ]; then
  echo "=== 全部情境通過 ✓ ==="
  rm -rf "$WORK"
  exit 0
else
  echo "=== 有 $FAILED 項失敗 ✗（工作目錄保留：$WORK）==="
  exit 1
fi
