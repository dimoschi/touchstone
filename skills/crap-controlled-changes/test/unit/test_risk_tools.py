import os

import risk_tools


def put_tool(directory, name):
    tool = directory / name
    tool.write_text('#!/bin/sh\n')
    tool.chmod(0o755)
    return tool


def test_which_finds_a_tool_on_path_and_returns_none_otherwise(tmp_path, monkeypatch):
    tool = put_tool(tmp_path, 'faketool')
    monkeypatch.setenv('PATH', str(tmp_path))
    assert risk_tools.which('faketool') == str(tool)
    assert risk_tools.which('absent-tool') is None


def test_missing_names_the_tool_until_it_is_on_path(tmp_path, monkeypatch):
    monkeypatch.setenv('PATH', str(tmp_path))
    assert risk_tools.missing('apidiff') == 'apidiff is not on PATH'
    put_tool(tmp_path, 'apidiff')
    assert risk_tools.missing('apidiff') is None


def test_run_captures_text_output_and_the_exit_code(tmp_path):
    done = risk_tools.run(['sh', '-c', 'echo out; echo err >&2; pwd -P; exit 3'],
                          cwd=str(tmp_path))
    assert done.returncode == 3
    assert done.stdout.split() == ['out', os.path.realpath(tmp_path)]
    assert done.stderr == 'err\n'


def test_tail_flattens_whitespace_and_keeps_only_the_end():
    assert risk_tools.tail('a\n  b\tc') == 'a b c'
    assert risk_tools.tail('x' * 500 + 'END', 10) == 'xxxxxxxEND'


def test_cat_file_returns_the_bytes_at_a_revision_or_none(repo):
    first = repo.commit({'a.txt': 'one\n'})
    repo.commit({'a.txt': 'two\n'})
    assert risk_tools.cat_file(str(repo.path), first, 'a.txt') == b'one\n'
    assert risk_tools.cat_file(str(repo.path), first, 'nope.txt') is None


def test_git_runs_in_the_named_repository(repo):
    sha = repo.commit({'a.txt': 'x\n'})
    done = risk_tools.git(str(repo.path), 'rev-parse', 'HEAD')
    assert done.returncode == 0
    assert done.stdout.decode().strip() == sha


def test_export_tree_unpacks_a_whole_revision(repo, tmp_path):
    rev = repo.commit({'a/x.go': '1\n', 'b/y.go': '2\n'})
    dest = tmp_path / 'out'
    dest.mkdir()
    assert risk_tools.export_tree(str(repo.path), rev, str(dest)) is True
    assert (dest / 'a' / 'x.go').read_text() == '1\n'
    assert (dest / 'b' / 'y.go').read_text() == '2\n'


def test_export_tree_limited_to_the_given_paths(repo, tmp_path):
    rev = repo.commit({'a/x.go': '1\n', 'b/y.go': '2\n'})
    dest = tmp_path / 'out'
    dest.mkdir()
    assert risk_tools.export_tree(str(repo.path), rev, str(dest), ('a',)) is True
    assert (dest / 'a' / 'x.go').exists()
    assert not (dest / 'b').exists()


def test_unpack_makes_a_fresh_directory_under_the_parent_for_each_call(repo, tmp_path):
    rev = repo.commit({'a/x.go': '1\n'})
    parent = tmp_path / 'work'
    parent.mkdir()
    first = risk_tools.unpack(str(repo.path), rev, str(parent))
    second = risk_tools.unpack(str(repo.path), rev, str(parent), ('a',))
    assert first != second
    assert os.path.dirname(first) == str(parent) == os.path.dirname(second)
    assert os.path.isfile(os.path.join(first, 'a', 'x.go'))
    assert os.path.isfile(os.path.join(second, 'a', 'x.go'))


def test_export_tree_reports_an_unknown_revision_as_failure(repo, tmp_path):
    repo.commit({'a.txt': 'x\n'})
    assert risk_tools.export_tree(str(repo.path), 'nosuchrev', str(tmp_path)) is False


def test_export_tree_reports_an_unusable_destination_as_failure(repo, tmp_path):
    rev = repo.commit({'a.txt': 'x\n'})
    assert risk_tools.export_tree(str(repo.path), rev, str(tmp_path / 'absent')) is False
