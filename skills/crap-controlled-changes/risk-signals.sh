#!/usr/bin/env bash
# risk-signals.sh: deterministic change-risk signals for a commit range.
#
#   risk-signals.sh [<absolute-repo-path>] <base>..<head>
#
# Prints three lines and exits 0:
#
#   TOUCHSTONE_RISK_SIGNALS <range>
#   {"signals": {...}}
#   TOUCHSTONE_RISK_SIGNALS_END
#
# The JSON line holds one entry per signal: how much a range adds and removes,
# how many files and directories it touches, whether it changes a dependency
# manifest, whether it is a semantic no-op, breaks a public API, adds a security
# finding, changes code a main package reaches, how complex and untested the
# changed functions were, and whether an earlier run left a defect open in a path
# it changes. An entry is {"value": ..., "evidence": ...}, or {"value":
# "unmeasured", "reason": ...} when a tool is missing, fails, or has no support
# for a language in the diff. Nothing here is a judgement: no model decides any
# of it, and nothing is read from a path convention.
#
# Exit 2, with no markers on stdout, for a bad argument, a path that is not a
# repository, or a range that does not resolve.
#
# The tools themselves are optional and looked up on PATH: difft, apidiff, griffe,
# roave-backward-compatibility-check, gosec, bandit, opengrep and deadcode.

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SKILL_DIR/lib"
. "$LIB_DIR/require-bash.sh"
source "$LIB_DIR/repo-arg.sh"

REPO_ARG=""
case "$#" in
  1) ;;
  2) REPO_ARG="$1"; shift ;;
  *) echo "usage: risk-signals.sh [<absolute-repo-path>] <base>..<head>" >&2; exit 2 ;;
esac

REPO_ROOT="$(resolve_repo_root risk-signals "$REPO_ARG")" || exit 2
unset GIT_DIR GIT_WORK_TREE

exec python3 "$LIB_DIR/risk_signals.py" "$REPO_ROOT" "$1"
