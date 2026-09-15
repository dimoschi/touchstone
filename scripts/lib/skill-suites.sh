#!/usr/bin/env bash
# Shared suite discovery for scripts/run-go-tests.sh and
# scripts/run-php-python-tests.sh. Sourced, not executed: assumes the caller
# has already set -uo pipefail and defines TEST_DIR, NEEDS_OTHER_TOOLCHAIN,
# select_suites and run_suites for the sourcing script to call.
#
# NEEDS_OTHER_TOOLCHAIN names every skill test/run*.sh suite that needs a live
# PHP toolchain or uv, neither of which the go job installs. select_suites
# partitions by exclusion against that one list, not by grepping each suite for
# a `command -v go`/`uv` guard: that rule could never match run-go-modules.sh,
# which tests Go module resolution in pure Python and so never carried one. A
# new suite opts into the go side by default and only opts out by being added
# to the list, so the two runners stay complements of a single discovery.
#
# run_suites treats a `SKIP:`/`skip:` line as a failure: every prerequisite the
# suites it is given need is installed in their own job, so a skip there means
# an unmet assumption, not a legitimate absence.

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../skills/crap-controlled-changes/test" && pwd)"
if [ -z "$TEST_DIR" ]; then
  echo "!! could not resolve skills/crap-controlled-changes/test" >&2
  exit 1
fi
cd "$TEST_DIR" || { echo "!! cd $TEST_DIR failed" >&2; exit 1; }

shopt -s nullglob

NEEDS_OTHER_TOOLCHAIN=(run-mutation-php-live.sh run-mutation-python.sh run-python-e2e.sh
  run-python-subproject.sh run-python-multiproject.sh run-python-root-project.sh
  run-python-baseline-unmeasured.sh)

select_suites() {
  local want="$1"
  local all_suites=(run*.sh)
  local suite excluded matched
  # Zero-element "${arr[@]}" is unbound under `set -u` before bash 4.4; the
  # repo's floor is 4.0.
  [ "${#all_suites[@]}" -gt 0 ] || return 0
  mapfile -t all_suites < <(printf '%s\n' "${all_suites[@]}" | sort)
  for suite in "${all_suites[@]}"; do
    matched=0
    for excluded in "${NEEDS_OTHER_TOOLCHAIN[@]}"; do
      [ "$suite" = "$excluded" ] && { matched=1; break; }
    done
    if [ "$want" = go ] && [ "$matched" -eq 0 ]; then
      printf '%s\n' "$suite"
    elif [ "$want" = other ] && [ "$matched" -eq 1 ]; then
      printf '%s\n' "$suite"
    fi
  done
}

run_suites() {
  local label="$1"
  local -a suites=()
  local suite out status failed=0

  mapfile -t suites
  if [ "${#suites[@]}" -eq 0 ]; then
    echo "!! no suites discovered in $TEST_DIR" >&2
    exit 1
  fi

  for suite in "${suites[@]}"; do
    echo "=============================================================="
    echo "== $suite"
    echo "=============================================================="
    out="$(bash "$suite" 2>&1)"
    status=$?
    echo "$out"
    if [ "$status" -ne 0 ]; then
      echo "!! $suite FAILED (exit $status)"
      echo
      failed=$((failed + 1))
    elif grep -qE '^[[:space:]]*(SKIP|skip):' <<<"$out"; then
      echo "!! $suite FAILED (skipped instead of running)"
      echo
      failed=$((failed + 1))
    else
      echo
    fi
  done

  if [ "$failed" -eq 0 ]; then
    echo "ALL $label SUITES OK"
  else
    echo "FAILED: $failed suite(s)"
    exit 1
  fi
}
