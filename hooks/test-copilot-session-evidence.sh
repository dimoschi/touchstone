#!/usr/bin/env bash
# Tests the Copilot PostToolUse Read evidence recorder and its session-path API.

set -euo pipefail

HOOKS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RECORDER="$HOOKS/copilot_session_evidence.py"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
STATE="$TMP/state"
DEFAULT_HOME="$TMP/default-home"
DEFAULT_XDG="$TMP/default-xdg"
HOME_FALLBACK="$TMP/home-fallback"
OVERRIDE_HOME="$TMP/override-home"
OVERRIDE_XDG="$TMP/override-xdg"
mkdir -p "$DEFAULT_HOME" "$DEFAULT_XDG" "$HOME_FALLBACK" "$OVERRIDE_HOME" "$OVERRIDE_XDG"
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

event, session_id, cwd, tool_name, target_path, result_type = sys.argv[1:7]
payload = {
    "hook_event_name": event,
    "session_id": session_id,
    "cwd": cwd,
    "tool_name": tool_name,
    "tool_input": {},
}
if target_path != "__MISSING__":
    payload["tool_input"]["path"] = target_path
if event == "PostToolUse":
    payload["tool_result"] = {"result_type": result_type}
json.dump(payload, sys.stdout)
PY
}

record() {
  local payload_json="$1"
  printf '%s' "$payload_json" | python3 "$RECORDER"
}

record_path() {
  local state_dir="$1" session_id="$2"
  python3 - "$state_dir" "$session_id" <<'PY'
import hashlib
import sys
from pathlib import Path

state_dir, session_id = sys.argv[1:3]
digest = hashlib.sha256(session_id.encode("utf-8")).hexdigest()
print(Path(state_dir) / f"{digest}.json")
PY
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

assert_read_rejected() {
  local state_dir="$1" session_id="$2" needle="$3"
  TOUCHSTONE_HOOK_STATE_DIR="$state_dir" python3 - "$HOOKS" "$session_id" "$needle" <<'PY'
import sys

sys.path.insert(0, sys.argv[1])
from copilot_session_evidence import SessionEvidenceError, read_session_paths

session_id = sys.argv[2]
needle = sys.argv[3]
try:
    read_session_paths(session_id)
except SessionEvidenceError as exc:
    message = str(exc)
    assert needle in message, message
    print(f"  ok: rejected {session_id}")
else:
    raise AssertionError("expected read_session_paths to reject")
PY
}

assert_paths_default() {
  local home_dir="$1" xdg_dir="$2" session_id="$3"
  shift 3
  env -u TOUCHSTONE_HOOK_STATE_DIR HOME="$home_dir" XDG_STATE_HOME="$xdg_dir" \
    python3 - "$HOOKS" "$session_id" "$@" <<'PY'
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

assert_paths_home_fallback() {
  local home_dir="$1" session_id="$2"
  shift 2
  env -u TOUCHSTONE_HOOK_STATE_DIR -u XDG_STATE_HOME HOME="$home_dir" \
    python3 - "$HOOKS" "$session_id" "$@" <<'PY'
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

echo "ordinary agent-side marker files are ignored"
printf 'agent says it read %s\n' "$REAL/CONTRIBUTING.md" > "$STATE/session-marker.ack"
assert_paths "session-marker"

echo "explicit state overrides the default HOME/XDG resolver"
if printf '%s' "$(payload PostToolUse session-override "$REAL" Read CONTRIBUTING.md success)" \
  | HOME="$OVERRIDE_HOME" XDG_STATE_HOME="$OVERRIDE_XDG" \
    TOUCHSTONE_HOOK_STATE_DIR="$STATE" python3 "$RECORDER" >"$OUT" 2>&1; then
  :
else
  cat "$OUT"
  echo "expected explicit state override to succeed"
  exit 1
fi
test -f "$(record_path "$STATE" session-override)"
test ! -e "$(record_path "$OVERRIDE_XDG/touchstone/copilot-hook-state" session-override)"
test ! -e "$(record_path "$OVERRIDE_HOME/.local/state/touchstone/copilot-hook-state" session-override)"

echo "default state dir resolves from XDG_STATE_HOME, then HOME"
if printf '%s' "$(payload PostToolUse session-default-xdg "$REAL" Read CONTRIBUTING.md success)" \
  | env -u TOUCHSTONE_HOOK_STATE_DIR HOME="$DEFAULT_HOME" XDG_STATE_HOME="$DEFAULT_XDG" \
    python3 "$RECORDER" >"$OUT" 2>&1; then
  :
else
  cat "$OUT"
  echo "expected XDG default state dir to succeed"
  exit 1
fi
assert_paths_default "$DEFAULT_HOME" "$DEFAULT_XDG" "session-default-xdg" "$REAL/CONTRIBUTING.md"
test -f "$(record_path "$DEFAULT_XDG/touchstone/copilot-hook-state" session-default-xdg)"
test ! -e "$(record_path "$DEFAULT_HOME/.local/state/touchstone/copilot-hook-state" session-default-xdg)"

if printf '%s' "$(payload PostToolUse session-default-home "$REAL" Read docs/DEVELOPMENT.md success)" \
  | env -u TOUCHSTONE_HOOK_STATE_DIR -u XDG_STATE_HOME HOME="$HOME_FALLBACK" \
    python3 "$RECORDER" >"$OUT" 2>&1; then
  :
else
  cat "$OUT"
  echo "expected HOME fallback state dir to succeed"
  exit 1
fi
assert_paths_home_fallback "$HOME_FALLBACK" "session-default-home" "$REAL/docs/DEVELOPMENT.md"
test -f "$(record_path "$HOME_FALLBACK/.local/state/touchstone/copilot-hook-state" session-default-home)"

echo "missing env, malformed payloads and unusable state fail observably"
if printf '%s' "$(payload PostToolUse session-missing-env "$REAL" Read CONTRIBUTING.md success)" \
  | env -u TOUCHSTONE_HOOK_STATE_DIR -u HOME -u XDG_STATE_HOME python3 "$RECORDER" >"$OUT" 2>&1; then
  echo "expected missing env to fail"
  exit 1
fi
grep -Fq 'could not determine state dir' "$OUT"

if printf '%s' "$(payload PostToolUse session-bad-xdg "$REAL" Read CONTRIBUTING.md success)" \
  | env -u TOUCHSTONE_HOOK_STATE_DIR HOME="$DEFAULT_HOME" XDG_STATE_HOME="relative/state" \
    python3 "$RECORDER" >"$OUT" 2>&1; then
  echo "expected relative XDG_STATE_HOME to fail"
  exit 1
fi
grep -Fq 'XDG_STATE_HOME must be an absolute path' "$OUT"

if printf '%s' "$(payload PostToolUse session-bad-home "$REAL" Read CONTRIBUTING.md success)" \
  | env -u TOUCHSTONE_HOOK_STATE_DIR -u XDG_STATE_HOME HOME="relative/home" \
    python3 "$RECORDER" >"$OUT" 2>&1; then
  echo "expected relative HOME to fail"
  exit 1
fi
grep -Fq 'HOME must be an absolute path' "$OUT"

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
grep -Fq 'tool_input.path' "$OUT"

BROKEN="$TMP/broken-state"
printf 'not a directory' > "$BROKEN"
if printf '%s' "$(payload PostToolUse session-broken "$REAL" Read CONTRIBUTING.md success)" \
  | TOUCHSTONE_HOOK_STATE_DIR="$BROKEN" python3 "$RECORDER" >"$OUT" 2>&1; then
  echo "expected invalid state dir to fail"
  exit 1
fi
grep -Fq 'not a directory' "$OUT"

echo "symlinked state and record paths are rejected without exposing evidence"
SYMLINK_STATE_REAL="$TMP/symlink-state-real"
SYMLINK_STATE="$TMP/symlink-state"
mkdir -p "$SYMLINK_STATE_REAL"
ln -s "$SYMLINK_STATE_REAL" "$SYMLINK_STATE"
if printf '%s' "$(payload PostToolUse session-symlink-dir "$REAL" Read CONTRIBUTING.md success)" \
  | TOUCHSTONE_HOOK_STATE_DIR="$SYMLINK_STATE" python3 "$RECORDER" >"$OUT" 2>&1; then
  echo "expected symlinked state dir to fail"
  exit 1
fi
grep -Fq 'must not be a symlink' "$OUT"
assert_read_rejected "$SYMLINK_STATE" "session-symlink-dir" 'must not be a symlink'

SYMLINK_SESSION="session-symlink-record"
SYMLINK_RECORD="$(record_path "$STATE" "$SYMLINK_SESSION")"
OUTSIDE_RECORD="$TMP/outside-record.json"
printf '{"session_id":"%s","paths":["%s"]}\n' \
  "$SYMLINK_SESSION" "$REAL/README.md" > "$OUTSIDE_RECORD"
ln -s "$OUTSIDE_RECORD" "$SYMLINK_RECORD"
before_symlink_attack="$(cat "$OUTSIDE_RECORD")"
if printf '%s' "$(payload PostToolUse "$SYMLINK_SESSION" "$REAL" Read CONTRIBUTING.md success)" \
  | python3 "$RECORDER" >"$OUT" 2>&1; then
  echo "expected symlinked session record to fail"
  exit 1
fi
grep -Fq 'record must not be a symlink' "$OUT"
test "$before_symlink_attack" = "$(cat "$OUTSIDE_RECORD")"
assert_read_rejected "$STATE" "$SYMLINK_SESSION" 'record must not be a symlink'

echo "records with unsafe permissions are rejected before reuse"
record "$(payload PostToolUse session-open-record "$REAL" Read CONTRIBUTING.md success)"
chmod 0644 "$(record_path "$STATE" session-open-record)"
if printf '%s' "$(payload PostToolUse session-open-record "$REAL" Read docs/DEVELOPMENT.md success)" \
  | python3 "$RECORDER" >"$OUT" 2>&1; then
  echo "expected permissive record to fail"
  exit 1
fi
grep -Fq 'owner-only permissions' "$OUT"
assert_read_rejected "$STATE" "session-open-record" 'owner-only permissions'

echo "COPILOT SESSION EVIDENCE OK"
