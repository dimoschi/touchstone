"""Normalize the hook payloads supported by Touchstone's policy gates."""

from __future__ import annotations

import dataclasses
from collections.abc import Mapping
from pathlib import Path
from typing import Literal


@dataclasses.dataclass(frozen=True)
class HookInvocation:
    host: Literal["claude", "codex", "copilot"]
    event: Literal["pre_tool_use", "post_tool_use"]
    session_id: str | None
    cwd: Path | None
    tool_name: str
    tool_input: Mapping[str, object]
    raw: Mapping[str, object]


def tool_input_path(tool_input: Mapping[str, object]) -> str | None:
    """Return the target path from either the legacy or native key."""
    for key in ("file_path", "path"):
        value = tool_input.get(key)
        if isinstance(value, str) and value:
            return value
    return None


def normalize_invocation(raw: object) -> HookInvocation | None:
    """Return the common input shape, or None for a malformed hook event."""
    if not isinstance(raw, Mapping):
        return None

    tool_input = raw.get("tool_input")
    if not isinstance(tool_input, dict):
        return None

    tool_name = raw.get("tool_name")
    if not isinstance(tool_name, str) or not tool_name:
        return None

    event_name = raw.get("hook_event_name")
    if event_name is None:
        event = "pre_tool_use"
        host = _host_from_payload(raw)
    elif event_name == "PreToolUse":
        event = "pre_tool_use"
        host = _host_from_payload(raw)
    elif event_name == "PostToolUse":
        event = "post_tool_use"
        host = _host_from_payload(raw)
    else:
        return None

    session_id = raw.get("session_id")
    if host == "copilot" and event_name in {"PreToolUse", "PostToolUse"}:
        if not isinstance(session_id, str) or not session_id:
            return None
        cwd = raw.get("cwd")
        if not isinstance(cwd, str) or not cwd:
            return None
        cwd_value = Path(cwd).resolve()
        return HookInvocation(
            host=host,
            event=event,
            session_id=session_id,
            cwd=cwd_value,
            tool_name=tool_name,
            tool_input=tool_input,
            raw=raw,
        )
    cwd = raw.get("cwd")
    if not isinstance(cwd, str) or not cwd:
        return None
    return HookInvocation(
        host=host,
        event=event,
        session_id=session_id if isinstance(session_id, str) else None,
        cwd=Path(cwd).resolve(),
        tool_name=tool_name,
        tool_input=tool_input,
        raw=raw,
    )


def _host_from_payload(raw: Mapping[str, object]) -> str:
    """The host that sent this payload, defaulting to claude.

    Shape must never decide this. Claude Code and Copilot both send
    `hook_event_name`, `session_id`, `cwd` and `tool_input` and neither
    marks itself, so an earlier rule that read any event-shaped payload as
    copilot classified every real Claude edit that way. contributing-gate
    then routed them to gate_copilot, which clears only via the
    session-evidence state written by a PostToolUse hook that exists in
    copilot-hooks.json and not in hooks.json, so a gated repo refused every
    edit except the guide itself. copilot-hook-runner.py stamps the host
    explicitly, which is sound because it is the one place that knows.
    """
    return _explicit_host(raw) or "claude"


def _explicit_host(raw: Mapping[str, object]) -> str | None:
    for key in ("host", "source"):
        value = raw.get(key)
        if value in {"claude", "codex", "copilot"}:
            return value
    return None
