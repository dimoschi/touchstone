#!/usr/bin/env bash
# crap-check-php.sh: per-method CRAP report for staged PHP changes.
# Drives PHPUnit's --coverage-clover output. PHPUnit's Clover writer already
# emits cyclomatic complexity and CRAP per method, so this script's job is
# just orchestration: stash, run, restore, run again, join, classify.
#
# Invoked by ../crap-check.sh after it determines PHP files are staged.
# Reads its file list from CRAP_FILES (newline-separated, repo-relative) if
# set; otherwise discovers from `git diff --cached`. Runs from repo root.
#
# Required env (optional overrides):
#   PHPUNIT_BIN   - path to phpunit binary (default: vendor/bin/phpunit)
#   PHPUNIT_ARGS  - extra args, e.g. --testsuite=Unit (default: empty)
#
# Exit codes: 0 measured (possibly zero methods), 2 setup problem,
# 3 stash restore failed, 4 could not measure (a changed file is absent from
# the current phase's Clover report entirely; see EXIT_UNMEASURABLE below).
#
# Performance: the configured PHPUnit suite runs twice (baseline + current).
# Scope it via PHPUNIT_ARGS for large codebases.

set -euo pipefail

EXIT_UNMEASURABLE=4

SKILL_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SKILL_LIB/read-lines.sh"
. "$SKILL_LIB/ignored-files.sh"
. "$SKILL_LIB/repo-lock.sh"

if [ -n "${CRAP_FILES:-}" ]; then
  read_lines CHANGED <<< "$CRAP_FILES"
else
  read_lines CHANGED < <(git diff --name-only --cached -- '*.php' \
    ':(exclude)tests/**' ':(exclude)**/Tests/**' ':(exclude)**/*Test.php')
fi
if [ "${#CHANGED[@]}" -eq 0 ] || [ -z "${CHANGED[0]}" ]; then
  exit 0
fi

PHPUNIT_BIN="${PHPUNIT_BIN:-vendor/bin/phpunit}"
PHPUNIT_ARGS_STR="${PHPUNIT_ARGS:-}"

if [ ! -x "$PHPUNIT_BIN" ]; then
  echo "crap-check[php]: $PHPUNIT_BIN not found or not executable" >&2
  echo "  Hint: run 'composer install' or set PHPUNIT_BIN=path/to/phpunit" >&2
  exit 2
fi

if ! command -v python3 >/dev/null; then
  echo "crap-check[php]: python3 required for Clover parsing" >&2
  exit 2
fi

STASHED=0
if ! git diff --quiet || ! git diff --cached --quiet; then
  acquire_repo_lock php
  git stash push -q --include-untracked -m "crap-check baseline" >/dev/null
  STASHED=1
fi

restore() {
  if [ "$STASHED" -eq 1 ]; then
    # The baseline suite runs against HEAD's tree and can write to tracked
    # files as it goes -- PHPUnit's .phpunit.result.cache is the common one,
    # and snapshot suites do the same. Those writes then collide with the pop
    # ("local changes would be overwritten"), which used to strand the user's
    # entire change set in a stash they were told to sort out by hand. The
    # baseline's own writes are worthless, so discard them first; only tracked
    # files are touched, so nothing the stash holds is at risk.
    git checkout -q -- . 2>/dev/null || true
    # --index restores the staged/unstaged split; a plain `pop` reinstates every change as unstaged.
    git stash pop --index -q >/dev/null || {
      {
        echo "crap-check[php]: FAILED TO RESTORE YOUR WORKING TREE."
        echo "  Your changes are safe but still stashed. Recover them with:"
        echo ""
        echo "    git -C $(pwd) stash pop --index"
        echo ""
        echo "  If that reports a conflict, the file it names was also written by"
        echo "  the test suite; discard that one file and retry the pop."
      } >&2
      exit 3
    }
    STASHED=0
  fi
}

BASE_XML="$(mktemp -t crap-php-base.XXXXXX.xml)"
CUR_XML="$(mktemp -t crap-php-cur.XXXXXX.xml)"
BASE_TSV="$(mktemp)"
CUR_TSV="$(mktemp)"
BASE_UNMEASURED="$(mktemp)"
CUR_UNMEASURED="$(mktemp)"

cleanup() {
  rm -f "$BASE_XML" "$CUR_XML" "$BASE_TSV" "$CUR_TSV" "$BASE_UNMEASURED" "$CUR_UNMEASURED"
  restore
  release_repo_lock
}
trap cleanup EXIT

run_phpunit() {
  local out_xml="$1" phase="$2"
  # PHPUnit returns nonzero on test failures; we want coverage either way.
  "$PHPUNIT_BIN" --coverage-clover="$out_xml" $PHPUNIT_ARGS_STR >/dev/null 2>&1 || true
  # No clover at all means the suite could not run, not that it failed. That
  # phase contributes no rows, which silently mistags every method as "new".
  if [ ! -s "$out_xml" ]; then
    collect_ignored_files "$phase" '*.php' ':(glob,exclude)**/vendor/**'
    {
      echo "crap-check[php]: PHPUnit wrote no clover report; this phase scored nothing."
      echo "  phase: $phase$(ignored_files_phase_suffix)"
      ignored_files_note
    } >&2
  fi
}

parse_clover() {
  local in_xml="$1" out_tsv="$2" unmeasured_out="$3"
  # Only files present in the tree this phase ran against. `git diff --cached`
  # lists deletions, so a removed file (or a rename's old path) reaches here
  # and can never appear in Clover: the suite had nothing to load. Reported as
  # unmeasured it became exit 4, refusing the commit and printing remedies that
  # ask for coverage of a file that no longer exists. Per phase, because the
  # baseline tree is stashed back to HEAD where the file does still exist.
  local existing=() f
  for f in "${CHANGED[@]}"; do
    [ -f "$f" ] && existing+=("$f")
  done
  : > "$unmeasured_out"
  if [ "${#existing[@]}" -eq 0 ]; then
    : > "$out_tsv"
    return
  fi
  if [ ! -s "$in_xml" ]; then
    : > "$out_tsv"
    # No report at all means every changed file is as unmeasured as one
    # Clover genuinely omitted; feeds the same could-not-measure check below.
    printf '%s\n' "${existing[@]}" > "$unmeasured_out"
    return
  fi
  CRAP_CHANGED_FILES="$(printf '%s\n' "${existing[@]}")" \
    CRAP_REPO_ROOT="$PWD" \
    python3 "$SKILL_LIB/parse_clover.py" "$in_xml" --unmeasured-out "$unmeasured_out" > "$out_tsv"
}

run_phpunit "$BASE_XML" "$PHASE_BASELINE"
parse_clover "$BASE_XML" "$BASE_TSV" "$BASE_UNMEASURED"

if [ -s "$BASE_UNMEASURED" ]; then
  # HEAD never measuring a file is not this run's failure: the file may be
  # new since HEAD, or only became imported by a test in the current change.
  BASE_UNMEASURED_LIST=()
  read_lines BASE_UNMEASURED_LIST < "$BASE_UNMEASURED"
  {
    echo "crap-check[php]: baseline (HEAD) Clover report has no data for:"
    printf '    %s\n' "${BASE_UNMEASURED_LIST[@]}"
    echo "  Rows for these will tag as new against an empty baseline rather than compared to HEAD."
  } >&2
fi

restore

run_phpunit "$CUR_XML" "$PHASE_CURRENT"
parse_clover "$CUR_XML" "$CUR_TSV" "$CUR_UNMEASURED"

if [ -s "$CUR_UNMEASURED" ]; then
  CUR_UNMEASURED_LIST=()
  read_lines CUR_UNMEASURED_LIST < "$CUR_UNMEASURED"
  {
    echo "crap-check[php]: FAILED TO MEASURE - Clover has no data for changed file(s):"
    printf '    %s\n' "${CUR_UNMEASURED_LIST[@]}"
    echo ""
    echo "  This is NOT a pass. No row was built for these files: there is no"
    echo "  coverage percentage to report for them, not a genuine 0%."
    echo ""
    echo "  Remedies:"
    echo "    - If a file is intentionally never imported by a test, confirm PHPUnit's"
    echo "      coverage include/whitelist in phpunit.xml covers it, and that at least"
    echo "      one test actually loads the class so PHPUnit's Clover writer sees it."
  } >&2
  exit "$EXIT_UNMEASURABLE"
fi

CLASSIFIED="$(python3 "$SKILL_LIB/classify_rows.py" \
  --base "$BASE_TSV" --current "$CUR_TSV" --layout plain --repo-root "$PWD")" || {
  echo "crap-check[php]: FAILED TO MEASURE - the measured rows could not be classified." >&2
  echo "  No row was built, which is not the same as having nothing to score." >&2
  exit "$EXIT_UNMEASURABLE"
}
if [ -n "$CLASSIFIED" ]; then
  printf '%s\n' "$CLASSIFIED"
fi
