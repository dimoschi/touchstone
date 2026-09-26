#!/usr/bin/env bash
# Entry point for the fix-loop/workflow suites under workflows/tests/, split
# out of this file (gh-118) so each area stays under about 800 lines instead
# of one 4651-line script. Runs every workflows/tests/test-*.sh in turn; see
# workflows/tests/harness.sh for what each of those shares.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TESTS_DIR="$REPO_ROOT/workflows/tests"

shopt -s nullglob
files=("$TESTS_DIR"/test-*.sh)
shopt -u nullglob

if [ ${#files[@]} -eq 0 ]; then
  echo "FAILED: no workflows/tests/test-*.sh suites found" >&2
  exit 1
fi

failures=0
for f in "${files[@]}"; do
  echo ""
  echo "== running $(basename "$f")"
  bash "$f"
  status=$?
  if [ "$status" -ne 0 ]; then
    failures=$((failures + 1))
  fi
done

echo ""
if [ "$failures" -eq 0 ]; then
  echo "OK (all workflows/tests suites)"
  exit 0
else
  echo "FAILED: $failures suite(s) failed"
  exit 1
fi
