# 0002. Depend on the official plugins and delegate overlapping engineering to them

Status: superseded by 0003
Date: 2026-05-25
Scope: workflow / plugin-architecture
Supersedes: 0001

## Context

ADR 0001 made throughline a **soft** overlay: self-contained (its own `/review`
skill + subagents), ingesting superpowers artifacts only if present, with
engineering-layer slimming explicitly *out of scope*. On reflection the intent is
stronger: throughline should be a true **layer on top of** the official,
actively-maintained plugins. Where throughline ships a script/subagent/skill that
*fully overlaps* a better-maintained official plugin or built-in **and** can
interoperate with throughline's flow, we should deprecate ours and prefer theirs.
The governance layer (PRD/TDD/ADR) stays — it has no official equivalent.

Overlap assessment:

- `/review` skill ↔ built-in `/code-review` + pr-review-toolkit `/review-pr` — **full overlap**.
- `explore` agent ↔ built-in `Explore` agent — **full overlap**.
- `code-reviewer` agent ↔ pr-review-toolkit `code-reviewer` (richer: silent-failure-hunter, type-design-analyzer, pr-test-analyzer) — **full overlap**; used by the `/implement` review gate.
- `security-reviewer` agent ↔ built-in `/security-review` — **full coverage** (pr-review-toolkit has no security agent; `security-guidance` is a reminder hook, not a reviewer).
- `build-prompt.md`'s failing-test-first discipline ↔ `superpowers:test-driven-development` — **overlap** (restated rather than referenced).
- **No overlap → KEEP:** the PRD/TDD/ADR skills, `design-reviewer` (reviews design docs, not code), `implement.sh` (unattended, mechanically-gated orchestration — no official equivalent), `ci-checks.sh` (mechanical tests+typecheck+lint gate), the `format-and-lint` hook.

## Decision

1. **Depend on the official plugins.** Throughline declares `superpowers` and
   `pr-review-toolkit` (both in `claude-plugins-official`) as cross-marketplace
   dependencies in `plugin.json`, with
   `allowCrossMarketplaceDependenciesOn: ["claude-plugins-official"]` in
   `marketplace.json`. (Cross-marketplace auto-install requires the user to already
   have `claude-plugins-official` added; version constraints need Claude Code ≥ 2.1.110.)
2. **Deprecate-and-prefer.** Any throughline piece that fully overlaps a maintained
   official plugin or built-in *and* interoperates is removed in favor of the
   official one.
3. **Keep governance + unique orchestration** (the KEEP list above).
4. **Phased rollout** (don't delete a working gate before its replacement is proven):
   - **Phase 1** (this ADR's PR): remove the `/review` skill (→ built-in
     `/code-review` + pr-review-toolkit) and the `explore` agent (→ built-in
     `Explore`); declare the dependencies; update docs.
   - **Phase 2** (after a verification spike): rewire `/implement`'s gates —
     `build-prompt.md` → `superpowers:test-driven-development`, `review-prompt.md` →
     pr-review-toolkit `code-reviewer` + built-in `/security-review` — then delete
     the now-redundant `code-reviewer`, `security-reviewer`, and `test-writer`
     agents. Gated on a spike proving those skills/agents can be dispatched from the
     detached `claude -p` build/review processes and that the cross-model review
     diversity still holds.

## Consequences

- Throughline is **no longer standalone** — it requires superpowers + pr-review-toolkit.
  The "layer on top" is now real, not aspirational.
- Less throughline code to maintain; the engineering layer tracks Anthropic's
  maintained versions, and reviews get richer (pr-review-toolkit's set + the
  security team's `/security-review`).
- **Install prerequisite:** users must have `claude-plugins-official` added, else
  throughline loads with a `dependency-unsatisfied` error until they add it (or
  install the deps manually). Documented in the README.
- Carries forward the ADR 0001 decisions that remain true — governance ownership,
  the explicit-command ownership signal, canonical `docs/{PRD,tdd,adr}`, and
  ingest-not-relocate of `docs/superpowers/*`. Only the "stay self-contained /
  slimming out of scope" stance is reversed.
