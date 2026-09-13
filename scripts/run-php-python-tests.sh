#!/usr/bin/env bash
# Run the suites scripts/run-go-tests.sh excludes: the ones that need a live
# PHP toolchain (infection, phpunit) or uv. This job installs both, so a SKIP
# line here means an unmet assumption, not a legitimate absence, same rule as
# run-go-tests.sh. Selection comes from the one NEEDS_OTHER_TOOLCHAIN list in
# scripts/lib/skill-suites.sh; a name in it that no longer exists on disk
# would otherwise shrink this job to fewer suites without anyone noticing.
#
# Exit 0 all green, 1 any suite failed, nothing discovered, or a stale name.

set -uo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/skill-suites.sh"

mapfile -t selected < <(select_suites other)
if [ "${#selected[@]}" -ne "${#NEEDS_OTHER_TOOLCHAIN[@]}" ]; then
  echo "!! expected ${#NEEDS_OTHER_TOOLCHAIN[@]} suite(s) (${NEEDS_OTHER_TOOLCHAIN[*]}), found ${#selected[@]} on disk" >&2
  exit 1
fi

printf '%s\n' "${selected[@]}" | run_suites "PHP/PYTHON"
