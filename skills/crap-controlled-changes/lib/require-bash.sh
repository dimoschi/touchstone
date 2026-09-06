#!/usr/bin/env bash
# Refuse to run on a bash older than 4.0, with a message that names the fix.
#
# The gates use associative arrays, mapfile-equivalent reads and other bash 4
# behaviour. macOS still ships bash 3.2 as /bin/bash, frozen in 2007, and this
# project does not support it: carrying it means a guarded-expansion idiom at
# every array use, forever, policed by review. Requiring a modern bash costs
# the user one install, once.
#
# Failing loudly here beats the alternative. Without this check the first
# symptom is `mapfile: command not found` or an `unbound variable` error deep
# inside a gate, which reads as a broken repo rather than a missing dependency.

if [ -z "${BASH_VERSINFO:-}" ] || [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  {
    echo "crap-controlled-changes: needs bash 4.0 or newer."
    echo "  running: ${BASH_VERSION:-not bash}"
    echo ""
    echo "  macOS ships bash 3.2 as /bin/bash and this project does not support it."
    echo "  Install a current bash and make sure it comes first on PATH:"
    echo ""
    echo "    brew install bash"
    echo ""
    echo "  Linux distributions already ship bash 5."
  } >&2
  exit 2
fi
