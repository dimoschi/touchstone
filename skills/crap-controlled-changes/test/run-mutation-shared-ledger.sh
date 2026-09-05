#!/usr/bin/env bash
# E2E test that a green mutation record survives the branch that made it, and
# only where that is sound. Merging preserves blobs, so every file a PR measured
# enters the base branch byte-identical and used to be re-measured from scratch.
# Borrowing is bounded by two guards this test exercises: the measuring commit
# must be reachable, and the tool versions must match.

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SKILL_DIR/mutation-check.sh"

command -v go  >/dev/null || { echo "SKIP: go not on PATH"; exit 0; }
command -v git >/dev/null || { echo "SKIP: git not on PATH"; exit 0; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

GIT_ENV=(GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
         GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=commit.gpgsign GIT_CONFIG_VALUE_0=false)

commit() { env "${GIT_ENV[@]}" git commit -q "$@"; }
merge()  { env "${GIT_ENV[@]}" git merge -q "$@"; }
pick()   { env "${GIT_ENV[@]}" git cherry-pick "$@" >/dev/null; }

run() {
  RC=0
  OUT="$(MUTATION_BASE="$BASE" "$SCRIPT" "$@" 2>&1)" || RC=$?
}

git init -qb main
printf 'module example.com/shared\n\ngo 1.26\n' > go.mod
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
BASE="$(git rev-parse HEAD)"

add_sign() {
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
}

echo "--- phase 1: a green run records the blob outside the branch namespace ---"
git checkout -qb feature
add_sign
git add calc.go calc_test.go
commit -m "feat: add Sign, fully tested"
run
echo "$OUT"
[ "$RC" -eq 0 ] || { echo "FAIL: expected MUTATION_OK on the branch, got $RC"; exit 1; }
grep -q '"feature"' .git/mutation-ledger.json || { echo "FAIL: branch record missing"; exit 1; }
grep -q '"\.\.blobs"' .git/mutation-ledger.json || { echo "FAIL: no shared blob namespace written"; exit 1; }
FEATURE_TIP="$(git rev-parse HEAD)"

echo "--- phase 2: after the merge the base branch trusts the record it inherited ---"
git checkout -q main
merge --no-ff -m "Merge feature" feature
run --verify
echo "$OUT"
[ "$RC" -eq 0 ] || { echo "FAIL: merged blobs must verify without re-measuring, got $RC"; exit 1; }
echo "$OUT" | grep -q 'borrowed' || { echo "FAIL: borrowing a record must be stated, not silent"; exit 1; }

echo "--- phase 3: a different mutator version is not allowed to borrow it ---"
RC=0
OUT="$(MUTATION_BASE="$BASE" MUTATION_GO_MUTAGO_VERSION=v2.8.0 "$SCRIPT" --verify 2>&1)" || RC=$?
echo "$OUT"
[ "$RC" -eq 5 ] || { echo "FAIL: a record measured by another mutago version must not count, got $RC"; exit 1; }

echo "--- phase 4: the full run on the base branch measures nothing ---"
run
echo "$OUT"
[ "$RC" -eq 0 ] || { echo "FAIL: expected exit 0 on the merge commit, got $RC"; exit 1; }
echo "$OUT" | grep -q 'already measured' || { echo "FAIL: expected zero re-measurement after a merge"; exit 1; }

echo "--- phase 5: an identical blob from unreachable history is not borrowed ---"
git checkout -q -b sibling "$BASE"
pick "$FEATURE_TIP"
[ "$(git rev-parse HEAD:calc.go)" = "$(git rev-parse "$FEATURE_TIP":calc.go)" ] ||
  { echo "FAIL: cherry-pick did not reproduce the blob, test is not testing anything"; exit 1; }
git merge-base --is-ancestor "$FEATURE_TIP" HEAD &&
  { echo "FAIL: the measuring commit is reachable here, test is not testing anything"; exit 1; }
run --verify
echo "$OUT"
[ "$RC" -eq 5 ] || { echo "FAIL: a record from history this branch does not contain must not count, got $RC"; exit 1; }

echo "MUTATION SHARED LEDGER OK"
