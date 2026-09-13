import io
import json
import subprocess
from pathlib import Path

from conftest import load_script

gate = load_script(Path(__file__).resolve().parent / "base-branch-commit-gate.py")


def _git(*args, cwd):
    subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True)


def _repo(tmp_path, *, branch="main", remote=False):
    _git("init", "-q", "-b", branch, str(tmp_path), cwd=tmp_path.parent)
    (tmp_path / "f.txt").write_text("x")
    _git("add", ".", cwd=tmp_path)
    _git(
        "-c", "user.name=t", "-c", "user.email=t@t",
        "-c", "commit.gpgsign=false",
        "commit", "-q", "-m", "init",
        cwd=tmp_path,
    )
    if remote:
        other = tmp_path.parent / "remote.git"
        _git("init", "-q", "--bare", str(other), cwd=tmp_path.parent)
        _git("remote", "add", "origin", str(other), cwd=tmp_path)
    return tmp_path


def _payload(cmd, cwd):
    return json.dumps({"tool_input": {"command": cmd}, "cwd": str(cwd)})


def _run(monkeypatch, payload):
    monkeypatch.setattr("sys.stdin", io.StringIO(payload))
    return gate.main()


def test_non_json_stdin_is_a_no_op(monkeypatch):
    monkeypatch.setattr("sys.stdin", io.StringIO("not json"))
    assert gate.main() == 0


def test_non_commit_command_is_allowed(monkeypatch, tmp_path):
    repo = _repo(tmp_path)
    assert _run(monkeypatch, _payload("git status", repo)) == 0


def test_commit_outside_a_git_repo_is_allowed(monkeypatch, tmp_path):
    assert _run(monkeypatch, _payload("git commit -m x", tmp_path)) == 0


def test_no_remote_is_exempt(monkeypatch, tmp_path):
    repo = _repo(tmp_path, remote=False)
    assert _run(monkeypatch, _payload("git commit -m x", repo)) == 0


def test_detached_head_is_allowed(monkeypatch, tmp_path):
    repo = _repo(tmp_path, remote=True)
    _git("checkout", "-q", "--detach", cwd=repo)
    assert _run(monkeypatch, _payload("git commit -m x", repo)) == 0


def test_feature_branch_with_remote_is_allowed(monkeypatch, tmp_path):
    repo = _repo(tmp_path, remote=True)
    _git("checkout", "-q", "-b", "feature", cwd=repo)
    assert _run(monkeypatch, _payload("git commit -m x", repo)) == 0


def test_base_branch_with_remote_is_blocked(monkeypatch, tmp_path, capsys):
    repo = _repo(tmp_path, remote=True, branch="main")
    rc = _run(monkeypatch, _payload("git commit -m x", repo))
    assert rc == 2
    err = capsys.readouterr().err
    assert "base branch" in err
    assert "main" in err


def test_quoted_commit_message_does_not_trigger(monkeypatch, tmp_path):
    repo = _repo(tmp_path, remote=True)
    cmd = 'echo "please git commit later"'
    assert _run(monkeypatch, _payload(cmd, repo)) == 0
