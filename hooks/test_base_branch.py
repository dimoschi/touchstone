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


def test_target_repo_dash_c_matches_git_by_basename():
    # `\bgit\b` used to match `/usr/bin/git -C /x` too; a bare `== 'git'`
    # token compare must not silently drop that.
    out = base_branch.target_repo("/usr/bin/git -C /x status", Path("/cwd"))
    assert out == Path("/x")


def test_target_repo_dash_c_has_no_command_position_requirement():
    out = base_branch.target_repo("sudo git -C /x status", Path("/cwd"))
    assert out == Path("/x")


def test_target_repo_walks_cd_chain():
    out = base_branch.target_repo("cd repo && cd sub && git commit", Path("/root"))
    assert out == Path("/root/repo/sub")


def test_target_repo_ignores_cd_dash():
    out = base_branch.target_repo("cd -", Path("/root"))
    assert out == Path("/root")


def test_target_repo_falls_back_to_cwd():
    assert base_branch.target_repo("git commit", Path("/root")) == Path("/root")


def test_target_repo_ignores_dash_c_inside_quoted_argument_of_earlier_command():
    cmd = 'gh pr comment 79 --body "see git -C /other for context" && gh pr ready 79'
    assert base_branch.target_repo(cmd, Path("/cwd")) == Path("/cwd")


def test_target_repo_ignores_cd_inside_quoted_argument():
    cmd = 'gh pr comment 79 --body "run; cd /elsewhere now" && gh pr ready'
    assert base_branch.target_repo(cmd, Path("/cwd")) == Path("/cwd")


def test_target_repo_backslash_escaped_quote_does_not_reexpose_contents():
    cmd = 'git commit -m "he said \\"git -C /x\\"" && git -C /r push'
    assert base_branch.target_repo(cmd, Path("/cwd")) == Path("/r")


def test_target_repo_unterminated_quote_falls_back_to_cwd():
    cmd = 'gh pr comment 79 --body "unterminated'
    assert base_branch.target_repo(cmd, Path("/cwd")) == Path("/cwd")


def test_target_repo_dash_c_matches_at_minimal_three_token_command():
    assert base_branch.target_repo("git -C /x", Path("/cwd")) == Path("/x")


def test_target_repo_cd_walk_matches_at_minimal_two_token_command():
    assert base_branch.target_repo("cd repo", Path("/root")) == Path("/root/repo")


def test_target_repo_skippable_cd_path_does_not_abort_the_walk():
    out = base_branch.target_repo("cd - && cd repo", Path("/root"))
    assert out == Path("/root/repo")


def test_is_operator_true_only_for_pure_shell_punctuation():
    assert base_branch._is_operator('') is False
    assert base_branch._is_operator('a') is False
    assert base_branch._is_operator('&&') is True
    # A token whose character set exactly equals OPERATOR_CHARS: `<=` (equal
    # counts as a subset) and `<` (proper subset only) disagree here.
    assert base_branch._is_operator('();<>|&') is True


def test_shell_tokens_splits_quoted_argument_as_one_token():
    tokens = base_branch.shell_tokens(
        'gh pr comment 79 --body "see git -C /other for context"')
    assert tokens == [
        'gh', 'pr', 'comment', '79', '--body',
        'see git -C /other for context',
    ]


def test_shell_tokens_backslash_escaped_quote_stays_inside_the_word():
    tokens = base_branch.shell_tokens('git commit -m "he said \\"git -C /x\\""')
    assert tokens == ['git', 'commit', '-m', 'he said "git -C /x"']


def test_shell_tokens_keeps_punctuation_operators_without_surrounding_spaces():
    assert base_branch.shell_tokens('cd a&&cd b') == ['cd', 'a', '&&', 'cd', 'b']


def test_shell_tokens_unterminated_quote_returns_words_lexed_before_it():
    tokens = base_branch.shell_tokens('echo one "two three')
    assert tokens == ['echo', 'one']


def test_shell_tokens_whitespace_split_keeps_a_colon_inside_one_word():
    # ':' is not a wordchar and not a punctuation_chars operator, so without
    # whitespace_split=True it splits off as its own token.
    tokens = base_branch.shell_tokens('git push origin main:main')
    assert tokens == ['git', 'push', 'origin', 'main:main']


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


def test_git_common_dir_resolves_worktree_to_the_shared_git_dir(tmp_path):
    repo = _repo(tmp_path)
    # A sibling of tmp_path, not tmp_path.parent / "wt": every test sharing
    # this file's tmp_path.parent (the pytest session's own temp root) would
    # otherwise fight over the same worktree directory.
    wt_dir = tmp_path.parent / f"{tmp_path.name}-gcd-wt"
    _git("worktree", "add", "-q", "-b", "gcdbranch", str(wt_dir), cwd=repo)
    assert base_branch.git_common_dir(wt_dir) == str(repo / ".git")


def test_git_common_dir_none_outside_repo(tmp_path):
    assert base_branch.git_common_dir(tmp_path) is None


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


def test_worktree_root_outside_a_repository_is_none(tmp_path):
    """None, not a Path built from an empty toplevel: callers join a marker
    name onto this and must not be handed a path rooted at '/'."""
    loose = tmp_path / "loose"
    loose.mkdir()
    assert base_branch.worktree_root(loose / "a.py") is None
