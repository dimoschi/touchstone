import json
import subprocess
from types import SimpleNamespace

import parse_mutago


def test_main_func_spans_empty_paths_returns_empty_dict():
    assert parse_mutago.main_func_spans([]) == {}


def test_main_func_spans_parses_tsv_rows_and_skips_malformed(monkeypatch):
    def fake_run(*_a, **_k):
        return SimpleNamespace(stdout="cmd/x/main.go\t10\t20\nmalformed row\n")
    monkeypatch.setattr(parse_mutago.subprocess, "run", fake_run)
    assert parse_mutago.main_func_spans(["cmd/x/main.go"]) == {"cmd/x/main.go": (10, 20)}


def test_main_func_spans_subprocess_failure_exempts_nothing(monkeypatch, capsys):
    def fake_run(*_a, **_k):
        raise subprocess.CalledProcessError(1, "go")
    monkeypatch.setattr(parse_mutago.subprocess, "run", fake_run)
    assert parse_mutago.main_func_spans(["cmd/x/main.go"]) == {}
    assert "cannot locate func main" in capsys.readouterr().err


def _write_report(tmp_path, mutants):
    p = tmp_path / "report.json"
    p.write_text(json.dumps({"mutants": mutants}))
    return p


def test_main_filters_by_allowed_files_and_strips_dot_slash(monkeypatch, tmp_path, capsys):
    report = _write_report(tmp_path, [
        {"file": "./a.go", "line": 5, "mutator": "M1", "id": "id1"},
        {"file": "./b.go", "line": 5, "mutator": "M2", "id": "id2"},
    ])
    monkeypatch.setattr(parse_mutago, "main_func_spans", lambda paths: {})
    monkeypatch.setattr("sys.argv", ["parse_mutago.py", str(report), "", "a.go"])
    parse_mutago.main()
    out = capsys.readouterr().out
    assert "a.go:5" in out
    assert "b.go" not in out


def test_main_no_allowed_files_reports_everything(monkeypatch, tmp_path, capsys):
    report = _write_report(tmp_path, [
        {"file": "a.go", "line": 5, "mutator": "M1", "id": "id1", "description": "desc", "kill_hint": "hint"},
    ])
    monkeypatch.setattr(parse_mutago, "main_func_spans", lambda paths: {})
    monkeypatch.setattr("sys.argv", ["parse_mutago.py", str(report)])
    parse_mutago.main()
    out = capsys.readouterr().out
    assert "SURVIVED  id=id1" in out
    assert "desc" in out
    assert "kill hint: hint" in out


def test_main_prefixes_file_path(monkeypatch, tmp_path, capsys):
    report = _write_report(tmp_path, [{"file": "a.go", "line": 1, "mutator": "M1", "id": "id1"}])
    monkeypatch.setattr(parse_mutago, "main_func_spans", lambda paths: {})
    monkeypatch.setattr("sys.argv", ["parse_mutago.py", str(report), "svc/"])
    parse_mutago.main()
    assert "svc/a.go:1" in capsys.readouterr().out


def test_main_exempts_mutants_inside_main_span(monkeypatch, tmp_path, capsys):
    report = _write_report(tmp_path, [
        {"file": "main.go", "line": 12, "mutator": "M1", "id": "id1"},
        {"file": "main.go", "line": 99, "mutator": "M2", "id": "id2"},
    ])
    monkeypatch.setattr(parse_mutago, "main_func_spans", lambda paths: {"main.go": (10, 20)})
    monkeypatch.setattr("sys.argv", ["parse_mutago.py", str(report)])
    parse_mutago.main()
    out, err = capsys.readouterr()
    assert "id1" not in out
    assert "id2" in out
    assert "1 mutant(s) exempted, inside func main()" in err
    assert "main.go:12" in err


def test_main_total_flag_prints_total_mutants_count(monkeypatch, tmp_path, capsys):
    summary = tmp_path / "mutago-summary.json"
    summary.write_text(json.dumps({"totalMutantsCount": 5, "killedCount": 5}))
    monkeypatch.setattr("sys.argv", ["parse_mutago.py", "--total", str(summary)])
    parse_mutago.main()
    assert capsys.readouterr().out == "5\n"


def test_main_total_flag_defaults_to_zero_without_the_field(monkeypatch, tmp_path, capsys):
    summary = tmp_path / "mutago-summary.json"
    summary.write_text(json.dumps({}))
    monkeypatch.setattr("sys.argv", ["parse_mutago.py", "--total", str(summary)])
    parse_mutago.main()
    assert capsys.readouterr().out == "0\n"


def test_main_exempt_count_flag_counts_only_mutants_inside_main_span(monkeypatch, tmp_path, capsys):
    report = _write_report(tmp_path, [
        {"file": "main.go", "line": 12, "mutator": "M1", "id": "id1"},
        {"file": "main.go", "line": 99, "mutator": "M2", "id": "id2"},
    ])
    monkeypatch.setattr(parse_mutago, "main_func_spans", lambda paths: {"main.go": (10, 20)})
    monkeypatch.setattr("sys.argv", ["parse_mutago.py", "--exempt-count", str(report)])
    parse_mutago.main()
    assert capsys.readouterr().out == "1\n"


def test_main_exempt_count_flag_zero_when_nothing_in_span(monkeypatch, tmp_path, capsys):
    report = _write_report(tmp_path, [{"file": "a.go", "line": 5, "mutator": "M1", "id": "id1"}])
    monkeypatch.setattr(parse_mutago, "main_func_spans", lambda paths: {})
    monkeypatch.setattr("sys.argv", ["parse_mutago.py", "--exempt-count", str(report)])
    parse_mutago.main()
    assert capsys.readouterr().out == "0\n"


def test_main_handles_missing_or_non_numeric_line(monkeypatch, tmp_path, capsys):
    report = _write_report(tmp_path, [{"file": "a.go", "line": None, "mutator": "M1", "id": "id1"}])
    monkeypatch.setattr(parse_mutago, "main_func_spans", lambda paths: {"a.go": (1, 5)})
    monkeypatch.setattr("sys.argv", ["parse_mutago.py", str(report)])
    parse_mutago.main()
    out = capsys.readouterr().out
    assert "SURVIVED  id=id1" in out


def test_collect_rows_defaults_missing_file_key_to_question_mark():
    rows = parse_mutago.collect_rows({"mutants": [{"line": 1, "id": "id1"}]}, "", set())
    assert rows == [("?", 1, {"line": 1, "id": "id1"})]


def test_collect_rows_continues_past_disallowed_file_to_a_later_allowed_one():
    doc = {"mutants": [
        {"file": "skip.go", "line": 1, "id": "id1"},
        {"file": "keep.go", "line": 2, "id": "id2"},
    ]}
    rows = parse_mutago.collect_rows(doc, "", {"keep.go"})
    assert [m["id"] for _, _, m in rows] == ["id2"]


def test_print_survivor_defaults_missing_line_to_question_mark(capsys):
    parse_mutago.print_survivor("f.go", {"mutator": "M1", "id": "id1"})
    assert capsys.readouterr().out.startswith("f.go:?")


def test_print_survivor_defaults_missing_mutator_to_question_mark(capsys):
    parse_mutago.print_survivor("f.go", {"line": 5, "id": "id1"})
    fields = capsys.readouterr().out.split()
    assert fields[1] == "?"


def test_print_survivor_reads_the_real_mutator_value(capsys):
    parse_mutago.print_survivor("f.go", {"line": 5, "mutator": "RealMutator", "id": "id1"})
    fields = capsys.readouterr().out.split()
    assert fields[1] == "RealMutator"


def test_print_survivor_defaults_missing_id_to_empty_string(capsys):
    parse_mutago.print_survivor("f.go", {"line": 5, "mutator": "M1"})
    assert capsys.readouterr().out.rstrip("\n").endswith("id=")


def test_in_span_includes_both_boundary_lines():
    assert parse_mutago.in_span((10, 20), 10) is True
    assert parse_mutago.in_span((10, 20), 20) is True


def test_split_exempt_passes_deduped_sorted_disk_paths_to_main_func_spans(monkeypatch):
    doc = {"mutants": [
        {"file": "b.go", "line": 1, "id": "id1"},
        {"file": "a.go", "line": 2, "id": "id2"},
        {"file": "a.go", "line": 3, "id": "id3"},
    ]}
    captured = {}

    def fake_spans(paths):
        captured["paths"] = paths
        return {}

    monkeypatch.setattr(parse_mutago, "main_func_spans", fake_spans)
    parse_mutago._split_exempt(doc, "", set())
    assert captured["paths"] == ["a.go", "b.go"]


def test_split_exempt_defaults_missing_mutator_to_question_mark(monkeypatch):
    doc = {"mutants": [{"file": "main.go", "line": 12, "id": "id1"}]}
    monkeypatch.setattr(parse_mutago, "main_func_spans", lambda paths: {"main.go": (10, 20)})
    _, exempt = parse_mutago._split_exempt(doc, "", set())
    assert exempt[0].split()[1] == "?"


def test_split_exempt_reads_the_real_mutator_value(monkeypatch):
    doc = {"mutants": [{"file": "main.go", "line": 12, "mutator": "RealMutator", "id": "id1"}]}
    monkeypatch.setattr(parse_mutago, "main_func_spans", lambda paths: {"main.go": (10, 20)})
    _, exempt = parse_mutago._split_exempt(doc, "", set())
    assert exempt[0].split()[1] == "RealMutator"


def test_exempt_count_passes_the_allowed_set_through(monkeypatch, tmp_path):
    report = _write_report(tmp_path, [
        {"file": "a.go", "line": 1, "id": "id1"},
        {"file": "b.go", "line": 1, "id": "id2"},
    ])
    monkeypatch.setattr(parse_mutago, "main_func_spans", lambda paths: {"a.go": (1, 5), "b.go": (1, 5)})
    assert parse_mutago.exempt_count(str(report), "", {"a.go"}) == 1


def test_path_prefix_allowed_strips_leading_dot_slash():
    _, _, allowed = parse_mutago._path_prefix_allowed(["report.json", "", "./sub/x.go"])
    assert allowed == {"sub/x.go"}
