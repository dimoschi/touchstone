#!/usr/bin/env bash
# deadcode-check.sh: block code this diff adds that nothing can reach.
#
# CRAP and mutation testing both reward covered, asserted code, so a speculative
# helper plus a test for it passes them: the test is what makes it look alive.
# This closes that loophole. golang.org/x/tools/cmd/deadcode builds a call graph
# from every main package by Rapid Type Analysis and reports what is unreachable.
# It is run WITHOUT -test on purpose: with -test, a helper called only by its own
# test counts as reachable, which is exactly the case worth catching.
#
# Only symbols this diff *added* are reported, so existing dead code does not
# block new work. Go only for now; other languages exit 0 with a note.
#
#   deadcode-check.sh                      check the staged diff
#   deadcode-check.sh --accept '<key>'     record a user-approved exception
#   deadcode-check.sh --revoke '<key>'     drop one, once it is reachable again
#
# A key is "<repo-relative-file>|<symbol>". Acceptance is per branch and needs
# explicit user approval: unreachable is not always deletable (a method may exist
# to satisfy an interface nothing calls yet), which is why the escape hatch is
# recorded rather than absent.
#
# In a multi-module repo a library's callers sit in another module, so each
# changed module is analysed from every module that replaces it as well as
# itself, and a symbol is dead only when every root that built its package
# agrees. Analysing one module alone reported all of db/'s exported API as
# unreachable, which is a false positive an --accept would have frozen in.
#
# Exit codes: 0 nothing unreachable was added, 1 findings, 2 setup problem.

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SKILL_DIR/lib"
DEADCODE_VERSION="${DEADCODE_GO_VERSION:-latest}"
DEADCODE_PKG="golang.org/x/tools/cmd/deadcode"
# go/packages takes build tags as an explicit flag, not from GOFLAGS, so a
# module whose real files sit behind a tag (a CGO driver excluded by a mock
# tag, say) is otherwise compiled tagless and fails to analyse.
DEADCODE_TAGS_FLAG=()
if [ -n "${DEADCODE_TAGS:-}" ]; then
  DEADCODE_TAGS_FLAG=(-tags="$DEADCODE_TAGS")
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "deadcode-check: not inside a git repo" >&2
  exit 2
}
cd "$REPO_ROOT"

BRANCH="$(git symbolic-ref --quiet --short HEAD || echo detached)"
STORE="$(git rev-parse --git-dir)/deadcode-accepted.json"

if [ "${1:-}" = "--accept" ]; then
  [ -n "${2:-}" ] || { echo "usage: deadcode-check.sh --accept '<file>|<symbol>'" >&2; exit 2; }
  exec python3 "$LIB_DIR/deadcode_accepted.py" add "$STORE" "$BRANCH" "$2"
fi

if [ "${1:-}" = "--revoke" ]; then
  [ -n "${2:-}" ] || { echo "usage: deadcode-check.sh --revoke '<file>|<symbol>'" >&2; exit 2; }
  exec python3 "$LIB_DIR/deadcode_accepted.py" remove "$STORE" "$BRANCH" "$2"
fi

GO_SPEC=('*.go' ':(exclude)*_test.go' ':(exclude)*mock_*.go' ':(exclude)*.sql.go')
CHANGED=()
while IFS= read -r f; do
  [ -n "$f" ] && CHANGED+=("$f")
done < <(git diff --name-only --cached -- "${GO_SPEC[@]}")
if [ "${#CHANGED[@]}" -eq 0 ]; then
  echo "deadcode-check: no staged Go files"
  exit 0
fi

# Only after establishing there is Go to analyse. Demanding the toolchain first
# made every PHP and Python commit fail with "go not on PATH", which is both
# wrong and unfixable from inside the project being committed.
command -v go >/dev/null || { echo "deadcode-check: go not on PATH" >&2; exit 2; }

ADDED="$(mktemp)"
RAW="$(mktemp)"
STAGED_TREE=""

teardown_staged_tree() {
  [ -n "$STAGED_TREE" ] || return 0
  git worktree remove --force "$STAGED_TREE" >/dev/null 2>&1 || rm -rf "$STAGED_TREE"
  STAGED_TREE=""
}
trap 'rm -f "$ADDED" "$RAW"; teardown_staged_tree' EXIT

# Reachability has to be judged on exactly what is about to be committed. Run
# against the working tree instead and an unstaged caller satisfies the gate:
# the dead symbol gets committed, its only caller does not. So the index is
# materialised as a dangling commit and checked out on its own.
setup_staged_tree() {
  local tree commit
  tree="$(git write-tree)" || {
    echo "deadcode-check: cannot write the index as a tree (unmerged paths?)" >&2
    exit 2
  }
  if git rev-parse --verify --quiet HEAD >/dev/null; then
    commit="$(git commit-tree "$tree" -p HEAD -m 'deadcode-check: staged state')"
  else
    commit="$(git commit-tree "$tree" -m 'deadcode-check: staged state')"
  fi
  STAGED_TREE="$(mktemp -d)"
  rm -rf "$STAGED_TREE"
  git worktree add --detach -q "$STAGED_TREE" "$commit" >/dev/null 2>&1 || {
    echo "deadcode-check: could not check out the staged state for analysis" >&2
    exit 2
  }
}

# Symbols this diff adds, as "<file>|<name>", read off the staged diff's added
# lines. Methods are keyed "Type.Method" to match how deadcode names them.
for f in "${CHANGED[@]}"; do
  git diff --cached -U0 -- "$f" | awk -v file="$f" '
    /^\+func / {
      line = substr($0, 2)
      if (match(line, /^func \([^)]*\)[[:space:]]*/)) {
        recv = substr(line, 6, RLENGTH - 6)
        rest = substr(line, RLENGTH + 1)
        gsub(/[()]/, "", recv)
        n = split(recv, parts, /[[:space:]]+/)
        typ = parts[n]
        sub(/^\*/, "", typ)
        sub(/\[.*$/, "", typ)
        if (match(rest, /^[A-Za-z_][A-Za-z0-9_]*/)) {
          print file "|" typ "." substr(rest, 1, RLENGTH)
        }
      } else if (match(line, /^func [A-Za-z_][A-Za-z0-9_]*/)) {
        print file "|" substr(line, 6, RLENGTH - 5)
      }
    }
  ' >> "$ADDED"
done

if [ ! -s "$ADDED" ]; then
  echo "deadcode-check: the staged diff adds no functions; nothing to check."
  exit 0
fi

# Group by nearest enclosing go.mod: deadcode must run inside a module. The
# resolution, the module paths and the replace closure all come from
# lib/go_modules.py, which crap-check-go.sh and mutation-check-go.sh also use,
# so the three gates cannot disagree about which module owns a file.
MODDIRS=()
while IFS= read -r d; do
  [ -n "$d" ] && MODDIRS+=("$d")
done < <(printf '%s\n' "${CHANGED[@]}" | python3 "$LIB_DIR/go_modules.py" group \
         | cut -f1 | sort -u)

mod_path() { python3 "$LIB_DIR/go_modules.py" modpath "$1"; }

# Modules that pull in $1, transitively, plus $1 itself. A library module's
# callers live in another module, so analysing only the one the file sits in
# reports a shared package's whole exported API as unreachable.
analysis_roots() { python3 "$LIB_DIR/go_modules.py" roots "$1"; }

# deadcode prints paths relative to the root it ran in; the keys are
# repo-relative, and a root outside $mod reports it as "../<mod>/...".
normalize_findings() {
  python3 -c '
import os, re, sys
root, tree = sys.argv[1], sys.argv[2]
pat = re.compile(r"^([^:]+)(:\d+:\d+: unreachable func: .*)$")
for line in sys.stdin:
    m = pat.match(line.rstrip("\n"))
    if not m:
        continue
    p = os.path.normpath(os.path.join(tree, root, m.group(1)))
    print(os.path.relpath(p, tree) + m.group(2))
' "$1" "$STAGED_TREE"
}

setup_staged_tree

total=0
skipped=0
unanalysed=0
for mod in ${MODDIRS[@]+"${MODDIRS[@]}"}; do
  modpath="$(mod_path "$mod")"
  MANIFEST="$(mktemp)"
  SCOPE="$(mktemp -d)"
  roots_with_main=0

  while read -r root; do
    status=0
    # -filter widens reporting past the root's own module to the one being
    # checked; without it deadcode only ever reports the main module.
    (cd "$STAGED_TREE/$root" && \
      go run "$DEADCODE_PKG@$DEADCODE_VERSION" "${DEADCODE_TAGS_FLAG[@]}" -filter="^${modpath//./\\.}" ./...) \
      >"$RAW" 2>&1 || status=$?

    if grep -q 'no main packages' "$RAW"; then
      continue
    fi
    if [ "$status" -ne 0 ]; then
      {
        echo "deadcode-check: FAILED TO ANALYSE module '$mod' from root '$root' (exit $status)."
        echo "  This is NOT a pass: zero findings here means zero functions were"
        echo "  checked, not that none are unreachable."
        if [ -s "$RAW" ]; then
          echo "  deadcode output:"
          tail -n 20 "$RAW" | sed 's/^/    /'
        fi
      } >&2
      exit 2
    fi
    roots_with_main=$((roots_with_main + 1))

    slug="${root//\//_}"
    normalize_findings "$root" <"$RAW" >"$SCOPE/$slug.findings"

    # Not a relaxation: a package only tests import has no other consumer, so
    # the first pass asks a question with one possible answer. Elsewhere it
    # still decides alone. If this pass fails, nothing is marked test-only.
    tstatus=0
    (cd "$STAGED_TREE/$root" && \
      go run "$DEADCODE_PKG@$DEADCODE_VERSION" "${DEADCODE_TAGS_FLAG[@]}" -test -filter="^${modpath//./\\.}" ./...) \
      >"$RAW.test" 2>&1 || tstatus=$?
    : >"$SCOPE/$slug.testfindings"
    : >"$SCOPE/$slug.testonly"
    if [ "$tstatus" -eq 0 ]; then
      normalize_findings "$root" <"$RAW.test" >"$SCOPE/$slug.testfindings"
      (cd "$STAGED_TREE/$root" && go list -deps \
        -f '{{.ImportPath}}|{{join .Imports " "}}|{{join .TestImports " "}}|{{join .XTestImports " "}}' \
        ./... 2>/dev/null) | python3 "$LIB_DIR/deadcode_testonly.py" \
        >"$SCOPE/$slug.testonly" || true
    else
      echo "deadcode-check: the -test pass failed for root '$root'; no package is" >&2
      echo "  treated as test-only there, so every symbol takes the strict verdict." >&2
    fi
    rm -f "$RAW.test"

    (cd "$STAGED_TREE/$root" && go list -deps ./... 2>/dev/null) >"$SCOPE/$slug.pkgs" || true
    printf '%s\t%s\t%s\t%s\t%s\n' "$root" "$SCOPE/$slug.findings" "$SCOPE/$slug.pkgs" \
      "$SCOPE/$slug.testfindings" "$SCOPE/$slug.testonly" >>"$MANIFEST"
  done < <(analysis_roots "$mod")

  if [ "$roots_with_main" -eq 0 ]; then
    {
      echo "deadcode-check: SKIPPED for module '$mod': neither it nor any module"
      echo "  that replaces it has a main package, so reachability is undecidable"
      echo "  (a library's entry points are its exported API, which no call graph"
      echo "  can see). Nothing was checked here. This is not a pass."
    } >&2
    skipped=$((skipped + 1))
    rm -rf "$SCOPE" "$MANIFEST"
    continue
  fi

  scope_err="$(mktemp)"
  python3 "$LIB_DIR/deadcode_scope.py" "$ADDED" "$mod" "$modpath" "$MANIFEST" \
    >"$RAW.dead" 2>"$scope_err"
  [ -s "$scope_err" ] && { cat "$scope_err" >&2; unanalysed=$((unanalysed + 1)); }
  rm -f "$scope_err"

  found=0
  python3 "$LIB_DIR/deadcode_accepted.py" report "$STORE" "$BRANCH" "$ADDED" \
    < "$RAW.dead" > "$RAW.out" || found=$?
  grep -v '^unreachable=' "$RAW.out" || true
  total=$((total + $(sed -n 's/^unreachable=//p' "$RAW.out")))
  rm -f "$RAW.out" "$RAW.dead"
  rm -rf "$SCOPE" "$MANIFEST"
done

echo ""
echo "== NEXT_ACTION =="
if [ "$total" -gt 0 ]; then
  echo "DELETE_UNREACHABLE: $total function(s) this diff adds cannot be reached from"
  echo "any main package. A test that calls them does not make them live: that is"
  echo "the loophole this gate closes. Delete them, or wire them into the code path"
  echo "they were written for. Do not add a caller that only exists to satisfy this."
  echo "If a symbol must stay unreachable (satisfying an interface, a planned entry"
  echo "point), surface it to the user; on their explicit approval record it with:"
  echo "  deadcode-check.sh --accept '<file>|<symbol>'"
  exit 1
fi
if [ "$skipped" -gt 0 ]; then
  echo "DEADCODE_SKIPPED: $skipped module(s) have no main package; see stderr."
  exit 0
fi
echo "DEADCODE_OK"
