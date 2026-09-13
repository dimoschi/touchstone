import io
import json
from pathlib import Path
from types import SimpleNamespace

from conftest import load_script

runner = load_script(Path(__file__).resolve().parent / "copilot-hook-runner.py")


def _payload(event="PreToolUse", **overrides):
    payload = {
        "hook_event_name": event,
        "session_id": "s1",
        "cwd": "/tmp",
        "tool_name": "Bash",
        "tool_input": {"command": "echo hi"},
    }
    payload.update(overrides)
    return payload


def _run(monkeypatch, key, payload_bytes, record_ok=True):
    monkeypatch.setattr("sys.argv", ["copilot-hook-runner.py", key])
    monkeypatch.setattr("sys.stdin", SimpleNamespace(buffer=io.BytesIO(payload_bytes)))
    if record_ok:
        monkeypatch.setattr(runner, "record_hook_input", lambda *a, **k: None)
    return runner.main()


def test_child_payload_is_stamped_copilot_but_evidence_keeps_the_original(monkeypatch):
    """The runner is the only place that knows the host, so it must say so.

    Nothing in a payload's shape distinguishes Copilot from Claude, so the
    gates default to claude. Every Copilot entry comes through here, which
    makes this the one honest place to mark it.
    """
    seen = {}
    monkeypatch.setattr(runner, "_run_child",
                        lambda name, raw: (seen.__setitem__("child", raw), (True, ""))[1])
    monkeypatch.setattr(runner, "record_hook_input",
                        lambda key, raw: seen.__setitem__("recorded", raw))
    monkeypatch.setattr("sys.argv", ["copilot-hook-runner.py", "gate-pipe"])
    original = json.dumps(_payload()).encode()
    monkeypatch.setattr("sys.stdin", SimpleNamespace(buffer=io.BytesIO(original)))

    runner.main()

    assert json.loads(seen["child"])["host"] == "copilot"
    # evidence is what Copilot actually sent, not what we handed the gate
    assert seen["recorded"] == original


def test_unknown_key_is_a_denied_pre_tool_use(monkeypatch, capsys):
    monkeypatch.setattr("sys.argv", ["copilot-hook-runner.py", "not-a-real-key"])
    monkeypatch.setattr("sys.stdin", SimpleNamespace(buffer=io.BytesIO(b"{}")))
    rc = runner.main()
    assert rc == 0
    out = json.loads(capsys.readouterr().out)
    assert out["permissionDecision"] == "deny"
    assert "unknown hook key" in out["permissionDecisionReason"]


def test_missing_key_arg_is_unknown(monkeypatch, capsys):
    monkeypatch.setattr("sys.argv", ["copilot-hook-runner.py"])
    monkeypatch.setattr("sys.stdin", SimpleNamespace(buffer=io.BytesIO(b"{}")))
    rc = runner.main()
    assert rc == 0
    assert json.loads(capsys.readouterr().out)["permissionDecision"] == "deny"


def test_record_failure_is_reported(monkeypatch, capsys):
    monkeypatch.setattr("sys.argv", ["copilot-hook-runner.py", "gate-pipe"])
    monkeypatch.setattr("sys.stdin", SimpleNamespace(buffer=io.BytesIO(json.dumps(_payload()).encode())))

    def boom(*a, **k):
        raise OSError("disk full")

    monkeypatch.setattr(runner, "record_hook_input", boom)
    rc = runner.main()
    assert rc == 0
    out = json.loads(capsys.readouterr().out)
    assert "could not record hook stdin" in out["permissionDecisionReason"]


def test_invalid_json_payload_is_denied(monkeypatch, capsys):
    rc = _run(monkeypatch, "gate-pipe", b"not json")
    assert rc == 0
    out = json.loads(capsys.readouterr().out)
    assert out["permissionDecision"] == "deny"
    assert "invalid JSON" in out["permissionDecisionReason"]


def test_malformed_payload_is_denied(monkeypatch, capsys):
    rc = _run(monkeypatch, "gate-pipe", json.dumps({"nope": True}).encode())
    assert rc == 0
    out = json.loads(capsys.readouterr().out)
    assert out["permissionDecision"] == "deny"
    assert "malformed hook payload" in out["permissionDecisionReason"]


def test_successful_pre_tool_use_child_emits_allow(monkeypatch, capsys):
    monkeypatch.setattr(runner, "_run_child", lambda name, raw: (True, ""))
    rc = _run(monkeypatch, "gate-pipe", json.dumps(_payload()).encode())
    assert rc == 0
    assert json.loads(capsys.readouterr().out) == {"permissionDecision": "allow"}


def test_successful_post_tool_use_child_emits_empty_object(monkeypatch, capsys):
    monkeypatch.setattr(runner, "_run_child", lambda name, raw: (True, ""))
    payload = _payload(event="PostToolUse")
    rc = _run(monkeypatch, "guide-read", json.dumps(payload).encode())
    assert rc == 0
    assert json.loads(capsys.readouterr().out) == {}


def test_failing_pre_tool_use_child_emits_deny_with_detail(monkeypatch, capsys):
    monkeypatch.setattr(runner, "_run_child", lambda name, raw: (False, "some reason"))
    rc = _run(monkeypatch, "gate-pipe", json.dumps(_payload()).encode())
    assert rc == 0
    out = json.loads(capsys.readouterr().out)
    assert out == {"permissionDecision": "deny", "permissionDecisionReason": "some reason"}


def test_failing_post_tool_use_child_emits_additional_context(monkeypatch, capsys):
    monkeypatch.setattr(runner, "_run_child", lambda name, raw: (False, "some reason"))
    payload = _payload(event="PostToolUse")
    rc = _run(monkeypatch, "guide-read", json.dumps(payload).encode())
    assert rc == 0
    assert json.loads(capsys.readouterr().out) == {"additionalContext": "some reason"}


def test_run_child_reports_start_failure(monkeypatch, tmp_path):
    def boom(*a, **k):
        raise OSError("no interpreter")

    monkeypatch.setattr(runner.subprocess, "run", boom)
    ok, detail = runner._run_child("crap-commit-gate.py", b"{}")
    assert ok is False
    assert "could not start" in detail


def test_run_child_success(monkeypatch):
    monkeypatch.setattr(
        runner.subprocess, "run",
        lambda *a, **k: SimpleNamespace(returncode=0, stderr=b""),
    )
    ok, detail = runner._run_child("crap-commit-gate.py", b"{}")
    assert ok is True
    assert detail == ""


def test_run_child_failure_with_stderr(monkeypatch):
    monkeypatch.setattr(
        runner.subprocess, "run",
        lambda *a, **k: SimpleNamespace(returncode=2, stderr=b"boom detail"),
    )
    ok, detail = runner._run_child("crap-commit-gate.py", b"{}")
    assert ok is False
    assert "boom detail" in detail


def test_run_child_failure_without_stderr_reports_exit_code(monkeypatch):
    monkeypatch.setattr(
        runner.subprocess, "run",
        lambda *a, **k: SimpleNamespace(returncode=7, stderr=b"   "),
    )
    ok, detail = runner._run_child("crap-commit-gate.py", b"{}")
    assert ok is False
    assert "exited 7 with no stderr" in detail


def test_bounded_detail_truncates_lines_and_characters():
    many_lines = "\n".join(f"line {i}" for i in range(20))
    bounded = runner._bounded_detail(many_lines)
    assert bounded.count("\n") == runner.MAX_DETAIL_LINES - 1

    long_line = "x" * (runner.MAX_DETAIL_CHARS + 50)
    bounded = runner._bounded_detail(long_line)
    assert len(bounded) <= runner.MAX_DETAIL_CHARS
    assert bounded.endswith("…")


def test_bounded_detail_empty_input_has_a_default_message():
    assert runner._bounded_detail("   \n  \n") == "hook failed without a diagnostic"


def test_event_name_defaults_to_pre_tool_use_for_non_dict_payload():
    assert runner._event_name([1, 2, 3]) == "pre_tool_use"


def test_load_payload_invalid_json_returns_none_and_pre_tool_use():
    payload, event = runner._load_payload(b"not json")
    assert payload is None
    assert event == "pre_tool_use"
