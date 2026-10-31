#!/usr/bin/env bash
# A diff whose changed Go files are all filtered out of mutation selection (a
# <pkg>test double, a _test.go, a path the marker exempts) measures nothing, so
# it must not end in MUTATION_OK: that verdict reads as "every mutant was
# killed". It ends in NOTHING_TO_MEASURE and names each excluded file with the
# pattern that excluded it, so a reader can tell a real pass from an empty one.
#
# Needs only git, bash and python3: nothing is mutated on this path.

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MUTATION="$SKILL_DIR/mutation-check.sh"
failures=0

check() {
  local label="$1" want="$2" got="$3"
  if [ "$got" = "$want" ]; then
    printf '  ok:   %-58s %s\n' "$label" "$got"
  else
    printf '  FAIL: %-58s got %s want %s\n' "$label" "$got" "$want"
    failures=$((failures + 1))
  fi
}

has_line() { printf '%s\n' "$OUT" | grep -qE "$1" && echo yes || echo no; }

REPO="$(mktemp -d)"
cleanup() { cd /; rm -rf "$REPO"; }
trap cleanup EXIT
cd "$REPO" || exit 1
git init -q -b main .
git config user.email t@t
git config user.name t
git config commit.gpgsign false
git config core.excludesFile /dev/null
printf 'module example.com/t\n\ngo 1.26\n' > go.mod
echo 'package calc' > calc.go
git add -A
git commit -q -m base
git switch -q -c feat

mkdir -p testsupport/natstest tools
cat > testsupport/natstest/natstest.go <<'EOF'
package natstest

func Start() int {
	return 1
}
EOF
cat > calc_test.go <<'EOF'
package calc

import "testing"

func TestNothing(t *testing.T) {}
EOF
cat > tools/scratch.go <<'EOF'
package tools

func Scratch(x int) int {
	if x > 1 {
		return x
	}
	return 0
}
EOF
printf 'tools/scratch.go\n' > .crap-gated
git add -A
git commit -q -m "test double, a test and an exempted helper"

echo "a diff of only excluded files is NOTHING_TO_MEASURE, not MUTATION_OK"
OUT="$("$MUTATION" 2>&1)"; RC=$?
check "exits 0"                                   0 "$RC"
check "final line is the NOTHING_TO_MEASURE trailer" \
      "mutation-check: EXIT=0 NOTHING_TO_MEASURE" "$(printf '%s\n' "$OUT" | tail -n 1)"
check "MUTATION_OK is not printed"                no "$(has_line 'MUTATION_OK')"
check "keeps the no-changed-sources line"         yes "$(has_line 'no changed source files vs')"
check "prints a NEXT_ACTION block"                yes "$(has_line '^== NEXT_ACTION ==$')"
check "says the run is not mutation evidence"     yes \
      "$(has_line '^NOTHING_TO_MEASURE: .*no mutation evidence')"

echo "each excluded file is listed with the pattern that excluded it"
check "natstest.go by **/*test/*.go"              yes \
      "$(has_line 'testsupport/natstest/natstest\.go +excluded by \*\*/\*test/\*\.go$')"
check "calc_test.go by *_test.go"                 yes \
      "$(has_line 'calc_test\.go +excluded by \*_test\.go$')"
check "exempted file by the marker pattern"       yes \
      "$(has_line 'tools/scratch\.go +excluded by \.crap-gated tools/scratch\.go$')"

echo "the early exit still records the ledger"
"$MUTATION" --verify >/dev/null 2>&1
check "--verify passes afterwards"                0 "$?"

echo "a file MUTATION_ONLY leaves out is named, with MUTATION_ONLY as the reason"
git switch -q main
git switch -q -c only
mkdir -p other
printf 'package other\n\nfunc F(x int) int {\n\tif x > 1 {\n\t\treturn x\n\t}\n\treturn 0\n}\n' > other/foo.go
git add -A
git commit -q -m "a source file outside MUTATION_ONLY"
OUT="$(MUTATION_ONLY='pkg/*' "$MUTATION" 2>&1)"; RC=$?
check "exits 0"                                   0 "$RC"
check "final line is the NOTHING_TO_MEASURE trailer" \
      "mutation-check: EXIT=0 NOTHING_TO_MEASURE" "$(printf '%s\n' "$OUT" | tail -n 1)"
check "names the file and MUTATION_ONLY"          yes \
      "$(has_line '^  other/foo\.go +excluded by MUTATION_ONLY pkg/\*$')"
check "does not claim there are no changed files" no \
      "$(has_line '^  no changed go, php or python files$')"

echo "a branch with no go, php or python change says so"
git switch -q main
git switch -q -c docs
echo hi > README.md
git add -A
git commit -q -m docs
OUT="$("$MUTATION" 2>&1)"; RC=$?
check "exits 0"                                   0 "$RC"
check "final line is the NOTHING_TO_MEASURE trailer" \
      "mutation-check: EXIT=0 NOTHING_TO_MEASURE" "$(printf '%s\n' "$OUT" | tail -n 1)"
check "lists no files"                            yes \
      "$(has_line '^  no changed go, php or python files$')"

echo ""
if [ "$failures" -eq 0 ]; then
  echo "MUTATION NOTHING OK"
else
  echo "FAILED: $failures assertion(s)"
  exit 1
fi
