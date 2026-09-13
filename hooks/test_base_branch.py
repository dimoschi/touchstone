import subprocess
from pathlib import Path

import base_branch


def _git(*args, cwd):
    return subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True)


def _repo(tmp_path):
    _git("init", "-q", "-b", "main", str(tmp_path), cwd=tmp_path.parent)
    (tmp_path / "f.txt").write_text("x")
    _git("add", ".", cwd=tmp_path)
    _git(
        "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false",
        "commit", "-q", "-m", "init", cwd=tmp_path,
    )
    return tmp_path


def test_git_returns_none_on_failure(tmp_path):
    assert base_branch.git(tmp_path, "rev-parse", "--git-dir") is None


def test_git_returns_stripped_stdout_on_success(tmp_path):
    repo = _repo(tmp_path)
    out = base_branch.git(repo, "rev-parse", "--abbrev-ref", "HEAD")
    assert out == "main"


def test_git_returns_none_on_os_error(monkeypatch, tmp_path):
    def boom(*a, **k):
        raise OSError("no git")

    monkeypatch.setattr(base_branch.subprocess, "run", boom)
    assert base_branch.git(tmp_path, "status") is None


def test_git_returns_none_on_undecodable_blob(tmp_path):
    repo = _repo(tmp_path)
    (repo / "task.php").write_bytes(b"<?php\n// caf\xe9 latin1 comment\n")
    _git("add", ".", cwd=repo)
    _git(
        "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false",
        "commit", "-q", "-m", "non-utf8", cwd=repo,
    )
    assert base_branch.git(repo, "show", "HEAD:./task.php") is None


def test_target_repo_prefers_dash_c():
    out = base_branch.target_repo('git -C "/some repo" commit', Path("/cwd"))
    assert out == Path("/some repo")

    out = base_branch.target_repo("git -C '/quoted' status", Path("/cwd"))
    assert out == Path("/quoted")

    out = base_branch.target_repo("git -C /bare/path status", Path("/cwd"))
    assert out == Path("/bare/path")


def test_target_repo_walks_cd_chain():
    out = base_branch.target_repo("cd repo && cd sub && git commit", Path("/root"))
    assert out == Path("/root/repo/sub")


def test_target_repo_ignores_cd_dash():
    out = base_branch.target_repo("cd -", Path("/root"))
    assert out == Path("/root")


def test_target_repo_falls_back_to_cwd():
    assert base_branch.target_repo("git commit", Path("/root")) == Path("/root")


def test_base_branch_names_includes_origin_head(tmp_path):
    repo = _repo(tmp_path)
    remote = tmp_path.parent / "remote.git"
    _git("init", "-q", "--bare", str(remote), cwd=tmp_path.parent)
    _git("remote", "add", "origin", str(remote), cwd=repo)
    _git("push", "-q", "origin", "main", cwd=repo)
    _git("remote", "set-head", "origin", "main", cwd=repo)
    names = base_branch.base_branch_names(repo)
    assert "main" in names
    assert "master" in names  # always-present default


def test_base_branch_names_without_origin_head_is_just_defaults(tmp_path):
    repo = _repo(tmp_path)
    assert base_branch.base_branch_names(repo) == base_branch.BASE_BRANCHES


def test_repo_common_root_resolves_worktree_to_shared_root(tmp_path):
    repo = _repo(tmp_path)
    wt_dir = tmp_path.parent / "wt"
    _git("worktree", "add", "-q", "-b", "wtbranch", str(wt_dir), cwd=repo)
    assert base_branch.repo_common_root(wt_dir) == repo


def test_repo_common_root_none_outside_repo(tmp_path):
    assert base_branch.repo_common_root(tmp_path) is None


def test_is_gated_true_when_marker_present(tmp_path):
    repo = _repo(tmp_path)
    (repo / ".crap-gated").write_text("")
    (repo / "sub").mkdir()
    assert base_branch.is_gated(repo / "sub" / "file.py", ".crap-gated") is True


def test_is_gated_true_for_new_file_whose_parent_dir_does_not_exist_yet(tmp_path):
    repo = _repo(tmp_path)
    (repo / ".crap-gated").write_text("")
    assert base_branch.is_gated(repo / "sub" / "file.py", ".crap-gated") is True


def test_is_gated_false_without_marker(tmp_path):
    repo = _repo(tmp_path)
    assert base_branch.is_gated(repo / "file.py", ".crap-gated") is False


def test_is_gated_walks_to_nearest_existing_ancestor_for_new_file(tmp_path):
    repo = _repo(tmp_path)
    (repo / ".crap-gated").write_text("")
    new_dir_file = repo / "brand" / "new" / "dir" / "file.py"
    assert base_branch.is_gated(new_dir_file, ".crap-gated") is True


def test_is_gated_false_when_no_existing_ancestor_at_all(monkeypatch):
    # No real path has zero existing ancestors (root always exists), so this
    # forces the walk to exhaust without ever finding a directory.
    monkeypatch.setattr(Path, "is_dir", lambda self: False)
    assert base_branch.is_gated(Path("/definitely/not/a/real/path/x.py"), ".crap-gated") is False


def test_marker_path_returns_root_marker_when_repo_found(tmp_path):
    repo = _repo(tmp_path)
    (repo / "sub").mkdir()
    assert base_branch.marker_path(repo / "sub" / "file.py", ".comment-gated") == repo / ".comment-gated"


def test_marker_path_none_outside_a_repo(tmp_path):
    assert base_branch.marker_path(tmp_path / "file.py", ".comment-gated") is None


def test_marker_path_none_when_no_existing_ancestor_at_all(monkeypatch):
    monkeypatch.setattr(Path, "is_dir", lambda self: False)
    assert base_branch.marker_path(Path("/definitely/not/a/real/path/x.py"), ".comment-gated") is None
