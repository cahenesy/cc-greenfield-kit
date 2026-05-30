#!/usr/bin/env bash
# gitignore.sh — idempotent .gitignore line management for the consumer repo.
#
# Sourced by /bootstrap-project (post-success) and the SessionStart reconcile
# hook (on a repo-marker version mismatch) to ensure throughline's per-run
# artifacts stay untracked (TDD 0009 / FR-32). No top-level side effects.
#
#   tl_gitignore_add_line <line>
#     Ensure the repo-root .gitignore (relative to `git rev-parse
#     --show-toplevel`) contains an EXACT-match line equal to <line>; create the
#     file if absent. Returns 0 in both the "added" and "already present" cases;
#     a re-run is byte-identical when the line is already present.

tl_gitignore_add_line() {
  local line="$1" toplevel gi
  toplevel="$(git rev-parse --show-toplevel 2>/dev/null)" \
    || { echo "tl_gitignore_add_line: not inside a git repo" >&2; return 1; }
  gi="$toplevel/.gitignore"

  # Already present (exact line): no-op, keeps the file byte-identical.
  if [ -f "$gi" ] && grep -Fxq "$line" "$gi"; then
    return 0
  fi

  # If the file exists but its last byte is not a newline, start a fresh line
  # so we never merge into the prior entry (`build/` + `docs/...` -> one line).
  if [ -s "$gi" ] && [ -n "$(tail -c1 "$gi")" ]; then
    printf '\n' >> "$gi"
  fi
  printf '%s\n' "$line" >> "$gi"
}
