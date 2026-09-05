#!/usr/bin/env bash
# Unit test for lib/next_action.py: the Decision Policy state machine.
# Feeds synthetic report rows and asserts the emitted NEXT_ACTION directive,
# exit code, and attempt tracking across runs.

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NA="$SKILL_DIR/lib/next_action.py"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
STATE="$WORK/state.json"

FAILURES=0
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

run() {
  RC=0
  OUT="$(python3 "$NA" --state-file "$STATE" --branch main 2>&1)" || RC=$?
}

row_ok='pkg.Fine                                           complexity=3   coverage=100.0%  CRAP=3.0  OK           (new)'
row_needs='pkg.NeedsTests                                     complexity=5   coverage=40.0%  CRAP=12.0  NEEDS_TESTS  (new)'
row_hard='pkg.Big                                            complexity=9   coverage=88.0%  CRAP=9.2  HARD         (new)'
row_soft='pkg.Softy                                          complexity=7   coverage=90.0%  CRAP=7.1  SOFT         (new)'
row_soft2='pkg.Softy                                          complexity=7   coverage=92.0%  CRAP=7.5  SOFT         (new)'
row_soft_worse='pkg.Softy                                          complexity=9   coverage=92.0%  CRAP=9.0  HARD         (worsened)'
row_legacy='pkg.Legacy                                         complexity=12  coverage=50.0%  CRAP=22.5  HARD         (unchanged)'
row_main='main.run                                           complexity=9   coverage=n/a    CRAP=n/a    HARD_MAIN    (new)'

# T1: all green -> COMMIT_OK, exit 0
rm -f "$STATE"
run <<< "$row_ok"
[ "$RC" -eq 0 ] || fail "T1 exit ($RC != 0)"
grep -q 'COMMIT_OK' <<< "$OUT" || fail "T1 no COMMIT_OK"

# T2: NEEDS_TESTS beats HARD -> WRITE_TESTS, exit 1, hard func deferred
rm -f "$STATE"
run <<EOF
$row_needs
$row_hard
EOF
[ "$RC" -eq 1 ] || fail "T2 exit ($RC != 1)"
grep -q 'WRITE_TESTS' <<< "$OUT" || fail "T2 no WRITE_TESTS"
grep -q 'pkg.NeedsTests' <<< "$OUT" || fail "T2 missing needs-tests func"
grep -q 'REFACTOR' <<< "$OUT" && fail "T2 must not direct REFACTOR"
grep -q 'pkg.Big' <<< "$OUT" || fail "T2 should list deferred pkg.Big"

# T3: SOFT new, first run -> REFACTOR attempt 1 of 1
rm -f "$STATE"
run <<< "$row_soft"
[ "$RC" -eq 1 ] || fail "T3 exit ($RC != 1)"
grep -q 'REFACTOR' <<< "$OUT" || fail "T3 no REFACTOR"
grep -q 'attempt 1 of 1' <<< "$OUT" || fail "T3 not attempt 1 of 1"

# T4: identical re-run burns no attempt
run <<< "$row_soft"
grep -q 'attempt 1 of 1' <<< "$OUT" || fail "T4 re-run burned an attempt"

# T5: metrics changed, still SOFT -> attempts exhausted -> SURFACE_TO_USER
run <<< "$row_soft2"
[ "$RC" -eq 1 ] || fail "T5 exit ($RC != 1)"
grep -q 'SURFACE_TO_USER' <<< "$OUT" || fail "T5 no SURFACE_TO_USER"
grep -q '\-\-accept' <<< "$OUT" || fail "T5 missing --accept instruction"

# T6: user accepts -> COMMIT_OK with note
python3 "$NA" --state-file "$STATE" --branch main --accept 'pkg.Softy' >/dev/null || fail "T6 accept failed"
run <<< "$row_soft2"
[ "$RC" -eq 0 ] || fail "T6 exit ($RC != 0)"
grep -q 'COMMIT_OK' <<< "$OUT" || fail "T6 no COMMIT_OK"
grep -qi 'accepted' <<< "$OUT" || fail "T6 missing accepted note"

# T7: accepted function worsens -> acceptance revoked, gate red again
run <<< "$row_soft_worse"
[ "$RC" -eq 1 ] || fail "T7 exit ($RC != 1)"
grep -q 'COMMIT_OK' <<< "$OUT" && fail "T7 must not be COMMIT_OK"

# T8: HARD but unchanged legacy -> COMMIT_OK with remains-at note
rm -f "$STATE"
run <<< "$row_legacy"
[ "$RC" -eq 0 ] || fail "T8 exit ($RC != 0)"
grep -q 'COMMIT_OK' <<< "$OUT" || fail "T8 no COMMIT_OK"
grep -q 'remains at CRAP=22.5' <<< "$OUT" || fail "T8 missing legacy note"

# T9: HARD_MAIN new -> REFACTOR with thin-main guidance
rm -f "$STATE"
run <<< "$row_main"
[ "$RC" -eq 1 ] || fail "T9 exit ($RC != 1)"
grep -q 'REFACTOR' <<< "$OUT" || fail "T9 no REFACTOR"
grep -qi 'main' <<< "$OUT" || fail "T9 missing main guidance"
grep -qi 'extract' <<< "$OUT" || fail "T9 missing extract guidance"

# T10: HARD new gets two attempts before surfacing
rm -f "$STATE"
run <<< "$row_hard"
grep -q 'attempt 1 of 2' <<< "$OUT" || fail "T10 not attempt 1 of 2"
run <<< 'pkg.Big                                            complexity=9   coverage=90.0%  CRAP=9.1  HARD         (new)'
grep -q 'attempt 2 of 2' <<< "$OUT" || fail "T10 not attempt 2 of 2"
run <<< 'pkg.Big                                            complexity=9   coverage=91.0%  CRAP=9.0  HARD         (new)'
grep -q 'SURFACE_TO_USER' <<< "$OUT" || fail "T10 no SURFACE after 2 attempts"

# T11: passing function's stale state is dropped
rm -f "$STATE"
run <<< "$row_soft"
run <<< 'pkg.Softy                                          complexity=4   coverage=95.0%  CRAP=4.0  OK           (new)'
[ "$RC" -eq 0 ] || fail "T11 exit ($RC != 0)"
grep -q 'pkg.Softy' "$STATE" 2>/dev/null && fail "T11 stale state entry survived"

if [ "$FAILURES" -gt 0 ]; then
  echo "$FAILURES failure(s)"
  exit 1
fi
echo "NEXT_ACTION OK"
