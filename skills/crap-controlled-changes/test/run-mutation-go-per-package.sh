#!/usr/bin/env bash
# Test that each changed package directory gets its own mutago process.
#
# mutago keeps every package it loads, with its full dependency graph, until the
# process exits, so one process over a branch touching many packages grew past
# the memory of the machine running it. Separate processes bound the peak to one
# package. The report must not change: survivors from every run are listed, and
# the "all killed" total is the sum over the runs.

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODULE="$SKILL_DIR/lib/mutation-check-go.sh"

command -v go  >/dev/null || { echo "SKIP: go not on PATH"; exit 0; }
command -v git >/dev/null || { echo "SKIP: git not on PATH"; exit 0; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"
CALLS="$WORK/calls.log"
mkdir -p "$REPO"
cd "$REPO"

cat > "$WORK/runner.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$CALLS"
exec "\$@"
EOF
chmod +x "$WORK/runner.sh"

commit() {
  GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=commit.gpgsign GIT_CONFIG_VALUE_0=false \
    git commit -q "$@"
}

run() { # run <newline-separated files>
  RC=0
  : > "$CALLS"
  OUT="$(MUTATION_BASE=main MUTATION_FILES="$1" MUTATION_GO_RUNNER="$WORK/runner.sh" \
         "$MODULE" 2>&1)" || RC=$?
}

generated() { printf '%s\n' "$OUT" | sed -n 's/.*generated \([0-9]*\) mutant(s) on changed lines, all killed.*/\1/p'; }

git init -qb main
printf 'module example.com/pp\n\ngo 1.26\n' > go.mod
mkdir alpha beta
printf 'package alpha\n' > alpha/alpha.go
printf 'package beta\n' > beta/beta.go
git add .
commit -m baseline

git checkout -qb feature
cat > alpha/alpha.go <<'EOF'
package alpha

func Double(x int) int {
	return x * 2
}
EOF
cat > alpha/alpha_test.go <<'EOF'
package alpha

import "testing"

func TestDouble(t *testing.T) {
	if Double(3) != 6 || Double(-2) != -4 {
		t.Fatal("Double")
	}
}
EOF
cat > beta/beta.go <<'EOF'
package beta

func Triple(x int) int {
	return x * 3
}
EOF
cat > beta/beta_test.go <<'EOF'
package beta

import "testing"

func TestTriple(t *testing.T) {
	if Triple(3) != 9 || Triple(-2) != -6 {
		t.Fatal("Triple")
	}
}
EOF
git add .
commit -m "feat: add Double and Triple"

echo "--- phase 1: two packages, one mutago process each ---"
run $'./alpha/alpha.go\n./beta/beta.go'
[ "$RC" -eq 0 ] || { echo "FAIL: expected exit 0, got $RC"; echo "$OUT"; exit 1; }
calls="$(grep -c 'mutago' "$CALLS")"
[ "$calls" -eq 2 ] || { echo "FAIL: expected 2 mutago processes, got $calls"; cat "$CALLS"; exit 1; }
grep 'mutago' "$CALLS" | grep -q 'alpha.go.*beta.go\|beta.go.*alpha.go' \
  && { echo "FAIL: one mutago process got both packages"; cat "$CALLS"; exit 1; }
both="$(generated)"
[ -n "$both" ] || { echo "FAIL: expected an all-killed total"; echo "$OUT"; exit 1; }
echo "  ok: 2 processes, $both mutants all killed"

echo "--- phase 2: the total is the sum of the per-package totals ---"
run ./alpha/alpha.go
alpha="$(generated)"
run ./beta/beta.go
beta="$(generated)"
[ "$both" -eq $((alpha + beta)) ] || { echo "FAIL: total $both != $alpha + $beta"; exit 1; }
echo "  ok: $both = $alpha + $beta"

echo "--- phase 3: a survivor in the second package is still reported ---"
cat > beta/beta_test.go <<'EOF'
package beta

import "testing"

func TestTriple(t *testing.T) {
	Triple(3)
}
EOF
git add .
commit -m "test: weaken TestTriple"
run $'./alpha/alpha.go\n./beta/beta.go'
printf '%s\n' "$OUT" | grep ' SURVIVED ' | grep -q 'beta/beta.go' \
  || { echo "FAIL: expected a beta survivor"; echo "$OUT"; exit 1; }
printf '%s\n' "$OUT" | grep ' SURVIVED ' | grep -q 'alpha/alpha.go' \
  && { echo "FAIL: alpha has no survivors"; echo "$OUT"; exit 1; }
echo "  ok: beta survivor reported, alpha clean"

echo "MUTATION GO PER PACKAGE OK"
