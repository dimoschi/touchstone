#!/usr/bin/env bash
# Tests the Copilot PostToolUse Read evidence recorder and its session-path API.

set -euo pipefail

HOOKS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RECORDER="$HOOKS/copilot_session_evidence.py"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
STATE="$TMP/state"
export TOUCHSTONE_HOOK_STATE_DIR="$STATE"
OUT="$TMP/recorder.out"

REAL="$TMP/repo"
LINK="$TMP/link"
mkdir -p "$REAL/docs"
ln -s "$REAL" "$LINK"
printf 'guide\n' > "$REAL/CONTRIBUTING.md"
printf 'deeper guide\n' > "$REAL/docs/DEVELOPMENT.md"
printf '# notes\n' > "$REAL/README.md"

payload() {
  python3 - "$@" <<'PY'
import json
import sys

event, session_id, cwd, tool_name, file_path, result_type = sys.argv[1:7]
payload = {
    "hook_event_name": event,
    "session_id": session_id,
    "cwd": cwd,
    "tool_name": tool_name,
    "tool_input": {},
}
if file_path != "__MISSING__":
    payload["tool_input"]["file_path"] = file_path
if event == "PostToolUse":
    payload["tool_result"] = {"result_type": result_type}
json.dump(payload, sys.stdout)
PY
}

record() {
  local payload_json="$1"
  printf '%s' "$payload_json" | python3 "$RECORDER"
}

assert_paths() {
  local session_id="$1"
  shift
  TOUCHSTONE_HOOK_STATE_DIR="$STATE" python3 - "$HOOKS" "$session_id" "$@" <<'PY'
import sys
from pathlib import Path

sys.path.insert(0, sys.argv[1])
from copilot_session_evidence import read_session_paths

session_id = sys.argv[2]
expected = {str(Path(path).resolve(strict=False)) for path in sys.argv[3:]}
actual = read_session_paths(session_id)
assert actual == expected, (actual, expected)
print(f"  ok: {session_id}")
PY
}

echo "successful reads record canonical paths for the same session"
record "$(payload PostToolUse session-one "$REAL" Read CONTRIBUTING.md success)"
assert_paths "session-one" "$REAL/CONTRIBUTING.md"

echo "relative paths, symlinks and multiple reads are merged"
record "$(payload PostToolUse session-two "$LINK" Read CONTRIBUTING.md success)"
record "$(payload PostToolUse session-two "$REAL" Read docs/DEVELOPMENT.md success)"
assert_paths "session-two" "$REAL/CONTRIBUTING.md" "$REAL/docs/DEVELOPMENT.md"

echo "only successful Read events record"
record "$(payload PostToolUse session-grep "$REAL" Grep CONTRIBUTING.md success)"
record "$(payload PostToolUse session-failed "$REAL" Read CONTRIBUTING.md error)"
record "$(payload PreToolUse session-pre "$REAL" Read CONTRIBUTING.md success)"
record "$(payload PostToolUse session-wrong "$REAL" Read README.md success)"
assert_paths "session-grep"
assert_paths "session-failed"
assert_paths "session-pre"
assert_paths "session-wrong" "$REAL/README.md"

echo "missing env, malformed payloads and unusable state fail observably"
if printf '%s' "$(payload PostToolUse session-missing-env "$REAL" Read CONTRIBUTING.md success)" \
  | env -u TOUCHSTONE_HOOK_STATE_DIR python3 "$RECORDER" >"$OUT" 2>&1; then
  echo "expected missing env to fail"
  exit 1
fi
grep -Fq 'TOUCHSTONE_HOOK_STATE_DIR' "$OUT"

if printf '{' | python3 "$RECORDER" >"$OUT" 2>&1; then
  echo "expected malformed json to fail"
  exit 1
fi
grep -Fq 'invalid JSON' "$OUT"

if printf '%s' "$(payload PostToolUse session-missing-path "$REAL" Read __MISSING__ success)" \
  | python3 "$RECORDER" >"$OUT" 2>&1; then
  echo "expected missing path to fail"
  exit 1
fi
grep -Fq 'tool_input.file_path' "$OUT"

BROKEN="$TMP/broken-state"
printf 'not a directory' > "$BROKEN"
if printf '%s' "$(payload PostToolUse session-broken "$REAL" Read CONTRIBUTING.md success)" \
  | TOUCHSTONE_HOOK_STATE_DIR="$BROKEN" python3 "$RECORDER" >"$OUT" 2>&1; then
  echo "expected invalid state dir to fail"
  exit 1
fi
grep -Fq 'not a directory' "$OUT"

echo "COPILOT SESSION EVIDENCE OK"
