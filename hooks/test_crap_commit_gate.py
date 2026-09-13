import io
import json
import subprocess
from pathlib import Path

from conftest import load_script

gate = load_script(Path(__file__).resolve().parent / "crap-commit-gate.py")


def _git(*args, cwd):
    subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True)


def _repo(tmp_path, *, gated=True):
    _git("init", "-q", "-b", "main", str(tmp_path), cwd=tmp_path.parent)
    if gated:
        (tmp_path / ".crap-gated").write_text("")
    return tmp_path


def _run(monkeypatch, cmd, cwd):
    monkeypatch.setattr(
        "sys.stdin", io.StringIO(json.dumps({"tool_input": {"command": cmd}, "cwd": str(cwd)}))
    )
    return gate.main()


def test_non_commit_command_is_allowed(monkeypatch, tmp_path):
    repo = _repo(tmp_path)
    assert _run(monkeypatch, "git status", repo) == 0


def test_raw_commit_in_gated_repo_is_blocked(monkeypatch, tmp_path, capsys):
    repo = _repo(tmp_path)
    rc = _run(monkeypatch, "git commit -m x", repo)
    assert rc == 2
    assert "crap-commit-gate" in capsys.readouterr().err


def test_git_dash_c_commit_is_matched(monkeypatch, tmp_path, capsys):
    repo = _repo(tmp_path)
    rc = _run(monkeypatch, f"git -C {repo} commit -m x", repo.parent)
    assert rc == 2


def test_commit_in_ungated_repo_is_allowed(monkeypatch, tmp_path):
    repo = _repo(tmp_path, gated=False)
    assert _run(monkeypatch, "git commit -m x", repo) == 0


def test_wrapper_call_named_in_a_quoted_message_is_allowed(monkeypatch, tmp_path):
    repo = _repo(tmp_path)
    cmd = 'echo "use crap-commit.sh instead of git commit"'
    assert _run(monkeypatch, cmd, repo) == 0


def test_env_prefixed_commit_is_matched(monkeypatch, tmp_path):
    repo = _repo(tmp_path)
    rc = _run(monkeypatch, "FOO=bar git commit -m x", repo)
    assert rc == 2
