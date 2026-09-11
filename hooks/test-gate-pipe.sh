#!/usr/bin/env bash
# Tests gate-pipe-gate.py: piping a gate is refused because the pipeline's exit
# status is the last command's, not the gate's. Redirects and unrelated pipes
# are left alone.

set -uo pipefail

GATE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/gate-pipe-gate.py"
MUT='/opt/touchstone/skills/crap-controlled-changes/mutation-check.sh'
failures=0

# want: BLOCK | ALLOW
expect() {
  local label="$1" want="$2" cmd="$3" rc=0 out got
  out="$(jq -nc --arg c "$cmd" '{tool_input:{command:$c}}' | python3 "$GATE" 2>&1)" || rc=$?
  if [ "$rc" -eq 0 ]; then
    got=ALLOW
  elif printf '%s' "$out" | grep -q 'gate-pipe-gate:'; then
    got=BLOCK
  else
    got="OTHER($rc)"
  fi
  if [ "$got" = "$want" ]; then
    printf '  ok:   %-50s %s\n' "$label" "$got"
  else
    printf '  FAIL: %-50s got %s want %s\n' "$label" "$got" "$want"
    failures=$((failures + 1))
  fi
}

copilot_expect() {
  local label="$1" want="$2" cmd="$3" rc=0 out got
  out="$(python3 - "$cmd" <<'PY' | python3 "$GATE" 2>&1
import json
import sys

command = sys.argv[1]
json.dump(
    {
        "hook_event_name": "PreToolUse",
        "session_id": "copilot-gate-pipe",
        "cwd": "/tmp",
        "tool_name": "Bash",
        "tool_input": {"command": command},
    },
    sys.stdout,
)
PY
)" || rc=$?
  if [ "$rc" -eq 0 ]; then
    got=ALLOW
  elif printf '%s' "$out" | grep -q 'gate-pipe-gate:'; then
    got=BLOCK
  else
    got="OTHER($rc)"
  fi
  if [ "$got" = "$want" ]; then
    printf '  ok:   %-50s %s\n' "$label" "$got"
  else
    printf '  FAIL: %-50s got %s want %s\n' "$label" "$got" "$want"
    failures=$((failures + 1))
  fi
}

echo "piping a gate hides its verdict"
expect "tail"                        BLOCK "$MUT | tail -45"
expect "head"                        BLOCK "$MUT | head -20"
expect "grep"                        BLOCK "$MUT | grep SURVIVED"
expect "tee keeps output, not status" BLOCK "$MUT | tee /tmp/x.log"
expect "behind mise exec"            BLOCK "mise exec -- $MUT | tail -5"
expect "crap-check.sh"               BLOCK "/opt/touchstone/skills/crap-controlled-changes/crap-check.sh | tail -30"
expect "deadcode-check.sh"           BLOCK "/opt/touchstone/skills/crap-controlled-changes/deadcode-check.sh | tail -3"
expect "second segment of a chain"   BLOCK "cd /tmp && $MUT | tail -5"

echo "the sanctioned form and unrelated pipes are untouched"
expect "redirect to a file"          ALLOW "$MUT > /tmp/gate.log 2>&1; echo EXIT=\$?"
expect "bare invocation"             ALLOW "$MUT"
expect "redirect then a later pipe"  ALLOW "$MUT > /tmp/g.log 2>&1; cat /tmp/g.log | tail -5"
expect "gate named after ||"         ALLOW "grep -q x /tmp/f | wc -l || echo $MUT"
expect "pipe with no gate in it"     ALLOW "git status --porcelain | wc -l"
expect "gate quoted in a message"    ALLOW "git commit -m \"see mutation-check.sh | tail\""

echo "copilot bash payloads refuse the same pipelines"
copilot_expect "copilot piped gate"         BLOCK "$MUT | tail -45"
copilot_expect "copilot redirect instead"   ALLOW "$MUT > /tmp/gate.log 2>&1; echo EXIT=\$?"
copilot_expect "copilot unrelated pipe"     ALLOW "git status --porcelain | wc -l"

echo ""
if [ "$failures" -eq 0 ]; then
  echo "GATE PIPE OK"
else
  echo "FAILED: $failures assertion(s)"
  exit 1
fi
