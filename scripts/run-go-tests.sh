#!/usr/bin/env bash
# Run every suite in skills/crap-controlled-changes/test/ this job can run.
# The job installs a Go toolchain, python3, and a throwaway ssh signing key,
# so that covers everything except the suites that need a live PHP toolchain
# (infection, phpunit) or uv. Those run in scripts/run-php-python-tests.sh
# instead, via the shared selection in scripts/lib/skill-suites.sh.
#
# Exit 0 all green, 1 any suite failed (including: nothing was discovered).

set -uo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/skill-suites.sh"

select_suites go | run_suites GO
