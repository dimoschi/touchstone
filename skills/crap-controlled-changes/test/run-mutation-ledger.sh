#!/usr/bin/env bash
# E2E test for the mutation ledger in mutation-check.sh: a green run records
# both source and test blobs, and --verify trusts that record without running
# any mutants. Follows run-scored-ledger.sh's shape.

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SKILL_DIR/mutation-check.sh"

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

run() {
  RC=0
  OUT="$("$SCRIPT" "$@" 2>&1)" || RC=$?
}

git init -qb main
printf 'module example.com/ledger\n\ngo 1.26\n' > go.mod
cat > calc.go <<'EOF'
package calc

func Double(x int) int {
	return x * 2
}
EOF
cat > calc_test.go <<'EOF'
package calc

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

func Sign(x int) int {
	if x < 0 {
		return -1
	}
	return 1
}
EOF
cat >> calc_test.go <<'EOF'

func TestSign(t *testing.T) {
	cases := map[int]int{-5: -1, -1: -1, 0: 1, 5: 1}
	for in, want := range cases {
		if got := Sign(in); got != want {
			t.Fatalf("Sign(%d) = %d, want %d", in, got, want)
		}
	}
}
EOF
git add calc.go calc_test.go
commit -m "feat: add Sign, fully tested"

echo "--- phase 1: a green run records both calc.go and calc_test.go ---"
run
echo "$OUT"
[ "$RC" -eq 0 ] || { echo "FAIL: expected MUTATION_OK, got $RC"; exit 1; }
echo "$OUT" | grep -q 'MUTATION_OK' || { echo "FAIL: no MUTATION_OK"; exit 1; }
[ -f .git/mutation-ledger.json ] || { echo "FAIL: ledger not written"; exit 1; }
grep -q 'calc.go' .git/mutation-ledger.json      || { echo "FAIL: calc.go not recorded"; exit 1; }
grep -q 'calc_test.go' .git/mutation-ledger.json || { echo "FAIL: calc_test.go not recorded (tests must be in the key)"; exit 1; }

echo "--- phase 2: --verify passes immediately, running no mutants ---"
run --verify
echo "$OUT"
[ "$RC" -eq 0 ] || { echo "FAIL: expected --verify to pass, got $RC"; exit 1; }
echo "$OUT" | grep -qi 'SURVIVED' && { echo "FAIL: --verify ran mutants"; exit 1; }

echo "--- phase 3: editing the source after the recorded run makes --verify fail, naming it ---"
cat >> calc.go <<'EOF'

func Triple(x int) int {
	return x * 3
}
EOF
git add calc.go
commit -m "feat: add Triple, not yet measured"
run --verify
echo "$OUT"
[ "$RC" -eq 5 ] || { echo "FAIL: expected exit 5, got $RC"; exit 1; }
echo "$OUT" | grep -q 'calc.go' || { echo "FAIL: unrecorded file not named"; exit 1; }
git reset -q --hard HEAD~1

echo "--- phase 4: editing only a test file also makes --verify fail (tests are in the key) ---"
cat >> calc_test.go <<'EOF'

func TestDoubleZero(t *testing.T) {
	if Double(0) != 0 {
		t.Fatal("0")
	}
}
EOF
git add calc_test.go
commit -m "test: add a case, not re-measured"
run --verify
echo "$OUT"
[ "$RC" -eq 5 ] || { echo "FAIL: expected exit 5 for a test-only change, got $RC"; exit 1; }
echo "$OUT" | grep -q 'calc_test.go' || { echo "FAIL: unrecorded test file not named"; exit 1; }
git reset -q --hard HEAD~1

echo "--- phase 5: a branch with only test changes takes the early exit, but still records ---"
git checkout -q main
git checkout -qb test-only
cat >> calc_test.go <<'EOF'

func TestDoubleTwice(t *testing.T) {
	if Double(Double(2)) != 8 {
		t.Fatal("8")
	}
}
EOF
git add calc_test.go
commit -m "test: add a case, no source changed"
run
echo "$OUT"
[ "$RC" -eq 0 ] || { echo "FAIL: test-only branch should take the early exit (exit 0), got $RC"; exit 1; }
echo "$OUT" | grep -q 'no changed source files' || { echo "FAIL: expected the early-exit message"; exit 1; }
run --verify
[ "$RC" -eq 0 ] || { echo "FAIL: early exit must still record calc_test.go; --verify should pass, got $RC"; echo "$OUT"; exit 1; }

echo "MUTATION LEDGER OK"
