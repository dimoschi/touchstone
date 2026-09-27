#!/usr/bin/env bash
# Regression test for workflows/tests/harness.sh's own scenario-running
# footer (gh-96): a scenario that throws must not hide a scenario queued
# after it in the same suite file.
#
# Deliberately outside workflows/tests/ and not named test-fix-loop-join.sh,
# so scripts/check-assertions-discriminate.sh's suite glob never selects it:
# its scenarios never call harness.sh's run() (they don't exercise
# deliver-pipeline.js at all), so nothing here judges assertions about it.
#
# Each case runs a tiny generated suite file as its own `bash` process (real
# process boundary, not a captured function call), the same way a real suite
# runs: that is the only way `finish`'s exit code means anything, since
# run_js_scenarios only ever signals a failed scenario through the shared
# `failures` variable, and command substitution would run it in a subshell
# that drops that variable's mutation on exit.
#
# Needs node and git (harness.sh depends on both). Exit 0 all green, 1 any
# assertion failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HARNESS="$REPO_ROOT/workflows/tests/harness.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

failures=0

check() {
  local label="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then
    echo "  ok:   $label ($got)"
  else
    echo "  FAIL: $label (got $got, want $want)"
    failures=$((failures + 1))
  fi
}

assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo "  ok:   $label"
  else
    echo "  FAIL: $label (missing: $needle)"
    failures=$((failures + 1))
  fi
}

assert_not_contains() {
  local label="$1" haystack="$2" needle="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    echo "  ok:   $label"
  else
    echo "  FAIL: $label (unexpectedly found: $needle)"
    failures=$((failures + 1))
  fi
}

# Writes a throwaway suite file at $1 that sources the real harness.sh and
# hands run_js_scenarios the JS on stdin, same shape as a real workflows/tests/test-*.sh.
write_suite() {
  local out="$1"
  {
    echo '#!/usr/bin/env bash'
    echo 'set -uo pipefail'
    printf 'source %q\n' "$HARNESS"
    echo "run_js_scenarios <<'JS_EOF'"
    cat
    echo 'JS_EOF'
    echo 'finish'
  } > "$out"
}

SUITE1="$WORK/suite-abort.sh"
write_suite "$SUITE1" <<'JS'
async function scenarioThrows() {
  console.log('\n== scenario scenarioThrows')
  check('before the throw', 1, 1)
  throw new Error('boom')
}
async function scenarioAfter() {
  console.log('\n== scenario scenarioAfter')
  check('runs after an earlier abort', 1, 1)
}
const SCENARIOS = [scenarioThrows, scenarioAfter]
JS

echo "== a scenario that throws is reported by name and does not hide a later scenario"
OUT1="$(bash "$SUITE1" 2>&1)"
STATUS1=$?
assert_contains "the throwing scenario's own earlier check still printed" "$OUT1" "ok:   before the throw"
assert_contains "the throw is reported by scenario name and message" "$OUT1" "ABORTED: scenarioThrows: boom"
assert_contains "the later scenario still ran" "$OUT1" "ok:   runs after an earlier abort"
check "the suite still exits non-zero over the abort" "$STATUS1" 1

echo ""
if [ "$failures" -eq 0 ]; then
  echo "OK"
  exit 0
else
  echo "FAILED: $failures assertion(s)"
  exit 1
fi
