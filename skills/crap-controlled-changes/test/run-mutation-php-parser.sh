#!/usr/bin/env bash
# Unit test for parse_infection.py against a schema-faithful fixture
# (infection 0.34 JsonReporter shape). Infection itself is not run: PHP is
# not assumed on the test machine.

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PARSER="$SKILL_DIR/lib/parse_infection.py"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/report.json" <<'EOF'
{
  "stats": {"totalMutantsCount": 3, "killedCount": 1, "escapedCount": 1,
            "notCoveredCount": 1, "msi": 33.3},
  "escaped": [
    {
      "mutator": {
        "mutatorName": "GreaterThan",
        "originalSourceCode": "<?php if ($x > 10) { return 'big'; }",
        "mutatedSourceCode": "<?php if ($x >= 10) { return 'big'; }",
        "originalFilePath": "/repo/src/Branchy.php",
        "originalStartLine": 14
      },
      "diff": "--- Original\n+++ New\n@@ @@\n-        if ($x > 10) {\n+        if ($x >= 10) {\n",
      "processOutput": ""
    }
  ],
  "uncovered": [
    {
      "mutator": {
        "mutatorName": "ReturnRemoval",
        "originalFilePath": "/repo/src/Branchy.php",
        "originalStartLine": 20
      },
      "diff": ""
    }
  ],
  "killed": [
    {
      "mutator": {
        "mutatorName": "LessThan",
        "originalFilePath": "/repo/src/Branchy.php",
        "originalStartLine": 14
      }
    }
  ]
}
EOF

OUT="$(python3 "$PARSER" "$WORK/report.json" /repo)"
echo "$OUT"

FAILURES=0
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

grep -q 'src/Branchy.php:14.*GreaterThan.*SURVIVED' <<< "$OUT" || fail "escaped row missing"
grep -q 'id=GreaterThan@src/Branchy.php:14' <<< "$OUT" || fail "synthetic id missing"
grep -q 'src/Branchy.php:20.*ReturnRemoval.*SURVIVED' <<< "$OUT" || fail "uncovered row missing"
grep -q -- '-        if ($x > 10) {' <<< "$OUT" || fail "diff detail missing"
grep -q 'LessThan' <<< "$OUT" && fail "killed mutant leaked into rows"
[ "$(grep -c ' SURVIVED' <<< "$OUT")" -eq 2 ] || fail "expected exactly 2 survivor rows"

[ "$FAILURES" -gt 0 ] && { echo "$FAILURES failure(s)"; exit 1; }
echo "PHP PARSER OK"
