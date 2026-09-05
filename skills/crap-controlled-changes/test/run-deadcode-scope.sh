#!/usr/bin/env bash
# Tests lib/deadcode_scope.py's package_of, which maps a repo-relative Go file
# to the import path of its package.
#
# Regression: a file at the module root has an empty dirname, and
# os.path.relpath('', ...) raises ValueError instead of returning '.'. That
# crashed the gate for every single-module repo keeping Go files at the module
# root, which is the most common Go layout there is. Worse, the caller
# redirected this script's stderr and died on the non-zero exit before reading
# it, so the crash reached the user as exit 1 with no output at all, and
# crap-commit.sh reported that as a red gate. It was found by running the gate
# against a real repo, not by any unit test, so this one exists to keep it shut.
#
# Pure Python, so it needs no Go toolchain and runs anywhere.

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
failures=0

check() {
  local label="$1" want="$2" got="$3"
  if [ "$got" = "$want" ]; then
    printf '  ok:   %-50s %s\n' "$label" "$got"
  else
    printf '  FAIL: %-50s got %s want %s\n' "$label" "$got" "$want"
    failures=$((failures + 1))
  fi
}

pkg() {
  python3 -c '
import sys
sys.path.insert(0, sys.argv[1])
from deadcode_scope import package_of
try:
    print(package_of(sys.argv[2], sys.argv[3], sys.argv[4]))
except Exception as exc:
    print(f"{type(exc).__name__}: {exc}")
' "$SKILL_DIR/lib" "$1" "$2" "$3"
}

echo "a file at the module root maps to the module path itself"
check "root file, module dir '.'"   "example.com/x" "$(pkg 'main.go'      '.' 'example.com/x')"
check "root file, module dir ''"    "example.com/x" "$(pkg 'main.go'      ''  'example.com/x')"

echo "a file in a subpackage appends the relative directory"
check "one level down"  "example.com/x/internal"       "$(pkg 'internal/a.go'          '.'  'example.com/x')"
check "two levels down" "example.com/x/internal/parse" "$(pkg 'internal/parse/p.go'    '.'  'example.com/x')"

echo "a nested module strips its own directory prefix"
check "file at nested module root" "example.com/svc"         "$(pkg 'svc/svc.go'            'svc' 'example.com/svc')"
check "file inside nested module"  "example.com/svc/handler" "$(pkg 'svc/handler/h.go'      'svc' 'example.com/svc')"

echo ""
if [ "$failures" -eq 0 ]; then
  echo "DEADCODE SCOPE OK"
else
  echo "FAILED: $failures assertion(s)"
  exit 1
fi
