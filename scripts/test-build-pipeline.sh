#!/usr/bin/env bash
# Regression test for scripts/build-pipeline.sh.
#
# Runs a copy of the real script against a throwaway fixture tree, since
# build-pipeline.sh resolves workflows/parts and workflows/deliver-pipeline.js
# from its own location rather than an argument -- exercising it for real
# means giving it a tree to resolve, not just calling functions in isolation.
#
# Exit 0 all green, 1 any assertion failed.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REAL_SCRIPT="$ROOT/scripts/build-pipeline.sh"

failures=0

check() {
  local label="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then
    echo "  ok:   $label ($got)"
  else
    echo "  FAIL: $label (got $got, want $want)"
    failures=$((failures + 1))
  fi
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FIXTURE="$WORK/fixture"
mkdir -p "$FIXTURE/scripts" "$FIXTURE/workflows/parts"
cp "$REAL_SCRIPT" "$FIXTURE/scripts/build-pipeline.sh"
SCRIPT="$FIXTURE/scripts/build-pipeline.sh"
BUILT="$FIXTURE/workflows/deliver-pipeline.js"

printf 'export const meta = { name: %s }\n' "'fixture'" > "$FIXTURE/workflows/parts/00-a.js.part"
printf 'const rest = 1\n' > "$FIXTURE/workflows/parts/10-b.js.part"
EXPECTED="$(cat "$FIXTURE/workflows/parts/00-a.js.part" "$FIXTURE/workflows/parts/10-b.js.part")"

echo "== no parts, no built file yet"
rm -f "$FIXTURE/workflows/parts"/*.js.part
bash "$SCRIPT" --check >/dev/null 2>&1
check "no parts found exits 2" "$?" 2

printf 'export const meta = { name: %s }\n' "'fixture'" > "$FIXTURE/workflows/parts/00-a.js.part"
printf 'const rest = 1\n' > "$FIXTURE/workflows/parts/10-b.js.part"

echo ""
echo "== a fresh build"
bash "$SCRIPT" >/dev/null
check "the built file now exists" "$([ -f "$BUILT" ] && echo yes || echo no)" yes
check "it matches the parts concatenated in sorted order" "$(cat "$BUILT")" "$EXPECTED"

echo ""
echo "== --check on a build that matches its parts"
bash "$SCRIPT" --check >/dev/null 2>&1
check "exits 0" "$?" 0

echo ""
echo "== --check when the built file itself was hand-edited"
printf '\n// hand-edited\n' >> "$BUILT"
bash "$SCRIPT" --check >/dev/null 2>&1
check "exits 1" "$?" 1

echo ""
echo "== rebuilding clears that drift"
bash "$SCRIPT" >/dev/null
bash "$SCRIPT" --check >/dev/null 2>&1
check "exits 0 again" "$?" 0

echo ""
echo "== --check when a part changed but the built file did not"
printf 'const rest = 2\n' > "$FIXTURE/workflows/parts/10-b.js.part"
bash "$SCRIPT" --check >/dev/null 2>&1
check "exits 1" "$?" 1

echo ""
if [ "$failures" -eq 0 ]; then
  echo "OK"
  exit 0
else
  echo "FAILED: $failures assertion(s)"
  exit 1
fi
