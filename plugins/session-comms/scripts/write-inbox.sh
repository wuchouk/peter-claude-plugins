#!/usr/bin/env bash
# write-inbox.sh — Append a MSG block to a target session's inbox (with locking)
#
# Usage: write-inbox.sh <target-session-name> <from-session-name> <type> <id> <content>
#        type:    default | URGENT | FYI  (must be one of these, not empty)
#        id:      message id (e.g. m-001)
#        content: message body (multi-line OK, pass via $'...')
#
# The script formats the MSG block and appends it atomically.
# Exit: 0 OK, 1 if target inbox doesn't exist, 3 if lock acquisition timed out
#
# LOCKING: Uses mkdir as a POSIX-atomic spinlock (macOS-compatible, unlike flock
# which isn't in the base system). Lock acquire timeout: 5 seconds. On timeout,
# exits with code 3 so the caller can decide whether to retry or report failure.

set -euo pipefail

if [ $# -ne 5 ]; then
  echo "Usage: write-inbox.sh <target> <from> <type> <id> <content>" >&2
  exit 2
fi

TARGET="$1"
FROM="$2"
TYPE="$3"
MSG_ID="$4"
CONTENT="$5"

GIT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "ERROR: not in a git repo" >&2
  exit 1
}

INBOX="$GIT_ROOT/tasks/.comms/${TARGET}.inbox.md"

if [ ! -f "$INBOX" ]; then
  echo "ERROR: target inbox not found: $INBOX" >&2
  echo "HINT: is '$TARGET' registered and online? Check tasks/.comms/registry.md" >&2
  exit 1
fi

TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Build MSG block header (omit type attribute for default)
if [ "$TYPE" = "default" ]; then
  HEADER="<!-- MSG from:${FROM} ts:${TS} id:${MSG_ID} -->"
else
  HEADER="<!-- MSG from:${FROM} ts:${TS} type:${TYPE} id:${MSG_ID} -->"
fi
FOOTER="<!-- END id:${MSG_ID} -->"

# Build the complete block in a temp file first
TMP="$(mktemp "${TMPDIR:-/tmp}/comms-msg.XXXXXX")"
{
  printf '\n%s\n' "$HEADER"
  printf '%s\n' "$CONTENT"
  printf '%s\n' "$FOOTER"
} > "$TMP"

# Acquire lock using mkdir (POSIX atomic). Retry up to 5s (100 x 50ms).
LOCK="${INBOX}.lock"
ACQUIRED=0
for _ in $(seq 1 100); do
  if mkdir "$LOCK" 2>/dev/null; then
    ACQUIRED=1
    break
  fi
  sleep 0.05
done

if [ "$ACQUIRED" -ne 1 ]; then
  rm -f "$TMP"
  echo "ERROR: could not acquire lock on $INBOX after 5s (stale lock? try: rm -rf '$LOCK')" >&2
  exit 3
fi

# Guarantee lock release even on error
trap 'rmdir "$LOCK" 2>/dev/null; rm -f "$TMP"' EXIT INT TERM

# Critical section: append the message block
cat "$TMP" >> "$INBOX"

# Release lock (also released by trap on exit)
rmdir "$LOCK" 2>/dev/null
rm -f "$TMP"
trap - EXIT INT TERM

echo "OK sent to=$TARGET id=$MSG_ID type=${TYPE:-default}"
