#!/usr/bin/env bash
# mutation-check.sh: pre-PR mutation-testing check, sibling of crap-check.sh.
# Runs deterministic mutation testers scoped to the lines changed vs the diff
# base and reports surviving mutants as normalized rows:
#   <file>:<line>  <mutator>  SURVIVED  id=<id>
# followed by a NEXT_ACTION directive. Stateless by design: unlike the CRAP
# gate there are no attempt counters, survivors either exist or they don't.
#
# Run this after the CRAP gate is green and the branch work is committed,
# before opening a PR. Not wired into the commit hook: a full mutation run
# costs one test-suite run per mutant.
#
# Exit codes: 0 no survivors (MUTATION_OK, or MUTATION_UNMEASURED when nothing
# was actually generated to kill), 1 survivors (KILL_SURVIVORS), 2 setup
# problem, 4 could not measure, 5 --verify found unrecorded paths.
#
# MUTATION_BASE overrides the diff base (default: origin/HEAD, then main,
# then master).
#
# MUTATION_ONLY restricts a pass to changed paths matching one of its
# whitespace-separated globs, for a module whose tests split across mutually
# exclusive builds. The ledger is per path, so scoped passes accumulate.
#
# mutation-check.sh --accept '<id>' records a user-approved equivalent
# mutant (id= token from a SURVIVED row); only run it on explicit user
# approval. Acceptance is per branch and keys on the mutant id, which
# changes when the surrounding code changes, so it self-invalidates.
#
# A run measures only what the branch has dirtied since its last green run, and
# says so. The ledger is keyed per path, so an untouched blob's record still
# stands and re-measuring it produces the same claim; see lib/incremental_scope.py
# for what a changed test invalidates beyond itself. mutation-check.sh --full
# measures every changed source instead, which is what you want when something
# outside the ledger's key can change a verdict: a fixture, a compose file, a
# toolchain pin.
#
# mutation-check.sh --verify [branch]: checks the mutation ledger (see below)
# instead of running any mutants; returns in milliseconds. Meant for a
# PreToolUse hook gating a merge/push/PR, where a full run is too slow and too
# late. Without a branch, verifies HEAD; with one, verifies that branch's diff
# against BASE instead (for gating a merge before it happens, where HEAD is
# still the base branch).
#
# A green run records every changed path (source and test both, in every
# supported language) to a per-branch ledger keyed by git blob SHA, mirroring
# crap-check.sh's scored-blob ledger. --verify only trusts that record while
# every recorded path's content is still byte-for-byte what was measured.
#
# Records are filed under a shared namespace too, so a merge is free: blobs
# survive it. Borrowing needs a reachable measuring commit and matching tools.

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SKILL_DIR/lib"
. "$LIB_DIR/require-bash.sh"
source "$LIB_DIR/repo-arg.sh"
source "$LIB_DIR/head-pairs.sh"
source "$LIB_DIR/tool-versions.sh"
source "$LIB_DIR/tool-fingerprint.sh"
source "$LIB_DIR/unsupported-sources.sh"

mutation_fingerprint() {
  tool_fingerprint "$1" mutago "${MUTATION_GO_MUTAGO_VERSION:-$MUTAGO_VERSION_DEFAULT}"
}

REPO_ROOT="$(resolve_repo_root mutation-check "${1:-}")" || exit 2
# See crap-check.sh's identical line: GIT_DIR/GIT_WORK_TREE outrank `cd` for
# every git call below, so an explicit path would silently lose to a
# caller's exported vars without this.
case "${1:-}" in /*) shift; unset GIT_DIR GIT_WORK_TREE ;; esac
cd "$REPO_ROOT"

# The marker's exempt patterns apply here too, matching crap-check.sh and
# deadcode-check.sh. Without them a repo carrying both markers deadlocked: an
# exempted path was still mutated, the run that could not measure it recorded
# nothing, and --verify refused the PR naming a re-run that could never go green.
#
# Built here, not beside the selection further down, because --verify is the
# path the PR gate calls and it exits before reaching that point.
EXEMPT_SPEC=()
while IFS= read -r ex; do
  [ -n "$ex" ] && EXEMPT_SPEC+=("$ex")
done < <(crap_exempt_pathspecs "$REPO_ROOT")

# Shared across worktrees for the same reason as the ledger below, with one extra:
# this records a decision the *user* made, so losing it with a worktree means
# asking them to approve the same equivalent mutant twice. Acceptance keys on the
# mutant id, which changes when the surrounding code changes, so it still
# self-invalidates rather than outliving the code it was granted for.
ACCEPT_FILE="$(git rev-parse --git-common-dir)/mutation-accepted.json"
# The common git dir, not the per-worktree one: the ledger keys on git blobs, so
# a record is valid for byte-identical content whichever worktree measured it,
# and `git worktree remove` used to discard a green measurement whose branch then
# paid a full re-run in the next worktree.
LEDGER="$(git rev-parse --git-common-dir)/mutation-ledger.json"
BRANCH="$(git symbolic-ref --quiet --short HEAD || echo detached)"

# The verdict lives in the exit code, which a pipeline replaces with the last
# command's. Restating it as the final line means the answer survives `| tail`,
# and copying the rows out means the findings do too.
LOG="$(git rev-parse --path-format=absolute --git-common-dir)/mutation-check.log"

echo "mutation-check: repo $REPO_ROOT branch $BRANCH"

# Flips to 1 once a module's own "this is not a pass" line is seen, so the
# final verdict below does not read a zero-mutant run as MUTATION_OK.
ZERO_MUTANTS_RUN=0

summarise() {
  local code=$? verdict
  case "$code" in
    0) if [ "$ZERO_MUTANTS_RUN" -eq 1 ]; then verdict=MUTATION_UNMEASURED; else verdict=MUTATION_OK; fi ;;
    1) verdict=KILL_SURVIVORS ;;
    2) verdict=SETUP_FAILURE ;;
    *) verdict="see the output above" ;;
  esac
  if [ -n "${CAPTURE:-}" ] && [ -s "$CAPTURE" ]; then
    cp "$CAPTURE" "$LOG" 2>/dev/null || true
    verdict="$verdict; every mutant row is in $LOG"
  fi
  [ -n "${CAPTURE:-}" ] && rm -f "$CAPTURE" "$INVALIDATED"
  echo "mutation-check: EXIT=$code $verdict"
}
trap summarise EXIT

if [ "${1:-}" = "--accept" ]; then
  [ -n "${2:-}" ] || { echo "usage: mutation-check.sh --accept '<id>'" >&2; exit 2; }
  exec python3 "$LIB_DIR/mutation_accepted.py" add "$ACCEPT_FILE" "$BRANCH" "$2"
fi

BASE="${MUTATION_BASE:-}"
if [ -z "$BASE" ]; then
  for cand in "$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD || true)" main master; do
    [ -n "$cand" ] || continue
    if git rev-parse --verify --quiet "$cand^{commit}" >/dev/null; then
      BASE="$cand"
      break
    fi
  done
fi
[ -n "$BASE" ] || {
  echo "mutation-check: cannot determine a diff base; set MUTATION_BASE" >&2
  exit 2
}
export MUTATION_BASE="$BASE"

if [ "${1:-}" = "--verify" ]; then
  VERIFY_REF="${2:-HEAD}"
  VERIFY_BRANCH="${2:-$BRANCH}"
  PAIRS="$(git diff --name-only "$BASE...$VERIFY_REF" -- '*.go' '*.php' '*.py' \
    ${EXEMPT_SPEC[@]+"${EXEMPT_SPEC[@]}"} | head_pairs "$VERIFY_REF")"
  VERDICT=0
  LEDGER_OUT="$(printf '%s\n' "$PAIRS" | python3 "$LIB_DIR/scored_ledger.py" \
    verify "$LEDGER" "$VERIFY_BRANCH" --borrow --head "$VERIFY_REF" \
    --tools "$(mutation_fingerprint "$(printf '%s\n' "$PAIRS" | cut -d' ' -f1)")")" || VERDICT=$?
  if [ "$VERDICT" -eq 0 ]; then
    echo "mutation-check: mutation ledger covers every changed path for $VERIFY_BRANCH vs $BASE"
    printf '%s\n' "$LEDGER_OUT" \
      | sed -n 's/^borrowed=/  borrowed: measured on a reachable commit, same blob and tools: /p'
    exit 0
  fi
  {
    echo "mutation-check: mutation ledger is missing or stale for $VERIFY_BRANCH:"
    printf '%s\n' "$LEDGER_OUT" | sed -n 's/^unscored=/    /p'
    echo ""
    if printf '%s\n' "$LEDGER_OUT" | grep -q '^branch_unknown=1$'; then
      echo "  mutation-check.sh has never recorded a green run on $VERIFY_BRANCH. Run"
      echo "  the full check there (mutation-check.sh, no flags) before merging or"
      echo "  opening a PR."
    else
      echo "  These files changed after the last recorded run, or were never part of"
      echo "  one. Re-run mutation-check.sh (no flags) on $VERIFY_BRANCH until it"
      echo "  records MUTATION_OK."
    fi
  } >&2
  exit 5
fi

FULL=0
case "${1:-}" in
  '') ;;
  --full) FULL=1 ;;
  # A typo'd flag must not read as "no flags": that silently narrows the scope of
  # a run the user asked to widen.
  *) echo "mutation-check: unknown option $1" >&2; exit 2 ;;
esac

# MUTATION_ONLY: globs a pass is restricted to, for a module whose tests split
# across mutually exclusive builds and cannot be measured in one. Filters what
# is recorded too, or a scoped pass would fake a full green.
filter_only() {
  if [ -z "${MUTATION_ONLY:-}" ]; then
    cat
    return 0
  fi
  local line pat keep
  # noglob while splitting: unquoted $MUTATION_ONLY is pathname-expanded first,
  # so a pattern like foo/internal/* silently becomes the directory names under
  # it and matches no full path. That reported MUTATION_OK over 1 of 11 files.
  local -a pats
  set -f
  # shellcheck disable=SC2206 # word splitting is the point, globbing is not
  pats=( $MUTATION_ONLY )
  set +f
  while IFS= read -r line; do
    keep=0
    for pat in "${pats[@]}"; do
      # shellcheck disable=SC2254 # the glob is the point
      case "$line" in
        $pat) keep=1; break ;;
      esac
    done
    if [ "$keep" = 1 ]; then printf '%s\n' "$line"; fi
  done
  return 0
}

if [ -n "${MUTATION_ONLY:-}" ]; then
  echo "mutation-check: MUTATION_ONLY is set, so this pass measures and records"
  echo "  only paths matching: $MUTATION_ONLY"
  echo "  Anything else changed on this branch stays unmeasured; --verify will"
  echo "  still report it missing until another pass covers it."
fi

# Every changed path in a supported language, sources and tests both, without
# the exclusions the mutators below apply. Recorded to the ledger on a green
# run: a mutation result is only valid for the source it mutated *and* the
# tests that killed the mutants, so a deleted test must invalidate it too.
MUTATION_PATHS="$( (git diff --name-only "$BASE" -- '*.go' '*.php' '*.py' ${EXEMPT_SPEC[@]+"${EXEMPT_SPEC[@]}"} || true) | filter_only)"
TOOLS="$(mutation_fingerprint "$MUTATION_PATHS")"

# Both mock spellings: *mock_*.go misses the _mock.go suffix, which is where a
# build-tagged fake usually lives (driver_mock.go and the like). Mutating a
# test double proves nothing, and asking for one that a real-driver build
# excludes fails the run outright.
#
# **/*test/*.go covers the same intent for doubles that follow Go's <pkg>test
# convention (httptest, fstest, and project-local equivalents). Those are
# unmutatable in principle as well as in value: a stub whose closure ignores its
# ctx cannot distinguish ctx from nil, so context-nil survives whatever you write.
#
# test/** matches the tree the way the PHP and Python lines below already do:
# *test/*.go reaches only one level, so a harness any deeper was measured as
# production, and it usually builds only under a tag whose own lane excludes the
# unit tests that would kill its mutants.
#
# cmd/*/main.go: parse_mutago.py already exempts `func main()` itself, on the
# theory that it wires up live dependencies and is reachable only by re-execing
# the binary. The rest of the file is the same wiring under the same theory, so
# a package-level var, an init, or a helper main calls once was still measured
# as production and kept reappearing as an untestable survivor. Deliberately
# just the entry file, not cmd/**: a sibling in the same directory (flag
# parsing, config merging, subcommand wiring) is real logic and stays measured.
#
# A single **/-prefixed spelling covers both a root-level cmd/ and one nested
# under a subdirectory or module, unlike test/** above: git's own pathspec
# rule for **/ is "match in all directories", including zero, so **/cmd/*/main.go
# alone already reaches cmd/x/main.go too and a separate root-anchored spelling
# would be redundant. It uses :(glob) magic so the `*` stops at a slash:
# without it git's default pathspec matching lets `*` cross directory
# boundaries, which would also exclude a main.go nested deeper than the entry
# file itself (cmd/x/internal/main.go), not just the entry file this is
# limited to.
GO_FILES="$( (git diff --name-only "$BASE" -- '*.go' ':(exclude)*_test.go' ':(exclude)*mock_*.go' ':(exclude)*_mock.go' ':(exclude)**/*test/*.go' ':(exclude)test/**' ':(exclude)**/test/**' ':(exclude)*.sql.go' ':(exclude)*.pb.go' ':(exclude,glob)**/cmd/*/main.go' ${EXEMPT_SPEC[@]+"${EXEMPT_SPEC[@]}"} || true) | filter_only)"
PHP_FILES="$( (git diff --name-only "$BASE" -- '*.php' \
  ':(exclude)tests/**' ':(exclude)**/Tests/**' ':(exclude)**/*Test.php' \
  ${EXEMPT_SPEC[@]+"${EXEMPT_SPEC[@]}"} || true) | filter_only)"
PY_FILES="$( (git diff --name-only "$BASE" -- '*.py' \
  ':(exclude)**/test_*.py' ':(exclude)**/*_test.py' \
  ':(exclude)tests/**' ':(exclude)**/tests/**' ':(exclude)conftest.py' ':(exclude)**/conftest.py' \
  ${EXEMPT_SPEC[@]+"${EXEMPT_SPEC[@]}"} || true) | filter_only)"

ran_any=0
RAN_LANGS=""
CAPTURE="$(mktemp)"
INVALIDATED="$(mktemp)"

count_paths() { printf '%s\n' "$1" | grep -c '[^[:space:]]' || true; }
SOURCES_BEFORE=$(( $(count_paths "$GO_FILES") + $(count_paths "$PHP_FILES") + $(count_paths "$PY_FILES") ))

# Narrowing compares ledger blobs at HEAD against files on disk, so on a dirty
# tree it would scope the run from content that is not what gets measured, and an
# uncommitted edit to an already-measured file would narrow to nothing and skip
# the language modules' own dirty-tree handling (go refuses, php and python stash).
if ! git diff --quiet || ! git diff --cached --quiet; then
  FULL=1
fi

if [ "$FULL" -eq 0 ]; then
  # Deletions come from the diff because head_pairs resolves blobs from HEAD and
  # cannot see a deleted test, the one change that un-kills a mutant in a file
  # whose own blob is untouched. `verify` exits 1 whenever anything is unscored,
  # which here is the normal path, not a failure.
  {
    printf '%s\n' "$MUTATION_PATHS" | head_pairs HEAD \
      | python3 "$LIB_DIR/scored_ledger.py" verify "$LEDGER" "$BRANCH" \
        --borrow --head HEAD --tools "$TOOLS" \
      | sed -n 's/^unscored=//p' || true
    git diff --name-only --diff-filter=D "$BASE" -- '*.go' '*.php' '*.py' \
      ${EXEMPT_SPEC[@]+"${EXEMPT_SPEC[@]}"} || true
  } > "$INVALIDATED"

  narrow() { printf '%s\n' "$2" | python3 "$LIB_DIR/incremental_scope.py" "$1" "$INVALIDATED"; }
  GO_FILES="$(narrow go "$GO_FILES")"
  PHP_FILES="$(narrow php "$PHP_FILES")"
  PY_FILES="$(narrow py "$PY_FILES")"

  SOURCES_NOW=$(( $(count_paths "$GO_FILES") + $(count_paths "$PHP_FILES") + $(count_paths "$PY_FILES") ))
  if [ "$SOURCES_BEFORE" -gt 0 ]; then
    echo "mutation-check: incremental scope, $SOURCES_NOW of $SOURCES_BEFORE changed source file(s);"
    echo "  the rest are unchanged since the last green run on $BRANCH (--full to re-measure all)."
    echo ""
  fi
fi

run_module() {
  local lang="$1" files="$2" module="$3"
  if [ -z "$files" ]; then return 0; fi
  if [ ! -x "$module" ]; then
    echo "mutation-check: missing module $module" >&2
    return 2
  fi
  if [ "$ran_any" -eq 1 ]; then echo ""; fi
  echo "== $lang (vs $BASE) =="
  MUTATION_FILES="$files" "$module" | tee -a "$CAPTURE"
  ran_any=1
  RAN_LANGS="$RAN_LANGS $lang"
}

run_module go     "$GO_FILES"  "$LIB_DIR/mutation-check-go.sh"
run_module php    "$PHP_FILES" "$LIB_DIR/mutation-check-php.sh"
run_module python "$PY_FILES"  "$LIB_DIR/mutation-check-python.sh"

if [ "$ran_any" -eq 0 ]; then
  if [ "$SOURCES_BEFORE" -eq 0 ]; then
    echo "mutation-check: no changed source files vs $BASE in supported languages (go, php, python)"
  else
    echo "mutation-check: every changed source file is already measured on $BRANCH; no mutants to run."
  fi
  # A test-only branch takes this exit. --verify's file list includes tests,
  # so without this record it would find them unrecorded and block.
  printf '%s\n' "$MUTATION_PATHS" | head_pairs HEAD \
    | python3 "$LIB_DIR/scored_ledger.py" record "$LEDGER" "$BRANCH" \
      --commit "$(git rev-parse HEAD)" --tools "$TOOLS" >/dev/null
  exit 0
fi

FILTERED="$(python3 "$LIB_DIR/mutation_accepted.py" filter "$ACCEPT_FILE" "$BRANCH" < "$CAPTURE")"
SURVIVORS="$(sed -n 's/^unaccepted=//p' <<< "$FILTERED")"

echo ""
echo "== NEXT_ACTION =="
if [ "$SURVIVORS" -gt 0 ]; then
  echo "KILL_SURVIVORS: $SURVIVORS mutation(s) of the changed lines pass your tests."
  echo "Each SURVIVED row is a bug your suite cannot detect. For each survivor:"
  echo "write a test that fails on the mutated code and passes on the original"
  echo "(use the kill hint where given). Do not weaken the code to dodge the"
  echo "mutant. Re-run mutation-check.sh until MUTATION_OK."
  echo "If (and only if) a mutant is provably equivalent to the original code,"
  echo "surface it to the user; on their explicit approval record it with:"
  echo "  mutation-check.sh --accept '<id>'"
  # Only the language that actually ran: a Go reproduce line on a PHP run sends
  # the reader after a tool the project does not have.
  case " $RAN_LANGS " in
    *" go "*) echo "  Go: reproduce one survivor with mutago --run-mutant-id=<id>" ;;
  esac
  case " $RAN_LANGS " in
    *" php "*) echo "  PHP: reproduce one survivor with vendor/bin/infection --mutators=<Mutator>" ;;
  esac
  case " $RAN_LANGS " in
    *" python "*) echo "  Python: reproduce one survivor with mutmut show <id>" ;;
  esac
  exit 1
fi
printf '%s\n' "$MUTATION_PATHS" | head_pairs HEAD \
  | python3 "$LIB_DIR/scored_ledger.py" record "$LEDGER" "$BRANCH" \
    --commit "$(git rev-parse HEAD)" --tools "$TOOLS" >/dev/null
if grep -q 'this is not a pass' "$CAPTURE"; then
  ZERO_MUTANTS_RUN=1
  echo "MUTATION_UNMEASURED: no mutants were generated on the changed lines/functions;"
  echo "see the module output above for which ones. This is not the same as a kill;"
  echo "narrow MUTATION_BASE or MUTATION_ONLY, or accept that nothing here is mutable."
else
  echo "MUTATION_OK"
fi
sed -n 's/^accepted=/  user-accepted equivalent mutant: /p' <<< "$FILTERED"
exit 0
