import os

import buildtag_diagnosis


def test_constraint_missing_file_returns_empty(tmp_path):
    assert buildtag_diagnosis.constraint(str(tmp_path / "nope.go")) == ""


def test_constraint_stops_at_package_clause(tmp_path):
    f = tmp_path / "a.go"
    f.write_text("// +build integration\npackage main\n\n//go:build linux\n")
    assert buildtag_diagnosis.constraint(str(f)) == "integration"


def test_constraint_prefers_go_build_line(tmp_path):
    f = tmp_path / "a.go"
    f.write_text("//go:build integration && !windows\npackage main\n")
    assert buildtag_diagnosis.constraint(str(f)) == "integration && !windows"


def test_constraint_joins_multiple_plus_build_lines(tmp_path):
    f = tmp_path / "a.go"
    f.write_text("// +build linux\n// +build amd64\npackage main\n")
    assert buildtag_diagnosis.constraint(str(f)) == "linux amd64"


def test_constraint_no_tags_returns_empty(tmp_path):
    f = tmp_path / "a.go"
    f.write_text("package main\n")
    assert buildtag_diagnosis.constraint(str(f)) == ""


def test_required_tags_drops_negated_and_booleans():
    assert buildtag_diagnosis.required_tags("integration && !windows && true") == ["integration"]


def test_negated_tags_strips_bang():
    assert buildtag_diagnosis.negated_tags("integration && !windows") == {"windows"}


def test_main_tags_mode_prints_unique_required_tags(monkeypatch, tmp_path, capsys):
    f = tmp_path / "a.go"
    f.write_text("//go:build integration && integration && !windows\npackage main\n")
    monkeypatch.setattr("sys.argv", ["buildtag_diagnosis.py", "tags", str(f)])
    rc = buildtag_diagnosis.main()
    assert rc == 0
    assert capsys.readouterr().out == "integration\n"


def test_main_conflicts_mode_counts_excluded_test_files(monkeypatch, tmp_path, capsys):
    (tmp_path / "vendor").mkdir()
    (tmp_path / "vendor" / "x_test.go").write_text("// +build !integration\npackage vendor\n")
    (tmp_path / "a_test.go").write_text("// +build !integration\npackage main\n")
    (tmp_path / "b_test.go").write_text("package main\n")
    (tmp_path / "c.go").write_text("// +build !integration\npackage main\n")

    monkeypatch.setattr("sys.argv", ["buildtag_diagnosis.py", "conflicts", str(tmp_path), "integration"])
    rc = buildtag_diagnosis.main()
    assert rc == 0
    # vendor/ is skipped, b_test.go has no constraint, c.go is not a test file
    assert capsys.readouterr().out == "1\n"
