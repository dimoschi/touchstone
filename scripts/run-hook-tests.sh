#!/usr/bin/env bash
# Run every hook test suite. These need only python3 and git, so they are the
# part of the suite that runs anywhere; the skill's own tests under
# skills/crap-controlled-changes/test/ additionally need Go, PHP or Python
# toolchains and the mutation tools, and are run per language.
#
# Exit 0 all green, 1 any suite failed.

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../hooks"

failed=0
for suite in test-*.sh; do
  echo "=============================================================="
  echo "== $suite"
  echo "=============================================================="
  if bash "$suite"; then
    echo
  else
    echo "!! $suite FAILED"
    echo
    failed=$((failed + 1))
  fi
done

if [ "$failed" -eq 0 ]; then
  echo "ALL HOOK SUITES OK"
else
  echo "FAILED: $failed suite(s)"
  exit 1
fi
