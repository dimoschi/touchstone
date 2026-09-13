import io
import json
from pathlib import Path

from conftest import load_script

gate_pipe = load_script(Path(__file__).resolve().parent / "gate-pipe-gate.py")


def test_pipes_a_gate_detects_pipe_after_gate_name():
    assert gate_pipe.pipes_a_gate("mutation-check.sh | tail -45") is True


def test_pipes_a_gate_false_when_gate_not_piped():
    assert gate_pipe.pipes_a_gate("mutation-check.sh > /tmp/out.log 2>&1") is False


def test_pipes_a_gate_false_when_pipe_unrelated_to_gate():
    assert gate_pipe.pipes_a_gate("echo hi | grep hi && mutation-check.sh") is False


def test_pipes_a_gate_checks_each_segment_independently():
    assert gate_pipe.pipes_a_gate("echo hi | grep hi; crap-check.sh | cat") is True


def _run(monkeypatch, cmd):
    monkeypatch.setattr("sys.stdin", io.StringIO(json.dumps({"tool_input": {"command": cmd}})))
    return gate_pipe.main()


def test_main_allows_non_piped_command(monkeypatch):
    assert _run(monkeypatch, "crap-check.sh") == 0


def test_main_blocks_piped_gate(monkeypatch, capsys):
    assert _run(monkeypatch, "crap-check.sh | tail") == 2
    assert "gate-pipe-gate" in capsys.readouterr().err


def test_main_ignores_quoted_pipe_in_commit_message(monkeypatch):
    cmd = 'git commit -m "crap-check.sh | tail is bad, do not do it"'
    assert _run(monkeypatch, cmd) == 0
