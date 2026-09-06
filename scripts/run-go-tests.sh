#!/usr/bin/env bash
# Run every suite in skills/crap-controlled-changes/test/ this job can run.
# The job installs a Go toolchain, python3, and a throwaway ssh signing key,
# so that covers everything except the suites that need a live PHP toolchain
# (infection, phpunit) or uv. Those stay out of run-hook-tests.sh (python3 and
# git only) and this job alike, until a job installs them.
#
# Selection is by exclusion, not by grepping for a `command -v go` guard: that
# rule could never match run-go-modules.sh, which tests Go module resolution in
# pure Python and so never carried the guard. A new suite now runs here by
# default and opts out by name instead.
#
# In this job every prerequisite the selected suites need is installed, so a
# suite printing a SKIP line has an unmet assumption, not a legitimate skip,
# and is failed rather than let through quietly.
#
# Exit 0 all green, 1 any suite failed (including: nothing was discovered).

set -uo pipefail
shopt -s nullglob

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../skills/crap-controlled-changes/test" && pwd)"
if [ -z "$TEST_DIR" ]; then
  echo "!! could not resolve skills/crap-controlled-changes/test" >&2
  exit 1
fi
cd "$TEST_DIR" || { echo "!! cd $TEST_DIR failed" >&2; exit 1; }

# Needs a live php ^8.3 + infection + phpunit, or uv; this job installs neither.
NEEDS_OTHER_TOOLCHAIN=(run-mutation-php-live.sh run-mutation-python.sh run-python-e2e.sh)

all_suites=(run*.sh)
suites=()
# Guard both expansions below: under `set -u`, bash before 4.4 treats a
# zero-element array's "${arr[@]}" as unbound, and the repo's floor is 4.0.
if [ "${#all_suites[@]}" -gt 0 ]; then
  mapfile -t all_suites < <(printf '%s\n' "${all_suites[@]}" | sort)
  for suite in "${all_suites[@]}"; do
    skip=0
    for excluded in "${NEEDS_OTHER_TOOLCHAIN[@]}"; do
      [ "$suite" = "$excluded" ] && { skip=1; break; }
    done
    [ "$skip" -eq 0 ] && suites+=("$suite")
  done
fi

if [ "${#suites[@]}" -eq 0 ]; then
  echo "!! no suites discovered in $TEST_DIR" >&2
  exit 1
fi

failed=0
for suite in "${suites[@]}"; do
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
  elif grep -qE '^[[:space:]]*(SKIP|skip):' <<<"$OUT"; then
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
