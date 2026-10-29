import json
import os

import pytest

import parse_python


def spans(path, *rows):
    """Write crapper_spans.py-shaped rows: (file, name, complexity, first line)."""
    path.write_text("".join(f"{file}\t{line}\t{line + 4}\t{cc}\t{name}\t\n"
                            for file, name, cc, line in rows))
    return path


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


def test_load_coverage_without_a_files_key_returns_empty(tmp_path):
    cov = tmp_path / "cov.json"
    cov.write_text("{}")
    assert parse_python.load_coverage(str(cov), str(tmp_path)) == {}


def test_load_coverage_file_entry_without_a_functions_map(tmp_path):
    cov = tmp_path / "cov.json"
    cov.write_text(json.dumps({"files": {"mod.py": {}}}))
    assert parse_python.load_coverage(str(cov), str(tmp_path)) == {"mod.py": {}}


def test_load_coverage_skips_a_function_entry_without_a_summary(tmp_path):
    cov = tmp_path / "cov.json"
    cov.write_text(json.dumps({
        "files": {"mod.py": {"functions": {"f": {"start_line": 3}}}}
    }))
    assert parse_python.load_coverage(str(cov), str(tmp_path)) == {"mod.py": {}}


def test_load_spans_reads_each_function_with_its_class_qualified_name(tmp_path):
    rows = spans(tmp_path / "spans.tsv", ("mod.py", "f", 2, 1), ("mod.py", "C.m", 3, 5))
    assert parse_python.load_spans(str(rows), str(tmp_path)) == [
        ("mod.py", "f", 2, 1), ("mod.py", "C.m", 3, 5)]


def test_load_spans_normalizes_the_path_against_the_repo_root(tmp_path):
    rows = spans(tmp_path / "spans.tsv", (str(tmp_path / "pkg" / "mod.py"), "f", 2, 1))
    assert parse_python.load_spans(str(rows), str(tmp_path)) == [
        (os.path.normpath("pkg/mod.py"), "f", 2, 1)]


def test_load_spans_of_no_functions_is_empty(tmp_path):
    (tmp_path / "spans.tsv").write_text("")
    assert parse_python.load_spans(str(tmp_path / "spans.tsv"), str(tmp_path)) == []


def test_load_spans_of_a_missing_file_is_an_error_not_an_empty_list(tmp_path):
    with pytest.raises(FileNotFoundError):
        parse_python.load_spans(str(tmp_path / "nope.tsv"), str(tmp_path))


def test_crap_formula():
    assert parse_python.crap(0, 100) == 0
    assert round(parse_python.crap(5, 0), 4) == 5 ** 2 + 5


def test_main_returns_early_when_nothing_changed(monkeypatch, capsys):
    monkeypatch.setenv("CRAP_CHANGED_FILES", "")
    monkeypatch.setattr("sys.argv", ["parse_python.py", "spans.tsv", "cov.json"])
    assert parse_python.main() == 0
    assert capsys.readouterr().out == ""


def test_main_emits_rows_for_changed_files_only(monkeypatch, tmp_path, capsys):
    rows = tmp_path / "spans.tsv"
    cov = tmp_path / "cov.json"
    spans(rows, ("mod.py", "f", 2, 1), ("other.py", "g", 2, 1))
    cov.write_text(json.dumps({
        "files": {
            "mod.py": {"functions": {"f": {"start_line": 1, "summary": {"percent_covered": 100.0}}}}
        }
    }))
    monkeypatch.setenv("CRAP_REPO_ROOT", str(tmp_path))
    monkeypatch.setenv("CRAP_CHANGED_FILES", "mod.py\n")
    monkeypatch.setattr("sys.argv", ["parse_python.py", str(rows), str(cov)])
    assert parse_python.main() == 0
    out = capsys.readouterr().out
    assert out == "mod.py::f\t2\t100.0\t2.0\n"


def test_load_coverage_resolves_relative_key_against_cov_root(tmp_path):
    repo_root = tmp_path
    cov_root = tmp_path / "proj"
    cov = tmp_path / "cov.json"
    cov.write_text(json.dumps({
        "files": {
            "src/mod.py": {"functions": {"f": {"start_line": 1, "summary": {"percent_covered": 100.0}}}}
        }
    }))
    out = parse_python.load_coverage(str(cov), str(repo_root), str(cov_root))
    assert out == {os.path.normpath("proj/src/mod.py"): {1: 100.0}}


def test_load_coverage_absolute_key_ignores_cov_root(tmp_path):
    repo_root = tmp_path
    cov_root = tmp_path / "proj"
    abs_path = str(repo_root / "src" / "mod.py")
    cov = tmp_path / "cov.json"
    cov.write_text(json.dumps({
        "files": {
            abs_path: {"functions": {"f": {"start_line": 1, "summary": {"percent_covered": 100.0}}}}
        }
    }))
    out = parse_python.load_coverage(str(cov), str(repo_root), str(cov_root))
    assert out == {os.path.normpath("src/mod.py"): {1: 100.0}}


def test_load_coverage_no_cov_root_behaves_as_before(tmp_path):
    cov = tmp_path / "cov.json"
    cov.write_text(json.dumps({
        "files": {
            "mod.py": {"functions": {"f": {"start_line": 1, "summary": {"percent_covered": 100.0}}}}
        }
    }))
    out = parse_python.load_coverage(str(cov), str(tmp_path))
    assert out == {"mod.py": {1: 100.0}}


def test_unmeasured_files_missing_from_coverage_is_flagged():
    changed = {"mod.py"}
    cov = {}
    blocks = [("mod.py", "f", 2, 1)]
    assert parse_python.unmeasured_files(changed, cov, blocks) == ["mod.py"]


def test_unmeasured_files_empty_function_map_is_flagged():
    changed = {"mod.py"}
    cov = {"mod.py": {}}
    blocks = [("mod.py", "f", 2, 1)]
    assert parse_python.unmeasured_files(changed, cov, blocks) == ["mod.py"]


def test_unmeasured_files_measured_at_real_zero_is_not_flagged():
    changed = {"mod.py"}
    cov = {"mod.py": {1: 0.0}}
    blocks = [("mod.py", "f", 2, 1)]
    assert parse_python.unmeasured_files(changed, cov, blocks) == []


def test_unmeasured_files_without_a_function_is_not_flagged():
    changed = {"mod.py"}
    cov = {}
    blocks = []
    assert parse_python.unmeasured_files(changed, cov, blocks) == []


def test_unmeasured_files_ignores_files_outside_changed():
    changed = {"mod.py"}
    cov = {}
    blocks = [("mod.py", "f", 2, 1), ("other.py", "g", 2, 1)]
    assert parse_python.unmeasured_files(changed, cov, blocks) == ["mod.py"]


def test_unmeasured_files_keeps_scanning_past_a_file_with_no_function():
    changed = ["noblock.py", "mod.py"]
    cov = {}
    blocks = [("mod.py", "f", 2, 1)]
    assert parse_python.unmeasured_files(changed, cov, blocks) == ["mod.py"]


def test_emit_rows_keeps_scanning_past_an_unchanged_block(capsys):
    blocks = [("other.py", "g", 3, 1), ("mod.py", "f", 2, 1)]
    parse_python._emit_rows(blocks, {"mod.py"}, set(), {"mod.py": {1: 100.0}})
    assert capsys.readouterr().out == "mod.py::f\t2\t100.0\t2.0\n"


def test_emit_rows_keeps_scanning_past_an_unmeasured_block(capsys):
    blocks = [("unmeasured.py", "g", 3, 1), ("mod.py", "f", 2, 1)]
    parse_python._emit_rows(
        blocks, {"mod.py", "unmeasured.py"}, {"unmeasured.py"}, {"mod.py": {1: 100.0}}
    )
    assert capsys.readouterr().out == "mod.py::f\t2\t100.0\t2.0\n"


def test_unmeasured_files_sorted_and_deduped():
    changed = {"b.py", "a.py"}
    cov = {}
    blocks = [("b.py", "f", 1, 1), ("b.py", "g", 1, 5), ("a.py", "h", 1, 1)]
    assert parse_python.unmeasured_files(changed, cov, blocks) == ["a.py", "b.py"]


def test_main_skips_unmeasured_file_and_still_emits_measured_rows(monkeypatch, tmp_path, capsys):
    rows = tmp_path / "spans.tsv"
    cov = tmp_path / "cov.json"
    spans(rows, ("measured.py", "f", 2, 1), ("unmeasured.py", "g", 3, 1))
    cov.write_text(json.dumps({
        "files": {
            "measured.py": {"functions": {"f": {"start_line": 1, "summary": {"percent_covered": 100.0}}}}
        }
    }))
    monkeypatch.setenv("CRAP_REPO_ROOT", str(tmp_path))
    monkeypatch.setenv("CRAP_CHANGED_FILES", "measured.py\nunmeasured.py\n")
    monkeypatch.setattr("sys.argv", ["parse_python.py", str(rows), str(cov)])
    assert parse_python.main() == 0
    out = capsys.readouterr().out
    assert out == "measured.py::f\t2\t100.0\t2.0\n"


def test_main_writes_unmeasured_paths_to_out_file(monkeypatch, tmp_path, capsys):
    rows = tmp_path / "spans.tsv"
    cov = tmp_path / "cov.json"
    out_path = tmp_path / "unmeasured.txt"
    spans(rows, ("unmeasured.py", "g", 3, 1))
    cov.write_text(json.dumps({"files": {}}))
    monkeypatch.setenv("CRAP_REPO_ROOT", str(tmp_path))
    monkeypatch.setenv("CRAP_CHANGED_FILES", "unmeasured.py\n")
    monkeypatch.setattr(
        "sys.argv",
        ["parse_python.py", str(rows), str(cov), "--unmeasured-out", str(out_path)],
    )
    assert parse_python.main() == 0
    assert out_path.read_text() == "unmeasured.py\n"


def test_main_writes_nothing_to_out_file_when_all_measured(monkeypatch, tmp_path, capsys):
    rows = tmp_path / "spans.tsv"
    cov = tmp_path / "cov.json"
    out_path = tmp_path / "unmeasured.txt"
    spans(rows, ("measured.py", "f", 2, 1))
    cov.write_text(json.dumps({
        "files": {
            "measured.py": {"functions": {"f": {"start_line": 1, "summary": {"percent_covered": 100.0}}}}
        }
    }))
    monkeypatch.setenv("CRAP_REPO_ROOT", str(tmp_path))
    monkeypatch.setenv("CRAP_CHANGED_FILES", "measured.py\n")
    monkeypatch.setattr(
        "sys.argv",
        ["parse_python.py", str(rows), str(cov), "--unmeasured-out", str(out_path)],
    )
    assert parse_python.main() == 0
    assert out_path.read_text() == ""


def test_main_zero_fill_unmeasured_emits_rows_at_zero_instead_of_dropping(monkeypatch, tmp_path, capsys):
    rows = tmp_path / "spans.tsv"
    cov = tmp_path / "cov.json"
    out_path = tmp_path / "unmeasured.txt"
    spans(rows, ("measured.py", "f", 2, 1), ("unmeasured.py", "g", 3, 1))
    cov.write_text(json.dumps({
        "files": {
            "measured.py": {"functions": {"f": {"start_line": 1, "summary": {"percent_covered": 100.0}}}}
        }
    }))
    monkeypatch.setenv("CRAP_REPO_ROOT", str(tmp_path))
    monkeypatch.setenv("CRAP_CHANGED_FILES", "measured.py\nunmeasured.py\n")
    monkeypatch.setattr(
        "sys.argv",
        ["parse_python.py", str(rows), str(cov), "--zero-fill-unmeasured",
         "--unmeasured-out", str(out_path)],
    )
    assert parse_python.main() == 0
    out = capsys.readouterr().out
    assert out == "measured.py::f\t2\t100.0\t2.0\nunmeasured.py::g\t3\t0.0\t12.0\n"
    # Still reported as unmeasured for the caller's own "HEAD never measured
    # this file" warning, even though a row was emitted for it here.
    assert out_path.read_text() == "unmeasured.py\n"


def test_main_without_crap_changed_files_set_writes_no_unmeasured_file(monkeypatch, tmp_path, capsys):
    rows = tmp_path / "spans.tsv"
    cov = tmp_path / "cov.json"
    out_path = tmp_path / "unmeasured.txt"
    spans(rows, ("mod.py", "f", 2, 1))
    cov.write_text(json.dumps({"files": {}}))
    monkeypatch.delenv("CRAP_CHANGED_FILES", raising=False)
    monkeypatch.setenv("CRAP_REPO_ROOT", str(tmp_path))
    monkeypatch.setattr(
        "sys.argv",
        ["parse_python.py", str(rows), str(cov), "--unmeasured-out", str(out_path)],
    )
    assert parse_python.main() == 0
    assert capsys.readouterr().out == ""
    # Nothing was measured and nothing was asked about, so the caller must not
    # be handed an unmeasured list at all.
    assert not out_path.exists()


def test_main_resolves_absolute_span_paths_against_the_repo_root(monkeypatch, tmp_path, capsys):
    rows = tmp_path / "spans.tsv"
    cov = tmp_path / "cov.json"
    spans(rows, (str(tmp_path / "mod.py"), "f", 2, 1))
    cov.write_text(json.dumps({
        "files": {
            "mod.py": {"functions": {"f": {"start_line": 1, "summary": {"percent_covered": 100.0}}}}
        }
    }))
    monkeypatch.setenv("CRAP_REPO_ROOT", str(tmp_path))
    monkeypatch.setenv("CRAP_CHANGED_FILES", "mod.py\n")
    monkeypatch.setattr("sys.argv", ["parse_python.py", str(rows), str(cov)])
    assert parse_python.main() == 0
    assert capsys.readouterr().out == "mod.py::f\t2\t100.0\t2.0\n"


def test_main_uses_crap_cov_root_env_to_join_subproject_keys(monkeypatch, tmp_path, capsys):
    rows = tmp_path / "spans.tsv"
    cov = tmp_path / "cov.json"
    spans(rows, ("proj/mod.py", "f", 2, 1))
    cov.write_text(json.dumps({
        "files": {
            "mod.py": {"functions": {"f": {"start_line": 1, "summary": {"percent_covered": 100.0}}}}
        }
    }))
    monkeypatch.setenv("CRAP_REPO_ROOT", str(tmp_path))
    monkeypatch.setenv("CRAP_COV_ROOT", str(tmp_path / "proj"))
    monkeypatch.setenv("CRAP_CHANGED_FILES", "proj/mod.py\n")
    monkeypatch.setattr("sys.argv", ["parse_python.py", str(rows), str(cov)])
    assert parse_python.main() == 0
    out = capsys.readouterr().out
    assert out == os.path.normpath("proj/mod.py") + "::f\t2\t100.0\t2.0\n"
