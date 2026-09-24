#!/usr/bin/env bash
# pipeline-mark-done.sh — Claude 跑完 skill 後手動呼叫，寫 marker
# Usage: pipeline-mark-done.sh <step>
# Step: simplify | review | verify-tests | document-release | tidy-docs
set -euo pipefail

STEP="${1:-}"
if [ -z "$STEP" ]; then
  cat >&2 <<EOF
Usage: pipeline-mark-done.sh <step>
  step: simplify | review | verify-tests | document-release | tidy-docs
       regression --test "<test path / case>" | --skip "<reason>"
         (fix commits: writes .tests.regression.test / .skip_reason, the
          fields the fix-without-regression gate reads)
       repro --report <id> --path "<使用者描述/確認的重現路徑>" \
             (--spec tests/e2e/<x>.spec.ts | --probe .context/scratch/probe/<x>.json) \
             [--confirmed user|assumed]
         (bug fixes that come from a problem report: the gate then requires
          that spec to be new/modified in the staged diff, or that probe JSON
          to be pass=true and fresher than the staged files — no skip)
EOF
  exit 1
fi

# Step alias → marker key (single source: pipeline-steps.json via pipeline-lib.sh)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/pipeline-lib.sh"

# `regression` — the fix-commit regression-backfill fields. These previously
# had NO CLI: the gate demanded .tests.regression.test but nothing could write
# it, so agents reverse-engineered pipeline-lib.sh and hand-edited the state
# JSON with python (twice in the 2026-08 week audit). Not a gate step — no
# hash / timestamps involved; it annotates the existing tests entry.
if [ "$STEP" = "regression" ]; then
  MODE="${2:-}"
  VAL="${3:-}"
  if { [ "$MODE" != "--test" ] && [ "$MODE" != "--skip" ]; } || [ -z "$VAL" ]; then
    echo "Usage: pipeline-mark-done.sh regression --test \"<test path / case>\" | --skip \"<reason>\"" >&2
    exit 1
  fi
  REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
  if [ -z "$REPO_ROOT" ]; then
    echo "Not in a git repo — marker not written" >&2
    exit 1
  fi
  STATE_FILE="$REPO_ROOT/.claude/pipeline-state.json"
  mkdir -p "$REPO_ROOT/.claude"
  STATE='{}'
  [ -f "$STATE_FILE" ] && STATE=$(cat "$STATE_FILE")
  FIELD="test"
  [ "$MODE" = "--skip" ] && FIELD="skip_reason"
  echo "$STATE" | jq --arg v "$VAL" ".tests.regression.${FIELD} = \$v" > "$STATE_FILE"
  echo "✓ pipeline-mark-done regression — .tests.regression.${FIELD} set"
  exit 0
fi

# `repro` — a bug fix that answers a problem report must land with the
# user-described path as a test: an e2e spec touched in this diff, or (for
# external-source bugs) a live probe JSON. 2026-09-14: half of the period's
# fix commits shipped with unit tests only, and the one that started this
# gate had mocked away the very path the report described.
if [ "$STEP" = "repro" ]; then
  shift
  REPORT="" RPATH="" SPEC="" PROBE="" CONFIRMED="assumed"
  while [ $# -gt 0 ]; do
    case "$1" in
      --report|--path|--spec|--probe|--confirmed)
        [ $# -ge 2 ] || { echo "repro: $1 needs a value" >&2; exit 1; }
        case "$1" in
          --report) REPORT="$2" ;; --path) RPATH="$2" ;; --spec) SPEC="$2" ;;
          --probe) PROBE="$2" ;; --confirmed) CONFIRMED="$2" ;;
        esac
        shift 2 ;;
      *) echo "repro: unknown argument $1" >&2; exit 1 ;;
    esac
  done
  if [ -z "$REPORT" ] || [ -z "$RPATH" ] || { [ -z "$SPEC" ] && [ -z "$PROBE" ]; }; then
    echo "Usage: pipeline-mark-done.sh repro --report <id> --path \"<重現路徑>\" (--spec <e2e spec> | --probe <probe json>) [--confirmed user|assumed]" >&2
    exit 1
  fi
  case "$CONFIRMED" in user|assumed) ;; *) echo "repro: --confirmed must be user or assumed" >&2; exit 1 ;; esac
  REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
  [ -n "$REPO_ROOT" ] || { echo "Not in a git repo — marker not written" >&2; exit 1; }
  STATE_FILE="$REPO_ROOT/.claude/pipeline-state.json"
  mkdir -p "$REPO_ROOT/.claude"
  STATE='{}'
  [ -f "$STATE_FILE" ] && STATE=$(cat "$STATE_FILE")
  # `head` binds the marker to this change: the gates enforce it only while
  # that commit is an ancestor of HEAD and the spec has not been touched since
  # (so a fix that already landed, or a later unrelated session, is never
  # blocked by a stale marker). `regression.test` is set to the same artifact
  # so the fix-regression rule cannot be satisfied with an unrelated string.
  HEAD_NOW=$(git rev-parse HEAD 2>/dev/null || echo "")
  echo "$STATE" | jq --arg r "$REPORT" --arg p "$RPATH" --arg s "$SPEC" --arg pr "$PROBE" --arg c "$CONFIRMED" --arg h "$HEAD_NOW" \
    '.tests.repro = ({report_id: $r, path: $p, confirmed: $c, head: $h} + (if $s != "" then {spec: $s} else {} end) + (if $pr != "" then {probe: $pr} else {} end))
     | .tests.regression = {test: (if $s != "" then $s else ("live probe " + $pr) end)}' > "$STATE_FILE"
  echo "✓ pipeline-mark-done repro — .tests.repro set (report ${REPORT}, ${SPEC:+spec ${SPEC}}${PROBE:+probe ${PROBE}}, confirmed=${CONFIRMED})"
  exit 0
fi

KEY="$(pipeline_resolve_alias "$STEP")"
if [ -z "$KEY" ]; then
  echo "Unknown step: $STEP" >&2
  echo "Valid aliases: $(jq -r '.aliases | keys | join(" | ")' "$PIPELINE_STEPS_JSON")" >&2
  exit 1
fi

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
if [ -z "$REPO_ROOT" ]; then
  echo "Not in a git repo — marker not written" >&2
  exit 1
fi

# Stabilize the staged diff BEFORE hashing. The repo's pre-commit formatter
# (lint-staged / prettier) rewrites staged files DURING `git commit`, changing
# the staged hash mid-flight and invalidating every marker written here — the
# 2026-08 week audit counted 6/6 stale-hash blocks caused exactly this way.
# Running the same formatter now makes the commit-time pass a no-op, so the
# hash recorded below still matches when the gate re-checks it at commit time.
# Opt out with PIPELINE_NO_FORMAT=1.
if [ "${PIPELINE_NO_FORMAT:-}" != "1" ] && command -v npx >/dev/null 2>&1 \
  && [ -n "$(git diff --cached --name-only 2>/dev/null)" ]; then
  HAS_LS_CONFIG=0
  for f in .lintstagedrc .lintstagedrc.json .lintstagedrc.js .lintstagedrc.cjs \
    .lintstagedrc.mjs .lintstagedrc.yaml .lintstagedrc.yml \
    lint-staged.config.js lint-staged.config.cjs lint-staged.config.mjs; do
    [ -f "$REPO_ROOT/$f" ] && HAS_LS_CONFIG=1 && break
  done
  if [ "$HAS_LS_CONFIG" -eq 0 ] && [ -f "$REPO_ROOT/package.json" ] \
    && jq -e '."lint-staged" // empty' "$REPO_ROOT/package.json" >/dev/null 2>&1; then
    HAS_LS_CONFIG=1
  fi
  if [ "$HAS_LS_CONFIG" -eq 1 ]; then
    if ! (cd "$REPO_ROOT" && npx --no-install lint-staged >/dev/null 2>&1); then
      echo "note: pre-format via lint-staged failed/unavailable — the hash below may go stale if the commit-time formatter changes files" >&2
    fi
  fi
fi

STAGED_HASH=$(bash "$SCRIPT_DIR/compute-staged-hash.sh")
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# staged_tree — a snapshot of WHAT this step looked at, next to staged_hash's
# "whether it is still the same". The hash alone can only say identical/not, so
# a round-bound step (see `binding` in pipeline-steps.json) needs the tree to
# measure how far the content moved after it ran. `git write-tree` only writes
# objects out of the existing index; it does not touch the index or the working
# tree. It fails on an unmerged index (mid-conflict), and then the field is
# DELETED (not just skipped) below — leaving the previous round's tree next to
# a fresh staged_hash would describe two different contents, and the gate would
# measure drift against the wrong base instead of falling back to strict.
STAGED_TREE=$(git write-tree 2>/dev/null || echo "")

STATE_DIR="$REPO_ROOT/.claude"
STATE_FILE="$STATE_DIR/pipeline-state.json"
mkdir -p "$STATE_DIR"

STATE='{}'
if [ -f "$STATE_FILE" ] && [ -s "$STATE_FILE" ]; then
  STATE=$(cat "$STATE_FILE")
fi
# An empty (0-byte) state file used to feed jq an empty input: jq printed
# nothing, that nothing was written back over the file, and the script still
# reported success. The marker silently did not exist, which the gate then read
# as "step never ran" — or worse, wiped the .tests payload the evidence check
# depends on. Malformed (non-empty) JSON still fails the jq below, which is the
# right outcome: stop, keep the file, let the caller see the error.

# Ensure .gitignore has the marker file
GITIGNORE="$REPO_ROOT/.gitignore"
GITIGNORE_LINE=".claude/pipeline-state.json"
if [ ! -f "$GITIGNORE" ]; then
  echo "$GITIGNORE_LINE" > "$GITIGNORE"
elif ! grep -qxF "$GITIGNORE_LINE" "$GITIGNORE"; then
  [ -n "$(tail -c 1 "$GITIGNORE")" ] && echo "" >> "$GITIGNORE"
  echo "$GITIGNORE_LINE" >> "$GITIGNORE"
fi

# first_marked_at — the earliest tick of this step in the current round, carried
# over on a re-mark; first_marked_head is the HEAD at that moment, which is what
# delimits "the round" (a commit moves HEAD, so a mismatch means the timestamp
# belongs to a round that already ended).
#
# This used to be enforced with five subprocesses and a tamper check (refuse a
# parse failure, refuse a future timestamp, expire after 24h) because the gate's
# batch-tick rule read the field and a hand-edited value was a bypass. That rule
# is gone from this repo (see README), so the carry-over now fits in the merge
# expression below.
#
# Until the plugin cache is synced, the OLD gate in the cache copy still reads
# first_marked_at — but that copy runs its own future/parse/HEAD checks before
# trusting it, so repeating them here buys nothing. What it does lose is the 24h
# cap: a hand-written 25-hour-old timestamp now reaches the old gate and widens
# its spread enough to clear the batch check. That is a bypass of a rule this
# same change deletes, so it is accepted rather than carried forward.
# --verify: on an unborn branch plain `git rev-parse HEAD` prints "HEAD" to
# stdout before failing, so the field would become "HEAD\nno-head".
CUR_HEAD=$(git rev-parse --verify --quiet HEAD 2>/dev/null || echo "no-head")

# Merge (preserve other keys in the entry like decisions[] for tests)
NEW_STATE=$(echo "$STATE" | jq \
  --arg key "$KEY" \
  --arg done_at "$NOW" \
  --arg first_head "$CUR_HEAD" \
  --arg hash "$STAGED_HASH" \
  --arg tree "$STAGED_TREE" \
  '.[$key] as $prev
   | .[$key] = (($prev // {}) + {
       done_at: $done_at,
       first_marked_at: (if ($prev.first_marked_head // "") == $first_head
                         then ($prev.first_marked_at // $done_at) else $done_at end),
       first_marked_head: $first_head,
       staged_hash: $hash}
      + (if $tree != "" then {staged_tree: $tree} else {} end))
   | (if $tree == "" then del(.[$key].staged_tree) else . end)')

echo "$NEW_STATE" > "$STATE_FILE"
echo "✓ pipeline-mark-done $STEP — staged_hash=${STAGED_HASH:0:12}... at $NOW"
