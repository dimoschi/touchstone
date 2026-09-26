#!/usr/bin/env bash
# Test for the PHP module's infection invocation. Needs no PHP: infection is
# replaced by a stub that reads the config it was handed, writes a canned report
# to whatever `logs.json` names, and exits 0. That is exactly the contract the
# module has with infection, and it is the part that was wrong: 0.34 has no
# --logger-json flag (only logger-html/text/summary-json/github/gitlab), so the
# real binary rejected every invocation and the gate could only ever report
# FAILED TO MEASURE. The JSON report is a config key, and config paths resolve
# against dirname(config), so the merged config must sit beside the original.

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$SKILL_DIR/lib"
MODULE="$LIB/mutation-check-php.sh"

command -v git >/dev/null || { echo "SKIP: git not on PATH"; exit 0; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

expect() { # expect <label> <want> <got>
  [ "$2" = "$3" ] || { echo "FAIL: $1"; echo "  want: [$2]"; echo "  got:  [$3]"; exit 1; }
  echo "  ok: $1"
}

echo "--- unit: infection_config.py injects logs.json and keeps the rest ---"
cd "$WORK"
cat > infection.json <<'EOF'
{
  "source": { "directories": ["src"], "excludes": ["src/Generated"] },
  "mutators": { "@default": true },
  "bootstrap": "vendor/autoload.php"
}
EOF
python3 "$LIB/infection_config.py" infection.json merged.json /tmp/report-abs.json
field() { python3 -c "import json,sys;print(json.dumps(json.load(open('merged.json'))$1))"; }
expect "logs.json injected"    '"/tmp/report-abs.json"' "$(field "['logs']['json']")"
expect "source.directories kept" '["src"]'              "$(field "['source']['directories']")"
expect "source.excludes kept"  '["src/Generated"]'      "$(field "['source']['excludes']")"
expect "bootstrap kept"        '"vendor/autoload.php"'  "$(field "['bootstrap']")"
expect "mutators kept"         '{"@default": true}'     "$(field "['mutators']")"

echo "--- unit: an existing logs block keeps its other loggers ---"
cat > with-logs.json <<'EOF'
{ "source": { "directories": ["app"] }, "logs": { "text": "infection.log" } }
EOF
python3 "$LIB/infection_config.py" with-logs.json merged2.json /abs/r.json
expect "text logger survives injection" "infection.log" \
  "$(python3 -c "import json;print(json.load(open('merged2.json'))['logs']['text'])")"
expect "json logger added" "/abs/r.json" \
  "$(python3 -c "import json;print(json.load(open('merged2.json'))['logs']['json'])")"

echo "--- unit: an unparseable (json5) config is refused, not silently mangled ---"
printf '{\n  // a comment, legal json5, not json\n  "source": {"directories": ["src"]}\n}\n' > infection.json5
RC=0
OUT="$(python3 "$LIB/infection_config.py" infection.json5 merged3.json /abs/r.json 2>&1)" || RC=$?
[ "$RC" -ne 0 ] || { echo "FAIL: json5 config should be refused"; exit 1; }
echo "$OUT" | grep -qi "json5\|parse" || { echo "FAIL: refusal does not say why: $OUT"; exit 1; }
echo "  ok: json5 refused with a reason"

echo "--- e2e: no infection config is a setup problem (exit 2), not a pass ---"
REPO="$WORK/repo"
mkdir -p "$REPO/src"
cd "$REPO"
git init -q
cat > "$WORK/stub-noop" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$WORK/stub-noop"
RC=0
OUT="$(MUTATION_BASE=main MUTATION_FILES=src/Foo.php MUTATION_PHP_INFECTION="$WORK/stub-noop" "$MODULE" 2>&1)" || RC=$?
[ "$RC" -eq 2 ] || { echo "FAIL: expected exit 2 with no config, got $RC"; echo "$OUT"; exit 1; }
echo "$OUT" | grep -q "infection.json" || { echo "FAIL: message must name the config file"; echo "$OUT"; exit 1; }
echo "  ok: missing config refused with instructions"

echo "--- e2e: the merged config drives infection and survivors are reported ---"
cat > infection.json <<'EOF'
{ "source": { "directories": ["src"] } }
EOF
# The stub is infection: it proves the module passed -c, that the config it was
# handed names a JSON report, and that the report is picked up and parsed.
cat > "$WORK/stub-infection" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
CFG=""
prev=""
for a in "$@"; do
  case "$prev" in -c|--configuration) CFG="$a" ;; esac
  case "$a" in --configuration=*) CFG="${a#*=}" ;; esac
  prev="$a"
done
[ -n "$CFG" ] || { echo "stub: no -c passed" >&2; exit 90; }
[ -f "$CFG" ] || { echo "stub: config $CFG does not exist" >&2; exit 91; }
case "$*" in *--git-diff-lines*) ;; *) echo "stub: no --git-diff-lines" >&2; exit 92 ;; esac
case "$*" in *--logger-json*) echo "stub: --logger-json is not a valid 0.34 flag" >&2; exit 93 ;; esac
REPORT="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['logs']['json'])" "$CFG")"
cat > "$REPORT" <<JSON
{"stats":{"escapedCount":1},
 "escaped":[{"mutator":{"mutatorName":"Plus","originalFilePath":"$PWD/src/Calc.php","originalStartLine":11},
             "diff":"--- Original\n+++ New\n@@ @@\n-        return \$a + \$b;\n+        return \$a - \$b;\n"}],
 "uncovered":[]}
JSON
STUB
chmod +x "$WORK/stub-infection"
RC=0
OUT="$(MUTATION_BASE=main MUTATION_FILES=src/Calc.php MUTATION_PHP_INFECTION="$WORK/stub-infection" "$MODULE" 2>&1)" || RC=$?
echo "$OUT"
[ "$RC" -eq 0 ] || { echo "FAIL: expected exit 0 from a measured run, got $RC"; exit 1; }
echo "$OUT" | grep -q "src/Calc.php:11" || { echo "FAIL: survivor row missing or path not relativised"; exit 1; }
echo "$OUT" | grep -q "SURVIVED" || { echo "FAIL: no SURVIVED row"; exit 1; }
echo "$OUT" | grep -q -- "-        return" || { echo "FAIL: diff lines not shown"; exit 1; }

echo "--- e2e: the merged config is cleaned up and never left in the repo ---"
ls -1 "$REPO" | grep -q "infection-gate" && { echo "FAIL: merged config left behind"; ls -1 "$REPO"; exit 1; }
echo "  ok: no leftover config"

echo "--- e2e: a stub that writes no report is a loud failure, not a pass ---"
RC=0
OUT="$(MUTATION_BASE=main MUTATION_FILES=src/Calc.php MUTATION_PHP_INFECTION="$WORK/stub-noop" "$MODULE" 2>&1)" || RC=$?
[ "$RC" -eq 4 ] || { echo "FAIL: expected exit 4 when no report is produced, got $RC"; echo "$OUT"; exit 1; }
echo "$OUT" | grep -q "NOT a pass" || { echo "FAIL: missing the not-a-pass warning"; exit 1; }
echo "  ok: empty report reported as unmeasurable"

echo "--- e2e: mutants generated and all killed is distinct from none generated ---"
# Same empty escaped[]/uncovered[] shape both times; only stats.totalMutantsCount
# differs, which is the one signal that tells the two outcomes apart.
cat > "$WORK/stub-infection-killed" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
CFG=""
prev=""
for a in "$@"; do
  case "$prev" in -c|--configuration) CFG="$a" ;; esac
  prev="$a"
done
REPORT="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['logs']['json'])" "$CFG")"
cat > "$REPORT" <<'JSON'
{"stats":{"totalMutantsCount":3}, "escaped":[], "uncovered":[]}
JSON
STUB
chmod +x "$WORK/stub-infection-killed"
RC=0
OUT="$(MUTATION_BASE=main MUTATION_FILES=src/Calc.php MUTATION_PHP_INFECTION="$WORK/stub-infection-killed" "$MODULE" 2>&1)" || RC=$?
[ "$RC" -eq 0 ] || { echo "FAIL: expected exit 0, got $RC"; echo "$OUT"; exit 1; }
echo "$OUT" | grep -qE "generated 3 mutant\(s\) on changed lines, all killed" || { echo "FAIL: expected the all-killed message with the count"; echo "$OUT"; exit 1; }
echo "  ok: all-killed run names its count"

cat > "$WORK/stub-infection-empty" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
CFG=""
prev=""
for a in "$@"; do
  case "$prev" in -c|--configuration) CFG="$a" ;; esac
  prev="$a"
done
REPORT="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['logs']['json'])" "$CFG")"
cat > "$REPORT" <<'JSON'
{"stats":{"totalMutantsCount":0}, "escaped":[], "uncovered":[]}
JSON
STUB
chmod +x "$WORK/stub-infection-empty"
RC=0
OUT="$(MUTATION_BASE=main MUTATION_FILES=src/Calc.php MUTATION_PHP_INFECTION="$WORK/stub-infection-empty" "$MODULE" 2>&1)" || RC=$?
[ "$RC" -eq 0 ] || { echo "FAIL: expected exit 0, got $RC"; echo "$OUT"; exit 1; }
echo "$OUT" | grep -q "generated no mutants on changed lines" || { echo "FAIL: expected the no-mutants message"; echo "$OUT"; exit 1; }
echo "$OUT" | grep -q "killed" && { echo "FAIL: a zero-mutant run must not read as a kill"; echo "$OUT"; exit 1; }
echo "  ok: zero-mutant run is worded distinctly from all-killed"

echo "MUTATION PHP CONFIG OK"
