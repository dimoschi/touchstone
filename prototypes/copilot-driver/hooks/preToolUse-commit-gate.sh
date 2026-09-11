#!/usr/bin/env bash
# preToolUse hook: refuses a raw `git commit` unless a local check has already
# passed in this same working directory, mirroring hooks/crap-commit-gate.py's
# real policy (refuse the raw command, name the wrapper that runs the gate
# first) but expressed in Copilot's hook contract instead of Claude's.
#
# Copilot invokes this as the `bash` field of a preToolUse command hook and
# feeds it one JSON object on stdin:
#   {"sessionId":"...","timestamp":...,"cwd":"...","toolName":"bash","toolArgs":{"command":"...","description":"..."}}
# It reads our stdout for a decision object. Returning
# {"permissionDecision":"deny",...} blocks the tool call outright; returning
# {"permissionDecision":"allow"} (or nothing) lets it proceed. This is the
# concrete mechanism issue #53 verified and #56 is meant to generalise across
# all of hooks/*.py.

set -euo pipefail

input="$(cat)"

command_str="$(printf '%s' "$input" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    print("")
    raise SystemExit(0)
print(data.get("toolArgs", {}).get("command", ""))
')"

cwd="$(printf '%s' "$input" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    print("")
    raise SystemExit(0)
print(data.get("cwd", ""))
')"

# Only ever look at `git commit` invocations; everything else is allowed
# without opinion. A cheap substring check is enough for this prototype;
# the real port (#56) should reuse hooks/base_branch.py-style parsing rather
# than reinventing command parsing here.
if printf '%s' "$command_str" | grep -Eq '(^|[;&|]|\s)git\s+commit(\s|$)'; then
  marker="${cwd:-.}/.copilot-check-passed"
  if [ ! -f "$marker" ]; then
    printf '%s\n' '{"permissionDecision":"deny","permissionDecisionReason":"Raw git commit refused: run ./check-and-commit.sh instead, which runs the local check and only commits if it passes."}'
    exit 0
  fi
fi

printf '%s\n' '{"permissionDecision":"allow"}'
