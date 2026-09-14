import io
import json
import subprocess
from pathlib import Path
from types import SimpleNamespace

from conftest import load_script

gate = load_script(Path(__file__).resolve().parent / "mutation-pr-gate.py")


def _git(*args, cwd):
    subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True)


def _repo(tmp_path, *, branch="main", gated=True):
    _git("init", "-q", "-b", branch, str(tmp_path), cwd=tmp_path.parent)
    (tmp_path / "f.txt").write_text("x")
    _git("add", ".", cwd=tmp_path)
    _git(
        "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false",
        "commit", "-q", "-m", "init", cwd=tmp_path,
    )
    if gated:
        # The gate only checks the marker's existence on disk, so it need not
        # be tracked; leaving it untracked also sidesteps a global gitignore
        # some machines carry for `.mutation-gated`.
        (tmp_path / ".mutation-gated").write_text("")
    return tmp_path


def test_push_target_explicit_refspec_matches_base_branch():
    assert gate.push_target("origin main:main", "repo", {"main"}) == "main"


def test_push_target_explicit_refspec_no_match_returns_none():
    assert gate.push_target("origin feature:feature", "repo", {"main"}) is None


def test_push_target_no_refspec_uses_current_head(tmp_path):
    repo = _repo(tmp_path)
    assert gate.push_target("origin", repo, {"main"}) == "main"


def test_push_target_no_refspec_non_base_head_returns_none(tmp_path):
    repo = _repo(tmp_path, branch="feature")
    assert gate.push_target("origin", repo, {"main"}) is None


def test_push_target_force_refspec_strips_plus():
    assert gate.push_target("origin +feature:main", "repo", {"main"}) == "feature"


def test_trigger_gh_pr_ready():
    repo, branch = gate.trigger("gh pr ready 7", Path("/cwd"))
    assert repo == Path("/cwd")
    assert branch is None


def test_trigger_gh_pr_create_non_draft():
    repo, branch = gate.trigger("gh pr create --title x", Path("/cwd"))
    assert repo == Path("/cwd")
    assert branch is None


def test_trigger_gh_pr_create_draft_is_exempt():
    assert gate.trigger("gh pr create --title x --draft", Path("/cwd")) is None


def test_trigger_git_merge_on_base_branch(tmp_path):
    repo = _repo(tmp_path)
    _git("checkout", "-q", "-b", "feature", cwd=repo)
    _git("checkout", "-q", "main", cwd=repo)
    hit = gate.trigger("git merge feature", repo)
    assert hit == (repo.resolve(), "feature")


def test_trigger_git_merge_on_non_base_branch_is_none(tmp_path):
    repo = _repo(tmp_path)
    _git("checkout", "-q", "-b", "feature", cwd=repo)
    assert gate.trigger("git merge main", repo) is None


def test_trigger_git_merge_unknown_branch_is_none(tmp_path):
    repo = _repo(tmp_path)
    assert gate.trigger("git merge nonexistent-branch", repo) is None


def test_trigger_git_push_to_base_branch(tmp_path):
    repo = _repo(tmp_path)
    hit = gate.trigger("git push", repo)
    assert hit == (repo.resolve(), "main")


def test_trigger_git_push_non_base_head_is_none(tmp_path):
    repo = _repo(tmp_path, branch="feature")
    assert gate.trigger("git push", repo) is None


def test_trigger_non_matching_command_is_none(tmp_path):
    repo = _repo(tmp_path)
    assert gate.trigger("git status", repo) is None


def _payload(cmd, cwd):
    return json.dumps({"tool_input": {"command": cmd}, "cwd": str(cwd)})


def test_main_non_json_stdin_is_a_no_op(monkeypatch):
    monkeypatch.setattr("sys.stdin", io.StringIO("not json"))
    assert gate.main() == 0


def test_main_no_trigger_is_allowed(monkeypatch, tmp_path):
    repo = _repo(tmp_path)
    monkeypatch.setattr("sys.stdin", io.StringIO(_payload("git status", repo)))
    assert gate.main() == 0


def test_main_ungated_repo_is_allowed(monkeypatch, tmp_path):
    repo = _repo(tmp_path, gated=False)
    monkeypatch.setattr("sys.stdin", io.StringIO(_payload("gh pr ready", repo)))
    assert gate.main() == 0


def _stub_mutation_check(monkeypatch, returncode, stdout="", stderr=""):
    """Fake only the mutation-check.sh call; base_branch's own git() calls go
    through the real subprocess.run, since both modules share one `subprocess`
    module object and a blanket patch would break git() too."""
    real_run = subprocess.run

    def fake_run(args, *a, **k):
        if args and args[0] == str(gate.MUTATION_CHECK):
            return SimpleNamespace(returncode=returncode, stdout=stdout, stderr=stderr)
        return real_run(args, *a, **k)

    monkeypatch.setattr(gate.subprocess, "run", fake_run)


def test_main_green_ledger_is_allowed(monkeypatch, tmp_path):
    repo = _repo(tmp_path)
    monkeypatch.setattr("sys.stdin", io.StringIO(_payload("gh pr ready", repo)))
    _stub_mutation_check(monkeypatch, 0)
    assert gate.main() == 0


def test_main_red_ledger_blocks_with_remediation(monkeypatch, tmp_path, capsys):
    repo = _repo(tmp_path)
    monkeypatch.setattr("sys.stdin", io.StringIO(_payload("gh pr ready", repo)))
    _stub_mutation_check(monkeypatch, 1, stdout="row1\n")
    rc = gate.main()
    assert rc == 2
    err = capsys.readouterr().err
    assert "not green for this change" in err
    assert "row1" in err


def test_main_passes_explicit_branch_arg_for_a_merge(monkeypatch, tmp_path):
    repo = _repo(tmp_path)
    _git("checkout", "-q", "-b", "feature", cwd=repo)
    _git("checkout", "-q", "main", cwd=repo)
    monkeypatch.setattr("sys.stdin", io.StringIO(_payload("git merge feature", repo)))

    seen_args = []
    real_run = subprocess.run

    def fake_run(args, *a, **k):
        if args and args[0] == str(gate.MUTATION_CHECK):
            seen_args.append(args)
            return SimpleNamespace(returncode=0, stdout="", stderr="")
        return real_run(args, *a, **k)

    monkeypatch.setattr(gate.subprocess, "run", fake_run)
    assert gate.main() == 0
    assert seen_args == [[str(gate.MUTATION_CHECK), str(repo), "--verify", "feature"]]


def test_main_setup_failure_blocks_with_gate_failing_message(monkeypatch, tmp_path, capsys):
    repo = _repo(tmp_path)
    monkeypatch.setattr("sys.stdin", io.StringIO(_payload("gh pr ready", repo)))
    _stub_mutation_check(monkeypatch, 2, stderr="setup broke")
    rc = gate.main()
    assert rc == 2
    err = capsys.readouterr().err
    assert "gate failing, not a red ledger" in err
    assert "setup broke" in err
