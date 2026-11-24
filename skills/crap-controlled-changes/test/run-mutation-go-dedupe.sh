#!/usr/bin/env bash
# Test that a changed line is measured even when an unchanged line has the same text.
#
# mutago before v2.10.2 skipped a mutation whose changed-line text matched one it
# had already made in the run, before filtering to the diff. An untested new
# function sharing `if x < 0 {` with a tested old one then never had its
# mutants run, and the gate reported the branch as all killed.

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODULE="$SKILL_DIR/lib/mutation-check-go.sh"

command -v go  >/dev/null || { echo "SKIP: go not on PATH"; exit 0; }
command -v git >/dev/null || { echo "SKIP: git not on PATH"; exit 0; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK" || exit 1

commit() {
  GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=commit.gpgsign GIT_CONFIG_VALUE_0=false \
    git commit -q "$@"
}

git init -qb main
printf 'module example.com/dd\n\ngo 1.26\n' > go.mod
cat > calc.go <<'EOF'
package dd

func Sign(x int) int {
	if x < 0 {
		return -1
	}
	return 1
}
EOF
cat > calc_test.go <<'EOF'
package dd

import "testing"

func TestSign(t *testing.T) {
	cases := map[int]int{-5: -1, -1: -1, 0: 1, 5: 1}
	for in, want := range cases {
		if got := Sign(in); got != want {
			t.Fatalf("Sign(%d) = %d, want %d", in, got, want)
		}
	}
}
EOF
git add .
commit -m baseline

git checkout -qb feature
cat >> calc.go <<'EOF'

func Step(x int) int {
	if x < 0 {
		return 0
	}
	return 1
}
EOF
git add .
commit -m "feat: add Step, untested"

RC=0
OUT="$(MUTATION_BASE=main MUTATION_FILES=calc.go "$MODULE" 2>&1)" || RC=$?
echo "$OUT"
printf '%s\n' "$OUT" | grep ' SURVIVED ' | grep -q 'calc.go:11 .*expression/comparison' \
  || { echo "FAIL: Step's boundary mutant on calc.go:11 must survive, got exit $RC"; exit 1; }
printf '%s\n' "$OUT" | grep -q 'all killed' \
  && { echo "FAIL: an untested function was reported all killed"; exit 1; }

echo "MUTATION GO DEDUPE OK"
