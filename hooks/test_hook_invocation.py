from pathlib import Path

from hook_invocation import normalize_invocation, tool_input_path


def _base(**overrides):
    payload = {
        "tool_name": "Edit",
        "tool_input": {"file_path": "/tmp/x"},
        "cwd": "/tmp",
    }
    payload.update(overrides)
    return payload


def test_not_a_mapping_returns_none():
    assert normalize_invocation(None) is None
    assert normalize_invocation(["not", "a", "mapping"]) is None


def test_missing_tool_input_returns_none():
    assert normalize_invocation({"tool_name": "Edit"}) is None
    assert normalize_invocation({"tool_name": "Edit", "tool_input": "nope"}) is None


def test_missing_or_empty_tool_name_returns_none():
    assert normalize_invocation({"tool_input": {}}) is None
    assert normalize_invocation({"tool_name": "", "tool_input": {}}) is None
    assert normalize_invocation({"tool_name": 5, "tool_input": {}}) is None


def test_unknown_hook_event_name_returns_none():
    assert normalize_invocation(_base(hook_event_name="SomethingElse")) is None


def test_legacy_payload_defaults_to_claude_host():
    inv = normalize_invocation(_base())
    assert inv.host == "claude"
    assert inv.event == "pre_tool_use"
    assert inv.cwd == Path("/tmp").resolve()
    assert inv.session_id is None


def test_legacy_payload_honours_explicit_host():
    inv = normalize_invocation(_base(host="codex"))
    assert inv.host == "codex"
    inv = normalize_invocation(_base(source="copilot", cwd="/tmp", session_id="s1"))
    # explicit non-mapping-required host path: copilot without hook_event_name
    # does not go through the copilot-required branch, so session_id/cwd are
    # only required in the general sense (cwd is always required).
    assert inv.host == "copilot"
    assert inv.session_id == "s1"


def test_legacy_payload_ignores_unrecognised_host_value():
    inv = normalize_invocation(_base(host="not-a-real-host"))
    assert inv.host == "claude"


def test_legacy_payload_missing_cwd_returns_none():
    assert normalize_invocation(_base(cwd=None)) is None
    assert normalize_invocation(_base(cwd="")) is None


def test_legacy_payload_session_id_kept_only_if_str():
    inv = normalize_invocation(_base(session_id="abc"))
    assert inv.session_id == "abc"
    inv = normalize_invocation(_base(session_id=123))
    assert inv.session_id is None


def test_claude_pre_tool_use_payload_is_not_classified_as_copilot():
    """Claude Code sends hook_event_name and no host key.

    Defaulting that to copilot routed every real Claude edit into
    gate_copilot, which clears only via session-evidence state that no
    Claude-side hook writes, so a gated repo refused every edit.
    """
    inv = normalize_invocation(
        _base(
            hook_event_name="PreToolUse",
            session_id="abc123",
            transcript_path="/tmp/abc123.jsonl",
            cwd="/tmp",
        )
    )
    assert inv.host == "claude"
    assert inv.event == "pre_tool_use"


def test_explicit_copilot_pre_tool_use_requires_session_and_cwd():
    inv = normalize_invocation(
        _base(hook_event_name="PreToolUse", host="copilot", session_id="s1", cwd="/tmp")
    )
    assert inv.host == "copilot"
    assert inv.event == "pre_tool_use"
    assert inv.session_id == "s1"
    assert inv.cwd == Path("/tmp").resolve()

    assert normalize_invocation(
        _base(hook_event_name="PreToolUse", host="copilot", session_id=None, cwd="/tmp")
    ) is None
    assert normalize_invocation(
        _base(hook_event_name="PreToolUse", host="copilot", session_id="s1", cwd=None)
    ) is None
    assert normalize_invocation(
        _base(hook_event_name="PreToolUse", host="copilot", session_id="s1", cwd="")
    ) is None


def test_post_tool_use_event_maps_correctly():
    inv = normalize_invocation(
        _base(hook_event_name="PostToolUse", host="copilot", session_id="s1", cwd="/tmp")
    )
    assert inv.event == "post_tool_use"
    assert inv.host == "copilot"


def test_pre_tool_use_explicit_host_claude_uses_general_branch():
    inv = normalize_invocation(
        _base(hook_event_name="PreToolUse", host="claude", cwd="/tmp")
    )
    assert inv.host == "claude"
    assert inv.session_id is None
    # the general branch does not require session_id
    inv = normalize_invocation(
        _base(hook_event_name="PreToolUse", host="claude", cwd=None)
    )
    assert inv is None


def test_tool_input_path_prefers_file_path_then_path():
    assert tool_input_path({"file_path": "/a", "path": "/b"}) == "/a"
    assert tool_input_path({"path": "/b"}) == "/b"
    assert tool_input_path({}) is None
    assert tool_input_path({"file_path": ""}) is None
    assert tool_input_path({"file_path": 5}) is None
