#!/usr/bin/env bash
# gates.sh — Gate executors: build, review, runtime-verify, ci-checks.sh;
# result-sentinel parsers; install_deps; gated retry-loop wrappers.
#
# Extracted from scripts/implement.sh per TDD 0017 (Theme D slice 3/3, FR-69):
# the cluster that spawns `claude -p` for the build / review / runtime-verify
# gates, parses their result sentinels (BATCH_RESULT / REVIEW_RESULT /
# VERIFY_RUNTIME), runs ci-checks.sh, records the test-first + flip + blocker
# bookkeeping, installs worktree deps, and wraps each LLM gate for the in-gate
# retry loop. Every function here is a leaf called from the per-TDD inner loop
# (gate_one, in lib/resume.sh); the resume orchestration that calls them moves in
# the same slice.
#
# This module is SOURCED by implement.sh AFTER lib/state.sh and
# lib/pause-retry.sh, not executed: it calls helpers from both
# (record_session_pointer, set_tdd_state, _retry_in_gate, …) which are resolved
# at call time, so it sources standalone (top-level only declares functions). It
# shares the outer shell's scope for the variables the functions read ($MODEL,
# $REVIEW_MODEL, $TMPL, $RTMPL, $RVMTPL, $CI_CHECKS, $SDIR, $MAINREPO,
# $STATE_DIR, …), which the runner sets before these functions are called.
# Shared scope is deliberate for this dogfood slice, matching lib/state.sh.

# --- per-TDD primitives (cwd = the repo or worktree they run in) ---------------
build_one() {  # <tdd> <log>
  local tdd="$1" log="$2" prompt; prompt="$(sed "s#{{TDD}}#${tdd}#g" "$TMPL")"
  local args=(-p "$prompt" --permission-mode auto); [ -n "$MODEL" ] && args+=(--model "$MODEL")
  local start _rc; start=$(date +%s); _rc=0
  claude "${args[@]}" >>"$log" 2>&1; _rc=$?
  record_session_pointer "$log" "$start"
  # TDD 0019 / FR-68: record the original-build token spend on the fragment so
  # the rework-vs-original comparison is derivable from run-state alone. Reads
  # the same session JSONL record_session_pointer found; `null` when jq is
  # absent or no usage is present (acceptable — FR-68 is observability, not a
  # hard cap). Guarded so the SOURCE_ONLY test path (no fragment) is a no-op.
  if [ -n "${STATE_DIR:-}" ]; then
    local _slug; _slug="$(basename "$tdd" .md)"
    [ -f "$STATE_DIR/$_slug.json" ] && \
      _set_build_attempt_token_spend "$_slug" "$(_extract_token_spend "$(_last_session_path "$start")")"
  fi
  return "$_rc"   # TDD 0011 / BL-2: preserve claude's exit code (incl. signals like 143)
}
review_one() {  # <tdd> <base-ref> <log>
  local tdd="$1" base="$2" log="$3" prompt
  prompt="$(sed -e "s#{{TDD}}#${tdd}#g" -e "s#{{BASE}}#${base}#g" "$RTMPL")"
  local args=(-p "$prompt" --permission-mode auto); [ -n "$REVIEW_MODEL" ] && args+=(--model "$REVIEW_MODEL")
  local start _rc; start=$(date +%s); _rc=0
  claude "${args[@]}" >>"$log" 2>&1; _rc=$?
  record_session_pointer "$log" "$start"
  return "$_rc"   # TDD 0011 / BL-2: preserve claude's exit code
}
# Runtime-verify gate (FR-25 / FR-26 / ADR 0004): drives the BUILT artifact to
# the TDD's verification observation points in a FRESH `claude -p` process — so
# it is independent of the build's self-report regardless of model. Model is
# tiered by the verification plan's complexity (TDD 0013 / FR-52): mechanical
# observations (CLI exit code, log line grep, file presence, HTTP status code,
# etc.) run on `sonnet`; plans needing browser/UI driving, multi-step interactive
# flows, or judgment about ambiguous output run on the build `$MODEL`. The env
# `THROUGHLINE_RUNTIME_VERIFY_MODEL` pins a model unconditionally (matching the
# `--review-model` / `THROUGHLINE_REVIEW_MODEL` escape hatch). If the classifier
# helper is missing on disk (e.g. partial install), fall back to `$MODEL` and
# note the missing classifier in the gate log — no correctness regression, just
# no token saving for that run. cwd is the build worktree with deps installed
# by `install_deps`. The {{BASE}} substitution scopes the diff so the verifier
# can SEE which change to focus its observation on; it orients the verifier, it
# does not gate on the diff. The verdict is parsed from the transcript
# (`VERIFY_RUNTIME: ...`), exactly as build's `BATCH_RESULT:` and review's
# `REVIEW_RESULT:` already are.
verify_runtime_one() {  # <tdd> <base-ref> <log>
  local tdd="$1" base="$2" log="$3" prompt cls vm classifier note=""
  prompt="$(sed -e "s#{{TDD}}#${tdd}#g" -e "s#{{BASE}}#${base}#g" "$RVMTPL")"
  # Model tiering (FR-52). The env override always wins.
  vm="${THROUGHLINE_RUNTIME_VERIFY_MODEL:-}"
  # The classifier lives beside this module in lib/. With SDIR set (a normal run)
  # it is $SDIR/lib/plan-classifier.sh; with SDIR unset (the SOURCE_ONLY test
  # path) resolve it relative to THIS file's own directory. TDD 0017 / FR-69: the
  # move from implement.sh into lib/gates.sh changed ${BASH_SOURCE[0]} from
  # scripts/ to scripts/lib/, so the fallback must NOT re-append lib/ — gates.sh
  # already lives in lib/, where plan-classifier.sh is its sibling.
  classifier="${SDIR:+$SDIR/lib/plan-classifier.sh}"
  [ -z "$classifier" ] && classifier="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/plan-classifier.sh"
  # M3 (review pass): capture the classifier's exit code and attach a
  # distinguishing note when it fails. The previous form silently fell
  # through to plan=nontrivial on classifier error — the gate log line
  # was IDENTICAL to a genuine nontrivial classification, so a triage
  # could not tell a crashed classifier from a deliberate choice. The
  # `(classifier failed, rc=N)` annotation preserves NFR-4 honesty.
  # MAJ-1 (review pass 3): the classifier's stderr is redirected to the
  # gate log (`2>>"$log"`) rather than silenced. With BL-1/BL-2 fixed so
  # the classifier itself surfaces awk crashes as rc≠0 + stderr, the log
  # capture preserves the only externally-observable signal of what went
  # wrong for triage — `2>/dev/null` would have erased it.
  #
  # MAJ-2 (review pass 3): the env-pinned branch now applies the same
  # `case` guard for unexpected classifier output as the unpinned branch,
  # sanitizing any non-{mechanical, nontrivial} value to `nontrivial`
  # with a distinguishing note. Without this guard a misbehaving
  # classifier could propagate arbitrary text into the `plan=<x>` log
  # line, polluting the FR-36 observability surface.
  local cls_rc
  if [ -z "$vm" ]; then
    if [ -f "$classifier" ]; then
      # shellcheck source=/dev/null
      . "$classifier"
      cls="$(tl_classify_plan "$tdd" 2>>"$log")"; cls_rc=$?
      if [ "$cls_rc" -ne 0 ] || [ -z "$cls" ]; then
        vm="$MODEL"; cls="nontrivial"; note=" (classifier failed, rc=$cls_rc)"
      else
        case "$cls" in
          mechanical) vm="sonnet" ;;
          nontrivial) vm="$MODEL" ;;
          *)          vm="$MODEL"; note=" (classifier returned unexpected '$cls', defaulted nontrivial)"; cls="nontrivial" ;;
        esac
      fi
    else
      vm="$MODEL"; cls="nontrivial"; note=" (classifier missing)"
    fi
  else
    # Env-pinned: still classify for the observability line (so triage knows
    # what the heuristic *would* have picked), but the pin wins.
    if [ -f "$classifier" ]; then
      # shellcheck source=/dev/null
      . "$classifier"
      cls="$(tl_classify_plan "$tdd" 2>>"$log")"; cls_rc=$?
      if [ "$cls_rc" -ne 0 ] || [ -z "$cls" ]; then
        cls="nontrivial"; note=" (classifier failed, rc=$cls_rc)"
      else
        case "$cls" in
          mechanical|nontrivial) : ;;  # accept the heuristic's choice for the log line
          *)
            note=" (classifier returned unexpected '$cls', defaulted nontrivial)"
            cls="nontrivial"
            ;;
        esac
      fi
    else
      cls="nontrivial"; note=" (classifier missing)"
    fi
  fi
  printf 'runtime-verify model=%s (plan=%s)%s\n' "$vm" "$cls" "$note" >> "$log"
  local args=(-p "$prompt" --permission-mode auto)
  [ -n "$vm" ] && args+=(--model "$vm")
  local start _rc; start=$(date +%s); _rc=0
  claude "${args[@]}" >>"$log" 2>&1; _rc=$?
  record_session_pointer "$log" "$start"
  return "$_rc"   # TDD 0011 / BL-2: preserve claude's exit code
}
build_status()          { grep -aoE 'BATCH_RESULT: (OK|FAIL.*|BLOCKED.*)' "$1" 2>/dev/null | tail -1; }
review_status()         { grep -aoE 'REVIEW_RESULT: (PASS|BLOCK.*)' "$1" 2>/dev/null | tail -1; }
verify_runtime_status() { grep -aoE 'VERIFY_RUNTIME: (PASS|FAIL.*|BLOCKED.*|SKIP.*)' "$1" 2>/dev/null | tail -1; }
run_ci_checks()    { bash "$CI_CHECKS" >>"$1" 2>&1; }
# test-first gate: mechanical, git-history only. The build must show failing-test-
# first discipline — a dedicated `test(failing): ...` commit BEFORE the impl —
# unless it emits `TEST_FIRST: SKIPPED` for a genuine no-new-behavior change. The
# independent review gate judges test QUALITY; this just proves the order existed.
test_first_ok() {  # <base-ref> <log>
  [ "${THROUGHLINE_REQUIRE_TEST_FIRST:-1}" = "1" ] || return 0
  local base="$1" log="$2"
  grep -aqE 'TEST_FIRST:[[:space:]]*SKIPPED' "$log" && return 0
  git log --format='%s' "$base..HEAD" 2>/dev/null | grep -qiE '^test\(failing\)' && return 0
  return 1
}
flip_status() {  # <tdd> <log>
  local tdd="$1" log="$2"
  sed -i.bak -E 's/^Status:[[:space:]]*(draft|ready)/Status: implemented/' "$tdd" && rm -f "$tdd.bak"
  git add "$tdd" >>"$log" 2>&1
  git commit -m "mark $(basename "$tdd" .md) implemented (verified + reviewed)" >>"$log" 2>&1
}
record_blocker() {  # <tdd> <reason>  -> append to the main repo's blocker ledger
  local tdd="$1" reason="$2" bf="${MAINREPO:-$PWD}/docs/tdd/BLOCKERS.md"
  mkdir -p "$(dirname "$bf")"
  [ -f "$bf" ] || printf '# Implementation blockers\n\n> Design-level blockers raised by /implement. Resolve via /tdd-author, then delete the entry.\n\n' > "$bf"
  printf -- '- [ ] **%s** (%s): %s\n' "$(basename "$tdd")" "$(date +%Y-%m-%d)" "$reason" >> "$bf"
}

# install_deps: a fresh worktree does NOT carry gitignored, uncommitted state —
# most importantly node_modules — so a JS/TS build can't run its tests/typecheck
# and ci-checks.sh fails until deps are installed. Install them once per worktree,
# before building, using the project's package manager. No-ops for non-JS repos
# (and other ecosystems that fetch on build, e.g. cargo/go); skip with
# THROUGHLINE_SKIP_DEPS=1. cwd must be the worktree.
install_deps() {  # <log>
  [ "${THROUGHLINE_SKIP_DEPS:-0}" = "1" ] && return 0
  [ -f package.json ] || return 0
  local log="$1" pm cmd
  if   [ -f pnpm-lock.yaml ];   then pm=pnpm; cmd="pnpm install --frozen-lockfile"
  elif [ -f yarn.lock ];        then pm=yarn; cmd="yarn install --immutable"
  elif [ -f bun.lockb ] || [ -f bun.lock ]; then pm=bun; cmd="bun install --frozen-lockfile"
  elif [ -f package-lock.json ]; then pm=npm; cmd="npm ci"
  else pm=npm; cmd="npm install"; fi
  if ! command -v "$pm" >/dev/null 2>&1; then
    echo "install_deps: $pm not found on PATH; skipping (build will likely fail at verify)" >>"$log"; return 0
  fi
  echo "install_deps: $cmd" >>"$log"
  # Fall back to a plain install if the locked/frozen form fails (e.g. a lockfile
  # that's out of sync) so a build isn't blocked by a lock mismatch.
  sh -c "$cmd" >>"$log" 2>&1 || sh -c "$pm install" >>"$log" 2>&1 \
    || echo "install_deps: dependency install failed; build may fail at verify" >>"$log"
}

# --- gate-call wrappers used by _retry_in_gate (TDD 0011 / FR-42) ------------
# _retry_in_gate calls a gate-fn that returns 0 on success, non-zero on retry-
# eligible failure. The raw build_one / verify_runtime_one / review_one print
# to the log and don't return a useful exit code; these adapters parse the
# log's verdict line and convert it.
# TDD 0011 / BL-2: forward claude's actual exit code so _retry_in_gate's
# _classify_cause can see signals (143 SIGTERM → transient, 137 SIGKILL →
# fatal). The verdict in the log is the success signal; on non-zero exit
# the raw rc is what classifies the cause. Order: if exit was non-zero,
# return it (preserves signal); else if verdict is good, return 0; else
# return 1 (generic non-signal failure).
_build_one_gated() {  # <tdd> <log>
  local tdd="$1" log="$2" bs _rc
  build_one "$tdd" "$log"; _rc=$?
  [ "$_rc" -ne 0 ] && return "$_rc"
  bs="$(build_status "$log")"
  case "$bs" in *OK*) return 0 ;; esac
  return 1
}
_verify_runtime_one_gated() {  # <tdd> <rbase> <log>
  local tdd="$1" rbase="$2" log="$3" rvs _rc
  verify_runtime_one "$tdd" "$rbase" "$log"; _rc=$?
  [ "$_rc" -ne 0 ] && return "$_rc"
  rvs="$(verify_runtime_status "$log")"
  case "$rvs" in *PASS*|*SKIP*) return 0 ;; esac
  return 1
}
_review_one_gated() {  # <tdd> <rbase> <log>
  local tdd="$1" rbase="$2" log="$3" rs _rc
  review_one "$tdd" "$rbase" "$log"; _rc=$?
  [ "$_rc" -ne 0 ] && return "$_rc"
  rs="$(review_status "$log")"
  case "$rs" in *PASS*) return 0 ;; esac
  return 1
}

# === Bounded rework loop (TDD 0019 / FR-61, FR-62, FR-65, FR-66, FR-67) ========
# The leaf functions the gate_one review gate drives when a review pass emits a
# halting finding. _rework_one performs one bounded fix attempt on Sonnet;
# _rework_pre_pass runs the mechanical FR-66 scope cap + FR-67(a)/(b) structural
# checks against the rework commit's diff. All bounds are env-overridable (§6)
# and snapshotted into run.json (_rework_config_json) so any halt is
# reproducible from run-state alone (ADR 0006).

# _rework_scope_cap <region-lines>  — echo the FR-66 cap = max(FLOOR,
# FACTOR × region). An empty/non-numeric region collapses to the floor (the
# pre-TDD-0021 degraded mode, before findings carry region_lines).
_rework_scope_cap() {  # <region-lines>
  local region="${1:-}"
  local floor="${THROUGHLINE_REWORK_SCOPE_FLOOR:-60}"
  local factor="${THROUGHLINE_REWORK_SCOPE_FACTOR:-3}"
  case "$floor"  in ''|*[!0-9]*) floor=60 ;; esac
  case "$factor" in ''|*[!0-9]*) factor=3 ;; esac
  case "$region" in ''|*[!0-9]*) region=0 ;; esac
  local scaled=$((factor * region))
  if [ "$scaled" -gt "$floor" ]; then printf '%s' "$scaled"; else printf '%s' "$floor"; fi
}

# _rework_touched_files <tdd>  — echo the declared touched-file set (one path
# per line) parsed from the TDD's `## Touched files` section (TDD 0014). Each
# entry is the first backtick-delimited token on a `- ` bullet. Fence-aware so a
# code block inside the section is ignored. Mirrors tdd-lint.sh's parser.
_rework_touched_files() {  # <tdd>
  local f="$1"
  [ -f "$f" ] || return 0
  awk '
    BEGIN { in_fence=0; in_sec=0 }
    /^[[:space:]]*```/ { in_fence = !in_fence; next }
    !in_fence && /^## Touched files[[:space:]]*$/ { in_sec=1; next }
    !in_fence && /^## / { in_sec=0; next }
    in_sec && !in_fence && /^- / {
      if (match($0, /`[^`]+`/)) print substr($0, RSTART+1, RLENGTH-2)
    }
  ' "$f"
}

# _rework_file_declared_bound <tdd> <file>  — echo "<lines> <exception?>" for
# <file>'s entry in the TDD's `## Expected diff size` section (TDD 0014), where
# <exception?> is 1 if an inline `(exception: …)` marker is present, else 0.
# Echoes nothing when the file is not declared; <lines> is -1 when the estimate
# is unparseable. Mirrors tdd-lint.sh check_per_file_diff_bound's awk.
_rework_file_declared_bound() {  # <tdd> <file>
  local f="$1" target="$2"
  [ -f "$f" ] || return 0
  awk -v TARGET="$target" '
    BEGIN { in_fence=0; in_sec=0 }
    /^[[:space:]]*```/ { in_fence = !in_fence; next }
    !in_fence && /^## Expected diff size[[:space:]]*$/ { in_sec=1; next }
    !in_fence && /^## / { in_sec=0; next }
    in_sec && !in_fence && /^- / {
      rest = substr($0, 3)
      em = index(rest, "—")
      if (em > 0) { file = substr(rest, 1, em - 1) }
      else        { file = rest; sub(/[[:space:]].*/, "", file) }
      gsub(/`/, "", file)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", file)
      if (file == TARGET) {
        n = -1
        if (match(rest, /[0-9]+[[:space:]]*lines?/)) {
          num = substr(rest, RSTART, RLENGTH); sub(/[^0-9].*/, "", num); n = num + 0
        }
        exc = (index(rest, "(exception:") > 0) ? 1 : 0
        printf "%d %d\n", n, exc
        exit
      }
    }
  ' "$f"
}

# _rework_pre_pass <slug> <tdd> <new-head> <cleared-sha> <build-start-sha> <region-lines>
# Run the three mechanical checks against the rework commit's diff. Emits one
# `PRECHECK_FAIL: …` line per fired check (priority order: scope, then (a), then
# (b) — the caller routes on the first line) and returns non-zero if any fired.
#   FR-66 scope cap — total insertion+deletion over <cleared>..<new-head> vs
#     max(FLOOR, FACTOR × region).
#   FR-67(a) — any file in the diff outside the TDD's `## Touched files` set.
#   FR-67(b) — any touched file whose cumulative <build-start>..<new-head> line
#     count exceeds its `## Expected diff size` declaration (exception markers
#     honored).
# §Failure modes §5 / §Sequencing step 3: when <cleared-sha> is empty (TDD 0020
# not yet landed), the scope/membership diff base falls back to <build-start-sha>
# — a degraded but safe mode (bounds checked against the full TDD diff).
_rework_pre_pass() {  # <slug> <tdd> <new-head> <cleared-sha> <build-start-sha> <region-lines>
  local slug="$1" tdd="$2" new_head="$3" cleared="$4" build_start="$5" region="$6"
  local base="$cleared"; [ -z "$base" ] && base="$build_start"
  local fail=0 file

  # FR-66 scope cap.
  local cap span
  cap="$(_rework_scope_cap "$region")"
  span="$(git diff --numstat "$base..$new_head" 2>/dev/null | awk '{a+=$1; d+=$2} END{print a+d+0}')"
  [ -z "$span" ] && span=0
  if [ "$span" -gt "$cap" ] 2>/dev/null; then
    printf 'PRECHECK_FAIL: rework-scope-exceeded %s > %s\n' "$span" "$cap"
    fail=1
  fi

  # FR-67(a) touched-file scope.
  local set_list
  set_list="$(_rework_touched_files "$tdd")"
  while IFS= read -r file; do
    [ -z "$file" ] && continue
    if ! printf '%s\n' "$set_list" | grep -qxF "$file"; then
      printf 'PRECHECK_FAIL: structural-finding(a) %s\n' "$file"
      fail=1
    fi
  done < <(git diff --name-only "$base..$new_head" 2>/dev/null)

  # FR-67(b) per-file bound — cumulative since the build start (per §1).
  local decl num exc actual
  while IFS= read -r file; do
    [ -z "$file" ] && continue
    decl="$(_rework_file_declared_bound "$tdd" "$file")"
    [ -z "$decl" ] && continue          # not declared → (a)'s concern, not (b)'s
    num="${decl%% *}"; exc="${decl##* }"
    [ "$exc" = "1" ] && continue        # declared exception → bound not enforced
    [ "$num" -lt 0 ] 2>/dev/null && continue   # unparseable estimate → skip (b)
    actual="$(git diff --numstat "$build_start..$new_head" -- "$file" 2>/dev/null | awk '{a+=$1; d+=$2} END{print a+d+0}')"
    [ -z "$actual" ] && actual=0
    if [ "$actual" -gt "$num" ] 2>/dev/null; then
      printf 'PRECHECK_FAIL: structural-finding(b) %s %s > %s\n' "$file" "$actual" "$num"
      fail=1
    fi
  done < <(git diff --name-only "$base..$new_head" 2>/dev/null)

  return "$fail"
}

# _rework_one <tdd> <log> <finding-ref> <finding-text> <cap>
# Spawn ONE bounded rework attempt on the rework model (Sonnet by default —
# cheaper and less prone to opportunistic refactoring than Opus; §Approach /
# NFR-3). Substitutes the finding, the declared touched-file set, and the
# computed scope cap into the rework prompt template, runs `claude -p` to make
# and commit the fix, records the FR-36 session pointer, and echoes the new HEAD
# SHA so the caller can run _rework_pre_pass against the commit. cwd is the build
# worktree. The rework `claude` is responsible for committing its edit with a
# `rework:` message (per the template); _rework_one does not commit on its
# behalf — an empty diff is detected by the caller's pre-pass.
_rework_one() {  # <tdd> <log> <finding-ref> <finding-text> <cap>
  local tdd="$1" log="$2" finding_ref="$3" finding_text="$4" cap="$5"
  local rm="${THROUGHLINE_REWORK_MODEL:-sonnet}"
  # Resolve the template: $RWTMPL on a normal run; else relative to this
  # module (gates.sh lives in scripts/lib/, rework-prompt.md in scripts/) so
  # the SOURCE_ONLY test path resolves it without the implement.sh setup block.
  local tmpl="${RWTMPL:-}"
  [ -z "$tmpl" ] && tmpl="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/rework-prompt.md"
  if [ ! -f "$tmpl" ]; then
    echo "error: _rework_one: rework prompt template not found ($tmpl)" >&2
    return 1
  fi
  local touched_block prompt
  touched_block="$(_rework_touched_files "$tdd" | sed 's/^/  - /')"
  # Literal placeholder substitution via bash parameter expansion (safe for the
  # finding text's `/`, `#`, and newlines, which would break sed delimiters).
  prompt="$(cat "$tmpl")"
  prompt="${prompt//\{\{TDD\}\}/$tdd}"
  prompt="${prompt//\{\{FINDING\}\}/[$finding_ref] $finding_text}"
  prompt="${prompt//\{\{CAP\}\}/$cap}"
  prompt="${prompt//\{\{TOUCHED_FILES\}\}/$touched_block}"
  local args=(-p "$prompt" --permission-mode auto)
  [ -n "$rm" ] && args+=(--model "$rm")
  local start; start=$(date +%s)
  claude "${args[@]}" >>"$log" 2>&1
  record_session_pointer "$log" "$start"
  git rev-parse HEAD 2>/dev/null
}

# _rework_extract_finding <review-log>  — set RWK_STRUCTURAL / RWK_REGION /
# RWK_REF / RWK_TEXT for the FIRST halting finding in the review output. TDD 0021
# adds a structured `REVIEW_FINDING: severity=… structural=… region_lines=… ref=…
# | <text>` line per finding; this consumes it. Pre-TDD-0021 the review prompt
# emits no such marker, so the loop degrades safely: structural=0 (no predictive
# (c) escalation), region empty (cap collapses to the floor), ref `review:1`,
# and the BLOCK reason as the finding text — the retrospective (a)/(b) checks and
# the attempt budget still apply in full.
_rework_extract_finding() {  # <review-log>
  local log="$1" line r
  RWK_STRUCTURAL=0; RWK_REGION=""; RWK_REF="review:1"; RWK_TEXT=""
  line="$(grep -aE '^REVIEW_FINDING:' "$log" 2>/dev/null | grep -aiE 'severity=(blocker|major)' | tail -1)"
  if [ -n "$line" ]; then
    case "$line" in *structural=true*) RWK_STRUCTURAL=1 ;; esac
    RWK_REGION="$(printf '%s' "$line" | sed -n 's/.*region_lines=\([0-9]*\).*/\1/p')"
    r="$(printf '%s' "$line" | sed -n 's/.*ref=\([^ ]*\).*/\1/p')"; [ -n "$r" ] && RWK_REF="$r"
    case "$line" in *'| '*) RWK_TEXT="${line#*| }" ;; *) RWK_TEXT="$line" ;; esac
  else
    RWK_TEXT="$(grep -aoE 'REVIEW_RESULT: BLOCK.*' "$log" 2>/dev/null | tail -1 | sed 's/REVIEW_RESULT: BLOCK *//')"
    [ -z "$RWK_TEXT" ] && RWK_TEXT="review-blocking finding (no structured detail)"
  fi
}

# _rework_escalate <slug> <tdd> <gate> <step> <cause> <finding-ref> <criterion> <excerpt>
# Record a halt (TDD 0018's set_halt_cause) and append a structured design-level
# entry to docs/tdd/BLOCKERS.md (FR-67 / ADR 0007) naming the gate-step pair, the
# structural criterion that fired, and a one-line finding excerpt.
_rework_escalate() {  # <slug> <tdd> <gate> <step> <cause> <ref> <criterion> <excerpt>
  local slug="$1" tdd="$2" gate="$3" step="$4" cause="$5" ref="$6" crit="$7" excerpt="$8"
  set_halt_cause "$slug" "$cause" "$ref" "$crit" \
    || echo "warning: _rework_escalate: set_halt_cause failed for $slug ($cause)" >&2
  record_blocker "$tdd" "$gate:$step $cause $crit — $(printf '%s' "$excerpt" | head -c 200)"
}

# _rework_loop <slug> <tdd> <rbase> <log>  — the bounded automatic rework loop
# (FR-61, FR-62, FR-65, FR-66, FR-67). Runs the review gate; on a PASS verdict
# returns 0 (converged). On a halting finding it either escalates (structural
# (c)/(a)/(b) or budget) → records the halt + BLOCKERS entry + a blocked terminal
# state and returns 1, or runs one bounded rework on Sonnet, mechanically
# pre-passes the commit, and re-runs the review against the new diff. A transient
# pause during review returns 2 (the caller maps it to the paused halt). The user
# is never asked to drive between a finding and convergence/escalation (FR-61).
#   rbase — the build-start SHA (review diff base + the §5 cleared-SHA fallback
#           and the FR-67(b) cumulative base).
_rework_loop() {  # <slug> <tdd> <rbase> <log>
  local slug="$1" tdd="$2" rbase="$3" log="$4"
  local gate="review" step="${THROUGHLINE_REWORK_STEP:-1}"
  local max="${THROUGHLINE_REWORK_MAX:-3}"; case "$max" in ''|*[!0-9]*) max=3 ;; esac
  local build_start="$rbase" cleared attempts=0 rrc rs _retries_json
  cleared="$(git rev-parse HEAD 2>/dev/null || echo "$rbase")"
  while true; do
    _retry_in_gate _review_one_gated "$gate" "$slug" "$log" "$tdd" "$rbase" "$log"
    rrc=$?
    [ "$rrc" -eq 2 ] && return 2          # transient pause (NFR-4: not a fail)
    _retries_json="$(_read_fragment_raw_array "${STATE_DIR:-}/$slug.json" retries 2>/dev/null)"
    if [ "$rrc" -ne 0 ] && [ -n "$_retries_json" ] && [ "$_retries_json" != "[]" ]; then
      _terminal_state "$slug" failed "" "review gate fatal exit after retries (rc=$rrc)"
      return 1
    fi
    rs="$(review_status "$log")"
    case "$rs" in
      *PASS*)  return 0 ;;
      *BLOCK*) : ;;
      *) _terminal_state "$slug" failed "" "review: no REVIEW_RESULT line"; return 1 ;;
    esac

    # A halting finding (FR-58 blocker/major) → classify and act.
    _rework_extract_finding "$log"
    # FR-67(c): reviewer explicitly tagged it structural → no rework.
    if [ "${RWK_STRUCTURAL:-0}" = "1" ]; then
      _rework_escalate "$slug" "$tdd" "$gate" "$step" structural-finding "$RWK_REF" "(c)" "$RWK_TEXT"
      _terminal_state "$slug" blocked "" "structural-finding(c): $RWK_TEXT"
      return 1
    fi
    # FR-65: per-(gate,step) attempt budget. Exhausted BEFORE a further rework
    # (so the counter caps at THROUGHLINE_REWORK_MAX, never over).
    if [ "$attempts" -ge "$max" ]; then
      _rework_escalate "$slug" "$tdd" "$gate" "$step" rework-budget-exhausted "$RWK_REF" "budget" "rework budget $max exhausted at $gate:$step"
      _terminal_state "$slug" blocked "" "rework-budget-exhausted at $gate:$step (budget $max)"
      return 1
    fi

    # One bounded rework attempt (FR-62).
    attempts="$(_rework_attempt_count "$slug" "$gate" "$step")"
    local cap _start _fin new_head spend
    cap="$(_rework_scope_cap "$RWK_REGION")"
    cleared="$(git rev-parse HEAD 2>/dev/null || echo "$cleared")"
    _start=$(date +%s)
    new_head="$(_rework_one "$tdd" "$log" "$RWK_REF" "$RWK_TEXT" "$cap")"
    _fin=$(date +%s)
    spend="$(_extract_token_spend "$(_last_session_path "$_start")")"
    local model="${THROUGHLINE_REWORK_MODEL:-sonnet}"

    # Empty/no-commit rework (§Failure modes): record empty-diff, do not reset,
    # let the next review pass re-block (and eventually exhaust the budget).
    if [ -z "$new_head" ] || [ "$new_head" = "$cleared" ]; then
      _record_rework_attempt "$slug" "$attempts" "$gate" "$step" "$model" "$spend" "$_start" "$_fin" "$RWK_REF" "empty-diff"
      continue
    fi

    # FR-66 + FR-67(a)/(b) mechanical pre-pass against the rework commit.
    local pp pprc cause crit
    pp="$(_rework_pre_pass "$slug" "$tdd" "$new_head" "$cleared" "$build_start" "$RWK_REGION")"; pprc=$?
    if [ "$pprc" -ne 0 ]; then
      case "$pp" in
        *rework-scope-exceeded*)   cause=rework-scope-exceeded; crit="scope" ;;
        *"structural-finding(a)"*) cause=structural-finding;    crit="(a)" ;;
        *"structural-finding(b)"*) cause=structural-finding;    crit="(b)" ;;
        *)                         cause=structural-finding;    crit="(?)" ;;
      esac
      _record_rework_attempt "$slug" "$attempts" "$gate" "$step" "$model" "$spend" "$_start" "$_fin" "$RWK_REF" "rejected:$cause"
      git reset --hard "$cleared" >>"$log" 2>&1   # hard-reset the rejected rework off the branch
      _rework_escalate "$slug" "$tdd" "$gate" "$step" "$cause" "$RWK_REF" "$crit" "$(printf '%s\n' "$pp" | head -1)"
      _terminal_state "$slug" blocked "" "$cause $crit (rework rejected pre-ship)"
      return 1
    fi

    # Shipped: advance the cleared SHA and re-review the new diff.
    _record_rework_attempt "$slug" "$attempts" "$gate" "$step" "$model" "$spend" "$_start" "$_fin" "$RWK_REF" "shipped"
    cleared="$new_head"
  done
}
