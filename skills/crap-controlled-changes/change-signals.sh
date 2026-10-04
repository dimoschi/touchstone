#!/usr/bin/env bash
# change-signals.sh: record the deterministic change-risk signals of one commit range.
#
#   change-signals.sh <absolute-repo-path> <base>..<head>
#
# Prints exactly three lines, TOUCHSTONE_SIGNALS <range>, one compact JSON line
# and TOUCHSTONE_SIGNALS_END. Nothing else goes to stdout or stderr on success,
# because whoever reads the output has to be able to tell that those three lines
# are all of it. The signals themselves, and what makes one unmeasured, are in
# lib/change_signals.py; this script only resolves the repo and hands over the
# settings that live in shell: the languages no tool here covers, the paths the
# repo's .crap-gated exempts, and the deadcode version the gates pin.
#
# Exit codes: 0 printed, 2 bad arguments or a range that does not resolve. It
# never exits 1: nothing here is a gate, and a signal that could not be measured
# says so in its own value.

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SKILL_DIR/lib"
. "$LIB_DIR/require-bash.sh"
. "$LIB_DIR/tool-versions.sh"
source "$LIB_DIR/repo-arg.sh"
source "$LIB_DIR/unsupported-sources.sh"

[ "$#" -eq 2 ] || {
  echo "usage: change-signals.sh <absolute-repo-path> <base>..<head>" >&2
  exit 2
}
case "$1" in
  /*) ;;
  *) echo "change-signals: repo path must be absolute, got '$1'" >&2; exit 2 ;;
esac

REPO_ROOT="$(resolve_repo_root change-signals "$1")" || exit 2
# See crap-check.sh's identical line: these outrank -C for every git call.
unset GIT_DIR GIT_WORK_TREE

# UNSUPPORTED_SPEC leaves shell out because the CRAP gate has nothing to say about it, but no
# signal tool reads shell either, so here a changed script is a file nothing measured.
SIGNALS_UNSUPPORTED_SPEC=("${UNSUPPORTED_SPEC[@]}" '*.sh' '*.bash' '*.zsh' '*.ksh')

TOUCHSTONE_UNSUPPORTED_SPEC="$(printf '%s\n' "${SIGNALS_UNSUPPORTED_SPEC[@]}")" \
TOUCHSTONE_EXEMPT_SPEC="$(crap_exempt_pathspecs "$REPO_ROOT")" \
TOUCHSTONE_DEADCODE_VERSION="${DEADCODE_GO_VERSION:-$DEADCODE_VERSION_DEFAULT}" \
  exec python3 "$LIB_DIR/change_signals.py" "$REPO_ROOT" "$2"
