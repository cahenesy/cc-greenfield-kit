# Product Requirements: throughline

> Retroactively authored to capture the system's existing functionality as the
> design-of-record baseline. New capabilities are added from here via the normal
> `/prd-author` → `/tdd-author` → `/implement` flow.

## Problem & context

Building complex software with AI coding agents tends to lose the *design* and the
*decisions*: requirements and architectural rationale live in transient chat, "done"
is self-reported, and implementation is ungated. Generic engineering discipline (TDD,
code review, worktrees) is well covered by Anthropic's official Claude Code plugins
(superpowers, pr-review-toolkit), but those provide no persistent, traceable system
of record for *what* is being built and *why*.

throughline is a thin **governance overlay** for Claude Code: a persistent
PRD → TDD → ADR design-doc pipeline with phase-gate PRs and gated, unattended
implementation. It owns governance and traceability and **depends on / delegates**
discovery + engineering to the official plugins (see ADRs 0001–0003).

## Users & goals

- **Primary user:** a developer using Claude Code who wants design-docs-before-code
  discipline, an auditable thread from requirement → design → decision →
  implementation, and unattended-but-gated builds — without re-implementing the
  generic engineering layer.
- **Success looks like:** every shipped change traces to an approved requirement and
  design; architectural decisions are recorded and binding; no code is marked "done"
  on self-report; and the human stays in control via a merge gate at each phase.

## Requirements

Functional requirements (FR) and non-functional requirements (NFR), each
independently verifiable.

### Setup
- **FR-1 Toolchain bootstrap.** `/bootstrap-project` detects the primary language and
  ensures a linter, formatter, and test framework are configured (defaults: JS/TS
  prettier+eslint+vitest; Python ruff+pytest; Rust rustfmt+clippy+cargo test; Go
  gofmt+golangci-lint+go test).
- **FR-2 Greenfield vs brownfield handling.** On an empty project it installs and
  configures the defaults and writes one trivial passing test; on an existing project
  lacking tooling it does NOT silently install — it flags and asks first; existing
  tooling is reused, not swapped.
- **FR-3 Docs scaffold + git init.** It scaffolds `docs/PRD.md` (stub),
  `docs/adr/INDEX.md`, `docs/tdd/`, and a `docs/README.md` (canonical-vs-transient
  note), then initializes git on `main`.

### Requirements authoring
- **FR-4 PRD of record.** `/prd-author` produces/updates `docs/PRD.md` — the WHAT and
  WHY only (no architecture, tech choices, or implementation). Requirements are
  numbered and independently testable; it records non-goals, constraints, and open
  questions, leaving unresolved items open rather than inventing answers.
- **FR-5 PRD rigor.** It runs a scope-decomposition check (split multi-product asks),
  applies YAGNI, and runs an inline self-review (placeholder / consistency / scope /
  ambiguity) before opening the PR.
- **FR-6 PRD phase gate.** It commits to a `docs/prd/<slug>` branch and opens a PRD
  PR; it never auto-merges (the human merge approves requirements and anchors the
  diff the design step reads).

### Design authoring
- **FR-7 Delta-driven design.** `/tdd-author` runs once per PRD update: it establishes
  the previously-designed PRD revision (`PRD-rev` in the latest TDD), diffs the PRD,
  maps existing TDD coverage, and decides the set of TDDs the change needs —
  presenting that plan for approval before writing.
- **FR-8 TDD content + traceability.** Each TDD is written `Status: draft` with a
  requirement-traceability table (every in-scope FR/NFR → design element), a
  "dependencies considered" section requiring ≥1 concrete rejected alternative per new
  dependency, and no placeholder / hand-waving design content.
- **FR-9 ADR evaluation + creation.** `/tdd-author` evaluates the design against
  existing ADRs and, on approval, records durable decisions via `/adr-new`. Only
  `accepted` ADRs bind new TDDs.
- **FR-10 Self-review + independent design-critique gate.** Before opening the design
  PR it self-reviews, then spawns the `design-reviewer` (fresh context, different
  model) which blocks on untraced requirements, under-specified interfaces, a missing
  alternatives analysis, or ADR conflicts; the verdict rides in the PR body.
- **FR-11 Design phase gate.** It commits the TDD set + any promoted ADRs together on
  a `docs/design/<slug>` branch and opens the design PR; it never auto-merges.

### Decisions
- **FR-12 Append-only ADRs.** `/adr-new` records decisions to `docs/adr/NNNN-*` with a
  status (`proposed` | `accepted` | `superseded by NNNN`) and maintains `INDEX.md`. An
  accepted ADR is never edited in substance — a change is a new ADR that supersedes
  the old one, flipping only its status line.

### Implementation
- **FR-13 Merge-triggered build.** `/implement` builds every TDD merged to the
  integration branch and not yet `implemented`; the design-PR merge is the build
  trigger — there is no manual `Status: ready` step. A path argument builds one TDD.
- **FR-14 Detached, isolated execution.** Builds run in detached `claude -p`
  processes, each in a dedicated git worktree, so the runner never touches the live
  working tree or session. Modes: sequential (default; stacked, one PR per TDD),
  `--combined` (one PR), `--parallel` (one worktree/PR per feature).
- **FR-15 Three independent gates.** A TDD flips to `implemented` only after (a)
  failing-test-first discipline — a `test(failing):` commit precedes the
  implementation, following `superpowers:test-driven-development`; (b) a mechanical
  `verify.sh` re-run of tests + typecheck + linter; and (c) an independent review in a
  separate process on a different model (`pr-review-toolkit:code-reviewer` +
  `silent-failure-hunter` + `throughline:security-reviewer`) returning
  `REVIEW_RESULT: PASS`. Self-reported success is not trusted.
- **FR-16 Never merges; halt-on-failure.** `/implement` opens PRs but never merges. In
  sequential mode a failed gate halts the run and marks downstream TDDs `BLOCKED`
  rather than building on a broken base.
- **FR-17 Design-blocker feedback loop.** A requirement that proves infeasible or
  self-contradictory at build time is recorded to `docs/tdd/BLOCKERS.md` (a `BLOCKED`,
  not a `FAIL`) for `/tdd-author` to resolve in the next design pass.
- **FR-18 Resume safety + single-run lock.** A TDD already `implemented` on an
  existing un-merged branch is skipped (no duplicate work or PRs; `--rebuild`
  overrides), and a single-run lock prevents a second concurrent `/implement` on the
  same repo.
- **FR-19 Report + merge plan.** Each run writes a report with per-TDD status and log
  paths and, in sequential mode, an ordered bottom-up merge plan that warns a
  squash-merge breaks the stack.
- **FR-20 Worktree dependency install.** Each fresh build worktree installs the
  project's dependencies first (package-manager-aware) since a worktree carries no
  gitignored `node_modules`; opt out with `THROUGHLINE_SKIP_DEPS=1`.

### Quality hook & delegation
- **FR-21 Format + lint hook.** A `format-and-lint` PostToolUse hook formats then
  lints edited files when a linter is configured (no-op otherwise), debounced, for
  JS/TS, Python, Rust, and Go; lint failures are surfaced into the session for
  root-cause fixing.
- **FR-22 Layer-on-top delegation.** throughline depends on `superpowers` +
  `pr-review-toolkit` (declared cross-marketplace dependencies) and delegates
  discovery (`brainstorming`) and generic engineering (TDD, code review, the `Explore`
  agent) to them and to built-ins; on-demand code review is `/code-review` +
  `/review-pr`. `docs/PRD.md` + `docs/tdd/` + `docs/adr/` are canonical;
  `docs/superpowers/*` is transient input — ingested, never relocated.

### Non-functional
- **NFR-1 Human control via merge gates.** Every phase (requirements, design,
  implementation) ends in a PR the human merges; the plugin never merges.
- **NFR-2 Context hygiene.** Autonomous work runs in subagents / detached processes so
  the interactive session stays clean; the workflow is one fresh session per command.
- **NFR-3 Model diversity.** Builds run on the best model (opus default); the review
  gate runs on a different model (sonnet default) so the reviewer does not share the
  author's blind spots. Overridable via flags/env.
- **NFR-4 Verdict honesty.** Outcomes distinguish `PASS` / `FAIL` / `BLOCKED` —
  "couldn't complete" and "design-infeasible" are not conflated with
  "observed and wrong".
- **NFR-5 Centrally maintained.** Scripts and skills run from the plugin cache (not
  vendored into consumer repos), so updates reach every project.

## Non-goals

- Owning **discovery / ideation** (brainstorming) — that is superpowers' job.
- Owning **generic engineering mechanics** (TDD execution, code review, worktrees, the
  Explore agent) — delegated to superpowers / pr-review-toolkit / built-ins.
- **Auto-merging** PRs or otherwise removing the human gate.
- Replacing **CI**; `verify.sh` is a pre-flip gate, not a CI system.
- **Bite-sized task-plan documents**; TDDs are designs, not step-by-step build scripts
  (the step-level discipline lives in `/implement`).
- First-class support for **non-git / no-remote** workflows beyond a basic "skip git"
  escape hatch.

## Constraints & assumptions

- A Claude Code plugin; requires the `claude-plugins-official` marketplace added and
  Claude Code ≥ 2.1.110 for cross-marketplace dependency resolution.
- PR creation needs a git remote + the `gh` CLI; without them, commits stay on
  branches to be PR'd manually.
- The integration branch is auto-detected (`origin`'s default → `main` → `master`);
  override with `THROUGHLINE_INTEGRATION_BRANCH`.
- Default models: build `opus`, review `sonnet` (override via `--model` /
  `--review-model` or `THROUGHLINE_BUILD_MODEL` / `THROUGHLINE_REVIEW_MODEL`).

## Open questions

- None outstanding for the current (retroactively documented) functionality.
