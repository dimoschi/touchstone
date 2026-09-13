#!/usr/bin/env bash
# Tests that .crap-gated's exempt patterns reach the mutation gate too.
#
# crap-check.sh and deadcode-check.sh both narrow their own selection by the
# marker's patterns. mutation-check.sh did not, which deadlocked a repo carrying
# both markers: a path exempted precisely because it cannot be measured was
# still selected, so a full run recorded nothing for it, and --verify then found
# it unscored and denied `gh pr ready` with a remedy (re-run the full check)
# that could never go green.
#
# Needs only git, bash and python3: every assertion here is about which paths
# get selected, which is decided before any mutator runs.

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MUTATION="$SKILL_DIR/mutation-check.sh"
failures=0

check() {
  local label="$1" want="$2" got="$3"
  if [ "$got" = "$want" ]; then
    printf '  ok:   %-52s %s\n' "$label" "$got"
  else
    printf '  FAIL: %-52s got %s want %s\n' "$label" "$got" "$want"
    failures=$((failures + 1))
  fi
}

# 5 is --verify's "ledger is missing or stale" refusal, 0 is a clean pass.
# Anything else is a real failure and must not read as either.
verify_verdict() {
  "$MUTATION" --verify >/dev/null 2>&1
  case $? in
    0) echo PASS ;;
    5) echo REFUSE ;;
    *) echo OTHER ;;
  esac
}

new_repo() {
  REPO="$(mktemp -d)"
  cd "$REPO" || exit 1
  git init -q -b main .
  git config user.email t@t
  git config user.name t
  git config commit.gpgsign false
  # The developer's own global ignore file often lists .crap-gated, which would
  # keep the marker this test writes out of the scratch repo's commits.
  git config core.excludesFile /dev/null
  printf 'module example.com/t\n\ngo 1.26\n' > go.mod
  echo 'package main' > main.go
  git add -A
  git -c commit.gpgsign=false commit -q -m base
  git switch -q -c feat
}

commit() { git add -A; git -c commit.gpgsign=false commit -q -m "$1"; }

cleanup() { cd /; [ -n "${REPO:-}" ] && rm -rf "$REPO"; }
trap cleanup EXIT

go_file() {
  mkdir -p "$(dirname "$1")"
  cat > "$1" <<'EOF'
package main

func Scratch(x int) int {
	if x > 1 {
		return x
	}
	return 0
}
EOF
}

echo "an unmeasured Go file blocks --verify when nothing exempts it"
new_repo
go_file tools/scratch.go
commit "add scratch"
check "unexempted, never measured"   REFUSE "$(verify_verdict)"

echo "the marker's exempt patterns drop it from --verify's selection"
printf 'tools/scratch.go\n' > .crap-gated
commit "exempt the scratch helper"
check "exempted by exact path"       PASS   "$(verify_verdict)"

echo "a directory pattern works the same way"
go_file gen/generated.go
printf 'gen/**\n' >> .crap-gated
commit "exempt the generated tree"
check "exempted by gen/** glob"      PASS   "$(verify_verdict)"

echo "the exemption is not repo-wide"
go_file internal/real.go
commit "add a measured file"
check "a non-exempted file still blocks" REFUSE "$(verify_verdict)"

echo "a full run does not select an exempted path either"
# Without this the run would hand the exempted file to mutation-check-go.sh and
# fail on the missing toolchain, rather than reporting nothing to measure.
git rm -q internal/real.go; commit "drop the measured file"
OUT="$("$MUTATION" 2>&1)"; RC=$?
check "full run exits clean"         "0" "$RC"
check "full run selects no sources"  "1" \
      "$(printf '%s\n' "$OUT" | grep -c 'no changed source files')"

echo ""
if [ "$failures" -eq 0 ]; then
  echo "MUTATION EXEMPT OK"
else
  echo "FAILED: $failures assertion(s)"
  exit 1
fi
