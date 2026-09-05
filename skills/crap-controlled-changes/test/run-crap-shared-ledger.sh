#!/usr/bin/env bash
# E2E test that a green CRAP scoring survives the branch and the worktree that
# made it, and only where that is sound. A branch stacked on an unmerged one
# carries its parent's commits in range, so it used to be told to re-stage source
# it never wrote, and the documented escape was --mark-scored: an override that
# records "scored without measuring". Borrowing replaces that with reuse.

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SKILL_DIR/crap-check.sh"
WRAP="$SKILL_DIR/crap-commit.sh"

command -v go  >/dev/null || { echo "SKIP: go not on PATH"; exit 0; }
command -v git >/dev/null || { echo "SKIP: git not on PATH"; exit 0; }
export CRAP_SIGNING_KEY="${CRAP_SIGNING_KEY:-$HOME/.ssh/id_ed25519}"
[ -f "$CRAP_SIGNING_KEY" ] || { echo "SKIP: no ssh signing key at $CRAP_SIGNING_KEY"; exit 0; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
MAIN="$WORK/main"
mkdir -p "$MAIN"
cd "$MAIN"

GIT_ENV=(GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
         GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=commit.gpgsign GIT_CONFIG_VALUE_0=false)

commit() { env "${GIT_ENV[@]}" git commit -q "$@"; }
pick()   { env "${GIT_ENV[@]}" git cherry-pick "$@" >/dev/null; }

run() {
  RC=0
  OUT="$("$SCRIPT" "$@" 2>&1)" || RC=$?
}

# Rewrites one field of every shared record, to prove a guard bites rather than
# assuming it does.
poke() {
  python3 - "$1" "$2" <<'PY'
import json, sys
field, value = sys.argv[1], sys.argv[2]
path = ".git/crap-check-scored.json"
store = json.load(open(path))
for blobs in store.get("..blobs", {}).values():
    for record in blobs.values():
        record[field] = value
json.dump(store, open(path, "w"), indent=1, sort_keys=True)
PY
}

git init -qb main
printf 'module example.com/crapshared\n\ngo 1.26\n' > go.mod
cat > calc.go <<'EOF'
package calc

func Double(x int) int {
	return x * 2
}
EOF
cat > calc_test.go <<'EOF'
package calc

import "testing"

func TestDouble(t *testing.T) {
	if Double(3) != 6 {
		t.Fatal("3")
	}
}
EOF
git add .
commit -m baseline

echo "--- phase 1: a green run records the blob outside the branch namespace ---"
git checkout -qb feature
cat >> calc.go <<'EOF'

func Sign(x int) int {
	if x < 0 {
		return -1
	}
	return 1
}
EOF
cat >> calc_test.go <<'EOF'

func TestSign(t *testing.T) {
	cases := map[int]int{-5: -1, 0: 1, 5: 1}
	for in, want := range cases {
		if got := Sign(in); got != want {
			t.Fatalf("Sign(%d) = %d, want %d", in, got, want)
		}
	}
}
EOF
git add calc.go calc_test.go
RC=0
OUT="$(env "${GIT_ENV[@]}" "$WRAP" "$MAIN" -m "feat: add Sign, fully tested" 2>&1)" || RC=$?
echo "$OUT"
[ "$RC" -eq 0 ] || { echo "FAIL: expected a green gate and a commit, got $RC"; exit 1; }
FEATURE_TIP="$(git rev-parse HEAD)"
grep -q '"\.\.blobs"' .git/crap-check-scored.json || { echo "FAIL: no shared blob namespace written"; exit 1; }
grep -q "$FEATURE_TIP" .git/crap-check-scored.json ||
  { echo "FAIL: record anchored to the parent, not the commit carrying the blob"; exit 1; }

echo "--- phase 2: a branch stacked on it trusts what its parent scored ---"
git checkout -qb stacked
run
echo "$OUT"
[ "$RC" -eq 0 ] || { echo "FAIL: a stacked branch must trust its parent's scoring, got $RC"; exit 1; }
echo "$OUT" | grep -q 'borrowed' || { echo "FAIL: borrowing must be stated, not silent"; exit 1; }

echo "--- phase 3: an adoption is never borrowed, only a measurement ---"
poke source marked
run
[ "$RC" -eq 5 ] || { echo "FAIL: --mark-scored must not spread across branches, got $RC"; echo "$OUT"; exit 1; }
poke source measured

echo "--- phase 4: a different analyzer version is not allowed to borrow it ---"
poke tools 'go=go0.0.0 gocrap=v0.0.0'
run
[ "$RC" -eq 5 ] || { echo "FAIL: a record scored by another version must not count, got $RC"; echo "$OUT"; exit 1; }
run --mark-scored >/dev/null 2>&1
git checkout -q feature
git branch -qD stacked

echo "--- phase 5: an identical blob from unreachable history is not borrowed ---"
git checkout -q -b sibling main
pick "$FEATURE_TIP"
[ "$(git rev-parse HEAD:calc.go)" = "$(git rev-parse "$FEATURE_TIP":calc.go)" ] ||
  { echo "FAIL: cherry-pick did not reproduce the blob, test is not testing anything"; exit 1; }
git merge-base --is-ancestor "$FEATURE_TIP" HEAD &&
  { echo "FAIL: the measuring commit is reachable here, test is not testing anything"; exit 1; }
run
[ "$RC" -eq 5 ] || { echo "FAIL: a record from history this branch lacks must not count, got $RC"; echo "$OUT"; exit 1; }

echo "--- phase 6: a linked worktree on the scored branch trusts the record ---"
git checkout -q main
git worktree add -q "$WORK/wt" feature
cd "$WORK/wt"
run
echo "$OUT"
[ "$RC" -eq 0 ] || { echo "FAIL: the record must not be trapped in the worktree that made it, got $RC"; exit 1; }
[ -f "$MAIN/.git/worktrees/wt/crap-check-scored.json" ] &&
  { echo "FAIL: ledger written per-worktree"; exit 1; }

echo "--- phase 7: a record left in the pre-move per-worktree file still counts ---"
python3 - "$MAIN" <<'PY'
import json, os, sys
main = sys.argv[1]
store = json.load(open(f"{main}/.git/crap-check-scored.json"))
wt = f"{main}/.git/worktrees/wt"
os.makedirs(wt, exist_ok=True)
# The branch's records where they used to be written, and nowhere else.
json.dump({"orphan": store.pop("feature")}, open(f"{wt}/crap-check-scored.json", "w"))
json.dump(store, open(f"{main}/.git/crap-check-scored.json", "w"))
PY
git checkout -q -b orphan
run
[ "$RC" -eq 0 ] || { echo "FAIL: a pre-move worktree record must not be lost, got $RC"; echo "$OUT"; exit 1; }

echo "CRAP SHARED LEDGER OK"
