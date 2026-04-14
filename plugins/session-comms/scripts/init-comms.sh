#!/usr/bin/env bash
# init-comms.sh — One-time setup for session-comms in a git repo
#
# Creates:
#   tasks/.comms/               (directory)
#   tasks/.comms/archive/       (subdirectory)
#   tasks/.comms/registry.md    (empty registry, if not exists)
#
# Also:
#   - Adds tasks/.comms/ to .gitignore if missing
#   - Purges archive files older than 7 days
#
# Usage: init-comms.sh
# Exit:  0 OK, non-zero on error

set -euo pipefail

# Must be in a git repo
GIT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "ERROR: not in a git repo" >&2
  exit 1
}

COMMS_DIR="$GIT_ROOT/tasks/.comms"
ARCHIVE_DIR="$COMMS_DIR/archive"
REGISTRY="$COMMS_DIR/registry.md"
GITIGNORE="$GIT_ROOT/.gitignore"

# Create directories
mkdir -p "$ARCHIVE_DIR"

# Create empty registry if missing
if [ ! -f "$REGISTRY" ]; then
  cat > "$REGISTRY" <<'REG'
# Session Registry

> 多 session 平行開發時的註冊表。session-comms plugin 自動維護。
> 不要手動編輯，除非 plugin 壞掉。
>
> 活性檢查透過 `<session>.heartbeat` 檔案的 mtime，不透過 PID
> （Claude Code 的 Bash tool 每次 spawn 新 shell，`$$` 不穩定）。
> Zombie = heartbeat mtime 超過 10 分鐘沒更新。

| Session Name | Branch | Port | Scope | Started |
|--------------|--------|------|-------|---------|
REG
fi

# Ensure .gitignore includes tasks/.comms/
if [ -f "$GITIGNORE" ]; then
  if ! grep -qxF "tasks/.comms/" "$GITIGNORE"; then
    printf '\n# session-comms plugin ephemeral state\ntasks/.comms/\n' >> "$GITIGNORE"
  fi
else
  printf '# session-comms plugin ephemeral state\ntasks/.comms/\n' > "$GITIGNORE"
fi

# Purge archives older than 7 days (quietly)
find "$ARCHIVE_DIR" -type f -name '*.inbox.md' -mtime +7 -delete 2>/dev/null || true

echo "OK comms_dir=$COMMS_DIR"
