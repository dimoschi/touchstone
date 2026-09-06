#!/usr/bin/env bash
# Regression test: bootstrapping a baseline-less fixture must refuse when the
# fixture is dirty, never restore it.
#
# A crash between `git init` and the closing `git reset --hard` (or a manual
# `rm -rf fixture/.git`) can leave a fixture's tracked file already mutated
# with no .git present. The bootstrap guard in run.sh and
# run-go-unmeasurable.sh then treats that as "needs bootstrapping"; whatever
# is on disk is about to be sealed as the baseline every later assertion
# resets to, so it must refuse rather than restore or commit it, because
# either one could discard a developer's uncommitted work with no copy
# anywhere.
#
# This drives the real run.sh and run-go-unmeasurable.sh against the real
# fixture directories, not a synthetic stand-in, because the guard being
# tested reads *this checkout's* status via `git -C "$SKILL_DIR"`.

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$SKILL_DIR/test"

command -v go >/dev/null || { echo "SKIP: go not on PATH"; exit 0; }

# If either fixture area is already dirty, every case below would either
# blame this suite for someone else's uncommitted change or, worse, have its
# own cleanup discard it. Abort before touching anything.
for fixture_rel in fixture fixture-go-unmeasurable; do
  dirty="$(git -C "$SKILL_DIR" status --porcelain -- "test/$fixture_rel")"
  if [ -n "$dirty" ]; then
    {
      echo "run-fixture-bootstrap-refuses-dirty.sh: test/$fixture_rel is" \
           "already dirty; refusing to run rather than risk it as collateral."
      echo "$dirty" | sed 's/^/  /'
    } >&2
    exit 1
  fi
done

failures=0

check_exit() {
  local label="$1" want="$2" got="$3"
  if [ "$got" = "$want" ]; then
    echo "  ok: $label (exit $got)"
  else
    echo "  FAIL: $label (exit $got, want $want)"
    failures=$((failures + 1))
  fi
}

check_contains() {
  local label="$1" needle="$2" haystack="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    echo "  ok: $label"
  else
    echo "  FAIL: $label (missing: $needle)"
    failures=$((failures + 1))
  fi
}

# Same edit run.sh/run-go-unmeasurable.sh stage on a bootstrapped fixture,
# used here only to make the tracked file differ from HEAD with no .git
# present, i.e. a baseline-less, dirty fixture.
mutate() {
  python3 - "$1" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()
new = s.replace(
    'if x > 100 {\n\t\treturn "big"\n\t}\n\treturn "ok"',
    'if x > 100 {\n\t\treturn "big"\n\t}\n\tif x == 42 {\n\t\treturn "answer"\n\t}\n\treturn "ok"',
)
assert new != s, "setup pattern did not match"
p.write_text(new)
PY
}

# Undo only what this suite itself did to the fixture: the manual mutation
# below (if any) and any .git the target script bootstrapped. Never `git
# clean`: a baseline-less fixture that is dirty for a reason other than this
# suite's own `mutate` must be left exactly as found.
restore_own_mutation() {
  local fixture_rel="$1" mutated_file="$2"
  git -C "$SKILL_DIR" checkout HEAD -- "test/$fixture_rel/$mutated_file"
  rm -rf "$TEST_DIR/$fixture_rel/.git"
}

echo "case: baseline-less dirty test/fixture makes run.sh refuse"
rm -rf "$TEST_DIR/fixture/.git"
mutate "$TEST_DIR/fixture/main.go"
RC=0
OUT="$(bash "$TEST_DIR/run.sh" 2>&1)" || RC=$?
printf '%s\n' "$OUT" | sed 's/^/    | /'
check_exit "run.sh refuses" 1 "$RC"
check_contains "names the fixture" "test/fixture" "$OUT"
if [ -e "$TEST_DIR/fixture/.git" ]; then
  echo "  FAIL: run.sh bootstrapped a .git despite refusing"
  failures=$((failures + 1))
fi
restore_own_mutation fixture main.go

echo "case: baseline-less clean test/fixture makes run.sh bootstrap and pass"
rm -rf "$TEST_DIR/fixture/.git"
RC=0
OUT="$(bash "$TEST_DIR/run.sh" 2>&1)" || RC=$?
printf '%s\n' "$OUT" | sed 's/^/    | /'
check_exit "run.sh passes" 0 "$RC"
check_contains "reports OK" "OK" "$OUT"
rm -rf "$TEST_DIR/fixture/.git"

echo "case: baseline-less dirty test/fixture-go-unmeasurable makes run-go-unmeasurable.sh refuse"
rm -rf "$TEST_DIR/fixture-go-unmeasurable/.git"
mutate "$TEST_DIR/fixture-go-unmeasurable/internal/calc.go"
RC=0
OUT="$(bash "$TEST_DIR/run-go-unmeasurable.sh" 2>&1)" || RC=$?
printf '%s\n' "$OUT" | sed 's/^/    | /'
check_exit "run-go-unmeasurable.sh refuses" 1 "$RC"
check_contains "names the fixture" "test/fixture-go-unmeasurable" "$OUT"
if [ -e "$TEST_DIR/fixture-go-unmeasurable/.git" ]; then
  echo "  FAIL: run-go-unmeasurable.sh bootstrapped a .git despite refusing"
  failures=$((failures + 1))
fi
restore_own_mutation fixture-go-unmeasurable internal/calc.go

echo "case: baseline-less clean test/fixture-go-unmeasurable makes run-go-unmeasurable.sh bootstrap and pass"
rm -rf "$TEST_DIR/fixture-go-unmeasurable/.git"
RC=0
OUT="$(bash "$TEST_DIR/run-go-unmeasurable.sh" 2>&1)" || RC=$?
printf '%s\n' "$OUT" | sed 's/^/    | /'
check_exit "run-go-unmeasurable.sh passes" 0 "$RC"
check_contains "reports OK" "OK (5 cases)" "$OUT"
rm -rf "$TEST_DIR/fixture-go-unmeasurable/.git"

echo ""
if [ "$failures" -eq 0 ]; then
  echo "FIXTURE BOOTSTRAP REFUSES DIRTY OK (4 cases)"
else
  echo "FAILED: $failures assertion(s)"
  exit 1
fi
