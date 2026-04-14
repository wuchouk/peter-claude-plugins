#!/usr/bin/env bash
# watch-inbox.sh — Background file watcher; prints INBOX_CHANGED events on stdout
#
# Usage: watch-inbox.sh <session-name> [tick-seconds]
#        tick-seconds: poll interval, default 3
#
# Runs forever (until killed). Emits one line per mtime/size change:
#   INBOX_CHANGED ts=<unix-epoch> size=<bytes>
#
# Intended to be launched via Claude Code's Bash run_in_background=true,
# then monitored with the Monitor tool to receive notifications on stdout events.
#
# PORTABILITY: macOS only (uses BSD `stat -f`). On Linux use `stat -c %Y` / `-c %s`.
# PREREQ: the target inbox file must exist before starting this watcher.

set -euo pipefail

if [ $# -lt 1 ]; then
  echo "Usage: watch-inbox.sh <session-name> [tick-seconds]" >&2
  exit 2
fi

SESSION="$1"
TICK="${2:-3}"

GIT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "ERROR: not in a git repo" >&2
  exit 1
}

INBOX="$GIT_ROOT/tasks/.comms/${SESSION}.inbox.md"

if [ ! -f "$INBOX" ]; then
  echo "ERROR: inbox not found: $INBOX" >&2
  exit 1
fi

LAST_MTIME="$(stat -f %m "$INBOX")"
LAST_SIZE="$(stat -f %z "$INBOX")"
echo "WATCH_STARTED session=$SESSION tick=${TICK}s inbox=$INBOX mtime=$LAST_MTIME size=$LAST_SIZE"

while true; do
  if [ ! -f "$INBOX" ]; then
    echo "INBOX_REMOVED session=$SESSION"
    exit 0
  fi
  CUR_MTIME="$(stat -f %m "$INBOX")"
  CUR_SIZE="$(stat -f %z "$INBOX")"
  if [ "$CUR_MTIME" != "$LAST_MTIME" ] || [ "$CUR_SIZE" != "$LAST_SIZE" ]; then
    echo "INBOX_CHANGED ts=${CUR_MTIME} size=${CUR_SIZE}"
    LAST_MTIME="$CUR_MTIME"
    LAST_SIZE="$CUR_SIZE"
  fi
  sleep "$TICK"
done
