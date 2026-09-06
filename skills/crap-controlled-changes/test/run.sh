#!/usr/bin/env bash
# Integration test for crap-check.sh.
# Stages a known change in the fixture, invokes the script, asserts output.

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE_DIR="$SKILL_DIR/test/fixture"
SCRIPT="$SKILL_DIR/crap-check.sh"

command -v go >/dev/null || { echo "SKIP: go not on PATH"; exit 0; }

# Fixture must have a baseline commit, not just a .git/: a bootstrap that
# died between `git init` and `git commit` would otherwise wedge every
# later run at `git reset --hard -q HEAD` below.
if ! git -C "$FIXTURE_DIR" rev-parse --verify --quiet HEAD >/dev/null 2>&1; then
  (cd "$FIXTURE_DIR" && git init -q && git add . && \
   GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=t@t \
   GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=commit.gpgsign GIT_CONFIG_VALUE_0=false \
   git commit -q -m "baseline")
fi

cd "$FIXTURE_DIR"
git reset --hard -q HEAD

# Modify Branchy: add one more branch (complexity 4 -> 5), still no test coverage.
python3 - <<'PY'
import pathlib
p = pathlib.Path("main.go")
s = p.read_text()
new = s.replace(
    'if x > 100 {\n\t\treturn "big"\n\t}\n\treturn "ok"',
    'if x > 100 {\n\t\treturn "big"\n\t}\n\tif x == 42 {\n\t\treturn "answer"\n\t}\n\treturn "ok"',
)
assert new != s, "fixture pattern did not match"
p.write_text(new)
PY

git add main.go

# Run the script and capture output. NEEDS_TESTS means gate red, exit 1.
RC=0
OUT="$("$SCRIPT" 2>&1)" || RC=$?
echo "$OUT"

# Reset fixture for next run.
git reset --hard -q HEAD

# Assertions.
[ "$RC" -eq 1 ] || { echo "FAIL: expected exit 1 (gate red), got $RC"; exit 1; }
echo "$OUT" | grep -q 'Branchy'       || { echo "FAIL: Branchy not in output"; exit 1; }
echo "$OUT" | grep -q 'NEEDS_TESTS'   || { echo "FAIL: NEEDS_TESTS status not present"; exit 1; }
echo "$OUT" | grep -q 'worsened'      || { echo "FAIL: worsened tag not present"; exit 1; }
echo "$OUT" | grep -q 'NEXT_ACTION'   || { echo "FAIL: NEXT_ACTION block not present"; exit 1; }
echo "$OUT" | grep -q 'WRITE_TESTS'   || { echo "FAIL: WRITE_TESTS directive not present"; exit 1; }
echo "OK"
