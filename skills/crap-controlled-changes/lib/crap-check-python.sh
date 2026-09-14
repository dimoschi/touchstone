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
# The suite runs from the *project* directory (or directories), resolved:
#   1. CRAP_PY_PROJECT_DIR, if set: one directory, or several space/newline
#      separated. Each changed file is measured from whichever one owns it.
#   2. The repo root, if its own pyproject.toml declares [tool.coverage.run] or
#      [tool.pytest.ini_options], regardless of a workspace member also having
#      one of those headers for its own standalone use.
#   3. Otherwise the repo root, unless a changed file sits under a subdirectory
#      whose own pyproject.toml declares one of those headers: a subdirectory's
#      config only resolves from inside it, so this refuses (exit 2) and names
#      it rather than silently measuring with the wrong config.
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
#   CRAP_PY_PROJECT_DIR    - directory (or space/newline-separated directories)
#                            to run the suite and coverage from

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
# from the process cwd, so PROJECT_DIRS has to be settled before anything runs.
# Canonicalised (pwd -P) on both sides of the containment check below: macOS
# resolves /tmp through /private, so a plain $PWD vs. a `cd`-and-back path can
# differ only in that prefix and falsely read as outside the repo.
REPO_ROOT_PHYS="$(pwd -P)"

resolve_project_dir() {
  local raw="$1" cand dir
  case "$raw" in
    /*) cand="$raw" ;;
    *)  cand="$PWD/$raw" ;;
  esac
  dir="$(cd "$cand" 2>/dev/null && pwd -P)" || {
    echo "crap-check[python]: CRAP_PY_PROJECT_DIR does not exist: $raw" >&2
    exit 2
  }
  case "$dir" in
    "$REPO_ROOT_PHYS"|"$REPO_ROOT_PHYS"/*) ;;
    *)
      echo "crap-check[python]: CRAP_PY_PROJECT_DIR must be inside the repo: $raw" >&2
      exit 2
      ;;
  esac
  printf '%s\n' "$dir"
}

PROJECT_DIRS=()
if [ -n "${CRAP_PY_PROJECT_DIR:-}" ]; then
  # Space/newline separated: a diff can span more than one Python project, and
  # naming all of them is the only way that case ever measures for real (see
  # the >1-subproject refusal below).
  RAW_PROJECT_DIRS=()
  read -r -a RAW_PROJECT_DIRS <<< "$CRAP_PY_PROJECT_DIR"
  for RAW_DIR in "${RAW_PROJECT_DIRS[@]}"; do
    PROJECT_DIRS+=("$(resolve_project_dir "$RAW_DIR")")
  done
  PROJECT_DIR_SOURCE="CRAP_PY_PROJECT_DIR=$CRAP_PY_PROJECT_DIR"
else
  # A workspace member's own pyproject.toml can carry one of the two headers
  # for its own standalone use without being a separate project this gate
  # needs to measure from; the root's own config, when it has one, always wins.
  ROOT_DECLARES="$(python3 "$SKILL_LIB/python_project.py" --repo-root "$PWD" --root-declares)"
  if [ "$ROOT_DECLARES" = "1" ]; then
    PROJECT_DIRS=("$REPO_ROOT_PHYS")
    PROJECT_DIR_SOURCE="repo root (its own pyproject.toml declares [tool.coverage.run] or [tool.pytest.ini_options])"
  else
    SUBPROJECTS=()
    read_lines SUBPROJECTS < <(printf '%s\n' "${CHANGED[@]}" | python3 "$SKILL_LIB/python_project.py" --repo-root "$PWD")
    if [ "${#SUBPROJECTS[@]}" -eq 1 ]; then
      {
        echo "crap-check[python]: changed file(s) belong to a Python project in a subdirectory, not the repo root:"
        printf '    %s\n' "${SUBPROJECTS[@]}"
        echo "  A subdirectory's own pyproject.toml only resolves from inside it, so"
        echo "  running from the repo root would measure with the wrong config."
        echo "  Re-run with CRAP_PY_PROJECT_DIR=<dir> naming it (relative to the repo"
        echo "  root, or absolute), or CRAP_PY_PROJECT_DIR=. if the repo root really"
        echo "  is this change's project despite the above."
      } >&2
      exit 2
    elif [ "${#SUBPROJECTS[@]}" -gt 1 ]; then
      {
        echo "crap-check[python]: changed files belong to more than one Python project:"
        printf '    %s\n' "${SUBPROJECTS[@]}"
        echo "  Each one's pyproject.toml only resolves from inside it, and no single"
        echo "  directory measures both, so naming just one is not a fix. Re-run naming"
        echo "  all of them together, space-separated:"
        echo "    CRAP_PY_PROJECT_DIR=\"${SUBPROJECTS[*]}\" crap-check.sh"
      } >&2
      exit 2
    fi
    PROJECT_DIRS=("$REPO_ROOT_PHYS")
    PROJECT_DIR_SOURCE="repo root (no CRAP_PY_PROJECT_DIR set, no subdirectory project detected)"
  fi
fi

# Repo-relative form of each resolved directory, "." for the repo root itself;
# used to assign a changed file to its owning directory when more than one is
# in play (python_project.py --group, see measure() below).
PROJECT_RELS=()
for PDIR in "${PROJECT_DIRS[@]}"; do
  if [ "$PDIR" = "$REPO_ROOT_PHYS" ]; then
    PROJECT_RELS+=(".")
  else
    PROJECT_RELS+=("${PDIR#"$REPO_ROOT_PHYS"/}")
  fi
done

for PDIR in "${PROJECT_DIRS[@]}"; do
  if ! (cd "$PDIR" && $CRAP_PY_RUN coverage --version) >/dev/null 2>&1; then
    echo "crap-check[python]: 'coverage' not runnable via '${CRAP_PY_RUN:-<active env>}' in $PDIR" >&2
    echo "  Hint: install coverage.py + pytest in the project env, or set CRAP_PY_RUN" >&2
    echo "        (e.g. CRAP_PY_RUN='poetry run' or CRAP_PY_RUN='uv run')." >&2
    exit 2
  fi
done

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
  local PDIR
  for PDIR in "${PROJECT_DIRS[@]}"; do
    rm -f "$PDIR/.coverage"
  done
}

cleanup() {
  rm -f "$BASE_TSV" "$CUR_TSV" "$COV_JSON" "$RADON_JSON" "$BASE_UNMEASURED" "$CUR_UNMEASURED"
  clean_artifacts
  restore
  release_repo_lock
}
trap cleanup EXIT

# Coverage + radon + join for one project directory, restricted to `files`.
# Shared by the single- and multi-project cases in measure() below, so both
# go through the identical logic; a single project is just the N=1 case.
measure_dir() {
  local out_tsv="$1" phase="$2" unmeasured_out="$3" project_dir="$4"
  shift 4
  local files=("$@")

  (cd "$project_dir" && $CRAP_PY_RUN coverage run -m pytest $CRAP_PY_PYTEST_ARGS) >/dev/null 2>&1 || true
  # `coverage json` failing means no data was collected at all (import error,
  # collection error), not that tests failed. Every changed file reads as
  # unmeasured below; the baseline phase zero-fills those rows instead of
  # dropping them, the current phase does not (see the exit-4 check below).
  if ! (cd "$project_dir" && $CRAP_PY_RUN coverage json -o "$COV_JSON") >/dev/null 2>&1; then
    echo '{}' > "$COV_JSON"
    collect_ignored_files "$phase" '*.py' \
      ':(glob,exclude)**/.venv/**' ':(glob,exclude)**/venv/**' \
      ':(glob,exclude)**/site-packages/**' ':(glob,exclude)**/.tox/**'
    {
      echo "crap-check[python]: coverage.py collected no data; this phase scored nothing."
      echo "  phase: $phase$(ignored_files_phase_suffix)"
      echo "  project directory: $project_dir"
      ignored_files_note
    } >&2
  fi

  # radon and complexipy stay repo-rooted on repo-relative paths regardless of
  # project_dir: they need no project config to resolve, so their output keys
  # match `files` as-is and the join in parse_python.py needs no cov_root for them.
  $CRAP_PY_RADON cc -j "${files[@]}" > "$RADON_JSON" 2>/dev/null || echo '{}' > "$RADON_JSON"

  # Baseline only: HEAD not measuring a file is not evidence its functions are
  # new, so zero-fill instead of dropping the row. The current phase keeps
  # dropping so the exit-4 check below still fires.
  local zero_fill_flag=()
  [ "$phase" = "$PHASE_BASELINE" ] && zero_fill_flag=(--zero-fill-unmeasured)

  CRAP_CHANGED_FILES="$(printf '%s\n' "${files[@]}")" \
    CRAP_REPO_ROOT="$PWD" \
    CRAP_COV_ROOT="$project_dir" \
    python3 "$SKILL_LIB/parse_python.py" "$RADON_JSON" "$COV_JSON" \
      --unmeasured-out "$unmeasured_out" "${zero_fill_flag[@]}" > "$out_tsv"

  rm -f "$project_dir/.coverage"
}

measure() {
  local out_tsv="$1" phase="$2" unmeasured_out="$3"
  local existing=() f
  for f in "${CHANGED[@]}"; do
    [ -f "$f" ] && existing+=("$f")
  done
  : > "$out_tsv"
  : > "$unmeasured_out"
  if [ "${#existing[@]}" -eq 0 ]; then
    return
  fi

  if [ "${#PROJECT_DIRS[@]}" -eq 1 ]; then
    measure_dir "$out_tsv" "$phase" "$unmeasured_out" "${PROJECT_DIRS[0]}" "${existing[@]}"
    clean_artifacts
    return
  fi

  # More than one project: measure each directory's own files on their own.
  # Project A's coverage run over project B's files would just report them
  # unmeasured -- they were never in A's source tree.
  local group_args=() d
  for d in "${PROJECT_RELS[@]}"; do group_args+=(--group-by "$d"); done
  local grouped
  grouped="$(mktemp)"
  printf '%s\n' "${existing[@]}" \
    | python3 "$SKILL_LIB/python_project.py" --repo-root "$PWD" --group "${group_args[@]}" \
    > "$grouped"

  local i pdir prel dir_files dtsv dunm
  for i in "${!PROJECT_DIRS[@]}"; do
    pdir="${PROJECT_DIRS[$i]}"
    prel="${PROJECT_RELS[$i]}"
    dir_files=()
    while IFS= read -r f; do
      [ -n "$f" ] && dir_files+=("$f")
    done < <(awk -F'\t' -v d="$prel" '$1 == d { print $2 }' "$grouped")
    [ "${#dir_files[@]}" -eq 0 ] && continue

    dtsv="$(mktemp)"
    dunm="$(mktemp)"
    measure_dir "$dtsv" "$phase" "$dunm" "$pdir" "${dir_files[@]}"
    cat "$dtsv" >> "$out_tsv"
    cat "$dunm" >> "$unmeasured_out"
    rm -f "$dtsv" "$dunm"
  done
  rm -f "$grouped"
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
    echo "  project directory used: ${PROJECT_DIRS[*]}"
    echo "  resolved from:          $PROJECT_DIR_SOURCE"
    echo "  suite ran in:           ${PROJECT_DIRS[*]}"
    echo ""
    echo "  This is NOT a pass. No row was built for these files: there is no"
    echo "  coverage percentage to report for them, not a genuine 0%."
    echo ""
    echo "  Remedies:"
    echo "    - If this is the wrong project, set CRAP_PY_PROJECT_DIR to the one"
    echo "      that owns these files (or to '.' if it is the repo root itself)."
    echo "    - If a file is intentionally never imported by a test, add its"
    echo "      package to [tool.coverage.run] source (not include/omit) in the"
    echo "      project's pyproject.toml or .coveragerc: source is what makes"
    echo "      coverage.py report a file it never executed at a real 0%;"
    echo "      include/omit only filter files coverage already found, so they"
    echo "      cannot make an unimported file appear."
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
