#!/usr/bin/env bash
# Tests the shared event boundary: Claude's legacy payload and Copilot's
# documented PascalCase compatibility payload must normalize identically.

set -euo pipefail

HOOKS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

python3 - "$HOOKS" <<'PY'
import sys
from pathlib import Path

sys.path.insert(0, sys.argv[1])
from hook_invocation import normalize_invocation

copilot = normalize_invocation({
    "hook_event_name": "PreToolUse",
    "session_id": "copilot-session",
    "timestamp": "2026-09-12T00:00:00Z",
    "cwd": "/tmp/repo",
    "tool_name": "Edit",
    "tool_input": {"file_path": "pkg/a.py", "old_string": "x", "new_string": "y"},
})
assert copilot is not None
assert copilot.host == "copilot"
assert copilot.event == "pre_tool_use"
assert copilot.session_id == "copilot-session"
assert copilot.cwd == Path("/tmp/repo").resolve()
assert copilot.tool_name == "Edit"
assert copilot.tool_input["file_path"] == "pkg/a.py"

post = normalize_invocation({
    "hook_event_name": "PostToolUse",
    "session_id": "copilot-session",
    "cwd": "/tmp/repo",
    "tool_name": "Write",
    "tool_input": {"file_path": "pkg/b.py", "content": "ok"},
})
assert post is not None
assert post.host == "copilot"
assert post.event == "post_tool_use"

claude = normalize_invocation({
    "cwd": "/tmp/repo",
    "tool_name": "Edit",
    "tool_input": {"file_path": "pkg/a.py"},
})
assert claude is not None
assert claude.host == "claude"
assert claude.event == "pre_tool_use"

codex = normalize_invocation({
    "hook_event_name": "PreToolUse",
    "source": "codex",
    "session_id": "codex-session",
    "cwd": "/tmp/repo",
    "tool_name": "Bash",
    "tool_input": {"command": "echo hi"},
})
assert codex is not None
assert codex.host == "codex"

legacy = normalize_invocation({
    "cwd": "/tmp/repo",
    "tool_name": "codex-report",
    "tool_input": {"file_path": "pkg/a.py"},
})
assert legacy is not None
assert legacy.host == "claude"

assert normalize_invocation({"hook_event_name": "PreToolUse", "tool_input": []}) is None
assert normalize_invocation({"tool_input": []}) is None
assert normalize_invocation({
    "hook_event_name": "PreToolUse",
    "cwd": "/tmp/repo",
    "tool_name": "Edit",
    "tool_input": {"file_path": "pkg/a.py"},
}) is not None
assert normalize_invocation({
    "hook_event_name": "NotAHook",
    "cwd": "/tmp/repo",
    "tool_name": "Edit",
    "tool_input": {"file_path": "pkg/a.py"},
}) is None
assert normalize_invocation({
    "hook_event_name": "PreToolUse",
    "cwd": "",
    "tool_name": "Edit",
    "tool_input": {"file_path": "pkg/a.py"},
}) is None
assert normalize_invocation({
    "hook_event_name": "PreToolUse",
    "cwd": "/tmp/repo",
    "tool_name": "",
    "tool_input": {"file_path": "pkg/a.py"},
}) is None
print("HOOK INVOCATION OK")
PY
