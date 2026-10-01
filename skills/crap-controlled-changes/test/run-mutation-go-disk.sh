#!/usr/bin/env bash
# The Go mutation module must not be able to fill a disk: it refuses to start
# without free space, leaves the mutant build cache within its budget when it
# ends, and runs one at a time per cache however many worktrees start it.

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODULE="$SKILL_DIR/lib/mutation-check-go.sh"

command -v go  >/dev/null || { echo "SKIP: go not on PATH"; exit 0; }
command -v git >/dev/null || { echo "SKIP: git not on PATH"; exit 0; }

WORK="$(mktemp -d)"
HOLDER=""
trap '[ -n "$HOLDER" ] && kill "$HOLDER" 2>/dev/null; rm -rf "$WORK"' EXIT
cd "$WORK"

commit() {
  GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=commit.gpgsign GIT_CONFIG_VALUE_0=false \
    git commit -q "$@"
}

git init -qb main
printf 'module example.com/disk\n\ngo 1.26\n' > go.mod
printf 'package disk\n\nfunc Double(x int) int { return x * 2 }\n' > calc.go
git add .
commit -m baseline
git checkout -qb feature
printf 'package disk\n\ntype Meta struct{ Note string }\n' > meta.go
git add .
commit -m "add a type"

CACHE="$WORK/mutcache"
LOCK="$CACHE.lock"

run_module() {
  MUTATION_BASE=main MUTATION_FILES=./meta.go MUTATION_GOCACHE="$CACHE" "$MODULE"
}

fail() { echo "FAIL: $*"; exit 1; }

echo "--- phase 1: too little free space refuses with exit 2, naming volume, free space and threshold ---"
RC=0
OUT="$(MUTATION_MIN_FREE_MB=999999999 run_module 2>&1)" || RC=$?
echo "$OUT"
[ "$RC" -eq 2 ] || fail "expected exit 2, got $RC"
echo "$OUT" | grep -q "999999999" || fail "expected the threshold in the message"
echo "$OUT" | grep -qE "[0-9]+MB free" || fail "expected the free space in the message"
echo "$OUT" | grep -q "volume /" || fail "expected the volume in the message"
echo "$OUT" | grep -q "generated" && fail "a refused run must not measure"

echo "--- phase 2: a run within budget keeps the cache and releases its lock ---"
RC=0
OUT="$(run_module 2>&1)" || RC=$?
echo "$OUT"
[ "$RC" -eq 0 ] || fail "expected exit 0, got $RC"
[ -d "$CACHE" ] || fail "the cache must persist between runs"
[ -z "$(ls -A "$LOCK" 2>/dev/null)" ] || fail "a finished run must not leave a lock slot behind"

echo "--- phase 3: a run that ends over budget does not leave the cache behind ---"
RC=0
OUT="$(MUTATION_GOCACHE_MAX_MB=0 run_module 2>&1)" || RC=$?
echo "$OUT"
[ "$RC" -eq 0 ] || fail "expected exit 0, got $RC"
[ -d "$CACHE" ] && fail "the cache was left over its budget at exit"

echo "--- phase 4: a second run waits for the first, then runs ---"
sleep 600 & HOLDER=$!
mkdir -p "$LOCK/1"
echo "$HOLDER" > "$LOCK/1/pid"
run_module > "$WORK/waiter.log" 2>&1 &
WAITER=$!
for _ in $(seq 1 30); do
  grep -q "waiting" "$WORK/waiter.log" && break
  sleep 1
done
cat "$WORK/waiter.log"
grep -q "waiting" "$WORK/waiter.log" || fail "expected a message saying the run waits"
kill -0 "$WAITER" 2>/dev/null || fail "the second run did not wait for the first"
rm -rf "$LOCK/1"
RC=0
wait "$WAITER" || RC=$?
cat "$WORK/waiter.log"
[ "$RC" -eq 0 ] || fail "expected the waiting run to finish with exit 0, got $RC"
grep -q "generated no mutants" "$WORK/waiter.log" || fail "the waiting run did not measure once released"

echo "--- phase 5: MUTATION_GO_CONCURRENCY=2 runs beside a live holder ---"
mkdir -p "$LOCK/1"
echo "$HOLDER" > "$LOCK/1/pid"
RC=0
OUT="$(MUTATION_GO_CONCURRENCY=2 run_module 2>&1)" || RC=$?
echo "$OUT"
[ "$RC" -eq 0 ] || fail "expected exit 0, got $RC"
echo "$OUT" | grep -q "waiting" && fail "a free second slot must not wait"
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null; HOLDER=""
rm -rf "$LOCK/1"

echo "--- phase 6: a lock left by a dead pid is cleared, not waited on ---"
( exit 0 ) & DEAD=$!; wait "$DEAD" 2>/dev/null
mkdir -p "$LOCK/1"
echo "$DEAD" > "$LOCK/1/pid"
RC=0
OUT="$(run_module 2>&1)" || RC=$?
echo "$OUT"
[ "$RC" -eq 0 ] || fail "expected exit 0, got $RC"
echo "$OUT" | grep -q "dead pid $DEAD" || fail "expected the stale lock to be reported as cleared"
echo "$OUT" | grep -q "waiting" && fail "a dead holder must not be waited on"

echo "MUTATION GO DISK OK"
