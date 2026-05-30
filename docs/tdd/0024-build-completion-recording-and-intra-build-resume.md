# TDD 0024: Build-completion recording + intra-build resume — supersedes TDD 0011

Status: draft
PRD refs: FR-39, FR-40, FR-41, FR-42, FR-43, FR-44, FR-45
PRD-rev: cf5538b
ADR constraints: 0004, 0005, 0006, 0007
Supersedes: 0011

## Approach

Supersedes [[0011]] (detached `/implement` run recovery & restart resilience) from
the new ground truth set by the [[PRD]] revision (FR-40, May 2026): the
persisted run-state record is the **sole** source of truth for whether each of
the four gates — including gate 1 (build) — completed. The build gate's
completion is recorded only when its terminal sentinel `BATCH_RESULT: OK`
(FR-15) is observed.

The carried-forward design covers FR-39 (paused detection), FR-41 (recoverable
cause classification), FR-42 (bounded in-gate retry), FR-43 (lock reclaim),
FR-44 (state durability), and FR-45 (paused status display) — see TDD 0011 §§4
through 6 (data model, classifier, paused-state taxonomy) and §§7 through 9
(durability, lock reclaim, progress view). Those sections remain authoritative.
This TDD changes only FR-40's resume-flow specification and the data carried in
the build-gate's `gates_completed` entry.

The change:
1. **Record build-gate completion explicitly.** When `gate_one` observes
   `BATCH_RESULT: OK` from the build subprocess, it adds `"build"` to the
   per-TDD fragment's `gates_completed` array via the same `set_tdd_state`
   pattern already used for gates 2–4 (test-first, verify, verify-runtime).
2. **Drop the test-first-commit proxy in `_resume_from`.** The current
   implementation treats *any* `test(failing):` commit between
   `merge-base(integration, branch)` and `branch` as evidence of build-gate
   completion. PRD FR-40 (revised) explicitly forbids this proxy. Replace
   the entire Source-A scan with a direct read from `gates_completed`.
3. **Build prompt is resume-aware.** A short additional clause in
   `build-prompt.md` instructs the build subprocess: if the branch already
   carries commits from a prior attempt, examine them and continue from the
   next undone sequencing step rather than restarting from step 1. This
   formalizes the "build prompt is idempotent at the prompt level" claim
   already relied on by combined-mode resume in TDD 0011, so the assumption
   is no longer implicit.

The branch-head divergence guard (TDD 0011 / BLOCKER-1+MAJOR-10) is preserved
verbatim — it remains relevant for *both* inter-gate and intra-build resume,
since it detects a build branch that was rewritten while paused.

## Components & interfaces

**Modified — `scripts/lib/gates.sh` / `_build_one_gated`'s caller in
`gate_one` (lives in `scripts/lib/resume.sh`):**

```
# Gate 1: build — after parsing BATCH_RESULT
case "$bs" in
  *OK*) set_tdd_state "$slug" building build "" build \
          || echo "warning: gate_one: could not record build completion for $slug" >&2 ;;
  *BLOCKED*) record_blocker "$tdd" "${bs#*BLOCKED}"
             _terminal_state "$slug" blocked "" "build BLOCKED (design):${bs#*BLOCKED}"
             echo "BLOCKED (design)${bs#*BLOCKED}"; return 1 ;;
  *) _terminal_state "$slug" failed "" "build did not return OK (${bs:-no BATCH_RESULT})"
     echo "${bs:-FAIL (no BATCH_RESULT; see log)}"; return 1 ;;
esac
```

The 5th parameter to `set_tdd_state` is the gate-completion-additive contract
established in TDD 0011 / iter-9 SF-2 (the same call appears for `test-first`
at resume.sh:336, `verify` at :344, `verify-runtime` at :369; build is the only
gate currently missing this call).

**Modified — `scripts/lib/resume.sh` / `_resume_from`:**

Replace the entire Source-A test-first-commit scan (current lines 129-199,
including the combined-mode bypass and the no-merge-base degraded-evidence
refuse) with a direct read from `gates_completed`:

```
# Build-gate completion: read from the run-state record (FR-40 revised).
# Partial commits on the branch are NOT evidence of build completion;
# only an explicit "build" entry in gates_completed counts. A missing
# entry means the build did not reach BATCH_RESULT: OK before the
# interruption — re-run it.
```

The combined-mode `done_list` builder simplifies: both sequential and combined
modes now use the same logic — `done_list = gates_csv` (no implicit "build"
prepend). Idempotence of build_one is now an explicit contract documented in
`build-prompt.md`, not an implicit one inferred from commit log scanning.

The divergence guard (current lines 201-217) is preserved verbatim. The
`resume-blocked-build-state-missing` refuse-to-resume *write* path (lines
184-198 and 192-198 in the bypassed scan) is removed — that condition no
longer arises, since `gates_completed` is authoritative regardless of
merge-base availability. The runtime is in a strictly safer place after this
deletion: every prior call site that would have written this cause was a
"can't safely tell whether build completed" situation, and the new rule
("`gates_completed` is authoritative; if `build` is absent, re-run it") is
correctly safe for all such situations without needing a refuse-to-resume
gate.

**Read-side enum compatibility.** The four read-side enum arms recognizing
`resume-blocked-build-state-missing` (`state.sh:_next_actions_for_cause` line
635, `state.sh:_is_paused_cause` line 661, `status.sh:_halt_is_paused_cause`
line 187, `status.sh:_halt_cause_known` line 196) and the legacy next-action
label are NOT touched. Rationale: a paused fragment carrying this cause
exists only when a pre-this-TDD runner refused-to-resume at the Source-A
scan and the user upgraded before re-invoking. The new `_resume_from`
ignores the cause and resumes via `gates_completed` correctly. Removing the
arms would silently break halt-context display for such legacy fragments
(unrecognized cause → Resume trailer hidden + "unknown halt_cause" warning).
Retention has no runtime cost; the stale label is never re-displayed for
any post-this-TDD fragment.

**Modified — `scripts/build-prompt.md`:**

Add a single bullet to the "Build discipline" list (between the existing first
bullet "Implement in the sequence the TDD specifies, one step at a time." and
the FAILING TEST FIRST bullet):

```
- If the build branch already carries commits from a prior attempt (one or
  more `test(failing):` + `feat:` / `step:` pairs that reference this TDD's
  sequencing items), this is a RESUME, not a fresh build. Examine the
  existing commits with `git log` against the TDD's `## Sequencing /
  implementation plan`, identify which sequencing items are already
  committed, and continue from the next undone step rather than restarting
  at step 1. Do not duplicate or rewrite already-committed work; the
  divergence guard in the runner's resume path rejects branch rewrites and
  would refuse to flip the TDD.
```

This formalizes the idempotence assumption already relied on by
combined-mode resume in TDD 0011 §5, making it an explicit prompt-level
contract rather than an implicit hope.

## Data & state

`gates_completed` (FR-27 field, `string[]`) gains one allowed value:
`"build"`. The full closed set becomes:

```
build | test-first | verify | verify-runtime
```

The values match the existing `stage` enum from TDD 0011 §4. Schema version
(`run.json` / `.schema`) is NOT bumped — this is an additive value
extension to an existing field, consistent with the precedent in TDD 0018
§5 (additive-fields-don't-bump rule) and the FR-44 backward-compatibility
constraint that the resume gate hard-requires `schema == 1`. Old paused
fragments (e.g. one created before this TDD ships, written with no `build`
entry) resume into the build re-run path — which is the correct safe
default, because the absence of an explicit completion record means
"don't trust it." A fragment written post-shipping with `build` correctly
present resumes into the post-build path.

The `stage` field's transitions are unchanged. The fragment's
`branch_head_at_pause` semantics are unchanged.

**`paused_cause` closed enum (authoritative under this TDD).** Identical to
TDD 0011's set with one disposition change: `resume-blocked-build-state-missing`
becomes **legacy read-only** (no code path emits it post-this-TDD; read-side
enum arms retained — see §Components & interfaces). The other five values
(`ratelimit`, `usage-limit`, `transient`, `resume-blocked-branch-missing`,
`resume-blocked-branch-divergence`) remain writable, unchanged from TDD 0011.

## Sequencing / implementation plan

Standard red→green discipline applies (test(failing): before each
implementation commit; runner gates this mechanically).

1. **Record build completion.** Edit `scripts/lib/resume.sh:320-324` (the
   `case "$bs" in *OK*) ... esac` block) to call
   `set_tdd_state "$slug" building build "" build`. Extend the
   gate-completion-recording assertions in `tests/run-recovery.test.sh`
   Step 3 to expect `build` in `gates_completed` after a successful build.
2. **Drop the test-first proxy in resume.** Remove lines 129-199 of
   `scripts/lib/resume.sh` (Source-A scan, combined-mode bypass,
   no-merge-base refuse). Replace with a brief comment naming FR-40 and a
   direct read: `done_list="$gates_csv"`. Preserve the divergence guard
   (lines 201-217). Add a fixture that builds a fragment with
   `gates_completed: []` plus a branch carrying `test(failing):` commits;
   assert `_resume_from` sets the done-list without `build`.
3. **Build prompt resume-awareness.** Add the new bullet to
   `scripts/build-prompt.md` "Build discipline" section. Test: grep the
   prompt for the literal phrases "RESUME" and "next undone step".
4. **Intra-build interruption fixture.** Add a comprehensive fixture to
   `tests/run-recovery.test.sh` covering FR-40 (b): construct a paused
   fragment (`status=paused`, `paused_cause=usage-limit`,
   `gates_completed=[]`, `stage=build`) plus a build branch carrying two
   `test(failing):`+`feat:` pairs but no `BATCH_RESULT: OK` line. Drive
   `_resume_from`; assert the returned `done_list` lacks `build` and the
   divergence guard is unaffected.
5. **Close-out edits.** Update `docs/tdd/0011-detached-run-recovery.md`'s
   `Status:` line to `superseded by 0024 (formerly implemented;
   halt-taxonomy aspect superseded by 0018)`. Bump
   `.claude-plugin/plugin.json` `3.10.1` → `3.10.2` (patch bump,
   functional fix). Mechanical edits — no failing-test-first.

## Failure modes & edge cases

- **Old paused fragment from before this TDD ships.** A fragment written by
  the pre-TDD runner has `gates_completed: []` even if the build
  successfully reached `BATCH_RESULT: OK` and was interrupted between
  gates. On resume, the new code will re-run the build gate. The build
  prompt's new resume-awareness bullet handles this — the LLM sees the
  prior gate-1 commits and continues from where it left off (which, in
  this case, is "nothing remaining" → it emits `BATCH_RESULT: OK`
  immediately with no new commits, runner records `build` in
  `gates_completed`, proceeds to gate 2). Cost: one extra `claude -p`
  invocation for the old fragment population only; subsequent
  fragments are correct by construction.
- **Build subprocess emits `BATCH_RESULT: OK` but `set_tdd_state` fails.**
  The mirror handling at resume.sh:336/344/369 logs a warning and
  continues. We follow the same pattern — log to stderr, do not abort.
  The downstream gates will run anyway because they only check the
  fragment's `status`, not its `gates_completed`. The cost is one
  duplicate build re-run on a later resume (acceptable; an actual disk
  fault is a documented edge case under FR-44).
- **Concurrent paused fragments with mixed schemas.** A run with TDD A
  paused before this TDD shipped and TDD B paused after. The same
  `_resume_from` logic handles both — the pre-shipping TDD's fragment
  has `gates_completed: []` (build re-runs, idempotent); the
  post-shipping TDD's fragment has `gates_completed: ["build", …]`
  (build is skipped). No fragment schema discrimination needed.
- **Build branch carries `test(failing):` commits from a prior failed
  TDD (combined mode).** This is the case TDD 0011 / iter-4 BLOCKER-1
  worked around by skipping the test-first scan in combined mode. With
  the test-first scan gone entirely (step 2), the combined-mode
  workaround becomes unnecessary — `gates_completed` is per-TDD
  fragment and unambiguous. The combined-mode branch in `_resume_from`
  is simplified accordingly.
- **`stage=build` at pause but `gates_completed` contains `"build"`.**
  An impossibility under the new contract (a successful build sets
  `stage` forward to `test-first` before exiting gate 1's case). If it
  ever happens (manual fragment mutation, disk corruption), the
  divergence-guard / resume flow trusts `gates_completed` (per FR-40
  revised) and treats build as done. `stage` is advisory display, not
  authoritative gate completion.
- **Legacy paused fragment carries `paused_cause=resume-blocked-build-state-missing`.**
  An already-paused fragment created by the pre-this-TDD runner may
  still hold this cause; see §Data & state for why read-side enum arms
  are retained. On resume of such a fragment, the new `_resume_from`
  reads `gates_completed` directly (independent of `paused_cause`),
  finds it does not contain `build`, and re-runs the build gate.
  Outcome is correct (build resumes from current branch state,
  idempotent per the build prompt). The `paused_cause` label remains
  stale-by-policy but is never re-displayed for any new fragment.

## Verification plan

**Observable surface:** the per-TDD state fragment under
`docs/tdd/.implement-logs/<runid>/state.d/<slug>.json` and the per-TDD
build log under `docs/tdd/.implement-logs/<runid>/<slug>.log`.

**Observation points (the concrete scenarios that drive the changed code):**

1. **Build-completion recording.** Start a normal `/implement` build on a
   fresh TDD with no prior commits. After the runner observes
   `BATCH_RESULT: OK` and before gate 2 starts, read the per-TDD fragment.
2. **Intra-build resume — `gates_completed` is empty pre-resume.**
   Simulate an intra-build interruption (test fixture, not a real
   ratelimit): paused fragment with `status=paused`, `gates_completed:[]`,
   `stage=build`; build branch with 2 test-first+feat pairs but no
   BATCH_RESULT line. Re-invoke `/implement --resume <runid>`. The runner
   reads the fragment.
3. **Intra-build resume — build re-runs and completes.** Same fixture.
   Watch the per-TDD log between the resume timestamp and the next gate's
   verdict.
4. **Branch preservation across resume.** Same fixture. Compare
   `git rev-parse refs/heads/<branch>` before and after resume.
5. **Build prompt resume-awareness.** Read `scripts/build-prompt.md`.

**Expected observations (PASS):**

1. The fragment's `gates_completed` field contains the literal value
   `["build"]` (or `["build", …]` if subsequent gates have also recorded
   completion).
2. After `_resume_from` returns for that fragment, the export'd
   `RESUME_GATES_DONE_<slug>` variable's value does NOT contain the
   substring `"build"`. Additionally, the `_resume_from` execution
   contains zero `git log --format=...` calls keyed off
   `^test\(failing\)` (the deleted Source-A scan's signature pattern) —
   shellcheck or a test-stub for `git` can falsify either claim. Gate 1
   therefore re-runs on this fragment.
3. The log shows new build output (a `claude -p` invocation with the
   build prompt) between the resume timestamp and the
   `BATCH_RESULT: OK` line; the next-gate verdict appears after that.
4. The branch's HEAD SHA is unchanged from before the resume *up to* the
   pre-resume commits — the build either added zero new commits (steps
   were already complete) or appended new commits after the prior tip.
   Specifically, the prior 2 test-first+feat pairs (4 commits) remain at
   HEAD~N positions verbatim.
5. The "Build discipline" section of `build-prompt.md` contains a bullet
   with the literal phrases "RESUME" and "next undone step".

## Requirement traceability

| Requirement | Design element |
|---|---|
| FR-39 Interrupted-run detection | Carried forward from TDD 0011 §4 (paused-state detection); status.sh `--check-paused` shape unchanged. |
| **FR-40 Gate-level resume (REVISED)** | Step 1 (record `build` in `gates_completed` on BATCH_RESULT: OK) + step 2 (drop test-first proxy; read from `gates_completed`) + step 3 (build prompt resume-awareness). **Acceptance (a) inter-gate resume — observable behavior unchanged from TDD 0011 §6, but the implementation mechanism is materially different.** Pre-this-TDD: in sequential mode, `_resume_from` *infers* gate-1 completion from the existence of a `test(failing):` commit in `merge-base(integration, branch)..branch` (Source A). Post-this-TDD: `_resume_from` reads `gates_completed` directly; a fragment created post-shipping by a build that emitted `BATCH_RESULT: OK` carries `gates_completed: ["build", ...]`, so gate 1 is correctly skipped. A fragment created pre-shipping (legacy) carries `gates_completed: []`, so on a post-shipping resume gate 1 *re-runs* — which is also correct (build prompt resume-awareness handles the legacy case with zero new commits when the prior build had completed cleanly). **Acceptance (b) intra-build resume:** covered by Verification plan observations 2–4. |
| FR-41 Recoverable-cause classification | Carried forward from TDD 0011 §5 (`_classify_cause`, `_recoverable_patterns`). PR #51 (May 2026) added the `hit your session limit` pattern; this TDD makes no further classifier change. |
| FR-42 Bounded in-gate retry | Carried forward from TDD 0011 §5 (`_retry_in_gate`, retry budget, transient handling). Unchanged. |
| FR-43 Stale single-run lock reclaim | Carried forward from TDD 0011 §8 (lock reclaim). Unchanged. |
| FR-44 Persisted-state durability | Carried forward from TDD 0011 §7 (atomic fragment writes). Schema version 1 preserved (TDD 0018 precedent — additive field values do not bump). |
| FR-45 Paused status in progress view | Carried forward from TDD 0011 §9 (status.sh renderer, halt context). Unchanged. |

No gaps: every in-scope FR is covered.

## Dependencies considered

No new dependencies. All changes are to existing shell scripts and a
markdown prompt file; no library, framework, or service additions. The
test infrastructure is the existing `tests/run-recovery.test.sh` driven by
the repo's existing test runner — no new test framework.

## PRD conflicts surfaced (and resolution)

- **The original FR-40 wording allowed an "inferred-from-commits" proxy
  reading** ("the build branch's committed history is the source of truth
  for the build gate's output"). The revised FR-40 (PR #52, May 2026)
  explicitly disambiguates "output" (= content) from "completion" (=
  gate verdict). This TDD implements the resolution per the revised
  PRD; no further PRD change required.
- **No conflict with accepted ADRs.** ADR 0004 (verification-is-observation,
  no harness vendored) is unaffected — runtime-verify is unchanged. ADR
  0005 (gate-scope-by-prompt) is reinforced — the build prompt now
  carries the resume contract explicitly. ADR 0006
  (gate-decisions-grounded-in-verifiable-artifacts) is reinforced —
  build-gate completion now grounds in an explicit `gates_completed`
  entry, not an inferred commit pattern. ADR 0007 (halt model + bounded
  rework + structural escalation) is unaffected — rework and structural
  escalation operate at the review gate, not the build gate.

## Decisions to promote (ADR candidates)

None. This TDD enacts a PRD revision against existing ADRs without
introducing a cross-cutting decision worth elevating.

## Touched files

- `scripts/lib/resume.sh` — gate-1 completion recording (case `*OK*) ...`); drop test-first-commit proxy in `_resume_from`; preserve divergence guard
- `scripts/lib/gates.sh` — (no direct change expected; the `_build_one_gated` helper is unchanged) — listed only if a follow-on edit emerges
- `scripts/build-prompt.md` — add one bullet to "Build discipline" naming the RESUME contract
- `tests/run-recovery.test.sh` — extend gate-completion assertions; add intra-build interruption fixture
- `docs/tdd/0011-detached-run-recovery.md` — Status line update only (`superseded by 0024 (formerly implemented; halt-taxonomy aspect superseded by 0018)`); body unchanged
- `.claude-plugin/plugin.json` — version bump `3.10.1` → `3.10.2`

## Expected diff size

- `scripts/lib/resume.sh` — 90 lines (≈70 lines removed from the test-first scan + combined-mode bypass + degraded-evidence refuse; ≈20 lines added: gate-1 completion recording + a comment block citing FR-40)
- `scripts/lib/gates.sh` — 5 lines (placeholder; may be 0 if the change lands entirely in resume.sh)
- `scripts/build-prompt.md` — 10 lines (one new bullet, indented to match the existing style)
- `tests/run-recovery.test.sh` — 80 lines (≈30 lines extending existing gate-completion assertions for `build`; ≈50 lines for the new intra-build interruption fixture, matching the existing `[2.x]` block style)
- `docs/tdd/0011-detached-run-recovery.md` — 1 line (Status line)
- `.claude-plugin/plugin.json` — 1 line (version bump)

Total expected diff: 187 lines across 6 files.
