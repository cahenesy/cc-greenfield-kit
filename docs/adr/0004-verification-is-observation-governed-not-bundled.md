# 0004. Verification is runtime observation at the surface; governed, not bundled
Status: accepted
Date: 2026-05-25
Scope: workflow / verification

## Context

PRD revision `962732c` introduced verification-as-observation (FR-23–FR-26) as a
first-class principle threaded through every phase of the pipeline. Until now
throughline's only pre-flip behavioral check was `ci-checks.sh` — a mechanical re-run
of the project's tests, typecheck, and linter. But passing tests answer "does CI go
green", not "does the real artifact behave where a user (human or programmatic)
actually meets it". A `test(failing):`-first commit and a green `ci-checks.sh` can both
hold while the shipped CLI prints the wrong thing, the endpoint returns the wrong
shape, or the library throws on the documented happy path. The PRD names this gap and
asks throughline to *govern* verification from the requirement forward without
*owning* the verification machinery (which differs per artifact: CLI stdout, HTTP
responses, library return values, log lines, DOM, …).

This decision sits alongside ADR 0003 (delegate the build to
`superpowers:test-driven-development` and code review to `pr-review-toolkit`, keep
`security-reviewer` in the gate). It extends that same delegation logic to the
verification *mechanism*; it does not reverse anything in 0003.

## Decision

Treat **verification** as confirming the real artifact behaves at its observable
surface — distinct from tests/typechecks, which remain CI's job (`ci-checks.sh`).

- **Carry it from the PRD forward.** Each PRD requirement states an observable
  acceptance criterion (an observation of the artifact's surface, not "a test
  exists"); each TDD carries a verification plan (observable surface → observation
  point(s) → expected observations); `/implement` runs a runtime-verification gate
  that drives the built artifact to those observation points and confirms the
  expected observations hold. The three are one thread, not three afterthoughts.
- **Govern, do not bundle.** throughline owns only the *requirement* that a
  verification plan exists, is executed, and yields evidence. It ships **no**
  verification harness or framework. The *mechanism* is the project's, delegated to
  `superpowers:verification-before-completion` / the `/verify` skill and to
  project-appropriate means.
- **Keep the verdicts honest.** Runtime verification reports `PASS | FAIL | BLOCKED |
  SKIP`: "observed and wrong" (FAIL) is never conflated with "couldn't observe"
  (BLOCKED) or "nothing to observe" (SKIP, with justification, never silent), and
  ambiguity resolves to FAIL, never a false PASS.

Rejected alternatives:
- **Treat a green test suite as verification.** Conflates CI with verification — the
  exact gap this decision exists to close; a passing test ≠ an observed-correct
  artifact.
- **Bundle a verification harness/framework into throughline.** Lock-in, and it could
  not generalize across CLI/HTTP/library/DOM artifacts; it also contradicts the
  delegation posture of ADR 0002–0003. The mechanism belongs to the project.
- **Verify only at the end (no PRD/TDD carry-through).** Loses the
  requirement → design → build thread that makes verification traceable; verification
  becomes an afterthought rather than a governed gate.

## Consequences

- `/implement` gains a **fourth** independent gate — runtime verification — between
  `ci-checks.sh` and the independent review; a TDD flips to `implemented` only on a
  verification `PASS` (or a justified `SKIP`), never on passing tests alone.
- The `design-reviewer` gate BLOCKs a TDD with a missing or non-actionable
  verification plan; `/prd-author` enforces an observable acceptance criterion for
  new requirements.
- No verification framework is vendored into consumer repos; the mechanism stays
  delegated (consistent with NFR-5 and ADR 0003).
- Promoted by TDD 0007; complements ADR 0003 and supersedes nothing.
