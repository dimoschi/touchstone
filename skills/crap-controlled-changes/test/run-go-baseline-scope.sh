#!/usr/bin/env bash
# The Go gate runs the changed packages' tests, not the whole module, and
# measures the HEAD baseline once per HEAD, change set and build configuration
# rather than on every run.

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE_DIR="$SKILL_DIR/test/fixture-go-unmeasurable"
SCRIPT="$SKILL_DIR/crap-check.sh"

command -v go >/dev/null || { echo "SKIP: go not on PATH"; exit 0; }

# Fixture commits must not inherit the user's signing config; gpg has no TTY here.
fixture_commit() {
  GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=t@t \
    git -c commit.gpgsign=false -c gpg.format=openpgp commit -q -m "$1"
}

# Refuse over uncommitted work rather than reset it; see run-go-unmeasurable.sh.
if [ -n "$(git -C "$SKILL_DIR" ls-files -- test/fixture-go-unmeasurable 2>/dev/null)" ]; then
  dirty="$(git -C "$SKILL_DIR" status --porcelain --untracked-files=normal --ignored=matching -- test/fixture-go-unmeasurable)"
  if [ -n "$dirty" ]; then
    {
      echo "run-go-baseline-scope.sh: test/fixture-go-unmeasurable has uncommitted changes."
      echo "$dirty" | sed 's/^/  /'
      echo "This script resets that content on every run, so it must match HEAD first."
      echo "Nothing was changed. Discard the changes yourself if that is what you want:"
      echo "  git -C \"$SKILL_DIR\" checkout HEAD -- test/fixture-go-unmeasurable"
      echo "  git -C \"$SKILL_DIR\" clean -fd test/fixture-go-unmeasurable"
    } >&2
    exit 1
  fi
fi

if [ "$(git -C "$FIXTURE_DIR" rev-parse --git-dir 2>/dev/null)" != .git ] || ! git -C "$FIXTURE_DIR" rev-parse --verify --quiet HEAD >/dev/null 2>&1; then
  (cd "$FIXTURE_DIR" && git init -q && git add . && fixture_commit "baseline")
fi

cd "$FIXTURE_DIR"
git reset --hard -q HEAD
git clean -qfd
BASELINE_HEAD="$(git rev-parse HEAD)"
CACHE_DIR="$(git rev-parse --path-format=absolute --git-common-dir)/crap-check-baseline"
rm -rf "$CACHE_DIR"

COUNTER="$(mktemp)"
trap 'rm -f "$COUNTER"; rm -rf "$CACHE_DIR"; git -C "$FIXTURE_DIR" reset --hard -q "$BASELINE_HEAD"' EXIT
# Counts how many times the coverage suite ran: one line per invocation.
COUNTING="echo run >> $COUNTER; go test ./internal/..."
runs() { wc -l < "$COUNTER" | tr -d ' '; }

failures=0
check() {
  if [ "$2" = pass ]; then echo "  ok: $1"; else echo "  FAIL: $1"; failures=$((failures + 1)); fi
}

stage_function_change() {
  python3 - <<'PY'
import pathlib
p = pathlib.Path("internal/calc.go")
s = p.read_text()
new = s.replace(
    'if x > 100 {\n\t\treturn "big"\n\t}\n\treturn "ok"',
    'if x > 100 {\n\t\treturn "big"\n\t}\n\tif x == 42 {\n\t\treturn "answer"\n\t}\n\treturn "ok"',
)
assert new != s, "fixture pattern did not match"
p.write_text(new)
PY
  git add internal/calc.go
}

run_gate() {
  set +e
  OUT="$(env "$@" bash "$SCRIPT" 2>&1)"
  STATUS=$?
  set -e
}

echo "case 1: the default run skips a failing package the change does not touch"
stage_function_change
run_gate -u CRAP_GO_TEST_COMMAND
printf '%s\n' "$OUT" | sed 's/^/    | /'
[ "$STATUS" -eq 0 ] && check "clean exit" pass || check "clean exit (exit $STATUS, want 0)" fail
printf '%s' "$OUT" | grep -qF "calc.Branchy" && check "measured Branchy" pass || check "measured Branchy" fail
git reset --hard -q HEAD
rm -rf "$CACHE_DIR"

echo "case 2: a second run against the same HEAD reuses the baseline"
stage_function_change
run_gate CRAP_GO_TEST_COMMAND="$COUNTING"
first="$OUT"
[ "$(runs)" -eq 2 ] && check "first run measures baseline and change" pass || check "first run: $(runs) test runs, want 2" fail
run_gate CRAP_GO_TEST_COMMAND="$COUNTING"
[ "$(runs)" -eq 3 ] && check "second run measures only the change" pass || check "second run: $(runs) test runs in total, want 3" fail
[ "$OUT" = "$first" ] && check "same verdict from the cached baseline" pass || check "verdict changed with a cached baseline" fail

echo "case 3: disabling the cache measures the baseline again"
run_gate CRAP_GO_TEST_COMMAND="$COUNTING" CRAP_BASELINE_CACHE=0
[ "$(runs)" -eq 5 ] && check "baseline measured" pass || check "$(runs) test runs in total, want 5" fail

echo "case 4: a new HEAD measures its own baseline"
git reset --hard -q HEAD
printf '\n// Note is unrelated to the change.\nconst Note = "x"\n' >> internal/types.go
git add internal/types.go
fixture_commit "scratch: move HEAD"
stage_function_change
run_gate CRAP_GO_TEST_COMMAND="$COUNTING"
[ "$(runs)" -eq 7 ] && check "baseline measured for the new HEAD" pass || check "$(runs) test runs in total, want 7" fail
git reset --hard -q "$BASELINE_HEAD"

echo "case 5: a different test command does not reuse the baseline"
stage_function_change
run_gate CRAP_GO_TEST_COMMAND="$COUNTING -count=1"
[ "$(runs)" -eq 9 ] && check "baseline measured for the new command" pass || check "$(runs) test runs in total, want 9" fail
git reset --hard -q HEAD
rm -rf "$CACHE_DIR"

echo "case 6: an override narrows through {packages}"
stage_function_change
run_gate CRAP_GO_TEST_COMMAND="go test {packages}"
printf '%s\n' "$OUT" | sed 's/^/    | /'
[ "$STATUS" -eq 0 ] && check "clean exit, failing package skipped" pass || check "clean exit (exit $STATUS, want 0)" fail
printf '%s' "$OUT" | grep -qF "calc.Branchy" && check "measured Branchy" pass || check "measured Branchy" fail

echo ""
if [ "$failures" -eq 0 ]; then echo "OK (6 cases)"; else echo "FAILED: $failures assertion(s)"; exit 1; fi
