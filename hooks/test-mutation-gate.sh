#!/usr/bin/env bash
# Tests mutation-pr-gate.py: gh pr create/ready, a merge onto a base branch,
# and a push landing on one all verify the mutation ledger; a non-trigger
# command does not; a repo without .mutation-gated is never gated.
# Follows test-crap-commit-gate.sh's expect() shape.
#
# Scope is the .mutation-gated marker at the repo root, so the fixture is an
# ordinary mktemp directory. It used to live under the real ~/repos because the
# gate took its scope from a path prefix; that both polluted the workspace and
# tied the suite to one machine's directory layout.

set -uo pipefail

HOOKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$HOOKS_DIR/mutation-pr-gate.py"
# The plugin's own copy. This pointed at $HOME/.claude for a while, which meant
# the suite exercised whatever the developer had installed rather than the code
# in this repo, and passed even when the shipped copy was broken.
SCORED_LEDGER="$HOOKS_DIR/../skills/crap-controlled-changes/lib/scored_ledger.py"
failures=0

command -v git >/dev/null || { echo "SKIP: git not on PATH"; exit 0; }

commit() {
  GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=commit.gpgsign GIT_CONFIG_VALUE_0=false \
    git commit -q "$@"
}

# want: BLOCK | ALLOW
expect() {
  local label="$1" want="$2" cwd="$3" cmd="$4" rc=0 out got
  out="$(python3 -c 'import json, sys; print(json.dumps({"cwd": sys.argv[1], "tool_input": {"command": sys.argv[2]}}))' "$cwd" "$cmd" \
        | python3 "$GATE" 2>&1)" || rc=$?
  if [ "$rc" -eq 0 ]; then
    got=ALLOW
  elif [ "$rc" -eq 2 ]; then
    got=BLOCK
  else
    got="OTHER($rc)"
  fi
  if [ "$got" = "$want" ]; then
    printf '  ok:   %-52s %s\n' "$label" "$got"
  else
    printf '  FAIL: %-52s got %s want %s\n' "$label" "$got" "$want"
    printf '%s\n' "$out" | sed 's/^/        /'
    failures=$((failures + 1))
  fi
}

record_branch() {
  local branch="$1" blob
  blob="$(git rev-parse "$branch:x.go")"
  printf '%s %s\n' x.go "$blob" \
    | python3 "$SCORED_LEDGER" record "$WORK/.git/mutation-ledger.json" "$branch" >/dev/null
}

WORK="$(mktemp -d)"
# A directory that is not a git repo, standing in for the session cwd that
# exposed the push-path bug.
NONREPO="$(mktemp -d)"
trap 'git -C "$WORK" worktree remove --force "$WORK-wt" >/dev/null 2>&1; rm -rf "$WORK" "$WORK-wt" "$NONREPO"' EXIT
cd "$WORK"

git init -qb main
printf 'module example.com/x\n\ngo 1.26\n' > go.mod
echo 'package x' > x.go
git add .
commit -m baseline

git checkout -qb feature
cat >> x.go <<'EOF'

func Y() int { return 1 }
EOF
git add x.go
commit -m "feat: add Y"

git checkout -qb other main
cat >> x.go <<'EOF'

func Z() int { return 2 }
EOF
git add x.go
commit -m "feat: add Z, never recorded"

git checkout -q main

echo "=== a repo without the marker is never gated, even with a red ledger ==="
git checkout -q feature
expect "gh pr create, unrecorded, no marker -> allowed" ALLOW "$WORK" "gh pr create --title x"

echo "=== .mutation-gated opts the repo in ==="
touch "$WORK/.mutation-gated"
expect "gh pr create, unrecorded, marker present -> blocked" BLOCK "$WORK" "gh pr create --title x"
record_branch feature
expect "gh pr ready, now recorded -> allowed" ALLOW "$WORK" "gh pr ready"

echo "=== git merge <branch> while HEAD is a base branch ==="
git checkout -q main
expect "merge unrecorded branch -> blocked" BLOCK "$WORK" "git merge other"
expect "merge recorded feature -> allowed"  ALLOW "$WORK" "git merge feature"

echo "=== git push landing on a base branch ==="
expect "plain push while HEAD is main (empty diff) -> allowed" ALLOW "$WORK" "git push"
expect "push origin other:main, unrecorded source -> blocked"  BLOCK "$WORK" "git push origin other:main"
expect "push origin feature:main, recorded source -> allowed"  ALLOW "$WORK" "git push origin feature:main"
git checkout -q feature
expect "push origin feature (destination is not a base branch)" ALLOW "$WORK" "git push origin feature"

echo "=== the resolved repo must actually contain the ref being pushed ==="
# Regression: the refspec matched on command text alone, so from a cwd with no
# repo the gate ran mutation-check nowhere, read its exit 2 (setup problem) as a
# red ledger, and blocked a push it never evaluated. Merge already guards this.
expect "push refspec from a non-repo cwd -> allowed" ALLOW "$NONREPO" "git push -u origin main"

echo "=== a linked worktree resolves to the same repo root as its parent ==="
git worktree add -q "$WORK-wt" feature 2>/dev/null
expect "worktree of a gated repo is gated"    ALLOW "$WORK-wt" "gh pr ready"
git checkout -q feature

echo "=== cd <repo> && git ... gates the repo cd names, not the session cwd ==="
expect "cd into gated repo, unrecorded source -> blocked" BLOCK "$NONREPO" "cd $WORK && git push origin other:main"
expect "cd into gated repo, recorded source -> allowed"   ALLOW "$NONREPO" "cd $WORK && git push origin feature:main"

echo "=== a draft PR is not a review request, but ready always is ==="
# On `other`, whose ledger was never recorded, so a gated command blocks and an
# exempt one does not. On `feature` every case would pass the ledger check and
# prove nothing about the exemption.
git checkout -q other
# Opening a draft is how work in progress is made visible; gating it would force
# the work to stay invisible until finished. `gh pr ready` is where review is
# asked for. The compound cases matter: an exemption keyed on "a draft create is
# present" let `gh pr create --draft; gh pr ready` through with no check at all.
expect "draft create, unrecorded -> allowed"       ALLOW "$WORK" "gh pr create --draft --title x"
expect "draft flag last -> allowed"                ALLOW "$WORK" "gh pr create --title x --draft"
expect "non-draft create, unrecorded -> blocked"   BLOCK "$WORK" "gh pr create --title x"
expect "draft then ready -> blocked"               BLOCK "$WORK" "gh pr create --draft --title x; gh pr ready 7"
expect "ready then draft -> blocked"               BLOCK "$WORK" "gh pr ready 7 && gh pr create --draft"
expect "--draft-mode is not --draft -> blocked"    BLOCK "$WORK" "gh pr create --draft-mode"

echo "=== a non-trigger command passes straight through ==="
expect "unrelated command" ALLOW "$WORK" "git status"

echo ""
if [ "$failures" -eq 0 ]; then
  echo "MUTATION GATE OK"
else
  echo "FAILED: $failures assertion(s)"
  exit 1
fi
