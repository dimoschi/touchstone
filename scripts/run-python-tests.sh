#!/usr/bin/env bash
# Run the unit suites for hooks/*.py and skills/crap-controlled-changes/lib/*.py
# under coverage, and enforce the floor crap-check-python.sh assumes (80% per
# function; this checks 90% combined across both directories, the same margin
# the ticket that added this script asked for).
#
# Neither coverage nor pytest need to be importable in the active environment:
# set CRAP_PY_RUN to a launcher prefix when they are not, e.g.
#   CRAP_PY_RUN="uv run --no-project --with coverage>=7.13.1 --with pytest --"
# No inner quotes around the version spec: this value is expanded unquoted
# below, and word splitting does not strip quote characters the way the shell
# does while parsing a script, so a quoted spec reaches uv as a literal string
# containing quote characters and fails to resolve.
# (the same variable skills/crap-controlled-changes/lib/crap-check-python.sh
# reads, so one setting covers both).
#
# Exit 0 every test passed and combined coverage is >= 90%, 1 otherwise.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CRAP_PY_RUN="${CRAP_PY_RUN:-}"

# Checked before the real run so a broken launcher is reported as that, not
# misread as "pytest reported failures" once coverage never runs at all.
if ! $CRAP_PY_RUN coverage --version >/dev/null 2>&1; then
  echo "!! 'coverage' not runnable via '${CRAP_PY_RUN:-<active env>}'" >&2
  echo "   Hint: install coverage.py + pytest in this environment, or set CRAP_PY_RUN" >&2
  echo "   to a launcher, e.g. CRAP_PY_RUN=\"uv run --no-project --with coverage>=7.13.1 --with pytest --\"." >&2
  exit 1
fi

$CRAP_PY_RUN coverage run -m pytest
TEST_STATUS=$?

$CRAP_PY_RUN coverage report --fail-under=90
COVERAGE_STATUS=$?

if [ "$TEST_STATUS" -ne 0 ]; then
  echo "!! pytest reported failures" >&2
  exit 1
fi
if [ "$COVERAGE_STATUS" -ne 0 ]; then
  echo "!! combined coverage over hooks/ and skills/crap-controlled-changes/lib/ is below 90%" >&2
  exit 1
fi

echo "ALL PYTHON SUITES OK"
