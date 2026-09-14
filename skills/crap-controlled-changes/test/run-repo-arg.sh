#!/usr/bin/env bash
# Tests the optional leading <absolute-repo-path> argument shared by
# crap-check.sh, mutation-check.sh and deadcode-check.sh (lib/repo-arg.sh):
# a gate given one measures that repository and never consults the process
# cwd, prints the resolved repo and branch as its first line on every code
# path, and refuses a bad path with exit 2 instead of falling back to the
# cwd repo. Needs only git, bash and python3: no gate here mutates anything,
# so no language toolchain is required to prove the argument is honoured.

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CRAP="$SKILL_DIR/crap-check.sh"
MUTATION="$SKILL_DIR/mutation-check.sh"
DEADCODE="$SKILL_DIR/deadcode-check.sh"

command -v git >/dev/null || { echo "SKIP: git not on PATH"; exit 0; }

# Resolved with pwd -P: macOS's mktemp returns a path under /tmp, a symlink
# to /private/tmp, and `git rev-parse --show-toplevel` always prints the
# resolved form. Comparing against the raw path would fail every announcement
# assertion below on macOS for a reason that has nothing to do with this test.
WORK="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
failures=0

commit() {
  GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=commit.gpgsign GIT_CONFIG_VALUE_0=false \
    git commit -q "$@"
}

check() {
  if [ "$2" = "$3" ]; then
    echo "  ok:   $1"
  else
    echo "  FAIL: $1 (got '$2', want '$3')"
    failures=$((failures + 1))
  fi
}

check_contains() {
  if printf '%s' "$2" | grep -qF -- "$3"; then
    echo "  ok:   $1"
  else
    echo "  FAIL: $1 (did not find '$3' in output)"
    printf '%s\n' "$2" | sed 's/^/    | /'
    failures=$((failures + 1))
  fi
}

# run_from <cwd> <script> [args...]: runs the gate as if invoked from a
# different repo's cwd, the failure mode this argument exists to close.
run_from() {
  local dir="$1"
  shift
  RC=0
  OUT="$(cd "$dir" && "$@" 2>&1)" || RC=$?
}

# MAIN: a repo with no Go/PHP/Python source, so its gate runs never touch a
# language module or need a toolchain.
MAIN="$WORK/main"
mkdir -p "$MAIN"
git init -qb main "$MAIN"
echo "# readme" > "$MAIN/README.md"
git -C "$MAIN" add README.md
(cd "$MAIN" && commit -m baseline)

# WT: a linked worktree of MAIN, on its own branch with a real Go source
# file, so it can be marked scored without running any tool.
git -C "$MAIN" worktree add -q -b feature "$WORK/wt" >/dev/null
WT="$WORK/wt"
printf 'module example.com/repoarg\n\ngo 1.26\n' > "$WT/go.mod"
cat > "$WT/calc.go" <<'EOF'
package calc

func Double(x int) int {
	return x * 2
}
EOF
git -C "$WT" add go.mod calc.go
(cd "$WT" && commit -m "feat: add calc")

# OTHER: an unrelated repo on a third branch. Every "explicit path" case
# below runs from here, so a gate that silently fell back to the cwd would
# report OTHER's root and branch instead of the one it was told to measure.
OTHER="$WORK/other"
mkdir -p "$OTHER"
git init -qb other-branch "$OTHER"

NOTGIT="$WORK/notgit"
mkdir -p "$NOTGIT"

echo "=== no leading path: cwd resolution is unchanged ==="
run_from "$MAIN" "$CRAP"
check "crap-check exit 0"        "$RC" "0"
check_contains "crap-check announces MAIN/main" "$OUT" "crap-check: repo $MAIN branch main"
check_contains "crap-check: nothing staged" "$OUT" "no staged source files in supported languages"

run_from "$MAIN" "$MUTATION"
check "mutation-check exit 0"    "$RC" "0"
check_contains "mutation-check announces MAIN/main" "$OUT" "mutation-check: repo $MAIN branch main"

run_from "$MAIN" "$DEADCODE"
check "deadcode-check exit 0"    "$RC" "0"
check_contains "deadcode-check announces MAIN/main" "$OUT" "deadcode-check: repo $MAIN branch main"
check_contains "deadcode-check: nothing staged" "$OUT" "no staged Go files"

echo "=== explicit leading path: the target repo is measured, never the cwd ==="
run_from "$OTHER" "$CRAP" "$MAIN"
check "crap-check exit 0 from elsewhere"     "$RC" "0"
check_contains "crap-check announces MAIN, not OTHER" "$OUT" "crap-check: repo $MAIN branch main"

run_from "$OTHER" "$DEADCODE" "$MAIN"
check "deadcode-check exit 0 from elsewhere" "$RC" "0"
check_contains "deadcode-check announces MAIN, not OTHER" "$OUT" "deadcode-check: repo $MAIN branch main"

echo "=== ticket-43: cwd on one branch, explicit path a worktree on another ==="
run_from "$OTHER" "$CRAP" "$WT" --mark-scored
check "crap-check --mark-scored exit 0"      "$RC" "0"
check_contains "announces the worktree's own root and branch, not OTHER's" "$OUT" \
  "crap-check: repo $WT branch feature"
check_contains "marked calc.go as scored without measuring it" "$OUT" \
  "recorded the branch's current source as scored WITHOUT measuring it"
check_contains "the common ledger recorded the worktree's branch" \
  "$(cat "$MAIN/.git/crap-check-scored.json" 2>/dev/null)" '"feature"'

run_from "$OTHER" "$MUTATION" "$WT" --verify
check "mutation-check --verify exit 5 (never recorded)" "$RC" "5"
check_contains "announces the worktree's own root and branch" "$OUT" \
  "mutation-check: repo $WT branch feature"

echo "=== a bad leading path refuses with exit 2, never falls back to the cwd ==="
run_from "$OTHER" "$CRAP" "/nonexistent/repo-arg-test-76"
check "nonexistent directory exit 2" "$RC" "2"
check_contains "names the missing path" "$OUT" "no such directory: /nonexistent/repo-arg-test-76"

run_from "$OTHER" "$MUTATION" "$NOTGIT"
check "not-a-repo directory exit 2"  "$RC" "2"
check_contains "names the non-repo path" "$OUT" "not a git repository: $NOTGIT"

run_from "$OTHER" "$DEADCODE" "relative/path/x"
check "relative path refused, exit 2" "$RC" "2"
check_contains "says the path must be absolute" "$OUT" \
  "repo path must be absolute, got 'relative/path/x'"

echo "=== a subdirectory or worktree path resolves to its own toplevel ==="
mkdir -p "$MAIN/sub"
run_from "$OTHER" "$CRAP" "$MAIN/sub"
check "a subdirectory resolves to the repo root" "$RC" "0"
check_contains "announces MAIN's toplevel, not the subdirectory" "$OUT" \
  "crap-check: repo $MAIN branch main"

echo "=== flags still parse after a leading path ==="
run_from "$OTHER" "$CRAP" "$WT" --accept 'bogus-function-id'
check "crap-check --accept reaches next_action.py" "$RC" "2"
check_contains "not a path-parsing error" "$OUT" \
  "no recorded state for 'bogus-function-id'"

run_from "$OTHER" "$DEADCODE" "$WT" --revoke 'calc.go|Bogus'
check "deadcode-check --revoke reaches deadcode_accepted.py" "$RC" "1"
check_contains "not a path-parsing error" "$OUT" "nothing to revoke"

run_from "$OTHER" "$MUTATION" "$MAIN" --full
check "mutation-check --full parses and runs (nothing to measure)" "$RC" "0"
check_contains "the --full flag was honoured, not read as garbage" "$OUT" \
  "no changed source files vs main"

run_from "$OTHER" "$MUTATION" "$MAIN" --bogus
check "mutation-check still refuses an unknown option" "$RC" "2"
check_contains "unknown option, not a path error" "$OUT" "unknown option --bogus"

echo ""
if [ "$failures" -eq 0 ]; then
  echo "REPO ARG OK"
else
  echo "FAILED: $failures assertion(s)"
  exit 1
fi
