#!/usr/bin/env bash
# Regression test: bootstrapping a fixture must restore the tracked content
# this checkout ships, not commit whatever the disk happens to hold.
#
# A crash between `git init` and the closing `git reset --hard` (or a manual
# `rm -rf fixture/.git`) can leave a fixture's tracked file already mutated
# with no .git present. The bootstrap guard in run.sh and
# run-go-unmeasurable.sh then treats that as "needs bootstrapping" and, if it
# committed the mutated content as-is, would seal the mutation into the
# baseline forever: every later `assert new != s` fails because the pattern
# it looks for is already gone from the file the suite resets to.
#
# This drives the real run.sh and run-go-unmeasurable.sh against the real
# fixture directories, not a synthetic stand-in, because the fix restores
# from *this checkout's* tracked content via `git -C "$SKILL_DIR"`.

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$SKILL_DIR/test"

command -v go >/dev/null || { echo "SKIP: go not on PATH"; exit 0; }

failures=0

# Discard any nested .git the fixture built up on a prior run, and restore
# its tracked files to what this checkout has at HEAD.
restore_pristine() {
  local fixture_rel="$1"
  rm -rf "$TEST_DIR/$fixture_rel/.git"
  git -C "$SKILL_DIR" checkout -q -- "test/$fixture_rel"
  git -C "$SKILL_DIR" clean -qfd -- "test/$fixture_rel"
}

check() {
  local label="$1" script="$2"
  if OUT="$(bash "$TEST_DIR/$script" 2>&1)"; then
    echo "  ok: $label"
  else
    echo "  FAIL: $label"
    printf '%s\n' "$OUT" | sed 's/^/    | /'
    failures=$((failures + 1))
  fi
}

echo "case: run.sh recovers when a crash leaves the fixture mutated with no .git"
restore_pristine fixture
(cd "$TEST_DIR/fixture" && python3 - <<'PY'
import pathlib
p = pathlib.Path("main.go")
s = p.read_text()
new = s.replace(
    'if x > 100 {\n\t\treturn "big"\n\t}\n\treturn "ok"',
    'if x > 100 {\n\t\treturn "big"\n\t}\n\tif x == 42 {\n\t\treturn "answer"\n\t}\n\treturn "ok"',
)
assert new != s, "setup pattern did not match"
p.write_text(new)
PY
)
check "run.sh" "run.sh"
restore_pristine fixture

echo "case: run-go-unmeasurable.sh recovers when a crash leaves the fixture mutated with no .git"
restore_pristine fixture-go-unmeasurable
(cd "$TEST_DIR/fixture-go-unmeasurable" && python3 - <<'PY'
import pathlib
p = pathlib.Path("internal/calc.go")
s = p.read_text()
new = s.replace(
    'if x > 100 {\n\t\treturn "big"\n\t}\n\treturn "ok"',
    'if x > 100 {\n\t\treturn "big"\n\t}\n\tif x == 42 {\n\t\treturn "answer"\n\t}\n\treturn "ok"',
)
assert new != s, "setup pattern did not match"
p.write_text(new)
PY
)
check "run-go-unmeasurable.sh" "run-go-unmeasurable.sh"
restore_pristine fixture-go-unmeasurable

echo ""
if [ "$failures" -eq 0 ]; then
  echo "FIXTURE BOOTSTRAP RECOVERS FROM DIRTY DISK OK (2 cases)"
else
  echo "FAILED: $failures assertion(s)"
  exit 1
fi
