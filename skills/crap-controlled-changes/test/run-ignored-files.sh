#!/usr/bin/env bash
# Regression test: the gitignored-file diagnostic in the PHP and Python modules.
#
# Go's version is covered end to end by run-go-unmeasurable.sh (case E). PHP and
# Python need a real phpunit / coverage toolchain to reach their warning, so the
# toolchains are stubbed to produce no coverage, which is the trigger.
#
# Locks two things that broke during development:
#   - the note must fire for the baseline phase, naming the ignored file
#   - it must NOT repeat for the current phase (IGNORED_FILES is a global, and
#     an ungated collect leaves the baseline's findings in place)

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$SKILL_DIR/lib"

STUBS="$(mktemp -d)"
WORK="$(mktemp -d)"
trap 'rm -rf "$STUBS" "$WORK"' EXIT

printf '#!/bin/sh\nexit 0\n' > "$STUBS/phpunit"
cat > "$STUBS/coverage" <<'SH'
#!/bin/sh
case "$1" in
  --version) exit 0 ;;
  json)      exit 1 ;;
  *)         exit 0 ;;
esac
SH
chmod +x "$STUBS"/*

failures=0

check() {
  local label="$1" condition="$2"
  if [ "$condition" = "pass" ]; then
    echo "  ok: $label"
  else
    echo "  FAIL: $label"
    failures=$((failures + 1))
  fi
}

expect_matches() {
  local label="$1" pattern="$2"
  if printf '%s' "$OUT" | grep -qE -- "$pattern"; then
    check "$label" pass
  else
    check "$label (no line matching: $pattern)" fail
  fi
}

expect_count() {
  local label="$1" pattern="$2" want="$3" got
  got="$(printf '%s\n' "$OUT" | grep -cE -- "$pattern" || true)"
  if [ "$got" = "$want" ]; then
    check "$label" pass
  else
    check "$label (matched $got, want $want)" fail
  fi
}

# Each repo gets an over-broad ignore rule ("gen") hiding a source file, plus a
# dependency directory that is ignored by design and must stay out of the note.
setup_repo() {
  local dir="$1" ext="$2" depdir="$3"
  git init -q "$dir"
  (
    cd "$dir"
    printf 'gen\n%s\n' "$depdir" > .gitignore
    printf 'original\n' > "a.$ext"
    git add .gitignore "a.$ext"
    GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=t@t \
      GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=t@t \
      git -c commit.gpgsign=false -c gpg.format=openpgp commit -q -m baseline

    mkdir -p gen "$depdir/pkg"
    printf 'generated\n' > "gen/mock.$ext"
    printf 'vendored\n' > "$depdir/pkg/dep.$ext"

    printf 'changed\n' > "a.$ext"
    git add "a.$ext"
  )
}

run_module() {
  local dir="$1" module="$2"
  shift 2
  set +e
  OUT="$(cd "$dir" && PATH="$STUBS:$PATH" "$@" bash "$module" 2>&1)"
  set -e
}

echo "php: baseline names the ignored file, current does not repeat it"
setup_repo "$WORK/php" php vendor
run_module "$WORK/php" "$LIB/crap-check-php.sh" env PHPUNIT_BIN="$STUBS/phpunit"
printf '%s\n' "$OUT" | sed 's/^/    | /'
expect_matches "labels the baseline phase"   'phase: baseline \(HEAD\) \+ 1 ignored file'
expect_matches "lists the ignored file"      '^ +gen/mock\.php$'
expect_matches "explains --include-untracked" '\-\-include-untracked'
expect_matches "reaches the current phase"   'phase: current \(working tree'
expect_count   "note appears exactly once"   'NOTE: .* are gitignored' 1
expect_count   "vendor stays out of it"      'vendor/pkg/dep\.php' 0

echo "python: baseline names the ignored file, current does not repeat it"
setup_repo "$WORK/py" py .venv
run_module "$WORK/py" "$LIB/crap-check-python.sh" \
  env CRAP_PY_RADON=false CRAP_PY_COMPLEXIPY=false
printf '%s\n' "$OUT" | sed 's/^/    | /'
expect_matches "labels the baseline phase" 'phase: baseline \(HEAD\) \+ 1 ignored file'
expect_matches "lists the ignored file"    '^ +gen/mock\.py$'
expect_matches "reaches the current phase" 'phase: current \(working tree'
expect_count   "note appears exactly once" 'NOTE: .* are gitignored' 1
expect_count   ".venv stays out of it"     '\.venv/pkg/dep\.py' 0

echo ""
if [ "$failures" -eq 0 ]; then
  echo "IGNORED FILES OK"
else
  echo "FAILED: $failures assertion(s)"
  exit 1
fi
