import json
import os

import parse_infection


def test_rows_with_no_root_uses_original_path_verbatim(capsys):
    entries = [{
        "mutator": {"originalFilePath": "/abs/path/File.php", "originalStartLine": 10, "mutatorName": "Foo"},
        "diff": "--- orig\n+++ new\n-old line\n+new line\n context line\n",
    }]
    parse_infection.rows(entries, "")
    out = capsys.readouterr().out.splitlines()
    assert out[0].startswith("/abs/path/File.php:10")
    assert "SURVIVED  id=Foo@/abs/path/File.php:10" in out[0]
    assert out[1] == "    -old line"
    assert out[2] == "    +new line"
    assert len(out) == 3


def test_rows_missing_original_file_path_defaults_to_question_mark(capsys):
    parse_infection.rows([{"mutator": {}, "diff": ""}], "")
    out = capsys.readouterr().out
    assert out.startswith("?:?")


def test_rows_strips_root_prefix_when_it_matches(tmp_path, capsys):
    root = tmp_path
    target = root / "sub" / "File.php"
    target.parent.mkdir(parents=True)
    target.write_text("x")
    entries = [{
        "mutator": {
            "originalFilePath": str(target),
            "originalStartLine": 3,
            "mutatorName": "Bar",
        },
        "diff": "",
    }]
    parse_infection.rows(entries, str(root))
    out = capsys.readouterr().out
    assert out.startswith(f"sub{os.sep}File.php:3")


def test_rows_keeps_original_path_when_root_does_not_match(tmp_path, capsys):
    entries = [{
        "mutator": {
            "originalFilePath": "/somewhere/else/File.php",
            "originalStartLine": 3,
            "mutatorName": "Bar",
        },
        "diff": "",
    }]
    parse_infection.rows(entries, str(tmp_path))
    out = capsys.readouterr().out
    assert out.startswith("/somewhere/else/File.php:3")


def test_main_processes_escaped_and_uncovered_with_default_root(monkeypatch, tmp_path, capsys):
    report = tmp_path / "report.json"
    report.write_text(json.dumps({
        "escaped": [{"mutator": {"originalFilePath": "/a.php", "originalStartLine": 1, "mutatorName": "M1"}, "diff": ""}],
        "uncovered": [{"mutator": {"originalFilePath": "/b.php", "originalStartLine": 2, "mutatorName": "M2"}, "diff": ""}],
    }))
    monkeypatch.setattr("sys.argv", ["parse_infection.py", str(report)])
    parse_infection.main()
    out = capsys.readouterr().out
    assert "/a.php:1" in out
    assert "/b.php:2" in out


def test_main_accepts_optional_root_argument(monkeypatch, tmp_path, capsys):
    report = tmp_path / "report.json"
    report.write_text(json.dumps({"escaped": [], "uncovered": []}))
    monkeypatch.setattr("sys.argv", ["parse_infection.py", str(report), str(tmp_path)])
    parse_infection.main()
    assert capsys.readouterr().out == ""


def test_total_count_reads_stats_total_mutants_count():
    doc = {"stats": {"totalMutantsCount": 7}, "escaped": [], "uncovered": []}
    assert parse_infection.total_count(doc) == 7


def test_total_count_defaults_to_zero_without_stats():
    assert parse_infection.total_count({}) == 0


def test_main_total_flag_prints_count_from_report(monkeypatch, tmp_path, capsys):
    report = tmp_path / "report.json"
    report.write_text(json.dumps({"stats": {"totalMutantsCount": 3}}))
    monkeypatch.setattr("sys.argv", ["parse_infection.py", "--total", str(report)])
    parse_infection.main()
    assert capsys.readouterr().out == "3\n"
