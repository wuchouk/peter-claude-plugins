#!/usr/bin/env bash
# pipeline-lib.sh — shared reader for pipeline-steps.json
# Source this from guards / mark-done so the step list lives in ONE place.
#
# Provides:
#   pipeline_gate_steps <gate>        → space-separated canonical step keys for a gate (commit|ship)
#   pipeline_resolve_alias <input>    → canonical step key for an alias, or "" if unknown
#   pipeline_step_help <step> <mark>  → human help line ({MARK} replaced by <mark>), or "" if none
#   pipeline_batch_window             → batch-tick window in seconds (C / anti-gaming)
#
# Resolution of the JSON path: <plugin_root>/pipeline-steps.json, where plugin_root
# is two levels up from this script (scripts/ -> plugin root).

_PIPELINE_LIB_SRC="${BASH_SOURCE[0]:-${0}}"
_PIPELINE_LIB_DIR="$(cd "$(dirname "$_PIPELINE_LIB_SRC")" && pwd)"
PIPELINE_STEPS_JSON="${PIPELINE_STEPS_JSON:-$(dirname "$_PIPELINE_LIB_DIR")/pipeline-steps.json}"

_pipeline_require_json() {
  if [ ! -f "$PIPELINE_STEPS_JSON" ]; then
    echo "pipeline-lib: missing $PIPELINE_STEPS_JSON" >&2
    return 1
  fi
}

pipeline_gate_steps() {
  local gate="$1"
  _pipeline_require_json || return 1
  jq -r --arg g "$gate" '.gates[$g][]? // empty' "$PIPELINE_STEPS_JSON"
}

pipeline_resolve_alias() {
  local input="$1"
  _pipeline_require_json || return 1
  jq -r --arg a "$input" '.aliases[$a] // ""' "$PIPELINE_STEPS_JSON"
}

pipeline_step_help() {
  local step="$1" mark="$2"
  _pipeline_require_json || return 1
  jq -r --arg s "$step" --arg m "$mark" '(.help[$s] // "") | gsub("\\{MARK\\}"; $m)' "$PIPELINE_STEPS_JSON"
}

pipeline_batch_window() {
  _pipeline_require_json || return 1
  jq -r '.batch_window_seconds // 5' "$PIPELINE_STEPS_JSON"
}

# ISO-8601 (UTC, "...Z") → epoch seconds; echoes 0 on parse failure.
_pipeline_iso_to_epoch() {
  date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$1" +%s 2>/dev/null || echo 0
}

# pipeline_eval_gate <gate> <label>
#   Evaluates the required steps for <gate> against the current staged diff and
#   .claude/pipeline-state.json in the current repo. Prints a BLOCKED report to
#   stderr and returns 1 if the pipeline is incomplete, stale, or gamed
#   (batch-ticked). Returns 0 (and only a soft WARN for >24h markers) if clean.
#
#   <label> is the prefix shown in messages, e.g. "pre-commit-pipeline".
pipeline_eval_gate() {
  local gate="$1" label="${2:-pre-commit-pipeline}"
  _pipeline_require_json || return 1

  local repo_root
  repo_root=$(git rev-parse --show-toplevel 2>/dev/null || true)
  [ -z "$repo_root" ] && return 0  # not a git repo: let git itself decide

  local staged_hash now_epoch state_file mark_cmd window
  staged_hash=$(cd "$repo_root" && bash "$_PIPELINE_LIB_DIR/compute-staged-hash.sh")
  now_epoch=$(date +%s)
  state_file="$repo_root/.claude/pipeline-state.json"
  mark_cmd="bash ~/peter-claude-plugins/plugins/pre-commit-pipeline/scripts/pipeline-mark-done.sh"
  window=$(pipeline_batch_window)

  local -a required missing stale_hash stale_time
  local -a fresh_epochs
  required=()
  while IFS= read -r s; do [ -n "$s" ] && required+=("$s"); done < <(pipeline_gate_steps "$gate")

  local state="{}"
  [ -f "$state_file" ] && state=$(cat "$state_file")

  local step entry mhash mtime mepoch age
  for step in "${required[@]}"; do
    entry=$(echo "$state" | jq -c --arg s "$step" '.[$s] // null')
    if [ "$entry" = "null" ]; then
      missing+=("$step"); continue
    fi
    mhash=$(echo "$entry" | jq -r '.staged_hash // ""')
    mtime=$(echo "$entry" | jq -r '.done_at // .verified_at // ""')
    if [ "$mhash" != "$staged_hash" ]; then
      stale_hash+=("$step"); continue
    fi
    if [ -n "$mtime" ]; then
      mepoch=$(_pipeline_iso_to_epoch "$mtime")
      fresh_epochs+=("$mepoch")
      age=$((now_epoch - mepoch))
      [ "$age" -gt 86400 ] && stale_time+=("$step")
    fi
  done

  # C — batch-tick detection: 2+ fresh markers whose done_at spread <= window
  # cannot reflect a real run (a genuine /review alone takes minutes).
  local batch_gamed=0 min_e max_e e
  if [ "${#fresh_epochs[@]}" -ge 2 ]; then
    min_e=${fresh_epochs[0]}; max_e=${fresh_epochs[0]}
    for e in "${fresh_epochs[@]}"; do
      [ "$e" -lt "$min_e" ] && min_e=$e
      [ "$e" -gt "$max_e" ] && max_e=$e
    done
    if [ $((max_e - min_e)) -le "$window" ]; then
      batch_gamed=1
    fi
  fi

  if [ "${#missing[@]}" -eq 0 ] && [ "${#stale_hash[@]}" -eq 0 ] && [ "$batch_gamed" -eq 0 ]; then
    [ "${#stale_time[@]}" -gt 0 ] && echo "[$label] WARN: markers older than 24h: ${stale_time[*]}" >&2
    return 0
  fi

  {
    echo ""
    echo "[$label] BLOCKED — pipeline incomplete for staged diff:"
    echo "  staged_hash: ${staged_hash:0:12}..."
    echo ""
    if [ "$batch_gamed" -eq 1 ]; then
      echo "Suspected batch-tick (markers written within ${window}s of each other — a real"
      echo "review/simplify cannot complete that fast). Run the steps for real, then mark."
      echo ""
    fi
    if [ "${#missing[@]}" -gt 0 ]; then
      echo "Missing markers:"
      for step in "${missing[@]}"; do echo "  - run $(pipeline_step_help "$step" "$mark_cmd")"; done
      echo ""
    fi
    if [ "${#stale_hash[@]}" -gt 0 ]; then
      echo "Stale markers (staged diff changed since these ran):"
      for step in "${stale_hash[@]}"; do echo "  - re-run $(pipeline_step_help "$step" "$mark_cmd")"; done
      echo ""
    fi
  } >&2
  return 1
}

# pipeline_check_evidence <label> [commit_msg]
#   Hard-checks the tests marker payload written by /verify-tests:
#   1. every key in .tests.evidence_required must have a non-empty .tests.evidence[key]
#   2. if commit_msg starts with "fix", .tests.regression.test or .regression.skip_reason must be non-empty
#   Returns 1 + BLOCKED report on stderr when violated. Missing marker/file is NOT
#   handled here (the gate itself already blocks that case).
pipeline_check_evidence() {
  local label="${1:-pre-commit-pipeline}" msg="${2:-}"
  local repo_root state_file entry
  repo_root=$(git rev-parse --show-toplevel 2>/dev/null || true)
  [ -z "$repo_root" ] && return 0
  state_file="$repo_root/.claude/pipeline-state.json"
  [ -f "$state_file" ] || return 0
  entry=$(jq -c '.tests // null' "$state_file" 2>/dev/null || echo null)
  [ "$entry" = "null" ] && return 0

  local missing_evidence
  missing_evidence=$(echo "$entry" | jq -r '. as $t | ($t.evidence_required // [])[] | select((($t.evidence // {})[.] // "") == "")')
  if [ -n "$missing_evidence" ]; then
    {
      echo ""
      echo "[$label] BLOCKED — evidence missing for required kinds:"
      echo "$missing_evidence" | sed 's/^/  - /'
      echo "Re-run /verify-tests and provide real evidence paths (render 證據 / 真實樣本結果)."
    } >&2
    return 1
  fi

  if [ -n "$msg" ] && printf '%s' "$msg" | grep -qEi '^fix([(:!]|$)'; then
    local reg_ok
    reg_ok=$(echo "$entry" | jq -r 'if ((.regression.test // "") != "") or ((.regression.skip_reason // "") != "") then "ok" else "no" end')
    if [ "$reg_ok" != "ok" ]; then
      {
        echo ""
        echo "[$label] BLOCKED — fix commit without regression backfill:"
        echo "  add a regression test for the bug (marker .tests.regression.test),"
        echo "  or record why it cannot be automated (.tests.regression.skip_reason)."
      } >&2
      return 1
    fi
  fi
  return 0
}
