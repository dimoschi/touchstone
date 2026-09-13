import deadcode_scope


def test_package_of_root_file_uses_module_path_itself():
    assert deadcode_scope.package_of("main.go", ".", "example.com/foo") == "example.com/foo"


def test_package_of_nested_file_appends_relative_dir():
    assert deadcode_scope.package_of("pkg/sub/file.go", ".", "example.com/foo") == \
        "example.com/foo/pkg/sub"


def test_package_of_relative_to_non_root_moddir():
    assert deadcode_scope.package_of("svc/pkg/file.go", "svc", "example.com/svc") == \
        "example.com/svc/pkg"


def test_findings_map_parses_unreachable_lines(tmp_path):
    f = tmp_path / "findings.txt"
    f.write_text(
        "pkg/a.go:10:2: unreachable func: Foo\n"
        "not a finding line\n"
        "pkg/b.go:20:2: unreachable func: Bar\n"
    )
    result = deadcode_scope.findings_map(str(f))
    assert result == {
        "pkg/a.go|Foo": "pkg/a.go:10:2: unreachable func: Foo",
        "pkg/b.go|Bar": "pkg/b.go:20:2: unreachable func: Bar",
    }


def _write_lines(path, lines):
    path.write_text("\n".join(lines) + "\n" if lines else "")


def test_main_reports_dead_symbol_all_roots_agree(monkeypatch, tmp_path, capsys):
    added = tmp_path / "added.txt"
    _write_lines(added, ["pkg/a.go|Foo"])

    findings = tmp_path / "findings.txt"
    _write_lines(findings, ["pkg/a.go:10:2: unreachable func: Foo"])
    test_findings = tmp_path / "test_findings.txt"
    _write_lines(test_findings, [])
    pkgs = tmp_path / "pkgs.txt"
    _write_lines(pkgs, ["example.com/foo/pkg"])
    testonly = tmp_path / "testonly.txt"
    _write_lines(testonly, [])

    manifest = tmp_path / "manifest.txt"
    manifest.write_text(f"root\t{findings}\t{pkgs}\t{test_findings}\t{testonly}\n")

    monkeypatch.setattr("sys.argv", [
        "deadcode_scope.py", str(added), ".", "example.com/foo", str(manifest),
    ])
    rc = deadcode_scope.main()
    assert rc == 0
    out, err = capsys.readouterr()
    assert out == "pkg/a.go:10:2: unreachable func: Foo\n"
    assert err == ""


def test_main_symbol_alive_when_any_root_does_not_flag_it(monkeypatch, tmp_path, capsys):
    added = tmp_path / "added.txt"
    _write_lines(added, ["pkg/a.go|Foo"])

    # Root A flags it dead, root B's build of the same package does not.
    findings_a = tmp_path / "findings_a.txt"
    _write_lines(findings_a, ["pkg/a.go:10:2: unreachable func: Foo"])
    findings_b = tmp_path / "findings_b.txt"
    _write_lines(findings_b, [])
    empty = tmp_path / "empty.txt"
    _write_lines(empty, [])
    pkgs = tmp_path / "pkgs.txt"
    _write_lines(pkgs, ["example.com/foo/pkg"])

    manifest = tmp_path / "manifest.txt"
    manifest.write_text(
        f"rootA\t{findings_a}\t{pkgs}\t{empty}\t{empty}\n"
        f"rootB\t{findings_b}\t{pkgs}\t{empty}\t{empty}\n"
    )

    monkeypatch.setattr("sys.argv", [
        "deadcode_scope.py", str(added), ".", "example.com/foo", str(manifest),
    ])
    assert deadcode_scope.main() == 0
    assert capsys.readouterr().out == ""


def test_main_testonly_package_deciding_vote_is_the_test_pass(monkeypatch, tmp_path, capsys):
    added = tmp_path / "added.txt"
    _write_lines(added, ["pkg/a.go|Helper"])

    # The non-test pass reports it unreachable (nothing outside tests calls it),
    # but the package is testonly and the -test pass DOES reach it, so it's alive.
    findings = tmp_path / "findings.txt"
    _write_lines(findings, ["pkg/a.go:5:2: unreachable func: Helper"])
    test_findings = tmp_path / "test_findings.txt"
    _write_lines(test_findings, [])  # -test pass reaches it: no finding for it
    pkgs = tmp_path / "pkgs.txt"
    _write_lines(pkgs, ["example.com/foo/pkg"])
    testonly = tmp_path / "testonly.txt"
    _write_lines(testonly, ["example.com/foo/pkg"])

    manifest = tmp_path / "manifest.txt"
    manifest.write_text(f"root\t{findings}\t{pkgs}\t{test_findings}\t{testonly}\n")

    monkeypatch.setattr("sys.argv", [
        "deadcode_scope.py", str(added), ".", "example.com/foo", str(manifest),
    ])
    assert deadcode_scope.main() == 0
    assert capsys.readouterr().out == ""


def test_main_symbol_outside_moddir_is_skipped(monkeypatch, tmp_path, capsys):
    added = tmp_path / "added.txt"
    _write_lines(added, ["other/a.go|Foo"])
    empty = tmp_path / "empty.txt"
    _write_lines(empty, [])
    manifest = tmp_path / "manifest.txt"
    manifest.write_text(f"root\t{empty}\t{empty}\t{empty}\t{empty}\n")

    monkeypatch.setattr("sys.argv", [
        "deadcode_scope.py", str(added), "svc", "example.com/svc", str(manifest),
    ])
    assert deadcode_scope.main() == 0
    assert capsys.readouterr().out == ""


def test_main_unanalysed_symbol_reported_on_stderr(monkeypatch, tmp_path, capsys):
    added = tmp_path / "added.txt"
    _write_lines(added, ["pkg/a.go|Foo"])
    empty = tmp_path / "empty.txt"
    _write_lines(empty, [])
    pkgs = tmp_path / "pkgs.txt"
    _write_lines(pkgs, ["example.com/foo/other"])  # does not include pkg/a.go's package
    manifest = tmp_path / "manifest.txt"
    manifest.write_text(f"root\t{empty}\t{pkgs}\t{empty}\t{empty}\n")

    monkeypatch.setattr("sys.argv", [
        "deadcode_scope.py", str(added), ".", "example.com/foo", str(manifest),
    ])
    assert deadcode_scope.main() == 0
    out, err = capsys.readouterr()
    assert out == ""
    assert "1 symbol(s)" in err
    assert "pkg/a.go|Foo" in err
    assert "not a pass for them" in err
