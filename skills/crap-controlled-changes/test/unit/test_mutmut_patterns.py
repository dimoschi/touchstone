import io
import subprocess
from types import SimpleNamespace

import mutmut_patterns


def _fake_run(diff_output):
    def run(*_args, **_kwargs):
        return SimpleNamespace(stdout=diff_output)
    return run


def test_changed_ranges_parses_hunk_with_explicit_count(monkeypatch):
    monkeypatch.setattr(mutmut_patterns.subprocess, "run", _fake_run("@@ -1,1 +3,2 @@\n"))
    assert mutmut_patterns.changed_ranges("base", "f.py") == [(3, 4)]


def test_changed_ranges_defaults_count_to_one_line(monkeypatch):
    monkeypatch.setattr(mutmut_patterns.subprocess, "run", _fake_run("@@ -1 +5 @@\n"))
    assert mutmut_patterns.changed_ranges("base", "f.py") == [(5, 5)]


def test_changed_ranges_ignores_non_hunk_lines(monkeypatch):
    monkeypatch.setattr(mutmut_patterns.subprocess, "run", _fake_run("diff --git a b\n@@ -1 +1 @@\n+x\n"))
    assert mutmut_patterns.changed_ranges("base", "f.py") == [(1, 1)]


def test_module_path_plain():
    assert mutmut_patterns.module_path("pkg/mod.py") == "pkg.mod"


def test_module_path_strips_src_prefix():
    assert mutmut_patterns.module_path("src/pkg/mod.py") == "pkg.mod"


def test_module_path_collapses_dunder_init():
    assert mutmut_patterns.module_path("pkg/__init__.py") == "pkg"


def test_module_path_non_py_suffix_untouched():
    assert mutmut_patterns.module_path("pkg/mod") == "pkg.mod"


def test_emit_no_changed_ranges_prints_nothing(monkeypatch, tmp_path, capsys):
    monkeypatch.setattr(mutmut_patterns.subprocess, "run", _fake_run(""))
    f = tmp_path / "mod.py"
    f.write_text("def a():\n    pass\n")
    mutmut_patterns.emit(str(f), "base")
    assert capsys.readouterr().out == ""


def test_emit_prints_module_function_and_method_overlapping_changes(monkeypatch, tmp_path, capsys):
    f = tmp_path / "mod.py"
    f.write_text(
        "def top():\n"
        "    pass\n"
        "\n\n"
        "class C:\n"
        "    def method(self):\n"
        "        pass\n"
        "\n\n"
        "def untouched():\n"
        "    pass\n"
    )
    # Lines 1-2 (top) and 5-6 (C.method) are changed; untouched (8-9) is not.
    monkeypatch.setattr(mutmut_patterns.subprocess, "run", _fake_run("@@ -0,0 +1,2 @@\n@@ -0,0 +5,2 @@\n"))
    mutmut_patterns.emit(str(f), "base")
    out = capsys.readouterr().out
    lines = out.splitlines()
    assert any("x_top__mutmut_*\t" in l for l in lines)
    assert any(f"x\u01c1C\u01c1method__mutmut_*\t" in l for l in lines)
    assert not any("untouched" in l for l in lines)


def test_main_reads_paths_from_stdin(monkeypatch, tmp_path, capsys):
    f = tmp_path / "mod.py"
    f.write_text("def a():\n    pass\n")
    monkeypatch.setattr(mutmut_patterns.subprocess, "run", _fake_run("@@ -0,0 +1,2 @@\n"))
    monkeypatch.setattr("sys.argv", ["mutmut_patterns.py", "base"])
    monkeypatch.setattr("sys.stdin", io.StringIO(f"{f}\n\n"))
    mutmut_patterns.main()
    assert "x_a__mutmut_*" in capsys.readouterr().out
