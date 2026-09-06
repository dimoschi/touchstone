#!/usr/bin/env bash
# Tests lib/go_modules.py, which resolves changed Go files to their enclosing
# go.mod and computes the transitive `replace` closure.
#
# This logic used to be copy-pasted into three shell scripts. Three copies of
# "which module owns this file" could drift, and the gates would then measure
# different file sets while all reporting green. It is one module with one test
# now.
#
# The fixture is a multi-module repo:
#
#   .            module example.com/root
#   db/          module example.com/db
#   svc/         module example.com/svc   replace example.com/db => ../db
#   app/         module example.com/app   replace example.com/svc => ../svc
#
# so roots(db) must be {db, svc, app}: app reaches db only transitively, and
# missing that is what reported a shared package's whole exported API as dead.

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GM="$SKILL_DIR/lib/go_modules.py"
failures=0

FIX="$(mktemp -d)"
trap 'rm -rf "$FIX"' EXIT
cd "$FIX"
git init -q .

mkdir -p db svc/internal/handler app pkg/util
printf 'module example.com/root\n\ngo 1.24\n' > go.mod
printf 'module example.com/db\n\ngo 1.24\n' > db/go.mod
printf 'module example.com/svc\n\ngo 1.24\n\nreplace example.com/db => ../db\n' > svc/go.mod
printf 'module example.com/app\n\ngo 1.24\n\nreplace example.com/svc => ../svc\n' > app/go.mod
for f in main.go pkg/util/util.go db/db.go svc/svc.go svc/internal/handler/h.go app/app.go; do
  printf 'package p\n' > "$f"
done
git add -A
git -c commit.gpgsign=false -c user.email=t@t -c user.name=t commit -q -m fixture

check() {
  local label="$1" want="$2" got="$3"
  if [ "$got" = "$want" ]; then
    printf '  ok:   %s\n' "$label"
  else
    printf '  FAIL: %s\n        got  %s\n        want %s\n' "$label" "$got" "$want"
    failures=$((failures + 1))
  fi
}

echo "a file resolves to its nearest enclosing go.mod, not the repo root"
group() { printf '%s\n' "$@" | python3 "$GM" group; }

check "nested module wins over the root" \
  "svc" "$(group svc/internal/handler/h.go | cut -f1)"
check "file in the root module" \
  "." "$(group pkg/util/util.go | cut -f1)"
check "module dir itself" \
  "db" "$(group db/db.go | cut -f1)"

echo "grouping reports module dir, package dir, and both path spellings"
check "full row for a nested file" \
  "svc	svc/internal/handler	svc/internal/handler/h.go	./internal/handler/h.go" \
  "$(group svc/internal/handler/h.go)"
check "root-module file keeps its path as module-relative" \
  ".	pkg/util	pkg/util/util.go	./pkg/util/util.go" \
  "$(group pkg/util/util.go)"

check "several files group under their own modules, sorted" \
  ". db svc" \
  "$(group db/db.go svc/svc.go main.go | cut -f1 | tr '\n' ' ' | sed 's/ $//')"

echo "a file that does not exist is still resolvable by path"
check "deleted file resolves by path alone" \
  "db" "$(group db/gone.go | cut -f1)"

echo "an untracked go.mod still defines a module"
# Adding a module stages its .go files while go.mod is often still untracked.
# Resolving those to the parent module would measure them from the wrong root.
mkdir -p fresh
printf 'module example.com/fresh\n\ngo 1.24\n' > fresh/go.mod
printf 'package p\n' > fresh/f.go
check "untracked go.mod wins over the root module" \
  "fresh" "$(group fresh/f.go | cut -f1)"
rm -rf fresh

echo "the replace closure is transitive"
roots() { python3 "$GM" roots "$1" | sort | tr '\n' ' ' | sed 's/ $//'; }
# The root module replaces nothing, so it is absent from every closure. Verified
# byte-identical to the shell implementation this replaces.
check "db is reached by svc directly and app transitively" \
  "app db svc" "$(roots db)"
check "svc is reached by app" \
  "app svc" "$(roots svc)"
check "app is replaced by nobody, so only itself" \
  "app" "$(roots app)"

echo "module paths are read from go.mod"
check "nested module path" "example.com/svc" "$(python3 "$GM" modpath svc)"
check "root module path"   "example.com/root" "$(python3 "$GM" modpath .)"

echo "a repo with no go.mod anywhere falls back to the root"
OTHER="$(mktemp -d)"
(cd "$OTHER" && git init -q . && mkdir -p a/b && printf 'package p\n' > a/b/c.go \
  && git add -A && git -c commit.gpgsign=false -c user.email=t@t -c user.name=t commit -q -m x)
check "no go.mod means the repo root" \
  "." "$(cd "$OTHER" && printf 'a/b/c.go\n' | python3 "$GM" group | cut -f1)"
rm -rf "$OTHER"

echo ""
if [ "$failures" -eq 0 ]; then
  echo "GO MODULES OK"
else
  echo "FAILED: $failures assertion(s)"
  exit 1
fi
