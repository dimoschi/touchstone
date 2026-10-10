import json
import os
import subprocess

import pytest

import prepare_delivery as pd

GIT = ["git", "-c", "core.excludesFile=/dev/null", "-c", "commit.gpgsign=false", "-c", "user.name=t", "-c", "user.email=t@t"]


def git(repo, *args):
    done = subprocess.run([*GIT, "-C", str(repo), *args], check=True, capture_output=True, text=True)
    return done.stdout.strip()


AGENTS = """# Repo

## Checks

```bash
make test   # fast
```

text
## Advisory checks
```
make lint
```
### Notes
~~~
## not a heading
~~~
## Empty
"""


@pytest.fixture
def world(tmp_path, monkeypatch):
    """A clone of a bare origin whose main holds AGENTS.md, with gh stubbed on PATH."""
    seed = tmp_path / "seed"
    seed.mkdir()
    git(seed, "init", "-q", "-b", "main")
    (seed / "AGENTS.md").write_text(AGENTS)
    (seed / ".crap-gated").write_text("")
    (seed / ".claude-plugin").mkdir()
    (seed / ".claude-plugin" / "plugin.json").write_text(json.dumps({"name": "touchstone", "version": "9.9.9"}))
    git(seed, "add", "-A")
    git(seed, "commit", "-q", "-m", "seed")
    origin = tmp_path / "origin.git"
    subprocess.run(["git", "clone", "-q", "--bare", str(seed), str(origin)], check=True)
    repo = tmp_path / "repo"
    subprocess.run(["git", "clone", "-q", str(origin), str(repo)], check=True)
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    gh_out = tmp_path / "gh-out"
    gh_out.write_text("[]")
    gh = bin_dir / "gh"
    (tmp_path / "gh-code").write_text("0")
    gh.write_text(f"#!/bin/sh\necho \"$PWD $@\" >> {tmp_path}/gh.log\ncat {gh_out}\nexit $(cat {tmp_path}/gh-code)\n")
    gh.chmod(0o755)
    monkeypatch.setenv("PATH", f"{bin_dir}{os.pathsep}{os.environ['PATH']}")
    plugin = tmp_path / "plugin.json"
    plugin.write_text(json.dumps({"name": "touchstone", "version": "0.35.0"}))

    class World:
        pass

    w = World()
    w.tmp, w.seed, w.origin, w.gh_out, w.plugin = tmp_path, seed, origin, gh_out, plugin
    w.repo = os.path.realpath(repo)
    w.gh_log = tmp_path / "gh.log"
    return w


def run(world, capsys, *extra, ticket="163", type_="fix", slug="prepare-worktree"):
    argv = [world.repo, "--ticket", ticket, "--type", type_, "--slug", slug,
            "--plugin-json", str(world.plugin), *extra]
    code = pd.main(argv)
    out = capsys.readouterr().out
    return code, json.loads(out)


def wt_path(world, name="gh-163-prepare-worktree"):
    return os.path.join(world.repo, ".claude", "worktrees", name)




def test_fresh_creates_the_worktree_on_a_new_branch_cut_from_origin_base(world, capsys):
    git(world.seed, "commit", "-q", "--allow-empty", "-m", "later")
    git(world.origin, "fetch", "-q", str(world.seed), "main:main")
    later = git(world.seed, "rev-parse", "HEAD")
    code, out = run(world, capsys)
    assert code == 0
    assert out["worktree"] == wt_path(world)
    assert out["branch"] == "fix/gh-163-prepare-worktree"
    assert out["base"] == "main"
    assert out["repo_root"] == world.repo
    assert out["mode"] == "fresh"
    assert out["worktree_action"] == "created"
    assert out["ticket"] == "163"
    assert out["ticket_marker"] == "gh-163"
    assert out["detail"] == "cut fix/gh-163-prepare-worktree from origin/main"
    assert git(out["worktree"], "rev-parse", "HEAD") == later
    assert git(out["worktree"], "branch", "--show-current") == "fix/gh-163-prepare-worktree"


def test_fresh_reports_markers_plugin_and_base_manifest(world, capsys):
    code, out = run(world, capsys)
    assert code == 0
    assert out["markers"] == {"crap_gated": True, "mutation_gated": False}
    assert out["plugin"] == {"name": "touchstone", "version": "0.35.0"}
    manifest = out["base_manifest"]
    assert (manifest["found"], manifest["refreshed"], manifest["name"], manifest["version"]) == \
        (True, True, "touchstone", "9.9.9")
    assert out["prior_head"] is None
    assert out["prior_head_check"] is None


def test_mutation_marker_is_read_from_the_repo_root(world, capsys):
    (world.tmp / "repo" / ".mutation-gated").write_text("")
    os.remove(os.path.join(world.repo, ".crap-gated"))
    code, out = run(world, capsys)
    assert code == 0
    assert out["markers"] == {"crap_gated": False, "mutation_gated": True}


def test_fresh_refuses_a_name_that_exists_on_the_remote_only(world, capsys):
    git(world.seed, "branch", "fix/gh-163-prepare-worktree")
    git(world.origin, "fetch", "-q", str(world.seed), "fix/gh-163-prepare-worktree:fix/gh-163-prepare-worktree")
    code, out = run(world, capsys)
    assert code == 3
    assert out["error"] == "remote-branch-exists"
    assert "fix/gh-163-prepare-worktree" in out["reason"]
    assert not os.path.exists(wt_path(world))


def test_fresh_refuses_when_the_remote_cannot_be_asked(world, capsys, monkeypatch):
    real = pd.git

    def failing(root, *args):
        if args[0] == "ls-remote":
            return pd.Run(128, "", "fatal: no network")
        return real(root, *args)

    monkeypatch.setattr(pd, "git", failing)
    code, out = run(world, capsys)
    assert code == 3
    assert out["error"] == "remote-check-failed"
    assert "fatal: no network" in out["reason"]


def test_fresh_refuses_a_name_that_exists_locally(world, capsys):
    git(world.repo, "branch", "fix/gh-163-prepare-worktree")
    code, out = run(world, capsys)
    assert code == 3
    assert out["error"] == "local-branch-exists"
    assert "--existing" in out["reason"]


def test_fresh_refuses_an_occupied_path(world, capsys):
    os.makedirs(wt_path(world))
    code, out = run(world, capsys)
    assert code == 3
    assert out["error"] == "path-occupied"
    assert wt_path(world) in out["reason"]
    assert git(world.repo, "branch", "--list", "fix/*") == ""


def test_fresh_refuses_when_the_base_cannot_be_fetched(world, capsys):
    git(world.repo, "remote", "set-url", "origin", str(world.tmp / "gone.git"))
    code, out = run(world, capsys)
    assert code == 3
    assert out["error"] == "fetch-failed"
    assert "main" in out["reason"]


def test_fresh_with_a_given_base_cuts_from_it(world, capsys):
    git(world.repo, "commit", "-q", "--allow-empty", "-m", "stacked")
    git(world.repo, "branch", "stack", "HEAD")
    stack = git(world.repo, "rev-parse", "stack")
    code, out = run(world, capsys, "--base", "stack")
    assert code == 0
    assert out["base"] == "stack"
    assert git(out["worktree"], "rev-parse", "HEAD") == stack


def test_fresh_refuses_a_given_base_that_does_not_resolve(world, capsys):
    code, out = run(world, capsys, "--base", "no-such-ref")
    assert code == 3
    assert out["error"] == "base-unresolved"
    assert "no-such-ref" in out["reason"]


def test_a_failed_worktree_add_is_a_refusal(world, capsys, monkeypatch):
    real = pd.git

    def failing(root, *args):
        if args[:2] == ("worktree", "add"):
            return pd.Run(128, "", "fatal: nope")
        return real(root, *args)

    monkeypatch.setattr(pd, "git", failing)
    code, out = run(world, capsys)
    assert code == 3
    assert out["error"] == "worktree-add-failed"
    assert "fatal: nope" in out["reason"]


def test_fresh_prunes_stale_worktree_records_first(world, capsys):
    stale = os.path.realpath(world.tmp) + "/stale"
    git(world.repo, "worktree", "add", "-q", "-b", "other", stale)
    subprocess.run(["rm", "-rf", stale], check=True)
    code, _ = run(world, capsys)
    assert code == 0
    assert stale not in git(world.repo, "worktree", "list", "--porcelain")


def test_a_worktree_path_as_the_repo_argument_resolves_to_the_main_checkout(world, capsys):
    other = world.tmp / "other-wt"
    git(world.repo, "worktree", "add", "-q", "-b", "other", str(other))
    argv = [str(other), "--ticket", "163", "--type", "fix", "--slug", "prepare-worktree",
            "--plugin-json", str(world.plugin)]
    assert pd.main(argv) == 0
    assert json.loads(capsys.readouterr().out)["worktree"] == wt_path(world)




def test_default_base_is_what_origin_head_names(world):
    git(world.repo, "branch", "trunk")
    git(world.repo, "push", "-q", "origin", "trunk")
    git(world.repo, "remote", "set-head", "origin", "trunk")
    assert pd.default_base(world.repo) == "trunk"


def test_default_base_falls_back_to_master_without_origin_head(world):
    git(world.repo, "remote", "set-head", "origin", "-d")
    git(world.repo, "branch", "-m", "main", "master")
    git(world.repo, "update-ref", "-d", "refs/remotes/origin/main")
    assert pd.default_base(world.repo) == "master"


def test_default_base_falls_back_to_main_without_origin_head(world):
    git(world.repo, "remote", "set-head", "origin", "-d")
    assert pd.default_base(world.repo) == "main"


def kill_every_base(world):
    git(world.repo, "remote", "set-head", "origin", "-d")
    git(world.repo, "checkout", "-q", "-b", "trunk")
    git(world.repo, "branch", "-D", "main")
    git(world.repo, "update-ref", "-d", "refs/remotes/origin/main")


def test_default_base_is_none_when_nothing_names_one(world):
    kill_every_base(world)
    assert pd.default_base(world.repo) is None


def test_no_resolvable_base_is_a_refusal(world, capsys):
    kill_every_base(world)
    code, out = run(world, capsys)
    assert code == 3
    assert out["error"] == "base-unresolved"




def make_branch_worktree(world, branch, name):
    path = wt_path(world, name)
    git(world.repo, "worktree", "add", "-q", "-b", branch, path)
    return path


def test_existing_finds_the_ticket_worktree_whatever_its_type(world, capsys):
    path = make_branch_worktree(world, "feat/gh-163-old-slug", "gh-163-old-slug")
    code, out = run(world, capsys, "--existing")
    assert code == 0
    assert (out["worktree"], out["branch"], out["base"]) == (path, "feat/gh-163-old-slug", "main")
    assert out["mode"] == "existing"
    assert out["worktree_action"] == "reused"
    assert world.gh_log.read_text() == \
        f"{world.repo} pr list --head feat/gh-163-old-slug --state merged --json number\n"
    assert out["detail"] == "reused the worktree of feat/gh-163-old-slug"


def test_existing_does_not_match_a_marker_that_only_shares_a_prefix(world, capsys):
    make_branch_worktree(world, "feat/gh-1634-other", "gh-1634-other")
    code, out = run(world, capsys, "--existing")
    assert code == 3
    assert out["error"] == "not-found"


def test_existing_reattaches_a_branch_without_a_worktree(world, capsys):
    git(world.repo, "branch", "feat/gh-163-left-behind")
    code, out = run(world, capsys, "--existing")
    assert code == 0
    assert out["worktree"] == wt_path(world, "gh-163-left-behind")
    assert out["branch"] == "feat/gh-163-left-behind"
    assert out["worktree_action"] == "reattached"
    assert out["detail"] == "reattached the worktree of feat/gh-163-left-behind"
    assert world.gh_log.read_text().startswith(f"{world.repo} pr list --head feat/gh-163-left-behind ")
    assert git(out["worktree"], "branch", "--show-current") == "feat/gh-163-left-behind"


def test_existing_refuses_reattaching_onto_an_occupied_directory(world, capsys):
    git(world.repo, "branch", "feat/gh-163-left-behind")
    os.makedirs(wt_path(world, "gh-163-left-behind"))
    code, out = run(world, capsys, "--existing")
    assert code == 3
    assert out["error"] == "occupied"
    assert wt_path(world, "gh-163-left-behind") in out["reason"]


def test_existing_refuses_a_worktree_whose_pr_merged(world, capsys):
    make_branch_worktree(world, "feat/gh-163-done", "gh-163-done")
    world.gh_out.write_text('[{"number": 42}]')
    code, out = run(world, capsys, "--existing")
    assert code == 3
    assert out["error"] == "merged"
    assert "feat/gh-163-done" in out["reason"] and "#42" in out["reason"]


def test_existing_refuses_a_branch_whose_pr_merged_without_reattaching(world, capsys):
    git(world.repo, "branch", "feat/gh-163-done")
    world.gh_out.write_text('[{"number": 7}]')
    code, out = run(world, capsys, "--existing")
    assert code == 3
    assert out["error"] == "merged"
    assert not os.path.exists(wt_path(world, "gh-163-done"))


@pytest.mark.parametrize("reply", ["not json", '{"number": 1}', "[]", '[{"id": 1}]'])
def test_existing_treats_an_unusable_or_empty_gh_reply_as_live(world, capsys, reply):
    path = make_branch_worktree(world, "feat/gh-163-live", "gh-163-live")
    world.gh_out.write_text(reply)
    code, out = run(world, capsys, "--existing")
    assert code == 0
    assert out["worktree"] == path


def test_existing_treats_a_missing_gh_as_live(world, capsys, monkeypatch):
    path = make_branch_worktree(world, "feat/gh-163-live", "gh-163-live")
    monkeypatch.setattr(pd, "GH", "no-such-gh-binary")
    code, out = run(world, capsys, "--existing")
    assert code == 0
    assert out["worktree"] == path


def test_existing_refuses_a_dirty_worktree(world, capsys):
    path = make_branch_worktree(world, "feat/gh-163-wip", "gh-163-wip")
    with open(os.path.join(path, "stray.txt"), "w") as f:
        f.write("x")
    code, out = run(world, capsys, "--existing")
    assert code == 3
    assert out["error"] == "dirty"
    assert "stray.txt" in out["reason"]


def test_existing_refuses_two_matching_worktrees(world, capsys):
    make_branch_worktree(world, "feat/gh-163-a", "gh-163-a")
    make_branch_worktree(world, "fix/gh-163-b", "gh-163-b")
    code, out = run(world, capsys, "--existing")
    assert code == 3
    assert out["error"] == "ambiguous"
    assert "feat/gh-163-a" in out["reason"] and "fix/gh-163-b" in out["reason"]


def test_existing_refuses_two_matching_branches(world, capsys):
    git(world.repo, "branch", "feat/gh-163-a")
    git(world.repo, "branch", "fix/gh-163-b")
    code, out = run(world, capsys, "--existing")
    assert code == 3
    assert out["error"] == "ambiguous"
    assert "feat/gh-163-a" in out["reason"] and "fix/gh-163-b" in out["reason"]


def test_existing_refuses_a_worktree_outside_claude_worktrees(world, capsys):
    elsewhere = os.path.realpath(world.tmp) + "/elsewhere"
    git(world.repo, "worktree", "add", "-q", "-b", "feat/gh-163-x", elsewhere)
    code, out = run(world, capsys, "--existing")
    assert code == 3
    assert out["error"] == "outside-worktrees"
    assert elsewhere in out["reason"]


def test_existing_with_nothing_found_refuses(world, capsys):
    code, out = run(world, capsys, "--existing")
    assert code == 3
    assert out["error"] == "not-found"
    assert "gh-163" in out["reason"]


def test_existing_names_another_tickets_checkout_as_wrong_ticket(world, capsys):
    git(world.repo, "checkout", "-q", "-b", "feat/jira-AB-9-other")
    code, out = run(world, capsys, "--existing")
    assert code == 3
    assert out["error"] == "wrong-ticket"
    assert "jira-AB-9" in out["reason"]


def test_existing_does_not_need_the_remote(world, capsys):
    path = make_branch_worktree(world, "feat/gh-163-x", "gh-163-x")
    git(world.repo, "remote", "set-url", "origin", str(world.tmp / "gone.git"))
    code, out = run(world, capsys, "--existing")
    assert code == 0
    assert out["worktree"] == path
    assert out["base_manifest"]["refreshed"] is False
    assert out["base_manifest"]["found"] is True


def test_existing_with_a_given_base_reports_it(world, capsys):
    make_branch_worktree(world, "feat/gh-163-x", "gh-163-x")
    code, out = run(world, capsys, "--existing", "--base", "release")
    assert code == 0
    assert out["base"] == "release"


def test_existing_without_any_base_is_a_refusal(world, capsys):
    make_branch_worktree(world, "feat/gh-163-x", "gh-163-x")
    kill_every_base(world)
    code, out = run(world, capsys, "--existing")
    assert code == 3
    assert out["error"] == "base-unresolved"




def test_prior_head_check_prints_linear_for_an_ancestor(world, capsys):
    path = make_branch_worktree(world, "feat/gh-163-x", "gh-163-x")
    prior = git(path, "rev-parse", "HEAD")
    git(path, "commit", "-q", "--allow-empty", "-m", "more")
    code, out = run(world, capsys, "--existing", "--prior-head", prior)
    assert code == 0
    assert out["prior_head"] == prior
    assert out["prior_head_check"] == "TOUCHSTONE_PRIOR_HEAD_LINEAR 0"


def test_prior_head_check_prints_2_when_a_merge_follows(world, capsys):
    path = make_branch_worktree(world, "feat/gh-163-x", "gh-163-x")
    prior = git(path, "rev-parse", "HEAD")
    side = wt_path(world, "side")
    git(world.repo, "worktree", "add", "-q", "-b", "side", side, prior)
    git(side, "commit", "-q", "--allow-empty", "-m", "side")
    git(path, "commit", "-q", "--allow-empty", "-m", "main line")
    git(path, "merge", "-q", "--no-edit", "side")
    git(world.repo, "worktree", "remove", side)
    code, out = run(world, capsys, "--existing", "--prior-head", prior)
    assert code == 0
    assert out["prior_head_check"] == "TOUCHSTONE_PRIOR_HEAD_LINEAR 2"


def test_prior_head_check_prints_1_for_an_unknown_commit(world, capsys):
    make_branch_worktree(world, "feat/gh-163-x", "gh-163-x")
    code, out = run(world, capsys, "--existing", "--prior-head", "a" * 40)
    assert code == 0
    assert out["prior_head_check"] == "TOUCHSTONE_PRIOR_HEAD_LINEAR 1"


def test_prior_head_check_prints_1_for_a_commit_off_the_branch(world, capsys):
    make_branch_worktree(world, "feat/gh-163-x", "gh-163-x")
    side = wt_path(world, "side")
    git(world.repo, "worktree", "add", "-q", "-b", "side", side)
    git(side, "commit", "-q", "--allow-empty", "-m", "side")
    off = git(side, "rev-parse", "HEAD")
    code, out = run(world, capsys, "--existing", "--prior-head", off)
    assert code == 0
    assert out["prior_head_check"] == "TOUCHSTONE_PRIOR_HEAD_LINEAR 1"


def test_prior_head_without_existing_is_a_bad_argument(world, capsys):
    code, out = run(world, capsys, "--prior-head", "a" * 40)
    assert code == 2
    assert out["error"] == "bad-args"


def test_prior_head_must_be_a_full_sha(world, capsys):
    code, out = run(world, capsys, "--existing", "--prior-head", "abc")
    assert code == 2
    assert out["error"] == "bad-args"




@pytest.mark.parametrize("ticket,marker", [
    ("216", "gh-216"), ("#216", "gh-216"), (" 216 ", "gh-216"),
    ("proj-4821", "jira-PROJ-4821"), ("ABC-36", "jira-ABC-36"), ("A1-2", "jira-A1-2"),
])
def test_marker_for_matches_the_workflow(ticket, marker):
    assert pd.marker_for(ticket) == marker


@pytest.mark.parametrize("ticket", ["", "abc", "PROJ-", "-12", "1A-2", "12a", "PROJ-12x", "x216"])
def test_marker_for_refuses_anything_else(ticket):
    assert pd.marker_for(ticket) is None


@pytest.mark.parametrize("extra", [
    ["--ticket", "nope"],
    ["--type", "feature"],
    ["--slug", "Has-Caps"],
    ["--slug", "a-b-c-d-e-f-g"],
    ["--slug", "trailing-"],
    ["--slug", "-leading"],
    ["--slug", "two--hyphens"],
    ["--slug", ""],
    ["--base", "-x"],
    ["--base="],
    ["--base=-x"],
])
def test_bad_arguments_exit_2_with_a_reason(world, capsys, extra):
    code, out = run(world, capsys, *extra)
    assert code == 2
    assert out["error"] == "bad-args"
    assert out["reason"]


def test_a_six_word_slug_is_allowed(world, capsys):
    code, out = run(world, capsys, slug="a-b-c-d-e-f")
    assert code == 0
    assert out["branch"] == "fix/gh-163-a-b-c-d-e-f"


def test_every_branch_type_is_accepted():
    assert pd.TYPES == ("feat", "fix", "chore", "refactor", "docs", "test", "perf", "build", "ci")


def test_an_unknown_flag_is_a_bad_argument(world, capsys):
    code, out = run(world, capsys, "--bogus")
    assert code == 2
    assert out["error"] == "bad-args"


def test_a_relative_repo_path_is_a_bad_argument(world, capsys):
    code = pd.main(["repo", "--ticket", "1", "--type", "fix", "--slug", "x", "--plugin-json", str(world.plugin)])
    out = json.loads(capsys.readouterr().out)
    assert code == 2
    assert out["error"] == "bad-args"
    assert "absolute" in out["reason"]


def test_a_path_that_is_not_a_repo_is_a_bad_argument(world, capsys):
    code = pd.main([str(world.tmp), "--ticket", "1", "--type", "fix", "--slug", "x",
                    "--plugin-json", str(world.plugin)])
    out = json.loads(capsys.readouterr().out)
    assert code == 2
    assert out["error"] == "bad-args"
    assert str(world.tmp) in out["reason"]


@pytest.mark.parametrize("content", ["{not json", json.dumps({"name": "touchstone"}),
                                     json.dumps({"version": "1"}), "[1]"])
def test_an_unusable_plugin_manifest_is_a_setup_problem(world, capsys, content):
    world.plugin.write_text(content)
    code, out = run(world, capsys)
    assert code == 2
    assert out["error"] == "plugin-unreadable"


def test_a_missing_plugin_manifest_is_a_setup_problem(world, capsys):
    world.plugin.unlink()
    code, out = run(world, capsys)
    assert code == 2
    assert out["error"] == "plugin-unreadable"
    assert str(world.plugin) in out["reason"]




def test_base_manifest_not_found_when_the_base_has_no_plugin_json(world):
    git(world.repo, "rm", "-q", "-r", ".claude-plugin")
    git(world.repo, "commit", "-q", "-m", "drop")
    git(world.repo, "push", "-q", "origin", "main")
    got = pd.base_manifest(world.repo, "main", True)
    assert (got["found"], got["name"], got["version"], got["refreshed"]) == (False, "", "", True)
    assert "origin/main" in got["detail"]


@pytest.mark.parametrize("content", ["[1]", "{bad", json.dumps({"name": "x"})])
def test_base_manifest_not_found_when_the_file_is_not_a_manifest(world, content):
    (world.tmp / "repo" / ".claude-plugin" / "plugin.json").write_text(content)
    git(world.repo, "commit", "-q", "-am", "change")
    git(world.repo, "push", "-q", "origin", "main")
    assert pd.base_manifest(world.repo, "main", False)["found"] is False


def test_base_manifest_found_names_its_source(world):
    got = pd.base_manifest(world.repo, "main", True)
    assert got["found"] is True
    assert "origin/main" in got["detail"]


def test_base_manifest_without_a_base_is_not_found(world):
    got = pd.base_manifest(world.repo, None, False)
    assert (got["found"], got["refreshed"]) == (False, False)
    assert got["detail"]




def test_checks_source_transcribes_every_heading_and_its_first_fence(world, capsys):
    code, out = run(world, capsys)
    assert code == 0
    source = out["checks_source"]
    assert source["file"] == os.path.join(out["worktree"], "AGENTS.md")
    assert source["sections"] == [
        {"heading": "## Checks", "fence": "```bash\nmake test   # fast\n```"},
        {"heading": "## Advisory checks", "fence": "```\nmake lint\n```"},
        {"heading": "### Notes", "fence": "~~~\n## not a heading\n~~~"},
        {"heading": "## Empty", "fence": ""},
    ]
    assert source["detail"] == f"read {source['file']}: 4 sections"


def test_checks_source_falls_back_to_claude_md(tmp_path):
    (tmp_path / "CLAUDE.md").write_text("## Checks\n```\nx\n```\n")
    got = pd.checks_source(str(tmp_path))
    assert got["file"] == str(tmp_path / "CLAUDE.md")
    assert got["sections"] == [{"heading": "## Checks", "fence": "```\nx\n```"}]


def test_checks_source_prefers_agents_md(tmp_path):
    (tmp_path / "CLAUDE.md").write_text("## C\n")
    (tmp_path / "AGENTS.md").write_text("## A\n")
    assert pd.checks_source(str(tmp_path))["sections"] == [{"heading": "## A", "fence": ""}]


def test_checks_source_with_neither_file(tmp_path):
    got = pd.checks_source(str(tmp_path))
    assert got == {"file": "", "sections": [], "detail": "neither AGENTS.md nor CLAUDE.md exists"}


def test_checks_source_keeps_an_unclosed_fence_to_the_end(tmp_path):
    (tmp_path / "AGENTS.md").write_text("## Checks\n````\nx\n```\n## y\n")
    got = pd.checks_source(str(tmp_path))
    assert got["sections"] == [{"heading": "## Checks", "fence": "````\nx\n```\n## y"}]


def test_checks_source_closes_a_fence_only_on_its_own_marker(tmp_path):
    (tmp_path / "AGENTS.md").write_text("## A\n~~~\n```\n~~~\n## B\n```\ny\n```\n")
    got = pd.checks_source(str(tmp_path))
    assert got["sections"] == [{"heading": "## A", "fence": "~~~\n```\n~~~"},
                               {"heading": "## B", "fence": "```\ny\n```"}]


def test_a_longer_closing_marker_closes_the_fence(tmp_path):
    (tmp_path / "AGENTS.md").write_text("## A\n```\ny\n`````\n## B\n")
    got = pd.checks_source(str(tmp_path))
    assert got["sections"] == [{"heading": "## A", "fence": "```\ny\n`````"},
                               {"heading": "## B", "fence": ""}]


def test_an_indented_fence_marker_up_to_three_spaces_counts(tmp_path):
    (tmp_path / "AGENTS.md").write_text("## A\n   ```\ny\n   ```\n## B\n    ```\nz\n")
    got = pd.checks_source(str(tmp_path))
    assert got["sections"] == [{"heading": "## A", "fence": "   ```\ny\n   ```"},
                               {"heading": "## B", "fence": ""}]


def test_checks_source_takes_only_the_first_fence_under_a_heading(tmp_path):
    (tmp_path / "AGENTS.md").write_text("## A\n```\none\n```\n```\ntwo\n```\n")
    got = pd.checks_source(str(tmp_path))
    assert got["sections"] == [{"heading": "## A", "fence": "```\none\n```"}]


def test_a_single_hash_heading_is_not_a_section(tmp_path):
    (tmp_path / "AGENTS.md").write_text("# Top\n```\nz\n```\n")
    assert pd.checks_source(str(tmp_path))["sections"] == []


def test_a_heading_keeps_its_trailing_text_verbatim(tmp_path):
    (tmp_path / "AGENTS.md").write_text("## Checks  \r\n```\nx\n```\n")
    got = pd.checks_source(str(tmp_path))
    assert got["sections"][0]["heading"] == "## Checks  "


def test_git_runs_the_git_binary(world, argv_log):
    pd.git(world.repo, "status")
    assert argv_log[-1]["argv"][:3] == ["git", "-C", world.repo]


@pytest.mark.parametrize("flag", ["--ticket", "--type", "--slug", "--plugin-json"])
def test_each_required_flag_is_required(world, capsys, flag):
    argv = [world.repo, "--ticket", "163", "--type", "fix", "--slug", "x", "--plugin-json", str(world.plugin)]
    i = argv.index(flag)
    del argv[i:i + 2]
    code = pd.main(argv)
    out = json.loads(capsys.readouterr().out)
    assert code == 2
    assert out == {"error": "bad-args", "reason": f"the following arguments are required: {flag}"}


def test_a_bad_type_names_every_accepted_one(world, capsys):
    _, out = run(world, capsys, type_="feature")
    assert out["reason"] == "--type must be one of feat, fix, chore, refactor, docs, test, perf, build, ci, got 'feature'"


def test_prior_head_refusals_say_why(world, capsys):
    _, out = run(world, capsys, "--prior-head", "a" * 40)
    assert out["reason"] == "--prior-head is only meaningful with --existing"
    _, out = run(world, capsys, "--existing", "--prior-head", "abc")
    assert out["reason"] == "--prior-head must be a 40-character SHA, got 'abc'"


def test_a_manifest_without_fields_says_so(world, capsys):
    world.plugin.write_text("[1]")
    _, out = run(world, capsys)
    assert out["reason"] == f"{world.plugin} has no string name and version"


def test_a_branch_whose_name_only_ends_like_ours_is_not_ours(world, capsys):
    git(world.repo, "branch", "a/refs/heads/fix/gh-163-prepare-worktree")
    code, out = run(world, capsys)
    assert code == 0
    assert out["branch"] == "fix/gh-163-prepare-worktree"


def test_worktree_add_refuses_a_branch_that_appeared_after_the_checks(world, capsys, monkeypatch):
    git(world.repo, "commit", "-q", "--allow-empty", "-m", "elsewhere")
    git(world.repo, "branch", "fix/gh-163-prepare-worktree")
    monkeypatch.setattr(pd, "_refuse_taken_name", lambda root, branch: None)
    code, out = run(world, capsys)
    assert code == 3
    assert out["error"] == "worktree-add-failed"


def test_the_fetch_asks_for_the_base_alone(world, capsys):
    git(world.seed, "branch", "unrelated")
    git(world.origin, "fetch", "-q", str(world.seed), "unrelated:unrelated")
    code, _ = run(world, capsys)
    assert code == 0
    assert git(world.repo, "branch", "-r", "--list", "origin/unrelated") == ""


def test_no_base_names_why(world, capsys):
    kill_every_base(world)
    _, fresh_out = run(world, capsys)
    make_branch_worktree(world, "feat/gh-163-x", "gh-163-x")
    _, existing_out = run(world, capsys, "--existing")
    why = "no base branch: origin/HEAD is unset and neither main nor master exists"
    assert (fresh_out["reason"], existing_out["reason"]) == (why, why)


def test_base_manifest_details(world):
    assert pd.base_manifest(world.repo, "main", True)["detail"] == "read origin/main:.claude-plugin/plugin.json"
    assert pd.base_manifest(world.repo, "main", False)["detail"] == \
        "read origin/main:.claude-plugin/plugin.json; the fetch failed, so the ref may be stale"
    assert pd.base_manifest(world.repo, None, False)["detail"] == "no base branch resolved"


def test_markers_are_the_exact_file_names(tmp_path, exact_case_fs):
    (tmp_path / ".crap-gated").write_text("")
    (tmp_path / ".mutation-gated").write_text("")
    assert pd.markers(str(tmp_path)) == {"crap_gated": True, "mutation_gated": True}


@pytest.mark.parametrize("branch,want", [
    ("feat/gh-163-x", True), ("user/feat/gh-163-x", False), ("gh-163-x", False), ("feat/gh-1630-x", False),
])
def test_carries_reads_the_marker_after_the_first_slash(branch, want):
    assert pd.carries(branch, "gh-163") is want


def test_a_marker_deeper_than_the_first_segment_is_not_another_ticket(world, capsys):
    git(world.repo, "checkout", "-q", "-b", "x/feat/jira-AB-9-y")
    code, out = run(world, capsys, "--existing")
    assert out["error"] == "not-found"


def test_a_tag_carrying_the_marker_is_not_a_branch(world, capsys):
    git(world.repo, "tag", "feat/gh-163-tag")
    code, out = run(world, capsys, "--existing")
    assert out["error"] == "not-found"


def test_ambiguous_reasons_list_every_match(world, capsys):
    git(world.repo, "branch", "feat/gh-163-a")
    git(world.repo, "branch", "fix/gh-163-b")
    _, out = run(world, capsys, "--existing")
    assert out["reason"] == "more than one branch carries the gh-163 marker: feat/gh-163-a, fix/gh-163-b"
    a = make_branch_worktree(world, "chore/gh-163-c", "gh-163-c")
    b = make_branch_worktree(world, "docs/gh-163-d", "gh-163-d")
    _, out = run(world, capsys, "--existing")
    assert out["reason"] == ("more than one worktree carries the gh-163 marker: "
                             f"('{a}', 'chore/gh-163-c'), ('{b}', 'docs/gh-163-d')")


def test_a_failing_gh_is_not_believed_even_when_it_prints_a_merge(world, capsys):
    path = make_branch_worktree(world, "feat/gh-163-live", "gh-163-live")
    world.gh_out.write_text('[{"number": 5}]')
    (world.tmp / "gh-code").write_text("1")
    code, out = run(world, capsys, "--existing")
    assert code == 0
    assert out["worktree"] == path


def test_default_base_ignores_other_remotes_heads(world):
    git(world.repo, "update-ref", "refs/remotes/zz/dev", "HEAD")
    git(world.repo, "symbolic-ref", "refs/remotes/zz/HEAD", "refs/remotes/zz/dev")
    assert pd.default_base(world.repo) == "main"


def test_a_reattached_branch_with_a_slash_in_its_slug_gets_one_flat_directory(world, capsys):
    git(world.repo, "branch", "feat/gh-163-x/y")
    code, out = run(world, capsys, "--existing")
    assert code == 0
    assert out["worktree"] == wt_path(world, "gh-163-x-y")
