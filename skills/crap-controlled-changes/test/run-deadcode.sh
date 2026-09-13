#!/usr/bin/env bash
# Tests deadcode-check.sh: the gate that stops a diff adding code nothing can
# reach, including the case CRAP and mutation both wave through -- a helper whose
# only caller is its own test.

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$SKILL_DIR/deadcode-check.sh"

command -v go >/dev/null || { echo "SKIP: go not on PATH"; exit 0; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
failures=0

check() {
  if [ "$2" = "$3" ]; then
    echo "  ok:   $1"
  else
    echo "  FAIL: $1 (got '$2', want '$3')"
    failures=$((failures + 1))
  fi
}

commit() {
  GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
    git -c commit.gpgsign=false -c gpg.format=openpgp commit -q "$@"
}

cd "$WORK"
git init -qb main app
cd app
printf 'module example.com/dc\n\ngo 1.26\n' > go.mod
mkdir -p cmd/app lib
cat > lib/lib.go <<'EOF'
package lib

func Used() int { return 1 }
EOF
cat > cmd/app/main.go <<'GO'
package main

import "example.com/dc/lib"

func main() { _ = lib.Used() }
GO
git add . && commit -m baseline

run() { RC=0; OUT="$("$CHECK" 2>&1)" || RC=$?; }

echo "case A: a helper reachable from main is fine"
cat >> lib/lib.go <<'EOF'

func AlsoUsed() int { return Used() + 1 }
EOF
python3 - <<'PY'
import pathlib
p = pathlib.Path('cmd/app/main.go')
p.write_text(p.read_text().replace('_ = lib.Used()', '_ = lib.Used() + lib.AlsoUsed()'))
PY
git add lib/lib.go cmd/app/main.go
run
check "clean exit" "$RC" "0"
check "says OK" "$(printf '%s' "$OUT" | grep -c DEADCODE_OK)" "1"
commit -m "feat: reachable helper"

echo "case B: a helper only its own test calls is caught"
cat >> lib/lib.go <<'EOF'

func TestOnlyHelper() int { return 7 }
EOF
cat > lib/lib_test.go <<'EOF'
package lib

import "testing"

func TestHelper(t *testing.T) {
	if TestOnlyHelper() != 7 {
		t.Fatal("x")
	}
}
EOF
git add lib/lib.go lib/lib_test.go
run
check "gate is red" "$RC" "1"
check "names the symbol" "$(printf '%s' "$OUT" | grep -c 'TestOnlyHelper')" "1"
check "directive is DELETE_UNREACHABLE" "$(printf '%s' "$OUT" | grep -c DELETE_UNREACHABLE)" "1"
check "prints an accept key" "$(printf '%s' "$OUT" | grep -c 'lib/lib.go|TestOnlyHelper')" "1"

echo "case C: pre-existing dead code does not block a later diff"
commit -m "feat: add an unreachable helper anyway"
echo "# notes" > NOTES.md
git add NOTES.md
run
check "clean exit on an unrelated diff" "$RC" "0"

echo "case D: the recorded override clears it, and only it"
cat >> lib/lib.go <<'EOF'

func SecondDead() int { return 8 }
EOF
git add lib/lib.go
run
check "the new one is caught" "$(printf '%s' "$OUT" | grep -c 'SecondDead')" "1"
"$CHECK" --accept 'lib/lib.go|SecondDead' >/dev/null 2>&1 || true
run
check "accepted symbol no longer fails" "$RC" "0"
check "but is still shown as accepted" "$(printf '%s' "$OUT" | grep -c 'SecondDead  ACCEPTED')" "1"

echo "case E0: an UNSTAGED caller must not satisfy the gate"
# The dead symbol would be committed; a caller that is only in the working tree
# would not. Judging the working tree instead of the index passes this wrongly.
cat >> lib/lib.go <<'EOF'

func StagedDead() int { return 11 }
EOF
git add lib/lib.go
run
check "red while nothing calls it" "$RC" "1"
python3 - <<'PY'
import pathlib
p = pathlib.Path('cmd/app/main.go')
p.write_text(p.read_text().replace('lib.AlsoUsed()', 'lib.AlsoUsed() + lib.StagedDead()'))
PY
check "caller is unstaged" \
      "$(git status --porcelain cmd/app/main.go | cut -c1-2)" " M"
run
check "still red: the caller is not staged" "$RC" "1"
check "still names the symbol" "$(printf '%s' "$OUT" | grep -c 'StagedDead')" "1"
git checkout -q -- cmd/app/main.go
git checkout -q -- lib/lib.go 2>/dev/null || true
git reset -q lib/lib.go cmd/app/main.go 2>/dev/null || true
git checkout -q -- . 2>/dev/null || true

echo "case E: methods are keyed Type.Method"
commit -m "chore: accepted dead symbol"
cat >> lib/lib.go <<'EOF'

type Thing struct{}

func (t *Thing) Orphan() int { return 9 }
EOF
git add lib/lib.go
run
check "method is caught" "$(printf '%s' "$OUT" | grep -c 'Thing.Orphan')" "1"

echo "case E1: a staged state that does not compile is not a pass"
# deadcode exits 0 even when it reports findings, so an analysis failure can only
# be told apart by its exit status; its error text is not evidence of one.
cat >> lib/lib.go <<'EOF'

func Uncompilable() int { return noSuchHelper() }
EOF
git add lib/lib.go
run
check "exit 2, not 0" "$RC" "2"
check "says FAILED TO ANALYSE" "$(printf '%s' "$OUT" | grep -c 'FAILED TO ANALYSE')" "1"
check "denies being a pass" "$(printf '%s' "$OUT" | grep -c 'NOT a pass')" "1"
check "shows the build error" "$(printf '%s' "$OUT" | grep -c 'noSuchHelper')" "1"
check "does not claim OK" "$(printf '%s' "$OUT" | grep -c DEADCODE_OK)" "0"
git reset -q lib/lib.go && git checkout -q -- lib/lib.go

echo "case G: a package only tests import is judged from the test roots"
# The case a path or name exclusion gets wrong: exempting the whole package
# would let NeverCalled through too.
mkdir -p libtest
cat > libtest/helper.go <<'EOF'
package libtest

func Helper() int { return 5 }

func NeverCalled() int { return 6 }
EOF
cat > lib/lib_test.go <<'EOF'
package lib

import (
	"testing"

	"example.com/dc/libtest"
)

func TestHelper(t *testing.T) {
	if TestOnlyHelper() != 7 || libtest.Helper() != 5 {
		t.Fatal("x")
	}
}
EOF
git add libtest/helper.go lib/lib_test.go
run
check "gate is red" "$RC" "1"
check "the test-called helper passes" "$(printf '%s' "$OUT" | grep -c 'helper.go|Helper')" "0"
check "the helper no test calls is still caught" "$(printf '%s' "$OUT" | grep -c 'NeverCalled')" "1"

echo "case H: once production imports it, the strict rule comes back"
commit -m "test: add a test-only helper package"
python3 - <<'PY'
import pathlib
p = pathlib.Path('cmd/app/main.go')
t = p.read_text().replace(
    'import "example.com/dc/lib"',
    'import (\n\t"example.com/dc/lib"\n\t"example.com/dc/libtest"\n)')
t = t.replace('lib.AlsoUsed()', 'lib.AlsoUsed() + libtest.Helper()')
p.write_text(t)
PY
cat >> libtest/helper.go <<'EOF'

func ProdEraHelper() int { return 12 }
EOF
cat > lib/lib_test.go <<'EOF'
package lib

import (
	"testing"

	"example.com/dc/libtest"
)

func TestHelper(t *testing.T) {
	if TestOnlyHelper() != 7 || libtest.ProdEraHelper() != 12 {
		t.Fatal("x")
	}
}
EOF
git add cmd/app/main.go libtest/helper.go lib/lib_test.go
run
check "gate is red again" "$RC" "1"
check "a test-only caller no longer saves it" "$(printf '%s' "$OUT" | grep -c 'ProdEraHelper')" "1"
git checkout -q -- . 2>/dev/null || true
git reset -q 2>/dev/null || true

echo "case F: a module with no main package skips loudly, and does not pass silently"
cd "$WORK"
git init -qb main libonly
cd libonly
printf 'module example.com/lo\n\ngo 1.26\n' > go.mod
cat > lib.go <<'EOF'
package lo

func Exported() int { return 1 }
EOF
git add . && commit -m baseline
cat >> lib.go <<'EOF'

func Another() int { return 2 }
EOF
git add lib.go
run
check "exit 0 (cannot decide, does not block)" "$RC" "0"
check "says SKIPPED" "$(printf '%s' "$OUT" | grep -c 'SKIPPED for module')" "1"
check "denies being a pass" "$(printf '%s' "$OUT" | grep -c 'not a pass')" "1"
check "reports the skip in NEXT_ACTION" "$(printf '%s' "$OUT" | grep -c DEADCODE_SKIPPED)" "1"

echo "case I: a marker-exempted file with no enclosing go.mod is skipped, not analysed"
cd "$WORK"
git init -qb main noroot
cd noroot
mkdir -p sub
printf 'module example.com/noroot/sub\n\ngo 1.26\n' > sub/go.mod
cat > sub/main.go <<'EOF'
package main

func main() {}
EOF
git add . && commit -m baseline
cat > orphan.go <<'EOF'
package main

func Orphan() int { return 1 }
EOF
printf 'orphan.go\n' > .crap-gated
git add orphan.go .crap-gated
run
check "clean exit: the exempted orphan is never analysed" "$RC" "0"
check "reports no staged Go files once the exemption applies" \
      "$(printf '%s' "$OUT" | grep -c 'no staged Go files')" "1"

echo ""
if [ "$failures" -eq 0 ]; then
  echo "DEADCODE OK (9 cases)"
else
  echo "FAILED: $failures assertion(s)"
  exit 1
fi
