#!/usr/bin/env bash
# Unit test for the fixture-bootstrap guard shared (by copy) between run.sh and
# run-go-unmeasurable.sh: the condition that decides whether the fixture needs
# `git init` plus a baseline commit before the suite resets it.
#
# The guard line is extracted straight from each script via grep, so this
# exercises the code that actually ships, not a hand-copied duplicate that
# could silently drift out of sync with a later edit.

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# An enclosing repo standing in for the touchstone checkout: if the guard
# ascends past an absent or invalid fixture .git, this is what it lands on.
OUTER="$WORK/outer"
mkdir -p "$OUTER/nested"
(cd "$OUTER" && git init -q && \
 git -c commit.gpgsign=false -c user.email=t@t -c user.name=t commit -q --allow-empty -m base)

FIXTURE_DIR="$OUTER/nested/fixture"

failures=0
check() {
  if [ "$2" = "$3" ]; then
    echo "  ok: $1"
  else
    echo "  FAIL: $1 (got '$2', want '$3')"
    failures=$((failures + 1))
  fi
}

# Evaluate a script's live guard line against the current $FIXTURE_DIR state.
guard_says() {
  local script="$1" line
  line="$(grep -E '^if .*git-dir' "$SKILL_DIR/test/$script")"
  [ -n "$line" ] || { echo "NO_GUARD_LINE"; return; }
  FIXTURE_DIR="$FIXTURE_DIR" bash -c "$line echo NEEDS_BOOTSTRAP; else echo SKIP; fi"
}

for script in run.sh run-go-unmeasurable.sh; do
  echo "== $script =="

  rm -rf "$FIXTURE_DIR"; mkdir -p "$FIXTURE_DIR"
  check "$script: no .git at all" "$(guard_says "$script")" "NEEDS_BOOTSTRAP"

  rm -rf "$FIXTURE_DIR"; mkdir -p "$FIXTURE_DIR/.git"
  check "$script: .git exists but is not a valid gitdir" "$(guard_says "$script")" "NEEDS_BOOTSTRAP"

  rm -rf "$FIXTURE_DIR"; mkdir -p "$FIXTURE_DIR"; (cd "$FIXTURE_DIR" && git init -q)
  check "$script: .git valid but zero commits" "$(guard_says "$script")" "NEEDS_BOOTSTRAP"

  rm -rf "$FIXTURE_DIR"; mkdir -p "$FIXTURE_DIR"
  (cd "$FIXTURE_DIR" && git init -q && \
   git -c commit.gpgsign=false -c user.email=t@t -c user.name=t commit -q --allow-empty -m base)
  check "$script: .git valid with a baseline commit" "$(guard_says "$script")" "SKIP"
done

echo ""
if [ "$failures" -eq 0 ]; then
  echo "FIXTURE BOOTSTRAP GUARD OK (8 cases)"
else
  echo "FAILED: $failures assertion(s)"
  exit 1
fi
