#!/usr/bin/env bash
# pipeline-lib.sh — shared reader for pipeline-steps.json
# Source this from guards / mark-done so the step list lives in ONE place.
#
# Provides:
#   pipeline_gate_steps <gate>        → space-separated canonical step keys for a gate (commit|ship)
#   pipeline_resolve_alias <input>    → canonical step key for an alias, or "" if unknown
#   pipeline_step_help <step> <mark>  → human help line ({MARK} replaced by <mark>), or "" if none
#   pipeline_step_binding <step>      → "round" or "content" (default)
#   pipeline_round_drift              → "<floor_lines> <ratio_percent> <max_lines>"
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

# "round" or "content". Anything the JSON does not list is content-bound, so a
# gate step added later is strict until someone deliberately loosens it.
pipeline_step_binding() {
  local step="$1"
  _pipeline_require_json || return 1
  jq -r --arg s "$step" '(.binding[$s] // "content")' "$PIPELINE_STEPS_JSON"
}

# Always three integers. A hand-edited "30.5" or "abc" would otherwise reach
# bash arithmetic and take the whole gate down with a syntax error, so anything
# that is not a whole number falls back to the default.
pipeline_round_drift() {
  _pipeline_require_json || return 1
  jq -r '(.round_drift // {}) as $d
         | def int(v; fallback): (v | tostring | test("^[0-9]+$")) as $ok
             | if $ok then (v | tonumber | floor) else fallback end;
           "\(int($d.floor_lines; 40)) \(int($d.ratio_percent; 30)) \(int($d.max_lines; 200))"' \
    "$PIPELINE_STEPS_JSON"
}

# ISO-8601 (UTC, "...Z") → epoch seconds; echoes 0 on parse failure.
_pipeline_iso_to_epoch() {
  date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$1" +%s 2>/dev/null || echo 0
}

# Paths left out of both drift numbers, as git pathspecs. Defined in
# pipeline-steps.json so the knob lives with every other gate knob — the first
# version hardcoded `*.md` here, which blinded the gate to any repo whose
# product IS markdown (this one: SKILL.md, the plugin READMEs). The defaults
# below only apply when the JSON omits the key.
_pipeline_drift_excludes() {
  _pipeline_require_json || return 1
  jq -r '((.round_drift.exclude_paths) // ["docs/**", "TODOS.md", "tasks/todo.md", "CHANGELOG.md"])[]
         | ":(exclude)" + .' "$PIPELINE_STEPS_JSON"
}

# Sum of numstat columns over the staged diff, excluding the paths above.
#   <repo> <cols: "1" for added only, "1 2" for added+removed> [base tree]
# With a base tree it answers "how much content appeared since that tree";
# without one, "how big is the staged diff". Echoes "" when git fails (a base
# tree that no longer exists), which the caller reads as "cannot vouch".
_pipeline_numstat_sum() {
  local repo="$1" cols="$2" base="${3:-}" out
  local -a excludes=()
  while IFS= read -r p; do [ -n "$p" ] && excludes+=("$p"); done < <(_pipeline_drift_excludes)
  # ${arr[@]+"${arr[@]}"} — /bin/bash here is 3.2, where expanding an EMPTY
  # array under `set -u` is an unbound-variable error, and every guard runs with
  # `set -euo pipefail`. An empty exclude_paths (the most natural way to say
  # "count everything") would otherwise crash the gate mid-evaluation.
  if [ -n "$base" ]; then
    out=$(cd "$repo" && git diff --cached --numstat "$base" -- . ${excludes[@]+"${excludes[@]}"} 2>/dev/null) || return 0
  else
    out=$(cd "$repo" && git diff --cached --numstat -- . ${excludes[@]+"${excludes[@]}"} 2>/dev/null) || return 0
  fi
  printf '%s\n' "$out" | awk -v cols="$cols" '
    { n = split(cols, c, " "); for (i = 1; i <= n; i++) if ($c[i] ~ /^[0-9]+$/) s += $c[i] }
    END { print s + 0 }'
}

# pipeline_eval_gate <gate> <label>
#   Evaluates the required steps for <gate> against the current staged diff and
#   .claude/pipeline-state.json in the current repo. Prints a BLOCKED report to
#   stderr and returns 1 when a marker is missing or no longer matches the
#   staged content. A marker older than 24h is only a soft WARN, not a block.
#
#   Two ways a marker satisfies the gate, chosen per step by `binding` in
#   pipeline-steps.json (content unless listed otherwise):
#
#   content — its staged_hash equals the current staged hash. This was the only
#     rule the gate had, and it deadlocked: the steps run in order, so acting on
#     a review finding changes the content AFTER simplify was ticked, expiring
#     it; re-running simplify can change it again and expire review. Whatever
#     runs last and touches anything wins, forever.
#
#   round — the same content match, OR: written in this round (first_marked_head
#     is the current HEAD, marker under 24h), with a LATER content-bound step in
#     the same gate matching the current hash, and with the content that step
#     never saw under the round_drift limit. The later step is what makes this
#     safe: review sits after simplify and did look at the final diff, so the
#     only thing unvouched-for is "was the post-review fix itself simplified",
#     and the drift cap bounds how much that can be.
#
#   <label> is the prefix shown in messages, e.g. "pre-commit-pipeline".
pipeline_eval_gate() {
  local gate="$1" label="${2:-pre-commit-pipeline}"
  _pipeline_require_json || return 1

  local repo_root
  repo_root=$(git rev-parse --show-toplevel 2>/dev/null || true)
  [ -z "$repo_root" ] && return 0  # not a git repo: let git itself decide

  local staged_hash now_epoch state_file mark_cmd cur_head
  staged_hash=$(cd "$repo_root" && bash "$_PIPELINE_LIB_DIR/compute-staged-hash.sh")
  now_epoch=$(date +%s)
  # --verify matters on an unborn branch: plain `git rev-parse HEAD` prints
  # "HEAD" to stdout AND exits 128, so both sides of the || run and the value
  # becomes the two-line string "HEAD\nno-head". Harmless while nothing read
  # this field; it is load-bearing now that round condition 1 compares it.
  cur_head=$(cd "$repo_root" && git rev-parse --verify --quiet HEAD 2>/dev/null || echo "no-head")
  state_file="$repo_root/.claude/pipeline-state.json"
  mark_cmd="bash ~/peter-claude-plugins/plugins/pre-commit-pipeline/scripts/pipeline-mark-done.sh"

  local -a required missing stale_hash stale_time drift_over round_expired
  required=()
  while IFS= read -r s; do [ -n "$s" ] && required+=("$s"); done < <(pipeline_gate_steps "$gate")

  local state="{}"
  [ -f "$state_file" ] && state=$(cat "$state_file")

  # Pass 1 — read every step's marker. Kept in index-aligned arrays because the
  # round rule asks about steps positioned AFTER the one being judged.
  local -a k_name k_state k_hash k_head k_tree k_bind k_epoch
  local step entry
  for step in "${required[@]}"; do
    local mhash="" mtime="" mfhead="" mtree="" mstate="ok" mepoch=0
    entry=$(echo "$state" | jq -c --arg s "$step" '.[$s] // null')
    if [ "$entry" = "null" ]; then
      mstate="missing"
    else
      mhash=$(echo "$entry" | jq -r '.staged_hash // ""')
      mtime=$(echo "$entry" | jq -r '.done_at // .verified_at // ""')
      mfhead=$(echo "$entry" | jq -r '.first_marked_head // ""')
      mtree=$(echo "$entry" | jq -r '.staged_tree // ""')
      # An entry carrying only a matching staged_hash — no done_at, no
      # verified_at — used to satisfy the gate: not missing and not stale. That
      # made a hand-written state file enough to clear the whole pipeline.
      # Treat a timestampless entry as absent.
      if [ -z "$mtime" ]; then
        mstate="missing"
      else
        mepoch=$(_pipeline_iso_to_epoch "$mtime")
      fi
    fi
    k_name+=("$step"); k_state+=("$mstate"); k_hash+=("$mhash")
    k_head+=("$mfhead"); k_tree+=("$mtree"); k_epoch+=("$mepoch")
    k_bind+=("$(pipeline_step_binding "$step")")
  done

  # Pass 2 — judge each step.
  local n=${#k_name[@]} i j age added total="" limit floor ratio cap later_ok
  for ((i = 0; i < n; i++)); do
    if [ "${k_state[$i]}" = "missing" ]; then missing+=("${k_name[$i]}"); continue; fi
    age=$((now_epoch - ${k_epoch[$i]}))
    if [ "${k_hash[$i]}" = "$staged_hash" ]; then
      # epoch 0 = the timestamp did not parse. It still only warns (blocking
      # here would make the gate stricter than before), but it is reported as
      # what it is instead of being folded into the ">24h" message.
      if [ "${k_epoch[$i]}" -eq 0 ]; then
        stale_time+=("${k_name[$i]}(時間戳解析失敗)")
      elif [ "$age" -gt 86400 ]; then
        stale_time+=("${k_name[$i]}")
      fi
      continue
    fi
    if [ "${k_bind[$i]}" != "round" ]; then stale_hash+=("${k_name[$i]}"); continue; fi

    # Round-bound and the content moved on. Every condition below must hold, and
    # each failure falls back to the strict hash rule (never looser than before).
    # The reason is carried into its own bucket: the "stale hash" advice (re-run
    # it, the formatter probably rewrote your files) is wrong for all of these.
    # An unparseable timestamp lands in the >24h branch on its own — epoch 0
    # makes age ~1.7e9 — so it needs no separate test here.
    if [ "${k_head[$i]}" != "$cur_head" ]; then
      round_expired+=("${k_name[$i]}|這個章屬於上一輪（蓋章時的 HEAD 已經不是現在的 HEAD）")
      continue
    fi
    if [ "$age" -gt 86400 ]; then
      round_expired+=("${k_name[$i]}|這個章超過 24 小時（或時間戳壞掉）")
      continue
    fi
    if [ -z "${k_tree[$i]}" ]; then
      round_expired+=("${k_name[$i]}|這個章沒有 staged_tree，算不出它之後改了多少（舊版 marker）")
      continue
    fi
    later_ok=0
    for ((j = i + 1; j < n; j++)); do
      if [ "${k_bind[$j]}" != "round" ] && [ "${k_hash[$j]}" = "$staged_hash" ]; then later_ok=1; break; fi
    done
    if [ "$later_ok" -eq 0 ]; then
      round_expired+=("${k_name[$i]}|它後面沒有對得上最終內容的步驟可以背書")
      continue
    fi
    added=$(_pipeline_numstat_sum "$repo_root" "1" "${k_tree[$i]}")
    if [ -z "$added" ]; then
      # Distinguish the two ways this fails. "gc'd" was the message for both,
      # which sent people off to re-run /simplify when the real problem was a
      # broken exclude_paths or a git too old for :(exclude).
      if (cd "$repo_root" && git rev-parse --verify --quiet "${k_tree[$i]}^{tree}" >/dev/null 2>&1); then
        round_expired+=("${k_name[$i]}|算不出變動量（tree 還在，但 git diff 失敗——檢查 round_drift.exclude_paths 與 git 版本）")
      else
        round_expired+=("${k_name[$i]}|staged_tree 已經不存在（被 git gc 清掉或值壞掉），算不出變動量")
      fi
      continue
    fi
    # Loop-invariant: the staged diff's size and the limit do not depend on the
    # step. Computed on the first round step that gets this far, then reused.
    if [ -z "$total" ]; then
      read -r floor ratio cap <<< "$(pipeline_round_drift)"
      total=$(_pipeline_numstat_sum "$repo_root" "1 2")
      limit=$((total * ratio / 100))
      [ "$limit" -lt "$floor" ] && limit=$floor
      [ "$limit" -gt "$cap" ] && limit=$cap
    fi
    if [ "$added" -gt "$limit" ]; then
      drift_over+=("${k_name[$i]}|$added|$limit")
    fi
  done

  if [ "${#missing[@]}" -eq 0 ] && [ "${#stale_hash[@]}" -eq 0 ] \
    && [ "${#drift_over[@]}" -eq 0 ] && [ "${#round_expired[@]}" -eq 0 ]; then
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
    local dname dreason dadded dlimit
    if [ "${#round_expired[@]}" -gt 0 ]; then
      echo "這些步驟的章無法對應到這一輪的最終內容，必須重跑："
      for step in "${round_expired[@]}"; do
        IFS='|' read -r dname dreason <<< "$step"
        echo "  - $dname: $dreason"
        echo "    → re-run $(pipeline_step_help "$dname" "$mark_cmd")"
      done
      echo ""
    fi
    if [ "${#drift_over[@]}" -gt 0 ]; then
      echo "這些步驟跑完後又改了太多，必須重跑："
      for step in "${drift_over[@]}"; do
        IFS='|' read -r dname dadded dlimit <<< "$step"
        echo "  - $dname: 之後新增 $dadded 行，上限 $dlimit 行（round_drift 的排除路徑不計）"
        echo "    → re-run $(pipeline_step_help "$dname" "$mark_cmd")"
      done
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
