#!/usr/bin/env bash
# pipeline-lib.sh — shared reader for pipeline-steps.json
# Source this from guards / mark-done so the step list lives in ONE place.
#
# Provides:
#   pipeline_gate_steps <gate>        → space-separated canonical step keys for a gate (commit)
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

# Sets _PIPELINE_REPO_ROOT, computed once per process. Callers read the variable
# rather than `$(_pipeline_repo_root)` — a command substitution runs in a
# subshell, so the memo would never survive and every call would pay for git
# again (the first version of this did exactly that).
_pipeline_repo_root() {
  if [ -z "${_PIPELINE_REPO_ROOT+set}" ]; then
    _PIPELINE_REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
  fi
}

# Does this git understand the pathspec magic the docs-only rule is written in?
# `:(exclude)` and `:(glob)` need git >= 1.9. On an older git every pathspec
# below errors out, and code that reads "no output" as "no non-docs files" would
# hand out the exemption to a pure-code commit. Checked once per process.
_pipeline_pathspec_magic_ok() {
  if [ -z "${_PIPELINE_MAGIC_OK+set}" ]; then
    if git diff --cached --name-only -- ':(glob)**/*' ':(exclude)nothing' >/dev/null 2>&1; then
      _PIPELINE_MAGIC_OK=1
    else
      _PIPELINE_MAGIC_OK=0
    fi
  fi
  [ "$_PIPELINE_MAGIC_OK" = "1" ]
}

# pipeline_docs_only_exempt <gate> <label>
#   Returns 0 when this staged diff needs no markers at all: every path matches
#   docs_only.paths and none matches docs_only.instruction_paths, for a gate
#   listed in docs_only.gates. Prints the reason to stderr either way — a silent
#   skip is indistinguishable from a broken gate.
#
#   The exemption must also skip the evidence check, or it does not hold: a
#   `fix(docs): typo` message still demands a regression test and a stale .tests
#   marker still demands its evidence files. pipeline_enforce() owns that order
#   so no caller has to remember it.
#
#   No docs_only key (an older pipeline-steps.json) → never exempt.
pipeline_docs_only_exempt() {
  local gate="$1" label="${2:-pre-commit-pipeline}"
  _pipeline_require_json || return 1
  # The caller can say "this command reaches beyond the index, do not exempt"
  # (git commit -a / --amend / pathspec — see pre-commit-guard.sh).
  [ "${PIPELINE_NO_DOCS_EXEMPT:-}" = "1" ] && return 1

  # EVERY failure below returns 1 (no exemption). This function decides whether
  # to switch the gate OFF, so "the command errored" must never read as "found
  # nothing objectionable" — that is how a pure-code commit gets waved through.
  local jq_out jq_rc=0
  jq_out=$(jq -r '(.docs_only // {}) as $d
                  | ((($d.gates? // [])[] | ["gate", .]),
                     (($d.paths? // [])[] | ["doc", .]),
                     (($d.instruction_paths? // [])[] | ["instr", .]))
                  | map(if type == "string" then . else error("non-string pattern") end)
                  | @tsv' "$PIPELINE_STEPS_JSON" 2>/dev/null) || jq_rc=$?
  # A partial read is the dangerous one: @tsv aborts mid-stream on a bad element,
  # and if it died before the instruction patterns, the list looks empty.
  [ "$jq_rc" -eq 0 ] || return 1

  local -a docs_ps instr_ps
  local kind value gate_ok=0
  docs_ps=(); instr_ps=()
  while IFS=$'\t' read -r kind value; do
    case "$kind" in
      gate)  [ "$value" = "$gate" ] && gate_ok=1 ;;
      doc)   [ -n "$value" ] && docs_ps+=("$value") ;;
      instr) [ -n "$value" ] && instr_ps+=("$value") ;;
    esac
  done <<< "$jq_out"
  [ "$gate_ok" -eq 1 ] || return 1
  [ "${#docs_ps[@]}" -gt 0 ] || return 1

  _pipeline_repo_root
  local repo_root="$_PIPELINE_REPO_ROOT"
  [ -n "$repo_root" ] || return 1
  # An old git rejects every :(exclude)/:(glob) pathspec below; without this the
  # rejections all look like "nothing matched" and the gate turns itself off.
  _pipeline_pathspec_magic_ok || return 1

  # Ask the cheap question first: is there ANY staged path that is not docs?
  # One git call, and it answers the common case (a normal code commit) without
  # counting anything. `:(exclude)` is the same idiom the drift excludes use.
  local -a probe=(); local p
  for p in "${docs_ps[@]}"; do probe+=(":(exclude)$p"); done
  local non_docs git_rc=0
  non_docs=$(cd "$repo_root" && git -c core.quotePath=false diff --cached --name-only -- . "${probe[@]}" 2>/dev/null) || git_rc=$?
  [ "$git_rc" -eq 0 ] || return 1
  [ -z "$non_docs" ] || return 1
  # An empty staged diff is not a docs-only change; let the normal path handle it.
  local staged_any
  staged_any=$(cd "$repo_root" && git diff --cached --name-only 2>/dev/null) || return 1
  [ -n "$staged_any" ] || return 1

  local instr_files=""
  if [ "${#instr_ps[@]}" -gt 0 ]; then
    git_rc=0
    instr_files=$(cd "$repo_root" && git -c core.quotePath=false diff --cached --name-only -- "${instr_ps[@]}" 2>/dev/null) || git_rc=$?
    [ "$git_rc" -eq 0 ] || return 1
  fi
  if [ -z "$instr_files" ]; then
    echo "[$label] docs-only staged diff — gate skipped（沒有任何檔案落在 docs_only.paths 之外）" >&2
    return 0
  fi
  # Every path is docs-shaped, but some of it is the agent's own instructions,
  # which are code as far as this gate is concerned. Say which.
  {
    echo "[$label] 注意：這次不算純文件（所以不免審），因為這些檔屬於指令類"
    echo "（docs_only.instruction_paths）："
    printf '%s\n' "$instr_files" | head -5 | sed 's/^/  - /'
  } >&2
  return 1
}

# pipeline_enforce <gate> <label> [commit_msg]
#   The one entry point the guards call. Owns the ORDER — docs-only exemption,
#   then the marker gate, then the evidence check — so that "the exemption must
#   skip evidence too" is a property of this function instead of something three
#   separate guards have to remember. Returns 0 to allow, 1 to block; each guard
#   keeps its own exit code and its own follow-up advice.
#
#   evidence_gates (pipeline-steps.json) says where the evidence hard-check
#   applies — commit only, matching what the guards did before they shared an
#   entry point. Anything unreadable or not an array RUNS the check: the failure
#   direction has to be "check too much", or a typo in the config silently turns
#   the evidence rules off everywhere.
pipeline_enforce() {
  local gate="$1" label="${2:-pre-commit-pipeline}" msg="${3:-}" want=""
  pipeline_docs_only_exempt "$gate" "$label" && return 0
  pipeline_eval_gate "$gate" "$label" || return 1
  want=$(jq -r --arg g "$gate" \
    'if (.evidence_gates | type) == "array" then (if (.evidence_gates | index($g)) then "yes" else "no" end) else "yes" end' \
    "$PIPELINE_STEPS_JSON" 2>/dev/null || echo yes)
  [ "$want" = "no" ] || pipeline_check_evidence "$label" "$msg" || return 1
  return 0
}

# ISO-8601 (UTC, "...Z") → epoch seconds; echoes 0 on parse failure.
_pipeline_iso_to_epoch() {
  date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$1" +%s 2>/dev/null || echo 0
}

# Paths left out of both drift numbers, as git pathspecs. Defined in
# pipeline-steps.json so the knob lives with every other gate knob — the first
# version hardcoded `*.md` here, which blinded the gate to any repo whose
# product IS markdown (this one: SKILL.md, the plugin READMEs).
#
# No key → exclude nothing. A hardcoded fallback list was the second version and
# it immediately drifted: the JSON list was narrowed and this copy was not, so a
# steps.json without the key silently restored the hole the narrowing closed.
# One list, in the JSON; missing config is strict, like everything else here.
_pipeline_drift_excludes() {
  _pipeline_require_json || return 1
  jq -r '(.round_drift.exclude_paths? // [])[] | ":(exclude)" + .' "$PIPELINE_STEPS_JSON"
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
#   A gate pipeline-steps.json lists no steps for (a typo, or a config jq cannot
#   read) also returns 1 — checked first, before the not-a-git-repo early exit.
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

  # Both failures below block, never "nothing required". Before this check an
  # empty step list fell through: bash 3.2 under `set -u` died on the empty
  # "${required[@]}" further down with exit 1, which a PreToolUse hook treats as
  # allow (only exit 2 blocks), and without `set -u` the gate returned 0.
  # The steps are read into a variable first so a jq failure (truncated or
  # unreadable JSON) is reported as that, not as a misspelled gate name.
  local steps_out
  if ! steps_out=$(pipeline_gate_steps "$gate"); then
    echo "[$label] BLOCKED — cannot read gate steps from $PIPELINE_STEPS_JSON (see the jq error above)." >&2
    return 1
  fi
  local -a required missing stale_hash stale_time drift_over round_expired
  required=()
  while IFS= read -r s; do [ -n "$s" ] && required+=("$s"); done <<< "$steps_out"
  # ${#required[@]} itself is safe under `set -u` on bash 3.2.
  if [ "${#required[@]}" -eq 0 ]; then
    echo "[$label] BLOCKED — unknown gate '$gate': pipeline-steps.json lists no steps for it." >&2
    return 1
  fi

  local repo_root
  _pipeline_repo_root; repo_root="$_PIPELINE_REPO_ROOT"
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
  _pipeline_repo_root; repo_root="$_PIPELINE_REPO_ROOT"
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
