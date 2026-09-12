#!/usr/bin/env bash
# Run a real Copilot CLI smoke test against an isolated user-level hook install.
#
# Exit 0 on pass, 0 with a SKIP line only when Copilot CLI is unavailable or
# unauthenticated, 1 on a smoke failure, 2 on local setup misuse.

set -euo pipefail

if [ -z "${BASH_VERSINFO:-}" ] || [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  echo "run-copilot-hook-smoke: bash 4+ is required" >&2
  exit 2
fi

umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SOURCE_CONFIG="$ROOT/hooks/copilot-hooks.json"
SOURCE_HOOKS="$ROOT/hooks"
SOURCE_SKILLS="$ROOT/skills"
PLUGIN_MANIFEST="$ROOT/.claude-plugin/plugin.json"
REAL_HOME="${HOME:-}"
REAL_XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-}"

SCRATCH_ROOT=""
KEEP_SCRATCH="${TOUCHSTONE_KEEP_SMOKE_ROOT:-0}"
CURRENT_STEP="setup"

cleanup() {
  local rc=$?
  if [ -n "${SCRATCH_ROOT:-}" ] && [ -d "$SCRATCH_ROOT" ]; then
    if [ "$rc" -eq 0 ] && [ "$KEEP_SCRATCH" != "1" ]; then
      rm -rf "$SCRATCH_ROOT"
    else
      printf 'run-copilot-hook-smoke: kept scratch root %s (%s)\n' "$SCRATCH_ROOT" "$CURRENT_STEP" >&2
    fi
  fi
  exit "$rc"
}
trap cleanup EXIT INT TERM

skip_unavailable() {
  echo 'SKIP: copilot CLI unavailable or unauthenticated'
  exit 0
}

print_artifact() {
  local label="$1" path="$2"
  printf -- '--- %s (%s) ---%s' "$label" "$path" $'\n' >&2
  if [ -f "$path" ]; then
    sed 's/^/  /' "$path" >&2
  else
    echo '  <missing>' >&2
  fi
}

fail_with_logs() {
  local message="$1"
  shift
  echo "$message" >&2
  while [ "$#" -gt 0 ]; do
    print_artifact "$1" "$2"
    shift 2
  done
  exit 1
}

probe_is_auth_skip() {
  local stdout_path="$1" stderr_path="$2"
  python3 - "$stdout_path" "$stderr_path" <<'PY'
import re
import sys
from pathlib import Path

stdout_path, stderr_path = sys.argv[1:3]
text = ""
for path in (stdout_path, stderr_path):
    file = Path(path)
    if file.exists():
        text += file.read_text(encoding="utf-8", errors="replace") + "\n"
text = text.lower()
patterns = [
    r"\bno authentication information found\b",
    r"\bnot authenticated\b",
    r"\bunauthenticated\b",
    r"\bauthentication required\b",
    r"\blogin required\b",
    r"\bplease (?:sign in|log in)\b",
    r"\byou must (?:sign in|log in)\b",
    r"\brun\s+copilot\s+auth\s+login\b",
]
raise SystemExit(0 if any(re.search(pattern, text) for pattern in patterns) else 1)
PY
}

with_copilot_env() {
  if [ -n "${SMOKE_GH_TOKEN:-}" ]; then
    HOME="$SMOKE_HOME" \
    XDG_CONFIG_HOME="$SMOKE_XDG_CONFIG_HOME" \
    XDG_CACHE_HOME="$SMOKE_XDG_CACHE_HOME" \
    XDG_STATE_HOME="$SMOKE_XDG_STATE_HOME" \
    GH_CONFIG_DIR="$SMOKE_XDG_CONFIG_HOME/gh" \
    GH_TOKEN="$SMOKE_GH_TOKEN" \
    COPILOT_HOME="$SMOKE_COPILOT_HOME" \
      "$@"
  else
    HOME="$SMOKE_HOME" \
    XDG_CONFIG_HOME="$SMOKE_XDG_CONFIG_HOME" \
    XDG_CACHE_HOME="$SMOKE_XDG_CACHE_HOME" \
    XDG_STATE_HOME="$SMOKE_XDG_STATE_HOME" \
    GH_CONFIG_DIR="$SMOKE_XDG_CONFIG_HOME/gh" \
    COPILOT_HOME="$SMOKE_COPILOT_HOME" \
      "$@"
  fi
}

with_hook_env() {
  PLUGIN_ROOT="$SMOKE_INSTALLED_ROOT" \
  TOUCHSTONE_HOOK_STATE_DIR="$SMOKE_STATE_DIR" \
  TOUCHSTONE_HOOK_INPUT_EVIDENCE_DIR="$SMOKE_HOOK_INPUT_DIR" \
    "$@"
}

seed_gh_auth() {
  local source_dir=""
  if [ -n "$REAL_XDG_CONFIG_HOME" ] && [ -d "$REAL_XDG_CONFIG_HOME/gh" ]; then
    source_dir="$REAL_XDG_CONFIG_HOME/gh"
  elif [ -n "$REAL_HOME" ] && [ -d "$REAL_HOME/.config/gh" ]; then
    source_dir="$REAL_HOME/.config/gh"
  fi
  if [ -z "$source_dir" ]; then
    return 0
  fi
  cp -R "$source_dir" "$SMOKE_XDG_CONFIG_HOME/gh"
}

seed_smoke_auth_token() {
  SMOKE_GH_TOKEN="${COPILOT_GITHUB_TOKEN:-${GH_TOKEN:-${GITHUB_TOKEN:-}}}"
  if [ -n "$SMOKE_GH_TOKEN" ]; then
    return 0
  fi
  if ! command -v gh >/dev/null 2>&1; then
    return 0
  fi
  if SMOKE_GH_TOKEN="$(gh auth token 2>/dev/null)"; then
    return 0
  fi
  SMOKE_GH_TOKEN=""
}

write_text() {
  local path="$1" text="$2"
  python3 - "$path" "$text" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
path.write_text(sys.argv[2], encoding="utf-8")
PY
}

uuid4() {
  python3 - <<'PY'
import uuid
print(uuid.uuid4())
PY
}

run_copilot() {
  local session_id="$1" prompt="$2" available_tools="$3" jsonl="$4" stderr_file="$5"
  local -a cmd=(
    copilot
    -C "$SMOKE_REPO"
    -p "$prompt"
    --session-id "$session_id"
    --allow-all-tools
    --disable-builtin-mcps
    --no-custom-instructions
    --no-auto-update
    --no-color
    --output-format json
    --stream off
  )
  if [ -n "$available_tools" ]; then
    cmd+=(--available-tools="$available_tools")
  fi
  if ! with_hook_env with_copilot_env "${cmd[@]}" >"$jsonl" 2>"$stderr_file"; then
    fail_with_logs \
      "run-copilot-hook-smoke: copilot failed unexpectedly during $CURRENT_STEP" \
      "copilot stderr" "$stderr_file" \
      "copilot jsonl" "$jsonl"
  fi
}

assert_probe() {
  local jsonl="$1" version_out="$2" detail_path="$3"
  python3 - "$jsonl" "$version_out" "$detail_path" <<'PY'
import json
import sys
from pathlib import Path

jsonl_path, version_out, detail_path = sys.argv[1:4]
events = []
for line in Path(jsonl_path).read_text(encoding="utf-8").splitlines():
    line = line.strip()
    if not line:
        continue
    events.append(json.loads(line))

result = next((event for event in events if event.get("type") == "result"), None)
if result is None or result.get("exitCode") != 0:
    raise SystemExit("probe did not finish cleanly")

assistant = next(
    (
        event for event in reversed(events)
        if event.get("type") == "assistant.message"
        and (event.get("data") or {}).get("content")
    ),
    None,
)
if assistant is None or (assistant.get("data") or {}).get("content") != "PROBE_READY":
    raise SystemExit("probe did not return PROBE_READY")

Path(detail_path).write_text(
    json.dumps(
        {
            "copilot_version": version_out.strip(),
            "probe_assistant_message": assistant["data"]["content"],
            "probe_session_id": result.get("sessionId"),
        },
        indent=2,
    )
    + "\n",
    encoding="utf-8",
)
PY
}

assert_manifest_version() {
  local manifest="$1" expected_version="$2" detail_path="$3"
  python3 - "$manifest" "$expected_version" "$detail_path" <<'PY'
import json
import sys
from pathlib import Path

manifest_path, expected_version, detail_path = sys.argv[1:4]
manifest = json.loads(Path(manifest_path).read_text(encoding="utf-8"))
actual_version = manifest.get("version")
if actual_version != expected_version:
    raise SystemExit(f"expected manifest version {expected_version!r}, got {actual_version!r}")

Path(detail_path).write_text(
    json.dumps(
        {
            "manifest_path": str(Path(manifest_path).resolve(strict=False)),
            "name": manifest.get("name"),
            "version": actual_version,
        },
        indent=2,
    )
    + "\n",
    encoding="utf-8",
)
PY
}

copy_hook_config() {
  local source_config="$1" target_config="$2" detail_path="$3"
  python3 - "$source_config" "$target_config" "$detail_path" <<'PY'
import json
import re
import sys
from pathlib import Path

source_config, target_config, detail_path = [Path(value) for value in sys.argv[1:4]]
source_bytes = source_config.read_bytes()
target_config.write_bytes(source_bytes)
if target_config.read_bytes() != source_bytes:
    raise SystemExit("installed config bytes drifted from source config")

source = json.loads(source_bytes.decode("utf-8"))
assert source["version"] == 1
assert set(source) == {"version", "hooks"}
assert isinstance(source["hooks"], dict) and source["hooks"]

command_re = re.compile(
    r'cd "\$PLUGIN_ROOT/hooks" && exec python3 \./copilot-hook-runner\.py ([a-z0-9-]+)$'
)
installed_hooks = []

for event_name, groups in source["hooks"].items():
    assert isinstance(groups, list) and groups, event_name
    for group in groups:
        assert isinstance(group, dict)
        assert isinstance(group.get("matcher"), str) and group["matcher"]
        hooks = group.get("hooks")
        assert isinstance(hooks, list) and hooks
        for hook in hooks:
            assert hook.get("type") == "command", hook
            assert "cwd" not in hook, hook
            assert "command" not in hook, hook
            assert isinstance(hook.get("bash"), str) and hook["bash"], hook
            assert isinstance(hook.get("timeoutSec"), int), hook
            match = command_re.fullmatch(hook["bash"].strip())
            assert match is not None, hook["bash"]
            key = match.group(1)
            installed_hooks.append(
                {
                    "event": event_name,
                    "matcher": group["matcher"],
                    "key": key,
                    "bash": hook["bash"],
                    "timeoutSec": hook["timeoutSec"],
                }
            )

detail_path.write_text(
    json.dumps(
        {
            "source_event_keys": list(source["hooks"].keys()),
            "installed_event_keys": list(source["hooks"].keys()),
            "installed_config_path": str(target_config),
            "copied_verbatim": True,
            "plugin_root_required": True,
            "installed_hooks": installed_hooks,
        },
        indent=2,
    )
    + "\n",
    encoding="utf-8",
)
PY
}

assert_denied_bash() {
  local jsonl="$1" command_substring="$2" reason_substring="$3" detail_path="$4"
  python3 - "$jsonl" "$command_substring" "$reason_substring" "$detail_path" <<'PY'
import json
import sys
from pathlib import Path

jsonl_path, command_substring, reason_substring, detail_path = sys.argv[1:5]
events = []
for line in Path(jsonl_path).read_text(encoding="utf-8").splitlines():
    line = line.strip()
    if not line:
        continue
    events.append(json.loads(line))

result = next((event for event in events if event.get("type") == "result"), None)
if result is None or result.get("exitCode") != 0:
    raise SystemExit("Copilot commit attempt did not finish cleanly")

starts = {}
for event in events:
    if event.get("type") == "tool.execution_start":
        data = event.get("data") or {}
        starts[data.get("toolCallId")] = data

match = None
for event in events:
    if event.get("type") != "tool.execution_complete":
        continue
    data = event.get("data") or {}
    start = starts.get(data.get("toolCallId"))
    if not start or start.get("toolName") != "bash":
        continue
    command = (start.get("arguments") or {}).get("command", "")
    if command_substring not in command:
        continue
    error = data.get("error") or {}
    if data.get("success") is not False or error.get("code") != "denied":
        raise SystemExit(f"expected denied bash command, got {data!r}")
    message = error.get("message", "")
    if reason_substring not in message:
        raise SystemExit(f"missing denial reason {reason_substring!r}: {message!r}")
    match = {"command": command, "error": message, "tool_call_id": data.get("toolCallId")}
    break

if match is None:
    raise SystemExit(f"did not observe denied bash command containing {command_substring!r}")

Path(detail_path).write_text(json.dumps(match, indent=2) + "\n", encoding="utf-8")
PY
}

assert_successful_view() {
  local jsonl="$1" target_path="$2" expected_text="$3" detail_path="$4"
  python3 - "$jsonl" "$target_path" "$expected_text" "$detail_path" <<'PY'
import json
import sys
from pathlib import Path

jsonl_path, target_path, expected_text, detail_path = sys.argv[1:5]
events = []
for line in Path(jsonl_path).read_text(encoding="utf-8").splitlines():
    line = line.strip()
    if not line:
        continue
    events.append(json.loads(line))

result = next((event for event in events if event.get("type") == "result"), None)
if result is None or result.get("exitCode") != 0:
    raise SystemExit("Copilot guide read did not finish cleanly")

starts = {}
for event in events:
    if event.get("type") == "tool.execution_start":
        data = event.get("data") or {}
        starts[data.get("toolCallId")] = data

match = None
for event in events:
    if event.get("type") != "tool.execution_complete":
        continue
    data = event.get("data") or {}
    start = starts.get(data.get("toolCallId"))
    if not start or start.get("toolName") != "view":
        continue
    path = (start.get("arguments") or {}).get("path")
    if path != target_path:
        continue
    if data.get("success") is not True:
        raise SystemExit(f"expected successful view of {target_path}, got {data!r}")
    content = ((data.get("result") or {}).get("content")) or ""
    if expected_text not in content:
        raise SystemExit(f"view content missing {expected_text!r}: {content!r}")
    match = {"path": path, "content": content, "tool_call_id": data.get("toolCallId")}
    break

if match is None:
    raise SystemExit(f"did not observe successful view of {target_path!r}")

Path(detail_path).write_text(json.dumps(match, indent=2) + "\n", encoding="utf-8")
PY
}

assert_recorded_state() {
  local hook_dir="$1" state_dir="$2" session_id="$3" expected_path="$4" detail_path="$5"
  TOUCHSTONE_HOOK_STATE_DIR="$state_dir" python3 - "$hook_dir" "$session_id" "$expected_path" "$detail_path" <<'PY'
import json
import os
import stat
import sys
from pathlib import Path

hook_dir, session_id, expected_path, detail_path = sys.argv[1:5]
sys.path.insert(0, hook_dir)
from copilot_session_evidence import read_session_paths

paths = sorted(read_session_paths(session_id))
expected = str(Path(expected_path).resolve(strict=False))
if paths != [expected]:
    raise SystemExit(f"expected exactly one recorded path {expected!r}, got {paths!r}")

state_mode = stat.S_IMODE(os.lstat(os.environ["TOUCHSTONE_HOOK_STATE_DIR"]).st_mode)
Path(detail_path).write_text(
    json.dumps(
        {
            "session_id": session_id,
            "paths": paths,
            "state_dir_mode_octal": format(state_mode, "#04o"),
        },
        indent=2,
    )
    + "\n",
    encoding="utf-8",
)
PY
}

assert_denied_edit() {
  local jsonl="$1" target_path="$2" reason_substring="$3" detail_path="$4"
  python3 - "$jsonl" "$target_path" "$reason_substring" "$detail_path" <<'PY'
import json
import sys
from pathlib import Path

jsonl_path, target_path, reason_substring, detail_path = sys.argv[1:5]
events = []
for line in Path(jsonl_path).read_text(encoding="utf-8").splitlines():
    line = line.strip()
    if not line:
        continue
    events.append(json.loads(line))

result = next((event for event in events if event.get("type") == "result"), None)
if result is None or result.get("exitCode") != 0:
    raise SystemExit("Copilot generated edit attempt did not finish cleanly")

starts = {}
for event in events:
    if event.get("type") == "tool.execution_start":
        data = event.get("data") or {}
        starts[data.get("toolCallId")] = data

match = None
for event in events:
    if event.get("type") != "tool.execution_complete":
        continue
    data = event.get("data") or {}
    start = starts.get(data.get("toolCallId"))
    if not start or start.get("toolName") != "edit":
        continue
    path = (start.get("arguments") or {}).get("path")
    if path != target_path:
        continue
    error = data.get("error") or {}
    if data.get("success") is not False or error.get("code") != "denied":
        raise SystemExit(f"expected denied edit of {target_path}, got {data!r}")
    message = error.get("message", "")
    if reason_substring not in message:
        raise SystemExit(f"missing denial reason {reason_substring!r}: {message!r}")
    match = {"path": path, "error": message, "tool_call_id": data.get("toolCallId")}
    break

if match is None:
    raise SystemExit(f"did not observe denied edit of {target_path!r}")

Path(detail_path).write_text(json.dumps(match, indent=2) + "\n", encoding="utf-8")
PY
}

assert_successful_edit() {
  local jsonl="$1" target_path="$2" detail_path="$3"
  python3 - "$jsonl" "$target_path" "$detail_path" <<'PY'
import json
import sys
from pathlib import Path

jsonl_path, target_path, detail_path = sys.argv[1:4]
events = []
for line in Path(jsonl_path).read_text(encoding="utf-8").splitlines():
    line = line.strip()
    if not line:
        continue
    events.append(json.loads(line))

result = next((event for event in events if event.get("type") == "result"), None)
if result is None or result.get("exitCode") != 0:
    raise SystemExit("Copilot ordinary edit did not finish cleanly")

starts = {}
for event in events:
    if event.get("type") == "tool.execution_start":
        data = event.get("data") or {}
        starts[data.get("toolCallId")] = data

match = None
for event in events:
    if event.get("type") != "tool.execution_complete":
        continue
    data = event.get("data") or {}
    start = starts.get(data.get("toolCallId"))
    if not start or start.get("toolName") != "edit":
        continue
    path = (start.get("arguments") or {}).get("path")
    if path != target_path:
        continue
    if data.get("success") is not True:
        raise SystemExit(f"expected successful edit of {target_path}, got {data!r}")
    result_text = ((data.get("result") or {}).get("content")) or ""
    if "updated with changes" not in result_text:
        raise SystemExit(f"unexpected edit result text: {result_text!r}")
    match = {"path": path, "result": result_text, "tool_call_id": data.get("toolCallId")}
    break

if match is None:
    raise SystemExit(f"did not observe successful edit of {target_path!r}")

Path(detail_path).write_text(json.dumps(match, indent=2) + "\n", encoding="utf-8")
PY
}

SCRATCH_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/touchstone-copilot-hook-smoke.XXXXXX")"
SCRATCH_ROOT="$(cd "$SCRATCH_ROOT" && pwd -P)"
mkdir -p "$SCRATCH_ROOT/artifacts"

SMOKE_HOME="$SCRATCH_ROOT/home"
SMOKE_XDG_CONFIG_HOME="$SCRATCH_ROOT/xdg-config"
SMOKE_XDG_CACHE_HOME="$SCRATCH_ROOT/xdg-cache"
SMOKE_XDG_STATE_HOME="$SCRATCH_ROOT/xdg-state"
SMOKE_COPILOT_HOME="$SCRATCH_ROOT/copilot-home"
SMOKE_REPO="$SCRATCH_ROOT/repo"
SMOKE_INSTALLED_ROOT="$SCRATCH_ROOT/installed/touchstone"
SMOKE_STATE_DIR="$SCRATCH_ROOT/hook-state"
SMOKE_HOOK_INPUT_DIR="$SCRATCH_ROOT/artifacts/hook-stdin"

mkdir -p \
  "$SCRATCH_ROOT/probe-cwd" \
  "$SMOKE_HOME" \
  "$SMOKE_XDG_CONFIG_HOME" \
  "$SMOKE_XDG_CACHE_HOME" \
  "$SMOKE_XDG_STATE_HOME" \
  "$SMOKE_COPILOT_HOME/hooks" \
  "$SMOKE_HOOK_INPUT_DIR"
seed_gh_auth
seed_smoke_auth_token

if ! command -v copilot >/dev/null 2>&1; then
  skip_unavailable
fi

CURRENT_STEP="detect-version"
VERSION_STDOUT="$SCRATCH_ROOT/artifacts/00-version.stdout"
VERSION_STDERR="$SCRATCH_ROOT/artifacts/00-version.stderr"
if ! with_copilot_env copilot --version >"$VERSION_STDOUT" 2>"$VERSION_STDERR"; then
  fail_with_logs \
    'run-copilot-hook-smoke: copilot --version failed unexpectedly' \
    "copilot --version stdout" "$VERSION_STDOUT" \
    "copilot --version stderr" "$VERSION_STDERR"
fi
VERSION_OUTPUT="$(<"$VERSION_STDOUT")"
VERSION_LINE="${VERSION_OUTPUT%%$'\n'*}"

CURRENT_STEP="probe-auth"
PROBE_JSONL="$SCRATCH_ROOT/artifacts/00-probe.jsonl"
PROBE_STDERR="$SCRATCH_ROOT/artifacts/00-probe.stderr"
PROBE_DETAIL="$SCRATCH_ROOT/artifacts/00-probe-summary.json"
PROBE_SESSION_ID="$(uuid4)"
if ! with_copilot_env copilot -C "$SCRATCH_ROOT/probe-cwd" \
  -p 'Reply with PROBE_READY only.' \
  --session-id "$PROBE_SESSION_ID" \
  --allow-all-tools \
  --disable-builtin-mcps \
  --no-custom-instructions \
  --no-auto-update \
  --no-color \
  --output-format json \
  --stream off >"$PROBE_JSONL" 2>"$PROBE_STDERR"; then
  if probe_is_auth_skip "$PROBE_JSONL" "$PROBE_STDERR"; then
    skip_unavailable
  fi
  fail_with_logs \
    'run-copilot-hook-smoke: probe failed unexpectedly' \
    "probe stderr" "$PROBE_STDERR" \
    "probe jsonl" "$PROBE_JSONL"
fi
if ! assert_probe "$PROBE_JSONL" "$VERSION_LINE" "$PROBE_DETAIL"; then
  fail_with_logs \
    'run-copilot-hook-smoke: probe output drifted or failed assertions' \
    "probe stderr" "$PROBE_STDERR" \
    "probe jsonl" "$PROBE_JSONL"
fi

CURRENT_STEP="build-smoke-repo"
mkdir -p "$SMOKE_REPO/src" "$SMOKE_INSTALLED_ROOT"
git -C "$SMOKE_REPO" init -q
git -C "$SMOKE_REPO" config user.name 'Touchstone Smoke'
git -C "$SMOKE_REPO" config user.email 'touchstone-smoke@example.com'
git -C "$SMOKE_REPO" config commit.gpgsign false
git -C "$SMOKE_REPO" branch -M main

write_text "$SMOKE_REPO/.crap-gated" $'\n'
write_text "$SMOKE_REPO/CONTRIBUTING.md" $'Read this guide before editing.\n'
write_text "$SMOKE_REPO/src/ordinary.txt" $'before\n'
write_text "$SMOKE_REPO/src/generated_fixture.go" $'// Code generated by smoke. DO NOT EDIT.\npackage smoke\n\nfunc generatedValue() int { return 1 }\n'
write_text "$SMOKE_REPO/src/commit-target.txt" $'base\n'

git -C "$SMOKE_REPO" add -f .crap-gated CONTRIBUTING.md src
git -C "$SMOKE_REPO" commit -qm 'fixture: root'
BASE_HEAD="$(git -C "$SMOKE_REPO" rev-parse HEAD)"
write_text "$SMOKE_REPO/src/commit-target.txt" $'staged change\n'
git -C "$SMOKE_REPO" add src/commit-target.txt

CURRENT_STEP="install-hooks"
cp -R "$SOURCE_HOOKS" "$SMOKE_INSTALLED_ROOT/hooks"
cp -R "$SOURCE_SKILLS" "$SMOKE_INSTALLED_ROOT/skills"
mkdir -p "$SMOKE_INSTALLED_ROOT/.claude-plugin" "$SMOKE_STATE_DIR"
cp "$PLUGIN_MANIFEST" "$SMOKE_INSTALLED_ROOT/.claude-plugin/plugin.json"
INSTALLED_CONFIG="$SMOKE_COPILOT_HOME/hooks/touchstone.json"
CONFIG_DETAIL="$SCRATCH_ROOT/artifacts/01-installed-config.json"
MANIFEST_DETAIL="$SCRATCH_ROOT/artifacts/02-installed-manifest.json"
copy_hook_config \
  "$SOURCE_CONFIG" \
  "$INSTALLED_CONFIG" \
  "$CONFIG_DETAIL"
assert_manifest_version "$SMOKE_INSTALLED_ROOT/.claude-plugin/plugin.json" "0.6.5" "$MANIFEST_DETAIL"

COMMIT_SESSION_ID="$(uuid4)"
GUIDE_SESSION_ID="$(uuid4)"
GUIDE_PATH="$SMOKE_REPO/CONTRIBUTING.md"
GENERATED_PATH="$SMOKE_REPO/src/generated_fixture.go"
ORDINARY_PATH="$SMOKE_REPO/src/ordinary.txt"
GENERATED_BASELINE="$SCRATCH_ROOT/artifacts/generated-baseline.go"
READ_HOOK_INPUT_DETAIL="$SCRATCH_ROOT/artifacts/22-guide-read-hook-input.json"
EDIT_HOOK_INPUT_DETAIL="$SCRATCH_ROOT/artifacts/41-ordinary-edit-hook-input.json"
cp "$GENERATED_PATH" "$GENERATED_BASELINE"

CURRENT_STEP="commit-denial"
COMMIT_JSONL="$SCRATCH_ROOT/artifacts/10-raw-commit.jsonl"
COMMIT_STDERR="$SCRATCH_ROOT/artifacts/10-raw-commit.stderr"
COMMIT_DETAIL="$SCRATCH_ROOT/artifacts/10-raw-commit.json"
RAW_COMMIT_TOKEN="smoke-raw-commit-${COMMIT_SESSION_ID%%-*}"
run_copilot \
  "$COMMIT_SESSION_ID" \
  "Use the bash tool. Run exactly this command and do not use any wrapper: git commit -m $RAW_COMMIT_TOKEN. Do not run git add, and do not change files. After the tool result, reply RAW_COMMIT_ATTEMPT_DONE only." \
  "bash" \
  "$COMMIT_JSONL" \
  "$COMMIT_STDERR"
assert_denied_bash "$COMMIT_JSONL" "git commit -m $RAW_COMMIT_TOKEN" 'crap-commit-gate:' "$COMMIT_DETAIL"
if [ "$(git -C "$SMOKE_REPO" rev-parse HEAD)" != "$BASE_HEAD" ]; then
  echo "run-copilot-hook-smoke: raw commit unexpectedly changed HEAD" >&2
  exit 1
fi

CURRENT_STEP="guide-read"
READ_JSONL="$SCRATCH_ROOT/artifacts/20-guide-read.jsonl"
READ_STDERR="$SCRATCH_ROOT/artifacts/20-guide-read.stderr"
READ_DETAIL="$SCRATCH_ROOT/artifacts/20-guide-read.json"
STATE_DETAIL="$SCRATCH_ROOT/artifacts/21-guide-state.json"
run_copilot \
  "$GUIDE_SESSION_ID" \
  "Use the file-reading tool exactly once. Read the exact file at $GUIDE_PATH. Do not inspect any other path. After the tool result, reply GUIDE_READ_DONE only." \
  "view" \
  "$READ_JSONL" \
  "$READ_STDERR"
assert_successful_view "$READ_JSONL" "$GUIDE_PATH" 'Read this guide before editing.' "$READ_DETAIL"
assert_recorded_state "$SMOKE_INSTALLED_ROOT/hooks" "$SMOKE_STATE_DIR" "$GUIDE_SESSION_ID" "$GUIDE_PATH" "$STATE_DETAIL"
python3 - "$SMOKE_HOOK_INPUT_DIR" "$READ_HOOK_INPUT_DETAIL" "$GUIDE_PATH" <<'PY'
import json
import sys
from pathlib import Path

evidence_dir, detail_path, expected_path = sys.argv[1:4]
matches = []
for candidate in sorted(Path(evidence_dir).glob("guide-read-*.json")):
    payload = json.loads(candidate.read_text(encoding="utf-8"))
    tool_input = payload.get("tool_input")
    if not isinstance(tool_input, dict):
        continue
    if payload.get("hook_event_name") != "PostToolUse":
        continue
    if payload.get("tool_name") != "Read":
        continue
    if tool_input.get("path") != expected_path:
        continue
    tool_result = payload.get("tool_result")
    if not isinstance(tool_result, dict) or tool_result.get("result_type") != "success":
        continue
    matches.append(
        {
            "evidence_file": str(candidate),
            "hook_event_name": payload["hook_event_name"],
            "tool_name": payload["tool_name"],
            "tool_input": tool_input,
            "tool_result": tool_result,
            "session_id": payload.get("session_id"),
        }
    )

if not matches:
    raise SystemExit(
        f"did not observe direct guide-read hook payload with PostToolUse and tool_input.path={expected_path!r}"
    )

Path(detail_path).write_text(json.dumps(matches[0], indent=2) + "\n", encoding="utf-8")
PY

CURRENT_STEP="generated-edit-denial"
GENERATED_JSONL="$SCRATCH_ROOT/artifacts/30-generated-edit.jsonl"
GENERATED_STDERR="$SCRATCH_ROOT/artifacts/30-generated-edit.stderr"
GENERATED_DETAIL="$SCRATCH_ROOT/artifacts/30-generated-edit.json"
run_copilot \
  "$GUIDE_SESSION_ID" \
  "Use the file editing tool exactly once. Try to replace the exact old string return 1 with return 2 in $GENERATED_PATH. Do not touch any other file. After the tool result, reply GENERATED_EDIT_ATTEMPT_DONE only." \
  "edit" \
  "$GENERATED_JSONL" \
  "$GENERATED_STDERR"
assert_denied_edit "$GENERATED_JSONL" "$GENERATED_PATH" 'generated-file-gate:' "$GENERATED_DETAIL"
if ! cmp -s "$GENERATED_BASELINE" "$GENERATED_PATH"; then
  echo "run-copilot-hook-smoke: generated file changed despite denial" >&2
  exit 1
fi

CURRENT_STEP="ordinary-edit-allow"
ORDINARY_JSONL="$SCRATCH_ROOT/artifacts/40-ordinary-edit.jsonl"
ORDINARY_STDERR="$SCRATCH_ROOT/artifacts/40-ordinary-edit.stderr"
ORDINARY_DETAIL="$SCRATCH_ROOT/artifacts/40-ordinary-edit.json"
run_copilot \
  "$GUIDE_SESSION_ID" \
  "Use the file editing tool exactly once. Replace the exact old string before with after in $ORDINARY_PATH. Do not touch any other file. After the tool result, reply ORDINARY_EDIT_DONE only." \
  "edit" \
  "$ORDINARY_JSONL" \
  "$ORDINARY_STDERR"
assert_successful_edit "$ORDINARY_JSONL" "$ORDINARY_PATH" "$ORDINARY_DETAIL"
python3 - "$SMOKE_HOOK_INPUT_DIR" "$EDIT_HOOK_INPUT_DETAIL" "$ORDINARY_PATH" <<'PY'
import json
import sys
from pathlib import Path

evidence_dir, detail_path, expected_path = sys.argv[1:4]
matches = []
for candidate in sorted(Path(evidence_dir).glob("contributing-*.json")):
    payload = json.loads(candidate.read_text(encoding="utf-8"))
    tool_input = payload.get("tool_input")
    if not isinstance(tool_input, dict):
        continue
    if payload.get("hook_event_name") != "PreToolUse":
        continue
    if payload.get("tool_name") != "Edit":
        continue
    if tool_input.get("path") != expected_path:
        continue
    matches.append(
        {
            "evidence_file": str(candidate),
            "hook_event_name": payload["hook_event_name"],
            "tool_name": payload["tool_name"],
            "tool_input": tool_input,
            "session_id": payload.get("session_id"),
        }
    )

if not matches:
    raise SystemExit(
        f"did not observe direct contributing hook payload with PreToolUse and tool_input.path={expected_path!r}"
    )

Path(detail_path).write_text(json.dumps(matches[0], indent=2) + "\n", encoding="utf-8")
PY
python3 - "$ORDINARY_PATH" <<'PY'
from pathlib import Path
import sys

content = Path(sys.argv[1]).read_text(encoding="utf-8")
if content != "after\n":
    raise SystemExit(f"unexpected ordinary file content: {content!r}")
PY

CURRENT_STEP="write-summary"
SUMMARY_PATH="$SCRATCH_ROOT/artifacts/summary.json"
python3 - "$SUMMARY_PATH" \
  "$VERSION_LINE" \
  "$BASE_HEAD" \
  "$PROBE_DETAIL" \
  "$CONFIG_DETAIL" \
  "$MANIFEST_DETAIL" \
  "$COMMIT_DETAIL" \
  "$READ_DETAIL" \
  "$STATE_DETAIL" \
  "$READ_HOOK_INPUT_DETAIL" \
  "$GENERATED_DETAIL" \
  "$ORDINARY_DETAIL" \
  "$EDIT_HOOK_INPUT_DETAIL" <<'PY'
import json
import sys
from pathlib import Path

(
    summary_path,
    version_output,
    base_head,
    probe_detail,
    config_detail,
    manifest_detail,
    commit_detail,
    read_detail,
    state_detail,
    read_hook_input_detail,
    generated_detail,
    ordinary_detail,
    edit_hook_input_detail,
) = sys.argv[1:14]

def load(path):
    return json.loads(Path(path).read_text(encoding="utf-8"))

summary = {
    "copilot_version": version_output.strip(),
    "base_head_before_smoke": base_head,
    "probe": load(probe_detail),
    "installed_hook_config": load(config_detail),
    "installed_manifest": load(manifest_detail),
    "raw_commit_denial": load(commit_detail),
    "guide_read": load(read_detail),
    "guide_state": load(state_detail),
    "guide_read_hook_input": load(read_hook_input_detail),
    "generated_edit_denial": load(generated_detail),
    "ordinary_edit_allow": load(ordinary_detail),
    "ordinary_edit_hook_input": load(edit_hook_input_detail),
}

Path(summary_path).write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
PY

echo "copilot-hook-smoke: PASS ($VERSION_LINE; installed manifest 0.6.5 validated; plugin-installed hooks/copilot-hooks.json preserved verbatim with PLUGIN_ROOT-based runner commands; raw git commit denied; direct Read hook payload observed; generated edit denied; ordinary edit allowed with direct Edit hook payload observed)"
