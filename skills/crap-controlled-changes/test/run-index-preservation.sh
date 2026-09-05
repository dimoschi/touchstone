#!/usr/bin/env bash
# run-index-preservation.sh: regression test for the stash/restore mechanic
# shared identically by all three crap-check-<lang> modules.
#
# Running a module must leave the git index byte-for-byte unchanged: files
# staged before stay staged (including files with a MIX of staged and unstaged
# hunks), unstaged stay unstaged, and untracked stay untracked. A plain
# `git stash pop` collapses that partition (everything comes back unstaged),
# which silently drops staged edits from the user's next commit; this test
# pins the correct behavior.
#
# The external toolchains (go, phpunit, coverage/radon) are stubbed so the test
# is hermetic and exercises only the stash push -> baseline -> restore path,
# which is where the corruption lived. No real Go/PHP/Python tooling is needed.

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$SKILL_DIR/lib"

command -v git     >/dev/null || { echo "SKIP: git not on PATH"; exit 0; }
command -v python3 >/dev/null || { echo "SKIP: python3 not on PATH"; exit 0; }

STUBS="$(mktemp -d)"
WORKROOT="$(mktemp -d)"
trap 'rm -rf "$STUBS" "$WORKROOT"' EXIT

# Stubs let each module run past its tool-availability guards and reach the
# stash/restore path without a real toolchain; measured scores are irrelevant.
cat > "$STUBS/go" <<'SH'
#!/bin/sh
exit 0
SH
cat > "$STUBS/phpunit" <<'SH'
#!/bin/sh
exit 0
SH
cat > "$STUBS/coverage" <<'SH'
#!/bin/sh
case "$1" in
  --version) echo "coverage stub"; exit 0 ;;
  json) shift; while [ $# -gt 0 ]; do [ "$1" = "-o" ] && printf '{}' > "$2"; shift; done; exit 0 ;;
  *) exit 0 ;;
esac
SH
chmod +x "$STUBS"/*

# Patch bodies (not just names) are captured so partial-staging collapse shows up.
snapshot() {
  echo "== staged names ==";    git diff --cached --name-only | LC_ALL=C sort
  echo "== unstaged names ==";  git diff --name-only | LC_ALL=C sort
  echo "== untracked names =="; git ls-files --others --exclude-standard | LC_ALL=C sort
  echo "== staged patch ==";    git diff --cached
  echo "== unstaged patch ==";  git diff
}

setup_repo() {
  local dir="$1" ext="$2"
  git init -q "$dir"
  (
    cd "$dir"
    git config commit.gpgsign false
    git config user.email t@t
    git config user.name t
    seq 1 12 > "partial.$ext"
    printf 'orig\n' > "staged_full.$ext"
    printf 'orig\n' > "unstaged_full.$ext"
    git add .
    git commit -q -m baseline

    printf 'CHANGED\n' > "staged_full.$ext"; git add "staged_full.$ext"
    printf 'CHANGED\n' > "unstaged_full.$ext"
    printf 'new\n' > "untracked.$ext"
    # Change line 1 and line 12: two disjoint hunks (>3 context lines apart).
    { echo TOP; seq 2 11; echo BOTTOM; } > "partial.$ext"
    git diff "partial.$ext" > full.patch
    # Stage only the first hunk (through the first @@ block), leaving the second.
    awk 'BEGIN{h=0} /^@@/{h++} h<=1{print}' full.patch > hunk1.patch
    git apply --cached hunk1.patch
    rm -f full.patch hunk1.patch
  )
}

fail=0
check() {
  local lang="$1"; shift
  local ext="$1"; shift
  local module="$1"; shift
  # Remaining args (if any) are an `env VAR=... ` prefix for the module.
  local dir="$WORKROOT/$lang"
  setup_repo "$dir" "$ext"
  cd "$dir"
  local before after
  before="$(snapshot)"
  PATH="$STUBS:$PATH" \
    CRAP_FILES="$(printf 'staged_full.%s\npartial.%s' "$ext" "$ext")" \
    "$@" "$module" >/dev/null 2>&1 || true
  after="$(snapshot)"
  cd /
  if [ "$before" = "$after" ]; then
    echo "PASS [$lang]: index partition preserved"
  else
    echo "FAIL [$lang]: index partition changed after running module"
    diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") || true
    fail=1
  fi
}

check go     go  "$LIB/crap-check-go.sh"
check php    php "$LIB/crap-check-php.sh"     env PHPUNIT_BIN="$STUBS/phpunit"
check python py  "$LIB/crap-check-python.sh"  env CRAP_PY_RADON=false CRAP_PY_COMPLEXIPY=false

if [ "$fail" -eq 0 ]; then
  echo "INDEX PRESERVATION OK"
else
  echo "INDEX PRESERVATION FAILED"
  exit 1
fi
