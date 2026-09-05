#!/usr/bin/env bash
# E2E test for the scored-blob ledger in crap-check.sh.
# Covers the case that motivated it (a docs + _test.go follow-up commit must not
# be mistaken for an unmeasured commit) and the cases a diff-text fingerprint
# got wrong: amend, and source edited after it was scored.

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SKILL_DIR/crap-check.sh"

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
  OUT="$("$SCRIPT" 2>&1)" || RC=$?
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
}
EOF
git add .
commit -m baseline

git checkout -qb feature

echo "--- phase 1: green run on staged source records the ledger ---"
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
}
EOF
git add calc.go calc_test.go
run
echo "$OUT"
[ "$RC" -eq 0 ] || { echo "FAIL: expected green gate (exit 0), got $RC"; exit 1; }
[ -f .git/crap-check-scored.json ] || { echo "FAIL: ledger not written"; exit 1; }
grep -q 'calc.go' .git/crap-check-scored.json || { echo "FAIL: calc.go not in ledger"; exit 1; }
grep -q 'calc_test.go' .git/crap-check-scored.json && { echo "FAIL: test file recorded as measurable"; exit 1; }

echo "--- phase 2: docs + _test.go follow-up commit is not an unmeasured commit ---"
commit -m "feat: add Triple"
mkdir -p docs
echo "# notes" > docs/notes.md
cat >> calc_test.go <<'EOF'

func TestDoubleNegative(t *testing.T) {
	if Double(-2) != -4 {
		t.Fatal("-2")
	}
}
EOF
git add docs/notes.md calc_test.go
commit -m "docs: notes, and another Double case"
run
echo "$OUT"
[ "$RC" -eq 0 ] || { echo "FAIL: docs+test follow-up should pass, got $RC"; echo "$OUT"; exit 1; }
echo "$OUT" | grep -q 'already scored' || { echo "FAIL: expected already-scored message"; exit 1; }

echo "--- phase 3: amending the commit does not invalidate the ledger ---"
commit --amend -m "docs: notes, and another Double case (reworded)"
run
[ "$RC" -eq 0 ] || { echo "FAIL: amend should not invalidate ledger, got $RC"; echo "$OUT"; exit 1; }

echo "--- phase 4: source edited after scoring, committed unmeasured, is caught ---"
cat >> calc.go <<'EOF'

func Quad(x int) int {
	return x * 4
}
EOF
git add calc.go
commit -m "feat: add Quad without measuring"
run
echo "$OUT"
[ "$RC" -eq 5 ] || { echo "FAIL: expected exit 5 for unscored source, got $RC"; exit 1; }
echo "$OUT" | grep -q 'calc.go' || { echo "FAIL: unscored file not named"; exit 1; }
echo "$OUT" | grep -q 'nothing was measured' || { echo "FAIL: expected unmeasured banner"; exit 1; }

echo "--- phase 5: --mark-scored is an explicit override that clears it ---"
OUT="$("$SCRIPT" --mark-scored 2>&1)" || { echo "FAIL: --mark-scored errored"; exit 1; }
echo "$OUT" | grep -q 'WITHOUT measuring' || { echo "FAIL: override not labelled as such"; exit 1; }
run
[ "$RC" -eq 0 ] || { echo "FAIL: expected pass after --mark-scored, got $RC"; echo "$OUT"; exit 1; }

echo "--- phase 6: a branch with no scored history says so ---"
git checkout -q main
git checkout -qb feature2
cat >> calc.go <<'EOF'

func Quint(x int) int {
	return x * 5
}
EOF
git add calc.go
commit -m "feat: add Quint without measuring"
run
echo "$OUT"
[ "$RC" -eq 5 ] || { echo "FAIL: expected exit 5 on virgin branch, got $RC"; exit 1; }
echo "$OUT" | grep -q 'ever been scored' || { echo "FAIL: expected virgin-branch advice"; exit 1; }
echo "$OUT" | grep -q -- '--mark-scored' || { echo "FAIL: expected adoption hint"; exit 1; }

echo "SCORED LEDGER OK"
