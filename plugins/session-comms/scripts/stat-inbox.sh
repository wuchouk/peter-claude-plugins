#!/usr/bin/env bash
# stat-inbox.sh — Fast mtime check for an inbox (pre/post long-tool peek)
#
# Usage: stat-inbox.sh <session-name>
# Output: a single line: "mtime=<unix-epoch> size=<bytes>"
# Exit:   0 if file exists, 1 if not
#
# Intended for Claude to call before and after long tool calls to detect new messages.
# Claude tracks the last-seen mtime+size in its working memory and compares against this output.
# Note: compare BOTH mtime AND size — macOS mtime has 1-second resolution, rapid writes
# within the same second won't bump mtime but size still changes.
#
# PORTABILITY: macOS only (uses BSD `stat -f`). On Linux use `stat -c %Y` / `-c %s`.

set -euo pipefail

if [ $# -ne 1 ]; then
  echo "Usage: stat-inbox.sh <session-name>" >&2
  exit 2
fi

SESSION="$1"
GIT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "ERROR: not in a git repo" >&2
  exit 1
}

INBOX="$GIT_ROOT/tasks/.comms/${SESSION}.inbox.md"

if [ ! -f "$INBOX" ]; then
  echo "mtime=0 size=0 exists=false"
  exit 1
fi

# macOS BSD stat
MTIME="$(stat -f %m "$INBOX")"
SIZE="$(stat -f %z "$INBOX")"

echo "mtime=${MTIME} size=${SIZE} exists=true"
