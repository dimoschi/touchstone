#!/usr/bin/env bash
# repo-lock.sh: serialise gate runs that take their baseline by stashing.
# Sourced by the per-language modules; not executable alone.
#
# The stash stack belongs to the repository, not the worktree: `git rev-parse
# --git-common-dir` is the same path from every linked worktree. Two concurrent
# baseline runs therefore push onto one stack and pop each other's tickets,
# swapping staged changes between worktrees. The Go module avoids this entirely
# by measuring its baseline in a throwaway worktree; php and python cannot,
# because they run their suites in-tree and need gitignored vendor/ and .venv/,
# so they serialise on this lock instead.
#
# The lock is a directory, because mkdir is atomic across processes. It holds the
# owner's pid so a run killed mid-stash does not wedge the repo forever.
#
# CRAP_LOCK_WAIT overrides the seconds to wait before giving up (default 900).

CRAP_LOCK_DIR=""

acquire_repo_lock() {
  local label="$1" waited=0 owner common
  # --git-common-dir answers ".git" in the main worktree but an absolute, fully
  # resolved path in a linked one. Canonicalise both to the physical path so the
  # two forms are the same string: on macOS the difference is /var vs
  # /private/var, which locks the same directory but reads like two locks.
  common="$(git rev-parse --git-common-dir)"
  common="$(cd "$common" 2>/dev/null && pwd -P)" || {
    echo "crap-check[$label]: cannot resolve the git common dir for locking" >&2
    exit 2
  }
  CRAP_LOCK_DIR="$common/crap-check-stash.lock"
  while ! mkdir "$CRAP_LOCK_DIR" 2>/dev/null; do
    owner="$(cat "$CRAP_LOCK_DIR/pid" 2>/dev/null || true)"
    if [ -n "$owner" ] && [ "$owner" -eq "$owner" ] 2>/dev/null \
       && ! kill -0 "$owner" 2>/dev/null; then
      echo "crap-check[$label]: clearing a baseline lock left by dead pid $owner" >&2
      rm -rf "$CRAP_LOCK_DIR"
      continue
    fi
    if [ "$waited" -ge "${CRAP_LOCK_WAIT:-900}" ]; then
      {
        echo "crap-check[$label]: gave up waiting for the baseline lock after ${waited}s."
        echo "  Holder: pid ${owner:-unknown}. The $label baseline stashes, and the stash"
        echo "  is shared by every worktree of this repo, so two runs must not overlap."
        echo "  Wait for the other gate run, or if pid ${owner:-?} is gone, remove:"
        echo "    $CRAP_LOCK_DIR"
      } >&2
      CRAP_LOCK_DIR=""
      exit 2
    fi
    if [ "$waited" -eq 0 ]; then
      echo "crap-check[$label]: another gate run holds the baseline lock; waiting..." >&2
    fi
    sleep 1
    waited=$((waited + 1))
  done
  echo "$$" > "$CRAP_LOCK_DIR/pid"
}

# Release only after the stash has been popped: the lock is what guarantees the
# pop takes back this run's own changes.
release_repo_lock() {
  [ -n "$CRAP_LOCK_DIR" ] || return 0
  rm -rf "$CRAP_LOCK_DIR"
  CRAP_LOCK_DIR=""
}
