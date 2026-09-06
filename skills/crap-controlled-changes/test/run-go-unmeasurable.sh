#!/usr/bin/env bash
# Regression test: a failure to measure must never look like a clean pass.
#
# The fixture is a monorepo shape that occurs often: a test/integration package
# that needs a live service, so crap4go's default `go test ./...` fails and it
# prints no CRAP report. Before the fix, crap-check.sh printed "== go ==" and
# exited 0, which is indistinguishable from "no changed functions".

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

# Refuse over uncommitted work below rather than reset/clean it. See run.sh
# for the rest: why a baseline commit (not just -d .git) is required, why
# the gitdir must be confirmed as the fixture's own, and why this skips when
# there's nothing to compare against (no outer repo, or none tracking
# this path).
if [ -n "$(git -C "$SKILL_DIR" ls-files -- test/fixture-go-unmeasurable 2>/dev/null)" ]; then
  dirty="$(git -C "$SKILL_DIR" status --porcelain --untracked-files=normal --ignored=matching -- test/fixture-go-unmeasurable)"
  if [ -n "$dirty" ]; then
    {
      echo "run-go-unmeasurable.sh: test/fixture-go-unmeasurable has uncommitted changes."
      echo "$dirty" | sed 's/^/  /'
      echo "This script resets or seals that content on every run, so it" \
           "must match HEAD first."
      echo "Nothing was changed. Discard the changes yourself if that is what" \
           "you want:"
      echo "  git -C \"$SKILL_DIR\" checkout HEAD -- test/fixture-go-unmeasurable"
      echo "  git -C \"$SKILL_DIR\" clean -fd test/fixture-go-unmeasurable"
    } >&2
    exit 1
  fi
fi

# See run.sh for why a baseline commit is required and the discovered
# gitdir must be confirmed as the fixture's own.
if [ "$(git -C "$FIXTURE_DIR" rev-parse --git-dir 2>/dev/null)" != .git ] || ! git -C "$FIXTURE_DIR" rev-parse --verify --quiet HEAD >/dev/null 2>&1; then
  (cd "$FIXTURE_DIR" && git init -q && git add . && fixture_commit "baseline")
fi

cd "$FIXTURE_DIR"
git reset --hard -q HEAD
git clean -qfd

failures=0

run_check() {
  local test_command="$1"
  set +e
  if [ -z "$test_command" ]; then
    OUT="$(unset CRAP_GO_TEST_COMMAND; bash "$SCRIPT" 2>&1)"
  else
    OUT="$(CRAP_GO_TEST_COMMAND="$test_command" bash "$SCRIPT" 2>&1)"
  fi
  STATUS=$?
  set -e
}

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

expect_matches() {
  local label="$1" pattern="$2"
  if printf '%s' "$OUT" | grep -qE -- "$pattern"; then
    check "$label" pass
  else
    check "$label (no line matching: $pattern)" fail
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

stage_unscored_change() {
  cat >> internal/calc.go <<'GO'

func Unscored(x int) int {
	if x > 7 {
		return x * 2
	}
	return x
}
GO
  git add internal/calc.go
}

echo "case A: unmeasurable (no override) must not exit 0"
stage_function_change
run_check ""
printf '%s\n' "$OUT" | sed 's/^/    | /'
expect_status "non-zero exit" 4
expect_contains "says it failed to measure" "FAILED TO MEASURE"
expect_contains "names the module"          "internal/calc.go"
expect_contains "surfaces crap4go output"   ".s.PGSQL.5432"
expect_contains "points at the override"    "CRAP_GO_TEST_COMMAND"
expect_contains "denies being a pass"       "NOT a pass"
expect_contains "denies being a flake"      "NOT a flake"

git reset --hard -q HEAD

echo "case B: override measures the same change"
stage_function_change
run_check "go test ./internal/..."
printf '%s\n' "$OUT" | sed 's/^/    | /'
expect_status "clean exit" 0
expect_contains "reports Branchy"      "calc.Branchy"
expect_contains "reports a CRAP score" "CRAP="
expect_contains "tags the baseline"    "worsened"
expect_contains "confirms it measured" "measured"

git reset --hard -q HEAD

echo "case C: no changed functions is distinct from could-not-measure"
printf '\n// Version is a doc-only addition.\nconst Version = "1"\n' >> internal/types.go
git add internal/types.go
run_check "go test ./internal/..."
printf '%s\n' "$OUT" | sed 's/^/    | /'
expect_status "clean exit" 0
expect_contains "says nothing to measure" "no Go functions to measure"
if printf '%s' "$OUT" | grep -qF "FAILED TO MEASURE"; then
  check "does not claim a measurement failure" fail
else
  check "does not claim a measurement failure" pass
fi

git reset --hard -q HEAD
git clean -qfd

echo "case D: post-commit run warns instead of no-op"
# Content no earlier case has scored: the ledger vouches for what a green run
# measured, so committing the *same* change an earlier case greened is a
# legitimate pass, not the no-op this case is about.
stage_unscored_change
fixture_commit "scratch: committed before checking"
run_check "go test ./internal/..."
printf '%s\n' "$OUT" | sed 's/^/    | /'
expect_status "non-zero exit" 5
expect_contains "explains nothing was staged" "nothing was measured"
expect_contains "says HEAD touched source"    "HEAD commit"
git reset --hard -q HEAD~1

# --include-untracked does not stash *ignored* files, so an unanchored ignore
# rule that catches a source directory leaves the baseline tree as HEAD's
# interfaces plus the current tree's generated code. That does not compile.
setup_ignored_generated_file() {
  printf 'gen\n' > .gitignore
  cat > internal/svc.go <<'GO'
package calc

// Service is the interface the change edits.
type Service interface {
	Name() string
	Legacy() int
}
GO
  git add .gitignore internal/svc.go
  fixture_commit "scratch: interface plus unanchored gitignore rule"

  mkdir -p internal/gen
  cat > internal/gen/mock.go <<'GO'
package gen

import calc "crapcheckunmeasurable/internal"

type MockService struct{}

func (m *MockService) Name() string { return "mock" }

var _ calc.Service = (*MockService)(nil)
GO

  # The staged change drops Legacy(); only the current tree agrees with the mock.
  cat > internal/svc.go <<'GO'
package calc

// Service is the interface the change edits.
type Service interface {
	Name() string
}
GO
  git add internal/svc.go
}

teardown_ignored_generated_file() {
  rm -rf internal/gen
  git reset --hard -q HEAD~1
  rm -f .gitignore
  git clean -qfd
}

echo "case E: an ignored file no longer contaminates the baseline"
# The baseline is a worktree at HEAD, so ignored files are simply absent from it
# rather than mixed in from the current tree. The contamination this case used to
# assert cannot happen; an ignored file only breaks the baseline now if the
# tracked sources need it to compile, which this fixture's does not.
setup_ignored_generated_file
run_check "go test ./internal/..."
printf '%s\n' "$OUT" | sed 's/^/    | /'
expect_status "clean exit" 0
expect_contains "measured without contamination" "COMMIT_OK"
teardown_ignored_generated_file

echo ""
if [ "$failures" -eq 0 ]; then
  echo "OK (5 cases)"
else
  echo "FAILED: $failures assertion(s)"
  exit 1
fi
