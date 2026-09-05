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
# Performance: the configured PHPUnit suite runs twice (baseline + current).
# Scope it via PHPUNIT_ARGS for large codebases.

set -euo pipefail

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

cleanup() {
  rm -f "$BASE_XML" "$CUR_XML" "$BASE_TSV" "$CUR_TSV"
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
  local in_xml="$1" out_tsv="$2"
  if [ ! -s "$in_xml" ]; then
    : > "$out_tsv"
    return
  fi
  CRAP_CHANGED_FILES="$(printf '%s\n' "${CHANGED[@]}")" \
    CRAP_REPO_ROOT="$PWD" \
    python3 "$SKILL_LIB/parse_clover.py" "$in_xml" > "$out_tsv"
}

run_phpunit "$BASE_XML" "$PHASE_BASELINE"
parse_clover "$BASE_XML" "$BASE_TSV"

restore

run_phpunit "$CUR_XML" "$PHASE_CURRENT"
parse_clover "$CUR_XML" "$CUR_TSV"

awk -v BASEFILE="$BASE_TSV" -F '\t' '
  function status(s, cov, tag) {
    if (cov != "n/a" && cov+0 < 80 && (tag == "new" || tag == "worsened")) {
      return "NEEDS_TESTS"
    }
    if (s <= 6) return "OK"
    if (s <= 8) return "SOFT"
    return "HARD"
  }
  FILENAME == BASEFILE {
    base_cc[$1]   = $2
    base_cov[$1]  = $3
    base_crap[$1] = $4
    next
  }
  {
    id = $1; cc = $2; cov = $3; crap = $4
    cur_score = (crap == "n/a") ? 0 : crap + 0
    tag = "new"
    if (id in base_cc) {
      base_score = (base_crap[id] == "n/a") ? 0 : base_crap[id] + 0
      if (cur_score > base_score + 0.05) tag = "worsened"
      else                                tag = "unchanged"
    }
    st = status(cur_score, cov, tag)
    printf "%-60s complexity=%-2s  coverage=%s%%  CRAP=%s  %-11s  (%s)\n", \
           id, cc, cov, crap, st, tag
  }
' "$BASE_TSV" "$CUR_TSV"
