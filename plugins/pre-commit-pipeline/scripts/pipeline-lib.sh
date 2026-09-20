#!/usr/bin/env bash
# pipeline-lib.sh — shared reader for pipeline-steps.json
# Source this from guards / mark-done so the step list lives in ONE place.
#
# Provides:
#   pipeline_gate_steps <gate>        → space-separated canonical step keys for a gate (commit|ship)
#   pipeline_resolve_alias <input>    → canonical step key for an alias, or "" if unknown
#   pipeline_step_help <step> <mark>  → human help line ({MARK} replaced by <mark>), or "" if none
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

# ISO-8601 (UTC, "...Z") → epoch seconds; echoes 0 on parse failure.
_pipeline_iso_to_epoch() {
  date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$1" +%s 2>/dev/null || echo 0
}

# pipeline_eval_gate <gate> <label>
#   Evaluates the required steps for <gate> against the current staged diff and
#   .claude/pipeline-state.json in the current repo. Prints a BLOCKED report to
#   stderr and returns 1 when a marker is missing or its staged hash no longer
#   matches. A marker older than 24h is only a soft WARN, not a block.
#
#   <label> is the prefix shown in messages, e.g. "pre-commit-pipeline".
pipeline_eval_gate() {
  local gate="$1" label="${2:-pre-commit-pipeline}"
  _pipeline_require_json || return 1

  local repo_root
  repo_root=$(git rev-parse --show-toplevel 2>/dev/null || true)
  [ -z "$repo_root" ] && return 0  # not a git repo: let git itself decide

  local staged_hash now_epoch state_file mark_cmd
  staged_hash=$(cd "$repo_root" && bash "$_PIPELINE_LIB_DIR/compute-staged-hash.sh")
  now_epoch=$(date +%s)
  state_file="$repo_root/.claude/pipeline-state.json"
  mark_cmd="bash ~/peter-claude-plugins/plugins/pre-commit-pipeline/scripts/pipeline-mark-done.sh"

  local -a required missing stale_hash stale_time
  required=()
  while IFS= read -r s; do [ -n "$s" ] && required+=("$s"); done < <(pipeline_gate_steps "$gate")

  local state="{}"
  [ -f "$state_file" ] && state=$(cat "$state_file")

  local step entry mhash mtime mepoch
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
    # An entry carrying only a matching staged_hash — no done_at, no verified_at
    # — used to satisfy the gate: not missing and not stale. That made a
    # hand-written state file enough to clear the whole pipeline. Treat a
    # timestampless entry as absent.
    if [ -z "$mtime" ]; then
      missing+=("$step"); continue
    fi
    # epoch 0 = the timestamp did not parse. It still only warns (blocking here
    # would make the gate stricter than before), but it is reported as what it
    # is instead of being folded into the ">24h" message.
    mepoch=$(_pipeline_iso_to_epoch "$mtime")
    if [ "$mepoch" -eq 0 ]; then
      stale_time+=("$step(時間戳解析失敗)")
    elif [ $((now_epoch - mepoch)) -gt 86400 ]; then
      stale_time+=("$step")
    fi
  done

  if [ "${#missing[@]}" -eq 0 ] && [ "${#stale_hash[@]}" -eq 0 ]; then
    [ "${#stale_time[@]}" -gt 0 ] && echo "[$label] WARN: markers older than 24h or with a bad timestamp: ${stale_time[*]}" >&2
    return 0
  fi

  {
    echo ""
    echo "[$label] BLOCKED — pipeline incomplete for staged diff:"
    echo "  staged_hash: ${staged_hash:0:12}..."
    echo ""
    if [ "${#missing[@]}" -gt 0 ]; then
      echo "Missing markers:"
      for step in "${missing[@]}"; do echo "  - run $(pipeline_step_help "$step" "$mark_cmd")"; done
      echo ""
    fi
    # The >24h warning is printed on the clean path too; repeating it here keeps
    # it from being swallowed whenever the gate blocks for another reason.
    if [ "${#stale_time[@]}" -gt 0 ]; then
      echo "Also: markers older than 24h or with a bad timestamp: ${stale_time[*]}"
      echo ""
    fi
    if [ "${#stale_hash[@]}" -gt 0 ]; then
      echo "Stale markers (staged diff changed since these ran):"
      for step in "${stale_hash[@]}"; do echo "  - re-run $(pipeline_step_help "$step" "$mark_cmd")"; done
      echo "(A stale hash DURING a commit usually means the pre-commit formatter rewrote"
      echo "staged files. pipeline-mark-done.sh now runs the formatter before hashing, so"
      echo "re-running the mark commands above stabilizes the hash — then commit again.)"
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

  # Evidence rules (2026-09-14 rewrite — the previous check only verified that
  # the field was non-empty, and a mock-only run pasted a plausible path):
  #   * every required kind must point at an existing non-empty file or
  #     directory (relative to the repo root, or absolute);
  #   * `live` (external-source probe JSON) is REQUIRED whenever a staged file
  #     matches docs/verification/config.yaml layers.external_sources.paths —
  #     derived here from the staged diff, never trusted from the marker — and
  #     the JSON must record pass=true with source/id and be newer than every
  #     matching staged file. A decisions[] entry {type:"live",status:"skipped",
  #     reason} waives it (printed as a NOTE so the reviewer sees it).
  local required
  required=$(jq -r 'if (.evidence_required|type) == "array" then .evidence_required[] else empty end' <<< "$entry")

  local config="$repo_root/docs/verification/config.yaml" live_hits=""
  if [ -f "$config" ] && grep -q 'external_sources' "$config"; then
    local py
    py=$(command -v /usr/bin/python3 || command -v python3 || true)
    [ -n "$py" ] && live_hits=$( (cd "$repo_root" && git diff --cached --name-only 2>/dev/null) | "$py" -c '
import re, sys
try:
    import yaml
except ImportError:
    sys.exit(0)
layer = (((yaml.safe_load(open(sys.argv[1], encoding="utf-8")) or {}).get("layers") or {}).get("external_sources") or {})
if not layer.get("enabled") or not layer.get("paths"):
    sys.exit(0)
def rx(g):
    g = re.escape(g)
    for pat, rep in (("\\*\\*/", "(?:.*/)?"), ("\\*\\*", ".*"), ("\\*", "[^/]*"), ("\\?", "[^/]")):
        g = g.replace(pat, rep)
    return re.compile("^" + g + "$")
pats = [rx(g) for g in layer["paths"]]
for line in sys.stdin.read().splitlines():
    if line and any(p.match(line) for p in pats):
        print(line)
' "$config" 2>/dev/null || true)
  fi
  if [ -n "$live_hits" ]; then
    local live_skip
    live_skip=$(jq -r '[(.decisions // [])[] | select(.type == "live" and .status == "skipped") | .reason // "no reason given"] | first // ""' <<< "$entry")
    if [ -n "$live_skip" ] && [ "$(jq -r '(.evidence // {}).live // ""' <<< "$entry")" = "" ]; then
      echo "[$label] NOTE — staged files reach external sources but the live probe was skipped: $live_skip" >&2
    else
      printf '%s\n' "$required" | grep -qx live || required="$required"$'\n'"live"
    fi
  fi

  local bad=() kind evidence_path resolved verdict f
  while IFS=$'\t' read -r kind evidence_path; do
    [ -n "$kind" ] || continue
    if [ -z "$evidence_path" ]; then
      if [ "$kind" = "live" ]; then
        bad+=("  - live: missing — staged files reach external sources:")
        while IFS= read -r f; do [ -n "$f" ] && bad+=("        $f"); done <<< "$live_hits"
        bad+=("    run the repo probe with the bug's own identifier (docs/verification/config.yaml layers.external_sources.runner) and record its JSON path in .tests.evidence.live, or add a decisions[] entry {type:\"live\",status:\"skipped\",reason}")
      else
        bad+=("  - $kind: missing")
      fi
      continue
    fi
    case "$evidence_path" in /*) resolved="$evidence_path" ;; *) resolved="$repo_root/$evidence_path" ;; esac
    if [ -d "$resolved" ]; then
      [ -n "$(ls -A "$resolved" 2>/dev/null)" ] || bad+=("  - $kind: $resolved (directory is empty)")
      continue
    fi
    if [ ! -f "$resolved" ] || [ ! -s "$resolved" ]; then
      bad+=("  - $kind: $resolved (file missing or empty; relative paths resolve from the repo root)")
      continue
    fi
    [ "$kind" = "live" ] || continue
    verdict=$(jq -r 'if type != "object" then "not a JSON object" elif .pass != true then "pass is not true — the probe did not get the expected result" elif ((.id // "") == "" or (.source // "") == "") then "missing source/id" else "ok" end' "$resolved" 2>/dev/null || echo "not JSON")
    if [ "$verdict" != "ok" ]; then
      bad+=("  - live: $resolved ($verdict)")
      continue
    fi
    local stale=""
    while IFS= read -r f; do
      [ -n "$f" ] && [ -e "$repo_root/$f" ] && [ "$repo_root/$f" -nt "$resolved" ] && stale="$stale $f"
    done <<< "$live_hits"
    [ -z "$stale" ] || bad+=("  - live: $resolved is older than staged file(s):$stale — rerun the probe after the last edit")
  done < <(jq -r --arg req "$required" '($req | split("\n") | map(select(. != ""))) as $kinds | .evidence // {} | . as $ev | $kinds[] | [., ($ev[.] // "")] | @tsv' <<< "$entry")

  if [ "${#bad[@]}" -gt 0 ]; then
    {
      echo ""
      echo "[$label] BLOCKED — evidence does not check out:"
      printf '%s\n' "${bad[@]}"
      echo "Evidence must be a real artifact produced by this change's verification (render 截圖 / runner 報告 / probe JSON), not a pasted path."
    } >&2
    return 1
  fi

  # A fix that answers a problem report (.tests.repro, written by
  # `pipeline-mark-done.sh repro` from the triage-report skill) must carry the
  # reported path as a test in THIS diff: the named e2e spec staged (new or
  # modified), or a live probe JSON that passed after the last staged edit.
  # There is deliberately no skip here — if the path cannot be automated the
  # agent has to come back and say so instead of committing.
  local repro_report repro_head
  repro_report=$(jq -r '.repro.report_id // ""' <<< "$entry")
  repro_head=$(jq -r '.repro.head // ""' <<< "$entry")
  # Only a live marker counts: its head must be an ancestor of HEAD (same
  # line of work). Commits after that head count as "this change" too, so a
  # fix that was already committed — or a WIP commit before it — is not asked
  # for the spec twice.
  if [ -n "$repro_report" ] && [ -n "$repro_head" ] && ! (cd "$repo_root" && git merge-base --is-ancestor "$repro_head" HEAD 2>/dev/null); then
    repro_report=""
  fi
  if [ -n "$repro_report" ] && [ -n "$msg" ] && printf '%s' "$msg" | grep -qEi '^fix([(:!]|$)'; then
    local repro_spec repro_probe repro_bad="" repro_changed
    repro_spec=$(jq -r '.repro.spec // ""' <<< "$entry")
    repro_probe=$(jq -r '.repro.probe // ""' <<< "$entry")
    repro_changed=$( (cd "$repo_root" && { git diff --cached --name-only; [ -n "$repro_head" ] && git diff --name-only "${repro_head}...HEAD"; } 2>/dev/null) | sort -u)
    if [ -n "$repro_spec" ]; then
      case "$repro_spec" in
        tests/e2e/*.spec.ts) ;;
        *) repro_bad="repro.spec must be a tests/e2e/*.spec.ts file, got: $repro_spec" ;;
      esac
      if [ -z "$repro_bad" ] && ! printf '%s\n' "$repro_changed" | grep -qxF "$repro_spec"; then
        repro_bad="repro.spec $repro_spec is not new or modified since the report was taken up (staged diff or commits after ${repro_head:0:9}) — the reported path has to be covered by THIS change"
      fi
    elif [ -n "$repro_probe" ]; then
      case "$repro_probe" in /*) resolved="$repro_probe" ;; *) resolved="$repo_root/$repro_probe" ;; esac
      if [ ! -s "$resolved" ] || ! jq -e '.pass == true and (.id // "") != ""' "$resolved" >/dev/null 2>&1; then
        repro_bad="repro.probe $repro_probe missing or not pass=true"
      else
        while IFS= read -r f; do
          [ -n "$f" ] && [ -e "$repo_root/$f" ] && [ "$repo_root/$f" -nt "$resolved" ] && repro_bad="repro.probe $repro_probe is older than staged file $f — rerun the probe after the last edit"
        done < <(cd "$repo_root" && git diff --cached --name-only 2>/dev/null)
      fi
    else
      repro_bad="repro has neither spec nor probe"
    fi
    if [ -n "$repro_bad" ]; then
      {
        echo ""
        echo "[$label] BLOCKED — fix for problem report ${repro_report} without its reproduction path as a test:"
        echo "  $repro_bad"
        echo "  path: $(jq -r '.repro.path // ""' <<< "$entry")"
        echo "  Add/extend the e2e spec for that path (or rerun the live probe) and record it with: pipeline-mark-done.sh repro --report ${repro_report} --path \"...\" --spec <file>"
      } >&2
      return 1
    fi
  fi

  if [ -n "$msg" ] && printf '%s' "$msg" | grep -qEi '^fix([(:!]|$)'; then
    local reg_ok
    reg_ok=$(jq -r 'if ((.regression.test // "") != "") or ((.regression.skip_reason // "") != "") then "ok" else "no" end' <<< "$entry")
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
