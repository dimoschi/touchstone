#!/usr/bin/env bash
# mutation-check-go.sh: surviving-mutant report for Go changes vs MUTATION_BASE.
# Runs quality-gates/mutago pinned (young project, no compat guarantee) with
# line-level git-diff scoping, and normalizes its agentic JSON into SURVIVED
# rows via parse_mutago.py.
#
# A clean working tree is required, and not because mutago touches the tree:
# v2.8.1 writes each mutant to its own MkdirTemp and substitutes it through
# `go test -overlay`, so a killed run strands nothing. The reason is the ledger.
# mutago reads sources from the worktree, while ../mutation-check.sh keys its
# record on HEAD blobs, so measuring uncommitted content would record a pass for
# bytes nothing ever tested.
#
# Mutants inside the body of `func main()` are exempted and listed on stderr
# instead of blocking; see parse_mutago.py. Only that function, not the rest of
# package main.
#
# Invoked by ../mutation-check.sh. Env:
#   MUTATION_BASE           diff base ref (required)
#   MUTATION_FILES          newline-separated changed .go files (repo-relative)
#   MUTATION_GO_RUNNER      command prefix for mutago, for code whose tests only
#                           run elsewhere (a container with the daemon they need)
#   MUTATION_GO_TEST_FLAGS  extra `go test` flags passed via mutago --test-flags
#   MUTATION_GO_WORKERS     parallel mutants (default: cores/4, min 1)
#   MUTATION_GO_MAXPROCS    GOMAXPROCS per worker (default: 2)
#   MUTATION_GOCACHE        build cache for mutant compiles (default: <GOCACHE>-mutation)
#   MUTATION_GOCACHE_MAX_MB reset that cache once it exceeds this (default: 8192)
#
# Exit codes: 0 measured, 2 setup problem, 4 could not measure.

set -euo pipefail

SKILL_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SKILL_LIB/tool-versions.sh"

MUTAGO_VERSION="${MUTATION_GO_MUTAGO_VERSION:-$MUTAGO_VERSION_DEFAULT}"
MUTAGO_PKG="github.com/quality-gates/mutago/v2/cmd/mutago"
EXIT_UNMEASURABLE=4
DIAG_LINES=30

command -v go >/dev/null || { echo "mutation-check[go]: go not on PATH" >&2; exit 2; }
[ -n "${MUTATION_BASE:-}" ] || { echo "mutation-check[go]: MUTATION_BASE not set" >&2; exit 2; }

if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "mutation-check[go]: working tree is dirty. A result is only recordable" >&2
  echo "  for the committed content the ledger keys on; commit or stash first," >&2
  echo "  then re-run." >&2
  exit 2
fi

CHANGED=()
while IFS= read -r f; do
  [ -n "$f" ] && CHANGED+=("$f")
done <<< "${MUTATION_FILES:-}"
if [ "${#CHANGED[@]}" -eq 0 ]; then
  exit 0
fi

# Group changed files by nearest enclosing go.mod, same as crap-check-go.sh:
# multi-module repos must run mutago from inside each module. Keep the file
# names, not just the module: MUTATION_FILES arrives already filtered by the
# parent (generated mocks, sqlc output, tests), and handing mutago ./... instead
# would throw that away. Passing the names narrows what mutago loads but does
# not bound what it reports: it resolves each file target to its enclosing
# package and mutates every changed line in it, so an excluded sibling still
# shows up. parse_mutago.py takes the same list and drops those rows.
# Paths are made module-relative for the cd below.
# Module resolution comes from lib/go_modules.py, shared with crap-check-go.sh
# and deadcode-check.sh so the three gates cannot disagree about which module
# owns a file. Deleted files are dropped first: mutating a file that is gone is
# not possible, and go_modules resolves by path without checking the disk.
BYMOD="$(mktemp)"
# Set here rather than beside RAW_OUT: the "nothing to mutate" exit below comes
# first and would otherwise leak this file. The rest are unset then, which the
# :- guards make harmless.
trap 'rm -f "$BYMOD" "${RAW_OUT:-}" "${RAW_ERR:-}"' EXIT
for f in "${CHANGED[@]}"; do
  [ -f "$f" ] || continue
  printf '%s\n' "$f"
done | python3 "$SKILL_LIB/go_modules.py" group | cut -f1,4 > "$BYMOD"

if [ ! -s "$BYMOD" ]; then
  echo "mutation-check[go]: all changed Go files are deleted; nothing to mutate."
  exit 0
fi

MODS=()
while IFS= read -r m; do
  [ -n "$m" ] && MODS+=("$m")
done < <(cut -f1 "$BYMOD" | sort -u)

targets_for() { awk -F'\t' -v m="$1" '$1 == m { print $2 }' "$BYMOD"; }

RAW_OUT="$(mktemp)"
RAW_ERR="$(mktemp)"

# mutago defaults to --workers=0, i.e. one worker per CPU, and every worker
# shells out to `go test`, which itself parallelizes to GOMAXPROCS. Unbounded
# that is cores x cores concurrent test processes plus as many concurrent Go
# builds, which swaps a laptop to a standstill. Bound both factors.
NCPU="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"
WORKERS="${MUTATION_GO_WORKERS:-$((NCPU / 4))}"
[ "$WORKERS" -lt 1 ] && WORKERS=1
GO_MAXPROCS="${MUTATION_GO_MAXPROCS:-2}"

# Every mutant compiles through `go test -overlay`, so its artefacts hash
# differently and are never reused: runs only add, and Go's 5-day trim does not
# keep up (tens of GB). Isolate them, persistent so deps stay warm across runs,
# and reset past the budget at the cost of one cold dependency build. The budget
# must clear several full runs or it defeats itself: one measured 2.5 GB, so the
# old 4 GB cap fired every second run and turned warm deps cold each time.
MUTATION_GOCACHE="${MUTATION_GOCACHE:-$(go env GOCACHE)-mutation}"
if [ -d "$MUTATION_GOCACHE" ]; then
  # du exits non-zero on an unreadable entry but still reports the total.
  cache_mb="$(du -sm "$MUTATION_GOCACHE" 2>/dev/null | cut -f1 || true)"
  if [ "${cache_mb:-0}" -gt "${MUTATION_GOCACHE_MAX_MB:-8192}" ]; then
    echo "mutation-check[go]: resetting mutant build cache (${cache_mb}MB)" >&2
    rm -rf "$MUTATION_GOCACHE"
  fi
fi
export GOCACHE="$MUTATION_GOCACHE"

MUTAGO_ARGS=(--git-diff-lines --git-diff-base="$MUTATION_BASE" --logger-agentic-json --quiet
             --workers="$WORKERS")
if [ -n "${MUTATION_GO_TEST_FLAGS:-}" ]; then
  # `=` is required: go-flags reads `--test-flags -short` as two options and refuses,
  # so the space form passed no value at all. Several flags in one string are fine.
  MUTAGO_ARGS+=(--test-flags="$MUTATION_GO_TEST_FLAGS")
fi

# A tag-excluded file yields no mutants, which reads as "nothing mutable
# changed": a pass on code nothing compiled. go list omits it from GoFiles.
UNANALYSED=""
for mod in ${MODS[@]+"${MODS[@]}"}; do
  SEEN=()
  while IFS= read -r t; do
    [ -n "$t" ] && SEEN+=("$t")
  done < <(targets_for "$mod")
  for t in ${SEEN[@]+"${SEEN[@]}"}; do
    listed="$(cd "$mod" && go list -f \
      '{{range .GoFiles}}{{.}} {{end}}{{range .CgoFiles}}{{.}} {{end}}' \
      "$(dirname "$t")" 2>/dev/null || true)"
    case " $listed " in *" $(basename "$t") "*) continue ;; esac
    reported="${mod%/}/${t#./}"
    UNANALYSED+="    ${reported#./}"$'\n'
  done
done
if [ -n "$UNANALYSED" ]; then
  {
    echo "mutation-check[go]: FAILED TO MEASURE - changed files are not in this build."
    echo "  mutago generates no mutants for a file nothing compiles, so the gate"
    echo "  refuses rather than reporting a pass on unbuilt code."
    echo ""
    # Name the tag and price it. "Set the tag" alone sends you in a circle, because
    # enabling one drops every test file constrained against it.
    while read -r path; do
      [ -n "$path" ] || continue
      echo "    $path"
      tags="$(python3 "$SKILL_LIB/buildtag_diagnosis.py" tags "$path" 2>/dev/null || true)"
      if [ -z "$tags" ]; then
        echo "      no //go:build constraint found, so this is the toolchain, not a tag:"
        echo "      check whether it needs CGO, a different GOOS/GOARCH, or GOFLAGS."
        continue
      fi
      for tag in $tags; do
        conflicts="$(python3 "$SKILL_LIB/buildtag_diagnosis.py" conflicts "." "$tag" 2>/dev/null || echo 0)"
        echo "      needs -tags=$tag; setting it excludes $conflicts test file(s)"
        echo "      constrained !$tag, whose mutants would then survive spuriously."
      done
    done <<< "$(printf '%s' "$UNANALYSED" | sed 's/^ *//')"
    echo ""
    echo "  So this is a choice, not a missing flag:"
    echo "    - measure this path in a run of its own, with"
    echo "      MUTATION_GO_TEST_FLAGS='-tags=<tag>', and read its survivors knowing"
    echo "      the excluded tests could not run; or"
    echo "    - bring it into the default build, by dropping the constraint or"
    echo "      splitting the mutable logic into a file that builds unconditionally"
    echo "      (usually right when this is test-support code); or"
    echo "    - run the gate where it does build (MUTATION_GO_RUNNER)."
    echo ""
    echo "  There is deliberately no flag for skipping the file: leaving changed"
    echo "  source unmeasured while the ledger records the branch as covered is an"
    echo "  exception only the user can grant, so surface it rather than route round it."
  } >&2
  exit "$EXIT_UNMEASURABLE"
fi

total_rows=0
for mod in ${MODS[@]+"${MODS[@]}"}; do
  status=0
  TARGETS=()
  while IFS= read -r t; do
    [ -n "$t" ] && TARGETS+=("$t")
  done < <(targets_for "$mod")
  (cd "$mod" && GOMAXPROCS="$GO_MAXPROCS" \
    ${MUTATION_GO_RUNNER:+$MUTATION_GO_RUNNER} \
    go run "$MUTAGO_PKG@$MUTAGO_VERSION" "${MUTAGO_ARGS[@]}" "${TARGETS[@]}") \
    >"$RAW_OUT" 2>"$RAW_ERR" || status=$?
  REPORT="$mod/mutago-agentic.json"

  if [ "$status" -ne 0 ] || [ ! -f "$REPORT" ]; then
    {
      echo "mutation-check[go]: FAILED TO MEASURE - mutago produced no report."
      echo "  module:            $mod"
      echo "  mutago exit:       $status"
      if [ -s "$RAW_ERR" ]; then
        echo "  stderr:"
        tail -n "$DIAG_LINES" "$RAW_ERR" | sed 's/^/    /'
      fi
      if [ -s "$RAW_OUT" ]; then
        echo "  stdout (last $DIAG_LINES lines):"
        tail -n "$DIAG_LINES" "$RAW_OUT" | sed 's/^/    /'
      fi
      echo ""
      echo "  This is NOT a pass: zero mutants were scored. If the default"
      echo "  \`go test ./...\` cannot pass here, narrow it, e.g.:"
      echo "    MUTATION_GO_TEST_FLAGS='-run TestUnit' or scope the package set."
    } >&2
    rm -f "$mod"/mutago-agentic.json "$mod"/report.json "$mod"/mutago-summary.json
    exit "$EXIT_UNMEASURABLE"
  fi

  prefix=""
  [ "$mod" != "." ] && prefix="$mod/"
  rows="$(python3 "$SKILL_LIB/parse_mutago.py" "$REPORT" "$prefix" "${TARGETS[@]}")"
  rm -f "$mod"/mutago-agentic.json "$mod"/report.json "$mod"/mutago-summary.json
  if [ -n "$rows" ]; then
    printf '%s\n' "$rows"
    total_rows=$((total_rows + $(printf '%s\n' "$rows" | grep -c ' SURVIVED ')))
  fi
done

if [ "$total_rows" -eq 0 ]; then
  echo "mutation-check[go]: all mutants on changed lines were killed (or nothing mutable changed)."
fi
