#!/usr/bin/env python3
"""Run allowlisted Touchstone hooks under Copilot's JSON hook contract."""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))
from hook_invocation import normalize_invocation

HOOKS = {
    "crap-commit": "crap-commit-gate.py",
    "mutation-pr": "mutation-pr-gate.py",
    "base-branch": "base-branch-commit-gate.py",
    "gate-pipe": "gate-pipe-gate.py",
    "contributing": "contributing-gate.py",
    "generated-file": "generated-file-gate.py",
    "guide-read": "copilot_session_evidence.py",
}
MAX_DETAIL_LINES = 12
MAX_DETAIL_CHARS = 1200


def main() -> int:
    raw = sys.stdin.buffer.read()
    payload, event = _load_payload(raw)
    key = _resolve_key()
    if key is None:
        return _emit_failure(event, _unknown_key_message())
    if payload is None:
        return _emit_failure(event, "invalid JSON hook payload")

    invocation = normalize_invocation(payload)
    if invocation is None:
        return _emit_failure(event, "malformed hook payload")

    ok, detail = _run_child(HOOKS[key], raw)
    if ok:
        return _emit_success(invocation.event)
    return _emit_failure(invocation.event, detail)


def _load_payload(raw: bytes) -> tuple[Any | None, str]:
    try:
        payload = json.loads(raw)
    except (json.JSONDecodeError, UnicodeDecodeError):
        return None, "pre_tool_use"
    return payload, _event_name(payload)


def _event_name(payload: object) -> str:
    if isinstance(payload, dict) and payload.get("hook_event_name") == "PostToolUse":
        return "post_tool_use"
    return "pre_tool_use"


def _resolve_key() -> str | None:
    if len(sys.argv) != 2:
        return None
    key = sys.argv[1]
    return key if key in HOOKS else None


def _unknown_key_message() -> str:
    allowed = ", ".join(sorted(HOOKS))
    return f"unknown hook key; expected exactly one of: {allowed}"


def _run_child(name: str, raw: bytes) -> tuple[bool, str]:
    target = Path(__file__).resolve().with_name(name)
    try:
        result = subprocess.run(
            [sys.executable, str(target)],
            input=raw,
            capture_output=True,
            check=False,
        )
    except OSError as exc:
        return False, _bounded_detail(f"{target.name} could not start: {exc}")

    if result.returncode == 0:
        return True, ""

    stderr = result.stderr.decode("utf-8", errors="replace")
    if stderr.strip():
        detail = stderr
    else:
        detail = f"{target.name} exited {result.returncode} with no stderr"
    return False, _bounded_detail(f"{target.name} exited {result.returncode}: {detail}")


def _bounded_detail(detail: str) -> str:
    lines = [line.rstrip() for line in detail.strip().splitlines() if line.strip()]
    if not lines:
        return "hook failed without a diagnostic"
    text = "\n".join(lines[:MAX_DETAIL_LINES])
    if len(text) > MAX_DETAIL_CHARS:
        text = text[: MAX_DETAIL_CHARS - 1].rstrip() + "…"
    return text


def _emit_success(event: str) -> int:
    if event == "post_tool_use":
        _emit({})
    else:
        _emit({"permissionDecision": "allow"})
    return 0


def _emit_failure(event: str, detail: str) -> int:
    if event == "post_tool_use":
        _emit({"additionalContext": detail})
    else:
        _emit(
            {
                "permissionDecision": "deny",
                "permissionDecisionReason": detail,
            }
        )
    return 0


def _emit(data: dict[str, object]) -> None:
    json.dump(data, sys.stdout, separators=(",", ":"))
    sys.stdout.write("\n")


if __name__ == "__main__":
    raise SystemExit(main())
