import io
import os

import incremental_scope


def test_read_lines_strips_and_drops_blank_lines():
    assert incremental_scope.read_lines(io.StringIO("a\n\n b \n")) == ["a", "b"]


def test_closure_non_go_returns_full_candidate_set():
    assert incremental_scope.closure("py", ["a.py", "b.py"], {"c.py"}) == {"a.py", "b.py"}


def test_closure_go_restricts_to_directories_of_invalidated_files():
    candidates = ["pkg/a.go", "pkg/b.go", "other/c.go"]
    invalidated = {"pkg/z_test.go"}
    assert incremental_scope.closure("go", candidates, invalidated) == {"pkg/a.go", "pkg/b.go"}


def _write(path, text=""):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)


def test_main_go_pulls_in_package_siblings_when_a_test_changed(monkeypatch, tmp_path, capsys):
    a = tmp_path / "pkg" / "a.go"
    b = tmp_path / "pkg" / "b.go"
    _write(a)
    _write(b)
    invalidated = tmp_path / "invalidated.txt"
    invalidated.write_text(f"{tmp_path / 'pkg' / 'z_test.go'}\n")

    monkeypatch.setattr("sys.argv", ["incremental_scope.py", "go", str(invalidated)])
    monkeypatch.setattr("sys.stdin", io.StringIO(f"{a}\n{b}\n"))
    incremental_scope.main()
    out = set(capsys.readouterr().out.splitlines())
    assert out == {str(a), str(b)}


def test_main_non_go_falls_back_to_full_candidate_list(monkeypatch, tmp_path, capsys):
    a = tmp_path / "a.py"
    b = tmp_path / "b.py"
    _write(a)
    _write(b)
    invalidated = tmp_path / "invalidated.txt"
    invalidated.write_text(f"{tmp_path / 'unrelated_test.py'}\n")

    monkeypatch.setattr("sys.argv", ["incremental_scope.py", "py", str(invalidated)])
    monkeypatch.setattr("sys.stdin", io.StringIO(f"{a}\n{b}\n"))
    incremental_scope.main()
    out = set(capsys.readouterr().out.splitlines())
    assert out == {str(a), str(b)}


def test_main_drops_candidates_that_no_longer_exist(monkeypatch, tmp_path, capsys):
    a = tmp_path / "a.php"
    _write(a)
    missing = tmp_path / "gone.php"
    invalidated = tmp_path / "invalidated.txt"
    invalidated.write_text(f"{a}\n")

    monkeypatch.setattr("sys.argv", ["incremental_scope.py", "php", str(invalidated)])
    monkeypatch.setattr("sys.stdin", io.StringIO(f"{a}\n{missing}\n"))
    incremental_scope.main()
    out = capsys.readouterr().out.splitlines()
    assert out == [str(a)]
