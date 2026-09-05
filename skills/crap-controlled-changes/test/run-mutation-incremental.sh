#!/usr/bin/env bash
# E2E test for incremental scoping in mutation-check.sh: a follow-up commit
# re-measures only the source files it dirtied, plus the package of any changed
# or deleted test file. Follows run-mutation-ledger.sh's shape.
#
# The load-bearing phase is 3: deleting a test file un-kills mutants in a source
# file whose own blob never changed, and the ledger cannot see it (head_pairs
# skips paths absent from HEAD). If that case narrows to nothing, the gate passes
# a branch whose tests no longer kill anything.

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SKILL_DIR/mutation-check.sh"

echo "--- unit: incremental_scope.py narrowing and closure ---"
UNIT="$(mktemp -d)"
mkdir -p "$UNIT/a" "$UNIT/b" "$UNIT/src" "$UNIT/tests" "$UNIT/pkg"
touch "$UNIT/a/a.go" "$UNIT/b/b.go" "$UNIT/src/Foo.php" "$UNIT/src/Bar.php" "$UNIT/pkg/m.py" "$UNIT/pkg/n.py"

scope() { # scope <lang> <invalidated> <candidates> -> narrowed, one path per line
  printf '%s\n' "$2" > "$UNIT/invalidated"
  ( cd "$UNIT" && printf '%s\n' "$3" | python3 "$SKILL_DIR/lib/incremental_scope.py" "$1" invalidated )
}

expect() { # expect <label> <want> <got>
  [ "$2" = "$3" ] || { echo "FAIL: $1"; echo "  want: [$2]"; echo "  got:  [$3]"; exit 1; }
  echo "  ok: $1"
}

expect "go: a changed test pulls its own package's source in" \
  "a/a.go" "$(scope go 'a/a_test.go' 'a/a.go
b/b.go')"
expect "go: a package with nothing invalidated stays out" \
  "b/b.go" "$(scope go 'b/b.go' 'a/a.go
b/b.go')"
expect "go: a deleted source pulls its surviving siblings in" \
  "a/a.go" "$(scope go 'a/gone.go' 'a/a.go
b/b.go')"
expect "go: a changed generated file invalidates its package" \
  "a/a.go" "$(scope go 'a/mock_thing.go' 'a/a.go
b/b.go')"
expect "php: a changed test falls back to the whole set" \
  "src/Bar.php
src/Foo.php" "$(scope php 'tests/FooTest.php' 'src/Foo.php
src/Bar.php')"
expect "php: a source-only change narrows to that source" \
  "src/Foo.php" "$(scope php 'src/Foo.php' 'src/Foo.php
src/Bar.php')"
expect "python: a changed test falls back to the whole set" \
  "pkg/m.py
pkg/n.py" "$(scope py 'tests/test_m.py' 'pkg/m.py
pkg/n.py')"
expect "other languages' paths never widen this one's scope" \
  "" "$(scope go 'src/Foo.php
tests/test_m.py' 'a/a.go')"
rm -rf "$UNIT"

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
printf 'module example.com/inc\n\ngo 1.26\n' > go.mod
mkdir -p a b
cat > a/a.go <<'EOF'
package a

func Double(x int) int {
	return x * 2
}
EOF
cat > a/a_test.go <<'EOF'
package a

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
cat > b/b.go <<'EOF'
package b

func Triple(x int) int {
	return x * 3
}
EOF
cat > b/b_test.go <<'EOF'
package b

import "testing"

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
commit -m baseline

git checkout -qb feature
cat >> a/a.go <<'EOF'

func Sign(x int) int {
	if x < 0 {
		return -1
	}
	return 1
}
EOF
cat >> a/a_test.go <<'EOF'

func TestSign(t *testing.T) {
	cases := map[int]int{-5: -1, -1: -1, 0: 1, 5: 1}
	for in, want := range cases {
		if got := Sign(in); got != want {
			t.Fatalf("Sign(%d) = %d, want %d", in, got, want)
		}
	}
}
EOF
cat >> b/b.go <<'EOF'

func Abs(x int) int {
	if x < 0 {
		return -x
	}
	return x
}
EOF
cat >> b/b_test.go <<'EOF'

func TestAbs(t *testing.T) {
	cases := map[int]int{-5: 5, -1: 1, 0: 0, 5: 5}
	for in, want := range cases {
		if got := Abs(in); got != want {
			t.Fatalf("Abs(%d) = %d, want %d", in, got, want)
		}
	}
}
EOF
git add .
commit -m "feat: add Sign and Abs, fully tested"

echo "--- phase 0: the first run on a branch narrows to nothing, both sources measured ---"
run
echo "$OUT"
[ "$RC" -eq 0 ] || { echo "FAIL: expected MUTATION_OK, got $RC"; exit 1; }
echo "$OUT" | grep -q 'incremental scope, 2 of 2' || { echo "FAIL: a fresh branch must measure every changed source"; exit 1; }

echo "--- phase 1: a follow-up touching one package measures only that package ---"
cat >> a/a.go <<'EOF'

func Negate(x int) int {
	return -x
}
EOF
cat >> a/a_test.go <<'EOF'

func TestNegate(t *testing.T) {
	if Negate(3) != -3 {
		t.Fatal("3")
	}
	if Negate(0) != 0 {
		t.Fatal("0")
	}
}
EOF
git add a
commit -m "feat: add Negate"
run
echo "$OUT"
[ "$RC" -eq 0 ] || { echo "FAIL: expected MUTATION_OK, got $RC"; exit 1; }
echo "$OUT" | grep -q 'incremental scope, 1 of 2' || { echo "FAIL: b/b.go was already measured and should have been skipped"; exit 1; }

echo "--- phase 2: a test-only edit re-measures its own package (closure) ---"
cat >> a/a_test.go <<'EOF'

func TestDoubleZero(t *testing.T) {
	if Double(0) != 0 {
		t.Fatal("0")
	}
}
EOF
git add a/a_test.go
commit -m "test: add a case"
run
echo "$OUT"
[ "$RC" -eq 0 ] || { echo "FAIL: expected MUTATION_OK, got $RC"; exit 1; }
echo "$OUT" | grep -q 'incremental scope, 1 of 2' || { echo "FAIL: a changed test must pull its package's source back in"; exit 1; }
echo "$OUT" | grep -q '== go (vs ' || { echo "FAIL: closure did not actually run the go module"; exit 1; }
echo "$OUT" | grep -q 'already measured' && { echo "FAIL: narrowed to nothing on a test change"; exit 1; }

echo "--- phase 3: a DELETED test re-measures its package, and its survivors block ---"
git rm -q b/b_test.go
commit -m "test: drop b's tests entirely"
run
echo "$OUT"
[ "$RC" -eq 1 ] || { echo "FAIL: deleting b's tests must surface survivors in b/b.go, got $RC"; exit 1; }
echo "$OUT" | grep -q 'b/b.go' || { echo "FAIL: no survivor reported in b/b.go"; exit 1; }
git reset -q --hard HEAD~1

echo "--- phase 4: --full re-measures everything, no narrowing ---"
run --full
echo "$OUT"
[ "$RC" -eq 0 ] || { echo "FAIL: expected MUTATION_OK from --full, got $RC"; exit 1; }
echo "$OUT" | grep -q 'incremental scope' && { echo "FAIL: --full must not narrow"; exit 1; }

echo "--- phase 5: nothing dirtied since the last green run runs no mutants ---"
run
echo "$OUT"
[ "$RC" -eq 0 ] || { echo "FAIL: expected exit 0, got $RC"; exit 1; }
echo "$OUT" | grep -q 'already measured' || { echo "FAIL: expected the already-measured message"; exit 1; }
echo "$OUT" | grep -q 'no changed source files' && { echo "FAIL: that message is for a branch with no changed sources at all"; exit 1; }
echo "$OUT" | grep -qi 'SURVIVED' && { echo "FAIL: ran mutants when there was nothing to measure"; exit 1; }

echo "--- phase 6: narrowing never makes --verify trust an unmeasured blob ---"
run --verify
[ "$RC" -eq 0 ] || { echo "FAIL: --verify should pass after a green run, got $RC"; echo "$OUT"; exit 1; }
cat >> b/b.go <<'EOF'

func Quad(x int) int {
	return x * 4
}
EOF
git add b/b.go
commit -m "feat: add Quad, not yet measured"
run --verify
echo "$OUT"
[ "$RC" -eq 5 ] || { echo "FAIL: expected exit 5 for an unmeasured blob, got $RC"; exit 1; }
echo "$OUT" | grep -q 'b/b.go' || { echo "FAIL: unrecorded file not named"; exit 1; }
git reset -q --hard HEAD~1

echo "--- phase 7: an unknown option is refused, not silently treated as default ---"
run --ful
echo "$OUT"
[ "$RC" -eq 2 ] || { echo "FAIL: expected exit 2 for an unknown option, got $RC"; exit 1; }

echo "--- phase 8: a dirty tree is still refused, not narrowed away ---"
echo "// dirty" >> a/a.go
run
echo "$OUT"
[ "$RC" -eq 2 ] || { echo "FAIL: an uncommitted edit to a measured file must not narrow to nothing, got $RC"; exit 1; }
git checkout -q a/a.go

echo "MUTATION INCREMENTAL OK"
