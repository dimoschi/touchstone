#!/usr/bin/env bash
# Tests the smoke-only Copilot hook stdin logger/pass-through wrapper.

set -euo pipefail

HOOKS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGGER="$HOOKS/copilot-hook-smoke-logger.py"
WORK="$(mktemp -d "$HOOKS/.test-copilot-hook-smoke-logger.XXXXXX")"
EVIDENCE="$WORK/evidence"
CHILD="$WORK/child.py"
STDOUT_FILE="$WORK/stdout"
STDERR_FILE="$WORK/stderr"
PAYLOAD_FILE="$WORK/payload.json"

cleanup() {
  local rc=$?
  rm -rf "$WORK"
  exit "$rc"
}
trap cleanup EXIT

python3 - "$CHILD" <<'PY'
from pathlib import Path
import sys

Path(sys.argv[1]).write_text(
    """#!/usr/bin/env python3
from __future__ import annotations

import sys

raw = sys.stdin.buffer.read()
assert sys.argv[1] == "guide-read", sys.argv
sys.stdout.write("child-stdout\\n")
sys.stderr.write(f"child-stderr:{raw.decode('utf-8')}\\n")
raise SystemExit(7)
""",
    encoding="utf-8",
)
PY
chmod 700 "$CHILD"

python3 - "$PAYLOAD_FILE" <<'PY'
from pathlib import Path
import sys

Path(sys.argv[1]).write_text(
    '{"hook_event_name":"PostToolUse","tool_name":"Read","tool_input":{"path":"docs/guide.md"},"note":"preserve spacing"}\n',
    encoding="utf-8",
)
PY

echo "wrapper records the exact stdin bytes and relays child output/exit"
set +e
TOUCHSTONE_HOOK_INPUT_EVIDENCE_DIR="$EVIDENCE" \
  python3 "$LOGGER" "$CHILD" guide-read <"$PAYLOAD_FILE" >"$STDOUT_FILE" 2>"$STDERR_FILE"
RC=$?
set -e
[ "$RC" -eq 7 ] || { echo "expected exit 7, got $RC"; exit 1; }
grep -Fxq 'child-stdout' "$STDOUT_FILE"
grep -Fqx "child-stderr:$(cat "$PAYLOAD_FILE")" "$STDERR_FILE"

python3 - "$EVIDENCE" "$PAYLOAD_FILE" <<'PY'
from pathlib import Path
import sys

evidence_dir = Path(sys.argv[1])
payload_path = Path(sys.argv[2])
evidence_files = sorted(evidence_dir.glob("guide-read-*.json"))
assert len(evidence_files) == 1, evidence_files
assert evidence_files[0].read_bytes() == payload_path.read_bytes()
print("  ok: evidence bytes")
PY

echo "COPILOT HOOK SMOKE LOGGER OK"
