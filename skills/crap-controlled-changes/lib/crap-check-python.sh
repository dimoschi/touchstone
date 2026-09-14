#!/usr/bin/env bash
# crap-check-python.sh: per-function CRAP report for staged Python changes.
# Complexity from radon (cc -j); per-function coverage from coverage.py's JSON.
# parse_python.py joins them by (file, start_line). Mirrors the PHP module's
# stash/baseline/restore/current/join/classify shape, plus a complexipy
# cognitive-complexity advisory like the Go module's gocognit section.
#
# Invoked by ../crap-check.sh after it determines Python files are staged.
# Reads its file list from CRAP_FILES (newline-separated, repo-relative) if set;
# otherwise discovers from `git diff --cached`.
#
# The suite runs from the *project* directory, resolved in this order:
#   1. CRAP_PY_PROJECT_DIR, if set (absolute, or relative to the repo root).
#   2. The repo root, unless a changed file sits under a subdirectory whose own
#      pyproject.toml declares [tool.coverage.run] or [tool.pytest.ini_options],
#      in which case this refuses (exit 2) and names it: a monorepo's project
#      config only resolves (e.g. a relative `include =`) from inside that
#      directory, so silently picking one would measure with the wrong config.
#
# The configured pytest suite runs twice (baseline + current) under coverage;
# test failures are tolerated because coverage is wanted either way. Scope the
# suite via CRAP_PY_PYTEST_ARGS on large codebases.
#
# Exit codes: 0 measured (possibly zero functions), 2 setup problem,
# 3 stash restore failed, 4 could not measure (a changed file has no coverage
# data at all in the current phase; see EXIT_UNMEASURABLE below).
#
# Env overrides:
#   CRAP_PY_RUN            - prefix for in-env commands (e.g. "poetry run", "uv run")
#   CRAP_PY_PYTEST_ARGS    - extra pytest args (e.g. "tests/unit -k foo")
#   CRAP_PY_RADON          - radon invocation (default "uvx radon")
#   CRAP_PY_COMPLEXIPY     - complexipy invocation (default "uvx complexipy")
#   CRAP_PY_PROJECT_DIR    - directory to run the suite and coverage from

set -euo pipefail

EXIT_UNMEASURABLE=4

SKILL_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SKILL_LIB/read-lines.sh"
. "$SKILL_LIB/ignored-files.sh"
. "$SKILL_LIB/repo-lock.sh"

if [ -n "${CRAP_FILES:-}" ]; then
  read_lines CHANGED <<< "$CRAP_FILES"
else
  read_lines CHANGED < <(git diff --name-only --cached -- '*.py' \
    ':(exclude)**/test_*.py' ':(exclude)**/*_test.py' \
    ':(exclude)tests/**' ':(exclude)**/tests/**' ':(exclude)conftest.py' ':(exclude)**/conftest.py')
fi
if [ "${#CHANGED[@]}" -eq 0 ] || [ -z "${CHANGED[0]}" ]; then
  exit 0
fi

command -v python3 >/dev/null || { echo "crap-check[python]: python3 required" >&2; exit 2; }

CRAP_PY_RUN="${CRAP_PY_RUN:-}"
CRAP_PY_PYTEST_ARGS="${CRAP_PY_PYTEST_ARGS:-}"
CRAP_PY_RADON="${CRAP_PY_RADON:-uvx radon}"
CRAP_PY_COMPLEXIPY="${CRAP_PY_COMPLEXIPY:-uvx complexipy}"

# uv run/poetry run resolve their env, and coverage.py resolves its config,
# from the process cwd, so PROJECT_DIR has to be settled before anything runs.
# Canonicalised (pwd -P) on both sides of the containment check below: macOS
# resolves /tmp through /private, so a plain $PWD vs. a `cd`-and-back path can
# differ only in that prefix and falsely read as outside the repo.
REPO_ROOT_PHYS="$(pwd -P)"
if [ -n "${CRAP_PY_PROJECT_DIR:-}" ]; then
  case "$CRAP_PY_PROJECT_DIR" in
    /*) CAND="$CRAP_PY_PROJECT_DIR" ;;
    *)  CAND="$PWD/$CRAP_PY_PROJECT_DIR" ;;
  esac
  PROJECT_DIR="$(cd "$CAND" 2>/dev/null && pwd -P)" || {
    echo "crap-check[python]: CRAP_PY_PROJECT_DIR does not exist: $CRAP_PY_PROJECT_DIR" >&2
    exit 2
  }
  case "$PROJECT_DIR" in
    "$REPO_ROOT_PHYS"|"$REPO_ROOT_PHYS"/*) ;;
    *)
      echo "crap-check[python]: CRAP_PY_PROJECT_DIR must be inside the repo: $CRAP_PY_PROJECT_DIR" >&2
      exit 2
      ;;
  esac
  PROJECT_DIR_SOURCE="CRAP_PY_PROJECT_DIR=$CRAP_PY_PROJECT_DIR"
else
  SUBPROJECTS=()
  read_lines SUBPROJECTS < <(printf '%s\n' "${CHANGED[@]}" | python3 "$SKILL_LIB/python_project.py" --repo-root "$PWD")
  if [ "${#SUBPROJECTS[@]}" -gt 0 ]; then
    {
      echo "crap-check[python]: changed file(s) belong to a Python project in a subdirectory, not the repo root:"
      printf '    %s\n' "${SUBPROJECTS[@]}"
      echo "  A subdirectory's own pyproject.toml only resolves from inside it, so"
      echo "  running from the repo root would measure with the wrong config."
      echo "  Re-run with CRAP_PY_PROJECT_DIR=<dir> naming which one to measure"
      echo "  (relative to the repo root, or absolute)."
    } >&2
    exit 2
  fi
  PROJECT_DIR="$PWD"
  PROJECT_DIR_SOURCE="repo root (no CRAP_PY_PROJECT_DIR set, no subdirectory project detected)"
fi

if ! (cd "$PROJECT_DIR" && $CRAP_PY_RUN coverage --version) >/dev/null 2>&1; then
  echo "crap-check[python]: 'coverage' not runnable via '${CRAP_PY_RUN:-<active env>}' in $PROJECT_DIR" >&2
  echo "  Hint: install coverage.py + pytest in the project env, or set CRAP_PY_RUN" >&2
  echo "        (e.g. CRAP_PY_RUN='poetry run' or CRAP_PY_RUN='uv run')." >&2
  exit 2
fi

STASHED=0
if ! git diff --quiet || ! git diff --cached --quiet; then
  acquire_repo_lock python
  git stash push -q --include-untracked -m "crap-check baseline" >/dev/null
  STASHED=1
fi

restore() {
  if [ "$STASHED" -eq 1 ]; then
    # The baseline suite runs against HEAD's tree and can write to tracked
    # files as it goes (a committed .coverage, a snapshot fixture, a cache).
    # Those writes then collide with the pop and used to strand the user's
    # entire change set in a stash they were told to sort out by hand. The
    # baseline's own writes are worthless, so discard them first; only tracked
    # files are touched, so nothing the stash holds is at risk.
    git checkout -q -- . 2>/dev/null || true
    # --index restores the staged/unstaged split; a plain `pop` reinstates every change as unstaged.
    git stash pop --index -q >/dev/null || {
      {
        echo "crap-check[python]: FAILED TO RESTORE YOUR WORKING TREE."
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

BASE_TSV="$(mktemp)"
CUR_TSV="$(mktemp)"
COV_JSON="$(mktemp -t crap-py-cov.XXXXXX.json)"
RADON_JSON="$(mktemp -t crap-py-radon.XXXXXX.json)"
BASE_UNMEASURED="$(mktemp)"
CUR_UNMEASURED="$(mktemp)"

clean_artifacts() {
  rm -rf .complexipy_cache
  rm -f "$PROJECT_DIR/.coverage"
}

cleanup() {
  rm -f "$BASE_TSV" "$CUR_TSV" "$COV_JSON" "$RADON_JSON" "$BASE_UNMEASURED" "$CUR_UNMEASURED"
  clean_artifacts
  restore
  release_repo_lock
}
trap cleanup EXIT

measure() {
  local out_tsv="$1" phase="$2" unmeasured_out="$3"
  local existing=() f
  for f in "${CHANGED[@]}"; do
    [ -f "$f" ] && existing+=("$f")
  done
  if [ "${#existing[@]}" -eq 0 ]; then
    : > "$out_tsv"
    return
  fi

  (cd "$PROJECT_DIR" && $CRAP_PY_RUN coverage run -m pytest $CRAP_PY_PYTEST_ARGS) >/dev/null 2>&1 || true
  # `coverage json` failing means no data was collected at all (import error,
  # collection error), not that tests failed. This phase then scores nothing,
  # which silently mistags every function as "new".
  if ! (cd "$PROJECT_DIR" && $CRAP_PY_RUN coverage json -o "$COV_JSON") >/dev/null 2>&1; then
    echo '{}' > "$COV_JSON"
    collect_ignored_files "$phase" '*.py' \
      ':(glob,exclude)**/.venv/**' ':(glob,exclude)**/venv/**' \
      ':(glob,exclude)**/site-packages/**' ':(glob,exclude)**/.tox/**'
    {
      echo "crap-check[python]: coverage.py collected no data; this phase scored nothing."
      echo "  phase: $phase$(ignored_files_phase_suffix)"
      ignored_files_note
    } >&2
  fi

  # radon and complexipy stay repo-rooted on repo-relative paths regardless of
  # PROJECT_DIR: they need no project config to resolve, so their output keys
  # match CHANGED as-is and the join in parse_python.py needs no cov_root for them.
  $CRAP_PY_RADON cc -j "${existing[@]}" > "$RADON_JSON" 2>/dev/null || echo '{}' > "$RADON_JSON"

  CRAP_CHANGED_FILES="$(printf '%s\n' "${existing[@]}")" \
    CRAP_REPO_ROOT="$PWD" \
    CRAP_COV_ROOT="$PROJECT_DIR" \
    python3 "$SKILL_LIB/parse_python.py" "$RADON_JSON" "$COV_JSON" \
      --unmeasured-out "$unmeasured_out" > "$out_tsv"

  clean_artifacts
}

measure "$BASE_TSV" "$PHASE_BASELINE" "$BASE_UNMEASURED"
if [ -s "$BASE_UNMEASURED" ]; then
  # HEAD never having measured a file is not this run's failure: the file may
  # be new since HEAD, or only became imported by a test in the current
  # change. It just means every row for it tags "new" rather than compared
  # against a real baseline, same shape as the "collected no data" warning
  # above.
  BASE_UNMEASURED_LIST=()
  read_lines BASE_UNMEASURED_LIST < "$BASE_UNMEASURED"
  {
    echo "crap-check[python]: baseline (HEAD) has no coverage data for:"
    printf '    %s\n' "${BASE_UNMEASURED_LIST[@]}"
    echo "  Rows for these will tag as new against an empty baseline rather than compared to HEAD."
  } >&2
fi
restore
measure "$CUR_TSV" "$PHASE_CURRENT" "$CUR_UNMEASURED"

if [ -s "$CUR_UNMEASURED" ]; then
  CUR_UNMEASURED_LIST=()
  read_lines CUR_UNMEASURED_LIST < "$CUR_UNMEASURED"
  {
    echo "crap-check[python]: FAILED TO MEASURE - coverage has no data for changed file(s):"
    printf '    %s\n' "${CUR_UNMEASURED_LIST[@]}"
    echo "  project directory used: $PROJECT_DIR"
    echo "  resolved from:          $PROJECT_DIR_SOURCE"
    echo "  suite ran in:           $PROJECT_DIR"
    echo ""
    echo "  This is NOT a pass. No row was built for these files: there is no"
    echo "  coverage percentage to report for them, not a genuine 0%."
    echo ""
    echo "  Remedies:"
    echo "    - If this is the wrong project, set CRAP_PY_PROJECT_DIR to the one"
    echo "      that owns these files."
    echo "    - If a file is intentionally never imported by a test, add its"
    echo "      package to [tool.coverage.run] source/include in the project's"
    echo "      pyproject.toml (or .coveragerc) so it reads a real 0% instead."
    echo "    - Confirm coverage.py >= 7.13.1 ran: older releases omit the"
    echo "      per-function start_line this gate joins on (see python.md)."
  } >&2
  exit "$EXIT_UNMEASURABLE"
fi

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

COGNIT_FILES=() f=
for f in "${CHANGED[@]}"; do
  [ -f "$f" ] && COGNIT_FILES+=("$f")
done
if [ "${#COGNIT_FILES[@]}" -gt 0 ]; then
  COGNIT_OUT="$($CRAP_PY_COMPLEXIPY -mx 15 -f -C no "${COGNIT_FILES[@]}" 2>/dev/null \
    | grep -E '^[[:space:]]*-[[:space:]]' || true)"
  clean_artifacts
  if [ -n "$COGNIT_OUT" ]; then
    echo ""
    echo "Cognitive complexity (advisory, >15):"
    printf '%s\n' "$COGNIT_OUT"
  fi
fi
