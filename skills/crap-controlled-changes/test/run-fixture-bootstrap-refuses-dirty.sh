#!/usr/bin/env bash
# Regression test: bootstrapping or resetting a fixture must refuse when the
# fixture is dirty relative to the outer checkout, never restore or reset it.
#
# A crash between `git init` and the closing `git reset --hard` (or a manual
# `rm -rf fixture/.git`) can leave a fixture's tracked file already mutated
# with no .git present. A developer can also edit an already-bootstrapped
# fixture directly. Either way, run.sh and run-go-unmeasurable.sh must refuse
# rather than seal or reset that content, because either one could discard a
# developer's uncommitted work with no copy anywhere.
#
# This drives the real run.sh and run-go-unmeasurable.sh against the real
# fixture directories, not a synthetic stand-in, because the check being
# tested reads *this checkout's* status via `git -C "$SKILL_DIR"`.

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$SKILL_DIR/test"

command -v go >/dev/null || { echo "SKIP: go not on PATH"; exit 0; }

# Abort before touching anything if either fixture area is already dirty:
# every case below would otherwise blame this suite for someone else's
# change. Force the same untracked/ignored flags the fix uses.
for fixture_rel in fixture fixture-go-unmeasurable; do
  dirty="$(git -C "$SKILL_DIR" status --porcelain --untracked-files=normal --ignored=matching -- "test/$fixture_rel")"
  if [ -n "$dirty" ]; then
    {
      echo "run-fixture-bootstrap-refuses-dirty.sh: test/$fixture_rel is" \
           "already dirty; refusing to run rather than risk it as collateral."
      echo "$dirty" | sed 's/^/  /'
    } >&2
    exit 1
  fi
done

failures=0

check_exit() {
  local label="$1" want="$2" got="$3"
  if [ "$got" = "$want" ]; then
    echo "  ok: $label (exit $got)"
  else
    echo "  FAIL: $label (exit $got, want $want)"
    failures=$((failures + 1))
  fi
}

check_contains() {
  local label="$1" needle="$2" haystack="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    echo "  ok: $label"
  else
    echo "  FAIL: $label (missing: $needle)"
    failures=$((failures + 1))
  fi
}

check_true() {
  local label="$1" condition="$2"
  if [ "$condition" = "true" ]; then
    echo "  ok: $label"
  else
    echo "  FAIL: $label"
    failures=$((failures + 1))
  fi
}

# Same edit run.sh/run-go-unmeasurable.sh stage on a bootstrapped fixture,
# used here to make a tracked file differ from HEAD.
mutate() {
  python3 - "$1" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()
new = s.replace(
    'if x > 100 {\n\t\treturn "big"\n\t}\n\treturn "ok"',
    'if x > 100 {\n\t\treturn "big"\n\t}\n\tif x == 42 {\n\t\treturn "answer"\n\t}\n\treturn "ok"',
)
assert new != s, "setup pattern did not match"
p.write_text(new)
PY
}

# Undo only what this suite did: the tracked mutation, the scratch files it
# planted, and any .git the target script bootstrapped. Never `git clean`,
# so unrelated dirt is left exactly as found.
cleanup_fixture() {
  local fixture_rel="$1" tracked_file="$2"
  git -C "$SKILL_DIR" checkout HEAD -- "test/$fixture_rel/$tracked_file"
  rm -f "$TEST_DIR/$fixture_rel/UNTRACKED_SCRATCH.tmp"
  rm -rf "$TEST_DIR/$fixture_rel/vendor"
  rm -rf "$TEST_DIR/$fixture_rel/.git"
}

# --- core contract, both fixtures: refuse dirty, bootstrap clean ---

run_core_cases() {
  local fixture_rel="$1" tracked_file="$2" script="$3" pass_needle="$4"

  echo "case: baseline-less dirty test/$fixture_rel makes $script refuse, untracked survives"
  rm -rf "$TEST_DIR/$fixture_rel/.git"
  mutate "$TEST_DIR/$fixture_rel/$tracked_file"
  : > "$TEST_DIR/$fixture_rel/UNTRACKED_SCRATCH.tmp"
  RC=0
  OUT="$(bash "$TEST_DIR/$script" 2>&1)" || RC=$?
  printf '%s\n' "$OUT" | sed 's/^/    | /'
  check_exit "$script refuses" 1 "$RC"
  check_contains "names the fixture" "test/$fixture_rel" "$OUT"
  check_true "no .git bootstrapped despite refusing" \
    "$([ ! -e "$TEST_DIR/$fixture_rel/.git" ] && echo true || echo false)"
  check_true "untracked file survives the refusal" \
    "$([ -e "$TEST_DIR/$fixture_rel/UNTRACKED_SCRATCH.tmp" ] && echo true || echo false)"
  cleanup_fixture "$fixture_rel" "$tracked_file"

  echo "case: baseline-less clean test/$fixture_rel makes $script bootstrap and pass"
  rm -rf "$TEST_DIR/$fixture_rel/.git"
  RC=0
  OUT="$(bash "$TEST_DIR/$script" 2>&1)" || RC=$?
  printf '%s\n' "$OUT" | sed 's/^/    | /'
  check_exit "$script passes" 0 "$RC"
  check_contains "reports OK" "$pass_needle" "$OUT"
  cleanup_fixture "$fixture_rel" "$tracked_file"

  echo "case: already-bootstrapped test/$fixture_rel dirtied afterward still makes $script refuse"
  rm -rf "$TEST_DIR/$fixture_rel/.git"
  RC=0
  bash "$TEST_DIR/$script" >/dev/null 2>&1 || RC=$?
  check_exit "$script bootstraps first" 0 "$RC"
  mutate "$TEST_DIR/$fixture_rel/$tracked_file"
  RC=0
  OUT="$(bash "$TEST_DIR/$script" 2>&1)" || RC=$?
  printf '%s\n' "$OUT" | sed 's/^/    | /'
  check_exit "$script refuses on an already-bootstrapped, dirty fixture" 1 "$RC"
  check_contains "names the fixture" "test/$fixture_rel" "$OUT"
  check_true "edit was not silently reset" \
    "$(grep -q 'x == 42' "$TEST_DIR/$fixture_rel/$tracked_file" && echo true || echo false)"
  cleanup_fixture "$fixture_rel" "$tracked_file"
}

run_core_cases fixture main.go run.sh OK
run_core_cases fixture-go-unmeasurable internal/calc.go run-go-unmeasurable.sh "OK (5 cases)"

# --- config-independence, pinned against one fixture: the underlying check
# is identical (by copy) in both scripts, see run.sh and run-go-unmeasurable.sh.

echo "case: baseline-less dirty test/fixture (untracked only, showUntrackedFiles=no) still makes run.sh refuse"
rm -rf "$TEST_DIR/fixture/.git"
: > "$TEST_DIR/fixture/UNTRACKED_SCRATCH.tmp"
RC=0
OUT="$(GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=status.showUntrackedFiles GIT_CONFIG_VALUE_0=no \
  bash "$TEST_DIR/run.sh" 2>&1)" || RC=$?
printf '%s\n' "$OUT" | sed 's/^/    | /'
check_exit "run.sh refuses despite showUntrackedFiles=no" 1 "$RC"
check_contains "names the fixture" "test/fixture" "$OUT"
check_true "no .git bootstrapped despite refusing" \
  "$([ ! -e "$TEST_DIR/fixture/.git" ] && echo true || echo false)"
cleanup_fixture fixture main.go

echo "case: baseline-less dirty test/fixture (ignored vendor/ leftover only) still makes run.sh refuse"
rm -rf "$TEST_DIR/fixture/.git"
mkdir -p "$TEST_DIR/fixture/vendor"
: > "$TEST_DIR/fixture/vendor/leftover.go"
RC=0
OUT="$(bash "$TEST_DIR/run.sh" 2>&1)" || RC=$?
printf '%s\n' "$OUT" | sed 's/^/    | /'
check_exit "run.sh refuses on an ignored leftover" 1 "$RC"
check_contains "names the fixture" "test/fixture" "$OUT"
check_true "no .git bootstrapped despite refusing" \
  "$([ ! -e "$TEST_DIR/fixture/.git" ] && echo true || echo false)"
cleanup_fixture fixture main.go

echo ""
if [ "$failures" -eq 0 ]; then
  echo "FIXTURE BOOTSTRAP REFUSES DIRTY OK (8 cases)"
else
  echo "FAILED: $failures assertion(s)"
  exit 1
fi
