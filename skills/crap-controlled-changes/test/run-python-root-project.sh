#!/usr/bin/env bash
# Regression test: the repo's Python project sits at the git root (its own
# pyproject.toml declares [tool.pytest.ini_options] + [tool.coverage.run]),
# and a member package under it also carries its own pyproject.toml with one
# of those two headers, for its own standalone use. Before this test's fix,
# the subdirectory detector treated that member's header as a reason to
# refuse (exit 2) even though the root config was all this change needed --
# see gh-80. No CRAP_PY_PROJECT_DIR should be required here.

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SKILL_DIR/crap-check.sh"
FIXTURE_SRC="$SKILL_DIR/test/fixture-python-root-project"

command -v uv  >/dev/null || { echo "SKIP: uv not on PATH";  exit 0; }
command -v git >/dev/null || { echo "SKIP: git not on PATH"; exit 0; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cp -R "$FIXTURE_SRC"/. "$WORK"/
rm -rf "$WORK/current"
cd "$WORK"

git init -q
GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=commit.gpgsign GIT_CONFIG_VALUE_0=false \
  bash -c 'git add . && git commit -q -m baseline'

cp "$FIXTURE_SRC/current/pkg/calc.py" pkg/calc.py
git add pkg/calc.py

export CRAP_PY_RUN="uv run --no-project --with coverage>=7.13.1 --with pytest --"

RC=0
OUT="$("$SCRIPT" 2>&1)" || RC=$?
echo "$OUT"

[ "$RC" -ne 2 ] || { echo "FAIL: refused (exit 2) despite the root's own pyproject.toml declaring a project"; exit 1; }
echo "$OUT" | grep -q 'pkg/calc.py::add' || { echo "FAIL: add not in output"; exit 1; }
echo "$OUT" | grep 'pkg/calc.py::add' | head -1 | grep -q '(unchanged)' \
  || { echo "FAIL: add (untouched by this diff) did not tag unchanged"; exit 1; }
echo "$OUT" | grep -q 'pkg/calc.py::add.*coverage=0.0%' && { echo "FAIL: add read a false zero"; exit 1; }
echo "ROOT-PROJECT OK"
