#!/usr/bin/env bash
# Tests Copilot's hook runner and its config without requiring Copilot CLI.

set -euo pipefail

HOOKS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="$HOOKS/copilot-hook-runner.py"
CONFIG="$HOOKS/copilot-hooks.json"
WORK="$HOOKS/.test-copilot-hook-runner.$$"
TARGET="$HOOKS/copilot_session_evidence.py"
BACKUP="$WORK/copilot_session_evidence.py.orig"
HAD_TARGET=0

cleanup() {
  local rc=$?
  rm -f "$TARGET"
  if [ "$HAD_TARGET" -eq 1 ] && [ -e "$BACKUP" ]; then
    mv "$BACKUP" "$TARGET"
  fi
  rm -rf "$WORK"
  exit "$rc"
}
trap cleanup EXIT

mkdir -p "$WORK/elsewhere"
if [ -e "$TARGET" ]; then
  HAD_TARGET=1
  mv "$TARGET" "$BACKUP"
fi

write_child() {
  python3 - "$TARGET" "$1" "$2" "$3" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
exit_code = int(sys.argv[2])
stderr_text = sys.argv[3]
stdout_text = sys.argv[4]
path.write_text(
    "#!/usr/bin/env python3\n"
    "import sys\n"
    "sys.stdin.buffer.read()\n"
    f"sys.stderr.write({stderr_text!r})\n"
    f"sys.stdout.write({stdout_text!r})\n"
    f"raise SystemExit({exit_code})\n",
    encoding="utf-8",
)
PY
  chmod +x "$TARGET"
}

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
        "tool_input": {"file_path": "CONTRIBUTING.md"},
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
assert [len(group["hooks"]) for group in pre] == [4, 2]
expected_pre = [
    ("crap-commit", 600),
    ("mutation-pr", 600),
    ("base-branch", 30),
    ("gate-pipe", 30),
    ("contributing", 30),
    ("generated-file", 30),
]
seen = []
for group in pre:
    for hook in group["hooks"]:
        assert hook["type"] == "command"
        assert hook["cwd"] == "hooks"
        assert "bash" in hook and "command" not in hook
        assert "timeoutSec" in hook and "timeout" not in hook
        assert "CLAUDE_PLUGIN_ROOT" not in hook["bash"]
        assert hook["bash"].startswith("python3 ./copilot-hook-runner.py ")
        seen.append((hook["bash"].rsplit(" ", 1)[-1], hook["timeoutSec"]))
assert seen == expected_pre
assert all(key != "guide-read" for key, _ in seen)

post = hooks["PostToolUse"]
assert [group["matcher"] for group in post] == ["Read"]
assert [len(group["hooks"]) for group in post] == [1]
hook = post[0]["hooks"][0]
assert hook == {
    "type": "command",
    "bash": "python3 ./copilot-hook-runner.py guide-read",
    "cwd": "hooks",
    "timeoutSec": 30,
}
print("  ok: config")
PY

echo "pre-tool success allows"
write_child 0 "" "ignored stdout"
out="$(run_runner "$HOOKS" guide-read "$(pre_payload)")"
assert_json "pre allow" "$out" 'data == {"permissionDecision": "allow"}'

echo "pre-tool failure denies and uses stderr, not child stdout"
write_child 2 "child blocked\n" "noise that must stay hidden\n"
out="$(run_runner "$HOOKS" guide-read "$(pre_payload)")"
assert_json "pre deny" "$out" '
    (
    data.get("permissionDecision") == "deny"
    and "child blocked" in data.get("permissionDecisionReason", "")
    and "noise that must stay hidden" not in data.get("permissionDecisionReason", "")
    )
'

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

echo "post-tool success is empty JSON"
write_child 0 "" "ignored stdout"
out="$(run_runner "$HOOKS" guide-read "$(post_payload)")"
assert_json "post success" "$out" 'data == {}'

echo "post-tool failure adds bounded context"
write_child 2 "post recorder failed\n" "ignored stdout\n"
out="$(run_runner "$HOOKS" guide-read "$(post_payload)")"
assert_json "post failure" "$out" '
    (
    set(data) == {"additionalContext"}
    and "post recorder failed" in data["additionalContext"]
    and "ignored stdout" not in data["additionalContext"]
    )
'

echo "runner resolves children relative to itself, not cwd"
write_child 0 "" ""
out="$(run_runner "$WORK/elsewhere" guide-read "$(pre_payload)")"
assert_json "arbitrary cwd" "$out" 'data == {"permissionDecision": "allow"}'

echo "COPILOT HOOK RUNNER OK"
