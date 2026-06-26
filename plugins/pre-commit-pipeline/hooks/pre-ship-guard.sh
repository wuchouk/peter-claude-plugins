#!/usr/bin/env bash
# pre-ship-guard.sh — PreToolUse (SlashCommand) hook for Claude Code.
# Blocks /ship until the full ship-gate markers (see pipeline-steps.json) are
# present, fresh, and not batch-ticked. No WIP escape hatch — /ship is a formal
# release and must clear the whole pipeline.
#
# Exit codes:
#   0 → allow
#   2 → block (stderr shown to Claude)
set -euo pipefail

PAYLOAD=$(cat)

# Different Claude Code versions may use different payload keys.
COMMAND=$(echo "$PAYLOAD" | jq -r '
  .tool_input.command //
  .tool_input.slash_command //
  .tool_input.name //
  ""
')

# Fast exit: not /ship
case "$COMMAND" in
  "/ship"|"/ship "*) ;;
  *) exit 0 ;;
esac

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
[ -z "$REPO_ROOT" ] && exit 0

LIB="$(cd "$(dirname "$0")" && pwd)/../scripts/pipeline-lib.sh"
# shellcheck source=/dev/null
. "$LIB"

if pipeline_eval_gate "ship" "pre-ship-pipeline"; then
  exit 0
fi
exit 2
