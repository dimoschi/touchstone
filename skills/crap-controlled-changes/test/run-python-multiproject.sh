#!/usr/bin/env bash
# Regression test: a single diff spans two independent Python subprojects,
# each with its own pyproject.toml, and the repo root has no project config
# of its own. Before this test's fix, naming a single CRAP_PY_PROJECT_DIR
# could not measure both, and the printed refusal told the user to "name
# which one to measure" -- advice that cannot succeed for either one. Naming
# both together, space-separated, must measure both for real -- see gh-80.

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SKILL_DIR/crap-check.sh"
FIXTURE_SRC="$SKILL_DIR/test/fixture-python-multiproject"

command -v uv  >/dev/null || { echo "SKIP: uv not on PATH";  exit 0; }
command -v git >/dev/null || { echo "SKIP: git not on PATH"; exit 0; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cp -R "$FIXTURE_SRC/projA" "$WORK/projA"
cp -R "$FIXTURE_SRC/projB" "$WORK/projB"
cd "$WORK"

git init -q
GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=commit.gpgsign GIT_CONFIG_VALUE_0=false \
  bash -c 'git add . && git commit -q -m baseline'

cp "$FIXTURE_SRC/current/projA/calc.py" projA/src/calc.py
cp "$FIXTURE_SRC/current/projB/calc.py" projB/src/calc.py
git add projA/src/calc.py projB/src/calc.py

export CRAP_PY_RUN="uv run --no-project --with coverage>=7.13.1 --with pytest --"

failures=0
check() {
  if [ "$2" = "pass" ]; then echo "  ok: $1"; else echo "  FAIL: $1"; failures=$((failures + 1)); fi
}

echo "case A: two subprojects touched, no CRAP_PY_PROJECT_DIR"
set +e
OUT="$("$SCRIPT" 2>&1)"
STATUS=$?
set -e
printf '%s\n' "$OUT" | sed 's/^/    | /'
[ "$STATUS" -eq 2 ] && check "refuses rather than guessing (exit $STATUS)" pass \
  || check "refuses rather than guessing (exit $STATUS, want 2)" fail
printf '%s' "$OUT" | grep -qF 'projA' && printf '%s' "$OUT" | grep -qF 'projB' \
  && check "names both subprojects" pass || check "names both subprojects" fail
printf '%s' "$OUT" | grep -q 'name which one' \
  && check "does not repeat the impossible name-just-one advice" fail \
  || check "does not repeat the impossible name-just-one advice" pass

echo "case B: CRAP_PY_PROJECT_DIR names both, space-separated"
CRAP_PY_PROJECT_DIR="projA projB"
export CRAP_PY_PROJECT_DIR
set +e
OUT="$("$SCRIPT" 2>&1)"
STATUS=$?
set -e
printf '%s\n' "$OUT" | sed 's/^/    | /'
[ "$STATUS" -ne 2 ] && [ "$STATUS" -ne 4 ] && check "measures rather than refusing (exit $STATUS)" pass \
  || check "measures rather than refusing (exit $STATUS)" fail
printf '%s' "$OUT" | grep -qF 'projA/src/calc.py::add' && check "reports projA's untouched function" pass \
  || check "reports projA's untouched function" fail
printf '%s' "$OUT" | grep -qF 'projB/src/calc.py::add' && check "reports projB's untouched function" pass \
  || check "reports projB's untouched function" fail
printf '%s' "$OUT" | grep 'projA/src/calc.py::add' | grep -qF 'coverage=100.0%' \
  && check "projA's add at real coverage, not a false zero" pass \
  || check "projA's add at real coverage, not a false zero" fail
printf '%s' "$OUT" | grep 'projB/src/calc.py::add' | grep -qF 'coverage=100.0%' \
  && check "projB's add at real coverage, not a false zero" pass \
  || check "projB's add at real coverage, not a false zero" fail

if [ "$failures" -eq 0 ]; then
  echo "MULTIPROJECT OK"
else
  echo "FAILED: $failures assertion(s)"
  exit 1
fi
