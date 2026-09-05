#!/usr/bin/env bash
# A file excluded from the build by a //go:build tag must produce a diagnosis, not
# a hint. The old message said "check GOFLAGS, and whether the code needs CGO",
# which is a dead end: it does not name the tag, and it does not say that setting
# the tag drops every test file constrained against it, so mutants those tests kill
# would survive spuriously. Naming both turns it into a decision.

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODULE="$SKILL_DIR/lib/mutation-check-go.sh"
LIB="$SKILL_DIR/lib"

command -v go  >/dev/null || { echo "SKIP: go not on PATH"; exit 0; }
command -v git >/dev/null || { echo "SKIP: git not on PATH"; exit 0; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

expect() {
  [ "$2" = "$3" ] || { echo "FAIL: $1"; echo "  want: [$2]"; echo "  got:  [$3]"; exit 1; }
  echo "  ok: $1"
}

git init -qb main
printf 'module example.com/bt\n\ngo 1.26\n' > go.mod
mkdir -p harness
cat > harness/stub_runner.go <<'EOF'
//go:build integration

package harness

func Stub(x int) int {
	return x * 2
}
EOF
for n in a b c; do
  cat > "unit_${n}_test.go" <<EOF
//go:build !integration

package bt

import "testing"

func Test${n}(t *testing.T) { _ = 1 }
EOF
done
cat > plain_test.go <<'EOF'
package bt

import "testing"

func TestPlain(t *testing.T) { _ = 1 }
EOF
printf 'package bt\n\nfunc Keep() int { return 1 }\n' > keep.go
git add -A
GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=commit.gpgsign GIT_CONFIG_VALUE_0=false \
  git commit -qm baseline

echo "--- unit: the required tag is read from the //go:build line ---"
expect "positive tag extracted" "integration" \
  "$(python3 "$LIB/buildtag_diagnosis.py" tags harness/stub_runner.go)"
printf '//go:build integration && !windows\n\npackage x\n' > /tmp/bt-multi.go
expect "negated terms are not reported as required" "integration" \
  "$(python3 "$LIB/buildtag_diagnosis.py" tags /tmp/bt-multi.go)"
printf '// +build legacy\n\npackage x\n' > /tmp/bt-legacy.go
expect "legacy +build syntax read too" "legacy" \
  "$(python3 "$LIB/buildtag_diagnosis.py" tags /tmp/bt-legacy.go)"
printf 'package x\n' > /tmp/bt-none.go
expect "no constraint yields nothing" "" \
  "$(python3 "$LIB/buildtag_diagnosis.py" tags /tmp/bt-none.go)"

echo "--- unit: test files constrained against the tag are counted ---"
expect "three contradicting test files" "3" \
  "$(python3 "$LIB/buildtag_diagnosis.py" conflicts . integration)"
expect "a tag nothing negates counts zero" "0" \
  "$(python3 "$LIB/buildtag_diagnosis.py" conflicts . nosuchtag)"

echo "--- e2e: the module's refusal names the tag and the collateral ---"
RC=0
# Repo-relative with no leading ./, exactly as the parent's git diff --name-only
# produces it, so the reported path is the one a reader can paste.
OUT="$(MUTATION_BASE=main MUTATION_FILES=harness/stub_runner.go "$MODULE" 2>&1)" || RC=$?
echo "$OUT"
[ "$RC" -eq 4 ] || { echo "FAIL: expected exit 4, got $RC"; exit 1; }
echo "$OUT" | grep -q -- "-tags=integration" || { echo "FAIL: the required tag is not named"; exit 1; }
echo "$OUT" | grep -qE "^    harness/stub_runner\.go$" || { echo "FAIL: path not reported cleanly"; exit 1; }
echo "$OUT" | grep -qE "3 test file" || { echo "FAIL: the excluded test count is not reported"; exit 1; }
echo "$OUT" | grep -qi "spurious\|survive" || { echo "FAIL: the consequence of setting the tag is not stated"; exit 1; }
echo "$OUT" | grep -q "GOFLAGS, and whether the code needs CGO" && { echo "FAIL: still emitting the dead-end hint"; exit 1; }

echo "MUTATION GO BUILDTAGS OK"
