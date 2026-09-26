#!/usr/bin/env bash
# Behavioural git premises (worktree cuts, merge-base, existing-branch
# lookup) against real scratch repos under $WORK. Split out of
# test-fix-loop-join.sh (gh-118); see harness.sh.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/harness.sh"

REPO="$WORK/scratch"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name test
git -C "$REPO" config commit.gpgsign false

echo "one" > "$REPO/changed.txt"
echo "one" > "$REPO/untouched.txt"
git -C "$REPO" add changed.txt untouched.txt
git -C "$REPO" commit -qm "recorded_at: both files exist"
RECORDED_AT="$(git -C "$REPO" rev-parse HEAD)"

echo "two" > "$REPO/changed.txt"
git -C "$REPO" add changed.txt
git -C "$REPO" commit -qm "a later round touches changed.txt only"

run_template() {
  local file="$1"
  # Same shape as the prompt, with <recorded_at> and <file> substituted.
  git -C "$REPO" log -p "$RECORDED_AT..HEAD" -- "$file"
}

check "a file with a commit in the range reports non-empty" \
  "$([ -n "$(run_template changed.txt)" ] && echo yes || echo no)" yes
check "a file with no commit in the range reports empty" \
  "$([ -n "$(run_template untouched.txt)" ] && echo yes || echo no)" no

echo ""
echo "== worktree phase: the default cut is unaffected by a dirty main checkout"
# Runs the exact command sequence the branch prompt now prescribes for the
# non-baseOverride cut (git fetch origin; git rev-parse --verify
# origin/<base>; git worktree add <path> -b <branch> origin/<base>) against a
# real remote and a real main checkout, proving the main tree's dirty state
# and its stale local base are both irrelevant to the cut.
ORIGIN="$WORK/wt-origin.git"
git init -q --bare "$ORIGIN"

MAIN="$WORK/wt-main"
git clone -q "$ORIGIN" "$MAIN"
git -C "$MAIN" config user.email test@example.com
git -C "$MAIN" config user.name test
git -C "$MAIN" config commit.gpgsign false

echo "base v1" > "$MAIN/tracked.txt"
git -C "$MAIN" add tracked.txt
git -C "$MAIN" commit -qm "initial commit on main"
git -C "$MAIN" push -q origin HEAD:main
LOCAL_BASE_SHA_BEFORE="$(git -C "$MAIN" rev-parse main)"

# A second clone advances the remote past what MAIN has fetched, so
# origin/main (once fetched) differs from MAIN's own stale local main.
OTHER_CLONE="$WORK/wt-other-clone"
git clone -q "$ORIGIN" "$OTHER_CLONE"
git -C "$OTHER_CLONE" config user.email test@example.com
git -C "$OTHER_CLONE" config user.name test
git -C "$OTHER_CLONE" config commit.gpgsign false
echo "base v2" > "$OTHER_CLONE/tracked.txt"
git -C "$OTHER_CLONE" add tracked.txt
git -C "$OTHER_CLONE" commit -qm "a commit MAIN has not fetched yet"
git -C "$OTHER_CLONE" push -q origin HEAD:main
REMOTE_HEAD_SHA="$(git -C "$OTHER_CLONE" rev-parse HEAD)"

# Dirty the main checkout: a modified tracked file, a staged new file, an
# untracked file.
echo "modified locally" > "$MAIN/tracked.txt"
echo "staged new file" > "$MAIN/staged.txt"
git -C "$MAIN" add staged.txt
echo "untracked" > "$MAIN/untracked.txt"

STATUS_BEFORE="$(git -C "$MAIN" status --porcelain)"
TRACKED_BEFORE="$(cat "$MAIN/tracked.txt")"
STAGED_BEFORE="$(cat "$MAIN/staged.txt")"
BRANCH_BEFORE="$(git -C "$MAIN" branch --show-current)"

WTPATH="$WORK/wt-new-worktree"
git -C "$MAIN" fetch -q origin
git -C "$MAIN" rev-parse --verify origin/main >/dev/null 2>&1
FETCH_VERIFY_STATUS=$?
git -C "$MAIN" worktree add -q "$WTPATH" -b feat/gh-999-test origin/main

check "the fetch and verify step succeeded" "$FETCH_VERIFY_STATUS" 0
check "git status --porcelain in the main checkout is unchanged" \
  "$(git -C "$MAIN" status --porcelain)" "$STATUS_BEFORE"
check "the modified tracked file's content is unchanged" \
  "$(cat "$MAIN/tracked.txt")" "$TRACKED_BEFORE"
check "the staged file's content is unchanged" \
  "$(cat "$MAIN/staged.txt")" "$STAGED_BEFORE"
check "the local base branch SHA is unchanged" \
  "$(git -C "$MAIN" rev-parse main)" "$LOCAL_BASE_SHA_BEFORE"
check "the main checkout is still on the same branch" \
  "$(git -C "$MAIN" branch --show-current)" "$BRANCH_BEFORE"
check "the new worktree's HEAD equals origin/main, not the stale local main" \
  "$(git -C "$WTPATH" rev-parse HEAD)" "$REMOTE_HEAD_SHA"
check "origin/main (fetched) actually differs from the stale local main" \
  "$([ "$REMOTE_HEAD_SHA" != "$LOCAL_BASE_SHA_BEFORE" ] && echo yes || echo no)" yes

echo ""
echo "== worktree phase: a missing origin/<base> ref fails the verify step"
git -C "$MAIN" rev-parse --verify origin/does-not-exist >/dev/null 2>&1
MISSING_REF_STATUS=$?
check "git rev-parse --verify on a missing remote ref exits non-zero" \
  "$([ "$MISSING_REF_STATUS" -ne 0 ] && echo yes || echo no)" yes

echo ""
echo "== implementer's merge-base rule: the origin candidate stays at the true fork point when the local base goes stale"
# Clone at A, a colleague pushes three commits straight to the remote, a
# branch is cut from origin/<base> and gets one commit of its own. The local
# <base> ref never moves, so merge-base against it alone reaches back through
# the colleague's three commits too.
TC_REMOTE="$WORK/tc-origin.git"
git init -q --bare "$TC_REMOTE"

TC_CLONE="$WORK/tc-clone"
git clone -q "$TC_REMOTE" "$TC_CLONE"
git -C "$TC_CLONE" config user.email test@example.com
git -C "$TC_CLONE" config user.name test
git -C "$TC_CLONE" config commit.gpgsign false

echo "a" > "$TC_CLONE/f.txt"
git -C "$TC_CLONE" add f.txt
git -C "$TC_CLONE" commit -qm "A: initial commit"
git -C "$TC_CLONE" push -q origin HEAD:main
LOCAL_MAIN_SHA="$(git -C "$TC_CLONE" rev-parse main)"

TC_COLLEAGUE="$WORK/tc-colleague"
git clone -q "$TC_REMOTE" "$TC_COLLEAGUE"
git -C "$TC_COLLEAGUE" config user.email test@example.com
git -C "$TC_COLLEAGUE" config user.name test
git -C "$TC_COLLEAGUE" config commit.gpgsign false
for n in 1 2 3; do
  echo "colleague $n" >> "$TC_COLLEAGUE/f.txt"
  git -C "$TC_COLLEAGUE" add f.txt
  git -C "$TC_COLLEAGUE" commit -qm "colleague commit $n"
done
git -C "$TC_COLLEAGUE" push -q origin HEAD:main
COLLEAGUE_HEAD_SHA="$(git -C "$TC_COLLEAGUE" rev-parse HEAD)"

git -C "$TC_CLONE" fetch -q origin
git -C "$TC_CLONE" checkout -q -b feat/tc-test origin/main
echo "own change" > "$TC_CLONE/g.txt"
git -C "$TC_CLONE" add g.txt
git -C "$TC_CLONE" commit -qm "run 1's own commit"

ORIGIN_MERGE_BASE="$(git -C "$TC_CLONE" merge-base HEAD origin/main)"
LOCAL_MERGE_BASE="$(git -C "$TC_CLONE" merge-base HEAD main)"
check "the origin candidate is the true fork point" "$ORIGIN_MERGE_BASE" "$COLLEAGUE_HEAD_SHA"
check "the local candidate is the stale pre-fetch main" "$LOCAL_MERGE_BASE" "$LOCAL_MAIN_SHA"

git -C "$TC_CLONE" merge-base --is-ancestor "$LOCAL_MERGE_BASE" "$ORIGIN_MERGE_BASE"
check "the origin candidate is a descendant of the local one, so the rule picks it" "$?" 0

ORIGIN_RANGE_COUNT="$(git -C "$TC_CLONE" rev-list --count "$ORIGIN_MERGE_BASE"..HEAD)"
LOCAL_RANGE_COUNT="$(git -C "$TC_CLONE" rev-list --count "$LOCAL_MERGE_BASE"..HEAD)"
check "the origin candidate reviews exactly this run's one commit" "$ORIGIN_RANGE_COUNT" 1
check "the stale local base alone would widen the range past it" \
  "$([ "$LOCAL_RANGE_COUNT" -gt "$ORIGIN_RANGE_COUNT" ] && echo yes || echo no)" yes

echo ""
echo "== premise: git reports a ticket's linked worktree while the main checkout sits on the base branch"
# Establishes the git facts the lookup rests on; it never runs the pipeline, so
# it cannot fail if the lookup regresses. Scenarios BI, BJ and BK cover that.
EXIST_ORIGIN="$WORK/exist-origin.git"
git init -q --bare "$EXIST_ORIGIN"

EXIST_MAIN="$WORK/exist-main"
git clone -q "$EXIST_ORIGIN" "$EXIST_MAIN"
git -C "$EXIST_MAIN" config user.email test@example.com
git -C "$EXIST_MAIN" config user.name test
git -C "$EXIST_MAIN" config commit.gpgsign false

echo "base" > "$EXIST_MAIN/tracked.txt"
git -C "$EXIST_MAIN" add tracked.txt
git -C "$EXIST_MAIN" commit -qm "initial commit on main"
git -C "$EXIST_MAIN" push -q origin HEAD:main

EXIST_WT="$WORK/exist-worktree-gh-21"
git -C "$EXIST_MAIN" worktree add -q "$EXIST_WT" -b feat/gh-21-retry-path origin/main
# git's own porcelain output reports the canonical path (symlinks resolved),
# which on macOS differs from $EXIST_WT under /var; resolve the same way
# before comparing rather than string-matching the pre-resolution form.
EXIST_WT_CANON="$(cd "$EXIST_WT" && pwd -P)"

MATCHED_PATH="$(git -C "$EXIST_MAIN" worktree list --porcelain | awk '
  /^worktree / { path = $2 }
  /^branch refs\/heads\/feat\/gh-21-retry-path$/ { print path }
')"

check "the git worktree list --porcelain match resolves to the linked worktree path" \
  "$MATCHED_PATH" "$EXIST_WT_CANON"
check "git branch --show-current in the main checkout reports main, not the ticket branch" \
  "$(git -C "$EXIST_MAIN" branch --show-current)" "main"

finish
