#!/usr/bin/env bash
# throughline-session-reconcile.sh — SessionStart hook (TDD 0009 / FR-34, FR-35).
#
# Reconciles the two install/update markers against the running plugin version
# WITHOUT launching Claude. Every step is best-effort and SILENT on failure: a
# SessionStart hook must never noise up or break an unrelated session start.
# Its only side effects are the cheap idempotent repo edits FR-34 sanctions
# (the .gitignore entry, missing docs-scaffold files, the repo marker) and, on a
# local-impacting update, exactly one stderr notice. It never installs software,
# never touches git refs, and never spawns Claude.
set -uo pipefail

PR="${CLAUDE_PLUGIN_ROOT:-}"

# 1. Move to the repo root; outside a git repo there is no throughline project.
toplevel="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
[ -n "$toplevel" ] || exit 0
cd "$toplevel" 2>/dev/null || exit 0

# 2. Short-circuit: no committed marker -> not a throughline-bootstrapped repo.
#    This single file-stat is the only session-start cost outside throughline
#    projects (NFR-5 spirit).
[ -f docs/.throughline-bootstrap.json ] || exit 0

# 3. Source the helpers. If the plugin path is broken we cannot reconcile —
#    exit silently rather than break the session.
for _lib in repo-id.sh markers.sh gitignore.sh; do
  # shellcheck disable=SC1090
  source "$PR/scripts/lib/$_lib" 2>/dev/null || exit 0
done

marker="$(tl_repo_marker_read 2>/dev/null || printf '{}')"
applied="$(printf '%s\n' "$marker"   | sed -n 's/.*"plugin_version_applied"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'      | head -n1)"
language="$(printf '%s\n' "$marker"  | sed -n 's/.*"language"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'                    | head -n1)"
steps_csv="$(printf '%s\n' "$marker" | sed -n 's/.*"repo_steps_applied"[[:space:]]*:[[:space:]]*\[\([^]]*\)\].*/\1/p' | head -n1 | tr -d ' "')"

# 4. Current plugin version (one field, no jq dependency).
current="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$PR/.claude-plugin/plugin.json" 2>/dev/null | head -n1)"
[ -n "$current" ] || exit 0   # no target version -> nothing to reconcile against

# 5. Repo reconcile. A version mismatch — or a malformed marker that read as
#    "{}", leaving $applied empty — re-applies the cheap idempotent repo steps
#    and bumps the marker to the running version. A downgrade (applied > current)
#    is handled the same as an upgrade: any difference triggers reconcile. Silent.
if [ "$applied" != "$current" ]; then
  tl_gitignore_add_line "docs/tdd/.implement-logs/" 2>/dev/null || true

  # Any missing docs-scaffold files (FR-3); create only when absent so existing
  # (richer) content is never overwritten.
  mkdir -p docs/tdd docs/adr 2>/dev/null || true
  [ -e docs/PRD.md ] || cat > docs/PRD.md <<'EOF' 2>/dev/null || true
# Product Requirements

## Problem & context

## Requirements

## Non-goals

## Constraints & assumptions

## Open questions
EOF
  [ -e docs/adr/INDEX.md ] || cat > docs/adr/INDEX.md <<'EOF' 2>/dev/null || true
# ADR Index

> Only `accepted` ADRs are binding constraints for new TDDs.

| #    | Title | Status | Scope |
|------|-------|--------|-------|
EOF
  [ -e docs/README.md ] || cat > docs/README.md <<'EOF' 2>/dev/null || true
# Docs

`docs/PRD.md`, `docs/tdd/`, and `docs/adr/` are the canonical design-of-record.
Anything under `docs/superpowers/` is transient input — ingested, never
treated as authoritative or relocated.
EOF

  # Bump the repo marker to the running version, preserving the recorded
  # language + applied steps. If this write fails it is silent (best-effort);
  # the next session-start retries.
  tl_repo_marker_write "$current" "$language" "$steps_csv" 2>/dev/null || true
fi

# 6. Local notice. Gated on jq AND a valid releases manifest: surface exactly one
#    line ONLY when the local marker's plugin_version_seen is behind current AND a
#    release flagged local_impacting falls in the gap (seen, current]. Any missing
#    condition -> no notice (conservative: better silent than spurious). Version
#    comparison is done in jq via numeric-array ordering (semver), so no semver
#    CLI dependency is introduced.
releases="$PR/.claude-plugin/releases.json"
if command -v jq >/dev/null 2>&1 && [ -f "$releases" ] && jq -e . "$releases" >/dev/null 2>&1; then
  seen="$(tl_local_marker_read 2>/dev/null | jq -r '.plugin_version_seen // empty' 2>/dev/null)"
  if [ -n "$seen" ] && [ "$seen" != "$current" ]; then
    impacting="$(jq -r --arg seen "$seen" --arg cur "$current" '
      [ .[]
        | select(.local_impacting == true)
        | .version
        | select((split(".") | map(tonumber)) >  ($seen | split(".") | map(tonumber)))
        | select((split(".") | map(tonumber)) <= ($cur  | split(".") | map(tonumber)))
      ] | length' "$releases" 2>/dev/null)"
    if [ "${impacting:-0}" -gt 0 ] 2>/dev/null; then
      printf 'throughline updated %s→%s; run /bootstrap-project to refresh your local toolchain\n' "$seen" "$current" >&2
      # Advance plugin_version_seen so the notice fires exactly once across
      # sessions. Best-effort: an unwritable ${CLAUDE_PLUGIN_DATA} just means the
      # next session re-notifies (acceptable) rather than a hard failure.
      tl_local_marker_write "$current" deps_installed 2>/dev/null || true
    fi
  fi
fi

exit 0
