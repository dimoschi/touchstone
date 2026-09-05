#!/usr/bin/env bash
# Unit test for lib/repo-lock.sh: the guard that stops two stash-based gate runs
# (php, python) from popping each other's changes across linked worktrees.

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$SKILL_DIR/lib"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"
git init -q main-repo
cd main-repo

failures=0
check() {
  if [ "$2" = "$3" ]; then
    echo "  ok: $1"
  else
    echo "  FAIL: $1 (got '$2', want '$3')"
    failures=$((failures + 1))
  fi
}

. "$LIB/repo-lock.sh"
LOCK="$(git rev-parse --git-common-dir)/crap-check-stash.lock"

echo "case A: acquire creates the lock and records the owner pid"
acquire_repo_lock php
check "lock directory exists" "$([ -d "$LOCK" ] && echo yes)" "yes"
check "records our pid"       "$(cat "$LOCK/pid")" "$$"

echo "case B: release removes it"
release_repo_lock
check "lock directory gone" "$([ -d "$LOCK" ] || echo yes)" "yes"
check "release is idempotent" "$(release_repo_lock; echo $?)" "0"

echo "case C: a live holder makes a second run wait, then give up"
mkdir -p "$LOCK"
echo $$ > "$LOCK/pid"            # our own pid: definitely alive
rc=0
out="$(CRAP_LOCK_WAIT=1 bash -c '
  . '"$LIB"'/repo-lock.sh
  acquire_repo_lock python
' 2>&1)" || rc=$?
check "gives up rather than stealing" "$rc" "2"
check "names the holder" "$(printf '%s' "$out" | grep -c "Holder: pid $$")" "1"
check "explains the shared stash" \
      "$(printf '%s' "$out" | grep -c 'shared by every worktree')" "1"
check "lock survives the failed attempt" "$([ -d "$LOCK" ] && echo yes)" "yes"
rm -rf "$LOCK"

echo "case D: a dead holder's lock is cleared, not waited on"
mkdir -p "$LOCK"
# A pid that has certainly exited: spawn a trivial child and reap it.
( exit 0 ) & dead=$!; wait "$dead" 2>/dev/null
echo "$dead" > "$LOCK/pid"
rc=0
out="$(CRAP_LOCK_WAIT=1 bash -c '
  . '"$LIB"'/repo-lock.sh
  acquire_repo_lock php
  echo ACQUIRED
  release_repo_lock
' 2>&1)" || rc=$?
check "acquires despite the stale lock" "$rc" "0"
check "reports clearing it" "$(printf '%s' "$out" | grep -c 'clearing a baseline lock')" "1"
check "says ACQUIRED" "$(printf '%s' "$out" | grep -c ACQUIRED)" "1"

echo "case E: garbage in the pid file does not crash the wait"
mkdir -p "$LOCK"
printf 'not-a-pid\n' > "$LOCK/pid"
rc=0
CRAP_LOCK_WAIT=1 bash -c '
  . '"$LIB"'/repo-lock.sh
  acquire_repo_lock php
' >/dev/null 2>&1 || rc=$?
check "treats it as held and gives up cleanly" "$rc" "2"
rm -rf "$LOCK"

echo "case F: the lock is repo-global, shared by linked worktrees"
git -c commit.gpgsign=false -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
git worktree add -q --detach "$WORK/linked" HEAD
# Resolve through the function itself, from inside each worktree, so the test
# pins the path the modules actually lock on.
lock_from() {
  ( cd "$1" && . "$LIB/repo-lock.sh" && acquire_repo_lock t >/dev/null 2>&1
    printf '%s' "$CRAP_LOCK_DIR"; release_repo_lock )
}
main_seen="$(lock_from "$WORK/main-repo")"
linked_seen="$(lock_from "$WORK/linked")"
check "linked worktree locks the same path" \
      "$([ -n "$main_seen" ] && [ "$main_seen" = "$linked_seen" ] && echo yes)" "yes"

echo ""
if [ "$failures" -eq 0 ]; then
  echo "REPO LOCK OK (6 cases)"
else
  echo "FAILED: $failures assertion(s)"
  exit 1
fi
