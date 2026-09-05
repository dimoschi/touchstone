#!/usr/bin/env bash
# crap-check-python.sh: per-function CRAP report for staged Python changes.
# Complexity from radon (cc -j); per-function coverage from coverage.py's JSON.
# parse_python.py joins them by (file, start_line). Mirrors the PHP module's
# stash/baseline/restore/current/join/classify shape, plus a complexipy
# cognitive-complexity advisory like the Go module's gocognit section.
#
# Invoked by ../crap-check.sh after it determines Python files are staged.
# Reads its file list from CRAP_FILES (newline-separated, repo-relative) if set;
# otherwise discovers from `git diff --cached`. Runs from repo root.
#
# The configured pytest suite runs twice (baseline + current) under coverage;
# test failures are tolerated because coverage is wanted either way. Scope the
# suite via CRAP_PY_PYTEST_ARGS on large codebases.
#
# Env overrides:
#   CRAP_PY_RUN          - prefix for in-env commands (e.g. "poetry run", "uv run")
#   CRAP_PY_PYTEST_ARGS  - extra pytest args (e.g. "tests/unit -k foo")
#   CRAP_PY_RADON        - radon invocation (default "uvx radon")
#   CRAP_PY_COMPLEXIPY   - complexipy invocation (default "uvx complexipy")

set -euo pipefail

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

if ! $CRAP_PY_RUN coverage --version >/dev/null 2>&1; then
  echo "crap-check[python]: 'coverage' not runnable via '${CRAP_PY_RUN:-<active env>}'" >&2
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
    # --index restores the staged/unstaged split; a plain `pop` reinstates every change as unstaged.
    git stash pop --index -q >/dev/null || {
      echo "crap-check[python]: failed to restore stash; resolve manually" >&2
      exit 3
    }
    STASHED=0
  fi
}

BASE_TSV="$(mktemp)"
CUR_TSV="$(mktemp)"
COV_JSON="$(mktemp -t crap-py-cov.XXXXXX.json)"
RADON_JSON="$(mktemp -t crap-py-radon.XXXXXX.json)"

clean_artifacts() {
  rm -rf .complexipy_cache
  rm -f .coverage
}

cleanup() {
  rm -f "$BASE_TSV" "$CUR_TSV" "$COV_JSON" "$RADON_JSON"
  clean_artifacts
  restore
  release_repo_lock
}
trap cleanup EXIT

measure() {
  local out_tsv="$1" phase="$2"
  local existing=() f
  for f in "${CHANGED[@]}"; do
    [ -f "$f" ] && existing+=("$f")
  done
  if [ "${#existing[@]}" -eq 0 ]; then
    : > "$out_tsv"
    return
  fi

  $CRAP_PY_RUN coverage run -m pytest $CRAP_PY_PYTEST_ARGS >/dev/null 2>&1 || true
  # `coverage json` failing means no data was collected at all (import error,
  # collection error), not that tests failed. This phase then scores nothing,
  # which silently mistags every function as "new".
  if ! $CRAP_PY_RUN coverage json -o "$COV_JSON" >/dev/null 2>&1; then
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

  $CRAP_PY_RADON cc -j "${existing[@]}" > "$RADON_JSON" 2>/dev/null || echo '{}' > "$RADON_JSON"

  CRAP_CHANGED_FILES="$(printf '%s\n' "${CHANGED[@]}")" \
    CRAP_REPO_ROOT="$PWD" \
    python3 "$SKILL_LIB/parse_python.py" "$RADON_JSON" "$COV_JSON" > "$out_tsv"

  clean_artifacts
}

measure "$BASE_TSV" "$PHASE_BASELINE"
restore
measure "$CUR_TSV" "$PHASE_CURRENT"

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
