#!/usr/bin/env bash
# Regression test: a Python project living in a subdirectory of the repo,
# with its own pyproject.toml. Before this suite existed, crap-check.sh always
# ran from the git root, so a relative `[tool.coverage.run] include` in that
# pyproject.toml never resolved and every changed function read coverage=0.0%
# -- see gh-80. Three cases:
#   A: no CRAP_PY_PROJECT_DIR -> refuse (exit 2), name the subdirectory.
#   B: CRAP_PY_PROJECT_DIR given -> measure for real from inside it.
#   C: a changed file no test imports -> exit 4, not a false 0% row.

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE_SRC="$SKILL_DIR/test/fixture-python-subproject"
SCRIPT="$SKILL_DIR/crap-check.sh"

command -v uv  >/dev/null || { echo "SKIP: uv not on PATH";  exit 0; }
command -v git >/dev/null || { echo "SKIP: git not on PATH"; exit 0; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cp -R "$FIXTURE_SRC/proj" "$WORK/proj"
cd "$WORK"

git init -q
GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=commit.gpgsign GIT_CONFIG_VALUE_0=false \
  bash -c 'git add . && git commit -q -m baseline'

export CRAP_PY_RUN="uv run --no-project --with coverage>=7.13.1 --with pytest --"

failures=0

check() {
  local label="$1" condition="$2"
  if [ "$condition" = "pass" ]; then
    echo "  ok: $label"
  else
    echo "  FAIL: $label"
    failures=$((failures + 1))
  fi
}

expect_contains() {
  local label="$1" needle="$2"
  if printf '%s' "$OUT" | grep -qF -- "$needle"; then
    check "$label" pass
  else
    check "$label (missing: $needle)" fail
  fi
}

expect_not_contains() {
  local label="$1" needle="$2"
  if printf '%s' "$OUT" | grep -qF -- "$needle"; then
    check "$label (unexpectedly present: $needle)" fail
  else
    check "$label" pass
  fi
}

expect_status() {
  local label="$1" want="$2"
  if [ "$STATUS" = "$want" ]; then
    check "$label (exit $STATUS)" pass
  else
    check "$label (exit $STATUS, want $want)" fail
  fi
}

expect_status_not() {
  local label="$1" not_want="$2"
  if [ "$STATUS" != "$not_want" ]; then
    check "$label (exit $STATUS)" pass
  else
    check "$label (exit $STATUS, wanted anything but $not_want)" fail
  fi
}

run_check() {
  set +e
  OUT="$(bash "$SCRIPT" 2>&1)"
  STATUS=$?
  set -e
}

echo "case A: subdirectory project, no CRAP_PY_PROJECT_DIR"
cp "$FIXTURE_SRC/current/calc.py" proj/src/calc.py
git add proj/src/calc.py
run_check
printf '%s\n' "$OUT" | sed 's/^/    | /'
expect_status "refuses rather than guessing" 2
expect_contains "names the subdirectory" "proj"
expect_not_contains "never reports a false zero" "coverage=0.0%"

git reset --hard -q HEAD
git clean -qfd

echo "case B: CRAP_PY_PROJECT_DIR names the subdirectory"
cp "$FIXTURE_SRC/current/calc.py" proj/src/calc.py
git add proj/src/calc.py
CRAP_PY_PROJECT_DIR="$WORK/proj" run_check
printf '%s\n' "$OUT" | sed 's/^/    | /'
expect_status_not "does not refuse to measure" 4
expect_contains "reports the untouched function" "proj/src/calc.py::add"
expect_contains "at full coverage, not a false zero" "coverage=100.0%"

git reset --hard -q HEAD
git clean -qfd

echo "case C: a changed file no test imports"
cat > proj/src/untested.py <<'PY'
def never_called(x):
    return x + 1
PY
git add proj/src/untested.py
CRAP_PY_PROJECT_DIR=proj run_check
printf '%s\n' "$OUT" | sed 's/^/    | /'
expect_status "refuses to report a file it never measured" 4
expect_contains "says it failed to measure" "FAILED TO MEASURE"
expect_contains "names the unmeasured file" "proj/src/untested.py"
expect_contains "denies being a pass" "NOT a pass"

git reset --hard -q HEAD
git clean -qfd

if [ "$failures" -eq 0 ]; then
  echo "SUBPROJECT OK"
else
  echo "FAILED: $failures assertion(s)"
  exit 1
fi
