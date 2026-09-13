#!/usr/bin/env bash
# crap-check.sh: language-agnostic dispatcher for the CRAP pre-commit check.
# Detects the languages of staged files and delegates to lib/crap-check-<lang>.sh.
# Each language module emits the same row format:
#   <id>  complexity=<c>  coverage=<cov>%  CRAP=<score>  <STATUS>  (<tag>)
# The rows are then fed to lib/next_action.py, which applies the Decision
# Policy and prints a single NEXT_ACTION directive (WRITE_TESTS / REFACTOR /
# SURFACE_TO_USER / COMMIT_OK). Follow the directive literally.
#
# Exit codes: 0 gate green (COMMIT_OK), 1 gate red (see NEXT_ACTION),
# 2 setup problem, 5 nothing staged but the branch carries unscored source.
# Modules add: 3 stash restore failed, 4 could not measure.
#
# crap-check.sh --accept '<function-id>' records a user-approved score after
# a SURFACE_TO_USER directive; only run it on explicit user approval.
#
# crap-check.sh --mark-scored records the branch's current source as scored
# WITHOUT measuring it, to adopt the gate on a branch whose commits predate it.
# It is an override, not a pass; only run it on explicit user approval.
#
# CRAP_BASE overrides the branch diff base (default: origin/HEAD, then main,
# then master).

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SKILL_DIR/lib"
. "$LIB_DIR/require-bash.sh"
source "$LIB_DIR/head-pairs.sh"
source "$LIB_DIR/tool-versions.sh"
source "$LIB_DIR/tool-fingerprint.sh"
source "$LIB_DIR/unsupported-sources.sh"

crap_fingerprint() {
  tool_fingerprint "$1" gocrap "${CRAP_GO_GOCRAP_VERSION:-$GOCRAP_VERSION_DEFAULT}"
}

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "crap-check: not inside a git repo" >&2
  exit 2
}
cd "$REPO_ROOT"

STATE_FILE="$(git rev-parse --git-dir)/crap-check-state.json"
BRANCH="$(git symbolic-ref --quiet --short HEAD || echo detached)"

# Per-path blob SHAs of source a green run actually scored. Content-addressed,
# so it survives amend, rebase, and unrelated commits landing in between; a
# file edited after being scored no longer matches. In the common git dir, so a
# per-ticket worktree does not take the record away with it when it is removed.
LEDGER="$(git rev-parse --git-common-dir)/crap-check-scored.json"
# Where it used to live. Read-only, so a worktree that scored before the move
# keeps its measurement instead of being told to re-measure content it did score.
LEGACY_LEDGER="$(git rev-parse --git-dir)/crap-check-scored.json"
LEGACY_ARGS=()
[ "$LEGACY_LEDGER" != "$LEDGER" ] && [ -f "$LEGACY_LEDGER" ] &&
  LEGACY_ARGS=(--legacy "$LEGACY_LEDGER")

if [ "${1:-}" = "--accept" ]; then
  [ -n "${2:-}" ] || { echo "usage: crap-check.sh --accept '<function-id>'" >&2; exit 2; }
  exec python3 "$LIB_DIR/next_action.py" --state-file "$STATE_FILE" --branch "$BRANCH" --accept "$2"
fi

# These excludes control *selection* (what gets scored) only. They have no
# bearing on the baseline stash: an excluded file still sits in the working
# tree during the baseline phase and still has to compile. See lib/ignored-files.sh.
#
# The marker's own exempt patterns apply here too, not only to the unsupported-
# language check below: a repo can carry Go/PHP/Python source it structurally
# cannot score (a fixture copied into a throwaway git repo to test this gate
# itself, a standalone helper script with no enclosing module) and .crap-gated
# is already the one place a repo lists what it excludes from measurement.
EXEMPT_SPEC=()
while IFS= read -r ex; do
  [ -n "$ex" ] && EXEMPT_SPEC+=("$ex")
done < <(crap_exempt_pathspecs "$REPO_ROOT")

GO_SPEC=('*.go' ':(exclude)*_test.go' ':(exclude)*mock_*.go' ':(exclude)*.sql.go' ':(exclude)*.pb.go' ${EXEMPT_SPEC[@]+"${EXEMPT_SPEC[@]}"})
PHP_SPEC=('*.php' ':(exclude)tests/**' ':(exclude)**/Tests/**' ':(exclude)**/*Test.php' ${EXEMPT_SPEC[@]+"${EXEMPT_SPEC[@]}"})
PY_SPEC=('*.py' ':(exclude)**/test_*.py' ':(exclude)**/*_test.py'
         ':(exclude)tests/**' ':(exclude)**/tests/**'
         ':(exclude)conftest.py' ':(exclude)**/conftest.py' ${EXEMPT_SPEC[@]+"${EXEMPT_SPEC[@]}"})

resolve_base() {
  local b="${CRAP_BASE:-}" cand
  if [ -z "$b" ]; then
    for cand in "$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD || true)" main master; do
      [ -n "$cand" ] || continue
      if git rev-parse --verify --quiet "$cand^{commit}" >/dev/null; then b="$cand"; break; fi
    done
  fi
  printf '%s' "$b"
}

# Measurable paths against any diff target ("--cached", or a range).
measurable_names() {
  git diff --name-only "$@" -- "${GO_SPEC[@]}"  2>/dev/null || true
  git diff --name-only "$@" -- "${PHP_SPEC[@]}" 2>/dev/null || true
  git diff --name-only "$@" -- "${PY_SPEC[@]}"  2>/dev/null || true
}

# "<path> <blob>" for the index version of each path on stdin.
staged_pairs() {
  local p blob
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    blob="$(git rev-parse ":$p" 2>/dev/null || true)"
    [ -n "$blob" ] && printf '%s %s\n' "$p" "$blob"
  done
  return 0
}

# The range that defines "source this branch is responsible for". Falls back to
# the last commit when no base can be resolved, so a missing origin degrades to
# the old narrow check rather than to silence.
branch_range() {
  local base
  base="$(resolve_base)"
  if [ -n "$base" ]; then printf '%s...HEAD' "$base"; else printf 'HEAD~1 HEAD'; fi
}

# Sets RANGE and PAIRS to the branch's source and the range they came from.
#
# On the base branch itself, with no remote to diff against, or on a branch with
# no commits of its own yet, base...HEAD is empty. That must not read as "nothing
# to check": fall back to the last commit, which is what this guard looked at
# before it became branch-wide.
#
# Both the verify path and --mark-scored resolve through here, and must: while
# only verify applied the fallback, --mark-scored on a branch cut from a merge
# recorded zero pairs and still reported success, so the override it exists to
# provide silently did nothing and verify went on refusing.
resolve_branch_pairs() {
  read -r -a RANGE <<< "$(branch_range)"
  PAIRS="$(measurable_names "${RANGE[@]}" | head_pairs HEAD)"
  # A merge commit authors nothing. Its diff against its first parent is the
  # merged branch's work, which was scored on that branch under that branch's
  # name, so charging it to whoever commits next here is a false positive that
  # fires after every single merge to a base branch. Nothing to fall back to.
  if [ -z "$PAIRS" ] && git rev-parse --verify --quiet 'HEAD^2' >/dev/null; then
    return 0
  fi
  if [ -z "$PAIRS" ] && [ "${RANGE[0]}" != "HEAD~1" ]; then
    RANGE=(HEAD~1 HEAD)
    PAIRS="$(measurable_names "${RANGE[@]}" | head_pairs HEAD)"
  fi
}

# Called by crap-commit.sh once the commit exists, which is the only moment the
# shared record can name the commit that carries the blob it vouches for.
if [ "${1:-}" = "--anchor-committed" ]; then
  git rev-parse --verify --quiet 'HEAD~1' >/dev/null || exit 0
  PAIRS="$(measurable_names HEAD~1 HEAD | head_pairs HEAD)"
  [ -n "$PAIRS" ] || exit 0
  printf '%s\n' "$PAIRS" \
    | python3 "$LIB_DIR/scored_ledger.py" anchor "$LEDGER" "$BRANCH" \
      --commit "$(git rev-parse HEAD)" \
      --tools "$(crap_fingerprint "$(printf '%s\n' "$PAIRS" | cut -d' ' -f1)")" >/dev/null
  exit 0
fi

if [ "${1:-}" = "--mark-scored" ]; then
  resolve_branch_pairs
  if [ -z "$PAIRS" ]; then
    echo "crap-check: nothing to mark; no measurable source in ${RANGE[*]}." >&2
    exit 2
  fi
  printf '%s\n' "$PAIRS" \
    | python3 "$LIB_DIR/scored_ledger.py" record "$LEDGER" "$BRANCH" marked >/dev/null
  echo "crap-check: recorded the branch's current source as scored WITHOUT measuring it."
  echo "  This is a user override to adopt the gate on pre-existing commits, not a pass."
  exit 0
fi

GO_FILES="$(git diff --name-only --cached -- "${GO_SPEC[@]}" || true)"
PHP_FILES="$(git diff --name-only --cached -- "${PHP_SPEC[@]}" || true)"
PY_FILES="$(git diff --name-only --cached -- "${PY_SPEC[@]}" || true)"

# Checked before any module runs, so a mixed diff is refused too. The gate
# scores the staged diff as a whole and cannot certify one it only partly
# measured, so an unmeasurable file is refused whether or not Go, PHP or Python
# files sit beside it.
report_unsupported_sources "$REPO_ROOT" || exit 2

ran_any=0
CAPTURE="$(mktemp)"
trap 'rm -f "$CAPTURE"' EXIT

run_module() {
  local lang="$1" files="$2" module="$3"
  if [ -z "$files" ]; then return 0; fi
  if [ ! -x "$module" ]; then
    echo "crap-check: missing module $module" >&2
    return 2
  fi
  if [ "$ran_any" -eq 1 ]; then echo ""; fi
  echo "== $lang =="
  CRAP_FILES="$files" "$module" | tee -a "$CAPTURE"
  ran_any=1
}

run_module go     "$GO_FILES"  "$LIB_DIR/crap-check-go.sh"
run_module php    "$PHP_FILES" "$LIB_DIR/crap-check-php.sh"
run_module python "$PY_FILES"  "$LIB_DIR/crap-check-python.sh"

if [ "$ran_any" -eq 1 ]; then
  echo ""
  NA_STATUS=0
  python3 "$LIB_DIR/next_action.py" --state-file "$STATE_FILE" --branch "$BRANCH" \
    < "$CAPTURE" || NA_STATUS=$?
  # Only a green gate licenses the commit that follows, so only record then.
  if [ "$NA_STATUS" -eq 0 ]; then
    printf '%s\n' "$GO_FILES" "$PHP_FILES" "$PY_FILES" | staged_pairs \
      | python3 "$LIB_DIR/scored_ledger.py" record "$LEDGER" "$BRANCH" measured >/dev/null
  fi
  exit "$NA_STATUS"
fi

# Nothing staged is only a clean no-op if the branch does not already carry
# source that was never scored: agents are told to run this *before* committing,
# and if that order slips this looks identical to a pass unless we check. The
# comparison is per-file blob identity against the ledger, so a docs/test/config
# commit adds nothing measurable and passes, while source that reached a commit
# without a green run is named individually.
resolve_branch_pairs

if [ -z "$PAIRS" ]; then
  echo "crap-check: no staged source files in supported languages (go, php, python)"
  exit 0
fi

VERDICT=0
LEDGER_OUT="$(printf '%s\n' "$PAIRS" | python3 "$LIB_DIR/scored_ledger.py" \
  verify "$LEDGER" "$BRANCH" --borrow --head HEAD "${LEGACY_ARGS[@]}" \
  --tools "$(crap_fingerprint "$(printf '%s\n' "$PAIRS" | cut -d' ' -f1)")")" || VERDICT=$?

if [ "$VERDICT" -eq 0 ]; then
  echo "crap-check: no staged source files; this branch's source was already scored"
  # An adoption satisfies the gate but is not a measurement, so say which files
  # got through on one. Without this the two are indistinguishable at the point
  # where someone decides whether to trust the pass.
  MARKED="$(printf '%s\n' "$LEDGER_OUT" | sed -n 's/^marked=/    /p')"
  if [ -n "$MARKED" ]; then
    echo "  adopted with --mark-scored, never measured:"
    printf '%s\n' "$MARKED"
  fi
  BORROWED="$(printf '%s\n' "$LEDGER_OUT" | sed -n 's/^borrowed=/    /p')"
  if [ -n "$BORROWED" ]; then
    echo "  borrowed: scored on a reachable commit, same blob and analyzer:"
    printf '%s\n' "$BORROWED"
  fi
  exit 0
fi

{
  echo "crap-check: nothing was measured. Nothing is staged, but the HEAD commit"
  echo "  ($(git log -1 --format='%h %s' 2>/dev/null)) or an earlier one on this"
  echo "  branch (vs ${RANGE[*]}) carries source with no green scoring on record:"
  printf '%s\n' "$LEDGER_OUT" | sed -n 's/^unscored=/    /p'
  echo ""
  if printf '%s\n' "$LEDGER_OUT" | grep -q '^branch_unknown=1$'; then
    echo "  Nothing has ever been scored on this branch. If these commits predate"
    echo "  the gate, ask the user to adopt it with:  crap-check.sh --mark-scored"
  else
    echo "  These files changed after they were scored, or were never staged during"
    echo "  a run. Re-stage them and re-run, or amend/reset so they can be scored."
  fi
} >&2
exit 5
