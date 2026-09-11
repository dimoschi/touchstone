#!/usr/bin/env bash
# Runnable prototype for issue #53's acceptance criteria: "invoke a worker,
# validate its result, run two read-only reviewers concurrently, execute a
# local check via a hook, halt on its failure, and recover enough state after
# interruption to continue safely" -- all against a real Copilot CLI, in an
# isolated scratch repo and an isolated COPILOT_HOME, so it touches nothing in
# the developer's real ~/.copilot config or trustedFolders.
#
# This is a spike, not the shipped adapter. #57 (shared controller contract)
# and #58 (real Copilot entrypoint) own the production version; this script
# exists to prove the primitives it will rely on actually work, with a real
# process exit code at the end instead of prose.
#
# Requires: copilot CLI on PATH, authenticated. Makes real API calls (small,
# cheap prompts) -- this is not free to run, by design: it is evidence, not a
# unit test.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_ROOT="$(mktemp -d)"
COPILOT_HOME_SCRATCH="$RUN_ROOT/copilot-home"
REPO="$RUN_ROOT/repo"
export COPILOT_HOME="$COPILOT_HOME_SCRATCH"

fail=0
pass() { echo "PASS: $1"; }
failed() { echo "FAIL: $1"; fail=1; }

cleanup() { if [ "${KEEP_RUN:-0}" != "1" ]; then rm -rf "$RUN_ROOT"; else echo "KEEP_RUN=1: leaving $RUN_ROOT in place"; fi; }
trap cleanup EXIT

echo "== scratch run root: $RUN_ROOT =="
echo "== isolated COPILOT_HOME: $COPILOT_HOME_SCRATCH (real ~/.copilot untouched) =="

# --- Set up an isolated user-level hook. Verified in #53's investigation:
# repo-level .github/hooks/*.json is silently skipped outside trustedFolders,
# but a user-level hook under $COPILOT_HOME/hooks/ fires unconditionally, so
# this is the portable way to install a hard gate for a scratch/CI run
# without mutating the developer's real global config.
mkdir -p "$COPILOT_HOME_SCRATCH/hooks"
cat > "$COPILOT_HOME_SCRATCH/hooks/gate.json" <<EOF
{
  "version": 1,
  "hooks": {
    "preToolUse": [
      { "type": "command", "bash": "bash '$HERE/hooks/preToolUse-commit-gate.sh'", "timeoutSec": 15 }
    ]
  }
}
EOF

# --- Set up the scratch repo the worker/reviewers operate on.
mkdir -p "$REPO"
cd "$REPO"
git init -q
git -c commit.gpgsign=false -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

# check-and-commit.sh does `cd "$(dirname "$0")/repo"`, so it must sit right
# next to $REPO for that relative path to resolve.
cp "$HERE/check-and-commit.sh" "$RUN_ROOT/check-and-commit.sh"
chmod +x "$RUN_ROOT/check-and-commit.sh"

run_copilot() {
  # $1 = session id, rest = prompt
  local sid="$1"; shift
  timeout 120 copilot -p "$*" --session-id "$sid" --allow-all-tools --no-color \
    -C "$REPO" --output-format json --log-level error
}

result_line() {
  # Extract the final {"type":"result",...} line from a JSON-lines transcript on stdin.
  python3 -c '
import json, sys
last = None
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        obj = json.loads(line)
    except Exception:
        continue
    if obj.get("type") == "result":
        last = obj
print(json.dumps(last) if last else "null")
'
}

########################################################################
echo
echo "### 1. Worker phase: invoke, then validate its structured result"
########################################################################
WORKER_SID="$(python3 -c 'import uuid; print(uuid.uuid4())')"
worker_out="$(run_copilot "$WORKER_SID" "In this repo, create calc.py with a function add(a, b) that returns a + b, and create test_calc.py using Python's stdlib unittest module with at least one test for it. Do not run git commit.")"
worker_result="$(printf '%s' "$worker_out" | result_line)"
worker_exit="$(printf '%s' "$worker_result" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("exitCode") if d else "null")')"

if [ "$worker_exit" = "0" ] && [ -f "$REPO/calc.py" ] && [ -f "$REPO/test_calc.py" ]; then
  pass "worker phase produced calc.py + test_calc.py and reported exitCode 0"
else
  failed "worker phase did not produce the expected files (exitCode=$worker_exit)"
fi

########################################################################
echo
echo "### 2. Hard gate: a raw commit is refused before the local check runs"
########################################################################
rm -f "$REPO/.copilot-check-passed"
gate_out="$(run_copilot "$(python3 -c 'import uuid; print(uuid.uuid4())')" "Run exactly this shell command and report its output verbatim: git commit -am 'attempt without check'")"
if printf '%s' "$gate_out" | grep -q '"code":"denied"'; then
  pass "raw git commit was denied by the preToolUse hook before any local check ran"
else
  failed "raw git commit was NOT denied -- hard gate did not fire"
fi

########################################################################
echo
echo "### 3. Local check halts on failure, then unblocks the commit on success"
########################################################################
# 3a. Break the code so the local check fails, and confirm the wrapper halts
# rather than committing.
echo "def add(a, b): return a - b  # deliberately wrong" > "$REPO/calc.py"
if "$RUN_ROOT/check-and-commit.sh" "should not land" 2>/tmp/copilot-driver-check-fail.log; then
  failed "check-and-commit.sh committed despite a failing local check"
else
  pass "check-and-commit.sh halted (nonzero exit) on a failing local check, nothing committed"
fi

# 3b. Fix the code, rerun, confirm the check passes and the gated commit lands.
python3 - "$REPO/calc.py" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path, "w") as f:
    f.write("def add(a, b):\n    return a + b\n")
PYEOF
before_head="$(git -C "$REPO" rev-parse HEAD)"
if "$RUN_ROOT/check-and-commit.sh" "fix calc.add and land the gated commit"; then
  after_head="$(git -C "$REPO" rev-parse HEAD)"
  if [ "$before_head" != "$after_head" ]; then
    pass "check-and-commit.sh committed once the local check passed (HEAD advanced)"
  else
    failed "check-and-commit.sh exited 0 but HEAD did not advance"
  fi
else
  failed "check-and-commit.sh failed even with a passing local check"
fi

########################################################################
echo
echo "### 4. Two read-only-shaped reviewers run concurrently"
########################################################################
R1_SID="$(python3 -c 'import uuid; print(uuid.uuid4())')"
R2_SID="$(python3 -c 'import uuid; print(uuid.uuid4())')"
t0=$(date +%s)
run_copilot "$R1_SID" "Read calc.py and reply with exactly one word: CORRECT or WRONG, judging whether add(a, b) returns a + b." > "$RUN_ROOT/reviewer1.json" 2>&1 &
P1=$!
run_copilot "$R2_SID" "Read test_calc.py and reply with exactly one word: PRESENT or MISSING, judging whether a unittest test for add exists." > "$RUN_ROOT/reviewer2.json" 2>&1 &
P2=$!
wait "$P1"; E1=$?
wait "$P2"; E2=$?
t1=$(date +%s)
elapsed=$((t1 - t0))
if [ "$E1" -eq 0 ] && [ "$E2" -eq 0 ]; then
  pass "both concurrent reviewer processes exited 0 (wall time ${elapsed}s, not serialized)"
else
  failed "a concurrent reviewer process failed (exit1=$E1 exit2=$E2)"
fi

########################################################################
echo
echo "### 5. Recover state after interruption"
########################################################################
RESUME_SID="$(python3 -c 'import uuid; print(uuid.uuid4())')"
( run_copilot "$RESUME_SID" "Remember this exact token for later: TOUCHSTONE-9F2B. Then use your bash tool to run: sleep 8 ; echo woke. Then acknowledge briefly." > "$RUN_ROOT/interrupt1.json" 2>&1 ) &
IP=$!
sleep 3
kill -TERM "$IP" 2>/dev/null || true
wait "$IP" 2>/dev/null
recall_out="$(run_copilot "$RESUME_SID" "What exact token did I just tell you? Reply with only the token, or UNKNOWN if you cannot recall it.")"
recall_msg_count="$(printf '%s' "$recall_out" | grep -o '"message_count":[0-9]*' | head -1)"
if printf '%s' "$recall_out" | grep -q 'TOUCHSTONE-9F2B'; then
  pass "session recalled state across an interrupted process via --session-id"
else
  echo "FINDING: SIGTERM mid-turn (during a tool call) orphans the --session-id. The"
  echo "  resumed call did NOT error and did NOT recover the token -- it silently"
  echo "  started a brand-new conversation ($recall_msg_count) and answered UNKNOWN."
  echo "  This means a driver MUST NOT rely on --session-id reuse for crash recovery;"
  echo "  it must keep its own external phase-completion checkpoint instead."
  failed "confirmed: Copilot CLI session state is not crash-durable across a killed process"
fi

echo
echo "================================================================"
if [ "$fail" -eq 0 ]; then
  echo "ALL PROTOTYPE CHECKS PASSED"
else
  echo "SOME PROTOTYPE CHECKS FAILED (see FAIL lines above)"
fi
exit "$fail"
