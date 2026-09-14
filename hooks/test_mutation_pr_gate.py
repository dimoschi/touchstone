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


def test_trigger_gh_pr_ready(tmp_path):
    repo = _repo(tmp_path)
    hit_repo, branch = gate.trigger("gh pr ready 7", repo)
    assert hit_repo == repo.resolve()
    assert branch is None


def test_trigger_gh_pr_create_non_draft(tmp_path):
    repo = _repo(tmp_path)
    hit_repo, branch = gate.trigger("gh pr create --title x", repo)
    assert hit_repo == repo.resolve()
    assert branch is None


def test_trigger_gh_pr_create_draft_is_exempt(tmp_path):
    repo = _repo(tmp_path)
    assert gate.trigger("gh pr create --title x --draft", repo) is None


def test_trigger_gh_pr_ready_respects_dash_c(tmp_path):
    # `gh` itself has no `-C` flag, so a worktree agent that never `cd`s can
    # only name the repo by chaining a `git -C <path>` invocation into the
    # same command line (e.g. the push right before `gh pr ready`). The
    # cwd-fallback in trigger() must not shadow that.
    other = _repo(tmp_path / "other")
    cwd = _repo(tmp_path / "cwd")
    hit = gate.trigger(f"git -C {other} push && gh pr ready 7", cwd)
    assert hit == (other.resolve(), None)


def test_trigger_gh_pr_create_respects_dash_c(tmp_path):
    other = _repo(tmp_path / "other")
    cwd = _repo(tmp_path / "cwd")
    hit = gate.trigger(
        f"git -C {other} push -u origin feature && gh pr create --title x", cwd)
    assert hit == (other.resolve(), None)


def test_trigger_gh_pr_ready_ignores_dash_c_after_the_gh_call(tmp_path):
    # A `git -C` that appears after `gh pr ready` never ran before it, so it
    # cannot have redirected where `gh` itself acted; picking it up anyway let
    # an unrelated repo silently stand in for the one actually gated.
    other = _repo(tmp_path / "other")
    cwd = _repo(tmp_path / "cwd")
    hit = gate.trigger(f"gh pr ready 7 && git -C {other} status", cwd)
    assert hit == (cwd.resolve(), None)


def test_trigger_gh_pr_create_ignores_dash_c_inside_quoted_body(tmp_path):
    # A `--body` argument is consumed by the `gh pr create` call itself, so a
    # `git -C` inside its quoted text is message content, not a redirect.
    other = _repo(tmp_path / "other")
    cwd = _repo(tmp_path / "cwd")
    hit = gate.trigger(
        f'gh pr create --title x --body "see git -C {other} for notes"', cwd)
    assert hit == (cwd.resolve(), None)


def test_trigger_gh_pr_ready_unprovable_dash_c_falls_back_to_cwd(tmp_path):
    # Returning None here fixed a FileNotFoundError crash and opened a worse
    # hole: any `git -C <not-a-repo>` earlier on the line switched the gate
    # off. `gh` has no -C, so such a path never redirected it.
    cwd = _repo(tmp_path / "cwd")
    missing = tmp_path / "does-not-exist"
    hit = gate.trigger(f"git -C {missing} push && gh pr ready 7", cwd)
    assert hit == (cwd.resolve(), None)


def test_trigger_gh_pr_ready_existing_non_repo_dash_c_falls_back_to_cwd(tmp_path):
    # The mundane version: an ordinary directory that simply is not a repo.
    cwd = _repo(tmp_path / "cwd")
    plain = tmp_path / "plain"
    plain.mkdir()
    hit = gate.trigger(f"git -C {plain} log -1 && gh pr ready 7", cwd)
    assert hit == (cwd.resolve(), None)


def test_trigger_gh_pr_ready_outside_any_repo_is_none(tmp_path):
    # The fallback is to the cwd, not past it: with no repo to gate there is
    # nothing to verify, and that is the one case None is right for.
    plain = tmp_path / "plain"
    plain.mkdir()
    assert gate.trigger("gh pr ready 7", plain) is None


def test_trigger_gh_pr_create_outside_any_repo_is_none(tmp_path):
    # The create branch repeats the expression, so it needs its own case.
    plain = tmp_path / "plain"
    plain.mkdir()
    assert gate.trigger("gh pr create --title x", plain) is None


def test_gh_route_repo_probes_the_slice_then_the_cwd_with_exact_args(
        monkeypatch, tmp_path):
    # Both probes must be asserted as a pair. A membership check passes while
    # either one alone has its flag dropped or case-swapped, because the other
    # still records the right args.
    cwd = _repo(tmp_path / "cwd")
    missing = tmp_path / "does-not-exist"
    calls = []
    real_git = gate.git

    def spy(r, *args):
        calls.append((str(r), args))
        return real_git(r, *args)

    monkeypatch.setattr(gate, "git", spy)
    cmd = f"git -C {missing} push && gh pr ready 7"
    m = gate.GH_PR_READY.search(cmd)
    assert gate.gh_route_repo(cmd, m, cwd) == cwd.resolve()
    assert calls == [
        (str(missing.resolve()), ("rev-parse", "--show-toplevel")),
        (str(cwd.resolve()), ("rev-parse", "--show-toplevel")),
    ]


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


def test_main_gh_pr_ready_unprovable_dash_c_still_gates_the_cwd(monkeypatch, tmp_path):
    # End to end for the fallback: no crash, and the cwd's red ledger still
    # blocks. Asserting rc 0 here only passed while the route was abandoned.
    cwd = _repo(tmp_path / "cwd")
    missing = tmp_path / "does-not-exist"
    cmd = f"git -C {missing} push && gh pr ready 7"
    monkeypatch.setattr("sys.stdin", io.StringIO(_payload(cmd, cwd)))
    _stub_mutation_check(monkeypatch, 1, stdout="row1\n")
    assert gate.main() == 2


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


def test_main_could_not_measure_blocks_with_gate_failing_message(monkeypatch, tmp_path, capsys):
    # returncode 4 (could not measure) gets the same "gate failing" wording as
    # 2 (setup problem): neither one read the ledger, so both are the gate
    # itself failing, not a red verdict.
    repo = _repo(tmp_path)
    monkeypatch.setattr("sys.stdin", io.StringIO(_payload("gh pr ready", repo)))
    _stub_mutation_check(monkeypatch, 4, stderr="could not measure")
    rc = gate.main()
    assert rc == 2
    err = capsys.readouterr().err
    assert "gate failing, not a red ledger" in err
    assert "could not measure" in err


def test_gh_route_repo_probes_with_show_toplevel(monkeypatch, tmp_path):
    repo = _repo(tmp_path)
    calls = []
    real_git = gate.git

    def spy(r, *args):
        calls.append(args)
        return real_git(r, *args)

    monkeypatch.setattr(gate, "git", spy)
    m = gate.GH_PR_READY.search("gh pr ready 7")
    assert gate.gh_route_repo("gh pr ready 7", m, repo) == repo.resolve()
    assert ("rev-parse", "--show-toplevel") in calls


def test_trigger_gh_pr_create_unprovable_dash_c_falls_back_to_cwd(tmp_path):
    # The `gh pr create` branch builds its (repo, None) tuple from a separate
    # occurrence of the same expression, so it needs its own case.
    cwd = _repo(tmp_path / "cwd")
    missing = tmp_path / "does-not-exist"
    hit = gate.trigger(f"git -C {missing} push && gh pr create --title x", cwd)
    assert hit == (cwd.resolve(), None)


def test_merge_hit_uses_exact_probe_and_verify_args(monkeypatch, tmp_path):
    repo = _repo(tmp_path)
    _git("checkout", "-q", "-b", "feature", cwd=repo)
    _git("checkout", "-q", "main", cwd=repo)

    git_calls = []
    real_git = gate.git

    def spy_git(r, *args):
        git_calls.append(args)
        return real_git(r, *args)

    base_calls = []
    real_base = gate.base_branch_names

    def spy_base(r):
        base_calls.append(r)
        return real_base(r)

    monkeypatch.setattr(gate, "git", spy_git)
    monkeypatch.setattr(gate, "base_branch_names", spy_base)

    m = gate.GIT_MERGE.search("git merge feature")
    assert gate.merge_hit(repo, m) == (repo, "feature")
    assert base_calls == [repo]
    assert ("rev-parse", "--abbrev-ref", "HEAD") in git_calls
    assert ("rev-parse", "--verify", "--quiet", "feature^{commit}") in git_calls


def test_push_hit_uses_exact_probe_and_verify_args(monkeypatch, tmp_path):
    repo = _repo(tmp_path)

    git_calls = []
    real_git = gate.git

    def spy_git(r, *args):
        git_calls.append(args)
        return real_git(r, *args)

    base_calls = []
    real_base = gate.base_branch_names

    def spy_base(r):
        base_calls.append(r)
        return real_base(r)

    monkeypatch.setattr(gate, "git", spy_git)
    monkeypatch.setattr(gate, "base_branch_names", spy_base)

    m = gate.GIT_PUSH.search("git push")
    assert gate.push_hit(repo, m) == (repo, "main")
    assert base_calls == [repo]
    assert ("rev-parse", "--verify", "--quiet", "main^{commit}") in git_calls


def test_push_hit_and_short_circuits_without_verify_probe(monkeypatch, tmp_path):
    # `target and git(...)`: when push_target finds no base-branch target, the
    # verify probe must never run at all, not merely fail.
    repo = _repo(tmp_path, branch="feature")

    git_calls = []
    real_git = gate.git

    def spy_git(r, *args):
        git_calls.append(args)
        return real_git(r, *args)

    monkeypatch.setattr(gate, "git", spy_git)

    m = gate.GIT_PUSH.search("git push")
    assert gate.push_hit(repo, m) is None
    assert not any(a[0] == "rev-parse" and "--verify" in a for a in git_calls)


def test_push_hit_head_refspec_returns_none_branch(tmp_path):
    repo = _repo(tmp_path)
    m = gate.GIT_PUSH.search("git push origin HEAD:main")
    assert gate.push_hit(repo, m) == (repo, None)


def test_main_missing_command_falls_back_to_empty_string(monkeypatch, tmp_path):
    repo = _repo(tmp_path)
    calls = []
    real_trigger = gate.trigger

    def spy_trigger(cmd, cwd):
        calls.append(cmd)
        return real_trigger(cmd, cwd)

    monkeypatch.setattr(gate, "trigger", spy_trigger)
    monkeypatch.setattr(
        "sys.stdin", io.StringIO(json.dumps({"tool_input": {}, "cwd": str(repo)}))
    )
    assert gate.main() == 0
    assert calls == [""]


def test_main_checks_exact_marker_name(monkeypatch, tmp_path):
    repo = _repo(tmp_path)
    calls = []
    real_is_gated = gate.is_gated

    def spy(path, marker):
        calls.append(marker)
        return real_is_gated(path, marker)

    monkeypatch.setattr(gate, "is_gated", spy)
    monkeypatch.setattr("sys.stdin", io.StringIO(_payload("gh pr ready", repo)))
    _stub_mutation_check(monkeypatch, 0)
    assert gate.main() == 0
    assert calls == [".mutation-gated"]


def test_main_calls_mutation_check_with_exact_subprocess_args(monkeypatch, tmp_path):
    repo = _repo(tmp_path)
    monkeypatch.setattr("sys.stdin", io.StringIO(_payload("gh pr ready", repo)))
    seen = {}
    real_run = subprocess.run

    def fake_run(args, **kwargs):
        if args and args[0] == str(gate.MUTATION_CHECK):
            seen["kwargs"] = kwargs
            return SimpleNamespace(returncode=0, stdout="", stderr="")
        return real_run(args, **kwargs)

    monkeypatch.setattr(gate.subprocess, "run", fake_run)
    assert gate.main() == 0
    assert seen["kwargs"] == {
        "cwd": repo.resolve(),
        "capture_output": True,
        "text": True,
    }


def test_main_red_ledger_tail_joins_stdout_and_stderr_correctly(monkeypatch, tmp_path, capsys):
    repo = _repo(tmp_path)
    monkeypatch.setattr("sys.stdin", io.StringIO(_payload("gh pr ready", repo)))
    _stub_mutation_check(monkeypatch, 1, stdout="line1\nline2", stderr="line3\nline4")
    rc = gate.main()
    assert rc == 2
    err = capsys.readouterr().err
    assert "line1\nline2\nline3\nline4" in err
