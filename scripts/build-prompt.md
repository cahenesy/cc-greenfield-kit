Implement the Technical Design Doc at {{TDD}} as a single unattended build.

Load context: read {{TDD}} in full; read docs/PRD.md for the requirements it
references; read the accepted ADRs it lists under "ADR constraints" (full
bodies) plus docs/adr/INDEX.md for anything else relevant. Use the built-in
`Explore` subagent for broader investigation so reading stays out of context.

Build discipline:
- Implement in the sequence the TDD specifies, one step at a time.
- FAILING TEST FIRST (mandatory). Follow the `superpowers:test-driven-development`
  skill (load it and apply its red→green discipline). For each unit of behavior,
  BEFORE writing the implementation: write the test, run it, and confirm it FAILS
  for the right reason (the behavior is genuinely absent — not a typo or a missing
  import). Commit that test on its own with a message beginning
  `test(failing): <behavior>`. THEN implement until it passes and commit the
  implementation separately. The runner gates this red→green order mechanically
  (it requires a `test(failing):` commit before the impl) and the independent
  review judges whether the tests are meaningful. Only a genuine no-new-behavior
  change (pure refactor/docs) may skip it — and then you MUST end with
  `TEST_FIRST: SKIPPED <reason>`.
- After each step run the relevant tests and the typecheck; fix failures at the
  ROOT CAUSE — never suppress errors, never weaken assertions to go green.
- The format-and-lint hook runs on each edit; resolve anything it reports.
- Stay within accepted-ADR constraints.
- DO NOT introduce a dependency, library, or service the TDD did not sanction.
  Choosing a dependency requires the alternatives analysis that belongs in the
  design, not a snap decision at build time. If you find you need one, STOP and
  end with `BATCH_RESULT: BLOCKED new dependency needed: <name> (<why>)` so
  /tdd-author can weigh it and its alternatives and update the design.

Build-phase boundaries (these belong to OTHER gates — your job is to write code
and commit it, not to drive the running artifact):
- DO NOT spawn nested `claude` processes from inside the build (no `claude -p
  ...` from Bash, no embedded sub-claude orchestration). Driving the built
  artifact to verify its behavior is the runtime-verify gate's job, run by the
  runner in a SEPARATE process AFTER your build returns. If you spawn nested
  claude during build you are doing gate 3's work in gate 1, on the wrong
  process, with no verdict line the runner can parse.
- DO NOT use `pkill`, `killall`, or ANY pattern-based process killing
  (`pkill -f`, `pgrep | xargs kill`, etc.). A pattern broad enough to find your
  test invocations is almost certainly broad enough to match the runner's own
  `claude -p` parent — and killing your own parent ends the build with no
  `end_turn`, producing an empty log and a FAIL with no actionable diagnostic.
  If you must kill child processes you yourself spawned, track each child's PID
  from `$!` and kill ONLY those PIDs.
- DO NOT create runtime-driving fixtures in `/tmp` or anywhere outside the
  repo. The failing-test-first gate inspects commits; `verify.sh` runs the
  committed test suite + typecheck + lint. Both look at what is IN the repo.
  Out-of-repo `/tmp/...` fixtures and ad-hoc scratch dirs are gate 3's surface,
  not gate 1's — and they leave debris the runner cannot clean up.

Design blockers (the feedback edge): if a requirement is infeasible,
self-contradictory, or cannot be implemented without breaking an accepted ADR,
do NOT silently work around it. Stop and end with
`BATCH_RESULT: BLOCKED <one-line reason>`. The runner logs it to
docs/tdd/BLOCKERS.md for `/tdd-author` to revise the design. Use this only for
design-level problems, not ordinary bugs you can fix.

Close:
- Run the FULL test suite, typecheck, and linter; confirm green. An INDEPENDENT
  gate will re-run these (verify.sh — tests + typecheck + lint, with clippy at
  `-D warnings`), then a SEPARATE runtime-verification gate will DRIVE the
  built artifact at its observable surface (per the TDD's `## Verification
  plan`) — so make sure what you committed is RUNNABLE (entry points work,
  deps install, fixtures present), don't only run tests against it. throughline
  ships no verification harness: the runtime gate uses the project's own means
  (CLI, HTTP, library, log, DOM, …), delegating the *mechanism* to
  `superpowers:verification-before-completion` / `/verify` (FR-26 / ADR 0004).
  An isolated review in a SEPARATE process runs after that — self-attestation
  is not trusted, so actually make them pass. Resolve lint at the root cause,
  do not suppress it to get past the gate.
- Keep docs in sync IN THIS COMMIT — not a later sweep. Grep for every concept
  this feature changed (renamed types, dropped tools, swapped dependencies,
  revised flows). For each hit in a doc decide if it is now wrong and fix it:
  evergreen docs (README/ARCHITECTURE/INSTALL/CONTRIBUTING/CLAUDE/behavior spec)
  are edited in place; an `accepted` ADR or design doc whose SUBSTANCE is now
  wrong gets a superseding doc, not a rewrite. Small doc fixes ride in the
  feature commit; substantial doc work is a second commit in the same branch.
  Do not finish with known-stale docs.
- Commit with a descriptive message referencing the TDD and the PRD requirement
  numbers. Do NOT open a PR, do NOT change the TDD's `Status:`, and do NOT run
  the final review yourself — the runner owns branches, PRs, the verify + review
  gates, and the flip to `implemented` (only after both gates pass).
- End your final message with exactly `BATCH_RESULT: OK` on success,
  `BATCH_RESULT: FAIL <reason>` if you could not complete it, or
  `BATCH_RESULT: BLOCKED <reason>` for a design-level blocker.
