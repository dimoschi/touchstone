import json
import os

import parse_python


def test_normrel_absolute_path_resolves_relative_to_root(tmp_path):
    root = tmp_path
    abs_path = str(root / "pkg" / "mod.py")
    assert parse_python.normrel(abs_path, str(root)) == os.path.normpath("pkg/mod.py")


def test_normrel_absolute_path_value_error_falls_back_to_normpath(monkeypatch, tmp_path):
    def boom(*_a, **_k):
        raise ValueError("no common drive")

    monkeypatch.setattr(os.path, "relpath", boom)
    abs_path = str(tmp_path / "mod.py")
    assert parse_python.normrel(abs_path, str(tmp_path)) == os.path.normpath(abs_path)


def test_normrel_relative_path_is_normalized():
    assert parse_python.normrel("a/./b.py", "/whatever") == os.path.normpath("a/./b.py")


def test_load_coverage_missing_file_returns_empty(tmp_path):
    assert parse_python.load_coverage(str(tmp_path / "nope.json"), str(tmp_path)) == {}


def test_load_coverage_invalid_json_returns_empty(tmp_path):
    bad = tmp_path / "cov.json"
    bad.write_text("{not json")
    assert parse_python.load_coverage(str(bad), str(tmp_path)) == {}


def test_load_coverage_skips_incomplete_function_entries(tmp_path):
    cov = tmp_path / "cov.json"
    cov.write_text(json.dumps({
        "files": {
            "mod.py": {
                "functions": {
                    "f": {"start_line": 3, "summary": {"percent_covered": 80.0}},
                    "g": {"summary": {"percent_covered": 50.0}},
                    "h": {"start_line": 9, "summary": {}},
                }
            }
        }
    }))
    out = parse_python.load_coverage(str(cov), str(tmp_path))
    assert out == {"mod.py": {3: 80.0}}


def test_load_radon_missing_file_returns_empty(tmp_path):
    assert parse_python.load_radon(str(tmp_path / "nope.json"), str(tmp_path)) == []


def test_load_radon_invalid_json_returns_empty(tmp_path):
    bad = tmp_path / "radon.json"
    bad.write_text("not json")
    assert parse_python.load_radon(str(bad), str(tmp_path)) == []


def test_load_radon_filters_type_and_joins_classname(tmp_path):
    radon = tmp_path / "radon.json"
    radon.write_text(json.dumps({
        "mod.py": [
            {"type": "function", "name": "f", "complexity": 2, "lineno": 1},
            {"type": "method", "name": "m", "classname": "C", "complexity": 3, "lineno": 5},
            {"type": "class", "name": "C", "complexity": 1, "lineno": 5},
        ]
    }))
    out = parse_python.load_radon(str(radon), str(tmp_path))
    assert ("mod.py", "f", 2, 1) in out
    assert ("mod.py", "C.m", 3, 5) in out
    assert len(out) == 2


def test_crap_formula():
    assert parse_python.crap(0, 100) == 0
    assert round(parse_python.crap(5, 0), 4) == 5 ** 2 + 5


def test_main_returns_early_when_nothing_changed(monkeypatch, capsys):
    monkeypatch.setenv("CRAP_CHANGED_FILES", "")
    monkeypatch.setattr("sys.argv", ["parse_python.py", "radon.json", "cov.json"])
    assert parse_python.main() == 0
    assert capsys.readouterr().out == ""


def test_main_emits_rows_for_changed_files_only(monkeypatch, tmp_path, capsys):
    radon = tmp_path / "radon.json"
    cov = tmp_path / "cov.json"
    radon.write_text(json.dumps({
        "mod.py": [{"type": "function", "name": "f", "complexity": 2, "lineno": 1}],
        "other.py": [{"type": "function", "name": "g", "complexity": 2, "lineno": 1}],
    }))
    cov.write_text(json.dumps({
        "files": {
            "mod.py": {"functions": {"f": {"start_line": 1, "summary": {"percent_covered": 100.0}}}}
        }
    }))
    monkeypatch.setenv("CRAP_REPO_ROOT", str(tmp_path))
    monkeypatch.setenv("CRAP_CHANGED_FILES", "mod.py\n")
    monkeypatch.setattr("sys.argv", ["parse_python.py", str(radon), str(cov)])
    assert parse_python.main() == 0
    out = capsys.readouterr().out
    assert out == "mod.py::f\t2\t100.0\t2.0\n"
