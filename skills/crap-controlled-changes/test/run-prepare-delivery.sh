#!/usr/bin/env bash
# prepare-delivery.sh end to end: what it refuses before python runs, that it
# hands the shipped plugin manifest to lib/prepare_delivery.py, and that a
# refusal keeps python's exit code and JSON. The lookups themselves are covered
# by test/unit/test_prepare_delivery.py.

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SKILL_DIR/prepare-delivery.sh"
MANIFEST_VERSION="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["version"])' "$SKILL_DIR/../../.claude-plugin/plugin.json")"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

failures=0
check() {
  local label="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then
    echo "  ok:   $label ($got)"
  else
    echo "  FAIL: $label (got $got, want $want)"
    failures=$((failures + 1))
  fi
}

g() { git -c core.excludesFile=/dev/null -c commit.gpgsign=false -c user.name=t -c user.email=t@t "$@"; }
g init -q -b main "$WORK/seed"
printf '## Checks\n```\ntrue\n```\n' > "$WORK/seed/AGENTS.md"
g -C "$WORK/seed" add -A
g -C "$WORK/seed" commit -q -m seed
git clone -q --bare "$WORK/seed" "$WORK/origin.git"
git clone -q "$WORK/origin.git" "$WORK/repo"
REPO="$(cd "$WORK/repo" && pwd -P)"

field() { python3 -c 'import json, sys; print(json.loads(sys.stdin.read())[sys.argv[1]])' "$1"; }

run() {
  OUT="$("$SCRIPT" "$@" 2>"$WORK/err.log")"
  RC=$?
}

echo "== a fresh run prints the prepared worktree with the shipped plugin version"
run "$REPO" --ticket 7 --type feat --slug end-to-end
check "exit status" "$RC" 0
check "worktree" "$(printf '%s' "$OUT" | field worktree)" "$REPO/.claude/worktrees/gh-7-end-to-end"
check "plugin version is the shipped manifest's" \
  "$(printf '%s' "$OUT" | python3 -c 'import json, sys; print(json.load(sys.stdin)["plugin"]["version"])')" \
  "$MANIFEST_VERSION"
check "stderr is empty" "$(wc -c < "$WORK/err.log" | tr -d ' ')" 0

echo "== a refusal keeps python's exit code and JSON"
run "$REPO" --ticket 7 --type feat --slug end-to-end
check "exit status" "$RC" 3
check "error" "$(printf '%s' "$OUT" | field error)" "local-branch-exists"

echo "== a relative repo path is refused before python runs"
run repo --ticket 7 --type feat --slug x
check "exit status" "$RC" 2
check "error" "$(printf '%s' "$OUT" | field error)" "bad-args"

echo "== no arguments at all print usage as a refusal"
run
check "exit status" "$RC" 2
check "reason names the usage" "$(printf '%s' "$OUT" | field reason | cut -c1-25)" "usage: prepare-delivery.s"

echo "== a directory that is not a repository is refused"
mkdir "$WORK/plain"
run "$WORK/plain" --ticket 7 --type feat --slug x
check "exit status" "$RC" 2
check "reason names the path" "$(printf '%s' "$OUT" | field reason | grep -c "$WORK/plain")" 1

echo "== GIT_DIR in the environment does not redirect it"
GIT_DIR="$WORK/origin.git" run "$REPO" --ticket 8 --type fix --slug env-ignored
check "exit status" "$RC" 0
check "worktree" "$(printf '%s' "$OUT" | field worktree)" "$REPO/.claude/worktrees/gh-8-env-ignored"

echo ""
if [ "$failures" -eq 0 ]; then
  echo "OK"
  exit 0
fi
echo "FAILED: $failures assertion(s)"
exit 1
