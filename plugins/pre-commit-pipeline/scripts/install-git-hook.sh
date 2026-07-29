#!/usr/bin/env bash
# install-git-hook.sh — 讓「沒有 husky」的 repo 也受 git-native pipeline gate 保護。
#
# 為什麼需要：git-native guard 目前透過 ~/.config/husky/init.sh 掛載，而那個
# loader 只在 husky repo 生效。沒有 husky 的 repo 就只剩 Claude Code 的
# PreToolUse hook 守著，那一層有兩個結構性問題：
#   1. 只在 Claude Code 內生效 —— Codex / Fugu / 人手 commit 完全沒守。
#   2. 它必須從命令「字串」猜這是不是 commit，所以任何提到 git commit 的命令
#      都會被誤攔（實例：把一段說明文字餵給 codex exec 時被擋下，而那個命令
#      根本不碰 git）。
# 從 git 自己觸發沒有這兩個問題 —— git 當然知道自己在 commit。
#
# 用法：
#   bash install-git-hook.sh              # 安裝到當前 repo
#   bash install-git-hook.sh --uninstall  # 移除
#
# 安全性：**絕不動不是本工具寫的 hook**。所有權以「內容與本工具會生成的完全
# 相同」判定，不靠標記字串或行數 —— 兩者都可能誤判別人的 hook 而刪掉它。
set -euo pipefail

MARKER="pre-commit-pipeline gate"

# guard 路徑在安裝當下解析成絕對路徑寫進 stub，不留 $HOME 讓執行期展開：
# 換使用者、GUI 帶不同 HOME、或 plugin 搬家，都會讓執行期展開找不到 guard，
# 而 hook 找不到 guard 就靜默放行 —— gate 無聲消失正是這整套要防的事。
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
GUARD="$SCRIPT_DIR/../hooks/git-commit-msg-guard.sh"
GUARD=$(cd "$(dirname "$GUARD")" && pwd)/$(basename "$GUARD")

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
if [ -z "$REPO_ROOT" ]; then
  if [ "$(git rev-parse --is-bare-repository 2>/dev/null || echo false)" = "true" ]; then
    echo "install-git-hook: 這是 bare repo，不會有 commit 動作，無需安裝。" >&2
  else
    echo "install-git-hook: 不在 git repo 內。" >&2
  fi
  exit 1
fi

# hook 目錄要問 git，不能拼 "$REPO_ROOT/.git/hooks"：
#   - core.hooksPath 一旦設定，git 只從那裡找 hook，寫到 .git/hooks 等於白裝
#   - linked worktree 的 .git 是檔案不是目錄
HOOKS_PATH=$(cd "$REPO_ROOT" && git config --get core.hooksPath 2>/dev/null || true)
if [ -n "$HOOKS_PATH" ]; then
  case "$HOOKS_PATH" in /*) HOOK_DIR="$HOOKS_PATH" ;; *) HOOK_DIR="$REPO_ROOT/$HOOKS_PATH" ;; esac
  USING_HOOKSPATH=1
else
  HOOK_DIR=$(cd "$REPO_ROOT" && git rev-parse --git-path hooks)
  case "$HOOK_DIR" in /*) ;; *) HOOK_DIR="$REPO_ROOT/$HOOK_DIR" ;; esac
  USING_HOOKSPATH=0
fi
HOOK="$HOOK_DIR/pre-commit"

# 產生這台機器上「本工具應該寫出的」確切內容。install 與 uninstall 都拿它跟
# 現場檔案做全文比對 —— 這才是所有權的證明。
gen_stub() {
  cat <<EOF
#!/usr/bin/env sh
# ${MARKER} — installed by install-git-hook.sh
# 讓非-husky repo 也能在 git 層擋下沒跑完 pipeline 的 commit。
# 移除：bash ${SCRIPT_DIR}/install-git-hook.sh --uninstall
_g="${GUARD}"
if [ -x "\$_g" ]; then
  exec "\$_g"
fi
echo "pre-commit-pipeline: guard 不存在或不可執行：\$_g" >&2
echo "  重新安裝：bash ${SCRIPT_DIR}/install-git-hook.sh" >&2
echo "  或移除本 hook：bash ${SCRIPT_DIR}/install-git-hook.sh --uninstall" >&2
exit 1
EOF
}

# 找不到 guard 時 stub 選擇「擋下」而非放行：一個靜默消失的 gate 比一個會抱怨
# 的 gate 危險得多 —— 你會以為它還在守。

if [ "${1:-}" = "--uninstall" ]; then
  if [ ! -f "$HOOK" ]; then
    echo "install-git-hook: 這個 repo 沒有 ${HOOK}，無需移除。"
    exit 0
  fi
  if diff -q <(gen_stub) "$HOOK" >/dev/null 2>&1; then
    rm -f "$HOOK"
    echo "install-git-hook: 已移除 ${HOOK}"
    exit 0
  fi
  echo "install-git-hook: ${HOOK} 的內容不是本工具寫的（或已被修改過），未做任何變更。" >&2
  if grep -q "$MARKER" "$HOOK" 2>/dev/null; then
    echo "  它含有本工具的標記，但內容對不上 —— 可能是舊版安裝或有人編輯過。" >&2
    echo "  請自行確認後手動處理，本工具不會刪除無法證明歸屬的檔案。" >&2
  fi
  exit 1
fi

# husky repo 的判定要看「實際存在的 user hook 檔案」，不是看 .husky/ 目錄：
# husky v9 的 loader（.husky/_/h）在該 hook 沒有對應 user hook 檔時會提前
# 結束，根本不會 source ~/.config/husky/init.sh —— 那種 repo 其實沒有被涵蓋，
# 需要安裝。
if [ -f "$REPO_ROOT/.husky/pre-commit" ] || [ -f "$REPO_ROOT/.husky/commit-msg" ]; then
  echo "install-git-hook: 這是 husky repo 且有 user hook，已由 ~/.config/husky/init.sh 涵蓋 —— 不需安裝。"
  exit 0
fi
if [ -d "$REPO_ROOT/.husky" ]; then
  echo "install-git-hook: 偵測到 .husky/ 但沒有 pre-commit / commit-msg —— husky loader 不會 source 全域 init，"
  echo "  所以這個 repo 其實沒被涵蓋，仍需安裝。"
fi

if [ ! -x "$GUARD" ]; then
  echo "install-git-hook: 找不到可執行的 guard：${GUARD}" >&2
  echo "  確認 plugin 位置正確後再安裝（stub 會寫死這個路徑）。" >&2
  exit 1
fi

# guard 只納管有 .claude/ 的 repo（opt-in）。沒有的話裝了也不會生效，先講清楚。
if [ ! -d "$REPO_ROOT/.claude" ]; then
  echo "install-git-hook: 提醒 —— 這個 repo 沒有 .claude/ 目錄，guard 依約定會直接放行。"
  echo "  hook 仍會安裝，等你之後建立 .claude/ 就會自動開始納管。"
fi

mkdir -p "$HOOK_DIR"

if [ -f "$HOOK" ]; then
  if diff -q <(gen_stub) "$HOOK" >/dev/null 2>&1; then
    echo "install-git-hook: 已經安裝過了（${HOOK}）。"
    exit 0
  fi
  # 內容對不上 —— 不論它是不是含有我們的標記，都不動它。
  echo "install-git-hook: ${HOOK} 已存在且不是本工具寫的內容，未做任何修改。" >&2
  echo "" >&2
  echo "  要納管的話，把下面這段加進該檔案（或先備份後重裝）：" >&2
  echo "" >&2
  gen_stub | sed 's/^/    /' >&2
  echo "" >&2
  exit 1
fi

gen_stub > "$HOOK"
chmod +x "$HOOK"

echo "install-git-hook: 已安裝 ${HOOK}"
[ "$USING_HOOKSPATH" = "1" ] && echo "  （此 repo 設了 core.hooksPath，已安裝到該目錄）"
exit 0
