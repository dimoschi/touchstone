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
# CRAP_GO_TEST_COMMAND overrides the command used to produce coverage. By
# default it is `go test` on the changed files' packages only: without
# -coverpkg a package's coverage comes from its own tests alone, so the rest of
# the module cannot move a score. An override runs as given, with {packages}
# replaced by those packages, e.g.
#   CRAP_GO_TEST_COMMAND='go test ./internal/...'
#   CRAP_GO_TEST_COMMAND='some-runner go test {packages}'
#
# The baseline depends only on HEAD, the change set and the build
# configuration, so it is cached under the common git dir and a retry against
# the same HEAD measures only the change. CRAP_BASELINE_CACHE=0 measures it
# anyway. The key cannot see services the suite reaches (a Postgres that was
# down makes its tests skip), so rerun with the cache off after fixing one.

set -euo pipefail

EXIT_UNMEASURABLE=4
DIAG_LINES=30

SKILL_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SKILL_LIB/read-lines.sh"
. "$SKILL_LIB/ignored-files.sh"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "crap-check: not inside a git repo" >&2
  exit 2
}
cd "$REPO_ROOT"

if [ -n "${CRAP_FILES:-}" ]; then
  read_lines CHANGED <<< "$CRAP_FILES"
else
  read_lines CHANGED < <(git diff --name-only --cached -- '*.go' ':(exclude)*_test.go' ':(exclude)*mock_*.go' ':(exclude)*_mock.go' ':(exclude)*.sql.go' ':(exclude)*.pb.go')
fi
if [ "${#CHANGED[@]}" -eq 0 ] || [ -z "${CHANGED[0]}" ]; then
  exit 0
fi

command -v go >/dev/null || { echo "crap-check: go not on PATH" >&2; exit 2; }

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/tool-versions.sh"
GOCRAP_VERSION="${CRAP_GO_GOCRAP_VERSION:-$GOCRAP_VERSION_DEFAULT}"
GOCRAP_PKG="github.com/padiazg/go-crap"
GOCRAP=(go run "$GOCRAP_PKG@$GOCRAP_VERSION" scan)
GO_TEST_COMMAND="${CRAP_GO_TEST_COMMAND:-}"

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
  local dir="$1" prof="$2" phase="$3" status=0 body cmd="$GO_TEST_COMMAND" pkgs
  shift 3
  [ -n "$cmd" ] || cmd='go test {packages}'
  pkgs="$(printf '%q ' "$@")"
  cmd="${cmd//\{packages\}/${pkgs% }}"
  ( cd "$dir" && eval "$cmd" -coverprofile="$prof" -covermode=set ) \
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
    echo "  Coverage comes from \`go test\` on the changed packages by default. If"
    echo "  those cannot pass here (integration suites needing live Postgres,"
    echo "  RabbitMQ, etc.) it emits no report. Re-run with a package set that can pass:"
    echo ""
    echo "    CRAP_GO_TEST_COMMAND='go test ./internal/...' \\"
    echo "      $(dirname "$SKILL_LIB")/crap-check.sh"
    echo ""
  } >&2
}

# pkg_pattern prints pkgdir as a package pattern relative to module mod, the
# directory go test and go-crap are invoked from.
pkg_pattern() {
  local mod="$1" pkgdir="$2" pattern
  if [ "$mod" = "." ]; then pattern="./$pkgdir"; else pattern="./${pkgdir#"$mod"/}"; fi
  [ "$pkgdir" = "$mod" ] && pattern="."
  printf '%s\n' "${pattern%/.}"
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
  # single-module behavior. lib/go_modules.py does the resolution, shared with
  # deadcode-check.sh and mutation-check-go.sh so all three gates agree on which
  # module owns a file. Rows are "<moddir>\t<pkgdir>\t<repo-relative-file>".
  local grouped
  grouped="$(mktemp)"
  printf '%s\n' "${existing[@]}" \
    | (cd "$root" && python3 "$SKILL_LIB/go_modules.py" group) | cut -f1-3 > "$grouped"

  # One coverage run per module, then a cheap scan per changed package: profiles
  # are module-wide, so re-running the suite per package would be waste.
  local mod status prof pkgdir pattern base bases patterns
  while IFS= read -r mod; do
    patterns=()
    while IFS= read -r pkgdir; do
      patterns+=("$(pkg_pattern "$mod" "$pkgdir")")
    done < <(awk -F'\t' -v m="$mod" '$1 == m { print $2 }' "$grouped" | sort -u)
    prof="$(mktemp)"
    if ! gen_coverage "$root/$mod" "$prof" "$phase" "${patterns[@]}"; then
      rm -f "$prof"
      return "$EXIT_UNMEASURABLE"
    fi

    while IFS= read -r pkgdir; do
      [ -n "$pkgdir" ] || continue

      pattern="$(pkg_pattern "$mod" "$pkgdir")"

      bases=()
      while IFS= read -r f; do
        [ -n "$f" ] || continue
        bases+=("$(basename "$f")")
      done < <(awk -F'\t' -v m="$mod" -v p="$pkgdir" '$1 == m && $2 == p { print $3 }' "$grouped")

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
    done < <(awk -F'\t' -v m="$mod" '$1 == m { print $2 }' "$grouped" | sort -u)
    rm -f "$prof"
  done < <(cut -f1 "$grouped" | sort -u)
  rm -f "$grouped"
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

# Everything the baseline's rows depend on. The scripts are in it so an edit to
# how rows are produced never reads rows produced the old way.
baseline_key() {
  {
    git rev-parse HEAD
    printf '%s\n' "${CHANGED[@]}" | sort
    printf 'cmd=%s\n' "${GO_TEST_COMMAND:-<changed packages>}"
    printf 'gocrap=%s\n' "$GOCRAP_VERSION"
    go version
    go env GOFLAGS CGO_ENABLED GOOS GOARCH GOEXPERIMENT
    git hash-object "$SKILL_LIB/crap-check-go.sh" "$SKILL_LIB/parse_gocrap.py" "$SKILL_LIB/go_modules.py"
  } | git hash-object --stdin
}

BASELINE_CACHE_DIR="$(git rev-parse --path-format=absolute --git-common-dir)/crap-check-baseline"
CACHED_BASE=""
[ "${CRAP_BASELINE_CACHE:-1}" = 0 ] || CACHED_BASE="$BASELINE_CACHE_DIR/$(baseline_key).tsv"

# Baseline at HEAD, in its own worktree. Failing here is fatal too: without a
# baseline every function would be mistagged "new". Only a successful
# measurement is cached, and it is renamed into place so a concurrent run never
# reads half a file.
if [ -n "$CACHED_BASE" ] && [ -f "$CACHED_BASE" ]; then
  cp "$CACHED_BASE" "$BASE"
else
  setup_base_tree
  measure "$BASE" "$PHASE_BASELINE" "$BASE_TREE" || exit $?
  teardown_base_tree
  if [ -n "$CACHED_BASE" ]; then
    mkdir -p "$BASELINE_CACHE_DIR"
    find "$BASELINE_CACHE_DIR" -name '*.tsv' -mtime +14 -delete 2>/dev/null || true
    cp "$BASE" "$CACHED_BASE.$$" && mv "$CACHED_BASE.$$" "$CACHED_BASE"
  fi
fi

# Current state: the real working tree, with its index untouched throughout.
measure "$CUR" "$PHASE_CURRENT" "$REPO_ROOT" || exit $?
clean_target

# Join by "<pkg>.<func>" and classify. The bands, the coverage requirement and
# the `package main` rule are lib/thresholds.py, shared with the other two
# modules and overridable per repo in .crap-gated.
ROWS="$(python3 "$SKILL_LIB/classify_rows.py" \
          --base "$BASE" --current "$CUR" --layout go --repo-root "$REPO_ROOT")" || {
  echo "crap-check: FAILED TO MEASURE - the measured rows could not be classified." >&2
  echo "  No row was built, which is not the same as having nothing to score." >&2
  exit 4
}

if [ -n "$ROWS" ]; then
  printf '%s\n' "$ROWS"
  echo "crap-check: measured $(printf '%s\n' "$ROWS" | wc -l | tr -d ' ') Go function(s) in ${#CHANGED[@]} changed file(s)."
else
  echo "crap-check: no Go functions to measure in ${#CHANGED[@]} changed Go file(s)."
  echo "crap-check: the scan ran and had nothing to score (declaration-only or comment-only change). Clean pass, not a measurement failure."
fi

GOCOGNIT_OVER="$(python3 "$SKILL_LIB/thresholds.py" --repo-root "$REPO_ROOT" --show cognitive)"
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
