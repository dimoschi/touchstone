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
echo "== 45ee4f7..ad48807b: BM/BQ/BR/BT replaced, no longer vacuous"
if have_commits "45ee4f7..ad48807b" 45ee4f7 ad48807b; then
  OUT="$(bash "$DISCRIMINATE" "$REPO_ROOT" --base 45ee4f7 --head ad48807b)"
  STATUS=$?
  check "exit 0: nothing reported" "$STATUS" 0
  assert_not_contains "BM/BQ replacement not reported" "$OUT" \
    'the note is the ambiguity note, not the not-found note it replaced'
  assert_not_contains "BR replacement not reported" "$OUT" 'the step 4 slice was actually found'
  assert_not_contains "BT replacement not reported" "$OUT" 'the step 5 slice was actually found'
fi

echo ""
echo "== 45ee4f7..8a30e015: BS replaced, no longer vacuous"
if have_commits "45ee4f7..8a30e015" 45ee4f7 8a30e015; then
  OUT="$(bash "$DISCRIMINATE" "$REPO_ROOT" --base 45ee4f7 --head 8a30e015)"
  STATUS=$?
  check "exit 0: nothing reported" "$STATUS" 0
  assert_not_contains "BS replacement not reported (outcome turns on the name)" "$OUT" \
    'it makes the outcome turn on the re-derived name, not on the marker'
  assert_not_contains "BS replacement not reported (names both outcomes)" "$OUT" \
    'it names the reuse outcome and the fresh-cut outcome, not just one'
fi

echo ""
echo "== dba7da1..d765fcec: the stacked-PR sentence, introduced vacuous"
if have_commits "dba7da1..d765fcec" dba7da1 d765fcec; then
  OUT="$(bash "$DISCRIMINATE" "$REPO_ROOT" --base dba7da1 --head d765fcec)"
  STATUS=$?
  check "exit 1: something reported" "$STATUS" 1
  assert_contains "the stacked-PR sentence reported" "$OUT" 'the stacked-PR sentence uses the stripped base'
fi

echo ""
echo "== dba7da1..48ea0c9a: replaced by a runtime check, no longer vacuous"
if have_commits "dba7da1..48ea0c9a" dba7da1 48ea0c9a; then
  OUT="$(bash "$DISCRIMINATE" "$REPO_ROOT" --base dba7da1 --head 48ea0c9a)"
  STATUS=$?
  check "exit 0: nothing reported" "$STATUS" 0
  assert_not_contains "replacement not reported" "$OUT" 'the stacked-PR sentence uses the stripped base'
fi

echo ""
echo "== 316fbdf..c656bed: BU/CA, introduced vacuous"
if have_commits "316fbdf..c656bed" 316fbdf c656bed; then
  OUT="$(bash "$DISCRIMINATE" "$REPO_ROOT" --base 316fbdf --head c656bed)"
  STATUS=$?
  check "exit 1: something reported" "$STATUS" 1
  assert_contains "BU reported" "$OUT" 'no reviewer finding was recorded for the check'
  assert_contains "CA reported" "$OUT" 'no check is reported red: the baseline itself was green'
fi

echo ""
echo "== dfcff2f^..dfcff2f: a pure move (gh-118 split) selects nothing"
if have_commits "dfcff2f^..dfcff2f" dfcff2f; then
  OUT="$(bash "$DISCRIMINATE" "$REPO_ROOT" --base 'dfcff2f^' --head dfcff2f)"
  STATUS=$?
  check "exit 0: nothing reported" "$STATUS" 0
  check "no output line reports a finding" "$(echo "$OUT" | grep -c '^workflows/' || true)" 0
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
