#!/usr/bin/env bash
# End-to-end test for risk-signals.sh: the three-line contract, the hand-counted
# git signals, every tool-backed signal reading "unmeasured" (never false) when
# its tool is absent, the wiring to a tool when one is present, and exit 2 with
# nothing on stdout for a bad argument. Needs only git, bash, python3 and tar.
#
# The script runs with a PATH holding nothing but what it needs, so a gosec or
# difft the developer happens to have installed cannot change what "absent"
# means here. Fake tools are put ahead of that PATH where a test needs one.

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SKILL_DIR/risk-signals.sh"

command -v git >/dev/null || { echo "SKIP: git not on PATH"; exit 0; }
command -v python3 >/dev/null || { echo "SKIP: python3 not on PATH"; exit 0; }
command -v tar >/dev/null || { echo "SKIP: tar not on PATH"; exit 0; }

WORK="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
failures=0

BIN="$WORK/bin"
FAKE="$WORK/fake"
mkdir -p "$BIN" "$FAKE"
for tool in bash env git python3 tar dirname sh cat; do
  ln -s "$(command -v "$tool")" "$BIN/$tool"
done

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
    echo "  FAIL: $1 (did not find '$3' in: $2)"
    failures=$((failures + 1))
  fi
}

commit() {
  GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=commit.gpgsign GIT_CONFIG_VALUE_0=false \
    git commit -q "$@"
}

# run <path-prefix> <script args...>: stdout in OUT, exit status in RC.
run() {
  local prefix="$1"
  shift
  RC=0
  OUT="$(env PATH="$prefix$BIN" "$SCRIPT" "$@" 2>"$WORK/stderr")" || RC=$?
  ERR="$(cat "$WORK/stderr")"
}

# sig <key> <field>: one field of one entry on the JSON line of OUT, as JSON.
sig() {
  printf '%s\n' "$OUT" | sed -n 2p | python3 -c '
import json, sys
print(json.dumps(json.load(sys.stdin)["signals"][sys.argv[1]][sys.argv[2]]))' "$1" "$2"
}

REPO="$WORK/repo"
git init -qb main "$REPO"
cd "$REPO"
seq 0 9 | sed 's/^/l/' > a.py
seq 1 5 > b.py
echo readme > README.md
git add -A
commit -m base
BASE="$(git rev-parse HEAD)"

sed -i.bak 's/^l1$/L1/' a.py && rm a.py.bak
printf 'x\ny\n' >> a.py
git rm -q b.py
mkdir src
printf 'q\nw\ne\nr\n' > src/c.py
git add -A
commit -m head
HEAD1="$(git rev-parse HEAD)"
RANGE="$BASE..$HEAD1"

echo "== the three-line contract =="
run "" "$REPO" "$RANGE"
check "exit status" "$RC" 0
check "stdout is exactly three lines" "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" 3
check "begin marker names the range" "$(printf '%s\n' "$OUT" | sed -n 1p)" "TOUCHSTONE_RISK_SIGNALS $RANGE"
check "end marker is the last line" "$(printf '%s\n' "$OUT" | sed -n 3p)" "TOUCHSTONE_RISK_SIGNALS_END"
check "nothing on stderr" "$ERR" ""

echo "== every key, in order, each a measured value or an unmeasured reason =="
SHAPE="$(printf '%s\n' "$OUT" | sed -n 2p | python3 -c '
import json, sys
signals = json.load(sys.stdin)["signals"]
keys = ["la", "ld", "la_per_lt", "files", "directories", "dependency_surface", "semantic_noop",
        "api_broken", "security_pattern", "crap_max", "coverage_min", "entry_reachable",
        "prior_defect_files"]
assert list(signals) == keys, list(signals)
for key, entry in signals.items():
    if entry["value"] == "unmeasured":
        assert set(entry) == {"value", "reason"}, (key, entry)
        assert 0 < len(entry["reason"]) <= 400, key
    else:
        assert set(entry) == {"value", "evidence"}, (key, entry)
        assert isinstance(entry["value"], (bool, int, float)), (key, entry)
        assert 0 < len(entry["evidence"]) <= 400, key
print("ok")' 2>&1)"
check "13 keys with well-formed entries" "$SHAPE" ok

echo "== git signals match a hand count =="
check "la" "$(sig la value)" 7
check "ld" "$(sig ld value)" 6
check "files" "$(sig files value)" 3
check "directories" "$(sig directories value)" 2
check "la_per_lt" "$(sig la_per_lt value)" "$(python3 -c 'import json; print(json.dumps(7 / 15))')"
check "dependency_surface" "$(sig dependency_surface value)" false

echo "== a signal whose tool is absent is unmeasured and names the tool, never false =="
check "api_broken" "$(sig api_broken value)" '"unmeasured"'
check_contains "api_broken names griffe" "$(sig api_broken reason)" griffe
check "security_pattern" "$(sig security_pattern value)" '"unmeasured"'
check_contains "security_pattern names bandit" "$(sig security_pattern reason)" bandit
check "entry_reachable" "$(sig entry_reachable value)" '"unmeasured"'
check "crap_max" "$(sig crap_max value)" '"unmeasured"'
check "coverage_min" "$(sig coverage_min value)" '"unmeasured"'
check "prior_defect_files" "$(sig prior_defect_files value)" '"unmeasured"'

echo "== a deleted or added file is never a semantic no-op, whatever tools are installed =="
check "semantic_noop" "$(sig semantic_noop value)" false
check_contains "the evidence says why" "$(sig semantic_noop evidence)" "b.py is not a modification"

echo "== a range whose every file is new has no LT =="
git checkout -q -b newfiles "$BASE"
echo one > n1.py
printf 'a\nb\n' > n2.py
git add -A
commit -m "only new files"
run "" "$REPO" "$BASE..$(git rev-parse HEAD)"
check "la_per_lt is unmeasured" "$(sig la_per_lt value)" '"unmeasured"'
check_contains "the reason says LT is 0" "$(sig la_per_lt reason)" "LT is 0"

echo "== a package-manager file makes dependency_surface true =="
git checkout -q -b deps "$BASE"
printf 'module m\n' > go.mod
git add -A
commit -m "add go.mod"
run "" "$REPO" "$BASE..$(git rev-parse HEAD)"
check "dependency_surface" "$(sig dependency_surface value)" true
check_contains "the evidence names the file" "$(sig dependency_surface evidence)" go.mod

echo "== a language no tool supports leaves the semantic signals unmeasured =="
git checkout -q -b js "$BASE"
echo 'let x = 1' > app.js
git add -A
commit -m "add js"
run "" "$REPO" "$BASE..$(git rev-parse HEAD)"
check "semantic_noop" "$(sig semantic_noop value)" '"unmeasured"'
check_contains "the reason names the extension" "$(sig semantic_noop reason)" ".js"
check "api_broken" "$(sig api_broken value)" '"unmeasured"'
check "security_pattern" "$(sig security_pattern value)" '"unmeasured"'

echo "== a tool that is present is asked, and its answer is the value =="
cat > "$FAKE/difft" <<'EOF'
#!/bin/sh
if [ "$(grep -v '^#' "$4")" = "$(grep -v '^#' "$5")" ]; then exit 0; fi
exit 1
EOF
cat > "$FAKE/bandit" <<'EOF'
#!/bin/sh
echo '{"results": [{"filename": "./a.py", "issue_text": "weak hash", "line_number": 1, "line_range": [1], "test_id": "B324"}]}'
exit 1
EOF
chmod +x "$FAKE/difft" "$FAKE/bandit"
git checkout -q -b comment "$BASE"
{ echo '# a note'; cat a.py; } > a.py.new && mv a.py.new a.py
git add -A
commit -m "comment only"
COMMENT_RANGE="$BASE..$(git rev-parse HEAD)"
run "" "$REPO" "$COMMENT_RANGE"
check "semantic_noop without difft is unmeasured" "$(sig semantic_noop value)" '"unmeasured"'
check_contains "the reason names difft" "$(sig semantic_noop reason)" difft
run "$FAKE:" "$REPO" "$COMMENT_RANGE"
check "semantic_noop is true for a comment-only change" "$(sig semantic_noop value)" true
check "security_pattern is true for a finding on an added line" "$(sig security_pattern value)" true
check_contains "the evidence is the tool's finding" "$(sig security_pattern evidence)" "B324 weak hash at a.py:1"

echo "== a bad argument exits 2 with nothing on stdout =="
run "" "$REPO" "nope"
check "not a range: exit" "$RC" 2
check "not a range: stdout" "$OUT" ""
run "" "$REPO" "$BASE..nosuchref"
check "unresolvable head: exit" "$RC" 2
check "unresolvable head: stdout" "$OUT" ""
run "" "$WORK" "$BASE..$HEAD1"
check "not a repository: exit" "$RC" 2
check "not a repository: stdout" "$OUT" ""
run "" "relative/path" "$BASE..$HEAD1"
check "relative repo path: exit" "$RC" 2
check "relative repo path: stdout" "$OUT" ""
run "" "$REPO" "$RANGE" extra
check "too many arguments: exit" "$RC" 2
check "too many arguments: stdout" "$OUT" ""
run ""
check "no arguments: exit" "$RC" 2
check "no arguments: stdout" "$OUT" ""

echo "== without a leading path it measures the repo of the cwd =="
git checkout -q main
OUT="$(cd "$REPO" && env PATH="$BIN" "$SCRIPT" "$RANGE" 2>/dev/null)"
check "begin marker" "$(printf '%s\n' "$OUT" | sed -n 1p)" "TOUCHSTONE_RISK_SIGNALS $RANGE"

echo ""
if [ "$failures" -eq 0 ]; then
  echo "RISK SIGNALS OK"
  exit 0
fi
echo "FAILED: $failures assertion(s)"
exit 1
