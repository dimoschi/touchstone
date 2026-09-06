#!/usr/bin/env bash
# Run every Go-dependent suite in skills/crap-controlled-changes/test/. These
# need a real Go toolchain, and two of them a real ssh signing key, so they are
# kept out of run-hook-tests.sh (python3 and git only) and run in their own CI
# job that installs Go and a throwaway key first.
#
# The suite list is not hand-maintained: it is every run*.sh guarding itself
# with `command -v go`, the same guard its siblings already use to skip when Go
# is absent. In this job every prerequisite is installed, so a suite printing a
# SKIP line has an unmet assumption, not a legitimate skip, and is failed rather
# than let through quietly.
#
# Exit 0 all green, 1 any suite failed.

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../skills/crap-controlled-changes/test" && pwd)"
cd "$TEST_DIR"

failed=0
for suite in $(grep -lE 'command -v go[[:space:]]+>' run*.sh | sort); do
  echo "=============================================================="
  echo "== $suite"
  echo "=============================================================="
  OUT="$(bash "$suite" 2>&1)"
  STATUS=$?
  echo "$OUT"
  if [ "$STATUS" -ne 0 ]; then
    echo "!! $suite FAILED (exit $STATUS)"
    echo
    failed=$((failed + 1))
  elif printf '%s\n' "$OUT" | grep -qE '^[[:space:]]*(SKIP|skip):'; then
    echo "!! $suite FAILED (skipped instead of running)"
    echo
    failed=$((failed + 1))
  else
    echo
  fi
done

if [ "$failed" -eq 0 ]; then
  echo "ALL GO SUITES OK"
else
  echo "FAILED: $failed suite(s)"
  exit 1
fi
