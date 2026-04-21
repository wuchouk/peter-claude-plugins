#!/usr/bin/env bash
# zeabur-watch-deploy — poll the latest Zeabur deployment for a service.
# On success: one-line report. On failure: extract build log error snippets.
#
# Reuses ~/.config/zeabur/{token,services.json} from the retired zeabur-mcp.
# Usage: watch.sh [service-name]   (default: email-processor)
# Env:   ZEABUR_POLL_INTERVAL=15   ZEABUR_MAX_WAIT=1800

set -euo pipefail

SERVICE_NAME="${1:-email-processor}"
POLL_INTERVAL="${ZEABUR_POLL_INTERVAL:-15}"
MAX_WAIT="${ZEABUR_MAX_WAIT:-1800}"

TOKEN_FILE="${HOME}/.config/zeabur/token"
SERVICES_FILE="${HOME}/.config/zeabur/services.json"
GRAPHQL="https://api.zeabur.com/graphql"

[ -r "$TOKEN_FILE" ]    || { echo "Missing $TOKEN_FILE" >&2; exit 1; }
[ -r "$SERVICES_FILE" ] || { echo "Missing $SERVICES_FILE" >&2; exit 1; }

TOKEN=$(tr -d '[:space:]' < "$TOKEN_FILE")
[ -n "$TOKEN" ] || { echo "Empty token at $TOKEN_FILE" >&2; exit 1; }

SVC=$(jq --arg n "$SERVICE_NAME" '.[$n] // empty' "$SERVICES_FILE")
[ -n "$SVC" ] || { echo "Unknown service '$SERVICE_NAME'. Known: $(jq -r 'keys | join(", ")' "$SERVICES_FILE")" >&2; exit 1; }
SID=$(jq -r '.serviceId' <<<"$SVC")
EID=$(jq -r '.environmentId' <<<"$SVC")

gql() {
  curl -sS -X POST "$GRAPHQL" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    --data "$1"
}

LIST_Q='query($s:ObjectID!,$e:ObjectID!){deployments(serviceID:$s,environmentID:$e,perPage:1){edges{node{_id status commitSHA commitMessage createdAt}}}}'
GET_Q='query($id:ObjectID!){deployment(_id:$id){_id status finishedAt}}'
LOG_Q='query($id:ObjectID!){buildLogs(deploymentID:$id){message timestamp}}'

list_payload() {
  jq -nc --arg q "$LIST_Q" --arg s "$SID" --arg e "$EID" \
    '{query:$q,variables:{s:$s,e:$e}}'
}
get_payload() {
  jq -nc --arg q "$GET_Q" --arg id "$1" \
    '{query:$q,variables:{id:$id}}'
}
log_payload() {
  jq -nc --arg q "$LOG_Q" --arg id "$1" \
    '{query:$q,variables:{id:$id}}'
}

RESP=$(gql "$(list_payload)")
NODE=$(jq '.data.deployments.edges[0].node // empty' <<<"$RESP")
[ -n "$NODE" ] || { echo "No deployments found for $SERVICE_NAME. Raw response:" >&2; echo "$RESP" >&2; exit 1; }

DEP_ID=$(jq -r '._id' <<<"$NODE")
STATUS=$(jq -r '.status' <<<"$NODE")
COMMIT=$(jq -r '.commitSHA' <<<"$NODE" | cut -c1-7)
MSG=$(jq -r '.commitMessage' <<<"$NODE" | head -1)

echo "→ $SERVICE_NAME deployment $DEP_ID"
echo "→ commit $COMMIT: $MSG"
echo "→ status: $STATUS"

SUCCESS=" SUCCESS SUCCEEDED RUNNING ACTIVE DEPLOYED "
FAILED=" FAILED FAILURE ERROR CANCELLED CANCELED CRASHED "
is_terminal() { [[ "$1" == *" $2 "* ]]; }

extract_errors() {
  local logs msgs snippets
  logs=$(gql "$(log_payload "$1")")
  msgs=$(jq -r '.data.buildLogs[]?.message // empty' <<<"$logs")
  if [ -z "$msgs" ]; then
    echo "(no build log returned)"
    return
  fi
  snippets=$(echo "$msgs" | grep -iE '\b(FATAL|PANIC|ERROR|Exception|Traceback|build failed|Cannot find (module|name|package)|Module not found|non-zero exit|exit (code |status )?[1-9]|SyntaxError|TypeError|ReferenceError|EADDRINUSE|ECONNREFUSED|ETIMEDOUT)\b' | head -20 || true)
  if [ -n "$snippets" ]; then
    echo "$snippets"
  else
    echo "(no matched error lines — tailing last 30 log lines)"
    echo "$msgs" | tail -30
  fi
}

START=$(date +%s)
while true; do
  if is_terminal "$SUCCESS" "$STATUS"; then
    echo "✅ 部署成功（${SERVICE_NAME}, commit ${COMMIT}, status ${STATUS}）"
    exit 0
  fi
  if is_terminal "$FAILED" "$STATUS"; then
    echo "❌ 部署失敗（${SERVICE_NAME}, commit ${COMMIT}, status ${STATUS}）"
    echo "--- Build log error snippets ---"
    extract_errors "$DEP_ID"
    exit 2
  fi

  ELAPSED=$(( $(date +%s) - START ))
  if [ "$ELAPSED" -ge "$MAX_WAIT" ]; then
    echo "⏱  Timeout after ${MAX_WAIT}s (status still: $STATUS)" >&2
    exit 3
  fi

  sleep "$POLL_INTERVAL"
  RESP=$(gql "$(get_payload "$DEP_ID")")
  NEW=$(jq -r '.data.deployment.status // empty' <<<"$RESP")
  if [ -z "$NEW" ]; then
    echo "⚠  Empty status on poll, retrying…" >&2
    continue
  fi
  if [ "$NEW" != "$STATUS" ]; then
    echo "  [${ELAPSED}s] $STATUS → $NEW"
    STATUS=$NEW
  fi
done
