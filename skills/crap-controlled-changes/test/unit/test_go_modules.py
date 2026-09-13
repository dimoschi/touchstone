import io
import subprocess

import go_modules


def _git_repo(tmp_path):
    subprocess.run(["git", "init", "-q", str(tmp_path)], check=True)
    return tmp_path


def _write(path, text=""):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)


def _add(root, *rel_paths):
    subprocess.run(["git", "-C", str(root), "add", *rel_paths], check=True)


def test_module_dirs_finds_root_and_nested_tracked_go_mod(tmp_path):
    root = _git_repo(tmp_path)
    _write(root / "go.mod", "module root\n")
    _write(root / "svc" / "go.mod", "module svc\n")
    _add(root, "go.mod", "svc/go.mod")
    assert go_modules.module_dirs(str(root)) == {".", "svc"}


def test_module_dirs_root_go_mod_counts_even_when_untracked(tmp_path):
    root = _git_repo(tmp_path)
    _write(root / "svc" / "go.mod", "module svc\n")
    _add(root, "svc/go.mod")
    _write(root / "go.mod", "module root\n")  # left untracked on purpose
    assert go_modules.module_dirs(str(root)) == {".", "svc"}


def test_owning_module_walks_up_to_nearest_go_mod(tmp_path):
    moddirs = {".", "svc"}
    assert go_modules.owning_module("svc/pkg/a.go", moddirs, str(tmp_path)) == "svc"
    assert go_modules.owning_module("top.go", moddirs, str(tmp_path)) == "."


def test_owning_module_falls_back_to_root_when_no_ancestor_matches():
    assert go_modules.owning_module("a/b/c.go", set(), "/nonexistent") == "."


def test_owning_module_detects_untracked_go_mod_on_disk(tmp_path):
    _write(tmp_path / "svc" / "go.mod", "module svc\n")
    got = go_modules.owning_module("svc/pkg/a.go", set(), str(tmp_path))
    assert got == "svc"


def test_modpath_reads_module_line(tmp_path):
    _write(tmp_path / "go.mod", "module example.com/foo\n\ngo 1.22\n")
    assert go_modules.modpath(str(tmp_path), ".") == "example.com/foo"


def test_modpath_missing_file_returns_empty(tmp_path):
    assert go_modules.modpath(str(tmp_path), "nope") == ""


def test_local_replacements_single_line_and_block_and_comments(tmp_path):
    _write(tmp_path / "go.mod", (
        "module example.com/foo\n"
        "replace example.com/bar => ./bar\n"
        "replace (\n"
        "    example.com/baz => ../baz\n"
        "    example.com/pub => v1.0.0\n"
        ")\n"
        "// replace example.com/commented => ./commented\n"
    ))
    deps = go_modules.local_replacements(str(tmp_path), ".")
    assert deps == {"bar", "../baz"}


def test_local_replacements_line_without_arrow_is_ignored(tmp_path):
    _write(tmp_path / "go.mod", (
        "module example.com/foo\n"
        "replace (\n"
        "    example.com/nope\n"
        "    example.com/bar => ./bar\n"
        ")\n"
    ))
    assert go_modules.local_replacements(str(tmp_path), ".") == {"bar"}


def test_local_replacements_missing_file_returns_empty_set(tmp_path):
    assert go_modules.local_replacements(str(tmp_path), "nope") == set()


def test_local_replacements_replace_to_dot_normalizes(tmp_path):
    _write(tmp_path / "sub" / "go.mod", "replace example.com/x => ..\n")
    deps = go_modules.local_replacements(str(tmp_path), "sub")
    assert deps == {"."}


def test_roots_is_transitive_over_local_replaces(tmp_path):
    _write(tmp_path / "go.mod", "module root\n")
    _write(tmp_path / "a" / "go.mod", "module a\nreplace lib => ../lib\n")
    _write(tmp_path / "b" / "go.mod", "module b\nreplace a => ../a\n")
    _write(tmp_path / "lib" / "go.mod", "module lib\n")
    root = _git_repo(tmp_path)
    _add(root, "go.mod", "a/go.mod", "b/go.mod", "lib/go.mod")
    assert go_modules.roots(str(tmp_path), "lib") == {"lib", "a", "b"}


def test_cmd_group_emits_sorted_tsv_rows(monkeypatch, tmp_path, capsys):
    root = _git_repo(tmp_path)
    _write(root / "svc" / "go.mod", "module svc\n")
    _add(root, "svc/go.mod")
    monkeypatch.setattr("sys.stdin", io.StringIO("svc/pkg/b.go\nsvc/pkg/a.go\n"))
    go_modules.cmd_group(str(root))
    out = capsys.readouterr().out.splitlines()
    assert out == [
        "svc\tsvc/pkg\tsvc/pkg/a.go\t./pkg/a.go",
        "svc\tsvc/pkg\tsvc/pkg/b.go\t./pkg/b.go",
    ]


def test_cmd_group_skips_blank_lines(monkeypatch, tmp_path, capsys):
    root = _git_repo(tmp_path)
    monkeypatch.setattr("sys.stdin", io.StringIO("\n  \ntop.go\n"))
    go_modules.cmd_group(str(root))
    out = capsys.readouterr().out.splitlines()
    assert out == [".\t.\ttop.go\t./top.go"]


def test_main_no_args_exits_with_usage(monkeypatch):
    monkeypatch.setattr("sys.argv", ["go_modules.py"])
    try:
        go_modules.main(["go_modules.py"])
        assert False, "expected SystemExit"
    except SystemExit as exc:
        assert exc.code == go_modules.__doc__


def test_main_unknown_command_exits(monkeypatch, tmp_path):
    root = _git_repo(tmp_path)
    monkeypatch.chdir(root)
    try:
        go_modules.main(["go_modules.py", "bogus"])
        assert False, "expected SystemExit"
    except SystemExit as exc:
        assert "unknown command" in str(exc.code)


def test_main_roots_requires_moddir_arg(monkeypatch, tmp_path):
    root = _git_repo(tmp_path)
    monkeypatch.chdir(root)
    try:
        go_modules.main(["go_modules.py", "roots"])
        assert False, "expected SystemExit"
    except SystemExit as exc:
        assert "usage: go_modules.py roots" in str(exc.code)


def test_main_modpath_requires_moddir_arg(monkeypatch, tmp_path):
    root = _git_repo(tmp_path)
    monkeypatch.chdir(root)
    try:
        go_modules.main(["go_modules.py", "modpath"])
        assert False, "expected SystemExit"
    except SystemExit as exc:
        assert "usage: go_modules.py modpath" in str(exc.code)


def test_main_modpath_prints_module_path(monkeypatch, tmp_path, capsys):
    root = _git_repo(tmp_path)
    _write(root / "go.mod", "module example.com/x\n")
    monkeypatch.chdir(root)
    assert go_modules.main(["go_modules.py", "modpath", "."]) == 0
    assert capsys.readouterr().out == "example.com/x\n"


def test_main_roots_prints_sorted_roots(monkeypatch, tmp_path, capsys):
    _write(tmp_path / "go.mod", "module root\n")
    _write(tmp_path / "a" / "go.mod", "module a\nreplace lib => ../lib\n")
    _write(tmp_path / "lib" / "go.mod", "module lib\n")
    root = _git_repo(tmp_path)
    _add(root, "go.mod", "a/go.mod", "lib/go.mod")
    monkeypatch.chdir(root)
    assert go_modules.main(["go_modules.py", "roots", "lib"]) == 0
    assert capsys.readouterr().out == "a\nlib\n"


def test_main_group_reads_stdin_and_prints(monkeypatch, tmp_path, capsys):
    root = _git_repo(tmp_path)
    monkeypatch.chdir(root)
    monkeypatch.setattr("sys.stdin", io.StringIO("top.go\n"))
    assert go_modules.main(["go_modules.py", "group"]) == 0
    assert capsys.readouterr().out == ".\t.\ttop.go\t./top.go\n"


def test_repo_root_outside_git_repo_exits(monkeypatch, tmp_path):
    monkeypatch.chdir(tmp_path)
    try:
        go_modules.repo_root()
        assert False, "expected SystemExit"
    except SystemExit as exc:
        assert "not inside a git repo" in str(exc.code)
