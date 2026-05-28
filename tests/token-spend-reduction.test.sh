#!/usr/bin/env bash
# token-spend-reduction.test.sh — eval for TDD 0013 (FR-51 + FR-52).
#
# Covers:
#   - scripts/lib/tdd-lint.sh: the four lint functions and the unified exit-code
#     contract (0 = clean / nit-only, 1 = major, 2 = blocker), with the file's
#     stdout finding format `<file>:<line> <severity> <code>: <msg>`. Each
#     fixture under tests/fixtures/tdds/ asserts one rule of that contract.
#   - scripts/lib/plan-classifier.sh::tl_classify_plan: the mechanical vs
#     nontrivial heuristic.
#   - the agent / skill edits that wire FR-51 into /tdd-author.
#   - scripts/implement.sh::verify_runtime_one tiering: a `runtime-verify
#     model=<m> (plan=<cls>)` line is written to the per-TDD log BEFORE the
#     `claude` invocation, with the right model for each classifier outcome.
#   - the four-gates header comment + verify-runtime-prompt sentence + implement
#     skill Notes bullet documenting the env override.
#
# Run: bash tests/token-spend-reduction.test.sh

set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
LINT="$REPO/scripts/lib/tdd-lint.sh"
CLS="$REPO/scripts/lib/plan-classifier.sh"
IMPL="$REPO/scripts/implement.sh"
FIX="$REPO/tests/fixtures/tdds"

# Tally results in a tempfile so subshells can append.
RESULTS="$(mktemp)"; export RESULTS
ok()  { printf 'ok\n'   >>"$RESULTS"; printf '  ok   — %s\n' "$1"; }
bad() { printf 'fail\n' >>"$RESULTS"; printf '  FAIL — %s\n' "$1"; }
expect_exit() {  # <expected> <actual> <label>
  if [ "$1" = "$2" ]; then ok "$3 (exit=$2)"; else bad "$3 (expected exit=$1, got exit=$2)"; fi
}

echo "[lint-A] structural lint blocks on missing ## Verification plan"
(
  out="$(bash "$LINT" "$FIX/missing-vp.md" 2>/dev/null)"; rc=$?
  expect_exit 2 "$rc" "exit code 2 (blocker)"
  printf '%s\n' "$out" | grep -q 'section.verification_plan' \
    && ok "stdout names section.verification_plan" \
    || bad "expected /section.verification_plan/ in stdout (got: $out)"
)

echo "[lint-B] clean fixture exits 0 with no findings"
(
  out="$(bash "$LINT" "$FIX/clean.md" 2>/dev/null)"; rc=$?
  expect_exit 0 "$rc" "exit code 0 (clean)"
  [ -z "$out" ] && ok "stdout empty on clean fixture" || bad "expected empty stdout on clean fixture (got: $out)"
)

echo "[lint-C] placeholder lint silences fenced + <angle> TBD, fires on prose TBD"
(
  out="$(bash "$LINT" "$FIX/placeholder-prose.md" 2>/dev/null)"; rc=$?
  # major-severity placeholder + missing section nothing → exit 1
  expect_exit 1 "$rc" "exit code 1 (major)"
  printf '%s\n' "$out" | grep -qE 'placeholder' \
    && ok "stdout names placeholder finding" \
    || bad "expected /placeholder/ in stdout (got: $out)"

  out2="$(bash "$LINT" "$FIX/placeholder-fenced.md" 2>/dev/null)"; rc2=$?
  expect_exit 0 "$rc2" "fenced/angle-bracket TBD does not fire"
  [ -z "$out2" ] && ok "stdout empty on fenced-only TBD fixture" || bad "expected empty stdout on fenced-only fixture (got: $out2)"
)

echo "[lint-D] traceability lint flags an FR in PRD refs but absent from the table"
(
  out="$(bash "$LINT" "$FIX/untraced.md" 2>/dev/null)"; rc=$?
  expect_exit 1 "$rc" "exit code 1 (major)"
  printf '%s\n' "$out" | grep -qE 'FR-3' \
    && ok "stdout names the untraced FR-3" \
    || bad "expected /FR-3/ in stdout (got: $out)"
)

echo "[lint-E] section.empty lint fires on adjacent ## headings"
(
  out="$(bash "$LINT" "$FIX/empty-section.md" 2>/dev/null)"; rc=$?
  expect_exit 1 "$rc" "exit code 1 (major)"
  printf '%s\n' "$out" | grep -q 'section.empty' \
    && ok "stdout names section.empty" \
    || bad "expected /section.empty/ in stdout (got: $out)"
)

echo "[lint-F] aggregate exit is max(sub-lints), capped at 2"
(
  # missing-vp has a blocker -> aggregate rc must be 2 even when run alongside
  # cleans.
  out="$(bash "$LINT" "$FIX/clean.md" "$FIX/missing-vp.md" 2>/dev/null)"; rc=$?
  expect_exit 2 "$rc" "aggregate exit = max severity (blocker wins)"
)

echo "[cls-A] tl_classify_plan: mechanical observation -> mechanical"
(
  out="$(bash -c "source '$CLS'; tl_classify_plan '$FIX/clean.md'" 2>/dev/null)"; rc=$?
  [ "$out" = "mechanical" ] && ok "mechanical plan classified mechanical" || bad "expected mechanical, got '$out' (rc=$rc)"
)

echo "[cls-B] tl_classify_plan: browser/Playwright -> nontrivial"
(
  tmp="$(mktemp --suffix=.md)"
  cat > "$tmp" <<'EOF'
# fixture
PRD refs: FR-1
## Verification plan
Drive a browser via Playwright and observe the rendered DOM.
EOF
  out="$(bash -c "source '$CLS'; tl_classify_plan '$tmp'" 2>/dev/null)"
  [ "$out" = "nontrivial" ] && ok "browser/Playwright -> nontrivial" || bad "expected nontrivial, got '$out'"
  rm -f "$tmp"
)

echo "[cls-C] tl_classify_plan: HTTP 200 / body assertion -> mechanical"
(
  tmp="$(mktemp --suffix=.md)"
  cat > "$tmp" <<'EOF'
# fixture
## Verification plan
curl the endpoint and observe HTTP 200 plus the JSON body matches.
EOF
  out="$(bash -c "source '$CLS'; tl_classify_plan '$tmp'" 2>/dev/null)"
  [ "$out" = "mechanical" ] && ok "HTTP-200 plan -> mechanical" || bad "expected mechanical, got '$out'"
  rm -f "$tmp"
)

echo "[cls-D] tl_classify_plan: no obvious markers -> nontrivial (conservative)"
(
  tmp="$(mktemp --suffix=.md)"
  cat > "$tmp" <<'EOF'
# fixture
## Verification plan
The change is correct.
EOF
  out="$(bash -c "source '$CLS'; tl_classify_plan '$tmp'" 2>/dev/null)"
  [ "$out" = "nontrivial" ] && ok "ambiguous plan -> nontrivial (conservative default)" || bad "expected nontrivial default, got '$out'"
  rm -f "$tmp"
)

echo "[cls-E] tl_classify_plan: mixed (mechanical + browser) -> nontrivial (browser wins)"
(
  tmp="$(mktemp --suffix=.md)"
  cat > "$tmp" <<'EOF'
# fixture
## Verification plan
Drive the browser to /foo, observe stdout / exit code at the CLI side too.
EOF
  out="$(bash -c "source '$CLS'; tl_classify_plan '$tmp'" 2>/dev/null)"
  [ "$out" = "nontrivial" ] && ok "mixed plan -> nontrivial" || bad "expected nontrivial, got '$out'"
  rm -f "$tmp"
)

echo "[agent-A] design-reviewer.md carries the Pre-check already ran preamble"
(
  grep -q 'Pre-check already ran' "$REPO/agents/design-reviewer.md" \
    && ok "preamble present in agents/design-reviewer.md" \
    || bad "expected 'Pre-check already ran' in agents/design-reviewer.md"
)

echo "[agent-B] tdd-author SKILL.md invokes tdd-lint.sh in step 7a"
(
  grep -q 'tdd-lint.sh' "$REPO/skills/tdd-author/SKILL.md" \
    && ok "tdd-lint.sh referenced in tdd-author SKILL.md" \
    || bad "expected 'tdd-lint.sh' in skills/tdd-author/SKILL.md"
)

echo "[agent-C] implement SKILL.md documents THROUGHLINE_RUNTIME_VERIFY_MODEL"
(
  grep -q 'THROUGHLINE_RUNTIME_VERIFY_MODEL' "$REPO/skills/implement/SKILL.md" \
    && ok "env var documented in implement SKILL.md" \
    || bad "expected THROUGHLINE_RUNTIME_VERIFY_MODEL in skills/implement/SKILL.md"
)

echo "[agent-D] verify-runtime-prompt.md mentions tiering / model context"
(
  grep -qE 'mechanical|tiers|tier|the runner chose' "$REPO/scripts/verify-runtime-prompt.md" \
    && ok "prompt acknowledges the runner-chosen model" \
    || bad "expected the prompt to mention runner-chosen tiering"
)

echo "[agent-E] implement.sh header comment mentions runtime-verify model tiering"
(
  # The four-gates enumeration's gate-3 description now refers to plan-based tiering.
  grep -q 'tiers' "$IMPL" \
    && ok "implement.sh header mentions tiering" \
    || bad "expected 'tiers' in implement.sh header comment"
)

# --- verify_runtime_one runtime tiering -------------------------------------
#
# Stand up a stub `claude` and source implement.sh with THROUGHLINE_SOURCE_ONLY=1
# so verify_runtime_one is callable in isolation. The stub records its --model
# arg; we assert the per-TDD log carries the `runtime-verify model=… (plan=…)`
# line BEFORE the claude invocation, and that the chosen model is sonnet for a
# mechanical plan and opus (build model) for a nontrivial one. Env override
# pinning is asserted last.

setup_runtime() {
  TMPROOT="$(mktemp -d)"
  cd "$TMPROOT"
  git init -q >/dev/null
  git config user.email t@t.t; git config user.name t
  mkdir -p docs/tdd docs/adr "$TMPROOT/stub/bin"
  printf '# PRD\n' > docs/PRD.md
  printf '# ADR Index\n' > docs/adr/INDEX.md
  cat > docs/tdd/0001-mechanical.md <<'EOF'
# TDD: mechanical
Status: draft
PRD refs: FR-99
PRD-rev: deadbee
ADR constraints: none

## Approach
stub

## Verification plan
Run the CLI and observe stdout / exit code 0. grep the log line.

## Requirement traceability
| PRD | Design element |
|---|---|
| FR-99 | x |

## Dependencies considered
None.
EOF
  cat > docs/tdd/0002-nontrivial.md <<'EOF'
# TDD: nontrivial
Status: draft
PRD refs: FR-99
PRD-rev: deadbee
ADR constraints: none

## Approach
stub

## Verification plan
Drive a Playwright browser to /foo and observe the rendered DOM.

## Requirement traceability
| PRD | Design element |
|---|---|
| FR-99 | x |

## Dependencies considered
None.
EOF
  git add -A; git commit -qm init >/dev/null 2>&1
  # stub claude: dump its --model arg to a file then exit 0
  cat > "$TMPROOT/stub/bin/claude" <<'EOF'
#!/usr/bin/env bash
model=""
while [ $# -gt 0 ]; do case "$1" in --model) model="$2"; shift 2;; *) shift;; esac; done
echo "claude-model=$model" >> "$STUB_LOG"
echo "BATCH_RESULT: OK"
exit 0
EOF
  chmod +x "$TMPROOT/stub/bin/claude"
  export PATH="$TMPROOT/stub/bin:$PATH"
}

echo "[rt-A] verify_runtime_one writes runtime-verify line + uses sonnet for mechanical plan"
(
  setup_runtime
  export STUB_LOG="$TMPROOT/stub.log"
  : > "$STUB_LOG"
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL"
  MODEL=opus
  RVMTPL="$REPO/scripts/verify-runtime-prompt.md"
  LOGF="$TMPROOT/0001.log"; : > "$LOGF"
  verify_runtime_one docs/tdd/0001-mechanical.md HEAD "$LOGF" >/dev/null 2>&1
  grep -qE 'runtime-verify model=sonnet \(plan=mechanical\)' "$LOGF" \
    && ok "log line: runtime-verify model=sonnet (plan=mechanical)" \
    || bad "expected /runtime-verify model=sonnet \\(plan=mechanical\\)/ in log (got: $(cat "$LOGF"))"
  grep -q 'claude-model=sonnet' "$STUB_LOG" \
    && ok "claude was invoked with --model sonnet" \
    || bad "expected claude --model sonnet (stub log: $(cat "$STUB_LOG"))"
  cd "$REPO"; rm -rf "$TMPROOT"
)

echo "[rt-B] verify_runtime_one uses build model (opus) for nontrivial plan"
(
  setup_runtime
  export STUB_LOG="$TMPROOT/stub.log"; : > "$STUB_LOG"
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL"
  MODEL=opus
  RVMTPL="$REPO/scripts/verify-runtime-prompt.md"
  LOGF="$TMPROOT/0002.log"; : > "$LOGF"
  verify_runtime_one docs/tdd/0002-nontrivial.md HEAD "$LOGF" >/dev/null 2>&1
  grep -qE 'runtime-verify model=opus \(plan=nontrivial\)' "$LOGF" \
    && ok "log line: runtime-verify model=opus (plan=nontrivial)" \
    || bad "expected /runtime-verify model=opus \\(plan=nontrivial\\)/ (got: $(cat "$LOGF"))"
  grep -q 'claude-model=opus' "$STUB_LOG" \
    && ok "claude was invoked with --model opus" \
    || bad "expected claude --model opus (stub log: $(cat "$STUB_LOG"))"
  cd "$REPO"; rm -rf "$TMPROOT"
)

echo "[rt-C] THROUGHLINE_RUNTIME_VERIFY_MODEL pin wins over classifier"
(
  setup_runtime
  export STUB_LOG="$TMPROOT/stub.log"; : > "$STUB_LOG"
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL"
  MODEL=opus
  RVMTPL="$REPO/scripts/verify-runtime-prompt.md"
  LOGF="$TMPROOT/0001-pin.log"; : > "$LOGF"
  # Mechanical plan would normally pick sonnet; pin to haiku-like 'opus'.
  THROUGHLINE_RUNTIME_VERIFY_MODEL=opus \
    verify_runtime_one docs/tdd/0001-mechanical.md HEAD "$LOGF" >/dev/null 2>&1
  grep -q 'runtime-verify model=opus' "$LOGF" \
    && ok "env override pinned the model to opus" \
    || bad "expected env override to win (got: $(cat "$LOGF"))"
  cd "$REPO"; rm -rf "$TMPROOT"
)

# --- Review-blocker coverage (M1/M2/M3 from the TDD 0013 review pass) --------
# Each test below exercises a silent-failure mode the independent reviewer
# flagged. The pre-fix lint/runner answers `clean`/`nontrivial` to the caller
# despite an underlying failure, violating NFR-4 verdict honesty. The fixes
# either propagate the failure as an error code (rc=2) or attach a
# distinguishable note to the log line so triage can tell error from genuine.

echo "[lint-M1] section.empty lint emits finding even when input directory is read-only"
(
  # Pre-fix: tl_lint_structural's section.empty pass writes to
  # "$f.tdd-lint.empty.$$" adjacent to the input. Read-only directory →
  # redirect fails (silenced by 2>/dev/null) → [ -s ... ] is false → zero
  # findings, rc=0 (silent FAIL). The fix must keep the finding visible.
  TMP="$(mktemp -d)"
  cp "$FIX/empty-section.md" "$TMP/empty-section.md"
  chmod -w "$TMP"
  out="$(bash "$LINT" "$TMP/empty-section.md" 2>/dev/null)"; rc=$?
  chmod +w "$TMP"; rm -rf "$TMP"
  expect_exit 1 "$rc" "exit code 1 (major) under read-only dir"
  printf '%s\n' "$out" | grep -q 'section.empty' \
    && ok "stdout names section.empty even under read-only dir" \
    || bad "expected /section.empty/ in stdout under read-only dir (got: $out)"
)

echo "[lint-M2] placeholder lint surfaces awk crash as rc=2 instead of mapping it to clean"
(
  # Pre-fix: case "$?" in 1) rc=1 ;; *) rc=0 ;; — awk exit ≥2 (crash) maps
  # to "clean", so a broken awk run looks like a TDD with no placeholders.
  # The fix must propagate non-{0,1} awk exits as rc=2 (blocker) with a
  # stderr message.
  TMP="$(mktemp -d)"
  cat > "$TMP/awk" <<'EOF2'
#!/usr/bin/env bash
exit 3
EOF2
  chmod +x "$TMP/awk"
  export PATH="$TMP:$PATH"
  source "$LINT"
  err="$(tl_lint_placeholders "$FIX/clean.md" 2>&1 >/dev/null)"; rc=$?
  unset -f tl_lint_structural tl_lint_placeholders tl_lint_traced tl_lint_all _tl_emit 2>/dev/null
  rm -rf "$TMP"
  expect_exit 2 "$rc" "tl_lint_placeholders rc=2 on awk crash"
  printf '%s\n' "$err" | grep -q 'awk' \
    && ok "stderr names awk failure" \
    || bad "expected stderr to mention awk crash (got: $err)"
)

echo "[rt-M3] verify_runtime_one notes classifier failure distinctly from genuine nontrivial"
(
  # Pre-fix: a tl_classify_plan that returns non-zero leaves cls="" and
  # falls through to vm="$MODEL"; cls="nontrivial"; note="". The gate log
  # line then reads `runtime-verify model=opus (plan=nontrivial)` — IDENTICAL
  # to a genuine nontrivial classification. The fix must annotate the
  # classifier-failed case with a distinguishing note so triage can tell
  # error from genuine.
  setup_runtime
  mkdir -p "$TMPROOT/scripts/lib"
  cat > "$TMPROOT/scripts/lib/plan-classifier.sh" <<'EOF3'
#!/usr/bin/env bash
tl_classify_plan() { return 2; }
EOF3
  SDIR="$TMPROOT/scripts"
  THROUGHLINE_SOURCE_ONLY=1 source "$IMPL"
  MODEL=opus
  RVMTPL="$REPO/scripts/verify-runtime-prompt.md"
  LOGF="$TMPROOT/0001-cls-fail.log"; : > "$LOGF"
  PATH="$TMPROOT/stub/bin:$PATH" verify_runtime_one docs/tdd/0001-mechanical.md HEAD "$LOGF" >/dev/null 2>&1
  grep -q 'classifier failed' "$LOGF" \
    && ok "log line names 'classifier failed' (distinct from genuine nontrivial)" \
    || bad "expected /classifier failed/ in log (got: $(cat "$LOGF"))"
  cd "$REPO"; rm -rf "$TMPROOT"
)

PASS="$(grep -c '^ok$'   "$RESULTS" 2>/dev/null)"; PASS="${PASS:-0}"
FAIL="$(grep -c '^fail$' "$RESULTS" 2>/dev/null)"; FAIL="${FAIL:-0}"
rm -f "$RESULTS"
echo
echo "=== token-spend-reduction eval: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
