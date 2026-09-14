#!/usr/bin/env bash
# Regression test: a changed file that HEAD never measured because its test
# file is new in this same diff. Before the absent-vs-zero fix landed, this
# was fine (baseline rows read a real 0.0%). After it landed but before
# gh-80's follow-up, the baseline dropped those rows entirely, so `add` --
# untouched by this diff, never called by the new test either -- tagged
# "new" at coverage=0.0% and went NEEDS_TESTS. `add` must stay "unchanged".

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SKILL_DIR/crap-check.sh"
FIXTURE_SRC="$SKILL_DIR/test/fixture-python-newly-tested"

command -v uv  >/dev/null || { echo "SKIP: uv not on PATH";  exit 0; }
command -v git >/dev/null || { echo "SKIP: git not on PATH"; exit 0; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cp "$FIXTURE_SRC/calc.py" "$WORK/"
cd "$WORK"

git init -q
GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=commit.gpgsign GIT_CONFIG_VALUE_0=false \
  bash -c 'git add . && git commit -q -m baseline'

cp "$FIXTURE_SRC/current/calc.py" calc.py
mkdir tests
cp "$FIXTURE_SRC/tests/test_calc.py" tests/test_calc.py
git add calc.py tests/test_calc.py

export CRAP_PY_RUN="uv run --no-project --with coverage>=7.13.1 --with pytest --"

RC=0
OUT="$("$SCRIPT" 2>&1)" || RC=$?
echo "$OUT"

[ "$RC" -eq 0 ] || { echo "FAIL: expected exit 0 (gate green), got $RC"; exit 1; }
echo "$OUT" | grep -q 'calc.py::add' || { echo "FAIL: add not in output"; exit 1; }
echo "$OUT" | grep 'calc.py::add' | head -1 | grep -q '(unchanged)' \
  || { echo "FAIL: add not tagged unchanged (untouched functions must not read as new)"; exit 1; }
echo "$OUT" | grep -q 'NEEDS_TESTS' && { echo "FAIL: a function untouched by this diff went NEEDS_TESTS"; exit 1; }
echo "$OUT" | grep -q 'COMMIT_OK' || { echo "FAIL: COMMIT_OK directive not present"; exit 1; }
echo "BASELINE-UNMEASURED OK"
