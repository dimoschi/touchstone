#!/usr/bin/env bash
# crap-check.sh keeps the rows of a green run, and only of a green run, without
# ever changing the verdict it exits with. Needs only git, bash and python3: the
# language module is replaced by a stub that prints canned rows, so what is under
# test is the dispatcher's own handling of them.

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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

mkdir "$WORK/skill"
cp -R "$SKILL_DIR/lib" "$SKILL_DIR/crap-check.sh" "$WORK/skill/"
cat > "$WORK/skill/lib/crap-check-python.sh" <<'STUB'
#!/usr/bin/env bash
cat "$STUB_ROWS"
STUB
chmod +x "$WORK/skill/lib/crap-check-python.sh"

REPO="$WORK/repo"
git init -qb main "$REPO"
printf 'def f():\n    return 1\n' > "$REPO/a.py"
git -C "$REPO" add a.py
GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
  git -C "$REPO" -c commit.gpgsign=false commit -q -m base
git -C "$REPO" checkout -qb feature

ROWS_FILE="$REPO/.git/crap-check-rows.json"
GREEN="$WORK/green.txt"
RED="$WORK/red.txt"
printf 'a.py::f  complexity=2   coverage=100.0%%  CRAP=2.0  OK  (new)\n' > "$GREEN"
printf 'a.py::f  complexity=12  coverage=10.0%%   CRAP=120.0  HARD  (new)\n' > "$RED"

stage_change() {
  printf 'def f():\n    return %s\n' "$1" > "$REPO/a.py"
  git -C "$REPO" add a.py
}

gate() {
  STUB_ROWS="$1" "$WORK/skill/crap-check.sh" "$REPO" > "$WORK/out.log" 2>&1
  echo $?
}

echo "== a red run records nothing"
stage_change 2
check "the gate is red" "$(gate "$RED")" 1
check "no rows file was written" "$([ -e "$ROWS_FILE" ] && echo yes || echo no)" no

echo "== a green run records its rows under the branch"
stage_change 3
check "the gate is green" "$(gate "$GREEN")" 0
check "the branch's row is there" \
  "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["feature"]["a.py::f"]["tag"])' "$ROWS_FILE")" new
check "the row names the head and the tree the gate ran against" \
  "$(python3 -c 'import json,sys; r = json.load(open(sys.argv[1]))["feature"]["a.py::f"]; sys.stdout.write(r["head"] + " " + r["tree"])' "$ROWS_FILE")" \
  "$(git -C "$REPO" rev-parse HEAD) $(git -C "$REPO" write-tree)"

echo "== a later red run leaves the record as it was"
before="$(cat "$ROWS_FILE")"
stage_change 4
check "the gate is red again" "$(gate "$RED")" 1
check "the rows file is unchanged" "$([ "$(cat "$ROWS_FILE")" = "$before" ] && echo same || echo changed)" same

echo "== a green run in a linked worktree records into the common git dir"
WT="$WORK/wt"
git -C "$REPO" worktree add -q -b wtbranch "$WT"
printf 'def f():\n    return 9\n' > "$WT/a.py"
git -C "$WT" add a.py
STUB_ROWS="$GREEN" "$WORK/skill/crap-check.sh" "$WT" > "$WORK/out.log" 2>&1
check "the gate is green" "$?" 0
check "the worktree's branch has its row in the common git dir" \
  "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["wtbranch"]["a.py::f"]["tag"])' "$ROWS_FILE")" new
check "the worktree's own git dir holds none" \
  "$([ -e "$(git -C "$WT" rev-parse --absolute-git-dir)/crap-check-rows.json" ] && echo yes || echo no)" no
git -C "$REPO" worktree remove --force "$WT"
check "removing the worktree leaves its branch's row" \
  "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["wtbranch"]["a.py::f"]["tag"])' "$ROWS_FILE")" new

commit_in() {
  GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
    git -C "$1" -c commit.gpgsign=false commit -q -m "$2"
}

counted_rows() {
  PYTHONPATH="$SKILL_DIR/lib" python3 -c '
import sys, crap_rows
sys.stdout.write(" ".join(sorted(crap_rows.latest(*sys.argv[1:5]))))' "$ROWS_FILE" "$1" "$2" "$3"
}

echo "== a ticket redone from scratch under the same branch name keeps none of the earlier attempt's rows"
printf 'a.py::old  complexity=5  coverage=100.0%%  CRAP=5.0  OK  (new)\n' > "$WORK/first.txt"
printf 'b.py::g  complexity=1  coverage=100.0%%  CRAP=1.0  OK  (new)\n' > "$WORK/second.txt"
REDO="$WORK/redo"
git -C "$REPO" worktree add -q -b redo "$REDO" main
printf 'def old():\n    return 2\n' > "$REDO/a.py"
git -C "$REDO" add a.py
STUB_ROWS="$WORK/first.txt" "$WORK/skill/crap-check.sh" "$REDO" > "$WORK/out.log" 2>&1
check "the first attempt's gate is green" "$?" 0
commit_in "$REDO" first
check "the first attempt's row counts while its commit is in history" \
  "$(counted_rows redo "$REDO" "$(git -C "$REDO" rev-parse HEAD)")" "a.py::old"
git -C "$REPO" worktree remove --force "$REDO"
git -C "$REPO" branch -q -D redo
git -C "$REPO" worktree add -q -b redo "$REDO" main
printf 'def g():\n    return 3\n' > "$REDO/b.py"
git -C "$REDO" add b.py
STUB_ROWS="$WORK/second.txt" "$WORK/skill/crap-check.sh" "$REDO" > "$WORK/out.log" 2>&1
check "the second attempt's gate is green" "$?" 0
commit_in "$REDO" second
check "only the second attempt's row counts" \
  "$(counted_rows redo "$REDO" "$(git -C "$REDO" rev-parse HEAD)")" "b.py::g"
check "the file holds only the second attempt's row" \
  "$(python3 -c 'import json,sys; print(" ".join(sorted(json.load(open(sys.argv[1]))["redo"])))' "$ROWS_FILE")" "b.py::g"
git -C "$REPO" worktree remove --force "$REDO"

echo "== a record that cannot be written does not change the verdict"
rm -f "$ROWS_FILE"
mkdir "$ROWS_FILE"
stage_change 5
check "the gate is still green" "$(gate "$GREEN")" 0
check "it says the rows were not kept" \
  "$(grep -c 'could not record the CRAP rows' "$WORK/out.log")" 1

echo ""
if [ "$failures" -eq 0 ]; then
  echo "CRAP ROWS OK"
else
  echo "FAILED: $failures assertion(s)"
  exit 1
fi
