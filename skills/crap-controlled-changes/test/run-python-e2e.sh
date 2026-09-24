#!/usr/bin/env bash
# run-python-e2e.sh: end-to-end test for the Python CRAP module.
# Builds a real git fixture repo, stages a change to calc.py, runs crap-check.sh,
# and asserts branchy reports NEEDS_TESTS (worsened). Uses ephemeral uv to supply
# coverage+pytest, so no committed virtualenv is needed.
#
# The fixture's one thin test is deliberate. It puts branchy above the derived
# coverage minimum but with the coverage term of CRAP still dominating the
# complexity term, which is the case that has to route to WRITE_TESTS rather
# than REFACTOR. A fuller test would leave a score the gate is content with.

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SKILL_DIR/crap-check.sh"
FIXTURE_SRC="$SKILL_DIR/test/fixture-python-e2e"

command -v uv  >/dev/null || { echo "SKIP: uv not on PATH";  exit 0; }
command -v git >/dev/null || { echo "SKIP: git not on PATH"; exit 0; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cp "$FIXTURE_SRC/calc.py" "$FIXTURE_SRC/test_calc.py" "$WORK/"
cd "$WORK"

git init -q
GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=commit.gpgsign GIT_CONFIG_VALUE_0=false \
  bash -c 'git add . && git commit -q -m baseline'

cp "$FIXTURE_SRC/current/calc.py" calc.py
git add calc.py

export CRAP_PY_RUN="uv run --no-project --with coverage --with pytest --"

RC=0
OUT="$("$SCRIPT" 2>&1)" || RC=$?
echo "$OUT"

[ "$RC" -eq 1 ] || { echo "FAIL: expected exit 1 (gate red), got $RC"; exit 1; }
echo "$OUT" | grep -q 'calc.py::branchy'             || { echo "FAIL: branchy not in output"; exit 1; }
echo "$OUT" | grep 'branchy' | head -1 | grep -q 'NEEDS_TESTS' || { echo "FAIL: branchy not NEEDS_TESTS"; exit 1; }
echo "$OUT" | grep -q 'worsened'                     || { echo "FAIL: branchy not worsened"; exit 1; }
echo "$OUT" | grep -q 'WRITE_TESTS'                  || { echo "FAIL: WRITE_TESTS directive not present"; exit 1; }
echo "E2E OK"
