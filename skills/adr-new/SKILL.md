---
name: adr-new
description: Create a new Architecture Decision Record with append-only, status-gated supersession, and update the ADR index. Invoke with /adr-new, or let /tdd-author invoke it on approval of an ADR action (this skill stays model-invocable for that reason).
---

# New ADR

Record a durable architectural decision or established pattern. ADRs are the
sparse, forward-feeding memory loaded into every future TDD — keep the bar high
and the set small.

## Rules — enforce strictly

- APPEND-ONLY ON SUBSTANCE. Once an ADR is `accepted` (or built upon), its
  Context/Decision/Consequences are historical record. Light editorial touch-ups
  are fine — typos, a broken link, flipping `proposed`→`accepted`, marking
  `superseded by`. Anything that changes the SUBSTANCE of the decision is a new
  superseding ADR, never an edit. Rewriting the body destroys the record of what
  was decided and why at the time.
- Assign the next zero-padded number: highest existing in `docs/adr/` + 1.
- Every ADR has Status: `proposed` | `accepted` | `superseded by NNNN`.
- To reverse or replace a prior decision: create a NEW ADR with
  `Supersedes: NNNN` that captures the new context, decision, and consequences
  in FULL; then change ONLY the old ADR's Status line to `superseded by <new>`.
  Never delete the old ADR. Update any design docs that referenced the old ADR's
  substance to point at the new one.
- Challenging an accepted decision is encouraged when new information surfaces (a
  dependency's license, a competitor's architecture, a UX constraint) — say so
  plainly and supersede. Changing a decision early is far cheaper than discovering
  it was wrong after weeks of building on it. ADRs are accepted, not immutable.
- After writing, update `docs/adr/INDEX.md` (create if absent): add the new row
  and refresh the superseded ADR's status so both rows reflect the new state.

## ADR template

```
# NNNN. <title>
Status: accepted
Date: <YYYY-MM-DD>
Scope: <domain — used by the index and by TDD relevance matching>
Supersedes: <NNNN, if applicable>

## Context
## Decision
## Consequences
```

## Index format — docs/adr/INDEX.md

```
# ADR Index
> Only `accepted` ADRs are binding constraints for new TDDs.

| #    | Title   | Status   | Scope   |
|------|---------|----------|---------|
| 0001 | <title> | accepted | <scope> |
```

Keep each row to one line so the whole index stays cheap to keep in context.

## Commits
This skill only WRITES files (the ADR and the index). It does not commit or
branch. ADRs are committed by the design phase (`/tdd-author`) together with the
TDD set, so they travel in the design PR that justifies them.
