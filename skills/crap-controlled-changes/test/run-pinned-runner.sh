#!/usr/bin/env bash
# run-pinned-runner.sh: lib/uv-pinned.sh, and what the gates do without uv.
#
# Hermetic: uv itself is a stub that records how it was called, so the pinned
# command line is asserted without a network, and a PATH holding no uv at all
# stands in for a machine that lacks it.

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$SKILL_DIR/lib"

command -v git >/dev/null || { echo "SKIP: git not on PATH"; exit 0; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
failures=0

check() {
  if [ "$2" = "$3" ]; then
    echo "  ok:   $1"
  else
    echo "  FAIL: $1 (got '$2', want '$3')"
    failures=$((failures + 1))
  fi
}

contains() {
  case "$2" in *"$3"*) check "$1" yes yes ;; *) check "$1 (missing: $3)" no yes ;; esac
}

# A PATH holding what the gates need before they reach a tool, and no uv.
NOUV="$WORK/no-uv"
mkdir -p "$NOUV"
for tool in bash env git mktemp rm dirname python3 sed grep cat tr sort head awk wc date mkdir cp mv ls uname; do
  found="$(command -v "$tool" 2>/dev/null || true)"
  [ -n "$found" ] && ln -s "$found" "$NOUV/$tool"
done
printf '#!/bin/sh\nexit 0\n' > "$NOUV/go"
chmod +x "$NOUV/go"
check "the stand-in PATH really has no uv" "$(PATH="$NOUV" command -v uv || echo none)" "none"

STUBS="$WORK/stubs"
mkdir -p "$STUBS"
cat > "$STUBS/uv" <<'SH'
#!/bin/sh
printf '%s\n' "$@" > "$UV_ARGS"
SH
chmod +x "$STUBS/uv"

pinned() {
  PATH="$1" bash -c 'source "$1"; shift; "$@"' _ "$LIB/uv-pinned.sh" "${@:2}"
}

echo "pinned_ready"
out="$(pinned "$NOUV" pinned_ready dup-check dryer CRAP_DRYER_RUN "" 2>&1)"; rc=$?
check "no uv and no override is a setup problem" "$rc" "2"
contains "says uv is missing" "$out" "dup-check: uv is not on PATH, and dryer runs through it."
contains "names the override" "$out" "set CRAP_DRYER_RUN"
out="$(pinned "$NOUV" pinned_ready dup-check dryer CRAP_DRYER_RUN "python3" 2>&1)"; rc=$?
check "an override needs no uv" "$rc" "0"
check "and prints nothing" "$out" ""
out="$(pinned "$STUBS:$NOUV" pinned_ready dup-check dryer CRAP_DRYER_RUN "" 2>&1)"; rc=$?
check "uv on PATH is enough" "$rc" "0"

echo "pinned_run"
export UV_ARGS="$WORK/uv-args"
pinned "$STUBS:$NOUV" pinned_run dryer abc123 "" /lib/dup_scan.py --root /r
check "uv is asked for an isolated, projectless, pinned environment" \
      "$(tr '\n' ' ' < "$UV_ARGS")" \
      "run --isolated --no-project --quiet --python >=3.11 --with dryer @ git+https://github.com/unclebob/dryer@abc123 python3 /lib/dup_scan.py --root /r "
out="$(pinned "$NOUV" pinned_run dryer abc123 "echo launched" /lib/dup_scan.py --root /r 2>&1)"
check "an override runs in uv's place, script and arguments after it" \
      "$out" "launched /lib/dup_scan.py --root /r"

echo "dup-check.sh without uv"
R="$WORK/repo"
git init -q "$R"
printf 'x\n' > "$R/README"
printf 'def f():\n    return 1\n' > "$R/a.py"
: > "$R/.crap-gated"
git -C "$R" add README a.py
git -C "$R" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m base
printf 'def g():\n    return 2\n' > "$R/b.py"
git -C "$R" add b.py
out="$(PATH="$NOUV" "$SKILL_DIR/dup-check.sh" "$R" 2>&1)"; rc=$?
check "exit 2" "$rc" "2"
contains "says why" "$out" "uv is not on PATH, and dryer runs through it."
out="$(CRAP_DRYER_RUN=false PATH="$NOUV" "$SKILL_DIR/dup-check.sh" "$R" 2>&1)"; rc=$?
check "an override that does not run is a failed analysis, not a pass" "$rc" "2"
contains "says it could not analyse" "$out" "FAILED TO ANALYSE"

echo ""
if [ "$failures" -eq 0 ]; then
  echo "PINNED RUNNER OK"
else
  echo "FAILED: $failures assertion(s)"
  exit 1
fi
