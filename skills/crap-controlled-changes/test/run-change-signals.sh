#!/usr/bin/env bash
# change-signals.sh end to end: the arguments it accepts, what it prints, and the
# three settings it takes from shell and hands to lib/change_signals.py (the
# unsupported-language list, the marker's exemptions, the pinned deadcode
# version). The tools the signals call are not needed: the ones that matter here
# are stubbed or reported unmeasured.

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SKILL_DIR/change-signals.sh"

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

REPO="$WORK/repo"
git init -qb main "$REPO"
commit() {
  git -C "$REPO" add -A
  GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
    git -C "$REPO" -c commit.gpgsign=false commit -q -m "$1"
}
printf 'module example.com/m\n\ngo 1.22\n' > "$REPO/go.mod"
printf 'package m\n' > "$REPO/a.go"
mkdir "$REPO/web"
printf 'let a = 1\n' > "$REPO/web/app.ts"
commit base
BASE="$(git -C "$REPO" rev-parse HEAD)"
printf 'package m\n\nfunc A() {}\n' > "$REPO/a.go"
printf 'let a = 2\n' > "$REPO/web/app.ts"
commit head
HEAD_SHA="$(git -C "$REPO" rev-parse HEAD)"
RANGE="$BASE..$HEAD_SHA"

STUBS="$WORK/bin"
mkdir "$STUBS"
cat > "$STUBS/go" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG"
echo "deadcode: no main packages" >&2
exit 1
STUB
chmod +x "$STUBS/go"
export STUB_LOG="$WORK/go.log"

field() {
  python3 -c '
import json, sys
values = json.loads(sys.stdin.read().split("\n")[1])["values"]
sys.stdout.write(str(eval(sys.argv[1], {"v": values})) + "\n")
' "$1"
}

run() {
  OUT="$(PATH="$STUBS:$PATH" "$SCRIPT" "$@" 2>"$WORK/err.log")"
  RC=$?
}

echo "== it prints the markers and one JSON line, and nothing on stderr"
run "$REPO" "$RANGE"
check "exit status" "$RC" 0
check "the first line names the range" "$(printf '%s\n' "$OUT" | sed -n 1p)" "TOUCHSTONE_SIGNALS $RANGE"
check "the last line is the end marker" "$(printf '%s\n' "$OUT" | sed -n 3p)" "TOUCHSTONE_SIGNALS_END"
check "there are three lines" "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" 3
check "stderr is empty" "$(wc -c < "$WORK/err.log" | tr -d ' ')" 0
check "the lines added are counted" "$(printf '%s\n' "$OUT" | field 'v["la"]["value"]')" 3

echo "== a change in a language no tool covers makes the semantic signals unmeasured"
check "api_broken names the file" \
  "$(printf '%s\n' "$OUT" | field '"web/app.ts" in v["api_broken"]["reason"]')" True

echo "== the marker's exemptions do not take it out of the question: no tool read it either way"
printf 'web/**\n' > "$REPO/.crap-gated"
run "$REPO" "$RANGE"
check "api_broken still names it" \
  "$(printf '%s\n' "$OUT" | field '"web/app.ts" in v["api_broken"].get("reason", "")')" True
check "so does security_pattern" \
  "$(printf '%s\n' "$OUT" | field '"web/app.ts" in v["security_pattern"].get("reason", "")')" True
rm -f "$REPO/.crap-gated"

echo "== deadcode is run at the version the gates pin"
PINNED="$(bash -c ". '$SKILL_DIR/lib/tool-versions.sh'; echo \"\$DEADCODE_VERSION_DEFAULT\"")"
: > "$WORK/go.log"
run "$REPO" "$RANGE"
check "the pinned version reaches go run" \
  "$(grep -c "run golang.org/x/tools/cmd/deadcode@$PINNED -json" "$WORK/go.log")" 1
: > "$WORK/go.log"
DEADCODE_GO_VERSION=v9.9.9 run "$REPO" "$RANGE"
check "the gate's own override reaches it too" \
  "$(grep -c "deadcode@v9.9.9 " "$WORK/go.log")" 1

echo "== a shell script is a language no tool covers, though the CRAP gate leaves it alone"
printf '#!/bin/sh\necho hi\n' > "$REPO/run.sh"
printf 'notes\n' > "$REPO/README.md"
commit base-shell
SHELL_BASE="$(git -C "$REPO" rev-parse HEAD)"
printf 'package m\n\nfunc A() {}\n\nfunc B() {}\n' > "$REPO/a.go"
printf '#!/bin/sh\necho hi\neval "$1"\n' > "$REPO/run.sh"
printf 'more notes\n' > "$REPO/README.md"
commit head-shell
SHELL_HEAD="$(git -C "$REPO" rev-parse HEAD)"
run "$REPO" "$SHELL_BASE..$SHELL_HEAD"
check "security_pattern is not false" \
  "$(printf '%s\n' "$OUT" | field 'v["security_pattern"]["value"]')" unmeasured
check "security_pattern names the script" \
  "$(printf '%s\n' "$OUT" | field '"run.sh" in v["security_pattern"]["reason"]')" True
check "and not the document beside it" \
  "$(printf '%s\n' "$OUT" | field '"README.md" in v["security_pattern"]["reason"]')" False
check "reachable does not count the script as read" \
  "$(printf '%s\n' "$OUT" | field '"run.sh" in v["reachable"]["reason"]')" True

echo "== refusals exit 2 and print nothing on stdout"
run
check "no arguments" "$RC" 2
check "no output on stdout" "$OUT" ""
run "$REPO"
check "no range" "$RC" 2
run "relative/path" "$RANGE"
check "a relative repo path" "$RC" 2
check "it says the path must be absolute" "$(grep -c 'absolute' "$WORK/err.log")" 1
run "$WORK/not-a-repo" "$RANGE"
check "a directory that is not a repository" "$RC" 2
run "$REPO" "$BASE..nope"
check "a range that does not resolve" "$RC" 2
check "it names the ref" "$(grep -c 'cannot resolve nope' "$WORK/err.log")" 1
run "$REPO" "$HEAD_SHA"
check "a range without two dots" "$RC" 2

echo ""
if [ "$failures" -eq 0 ]; then
  echo "CHANGE SIGNALS OK"
else
  echo "FAILED: $failures assertion(s)"
  exit 1
fi
