#!/usr/bin/env bash
# Tests Copilot's hook runner and its config without requiring Copilot CLI.

set -euo pipefail

HOOKS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="$HOOKS/copilot-hook-runner.py"
CONFIG="$HOOKS/copilot-hooks.json"
WORK="$HOOKS/.test-copilot-hook-runner.$$"
STATE="$WORK/state"
HOOK_INPUT="$WORK/hook-input"

cleanup() {
  local rc=$?
  rm -rf "$WORK"
  exit "$rc"
}
trap cleanup EXIT

mkdir -p "$WORK/elsewhere"

pre_payload() {
  python3 - "$WORK" <<'PY'
import json
import sys

json.dump(
    {
        "hook_event_name": "PreToolUse",
        "session_id": "copilot-session",
        "timestamp": "2026-09-12T00:00:00Z",
        "cwd": sys.argv[1],
        "tool_name": "Bash",
        "tool_input": {"command": "git commit -m test"},
    },
    sys.stdout,
)
PY
}

post_payload() {
  python3 - "$WORK" <<'PY'
import json
import sys

json.dump(
    {
        "hook_event_name": "PostToolUse",
        "session_id": "copilot-session",
        "timestamp": "2026-09-12T00:00:00Z",
        "cwd": sys.argv[1],
        "tool_name": "Read",
        "tool_input": {"path": "CONTRIBUTING.md"},
        "tool_result": {
            "result_type": "success",
            "text_result_for_llm": "guide contents",
        },
    },
    sys.stdout,
)
PY
}

run_runner() {
  local from_dir="$1" key="$2" payload="$3"
  (
    cd "$from_dir"
    printf '%s' "$payload" | python3 "$RUNNER" "$key"
  )
}

run_runner_with_state() {
  local from_dir="$1" key="$2" payload="$3"
  (
    cd "$from_dir"
    printf '%s' "$payload" | TOUCHSTONE_HOOK_STATE_DIR="$STATE" python3 "$RUNNER" "$key"
  )
}

run_runner_with_state_and_input_capture() {
  local from_dir="$1" key="$2" payload="$3"
  (
    cd "$from_dir"
    printf '%s' "$payload" \
      | TOUCHSTONE_HOOK_STATE_DIR="$STATE" TOUCHSTONE_HOOK_INPUT_EVIDENCE_DIR="$HOOK_INPUT" \
        python3 "$RUNNER" "$key"
  )
}

assert_json() {
  local label="$1" out="$2" check="$3"
  python3 - "$label" "$out" "$check" <<'PY'
import json
import sys
import textwrap

label, out, check = sys.argv[1:4]
data = json.loads(out)
namespace = {"data": data}
check = textwrap.dedent(check).strip()
if not eval(check, {}, namespace):
    raise AssertionError(f"{label}: {data!r} did not satisfy {check!r}")
print(f"  ok: {label}")
PY
}

assert_recorded() {
  local session_id="$1" expected="$2"
  TOUCHSTONE_HOOK_STATE_DIR="$STATE" python3 - "$HOOKS" "$session_id" "$expected" <<'PY'
import sys

sys.path.insert(0, sys.argv[1])
from copilot_session_evidence import read_session_paths

session_id, expected = sys.argv[2:4]
paths = read_session_paths(session_id)
assert paths == {expected}, paths
print(f"  ok: recorded {session_id}")
PY
}

assert_hook_input_recorded() {
  local key="$1" payload="$2"
  python3 - "$HOOK_INPUT" "$key" "$payload" <<'PY'
from pathlib import Path
import sys

hook_input_dir = Path(sys.argv[1])
key = sys.argv[2]
payload = sys.argv[3].encode("utf-8")
evidence_files = sorted(hook_input_dir.glob(f"{key}-*.json"))
assert len(evidence_files) == 1, evidence_files
assert evidence_files[0].read_bytes() == payload
print(f"  ok: exact hook stdin for {key}")
PY
}

echo "config parses and routes the expected gates"
python3 - "$CONFIG" <<'PY'
import json
import sys
from pathlib import Path

config = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
assert config["version"] == 1
hooks = config["hooks"]
assert set(hooks) == {"PreToolUse", "PostToolUse"}

pre = hooks["PreToolUse"]
assert [group["matcher"] for group in pre] == ["Bash", "Edit|Write|MultiEdit"]
assert [len(group["hooks"]) for group in pre] == [4, 3]
expected_pre = [
    ("crap-commit", 600),
    ("mutation-pr", 600),
    ("base-branch", 30),
    ("gate-pipe", 30),
    ("contributing", 30),
    ("generated-file", 30),
    ("worktree-edit", 30),
]
seen = []
for group in pre:
    for hook in group["hooks"]:
        assert hook["type"] == "command"
        assert "cwd" not in hook
        assert "bash" in hook and "command" not in hook
        assert "timeoutSec" in hook and "timeout" not in hook
        assert "CLAUDE_PLUGIN_ROOT" not in hook["bash"]
        assert hook["bash"].startswith('cd "$PLUGIN_ROOT/hooks" && exec python3 ./copilot-hook-runner.py ')
        seen.append((hook["bash"].rsplit(" ", 1)[-1], hook["timeoutSec"]))
assert seen == expected_pre
assert all(key != "guide-read" for key, _ in seen)

post = hooks["PostToolUse"]
assert [group["matcher"] for group in post] == ["Read", "Edit|Write|MultiEdit"]
assert [len(group["hooks"]) for group in post] == [1, 1]
assert post[0]["hooks"][0] == {
    "type": "command",
    "bash": 'cd "$PLUGIN_ROOT/hooks" && exec python3 ./copilot-hook-runner.py guide-read',
    "timeoutSec": 30,
}
assert post[1]["hooks"][0] == {
    "type": "command",
    "bash": 'cd "$PLUGIN_ROOT/hooks" && exec python3 ./copilot-hook-runner.py comment-policy',
    "timeoutSec": 30,
}
print("  ok: config")
PY

echo "pre-tool success allows"
out="$(run_runner "$HOOKS" guide-read "$(pre_payload)")"
assert_json "pre allow" "$out" 'data == {"permissionDecision": "allow"}'

echo "malformed input denies"
out="$(
  cd "$HOOKS"
  printf '{' | python3 "$RUNNER" guide-read
)"
assert_json "malformed deny" "$out" '
    (
    data.get("permissionDecision") == "deny"
    and "invalid JSON" in data.get("permissionDecisionReason", "")
    )
'

echo "unknown gate denies"
out="$(run_runner "$HOOKS" not-a-gate "$(pre_payload)")"
assert_json "unknown deny" "$out" '
    (
    data.get("permissionDecision") == "deny"
    and "unknown hook key" in data.get("permissionDecisionReason", "")
    )
'

echo "post-tool success is empty JSON and records evidence"
payload="$(post_payload)"
out="$(run_runner_with_state_and_input_capture "$HOOKS" guide-read "$payload")"
assert_json "post success" "$out" 'data == {}'
assert_recorded "copilot-session" "$WORK/CONTRIBUTING.md"
assert_hook_input_recorded "guide-read" "$payload"

echo "post-tool failure adds bounded context"
out="$(
  cd "$HOOKS"
  printf '%s' "$(post_payload)" | env -u TOUCHSTONE_HOOK_STATE_DIR -u HOME -u XDG_STATE_HOME \
    python3 "$RUNNER" guide-read
)"
assert_json "post failure" "$out" '
    (
    set(data) == {"additionalContext"}
    and "could not determine state dir" in data["additionalContext"]
    )
'

echo "runner resolves children relative to itself, not cwd"
out="$(run_runner_with_state "$WORK/elsewhere" guide-read "$(post_payload)")"
assert_json "arbitrary cwd" "$out" 'data == {}'

echo "COPILOT HOOK RUNNER OK"
