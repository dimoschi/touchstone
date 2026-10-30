#!/usr/bin/env bash
# dup-check.sh: block a duplicate function this diff introduces.
#
# CRAP, dead code and mutation testing each judge a function alone, so a new
# function that is a copy of an old one with a few names changed passes all
# three. unclebob/dryer compares the normalized structure of every Go and Python
# function (names of locals, fields and literals do not count, call names and
# tree shape do) and scores a pair by Jaccard similarity. This reports a pair at
# or above the threshold when the staged diff is what created it.
#
# Only pairs the diff introduces are reported: a duplicate already at HEAD, in a
# file that is merely edited, moved or renamed, or one of whose copies is edited,
# never blocks. See lib/dup_scan.py.
#
#   dup-check.sh                      check the staged diff
#   dup-check.sh --accept '<key>'     record a user-approved exception
#   dup-check.sh --revoke '<key>'     drop one
#
# A key is "<side>|<side>", printed on each finding. Acceptance is per branch and
# needs explicit user approval: some duplication is deliberate (two handlers that
# are meant to stay in step), which is why the escape hatch is recorded rather
# than absent. It lapses when either function's structure changes, or when its
# file gains another copy of it.
#
# Runs only in a repo carrying .crap-gated, which also holds its settings:
#   duplication-threshold = 0.82   pairs scoring at or above this are reported
# and its exempt paths, which are left out of both sides of the comparison.
#
# Exit codes: 0 nothing introduced, 1 findings, 2 setup problem (no uv, dryer
# failed to import or run).

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SKILL_DIR/lib"
. "$LIB_DIR/require-bash.sh"
. "$LIB_DIR/tool-versions.sh"
. "$LIB_DIR/uv-pinned.sh"
source "$LIB_DIR/repo-arg.sh"
source "$LIB_DIR/unsupported-sources.sh"

REPO_ROOT="$(resolve_repo_root dup-check "${1:-}")" || exit 2
# See crap-check.sh's identical line: GIT_DIR/GIT_WORK_TREE outrank `cd` for
# every git call below, so an explicit path would silently lose to a caller's
# exported vars without this.
case "${1:-}" in /*) shift; unset GIT_DIR GIT_WORK_TREE ;; esac
cd "$REPO_ROOT"

BRANCH="$(git symbolic-ref --quiet --short HEAD || echo detached)"
STORE="$(git rev-parse --path-format=absolute --git-common-dir)/dup-accepted.json"

echo "dup-check: repo $REPO_ROOT branch $BRANCH"

if [ "${1:-}" = "--accept" ]; then
  [ -n "${2:-}" ] || { echo "usage: dup-check.sh --accept '<key>'" >&2; exit 2; }
  exec python3 "$LIB_DIR/dup_accepted.py" add "$STORE" "$BRANCH" "$2"
fi

if [ "${1:-}" = "--revoke" ]; then
  [ -n "${2:-}" ] || { echo "usage: dup-check.sh --revoke '<key>'" >&2; exit 2; }
  exec python3 "$LIB_DIR/dup_accepted.py" remove "$STORE" "$BRANCH" "$2"
fi

if [ ! -f "$REPO_ROOT/.crap-gated" ]; then
  echo "dup-check: this repo has no .crap-gated, so the duplication gate is not enabled"
  exit 0
fi

EXEMPT_SPEC=()
while IFS= read -r ex; do
  [ -n "$ex" ] && EXEMPT_SPEC+=("$ex")
done < <(crap_exempt_pathspecs "$REPO_ROOT")

# Generated code is not authored in this repo, and a copy there is not a finding.
# Tests, vendor/, testdata/ and the other directories dryer's own walk skips are
# left out by lib/dup_scan.py with dryer's rules, so the two cannot disagree.
DUP_SPEC=('*.go' '*.py'
          ':(exclude)*mock_*.go' ':(exclude)*_mock.go'
          ':(exclude)*.sql.go' ':(exclude)*.pb.go'
          ${EXEMPT_SPEC[@]+"${EXEMPT_SPEC[@]}"})

CHANGES_LIST="$(mktemp)"
POOL_LIST="$(mktemp)"
FOUND="$(mktemp)"
SCAN_ERR="$(mktemp)"
trap 'rm -f "$CHANGES_LIST" "$POOL_LIST" "$FOUND" "$SCAN_ERR"' EXIT

git -c core.quotePath=false diff --cached -M --name-status -- "${DUP_SPEC[@]}" > "$CHANGES_LIST"
if ! grep -qv '^D' "$CHANGES_LIST"; then
  echo "dup-check: no staged Go or Python files"
  exit 0
fi

pinned_ready dup-check dryer CRAP_DRYER_RUN "${CRAP_DRYER_RUN:-}" || exit 2

git -c core.quotePath=false ls-files -- "${DUP_SPEC[@]}" > "$POOL_LIST"
THRESHOLD="$(python3 "$LIB_DIR/thresholds.py" --repo-root "$REPO_ROOT" --show duplication)"

SCAN_STATUS=0
pinned_run dryer "$DRYER_SHA_DEFAULT" "${CRAP_DRYER_RUN:-}" "$LIB_DIR/dup_scan.py" \
  --root "$REPO_ROOT" --threshold "$THRESHOLD" --changes "$CHANGES_LIST" --pool "$POOL_LIST" \
  > "$FOUND" 2> "$SCAN_ERR" || SCAN_STATUS=$?
if [ "$SCAN_STATUS" -ne 0 ]; then
  {
    echo "dup-check: FAILED TO ANALYSE (exit $SCAN_STATUS)."
    echo "  This is NOT a pass: no duplication was compared, so none was ruled out."
    sed 's/^/    /' "$SCAN_ERR"
  } >&2
  exit 2
fi

REPORT_STATUS=0
REPORT="$(python3 "$LIB_DIR/dup_accepted.py" report "$STORE" "$BRANCH" < "$FOUND")" || REPORT_STATUS=$?
if [ "$REPORT_STATUS" -gt 1 ]; then
  echo "dup-check: FAILED TO ANALYSE - dup_accepted.py exited $REPORT_STATUS." >&2
  exit 2
fi

printf '%s\n' "$REPORT" | grep -v '^duplicates=' || true
COUNT="$(printf '%s\n' "$REPORT" | sed -n 's/^duplicates=//p')"

echo ""
echo "== NEXT_ACTION =="
if [ "$REPORT_STATUS" -eq 1 ]; then
  echo "DUPLICATION_INTRODUCED: $COUNT function pair(s) this diff adds are structural"
  echo "near-duplicates (score >= $THRESHOLD) of code already in the repo. Extract what they"
  echo "share, or reuse the existing function, rather than copying it. If the copy must"
  echo "stay (two handlers kept deliberately in step), surface it to the user; on their"
  echo "explicit approval record it with:"
  echo "  dup-check.sh --accept '<key>'"
  exit 1
fi
echo "DUPLICATION_OK"
