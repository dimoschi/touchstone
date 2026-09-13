import json

import parse_gocrap


def _run(monkeypatch, tmp_path, doc, extra_argv=()):
    report = tmp_path / "report.json"
    report.write_text(json.dumps(doc))
    monkeypatch.setattr("sys.argv", ["parse_gocrap.py", str(report), *extra_argv])
    parse_gocrap.main()


def test_emits_every_entry_when_no_basenames_given(monkeypatch, tmp_path, capsys):
    _run(monkeypatch, tmp_path, {"entries": [
        {"file": "a.go", "package": "pkg", "function": "F", "cyclomatic": 3, "coverage": 50, "crap": 5.5},
    ]})
    out = capsys.readouterr().out
    assert out == "pkg.F pkg 3 50.0 5.5\n"


def test_filters_by_basename_and_strips_pointer_receiver_star(monkeypatch, tmp_path, capsys):
    _run(monkeypatch, tmp_path, {"entries": [
        {"file": "a.go", "package": "pkg", "function": "*T.M", "cyclomatic": 1, "coverage": 0, "crap": 1},
        {"file": "b.go", "package": "pkg", "function": "G", "cyclomatic": 2, "coverage": 0, "crap": 2},
    ]}, extra_argv=("a.go",))
    out = capsys.readouterr().out
    assert out == "pkg.T.M pkg 1 0.0 1.0\n"


def test_missing_package_and_function_default(monkeypatch, tmp_path, capsys):
    _run(monkeypatch, tmp_path, {"entries": [{"file": "a.go"}]})
    out = capsys.readouterr().out
    assert out == "?.? ? 0 0.0 0.0\n"


def test_no_entries_key_prints_nothing(monkeypatch, tmp_path, capsys):
    _run(monkeypatch, tmp_path, {})
    assert capsys.readouterr().out == ""
