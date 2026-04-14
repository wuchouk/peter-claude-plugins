#!/usr/bin/env bash
# archive-inbox.sh — Move an inbox into archive/ and remove the heartbeat
#
# Usage: archive-inbox.sh <session-name> [reason]
#        reason: optional suffix tag (e.g. "leave", "zombie", "crash")
#
# Leaves the registry file alone — that's Claude's job via Edit.
# This script handles the file-side cleanup of a session's state:
#   1. Move <session>.inbox.md into archive/ with a timestamped name
#   2. Remove <session>.heartbeat (so the session won't appear alive on next check)

set -euo pipefail

if [ $# -lt 1 ]; then
  echo "Usage: archive-inbox.sh <session-name> [reason]" >&2
  exit 2
fi

SESSION="$1"
REASON="${2:-leave}"

GIT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "ERROR: not in a git repo" >&2
  exit 1
}

INBOX="$GIT_ROOT/tasks/.comms/${SESSION}.inbox.md"
HEARTBEAT="$GIT_ROOT/tasks/.comms/${SESSION}.heartbeat"
ARCHIVE_DIR="$GIT_ROOT/tasks/.comms/archive"

mkdir -p "$ARCHIVE_DIR"

MOVED_INBOX=""
if [ -f "$INBOX" ]; then
  TS="$(date -u +%Y%m%d-%H%M%S)"
  DEST="$ARCHIVE_DIR/${SESSION}-${TS}-${REASON}.inbox.md"
  mv "$INBOX" "$DEST"
  MOVED_INBOX="$DEST"
fi

# Always remove heartbeat, even if inbox was missing (idempotent zombie cleanup)
REMOVED_HB=""
if [ -f "$HEARTBEAT" ]; then
  rm -f "$HEARTBEAT"
  REMOVED_HB="yes"
fi

if [ -z "$MOVED_INBOX" ] && [ -z "$REMOVED_HB" ]; then
  echo "NOOP session=$SESSION has no inbox or heartbeat"
  exit 0
fi

echo "OK archived session=$SESSION inbox=${MOVED_INBOX:-none} heartbeat_removed=${REMOVED_HB:-no}"
