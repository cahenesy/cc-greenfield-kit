#!/usr/bin/env bash
# bootstrap-marker-wiring.test.sh — eval for TDD 0009 / FR-31 + FR-32 + FR-33:
# pins the wiring contract the /bootstrap-project skill prompt MUST carry so the
# two markers and the .gitignore entry are not optional.
#
# This is a prompt-contract test: the skill is model-driven, so the regression
# we guard is the prompt silently losing its marker wiring (exactly the kind of
# drift where the completion step gets scoped to greenfield only and the
# brownfield path stops recording the marker). It does NOT drive Claude — the
# helpers it references are unit-tested in repo-id/gitignore/markers .test.sh,
# and the live bootstrap behavior is covered by the runtime-verify gate.
#
# Written red-first against the first step-2 commit: that commit added Step 0 +
# a greenfield-only "On completion" section but left the BROWNFIELD completion
# path with no marker-recording instruction (case [E] fails). The fix broadens
# completion to every bootstrap run and adds an explicit brownfield instruction.
#
# Run: bash tests/bootstrap-marker-wiring.test.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="$REPO/skills/bootstrap-project/SKILL.md"
RESULTS="$(mktemp)"; export RESULTS
ok()  { printf 'ok\n'   >>"$RESULTS"; printf '  ok   — %s\n' "$1"; }
bad() { printf 'fail\n' >>"$RESULTS"; printf '  FAIL — %s\n' "$1"; }

has()  { grep -Fq "$1" "$SKILL"; }   # fixed-string presence
hasre(){ grep -Eiq "$1" "$SKILL"; }  # case-insensitive regex presence

# --- [A] the skill exists and sources all three helpers ----------------------
echo "[A] skill sources the three lib helpers"
for lib in repo-id.sh markers.sh gitignore.sh; do
  if has "scripts/lib/$lib"; then ok "sources $lib"; else bad "does not source $lib"; fi
done

# --- [B] the skill calls each marker/gitignore write helper ------------------
echo "[B] skill invokes the write helpers (markers + gitignore)"
for fn in tl_repo_marker_write tl_local_marker_write tl_gitignore_add_line tl_repo_marker_read; do
  if has "$fn"; then ok "calls $fn"; else bad "never calls $fn"; fi
done

# --- [C] Step 0 short-circuit prints the FR-31 'already bootstrapped' line ----
echo "[C] Step 0 documents the byte-stable short-circuit"
has "already bootstrapped at" && ok "prints 'already bootstrapped at ...'" \
                              || bad "missing the 'already bootstrapped at' short-circuit line"
hasre "byte-identical|do not rewrite the marker|never rewrit" \
  && ok "states the marker must stay byte-identical on re-run" \
  || bad "does not state the re-run marker must stay byte-identical"

# --- [D] the FR-32 ignore line is the exact implement-logs path --------------
echo "[D] the gitignore entry is docs/tdd/.implement-logs/"
has 'docs/tdd/.implement-logs/' && ok "references docs/tdd/.implement-logs/" \
                                || bad "missing docs/tdd/.implement-logs/ ignore entry"

# --- [E] marker recording is wired for BOTH greenfield AND brownfield --------
# The drift this guards: completion recording scoped to greenfield only. The
# brownfield path must also record the markers on completion.
echo "[E] completion recording covers the brownfield path, not just greenfield"
# A brownfield-labelled completion instruction must exist (a heading or step
# that ties 'brownfield' to recording the markers / running the completion step).
if grep -Eiq '^#+ +brownfield' "$SKILL" \
   && awk '
       /^#+ +[Bb]rownfield/{inbf=1}
       inbf && /record the bootstrap markers|tl_repo_marker_write|On completion/{found=1}
       /^#+ /{ if (seen && !/[Bb]rownfield/) inbf=0 } {seen=1}
       END{exit !found}
     ' "$SKILL"; then
  ok "a brownfield completion section ties brownfield -> record markers"
else
  bad "no brownfield completion instruction records the markers (greenfield-only drift)"
fi

echo
PASS="$(grep -c '^ok$'   "$RESULTS" 2>/dev/null)"; PASS="${PASS:-0}"
FAIL="$(grep -c '^fail$' "$RESULTS" 2>/dev/null)"; FAIL="${FAIL:-0}"
rm -f "$RESULTS"
echo "=== bootstrap-marker-wiring eval: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
