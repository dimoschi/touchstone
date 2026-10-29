#!/usr/bin/env bash
# run-dup.sh: dup-check.sh against throwaway repos, with the real dryer.
#
# Every case builds its own repo, so one case's acceptance or marker never
# reaches another. The copied functions differ only in names, which dryer
# normalizes away, so their score does not depend on dryer's exact weighting.

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SKILL_DIR/dup-check.sh"

command -v uv  >/dev/null || { echo "SKIP: uv not on PATH";  exit 0; }
command -v git >/dev/null || { echo "SKIP: git not on PATH"; exit 0; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
failures=0

fixture_commit() {
  GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
    git -c commit.gpgsign=false -c gpg.format=openpgp commit -q -m "$1"
}

check() {
  if [ "$2" = "pass" ]; then
    echo "  ok: $1"
  else
    echo "  FAIL: $1"
    failures=$((failures + 1))
  fi
}

expect_status() {
  if [ "$STATUS" = "$2" ]; then check "$1 (exit $STATUS)" pass; else check "$1 (exit $STATUS, want $2)" fail; fi
}

expect_contains() {
  if printf '%s' "$OUT" | grep -qF -- "$2"; then check "$1" pass; else check "$1 (missing: $2)" fail; fi
}

py_function() {
  cat <<PY
def $1(items, rate, discount):
    $2 = 0
    for item in items:
        if item.price > 0:
            $2 += item.price * item.qty
    if discount:
        $2 = $2 - discount
    return $2 * (1 + rate)
PY
}

go_function() {
  cat <<GO
func $1(items []Item, rate float64, discount float64) float64 {
	$2 := 0.0
	for _, item := range items {
		if item.Price > 0 {
			$2 += item.Price * float64(item.Qty)
		}
	}
	if discount > 0 {
		$2 = $2 - discount
	}
	return $2 * (1 + rate)
}
GO
}

# new_repo <name> <marker text>: a repo with a marker holding that text. The
# marker is left untracked: a global gitignore may well list it, and the gate
# reads it from the working tree either way.
new_repo() {
  local dir="$WORK/$1"
  mkdir -p "$dir/pkg"
  git init -q "$dir"
  printf '%s' "$2" > "$dir/.crap-gated"
  printf 'x\n' > "$dir/README"
  git -C "$dir" add README
  (cd "$dir" && fixture_commit baseline)
  printf '%s' "$dir"
}

commit_all() {
  (cd "$1" && git add -A && fixture_commit "$2")
}

# run_gate <repo> [args...]: OUT and STATUS, and whether the run left the repo as it was.
run_gate() {
  local repo="$1" before after
  shift
  before="$(git -C "$repo" status --porcelain --ignored)"
  STATUS=0
  OUT="$("$SCRIPT" "$repo" "$@" 2>&1)" || STATUS=$?
  after="$(git -C "$repo" status --porcelain --ignored)"
  printf '%s\n' "$OUT" | sed 's/^/    | /'
  if [ "$before" = "$after" ]; then
    check "leaves no files behind (no .metrics, venv or cache)" pass
  else
    check "leaves no files behind (before/after differ)" fail
  fi
}

echo "case A: a Python copy of an existing function is a new duplicate"
R="$(new_repo a "")"
py_function total_price total > "$R/pkg/a.py"
commit_all "$R" first
py_function order_cost cost > "$R/pkg/b.py"
git -C "$R" add pkg/b.py
run_gate "$R"
expect_status   "exit 1"                 1
expect_contains "names the finding"      "DUPLICATION_INTRODUCED"
expect_contains "names the new file"     "pkg/b.py"
expect_contains "names the old file"     "pkg/a.py"
BRANCH="$(git -C "$R" symbolic-ref --short HEAD)"
TOP="$(git -C "$R" rev-parse --show-toplevel)"
if [ "$(printf '%s\n' "$OUT" | sed -n 1p)" = "dup-check: repo $TOP branch $BRANCH" ]; then
  check "first line names the repo and branch" pass
else
  check "first line names the repo and branch" fail
fi
KEY="$(printf '%s\n' "$OUT" | sed -n 's/.*key=//p' | sed -n 1p)"

echo "case B: --accept lets it through, --revoke takes it back"
ACCEPT_OUT="$("$SCRIPT" "$R" --accept "$KEY" 2>&1)"
case "$ACCEPT_OUT" in *"recorded user acceptance"*) check "accept is recorded" pass ;; *) check "accept is recorded" fail ;; esac
[ -f "$(git -C "$R" rev-parse --path-format=absolute --git-common-dir)/dup-accepted.json" ] \
  && check "store sits in the git common dir" pass || check "store sits in the git common dir" fail
run_gate "$R"
expect_status   "exit 0 once accepted"   0
expect_contains "still shown, as accepted" "ACCEPTED"
"$SCRIPT" "$R" --revoke "$KEY" >/dev/null 2>&1
run_gate "$R"
expect_status   "exit 1 again once revoked" 1

echo "case C: a duplicate already at HEAD is not introduced by an unrelated edit"
R="$(new_repo c "")"
py_function total_price total > "$R/pkg/a.py"
py_function order_cost cost > "$R/pkg/b.py"
commit_all "$R" "two copies"
printf '\nLIMIT = 3\n' >> "$R/pkg/b.py"
git -C "$R" add pkg/b.py
run_gate "$R"
expect_status   "exit 0"                 0
expect_contains "says so"                "DUPLICATION_OK"

echo "case D: a threshold above any score lets the copy through"
R="$(new_repo d "duplication-threshold = 1.01  # nothing scores above 1
")"
py_function total_price total > "$R/pkg/a.py"
commit_all "$R" first
py_function order_cost cost > "$R/pkg/b.py"
git -C "$R" add pkg/b.py
run_gate "$R"
expect_status   "exit 0"                 0

echo "case E: an exempt path is left out of the comparison"
R="$(new_repo e "pkg/b.py
")"
py_function total_price total > "$R/pkg/a.py"
commit_all "$R" first
py_function order_cost cost > "$R/pkg/b.py"
git -C "$R" add pkg/b.py
run_gate "$R"
expect_status   "exit 0"                 0

echo "case F: a Go copy of an existing function is a new duplicate"
R="$(new_repo f "")"
{ printf 'package shop\n\ntype Item struct {\n\tPrice float64\n\tQty   int\n}\n\n'; go_function TotalPrice total; } > "$R/pkg/a.go"
commit_all "$R" first
{ printf 'package shop\n\n'; go_function OrderCost cost; } > "$R/pkg/b.go"
git -C "$R" add pkg/b.go
run_gate "$R"
expect_status   "exit 1"                 1
expect_contains "names the finding"      "DUPLICATION_INTRODUCED"
expect_contains "names the new file"     "pkg/b.go"

echo "case G: a repo without .crap-gated is not gated"
R="$WORK/g"
mkdir -p "$R/pkg"
git init -q "$R"
printf 'x\n' > "$R/README"
git -C "$R" add README
(cd "$R" && fixture_commit baseline)
py_function total_price total > "$R/pkg/a.py"
py_function order_cost cost > "$R/pkg/b.py"
git -C "$R" add pkg
run_gate "$R"
expect_status   "exit 0"                 0
expect_contains "says it is not enabled" "not enabled"

echo "case H: nothing staged in Go or Python needs no tool at all"
R="$(new_repo h "")"
printf 'notes\n' > "$R/NOTES.md"
git -C "$R" add NOTES.md
STATUS=0
OUT="$(CRAP_DRYER_RUN=false "$SCRIPT" "$R" 2>&1)" || STATUS=$?
expect_status   "exit 0"                 0
expect_contains "says nothing to check"  "no staged Go or Python files"

echo "case I: renaming a file does not introduce a duplicate it already held"
R="$(new_repo i "")"
py_function total_price total > "$R/pkg/a.py"
py_function order_cost cost > "$R/pkg/c.py"
commit_all "$R" "two copies"
git -C "$R" mv pkg/a.py pkg/b.py
run_gate "$R"
expect_status   "exit 0"                 0
expect_contains "says so"                "DUPLICATION_OK"

echo "case J: vendored code is not something a new function can duplicate"
R="$(new_repo j "")"
mkdir -p "$R/vendor/example.com/lib"
{ printf 'package lib\n\ntype Item struct {\n\tPrice float64\n\tQty   int\n}\n\n'; go_function Total total; } \
  > "$R/vendor/example.com/lib/lib.go"
commit_all "$R" "vendor a library"
{ printf 'package shop\n\n'; go_function OrderCost cost; } > "$R/pkg/b.go"
git -C "$R" add pkg/b.go
run_gate "$R"
expect_status   "exit 0"                 0
expect_contains "says so"                "DUPLICATION_OK"

echo "case K: a generated mock is not compared, in either spelling"
R="$(new_repo k "")"
{ printf 'package shop\n\n'; go_function TotalPrice total; go_function OrderCost cost; } > "$R/pkg/store_mock.go"
git -C "$R" add pkg/store_mock.go
run_gate "$R"
expect_status   "exit 0"                 0
expect_contains "finds nothing to check" "no staged Go or Python files"

echo "case L: accepting a pair in one file does not accept a further copy there"
R="$(new_repo l "")"
{ py_function handle_a first; printf '\n\n'; py_function handle_b second; } > "$R/pkg/h.py"
git -C "$R" add pkg/h.py
run_gate "$R"
expect_status   "exit 1"                 1
KEY="$(printf '%s\n' "$OUT" | sed -n 's/.*key=//p' | sed -n 1p)"
"$SCRIPT" "$R" --accept "$KEY" >/dev/null 2>&1
run_gate "$R"
expect_status   "exit 0 once accepted"   0
{ py_function handle_a first; printf '\n\n'; py_function handle_b second; printf '\n\n'
  py_function handle_c third; printf '\n\n'; py_function handle_d fourth; } > "$R/pkg/h.py"
git -C "$R" add pkg/h.py
run_gate "$R"
expect_status   "exit 1 for the further copies" 1

echo ""
if [ "$failures" -eq 0 ]; then
  echo "DUP OK"
else
  echo "FAILED: $failures assertion(s)"
  exit 1
fi
