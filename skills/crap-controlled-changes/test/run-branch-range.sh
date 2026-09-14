#!/usr/bin/env bash
# A branch with no commits of its own must not inherit the base's last commit.
#
# The branch range is empty in two unrelated situations, and treating them the
# same blocked ordinary work. On the base branch it means "the commit you just
# made is the thing to judge", and falling back to HEAD~1 is right. On a fresh
# branch it means "this branch has written nothing yet", and falling back
# charges it whatever the base merged last. Since crap-commit.sh gates before
# committing, every branch is in the second state for its first commit, so any
# first commit staging no Go, PHP or Python was refused with exit 5.
#
# Squash merges are why the existing HEAD^2 exemption does not cover it: a
# squash lands the branch's work as an ordinary one-parent commit.
#
# Needs only git, bash and python3: nothing is staged in any case here, so no
# language module ever runs.

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SKILL_DIR/crap-check.sh"

command -v git >/dev/null || { echo "SKIP: git not on PATH"; exit 0; }

WORK="$(cd "$(mktemp -d)" && pwd -P)"
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
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=commit.gpgsign GIT_CONFIG_VALUE_0=false \
    git commit -q "$@"
}

run() {
  RC=0
  OUT="$("$SCRIPT" "$@" 2>&1)" || RC=$?
}

REPO="$WORK/repo"
mkdir -p "$REPO"
git init -qb main "$REPO"
cd "$REPO"
echo "# readme" > README.md
git add README.md
commit -m baseline

# Stands in for a squash merge: one ordinary commit landing scorable source
# that no run on this branch ever scored.
cat > app.py <<'EOF'
def add(a, b):
    return a + b
EOF
git add app.py
commit -m "squash: land some python"

echo "=== on the base branch, the fallback still judges the last commit ==="
run "$REPO"
check "crap-check exits 5 on main (HEAD carries unscored source)" "$RC" "5"

echo "=== a fresh branch does not inherit that commit ==="
git checkout -q -b feat/docs-only
run "$REPO"
check "crap-check exits 0 on a branch with no commits of its own" "$RC" "0"
check "it does not name the base's file" \
  "$(printf '%s' "$OUT" | grep -c 'app.py')" "0"

echo "=== once the branch commits scorable source, it owns it again ==="
cat > other.py <<'EOF'
def mul(a, b):
    return a * b
EOF
git add other.py
commit -m "feat: add other"
run "$REPO"
check "crap-check exits 5 for the branch's own unscored source" "$RC" "5"

echo ""
if [ "$failures" -eq 0 ]; then
  echo "BRANCH RANGE OK"
  exit 0
fi
echo "FAILED: $failures assertion(s)"
exit 1
