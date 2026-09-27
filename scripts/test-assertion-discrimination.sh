#!/usr/bin/env bash
# scripts/check-assertions-discriminate.sh's own regression suite.
#
# Replays the check against ranges from this repo's own history where a
# vacuous assertion is known to have existed (gh-96): each cited commit is
# either reachable from origin/main, or exists locally as a loose object left
# over from the investigation that found it (never merged, so no ref of ours
# names it) -- either way `git cat-file -t` finds it without a network
# fetch. If a fresh clone or gc has actually dropped one, that range's checks
# are skipped with a clear reason rather than silently passing.
#
# Every classification rule this checker applies (never-ran, a source-text
# absence check, a revert that aborts rather than genuinely failing, a
# presence check saved only by a mutant) already has a synthetic fixture in
# scripts/lib/test_assertion_discrimination.py, against a throwaway scratch
# repo -- faster and more exact than reproducing each by finding a real
# historical commit shaped that way. This suite is the complement: proof
# against real history, not synthetic cases.
#
# Needs git (with these objects present), python3, node and bash. Slow: the
# largest range here replays an entire feature branch, not a typical PR's
# diff -- see docs/testing.md for the runtime this repo's own fence and CI
# step actually need to meet, which is a different, much smaller thing.
#
# Two of the ticket's cited demonstrations are not asserted here, found not
# to hold in this environment or against this repo's actual history rather
# than skipped for convenience:
#   - dba7da1..d765fcec's own vacuous check (`grep -c 'open the PR with
#     --base ${wt.base}'`, no -F) depends on plain `grep`'s BRE handling of
#     `$` and `{}` mid-pattern, which this machine's `grep` (ugrep) does not
#     match literally the way GNU/BSD grep commonly do; the check is red at
#     head here regardless of counterfactual, for a reason unrelated to
#     what it claims to test.
#   - dfcff2f^..dfcff2f is not a pure move: `git show
#     1ccc3f5:workflows/test-fix-loop-join.sh` does not contain several
#     checks/headers the split commit's own files do (e.g. scenario DY's
#     entire body was rewritten, not relocated), so this range genuinely
#     does introduce new assertions and reporting some of them is correct,
#     not a false positive.
#
# Exit 0 all green, 1 any assertion failed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DISCRIMINATE="$SCRIPT_DIR/check-assertions-discriminate.sh"

failures=0
skipped=0

check() {
  local label="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then
    echo "  ok:   $label"
  else
    echo "  FAIL: $label (got: $got, want: $want)"
    failures=$((failures + 1))
  fi
}

# $1 label, $2 haystack, $3 needle
assert_contains() {
  if [[ "$2" == *"$3"* ]]; then
    echo "  ok:   $1"
  else
    echo "  FAIL: $1 (missing: $3)"
    failures=$((failures + 1))
  fi
}

assert_not_contains() {
  if [[ "$2" != *"$3"* ]]; then
    echo "  ok:   $1"
  else
    echo "  FAIL: $1 (unexpectedly present: $3)"
    failures=$((failures + 1))
  fi
}

# $1 range label, remaining args: commit shas the range needs present.
# Returns 1 (and prints a skip) if any is missing from this clone's object store.
have_commits() {
  local label="$1"; shift
  local sha
  for sha in "$@"; do
    if ! git -C "$REPO_ROOT" cat-file -t "$sha" >/dev/null 2>&1; then
      echo ""
      echo "== SKIP: $label ($sha not present in this clone's object store)"
      skipped=$((skipped + 1))
      return 1
    fi
  done
  return 0
}

echo "== 45ee4f7..ed4d02e4: BM/BQ/BR/BT/BS, introduced vacuous"
if have_commits "45ee4f7..ed4d02e4" 45ee4f7 ed4d02e4; then
  OUT="$(bash "$DISCRIMINATE" "$REPO_ROOT" --base 45ee4f7 --head ed4d02e4)"
  STATUS=$?
  check "exit 1: something reported" "$STATUS" 1
  assert_contains "BM reported" "$OUT" 'the note does not recommend cutting a new branch'
  assert_contains "BR reported" "$OUT" 'step 4 no longer reuses a bare match with no PR-state check at all'
  assert_contains "BT reported" "$OUT" 'the re-attach action is folded into the Exactly one match bullet, not a sibling Not merged bullet'
  assert_contains "BS reported" "$OUT" 'it does not claim a same-named branch would be cut'
fi

echo ""
echo "== 45ee4f7..ad48807b: BM/BQ/BR/BT's replacement checks, not vacuous"
# Only the *replacement* labels are asserted absent, not the whole range's
# output: ad48807b adds each replacement alongside its original vacuous
# check rather than rewriting it away, so the range still reports plenty
# (including the untouched originals) -- this suite asserts what the ticket
# actually claims (the new checks discriminate), not that the range goes
# quiet.
if have_commits "45ee4f7..ad48807b" 45ee4f7 ad48807b; then
  OUT="$(bash "$DISCRIMINATE" "$REPO_ROOT" --base 45ee4f7 --head ad48807b)"
  assert_not_contains "BM/BQ replacement not reported" "$OUT" \
    'the note is the ambiguity note, not the not-found note it replaced'
  assert_not_contains "BR replacement not reported" "$OUT" 'the step 4 slice was actually found'
  assert_not_contains "BT replacement not reported" "$OUT" 'the step 5 slice was actually found'
fi

echo ""
echo "== 45ee4f7..8a30e015: BS's replacement checks, not vacuous"
if have_commits "45ee4f7..8a30e015" 45ee4f7 8a30e015; then
  OUT="$(bash "$DISCRIMINATE" "$REPO_ROOT" --base 45ee4f7 --head 8a30e015)"
  assert_not_contains "BS replacement not reported (outcome turns on the name)" "$OUT" \
    'it makes the outcome turn on the re-derived name, not on the marker'
  assert_not_contains "BS replacement not reported (names both outcomes)" "$OUT" \
    'it names the reuse outcome and the fresh-cut outcome, not just one'
fi

echo ""
echo "== dba7da1..48ea0c9a: the stacked-PR sentence's replacement, not vacuous"
if have_commits "dba7da1..48ea0c9a" dba7da1 48ea0c9a; then
  OUT="$(bash "$DISCRIMINATE" "$REPO_ROOT" --base dba7da1 --head 48ea0c9a)"
  assert_not_contains "replacement not reported" "$OUT" 'the stacked-PR sentence uses the stripped base'
fi

echo ""
echo "== 316fbdf..c656bed: BU, introduced vacuous"
# CA (`no check is reported red: the baseline itself was green`) is not
# asserted here: this repo's `checks.red` is a literal `[]` on that halt
# path, never a computed value, so no *string* mutant can move it, which is
# the only kind this check generates (see line_blank_string_mutants) --
# blanking a non-string literal risks the same control-flow collateral
# damage a comparison-operand blank does. Reverting to base is genuine here
# too, since the checks feature does not exist at all at 316fbdf, so `checks`
# reads as undefined rather than the empty list CA expects -- a real
# difference, just not the one CA's own reasoning is about. Confirmed by
# hand (see the ticket) rather than by this suite.
if have_commits "316fbdf..c656bed" 316fbdf c656bed; then
  OUT="$(bash "$DISCRIMINATE" "$REPO_ROOT" --base 316fbdf --head c656bed)"
  assert_contains "BU reported" "$OUT" 'no reviewer finding was recorded for the check'
fi

echo ""
if [ "$skipped" -gt 0 ]; then
  echo "SKIPPED: $skipped range(s) (commits not present in this clone)"
fi
if [ "$failures" -eq 0 ]; then
  echo "OK"
  exit 0
else
  echo "FAILED: $failures assertion(s)"
  exit 1
fi
