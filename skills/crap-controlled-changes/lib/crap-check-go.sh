#!/usr/bin/env bash
# crap-check.sh: per-function CRAP report for staged Go changes.
# Drives github.com/padiazg/go-crap to measure complexity and coverage,
# compares the working tree (with staged changes) against HEAD baseline,
# and prints one row per function in changed files with status and tag.
#
# Exit codes: 0 measured (possibly zero functions), 2 setup problem,
# 4 could not measure (no CRAP report produced).
#
# The HEAD baseline is measured in a throwaway detached worktree, never by
# stashing: the stash stack is repo-global across linked worktrees, so two
# concurrent gate runs pop each other's changes, and a kill between push and pop
# leaves the changes stashed with the tree looking clean. This touches no shared
# state, so concurrent runs in different worktrees cannot interfere.
#
# CRAP_GO_TEST_COMMAND overrides the command used to produce coverage.
# It defaults to `go test ./...`; repos whose default package set needs
# live services (Postgres, RabbitMQ) must narrow it, e.g.
#   CRAP_GO_TEST_COMMAND='go test ./internal/...'

set -euo pipefail

EXIT_UNMEASURABLE=4
DIAG_LINES=30

SKILL_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SKILL_LIB/ignored-files.sh"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "crap-check: not inside a git repo" >&2
  exit 2
}
cd "$REPO_ROOT"

if [ -n "${CRAP_FILES:-}" ]; then
  mapfile -t CHANGED <<< "$CRAP_FILES"
else
  mapfile -t CHANGED < <(git diff --name-only --cached -- '*.go' ':(exclude)*_test.go' ':(exclude)*mock_*.go' ':(exclude)*_mock.go' ':(exclude)*.sql.go' ':(exclude)*.pb.go')
fi
if [ "${#CHANGED[@]}" -eq 0 ] || [ -z "${CHANGED[0]}" ]; then
  exit 0
fi

command -v go >/dev/null || { echo "crap-check: go not on PATH" >&2; exit 2; }

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/tool-versions.sh"
GOCRAP_VERSION="${CRAP_GO_GOCRAP_VERSION:-$GOCRAP_VERSION_DEFAULT}"
GOCRAP_PKG="github.com/padiazg/go-crap"
GOCRAP=(go run "$GOCRAP_PKG@$GOCRAP_VERSION" scan)
GO_TEST_COMMAND="${CRAP_GO_TEST_COMMAND:-go test ./...}"

# go-crap selects whole packages, so the per-file excludes that the staged-file
# globs apply have to be repeated here: generated mocks and sqlc output are not
# authored in this repo. _test.go is excluded by go-crap already.
#
# Both mock spellings: mockery emits mock_foo.go, but Go's own convention is
# foo_mock.go, and scoring the latter also makes the <pkg>.<func> join key
# ambiguous whenever a build tag selects between two same-named constructors.
GOCRAP_EXCLUDES=(--exclude '.*mock_.*\.go' --exclude '.*_mock\.go' --exclude '.*\.sql\.go')

# go-crap can run `go test` itself, and must not be allowed to: when its run
# produces no usable coverage it reports every function at 0% (the default
# --missing pessimistic), prints nothing, and exits 0. That reads as a very bad
# but successful measurement. It also has no equivalent of CRAP_GO_TEST_COMMAND,
# which repos needing live services depend on. So the profile is generated here,
# checked for content, and passed in with --coverage-profile.
gen_coverage() {
  local dir="$1" prof="$2" phase="$3" status=0 body
  ( cd "$dir" && eval "$GO_TEST_COMMAND" -coverprofile="$prof" -covermode=set ) \
    >"$RAW_OUT" 2>"$RAW_ERR" || status=$?
  body="$(grep -cv '^mode:' "$prof" 2>/dev/null)" || body=0
  # A failed run still writes a profile for whichever packages did pass, so size
  # alone is not evidence of a measurement: partial coverage would silently score
  # functions against a suite that never ran. The exit status is the real signal.
  if [ "$status" -ne 0 ] || [ ! -s "$prof" ] || [ "$body" -eq 0 ]; then
    report_unmeasurable "$phase" "$dir" "$status" "$RAW_ERR" "$RAW_OUT" "${CHANGED[@]}"
    return 1
  fi
  return 0
}

BASE_TREE=""

# A detached worktree at HEAD gives the baseline content without touching the
# real working tree, its index, or the stash. Untracked files are absent there,
# which is what the old --include-untracked stash was emulating, and files that
# exist only in the index are absent too, so they still tag as "new".
setup_base_tree() {
  BASE_TREE="$(mktemp -d)"
  rm -rf "$BASE_TREE"
  git worktree add --detach -q "$BASE_TREE" HEAD >/dev/null 2>&1 || {
    echo "crap-check: could not create a baseline worktree at HEAD" >&2
    exit 2
  }
}

teardown_base_tree() {
  [ -n "$BASE_TREE" ] || return 0
  git worktree remove --force "$BASE_TREE" >/dev/null 2>&1 || rm -rf "$BASE_TREE"
  BASE_TREE=""
}

# A missing report means nothing was scored, which must never read as a pass.
# The coverage run's output and go-crap's own stderr both carry the reason, so
# both streams are reported.
report_unmeasurable() {
  local phase="$1" mod="$2" status="$3" err_file="$4" out_file="$5"
  shift 5
  collect_ignored_files "$phase" '*.go' ':(glob,exclude)**/vendor/**'
  {
    echo "crap-check: FAILED TO MEASURE - no usable coverage or CRAP report."
    echo "  phase:               $phase$(ignored_files_phase_suffix)"
    echo "  module:              $mod"
    echo "  selected files:      $*"
    echo "  tool exit status:    $status"
    if [ -s "$err_file" ]; then
      echo "  stderr:"
      sed 's/^/    /' "$err_file"
    fi
    if [ -s "$out_file" ]; then
      echo "  stdout (last $DIAG_LINES lines):"
      tail -n "$DIAG_LINES" "$out_file" | sed 's/^/    /'
    fi
    echo ""
    ignored_files_note "The baseline is a detached HEAD worktree, which has no
  ignored files at all, so any of these the tracked sources need to build are
  missing there:"
    echo "  This is NOT a pass. Zero rows means zero functions were scored, so"
    echo "  the CRAP gate did not run on this change."
    echo ""
    echo "  This is NOT a flake, and re-running will not clear it. Exit 4 is"
    echo "  emitted only when the coverage run exited non-zero or wrote an empty"
    echo "  profile. The two phases run sequentially, so they do not load each"
    echo "  other, and nothing here imposes a timeout. The stdout above names the"
    echo "  test that failed: fix that, then re-run. Do not read the output"
    echo "  through a filter that can drop the '--- FAIL:' line."
    echo ""
    echo "  Coverage comes from \`go test ./...\` by default. If that package set"
    echo "  cannot pass here (integration suites needing live Postgres, RabbitMQ,"
    echo "  etc.) it emits no report. Re-run with a package set that can pass:"
    echo ""
    echo "    CRAP_GO_TEST_COMMAND='go test ./internal/...' \\"
    echo "      $(dirname "$SKILL_LIB")/crap-check.sh"
    echo ""
  } >&2
}

# Run go-crap filtered to the changed files and emit
#   <pkg>.<func> <pkg> <complexity> <coverage> <crap>
# one per line. Coverage is a number or "n/a"; CRAP likewise.
# Returns $EXIT_UNMEASURABLE if any module yielded no report.
measure() {
  local out="$1" phase="$2" root="${3:-$REPO_ROOT}"
  local existing=()
  for f in "${CHANGED[@]}"; do
    if [ -f "$root/$f" ]; then existing+=("$f"); fi
  done
  : > "$out"
  if [ "${#existing[@]}" -eq 0 ]; then
    return 0
  fi

  # Multi-module repos: go-crap must run from inside a module, not the repo
  # root (a rootless-go.mod monorepo measures nothing and false-passes).
  # Group changed files by nearest enclosing go.mod; "." keeps the historic
  # single-module behavior.
  local -A bymod=() bypkg=()
  local f d
  for f in "${existing[@]}"; do
    d="$(dirname "$f")"
    while [ "$d" != "." ] && [ ! -f "$root/$d/go.mod" ]; do d="$(dirname "$d")"; done
    [ -f "$root/$d/go.mod" ] || d="."
    bymod["$d"]+="$f"$'\n'
    bypkg["$(dirname "$f")"]="$d"
  done

  # One coverage run per module, then a cheap scan per changed package: profiles
  # are module-wide, so re-running the suite per package would be waste.
  local mod status prof pkgdir pattern base bases
  for mod in "${!bymod[@]}"; do
    prof="$(mktemp)"
    if ! gen_coverage "$root/$mod" "$prof" "$phase"; then
      rm -f "$prof"
      return "$EXIT_UNMEASURABLE"
    fi

    while IFS= read -r pkgdir; do
      [ -n "$pkgdir" ] || continue
      [ "${bypkg[$pkgdir]}" = "$mod" ] || continue

      # Package pattern relative to the module go-crap is invoked from.
      if [ "$mod" = "." ]; then pattern="./$pkgdir"; else pattern="./${pkgdir#"$mod"/}"; fi
      [ "$pkgdir" = "$mod" ] && pattern="."
      pattern="${pattern%/.}"

      bases=()
      while IFS= read -r f; do
        [ -n "$f" ] || continue
        [ "$(dirname "$f")" = "$pkgdir" ] && bases+=("$(basename "$f")")
      done <<< "${bymod[$mod]}"

      status=0
      (cd "$root/$mod" && "${GOCRAP[@]}" "$pattern" --format json \
         --coverage-profile "$prof" "${GOCRAP_EXCLUDES[@]}") \
        >"$RAW_OUT" 2>"$RAW_ERR" || status=$?

      if [ "$status" -ne 0 ] || ! python3 -c "import json,sys; json.load(open(sys.argv[1]))" \
           "$RAW_OUT" 2>/dev/null; then
        report_unmeasurable "$phase" "$mod" "$status" "$RAW_ERR" "$RAW_OUT" "${bases[@]}"
        rm -f "$prof"
        return "$EXIT_UNMEASURABLE"
      fi

      python3 "$SKILL_LIB/parse_gocrap.py" "$RAW_OUT" "${bases[@]}" >> "$out"
    done < <(printf '%s\n' "${!bypkg[@]}")
    rm -f "$prof"
  done
}


BASE="$(mktemp)"
CUR="$(mktemp)"
RAW_OUT="$(mktemp)"
RAW_ERR="$(mktemp)"

# crap4go writes target/coverage/coverage.out to the repo root on every run.
# Strip it after each measurement so the artifact doesn't collide with git
# (e.g., when --include-untracked stashes it before pop).
clean_target() {
  rm -rf target/coverage
  rmdir target 2>/dev/null || true
}

cleanup() { rm -f "$BASE" "$CUR" "$RAW_OUT" "$RAW_ERR"; clean_target; teardown_base_tree; }
trap cleanup EXIT

# Baseline at HEAD, in its own worktree. Failing here is fatal too: without a
# baseline every function would be mistagged "new".
setup_base_tree
measure "$BASE" "$PHASE_BASELINE" "$BASE_TREE" || exit $?
teardown_base_tree

# Current state: the real working tree, with its index untouched throughout.
measure "$CUR" "$PHASE_CURRENT" "$REPO_ROOT" || exit $?
clean_target

# Join by "<pkg>.<func>" and classify.
#   - non-main packages: CRAP thresholds 6 / 8, with NEEDS_TESTS gate
#                        when cov<80% on new or worsened functions.
#   - package main:      complexity-only rule, threshold <= 5.
ROWS="$(awk -v BASEFILE="$BASE" '
  function score(pkg, cc, crap) {
    if (pkg == "main") return cc + 0
    if (crap == "n/a") return 0
    return crap + 0
  }
  function status(pkg, s, cov, tag) {
    if (pkg != "main" && cov != "n/a" && cov+0 < 80 && (tag == "new" || tag == "worsened")) {
      return "NEEDS_TESTS"
    }
    if (pkg == "main") {
      if (s <= 5) return "OK_MAIN"
      return "HARD_MAIN"
    }
    if (s <= 6) return "OK"
    if (s <= 8) return "SOFT"
    return "HARD"
  }
  FILENAME == BASEFILE {
    base_pkg[$1]  = $2
    base_cc[$1]   = $3
    base_cov[$1]  = $4
    base_crap[$1] = $5
    next
  }
  {
    fn = $1; pkg = $2; cc = $3; cov = $4; crap = $5
    cur_score = score(pkg, cc, crap)
    tag = "new"
    if (fn in base_cc) {
      base_score = score(base_pkg[fn], base_cc[fn], base_crap[fn])
      if (cur_score > base_score + 0.05) tag = "worsened"
      else                                tag = "unchanged"
    }
    st = status(pkg, cur_score, cov, tag)
    if (pkg == "main") {
      printf "%-50s complexity=%-2s  coverage=n/a    CRAP=n/a    %-11s  (%s)\n", \
             fn, cc, st, tag
    } else {
      printf "%-50s complexity=%-2s  coverage=%s%%  CRAP=%s  %-11s  (%s)\n", \
             fn, cc, cov, crap, st, tag
    }
  }
' "$BASE" "$CUR")"

if [ -n "$ROWS" ]; then
  printf '%s\n' "$ROWS"
  echo "crap-check: measured $(printf '%s\n' "$ROWS" | wc -l | tr -d ' ') Go function(s) in ${#CHANGED[@]} changed file(s)."
else
  echo "crap-check: no Go functions to measure in ${#CHANGED[@]} changed Go file(s)."
  echo "crap-check: the scan ran and had nothing to score (declaration-only or comment-only change). Clean pass, not a measurement failure."
fi

GOCOGNIT_OVER=15
COGNIT_FILES=()
for f in "${CHANGED[@]}"; do
  [ -f "$f" ] && COGNIT_FILES+=("$f")
done

if [ "${#COGNIT_FILES[@]}" -gt 0 ]; then
  COGNIT_STATUS=0
  COGNIT_OUT="$(go run github.com/uudashr/gocognit/cmd/gocognit@latest -over "$GOCOGNIT_OVER" "${COGNIT_FILES[@]}" 2>"$RAW_ERR")" || COGNIT_STATUS=$?
  if [ "$COGNIT_STATUS" -ne 0 ]; then
    echo "crap-check: cognitive complexity unavailable (gocognit exit $COGNIT_STATUS); advisory only, CRAP table above still stands." >&2
    tail -n 5 "$RAW_ERR" | sed 's/^/  /' >&2
  elif [ -n "$COGNIT_OUT" ]; then
    echo ""
    echo "Cognitive complexity (advisory, >${GOCOGNIT_OVER}):"
    printf '%s\n' "$COGNIT_OUT"
  fi
fi
