#!/usr/bin/env bash
# E2E test that the mutation ledger survives its worktree. It is keyed on git
# blobs, so a record is valid for byte-identical content no matter which worktree
# measured it; storing it in the per-worktree git dir meant `git worktree remove`
# discarded a green measurement and the next worktree on the same branch paid a
# full re-run. Follows run-mutation-ledger.sh's shape.

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SKILL_DIR/mutation-check.sh"

command -v go  >/dev/null || { echo "SKIP: go not on PATH"; exit 0; }
command -v git >/dev/null || { echo "SKIP: git not on PATH"; exit 0; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
MAIN="$WORK/main"
mkdir -p "$MAIN"
cd "$MAIN"

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
printf 'module example.com/wt\n\ngo 1.26\n' > go.mod
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

git worktree add -q -b feature "$WORK/wt"
cd "$WORK/wt"
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

echo "--- phase 1: a green run inside a worktree records to the shared git dir ---"
run
echo "$OUT"
[ "$RC" -eq 0 ] || { echo "FAIL: expected MUTATION_OK, got $RC"; exit 1; }
[ -f "$MAIN/.git/mutation-ledger.json" ] || { echo "FAIL: no ledger in the common git dir"; exit 1; }
grep -q 'feature' "$MAIN/.git/mutation-ledger.json" || { echo "FAIL: branch not recorded in the common ledger"; exit 1; }
[ -f "$MAIN/.git/worktrees/wt/mutation-ledger.json" ] && { echo "FAIL: ledger still written per-worktree"; exit 1; }

echo "--- phase 2: --verify passes from inside the worktree ---"
run --verify
[ "$RC" -eq 0 ] || { echo "FAIL: expected --verify to pass, got $RC"; echo "$OUT"; exit 1; }

echo "--- phase 3: the record survives git worktree remove and a fresh worktree ---"
cd "$MAIN"
git worktree remove "$WORK/wt"
[ -d "$WORK/wt" ] && { echo "FAIL: worktree not removed"; exit 1; }
git worktree add -q "$WORK/wt2" feature
cd "$WORK/wt2"
run --verify
echo "$OUT"
[ "$RC" -eq 0 ] || { echo "FAIL: a fresh worktree on the same branch must trust the record, got $RC"; exit 1; }
echo "$OUT" | grep -q 'never recorded' && { echo "FAIL: record was lost with the old worktree"; exit 1; }

echo "--- phase 4: a full run in the new worktree finds nothing left to measure ---"
run
echo "$OUT"
[ "$RC" -eq 0 ] || { echo "FAIL: expected exit 0, got $RC"; exit 1; }
echo "$OUT" | grep -q 'already measured' || { echo "FAIL: expected the already-measured message, i.e. zero re-measurement"; exit 1; }

echo "--- phase 5: a user's mutant acceptance is shared too, not lost with the worktree ---"
run --accept 'someMutator@src/x.go:1'
[ "$RC" -eq 0 ] || { echo "FAIL: --accept failed, got $RC"; echo "$OUT"; exit 1; }
[ -f "$MAIN/.git/mutation-accepted.json" ] || { echo "FAIL: acceptance not in the common git dir"; exit 1; }
[ -f "$MAIN/.git/worktrees/wt2/mutation-accepted.json" ] && { echo "FAIL: acceptance written per-worktree"; exit 1; }

echo "MUTATION WORKTREE LEDGER OK"
