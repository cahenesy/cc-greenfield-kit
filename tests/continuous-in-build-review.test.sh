#!/usr/bin/env bash
# continuous-in-build-review.test.sh — eval for continuous in-build review
# (TDD 0020 / FR-56, FR-57, FR-59; ADR 0006).
#
# The contract under test (function-level; the runtime-verify gate re-drives the
# same observable surface against a real /implement run):
#   - the per-TDD fragment gains last_cleared_review_sha (string|null) and
#     cleared_step_log (array), threaded through _write_tdd_fragment and carried
#     forward by every fragment writer (FR-57 / ADR 0006).
#   - _record_cleared_step appends a {step_id, base_sha, head_sha, pattern_tags,
#     cleared_at} entry and advances last_cleared_review_sha atomically.
#   - the review prompt carries a "Scope of this pass" section anchored to the
#     SHA range and a "Prior addressed patterns" section (FR-59), interpolated by
#     the runner.
#   - the build/runner coprocess intercepts STEP_COMMIT: sentinels, runs a scoped
#     per-step review, and replies STEP_REVIEW: PASS|BLOCK on the build's stdin;
#     a sentinel-less build degrades to end-of-build review.
#
# Run: bash tests/continuous-in-build-review.test.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
IMPL="$REPO/scripts/implement.sh"
RESULTS="$(mktemp)"; export RESULTS
ok()   { printf 'ok\n'   >>"$RESULTS"; printf '  ok   — %s\n' "$1"; }
bad()  { printf 'fail\n' >>"$RESULTS"; printf '  FAIL — %s\n' "$1"; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT

# --- §4 / Data: cleared-step log + last-cleared-SHA fields -------------------
echo "[A1] _write_tdd_fragment writes last_cleared_review_sha + cleared_step_log (params 24-25)"
( D="$ROOT/A1"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  _write_tdd_fragment 0020-x 20 docs/tdd/0020-x.md 1 reviewing review \
    1000 1000 "feat/0020-x" "" "log" "" "" "" "" "" \
    "" "" "" "" \
    "" "" "" \
    "abc123" '[{"step_id":1,"base_sha":"aaa","head_sha":"abc123","pattern_tags":["t1"],"cleared_at":1000}]'
  F="$D/state.d/0020-x.json"
  grep -q '"last_cleared_review_sha":"abc123"' "$F" 2>/dev/null \
    && ok "last_cleared_review_sha round-trips" || bad "last_cleared_review_sha should round-trip (got: $(cat "$F"))"
  grep -q '"cleared_step_log":\[{"step_id":1,"base_sha":"aaa","head_sha":"abc123"' "$F" 2>/dev/null \
    && ok "cleared_step_log array round-trips" || bad "cleared_step_log should round-trip"
) || true

echo "[A2] _write_tdd_fragment defaults the new fields to null / [] when empty"
( D="$ROOT/A2"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  # The historical 23-arg (TDD 0019) call shape must still emit the new
  # defaults so old call sites keep working.
  _write_tdd_fragment 0001-a 1 docs/tdd/0001-a.md 1 pending "" \
    1000 1000 "" "" "" "" "" "" "" "" \
    "" "" "" "" \
    "" "" ""
  F="$D/state.d/0001-a.json"
  grep -q '"last_cleared_review_sha":null' "$F" 2>/dev/null \
    && ok "last_cleared_review_sha defaults to null" || bad "last_cleared_review_sha should default to null (got: $(cat "$F"))"
  grep -q '"cleared_step_log":\[\]' "$F" 2>/dev/null \
    && ok "cleared_step_log defaults to []" || bad "cleared_step_log should default to []"
) || true

echo "[A3] _read_fragment_field + _read_fragment_raw_array read the new fields"
( D="$ROOT/A3"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  F="$D/state.d/0020-x.json"
  printf '{"slug":"0020-x","last_cleared_review_sha":"deadbee","cleared_step_log":[{"step_id":2,"head_sha":"deadbee"}]}\n' > "$F"
  [ "$(_read_fragment_field "$F" last_cleared_review_sha)" = "deadbee" ] \
    && ok "reads last_cleared_review_sha" || bad "should read last_cleared_review_sha (got '$(_read_fragment_field "$F" last_cleared_review_sha)')"
  [ "$(_read_fragment_raw_array "$F" cleared_step_log)" = '[{"step_id":2,"head_sha":"deadbee"}]' ] \
    && ok "reads cleared_step_log array" || bad "should read cleared_step_log (got '$(_read_fragment_raw_array "$F" cleared_step_log)')"
) || true

echo "[A4] _record_cleared_step appends an entry and advances last_cleared_review_sha"
( D="$ROOT/A4"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  _write_tdd_fragment 0020-x 20 docs/tdd/0020-x.md 1 reviewing review \
    1000 1000 "feat/0020-x" "" "log" "" "" "" "" "" "" "" "" "" "" "" ""
  _record_cleared_step 0020-x 1 base000 head111 "tag-a,tag-b"
  F="$D/state.d/0020-x.json"
  grep -q '"last_cleared_review_sha":"head111"' "$F" 2>/dev/null \
    && ok "last_cleared_review_sha advanced to head111" || bad "last_cleared_review_sha should be head111 (got: $(_read_fragment_field "$F" last_cleared_review_sha))"
  grep -q '"step_id":1' "$F" 2>/dev/null \
    && ok "cleared_step_log entry records step_id" || bad "entry should record step_id (got: $(_read_fragment_raw_array "$F" cleared_step_log))"
  grep -q '"base_sha":"base000"' "$F" 2>/dev/null \
    && ok "entry records base_sha" || bad "entry should record base_sha"
  grep -q '"head_sha":"head111"' "$F" 2>/dev/null \
    && ok "entry records head_sha" || bad "entry should record head_sha"
  grep -q '"pattern_tags":\["tag-a","tag-b"\]' "$F" 2>/dev/null \
    && ok "entry records pattern_tags as a JSON array" || bad "entry should record pattern_tags array (got: $(_read_fragment_raw_array "$F" cleared_step_log))"
  # A second cleared step appends (does not overwrite) and re-advances the SHA.
  _record_cleared_step 0020-x 2 head111 head222 ""
  n="$(grep -oE '"step_id":[0-9]+' "$F" | wc -l)"
  [ "$n" -eq 2 ] && ok "second cleared step appends (two entries)" || bad "cleared_step_log should have two entries (got $n)"
  grep -q '"last_cleared_review_sha":"head222"' "$F" 2>/dev/null \
    && ok "last_cleared_review_sha re-advanced to head222" || bad "last_cleared_review_sha should be head222"
  grep -q '"step_id":2,"base_sha":"head111","head_sha":"head222","pattern_tags":\[\]' "$F" 2>/dev/null \
    && ok "empty pattern tags record as []" || bad "empty pattern_tags should be [] (got: $(_read_fragment_raw_array "$F" cleared_step_log))"
) || true

echo "[A5] set_tdd_state / set_tdd_meta carry the new fields forward"
( D="$ROOT/A5"; mkdir -p "$D/state.d"
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  _write_tdd_fragment 0020-x 20 docs/tdd/0020-x.md 1 reviewing review \
    1000 1000 "feat/0020-x" "" "log" "" "" "" "" "" \
    "" "" "" "" \
    "" "" "" \
    "ccc333" '[{"step_id":1,"base_sha":"a","head_sha":"ccc333","pattern_tags":[],"cleared_at":1}]'
  set_tdd_state 0020-x reviewing flip
  F="$D/state.d/0020-x.json"
  grep -q '"last_cleared_review_sha":"ccc333"' "$F" 2>/dev/null \
    && ok "last_cleared_review_sha survives set_tdd_state" || bad "last_cleared_review_sha must survive set_tdd_state"
  grep -q '"cleared_step_log":\[{"step_id":1' "$F" 2>/dev/null \
    && ok "cleared_step_log survives set_tdd_state" || bad "cleared_step_log must survive set_tdd_state"
  set_tdd_meta 0020-x "pr_url=http://x"
  grep -q '"last_cleared_review_sha":"ccc333"' "$F" 2>/dev/null \
    && ok "last_cleared_review_sha survives set_tdd_meta" || bad "last_cleared_review_sha must survive set_tdd_meta"
  grep -q '"cleared_step_log":\[{"step_id":1' "$F" 2>/dev/null \
    && ok "cleared_step_log survives set_tdd_meta" || bad "cleared_step_log must survive set_tdd_meta"
) || true

echo "[A6] set_halt_cause / _append_retry / _enter_paused carry the new fields forward"
( D="$ROOT/A6"; mkdir -p "$D/state.d"; cd "$D" || { bad "cd failed"; exit 0; }
  export STATE_DIR="$D/state.d" STATE_STARTED_AT=1000 STATE_MODE="sequential"
  export INTEGRATION="master" CHANGE="ci" LOGDIR="$D"
  TDDS=()
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL" || { bad "source guard missing"; exit 0; }
  _write_tdd_fragment 0020-x 20 docs/tdd/0020-x.md 1 blocked review \
    1000 1000 "feat/0020-x" "" "log" "" "" "" "" "" \
    "" "" "" "" \
    "" "" "" \
    "ddd444" '[{"step_id":1,"base_sha":"a","head_sha":"ddd444","pattern_tags":[],"cleared_at":1}]'
  F="$D/state.d/0020-x.json"
  set_halt_cause 0020-x rework-budget-exhausted "review:1"
  grep -q '"last_cleared_review_sha":"ddd444"' "$F" 2>/dev/null \
    && ok "last_cleared_review_sha survives set_halt_cause" || bad "last_cleared_review_sha must survive set_halt_cause"
  grep -q '"cleared_step_log":\[{"step_id":1' "$F" 2>/dev/null \
    && ok "cleared_step_log survives set_halt_cause" || bad "cleared_step_log must survive set_halt_cause"
  _append_retry 0020-x review 1 30
  grep -q '"last_cleared_review_sha":"ddd444"' "$F" 2>/dev/null \
    && ok "last_cleared_review_sha survives _append_retry" || bad "last_cleared_review_sha must survive _append_retry"
  _enter_paused 0020-x transient review "$D/p.log"
  grep -q '"cleared_step_log":\[{"step_id":1' "$F" 2>/dev/null \
    && ok "cleared_step_log survives _enter_paused" || bad "cleared_step_log must survive _enter_paused"
) || true

echo
PASS="$(grep -c '^ok$'   "$RESULTS" 2>/dev/null)"; PASS="${PASS:-0}"
FAIL="$(grep -c '^fail$' "$RESULTS" 2>/dev/null)"; FAIL="${FAIL:-0}"
rm -f "$RESULTS"
echo "=== continuous-in-build-review eval: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
