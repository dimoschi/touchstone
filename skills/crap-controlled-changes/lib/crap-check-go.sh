#!/usr/bin/env bash
# crap-check.sh: per-function CRAP report for staged Go changes.
# Complexity and function spans come from unclebob/crapper (lib/crapper_spans.py,
# run through uv), coverage from `go test -coverprofile`; lib/parse_gocover.py
# joins them. Compares the working tree (with staged changes) against the HEAD
# baseline and prints one row per function in changed files with status and tag.
#
# Exit codes: 0 measured (possibly zero functions), 2 setup problem (no go, no
# uv, crapper failed), 4 could not measure (no usable coverage for a changed file).
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
# CRAP_CRAPPER_RUN replaces the launcher crapper runs through (see
# lib/uv-pinned.sh); it exists for the suites here, which run without a network.
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

. "$SKILL_LIB/tool-versions.sh"
. "$SKILL_LIB/uv-pinned.sh"
CRAPPER_RUN="${CRAP_CRAPPER_RUN:-}"
pinned_ready "crap-check[go]" crapper CRAP_CRAPPER_RUN "$CRAPPER_RUN" || exit 2
GO_TEST_COMMAND="${CRAP_GO_TEST_COMMAND:-}"

# The coverage profile is generated here, checked for content, and only then
# read: a run that collects nothing must be reported, not scored as 0%. It also
# has to honour CRAP_GO_TEST_COMMAND, which repos needing live services depend on.
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
# The coverage run's own output carries the reason, so both of its streams are
# reported.
report_unmeasurable() {
  local phase="$1" mod="$2" status="$3" err_file="$4" out_file="$5"
  shift 5
  collect_ignored_files "$phase" '*.go' ':(glob,exclude)**/vendor/**'
  {
    echo "crap-check: FAILED TO MEASURE - no usable coverage report."
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

# A changed file with functions that the coverage profile has no block for was
# never measured, and has no row: its coverage is unknown, not 0%.
report_unprofiled() {
  local files=("$@")
  {
    echo "crap-check: FAILED TO MEASURE - the coverage profile has no data for changed file(s):"
    printf '    %s\n' "${files[@]}"
    echo ""
    echo "  This is NOT a pass. No row was built for these files: there is no"
    echo "  coverage percentage to report for them, not a genuine 0%."
    echo ""
    echo "  Their package was not part of the coverage run. If CRAP_GO_TEST_COMMAND"
    echo "  is set, make it cover these packages ({packages} stands for them):"
    echo ""
    echo "    CRAP_GO_TEST_COMMAND='go test ./internal/... {packages}' \\"
    echo "      $(dirname "$SKILL_LIB")/crap-check.sh"
    echo ""
  } >&2
}

# pkg_pattern prints pkgdir as a package pattern relative to module mod, the
# directory go test and go list are invoked from.
pkg_pattern() {
  local mod="$1" pkgdir="$2" pattern
  if [ "$mod" = "." ]; then pattern="./$pkgdir"; else pattern="./${pkgdir#"$mod"/}"; fi
  [ "$pkgdir" = "$mod" ] && pattern="."
  printf '%s\n' "${pattern%/.}"
}

# score_module appends, for the changed files of one module, a row
#   <pkg>.<func> <pkg> <complexity> <coverage> <crap>
# per function to $out. Returns $EXIT_UNMEASURABLE when `go list` fails and 2
# when crapper does. Changed files the coverage profile has no block for are
# appended to $UNPROFILED, and in the baseline phase scored at 0% as well.
score_module() {
  local out="$1" phase="$2" root="$3" mod="$4" prof="$5" patterns_file="$6"
  shift 6
  local patterns=() built spans unprofiled modpath status=0 zero_fill=()
  read_lines patterns < "$patterns_file"
  built="$(mktemp)"
  spans="$(mktemp)"
  unprofiled="$(mktemp)"

  # Which of the changed files this build includes. A file a build constraint
  # leaves out (another GOOS, an ignore tag) has no block in the profile, and
  # reading that as "unmeasured" would refuse a change nothing can measure.
  (cd "$root/$mod" && go list -e \
     -f '{{range .GoFiles}}{{$.Dir}}/{{.}}{{"\n"}}{{end}}{{range .CgoFiles}}{{$.Dir}}/{{.}}{{"\n"}}{{end}}' \
     "${patterns[@]}") >"$built" 2>"$RAW_ERR" || status=$?
  if [ "$status" -eq 0 ]; then
    crapper_spans "crap-check[go]" "$root" "$spans" "$@" || status=2
  else
    report_unmeasurable "$phase" "$mod" "$status" "$RAW_ERR" "$RAW_OUT" "$@"
    status="$EXIT_UNMEASURABLE"
  fi

  if [ "$status" -eq 0 ]; then
    modpath="$(cd "$root" && python3 "$SKILL_LIB/go_modules.py" modpath "$mod")"
    [ "$phase" = "$PHASE_BASELINE" ] && zero_fill=(--zero-fill-unmeasured)
    python3 "$SKILL_LIB/parse_gocover.py" "$spans" "$prof" "$modpath" "$mod" \
      --root "$root" --built "$built" --unmeasured-out "$unprofiled" \
      ${zero_fill[@]+"${zero_fill[@]}"} >> "$out" || status=$?
    cat "$unprofiled" >> "$UNPROFILED"
  fi
  rm -f "$built" "$spans" "$unprofiled"
  return "$status"
}

# Measure the changed files and emit one row per function (see score_module).
# Returns $EXIT_UNMEASURABLE if any module yielded no coverage.
measure() {
  local out="$1" phase="$2" root="${3:-$REPO_ROOT}"
  local existing=() f
  for f in "${CHANGED[@]}"; do
    if [ -f "$root/$f" ]; then existing+=("$f"); fi
  done
  : > "$out"
  : > "$UNPROFILED"
  if [ "${#existing[@]}" -eq 0 ]; then
    return 0
  fi

  # Multi-module repos: the tools must run from inside a module, not the repo
  # root (a rootless-go.mod monorepo measures nothing and false-passes).
  # Group changed files by nearest enclosing go.mod; "." keeps the historic
  # single-module behavior. lib/go_modules.py does the resolution, shared with
  # deadcode-check.sh and mutation-check-go.sh so all three gates agree on which
  # module owns a file. Rows are "<moddir>\t<pkgdir>\t<repo-relative-file>".
  local grouped
  grouped="$(mktemp)"
  printf '%s\n' "${existing[@]}" \
    | (cd "$root" && python3 "$SKILL_LIB/go_modules.py" group) | cut -f1-3 > "$grouped"

  # One coverage run per module: profiles are module-wide, so re-running the
  # suite per package would be waste.
  local mod status prof pkgdir patterns patterns_file modfiles
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

    patterns_file="$(mktemp)"
    printf '%s\n' "${patterns[@]}" > "$patterns_file"
    read_lines modfiles < <(awk -F'\t' -v m="$mod" '$1 == m { print $3 }' "$grouped")
    status=0
    score_module "$out" "$phase" "$root" "$mod" "$prof" "$patterns_file" "${modfiles[@]}" || status=$?
    rm -f "$prof" "$patterns_file"
    if [ "$status" -ne 0 ]; then
      rm -f "$grouped"
      return "$status"
    fi
  done < <(cut -f1 "$grouped" | sort -u)
  rm -f "$grouped"
}


BASE="$(mktemp)"
CUR="$(mktemp)"
RAW_OUT="$(mktemp)"
RAW_ERR="$(mktemp)"
UNPROFILED="$(mktemp)"

cleanup() { rm -f "$BASE" "$CUR" "$RAW_OUT" "$RAW_ERR" "$UNPROFILED"; teardown_base_tree; }
trap cleanup EXIT

# Everything the baseline's rows depend on. The scripts are in it so an edit to
# how rows are produced never reads rows produced the old way.
baseline_key() {
  {
    git rev-parse HEAD
    printf '%s\n' "${CHANGED[@]}" | sort
    printf 'cmd=%s\n' "${GO_TEST_COMMAND:-<changed packages>}"
    printf 'crapper=%s\n' "${CRAPPER_RUN:-$CRAPPER_SHA_DEFAULT}"
    go version
    go env GOFLAGS CGO_ENABLED GOOS GOARCH GOEXPERIMENT
    git hash-object "$SKILL_LIB/crap-check-go.sh" "$SKILL_LIB/parse_gocover.py" \
      "$SKILL_LIB/go_modules.py" "$SKILL_LIB/crapper_spans.py" "$SKILL_LIB/uv-pinned.sh"
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
  if [ -s "$UNPROFILED" ]; then
    # HEAD never having measured a file is not this run's failure: the file may
    # be new since HEAD, or only covered by a test this change adds. Its rows are
    # scored at 0% and compared normally, so a function unchanged since HEAD
    # still tags "unchanged" rather than a false "new".
    {
      echo "crap-check: baseline (HEAD) has no coverage data for:"
      sed 's/^/    /' "$UNPROFILED"
      echo "  Rows for these are zero-filled at 0% and compared normally, not tagged new."
    } >&2
  fi
  if [ -n "$CACHED_BASE" ]; then
    mkdir -p "$BASELINE_CACHE_DIR"
    find "$BASELINE_CACHE_DIR" -name '*.tsv' -mtime +14 -delete 2>/dev/null || true
    cp "$BASE" "$CACHED_BASE.$$" && mv "$CACHED_BASE.$$" "$CACHED_BASE"
  fi
fi

# Current state: the real working tree, with its index untouched throughout.
measure "$CUR" "$PHASE_CURRENT" "$REPO_ROOT" || exit $?
if [ -s "$UNPROFILED" ]; then
  read_lines UNPROFILED_LIST < "$UNPROFILED"
  report_unprofiled "${UNPROFILED_LIST[@]}"
  exit "$EXIT_UNMEASURABLE"
fi

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
