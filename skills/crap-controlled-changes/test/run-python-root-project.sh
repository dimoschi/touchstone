#!/usr/bin/env bash
# Regression test, two cases:
#   A: the repo's Python project sits at the git root (its own pyproject.toml
#      declares [tool.pytest.ini_options] + [tool.coverage.run], the latter
#      naming the member package as its source), and a member package under
#      it also carries its own pyproject.toml with one of those two headers,
#      for its own standalone use. Before this test's fix, the subdirectory
#      detector treated that member's header as a reason to refuse (exit 2)
#      even though the root config was all this change needed -- see gh-80.
#      No CRAP_PY_PROJECT_DIR should be required here.
#   B: the root's own pyproject.toml declares [tool.pytest.ini_options] only
#      -- no [tool.coverage.run] -- and the changed file's own package
#      carries a [tool.coverage.run] the root does not reproduce. The root's
#      pytest-only header must not make it win over that closer, more
#      specific project: the pytest section says nothing about where
#      coverage.py should measure from, so treating it as license to skip the
#      subdirectory detector would silently measure with the member's config
#      absent, the exact failure the exit-2 refusal exists to prevent.

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

echo "case A: root declares [tool.coverage.run], member's own header is incidental"
RC=0
OUT="$("$SCRIPT" 2>&1)" || RC=$?
echo "$OUT"

[ "$RC" -ne 2 ] || { echo "FAIL: refused (exit 2) despite the root's own pyproject.toml declaring a project"; exit 1; }
echo "$OUT" | grep -q 'pkg/calc.py::add' || { echo "FAIL: add not in output"; exit 1; }
echo "$OUT" | grep 'pkg/calc.py::add' | head -1 | grep -q '(unchanged)' \
  || { echo "FAIL: add (untouched by this diff) did not tag unchanged"; exit 1; }
echo "$OUT" | grep -q 'pkg/calc.py::add.*coverage=0.0%' && { echo "FAIL: add read a false zero"; exit 1; }
echo "ROOT-PROJECT-COVERAGE OK"

git reset --hard -q HEAD
git clean -qfdx

echo "case B: root declares [tool.pytest.ini_options] only, member owns [tool.coverage.run]"
PYTEST_ONLY_SRC="$SKILL_DIR/test/fixture-python-root-pytest-only"
cp "$PYTEST_ONLY_SRC/pyproject.toml" pyproject.toml
cp "$PYTEST_ONLY_SRC/pkg/pyproject.toml" pkg/pyproject.toml
cp "$PYTEST_ONLY_SRC/pkg/calc.py" pkg/calc.py
GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=commit.gpgsign GIT_CONFIG_VALUE_0=false \
  bash -c 'git add -A && git commit -q -m "switch to pytest-only root"'

cp "$PYTEST_ONLY_SRC/current/pkg/calc.py" pkg/calc.py
git add pkg/calc.py

RC=0
OUT="$("$SCRIPT" 2>&1)" || RC=$?
echo "$OUT"

[ "$RC" -eq 2 ] || { echo "FAIL: expected exit 2 (refuse), got $RC -- root's pytest-only header silently won"; exit 1; }
echo "$OUT" | grep -q 'pkg' || { echo "FAIL: refusal does not name the member directory"; exit 1; }
echo "ROOT-PROJECT-PYTEST-ONLY OK"
