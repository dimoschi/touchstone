#!/usr/bin/env bash
# Report a check() assertion in the workflow test suites that no counterfactual
# production script makes fail: new or changed since a base revision, and
# still passing at head, but neither reverting to the base revision's own
# workflows/deliver-pipeline.js nor any mutant of what the diff added to it
# ever fails it.
#
#   scripts/check-assertions-discriminate.sh [<repo>] [--base <rev>] [--head <rev>]
#
# Base/head default resolution mirrors scripts/check-version-bump.sh: merge-base
# of origin/main (falling back to main) and HEAD, refusing a shallow clone for
# the same reason that script does -- a graft point would silently narrow the
# range. The first line of output is the repo, base and head resolved.
#
# Read-only and deterministic: every tree it inspects is a `git archive`
# extraction into a temp directory, never this repo's own worktree or .git.
#
# Exit 0 nothing to report, 1 something reported, 2 setup problem, 4 a
# selected suite printed no check record at all when run at head.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"

REPO=""
BASE=""
HEAD=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --base) BASE="$2"; shift 2 ;;
    --head) HEAD="$2"; shift 2 ;;
    /*) REPO="$1"; shift ;;
    *)
      echo "check-assertions-discriminate: unrecognized argument: $1" >&2
      exit 2
      ;;
  esac
done

if [ -n "$REPO" ]; then
  [ -d "$REPO" ] || { echo "check-assertions-discriminate: no such directory: $REPO" >&2; exit 2; }
  REPO="$(git -C "$REPO" rev-parse --show-toplevel 2>/dev/null)" || {
    echo "check-assertions-discriminate: not a git repository: $REPO" >&2
    exit 2
  }
else
  REPO="$(git rev-parse --show-toplevel 2>/dev/null)" || {
    echo "check-assertions-discriminate: not inside a git repo" >&2
    exit 2
  }
fi

if [ -z "$HEAD" ]; then
  HEAD="$(git -C "$REPO" rev-parse HEAD)"
fi

if [ -z "$BASE" ]; then
  if [ "$(git -C "$REPO" rev-parse --is-shallow-repository)" = "true" ]; then
    echo "check-assertions-discriminate: shallow clone, cannot resolve a merge base reliably (run with full history: fetch-depth: 0)" >&2
    exit 2
  fi
  BASE_REF=""
  for ref in origin/main main; do
    if git -C "$REPO" rev-parse -q --verify "$ref" >/dev/null 2>&1; then
      BASE_REF="$ref"
      break
    fi
  done
  [ -n "$BASE_REF" ] || {
    echo "check-assertions-discriminate: no origin/main or main to compare against" >&2
    exit 2
  }
  BASE="$(git -C "$REPO" merge-base "$BASE_REF" "$HEAD")" || {
    echo "check-assertions-discriminate: $HEAD and $BASE_REF share no common history" >&2
    exit 2
  }
fi

BASE_SHA="$(git -C "$REPO" rev-parse "$BASE" 2>/dev/null)" || {
  echo "check-assertions-discriminate: no such revision: $BASE" >&2
  exit 2
}
HEAD_SHA="$(git -C "$REPO" rev-parse "$HEAD" 2>/dev/null)" || {
  echo "check-assertions-discriminate: no such revision: $HEAD" >&2
  exit 2
}

echo "check-assertions-discriminate: repo $REPO base $BASE_SHA head $HEAD_SHA"

python3 "$LIB_DIR/assertion_discrimination.py" "$REPO" "$BASE_SHA" "$HEAD_SHA"
