#!/usr/bin/env bash
# A run whose changed lines generated zero mutants must not read the same as one
# that killed every mutant it generated: both leave total_rows at zero, so the
# module needs mutago's own totalMutantsCount (via --logger-summary-json) to
# tell them apart. Distinct from run-mutation-go-buildtags.sh, whose zero mutants
# come from a file the build excludes entirely (caught earlier, as exit 4); here
# the file builds and is analysed, it just has nothing mutable in the diff.

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

git init -qb main
printf 'module example.com/zero\n\ngo 1.26\n' > go.mod
cat > calc.go <<'EOF'
package zero

func Double(x int) int {
	return x * 2
}
EOF
cat > calc_test.go <<'EOF'
package zero

import "testing"

func TestDouble(t *testing.T) {
	if Double(3) != 6 {
		t.Fatal("3")
	}
}
EOF
git add .
commit -m baseline

git checkout -qb feature
cat > meta.go <<'EOF'
package zero

// Meta carries no logic; nothing here is mutable.
type Meta struct {
	Note string
}
EOF
cat >> calc.go <<'EOF'

func Half(x int) int {
	return x / 2
}
EOF
cat >> calc_test.go <<'EOF'

func TestHalf(t *testing.T) {
	if Half(4) != 2 {
		t.Fatal("4")
	}
}
EOF
git add .
commit -m "add a struct type (nothing executable) and a tested Half function"

echo "--- phase 1: a changed file with no mutable statement reports zero generated ---"
RC=0
OUT="$(MUTATION_BASE=main MUTATION_FILES=./meta.go "$MODULE" 2>&1)" || RC=$?
echo "$OUT"
[ "$RC" -eq 0 ] || { echo "FAIL: expected exit 0, got $RC"; exit 1; }
echo "$OUT" | grep -q "generated no mutants on changed lines" || { echo "FAIL: expected the zero-mutants message"; exit 1; }
echo "$OUT" | grep -q "killed" && { echo "FAIL: a zero-mutant run must not read as a kill"; exit 1; }

echo "--- phase 2: a changed file that does generate mutants, all killed, is worded differently ---"
RC=0
OUT="$(MUTATION_BASE=main MUTATION_FILES=./calc.go "$MODULE" 2>&1)" || RC=$?
echo "$OUT"
[ "$RC" -eq 0 ] || { echo "FAIL: expected exit 0, got $RC"; exit 1; }
echo "$OUT" | grep -qE "generated [0-9]+ mutant\(s\) on changed lines, all killed" || { echo "FAIL: expected the all-killed message with a nonzero count"; exit 1; }
echo "$OUT" | grep -q "generated no mutants" && { echo "FAIL: a measured all-killed run must not read as unmeasured"; exit 1; }

echo "--- phase 3: the outer gate's own verdict line does not read a zero-mutant run as a plain pass ---"
GATE="$SKILL_DIR/mutation-check.sh"
RC=0
OUT="$(MUTATION_BASE=main MUTATION_ONLY='meta.go' "$GATE" "$WORK" 2>&1)" || RC=$?
echo "$OUT"
[ "$RC" -eq 0 ] || { echo "FAIL: expected exit 0, got $RC"; exit 1; }
echo "$OUT" | tail -n 1 | grep -qE '^mutation-check: EXIT=0 MUTATION_OK($|;)' && { echo "FAIL: a zero-mutant run's final line must not read as a plain MUTATION_OK"; exit 1; }
echo "$OUT" | grep -q 'this is not a pass' || { echo "FAIL: expected the zero-mutant module message to reach the outer verdict"; exit 1; }

echo "MUTATION GO ZERO OK"
