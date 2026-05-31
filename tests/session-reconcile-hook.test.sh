#!/usr/bin/env bash
# session-reconcile-hook.test.sh — eval for TDD 0009 / FR-34 + FR-35:
# hooks/throughline-session-reconcile.sh is the SessionStart hook that reconciles
# the two install/update markers against the running plugin version WITHOUT
# launching Claude. This drives the hook as a black box at its observable
# surface (stderr, repo files, the markers) across the TDD's verification
# scenarios:
#   [B] non-throughline repo (no marker)        -> silent, no file changes   (a)
#   [C] marker at the current version           -> silent, no file changes   (b)
#   [D] backdated repo marker, all-false release -> .gitignore + marker bump,
#                                                  no notice                  (c)
#   [E] backdated local marker, impacting release -> ONE stderr notice; a
#                                                   second run is silent      (d)
#   [F] hooks.json registers SessionStart and keeps PostToolUse
#   [G] malformed marker -> treated as needs-reconcile (rebuilt, no crash)
#   [H] jq absent -> no notice even with an impacting release (notice is jq-gated)
#
# Run: bash tests/session-reconcile-hook.test.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$REPO/hooks/throughline-session-reconcile.sh"
HOOKS_JSON="$REPO/hooks/hooks.json"
RESULTS="$(mktemp)"; export RESULTS
ok()  { printf 'ok\n'   >>"$RESULTS"; printf '  ok   — %s\n' "$1"; }
bad() { printf 'fail\n' >>"$RESULTS"; printf '  FAIL — %s\n' "$1"; }
ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT

# Build a fake plugin root: <dir> <version> [releases-json]. Carries the real
# scripts/lib helpers so the hook sources the same code it ships with.
make_plugin_root() {
  local d="$1" v="$2" rel="${3-}"
  mkdir -p "$d/.claude-plugin"
  cp -r "$REPO/scripts" "$d/scripts"
  printf '{ "name": "throughline", "version": "%s" }\n' "$v" > "$d/.claude-plugin/plugin.json"
  [ -n "$rel" ] && printf '%s\n' "$rel" > "$d/.claude-plugin/releases.json"
  printf '%s\n' "$d"
}

# Fresh git repo. Optionally seed a committed repo marker at <applied> and a
# local marker at <seen>. Scaffolds the docs tree so the hook's "create if
# missing" guards have nothing to add (isolating the .gitignore + marker bump).
make_repo() {  # <dir> <plugin-root> [applied] [seen] [data-dir]
  local d="$1" pr="$2" applied="${3-}" seen="${4-}" data="${5-}"
  mkdir -p "$d/docs/tdd" "$d/docs/adr"
  printf '# PRD\n' > "$d/docs/PRD.md"
  printf '# ADR Index\n' > "$d/docs/adr/INDEX.md"
  printf '# Docs\n' > "$d/docs/README.md"
  git -C "$d" init -q; git -C "$d" config user.email t@t.t; git -C "$d" config user.name t
  if [ -n "$applied" ]; then
    # export, not a per-command prefix: the prefix form would scope the env var
    # to `source` alone, leaving the write helper to run without it.
    ( cd "$d" && export CLAUDE_PLUGIN_ROOT="$pr"
      source "$pr/scripts/lib/repo-id.sh"
      source "$pr/scripts/lib/markers.sh"
      tl_repo_marker_write "$applied" shell scaffold ) >/dev/null 2>&1
  fi
  if [ -n "$seen" ] && [ -n "$data" ]; then
    ( cd "$d" && export CLAUDE_PLUGIN_ROOT="$pr" CLAUDE_PLUGIN_DATA="$data"
      source "$pr/scripts/lib/repo-id.sh"
      source "$pr/scripts/lib/markers.sh"
      tl_local_marker_write "$seen" deps_installed ) >/dev/null 2>&1
  fi
  git -C "$d" add -A >/dev/null 2>&1; git -C "$d" commit -qm init >/dev/null 2>&1
}

# Runs the hook; leaves stderr in $ROOT/stderr and the exit code in $ROOT/hrc.
# (Not echoed via command substitution, so callers can read the rc — a $(...)
# subshell would swallow any variable set here.)
run_hook() {  # <repo> <plugin-root> [data-dir]
  local d="$1" pr="$2" data="${3-}"
  ( cd "$d" && CLAUDE_PLUGIN_ROOT="$pr" CLAUDE_PLUGIN_DATA="$data" bash "$HOOK" ) 2>"$ROOT/stderr" >"$ROOT/stdout"
  printf '%s' "$?" > "$ROOT/hrc"
}
hook_err() { cat "$ROOT/stderr"; }
hook_rc()  { cat "$ROOT/hrc"; }

marker_field() { sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" "$1" 2>/dev/null | head -n1; }

# --- [A] the hook exists and is syntactically valid --------------------------
echo "[A] the hook script exists and parses"
if [ -f "$HOOK" ]; then
  ok "throughline-session-reconcile.sh exists"
  bash -n "$HOOK" 2>/dev/null && ok "hook parses (bash -n)" || bad "hook has a syntax error"
else
  bad "hook script is missing"
fi

# --- [B] non-throughline repo: silent, no file changes (scenario a) ----------
echo "[B] no marker -> silent, no file changes"
PR1="$(make_plugin_root "$ROOT/pr1" 3.0.0)"
R="$ROOT/b"; mkdir -p "$R"; git -C "$R" init -q; git -C "$R" config user.email t@t.t; git -C "$R" config user.name t
printf 'hi\n' > "$R/file.txt"; git -C "$R" add -A >/dev/null 2>&1; git -C "$R" commit -qm init >/dev/null 2>&1
run_hook "$R" "$PR1"; err="$(hook_err)"
[ -z "$err" ] && ok "no stderr in a non-throughline repo" || bad "unexpected stderr: $err"
[ -z "$(git -C "$R" status --porcelain)" ] && ok "no file changes" || bad "hook modified files: $(git -C "$R" status --porcelain)"

# --- [C] marker at current version: silent, no file changes (scenario b) -----
echo "[C] marker at current version -> silent, no file changes"
DATA_C="$ROOT/c-data"
make_repo "$ROOT/c" "$PR1" 3.0.0 3.0.0 "$DATA_C"
run_hook "$ROOT/c" "$PR1" "$DATA_C"; err="$(hook_err)"
[ -z "$err" ] && ok "no stderr when already at current" || bad "unexpected stderr: $err"
[ -z "$(git -C "$ROOT/c" status --porcelain)" ] && ok "no file changes when already at current" \
  || bad "hook modified files: $(git -C "$ROOT/c" status --porcelain)"

# --- [D] backdated repo marker + all-false releases (scenario c) -------------
echo "[D] stale repo marker -> .gitignore reconciled + marker bumped, no notice"
REL_ALL_FALSE='[ { "version": "3.0.0", "local_impacting": false }, { "version": "2.0.0", "local_impacting": false } ]'
PR_D="$(make_plugin_root "$ROOT/pr-d" 3.0.0 "$REL_ALL_FALSE")"
DATA_D="$ROOT/d-data"
make_repo "$ROOT/d" "$PR_D" 2.0.0 2.0.0 "$DATA_D"
run_hook "$ROOT/d" "$PR_D" "$DATA_D"; err="$(hook_err)"
applied_after="$(marker_field "$ROOT/d/docs/.throughline-bootstrap.json" plugin_version_applied)"
[ "$applied_after" = "3.0.0" ] && ok "marker bumped to current (3.0.0)" || bad "marker not bumped (got '$applied_after')"
grep -Fxq 'docs/tdd/.implement-logs/' "$ROOT/d/.gitignore" 2>/dev/null \
  && ok ".gitignore reconciled with the implement-logs entry" || bad ".gitignore not reconciled"
[ -z "$err" ] && ok "no stderr notice (no local-impacting release in the gap)" || bad "unexpected notice: $err"

# --- [E] backdated local marker + impacting release -> ONE notice (scenario d)
echo "[E] impacting release in the gap -> exactly one notice; rerun is silent"
REL_IMPACT='[ { "version": "1.2.0", "local_impacting": false }, { "version": "1.1.0", "local_impacting": true }, { "version": "1.0.0", "local_impacting": false } ]'
PR_E="$(make_plugin_root "$ROOT/pr-e" 1.2.0 "$REL_IMPACT")"
DATA_E="$ROOT/e-data"
make_repo "$ROOT/e" "$PR_E" 1.0.0 1.0.0 "$DATA_E"
run_hook "$ROOT/e" "$PR_E" "$DATA_E"; err="$(hook_err)"
n="$(printf '%s\n' "$err" | grep -Fc 'throughline updated 1.0.0→1.2.0; run /bootstrap-project to refresh your local toolchain')"
[ "$n" = "1" ] && ok "exactly one local-impacting notice on stderr" || bad "expected one notice, got $n (stderr: $err)"
run_hook "$ROOT/e" "$PR_E" "$DATA_E"; err2="$(hook_err)"
n2="$(printf '%s\n' "$err2" | grep -Fc 'throughline updated')"
[ "$n2" = "0" ] && ok "a second session prints no notice (plugin_version_seen advanced)" \
  || bad "notice repeated on the second run ($n2)"

# --- [F] hooks.json registers SessionStart and preserves PostToolUse ---------
echo "[F] hooks.json registers the SessionStart hook + keeps format-and-lint"
if [ -f "$HOOKS_JSON" ] && python3 -m json.tool "$HOOKS_JSON" >/dev/null 2>&1; then
  if python3 - "$HOOKS_JSON" <<'PY'
import json, sys
h = json.load(open(sys.argv[1]))["hooks"]
ss = h.get("SessionStart", [])
cmds = [hh.get("command","") for grp in ss for hh in grp.get("hooks", [])]
assert any("throughline-session-reconcile.sh" in c for c in cmds), "SessionStart reconcile hook not registered"
pt = h.get("PostToolUse", [])
pcmds = [hh.get("command","") for grp in pt for hh in grp.get("hooks", [])]
assert any("format-and-lint" in c for c in pcmds), "PostToolUse format-and-lint dropped"
PY
  then ok "SessionStart reconcile registered and PostToolUse preserved"
  else bad "hooks.json missing the SessionStart entry or dropped PostToolUse"; fi
else
  bad "hooks.json absent or invalid JSON"
fi

# --- [G] malformed marker -> needs-reconcile, rebuilt, no crash --------------
echo "[G] malformed marker is treated as needs-reconcile (rebuilt to current)"
PR_G="$(make_plugin_root "$ROOT/pr-g" 3.0.0 "$REL_ALL_FALSE")"
R="$ROOT/g"; mkdir -p "$R/docs"; git -C "$R" init -q; git -C "$R" config user.email t@t.t; git -C "$R" config user.name t
printf '{ this is not valid json ' > "$R/docs/.throughline-bootstrap.json"
git -C "$R" add -A >/dev/null 2>&1; git -C "$R" commit -qm init >/dev/null 2>&1
run_hook "$R" "$PR_G" "$ROOT/g-data"; err="$(hook_err)"; HRC="$(hook_rc)"
if [ "$HRC" -eq 0 ]; then
  ok "hook exits 0 on a malformed marker (no crash)"
else
  bad "hook crashed on a malformed marker (rc=$HRC)"
fi
applied_g="$(marker_field "$R/docs/.throughline-bootstrap.json" plugin_version_applied)"
[ "$applied_g" = "3.0.0" ] && ok "malformed marker rebuilt at the current version" \
  || bad "malformed marker not rebuilt (got '$applied_g')"

# --- [H] jq absent -> no notice even with an impacting release ---------------
echo "[H] jq absent -> no local notice (the notice is jq-gated)"
BIN="$ROOT/h-bin"; mkdir -p "$BIN"
for t in bash git sed grep head tr mkdir cat date mv rm dirname tail cp ln awk sha256sum shasum env; do
  p="$(command -v "$t" 2>/dev/null)" && [ -n "$p" ] && ln -sf "$p" "$BIN/$t"
done
PR_H="$(make_plugin_root "$ROOT/pr-h" 1.2.0 "$REL_IMPACT")"
DATA_H="$ROOT/h-data"
make_repo "$ROOT/h" "$PR_H" 1.0.0 1.0.0 "$DATA_H"
err="$( ( cd "$ROOT/h" && CLAUDE_PLUGIN_ROOT="$PR_H" CLAUDE_PLUGIN_DATA="$DATA_H" PATH="$BIN" bash "$HOOK" ) 2>&1 >/dev/null )"
if printf '%s\n' "$err" | grep -Fq 'throughline updated'; then
  bad "printed a notice with jq absent (must be jq-gated): $err"
else
  ok "no notice printed when jq is unavailable"
fi

echo
PASS="$(grep -c '^ok$'   "$RESULTS" 2>/dev/null)"; PASS="${PASS:-0}"
FAIL="$(grep -c '^fail$' "$RESULTS" 2>/dev/null)"; FAIL="${FAIL:-0}"
rm -f "$RESULTS"
echo "=== session-reconcile-hook eval: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
