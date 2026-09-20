#!/usr/bin/env bash
# promote-plugin.sh — 把 worktree 裡改好的 pre-commit-pipeline 變更上線到這台機器。
#
# 兩件事：(1) 把 worktree 的分支併進主 checkout；(2) 把主 checkout 的外掛內容
# rsync 進 Claude Code 的 plugin cache（PreToolUse 層讀的是 cache 副本，不同步的話
# git 層是新規則、Claude 內建層還是舊規則）。最後印出兩處 pipeline-lib.sh 的雜湊值
# 自我驗證，並用主 checkout 的版本重跑一次情境測試。
#
# 先印出要做什麼並等確認，輸入 yes 才動手。只讀/寫這個外掛的檔案，不碰任何專案。
set -euo pipefail

WORKTREE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"   # …/.claude/worktrees/<name>
MAIN="$HOME/peter-claude-plugins"
REL="plugins/pre-commit-pipeline"

say() { printf '%s\n' "$@"; }
die() { printf '\n✗ %s\n' "$1" >&2; exit 1; }

# Checked before anything else: run from a copy that is not a git worktree (the
# plugin cache, a tarball) and the next git call would spit `fatal: not a git
# repository` with no context at all.
git -C "$WORKTREE" rev-parse --git-dir >/dev/null 2>&1 \
  || die "這支腳本要從 git worktree 裡跑，但 $WORKTREE 不是 git repo（是不是從 plugin cache 的副本執行？）"
BRANCH="$(git -C "$WORKTREE" rev-parse --abbrev-ref HEAD)"
# detached HEAD reports the branch name as "HEAD", which turns step 1 into
# `merge --ff-only HEAD` — merging main into itself. That succeeds, prints
# "fast-forward 完成", syncs the cache and reports success while not a single
# commit from this worktree went anywhere.
[ "$BRANCH" != "HEAD" ] \
  || die "worktree 目前是 detached HEAD，沒有分支可以併。先 checkout 一個分支再跑。"
# The cache directory is named after the plugin version. Reading it from
# plugin.json (the source of truth) instead of hardcoding it matters: a version
# bump with a hardcoded path makes this script quietly print "cache 不存在 →
# 跳過" and skip the one thing it exists to do.
VERSION="$(jq -r '.version' "$WORKTREE/$REL/.claude-plugin/plugin.json")"
CACHE="$HOME/.claude/plugins/cache/peter-claude-plugins/pre-commit-pipeline/$VERSION"

say "將要執行的動作"
say "  1. 把分支 $BRANCH（$WORKTREE）併進主 checkout $MAIN 的 main"
say "  2. rsync $MAIN/$REL/ → $CACHE/（Claude Code 讀的副本，版本取自 plugin.json）"
say "  3. 印出兩處 pipeline-lib.sh 的 SHA256 確認一致"
say "  4. 用主 checkout 的版本重跑 tests/gate-scenarios.sh"
say ""
say "前置檢查"

[ -d "$MAIN/.git" ] || die "找不到主 checkout：$MAIN"
[ -d "$CACHE" ] || say "  · plugin cache 不存在（$CACHE）→ 第 2 步會略過，改用 /plugin 重裝"

if [ -n "$(git -C "$WORKTREE" status --porcelain)" ]; then
  git -C "$WORKTREE" status --short | sed 's/^/      /'
  die "worktree 還有未提交的變更，先 commit 再跑這支"
fi
say "  · worktree 乾淨 ✓"

# The worktrees directory lives inside the main checkout and is untracked, so
# without the exclusion this refuses to run on any machine that does not happen
# to have `.claude/worktrees/` in its local .git/info/exclude.
if [ -n "$(git -C "$MAIN" status --porcelain -- ':!.claude/worktrees')" ]; then
  git -C "$MAIN" status --short -- ':!.claude/worktrees' | sed 's/^/      /'
  die "主 checkout 有未提交的變更，先處理掉再跑這支"
fi
MAIN_BRANCH="$(git -C "$MAIN" rev-parse --abbrev-ref HEAD)"
[ "$MAIN_BRANCH" = "main" ] || die "主 checkout 目前在 $MAIN_BRANCH，不是 main"
say "  · 主 checkout 乾淨且在 main ✓"

say ""
say "這次要併進來的 commit："
git -C "$MAIN" log --oneline main.."$BRANCH" | sed 's/^/      /' || true
say ""
# PROMOTE_ASSUME_YES exists so the scenario tests can drive this script. Without
# it a closed stdin made `read` fail under `set -e`: the script died silently,
# with no message at all, looking exactly like a crash.
if [ "${PROMOTE_ASSUME_YES:-}" = "1" ]; then
  say "確定執行嗎？→ PROMOTE_ASSUME_YES=1，略過確認"
else
  printf '確定執行嗎？輸入 yes 繼續：'
  read -r ANSWER || die "讀不到輸入（stdin 已關閉？）。非互動執行請設 PROMOTE_ASSUME_YES=1。"
  [ "$ANSWER" = "yes" ] || die "已取消，沒有任何變更"
fi

say ""
say "[1/4] 合併分支"
if git -C "$MAIN" merge --ff-only "$BRANCH" 2>/dev/null; then
  say "  fast-forward 完成"
else
  die "無法 fast-forward（main 已經往前走了）。請自行決定要 merge PR 還是 rebase，
     完成後重跑這支腳本；它會偵測到已經併好並直接做同步。"
fi

say ""
say "[2/4] 同步 plugin cache"
# The cache is what Claude Code actually runs, and rsync --delete replaces it
# wholesale. Everything after this point can still fail (verification, the test
# run), so keep a copy and put it back rather than leaving a half-verified gate
# installed — a broken cache blocks every commit on this machine.
CACHE_BAK=""
restore_cache() {
  [ -n "$CACHE_BAK" ] && [ -d "$CACHE_BAK" ] || return 0
  rsync -a --delete "$CACHE_BAK/" "$CACHE/"
  say "  ↩ plugin cache 已還原成同步前的內容"
}
die_rollback() { restore_cache; die "$1"; }
if [ -d "$CACHE" ]; then
  CACHE_BAK="$(mktemp -d "${TMPDIR:-/tmp}/pipeline-cache-bak.XXXXXX")"
  rsync -a "$CACHE/" "$CACHE_BAK/"
  rsync -a --delete --exclude='.git' --exclude='.in_use' "$MAIN/$REL/" "$CACHE/"
  say "  已同步（同步前的內容備份在 $CACHE_BAK）"
else
  say "  跳過（cache 不存在）"
fi

say ""
say "[3/4] 驗證兩處內容一致"
H_MAIN=$(shasum -a 256 "$MAIN/$REL/scripts/pipeline-lib.sh" | awk '{print $1}')
say "  主 checkout : $H_MAIN"
if [ -d "$CACHE" ]; then
  H_CACHE=$(shasum -a 256 "$CACHE/scripts/pipeline-lib.sh" | awk '{print $1}')
  say "  plugin cache: $H_CACHE"
  [ "$H_MAIN" = "$H_CACHE" ] || die_rollback "兩處的 pipeline-lib.sh 不一致，cache 同步沒成功"
  DRIFT=$(diff -rq "$MAIN/$REL" "$CACHE" --exclude='.git' --exclude='.in_use' 2>/dev/null || true)
  [ -z "$DRIFT" ] || { printf '%s\n' "$DRIFT" | sed 's/^/      /'; die_rollback "還有其他檔案不一致"; }
  say "  一致 ✓"
fi

say ""
say "[4/4] 用主 checkout 的版本重跑情境測試"
if bash "$MAIN/$REL/tests/gate-scenarios.sh" | tail -3; then
  :
else
  die_rollback "情境測試沒過 —— 這個版本不該留在 cache 裡"
fi

# Only now is the new copy known good; drop the backup.
[ -n "$CACHE_BAK" ] && rm -rf "$CACHE_BAK"

say ""
say "上線完成。新規則對 git 層即時生效；已經開著的 Claude session 會在下一次"
say "commit 時走到新的 cache 副本，不需要重啟。"
