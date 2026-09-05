#!/usr/bin/env bash
# Test that MUTATION_GO_TEST_FLAGS actually reaches `go test`.
#
# Proven by the verdict the flag changes: `-run` a pattern matching no test and the
# killed mutants must stop being killed. A suite that merely fails without the flag
# proves nothing, since an always-failing test kills every mutant trivially.
#
# go-flags reads `--test-flags -run X` as two options and refuses, so only the =
# form works, and every go test flag starts with a dash.

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODULE="$SKILL_DIR/lib/mutation-check-go.sh"

command -v go  >/dev/null || { echo "SKIP: go not on PATH"; exit 0; }
command -v git >/dev/null || { echo "SKIP: git not on PATH"; exit 0; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

commit() {
  GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=commit.gpgsign GIT_CONFIG_VALUE_0=false \
    git commit -q "$@"
}

run() { # run [test-flags]
  RC=0
  OUT="$(MUTATION_BASE=main MUTATION_FILES=./calc.go MUTATION_GO_TEST_FLAGS="${1:-}" \
         "$MODULE" 2>&1)" || RC=$?
}

git init -qb main
printf 'module example.com/tf\n\ngo 1.26\n' > go.mod
cat > calc.go <<'EOF'
package tf

func Double(x int) int {
	return x * 2
}
EOF
cat > calc_test.go <<'EOF'
package tf

import "testing"

func TestDouble(t *testing.T) {
	if Double(3) != 6 {
		t.Fatal("3")
	}
	if Double(-2) != -4 {
		t.Fatal("-2")
	}
}
EOF
git add .
commit -m baseline

git checkout -qb feature
cat >> calc.go <<'EOF'

func Triple(x int) int {
	return x * 3
}
EOF
cat >> calc_test.go <<'EOF'

func TestTriple(t *testing.T) {
	if Triple(3) != 9 {
		t.Fatal("3")
	}
	if Triple(-2) != -6 {
		t.Fatal("-2")
	}
}
EOF
git add .
commit -m "feat: add Triple"

echo "--- phase 1: baseline, no flags, every mutant is killed ---"
run ""
[ "$RC" -eq 0 ] || { echo "FAIL: expected exit 0 with no flags, got $RC"; echo "$OUT"; exit 1; }
echo "$OUT" | grep -q "all mutants on changed lines were killed" || { echo "FAIL: expected all killed"; echo "$OUT"; exit 1; }
echo "  ok: green without flags"

echo "--- phase 2: one flag value reaches go test and changes the verdict ---"
run "-run TestNothingMatchesThis"
echo "$OUT"
echo "$OUT" | grep -q "expected argument for flag" && { echo "FAIL: mutago rejected the flag form"; exit 1; }
[ "$RC" -eq 4 ] && { echo "FAIL: the flag never reached mutago (unmeasurable)"; exit 1; }
echo "$OUT" | grep -q "SURVIVED" || { echo "FAIL: -run did not reach go test; mutants still killed"; exit 1; }

echo "--- phase 3: several flags in one value are split, not passed as one argument ---"
run "-run TestNothingMatchesThis -count=1"
echo "$OUT"
echo "$OUT" | grep -q "expected argument for flag" && { echo "FAIL: two-flag value rejected"; exit 1; }
[ "$RC" -eq 4 ] && { echo "FAIL: two-flag value never reached mutago"; exit 1; }
echo "$OUT" | grep -q "SURVIVED" || { echo "FAIL: two flags did not both reach go test"; exit 1; }

echo "MUTATION GO TESTFLAGS OK"
