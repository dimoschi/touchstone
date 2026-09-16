import builtins
import io
import os
import signal

import pytest

import python_project


def test_declares_project_true_for_coverage_run_section(tmp_path):
    p = tmp_path / "pyproject.toml"
    p.write_text("[tool.coverage.run]\ninclude = [\"src/*\"]\n")
    assert python_project.declares_project(str(p)) is True


def test_declares_project_true_for_pytest_ini_options_section(tmp_path):
    p = tmp_path / "pyproject.toml"
    p.write_text("[tool.pytest.ini_options]\ntestpaths = [\"tests\"]\n")
    assert python_project.declares_project(str(p)) is True


def test_declares_project_false_without_either_section(tmp_path):
    p = tmp_path / "pyproject.toml"
    p.write_text("[project]\nname = \"foo\"\n")
    assert python_project.declares_project(str(p)) is False


def test_declares_project_false_for_missing_file(tmp_path):
    assert python_project.declares_project(str(tmp_path / "nope.toml")) is False


def test_declares_project_ignores_indented_or_trailing_whitespace(tmp_path):
    p = tmp_path / "pyproject.toml"
    p.write_text("  [tool.coverage.run]   \n")
    assert python_project.declares_project(str(p)) is True


def test_declares_project_coverage_only_true_for_coverage_run_section(tmp_path):
    p = tmp_path / "pyproject.toml"
    p.write_text("[tool.coverage.run]\n")
    assert python_project.declares_project(str(p), coverage_only=True) is True


def test_declares_project_coverage_only_false_for_pytest_ini_options_section(tmp_path):
    p = tmp_path / "pyproject.toml"
    p.write_text("[tool.pytest.ini_options]\n")
    assert python_project.declares_project(str(p), coverage_only=True) is False


def test_declares_project_reads_the_file_as_utf8_whatever_the_locale(monkeypatch, tmp_path):
    # The encoding is pinned rather than left to the platform: a pyproject.toml
    # with a non-ASCII byte read under a non-UTF-8 locale raises
    # UnicodeDecodeError, which is not an OSError and so would escape the
    # except below as a crash of the gate.
    p = tmp_path / "pyproject.toml"
    p.write_text("[tool.coverage.run]\n# café\n", encoding="utf-8")
    seen = {}
    real_open = builtins.open

    def spy(file, *args, **kwargs):
        seen[str(file)] = kwargs.get("encoding")
        return real_open(file, *args, **kwargs)

    monkeypatch.setattr(builtins, "open", spy)
    assert python_project.declares_project(str(p)) is True
    assert seen[str(p)] == "utf-8"


def test_find_project_dirs_nearest_ancestor_pyproject(tmp_path):
    proj = tmp_path / "proj"
    (proj / "src").mkdir(parents=True)
    (proj / "pyproject.toml").write_text("[tool.coverage.run]\n")
    changed = ["proj/src/mod.py"]
    assert python_project.find_project_dirs(changed, str(tmp_path)) == ["proj"]


def test_find_project_dirs_root_pyproject_is_not_reported(tmp_path):
    (tmp_path / "pyproject.toml").write_text("[tool.coverage.run]\n")
    (tmp_path / "src").mkdir()
    changed = ["src/mod.py", "mod.py"]
    assert python_project.find_project_dirs(changed, str(tmp_path)) == []


def test_find_project_dirs_root_pyproject_is_not_reported_for_a_dot_prefixed_path(tmp_path):
    # "./mod.py" has "." for a dirname, which is the root, so the walk-up must
    # stop before it: reporting "." would send the caller off to measure the
    # root from the root, which is where it already runs.
    (tmp_path / "pyproject.toml").write_text("[tool.coverage.run]\n")
    assert python_project.find_project_dirs(["./mod.py"], str(tmp_path)) == []


def test_find_project_dirs_looks_for_a_lowercase_pyproject_toml(tmp_path, monkeypatch):
    # A case-insensitive filesystem (macOS) hides a wrong-cased filename, so
    # the name is asserted rather than inferred from the lookup succeeding.
    seen = []
    real = python_project.declares_project

    def spy(path, coverage_only=False):
        seen.append(path)
        return real(path, coverage_only=coverage_only)

    monkeypatch.setattr(python_project, "declares_project", spy)
    proj = tmp_path / "proj"
    (proj / "src").mkdir(parents=True)
    (proj / "pyproject.toml").write_text("[tool.coverage.run]\n")
    assert python_project.find_project_dirs(["proj/src/mod.py"], str(tmp_path)) == ["proj"]
    assert seen == [
        os.path.join(str(tmp_path), os.path.normpath("proj/src"), "pyproject.toml"),
        os.path.join(str(tmp_path), "proj", "pyproject.toml"),
    ]


def test_find_project_dirs_ignores_dir_without_either_section(tmp_path):
    proj = tmp_path / "proj"
    proj.mkdir()
    (proj / "pyproject.toml").write_text("[project]\nname = \"proj\"\n")
    changed = ["proj/mod.py"]
    assert python_project.find_project_dirs(changed, str(tmp_path)) == []


def test_find_project_dirs_dedupes_several_files_under_one_project(tmp_path):
    proj = tmp_path / "proj"
    (proj / "src").mkdir(parents=True)
    (proj / "pyproject.toml").write_text("[tool.coverage.run]\n")
    changed = ["proj/src/a.py", "proj/src/b.py", "proj/mod.py"]
    assert python_project.find_project_dirs(changed, str(tmp_path)) == ["proj"]


def test_find_project_dirs_sorted_for_multiple_projects(tmp_path):
    for name in ("zproj", "aproj"):
        d = tmp_path / name
        d.mkdir()
        (d / "pyproject.toml").write_text("[tool.pytest.ini_options]\n")
    changed = ["zproj/mod.py", "aproj/mod.py"]
    assert python_project.find_project_dirs(changed, str(tmp_path)) == ["aproj", "zproj"]


def test_find_project_dirs_nearest_match_wins_over_grandparent(tmp_path):
    outer = tmp_path / "outer"
    inner = outer / "inner"
    inner.mkdir(parents=True)
    (outer / "pyproject.toml").write_text("[tool.coverage.run]\n")
    (inner / "pyproject.toml").write_text("[tool.pytest.ini_options]\n")
    changed = ["outer/inner/mod.py"]
    assert python_project.find_project_dirs(changed, str(tmp_path)) == [
        os.path.normpath("outer/inner")
    ]


def test_find_project_dirs_coverage_only_skips_pytest_ini_options_only_dir(tmp_path):
    proj = tmp_path / "proj"
    proj.mkdir()
    (proj / "pyproject.toml").write_text("[tool.pytest.ini_options]\n")
    changed = ["proj/mod.py"]
    assert python_project.find_project_dirs(changed, str(tmp_path), coverage_only=True) == []


def test_find_project_dirs_coverage_only_still_finds_coverage_run_dir(tmp_path):
    proj = tmp_path / "proj"
    proj.mkdir()
    (proj / "pyproject.toml").write_text("[tool.coverage.run]\n")
    changed = ["proj/mod.py"]
    assert python_project.find_project_dirs(changed, str(tmp_path), coverage_only=True) == ["proj"]


def test_find_project_dirs_terminates_for_an_absolute_changed_path(tmp_path):
    # The filesystem root is its own parent forever, so a changed path fed in
    # absolute (CRAP_FILES set by hand) used to spin the walk-up loop without
    # ever reaching "" or ".".
    def _on_alarm(signum, frame):
        raise TimeoutError("find_project_dirs did not terminate for an absolute path")

    old_handler = signal.signal(signal.SIGALRM, _on_alarm)
    signal.alarm(2)
    try:
        result = python_project.find_project_dirs(["/no/such/project/mod.py"], str(tmp_path))
    finally:
        signal.alarm(0)
        signal.signal(signal.SIGALRM, old_handler)
    assert result == []


def test_main_root_declares_prints_1_when_root_pyproject_qualifies(monkeypatch, tmp_path, capsys):
    (tmp_path / "pyproject.toml").write_text("[tool.coverage.run]\n")
    monkeypatch.setattr(
        "sys.argv", ["python_project.py", "--repo-root", str(tmp_path), "--root-declares"]
    )
    assert python_project.main() == 0
    assert capsys.readouterr().out == "1\n"


def test_main_root_declares_prints_0_when_root_pyproject_does_not_qualify(monkeypatch, tmp_path, capsys):
    (tmp_path / "pyproject.toml").write_text("[project]\nname = \"x\"\n")
    monkeypatch.setattr(
        "sys.argv", ["python_project.py", "--repo-root", str(tmp_path), "--root-declares"]
    )
    assert python_project.main() == 0
    assert capsys.readouterr().out == "0\n"


def test_main_root_declares_coverage_only_prints_0_for_pytest_ini_options_only_root(monkeypatch, tmp_path, capsys):
    (tmp_path / "pyproject.toml").write_text("[tool.pytest.ini_options]\n")
    monkeypatch.setattr(
        "sys.argv",
        ["python_project.py", "--repo-root", str(tmp_path), "--root-declares", "--coverage-only"],
    )
    assert python_project.main() == 0
    assert capsys.readouterr().out == "0\n"


def test_main_root_declares_prints_0_when_root_has_no_pyproject(monkeypatch, tmp_path, capsys):
    monkeypatch.setattr(
        "sys.argv", ["python_project.py", "--repo-root", str(tmp_path), "--root-declares"]
    )
    assert python_project.main() == 0
    assert capsys.readouterr().out == "0\n"


def test_owning_dir_nearest_candidate_wins(tmp_path):
    assert python_project.owning_dir("projA/src/mod.py", ["projA", "projB"]) == "projA"
    assert python_project.owning_dir("projB/mod.py", ["projA", "projB"]) == "projB"


def test_owning_dir_root_candidate_matches_anything(tmp_path):
    assert python_project.owning_dir("mod.py", [".", "projA"]) == "."
    assert python_project.owning_dir("projA/mod.py", [".", "projA"]) == "projA"


def test_owning_dir_falls_back_to_first_candidate_for_a_stray_file():
    assert python_project.owning_dir("elsewhere/mod.py", ["projA", "projB"]) == "projA"


def test_owning_dir_root_candidate_wins_over_an_earlier_candidate_that_does_not_match():
    # "." is the weakest match, but it is still a match: it must beat "no
    # candidate owns this file" even when it is not listed first.
    assert python_project.owning_dir("sub/mod.py", ["projA", "."]) == "."


def test_owning_dir_one_char_dir_beats_the_root_candidate():
    # "." matches at length 0, below every real directory, so a one-character
    # directory still outranks it.
    assert python_project.owning_dir("a/mod.py", [".", "a"]) == "a"


def test_owning_dir_exact_directory_match_not_just_a_prefix():
    # "projAX" must not match candidate "projA" (a naive string-prefix check would).
    assert python_project.owning_dir("projAX/mod.py", ["projA", "projB"]) == "projA"


def test_main_group_prints_owning_dir_and_file_per_line(monkeypatch, tmp_path, capsys):
    monkeypatch.setattr(
        "sys.stdin", __import__("io").StringIO("projA/src/mod.py\nprojB/mod.py\n")
    )
    monkeypatch.setattr(
        "sys.argv",
        ["python_project.py", "--repo-root", str(tmp_path), "--group",
         "--group-by", "projA", "--group-by", "projB"],
    )
    assert python_project.main() == 0
    assert capsys.readouterr().out == (
        "projA\tprojA/src/mod.py\n"
        "projB\tprojB/mod.py\n"
    )


def test_main_group_ignores_blank_stdin_lines(monkeypatch, tmp_path, capsys):
    monkeypatch.setattr("sys.stdin", __import__("io").StringIO("\nprojA/mod.py\n\n"))
    monkeypatch.setattr(
        "sys.argv",
        ["python_project.py", "--repo-root", str(tmp_path), "--group", "--group-by", "projA"],
    )
    assert python_project.main() == 0
    assert capsys.readouterr().out == "projA\tprojA/mod.py\n"


def test_main_prints_one_dir_per_line(monkeypatch, tmp_path, capsys):
    proj = tmp_path / "proj"
    proj.mkdir()
    (proj / "pyproject.toml").write_text("[tool.coverage.run]\n")
    monkeypatch.setattr(
        "sys.stdin", __import__("io").StringIO("proj/mod.py\n")
    )
    monkeypatch.setattr("sys.argv", ["python_project.py", "--repo-root", str(tmp_path)])
    assert python_project.main() == 0
    assert capsys.readouterr().out == "proj\n"


def test_main_prints_nothing_when_clean(monkeypatch, tmp_path, capsys):
    monkeypatch.setattr("sys.stdin", __import__("io").StringIO("mod.py\n"))
    monkeypatch.setattr("sys.argv", ["python_project.py", "--repo-root", str(tmp_path)])
    assert python_project.main() == 0
    assert capsys.readouterr().out == ""


def test_main_ignores_blank_stdin_lines(monkeypatch, tmp_path, capsys):
    proj = tmp_path / "proj"
    proj.mkdir()
    (proj / "pyproject.toml").write_text("[tool.coverage.run]\n")
    monkeypatch.setattr(
        "sys.stdin", __import__("io").StringIO("\nproj/mod.py\n\n")
    )
    monkeypatch.setattr("sys.argv", ["python_project.py", "--repo-root", str(tmp_path)])
    assert python_project.main() == 0
    assert capsys.readouterr().out == "proj\n"


def test_cmd_find_defaults_to_accepting_either_section(tmp_path, capsys):
    proj = tmp_path / "proj"
    proj.mkdir()
    (proj / "pyproject.toml").write_text("[tool.pytest.ini_options]\n")
    python_project._cmd_find(["proj/mod.py"], str(tmp_path))
    assert capsys.readouterr().out == "proj\n"


def test_main_coverage_only_find_skips_a_pytest_ini_options_only_project(monkeypatch, tmp_path, capsys):
    proj = tmp_path / "proj"
    proj.mkdir()
    (proj / "pyproject.toml").write_text("[tool.pytest.ini_options]\n")
    monkeypatch.setattr("sys.stdin", io.StringIO("proj/mod.py\n"))
    monkeypatch.setattr(
        "sys.argv",
        ["python_project.py", "--repo-root", str(tmp_path), "--coverage-only"],
    )
    assert python_project.main() == 0
    assert capsys.readouterr().out == ""


def test_main_coverage_only_find_still_reports_a_coverage_run_project(monkeypatch, tmp_path, capsys):
    proj = tmp_path / "proj"
    proj.mkdir()
    (proj / "pyproject.toml").write_text("[tool.coverage.run]\n")
    monkeypatch.setattr("sys.stdin", io.StringIO("proj/mod.py\n"))
    monkeypatch.setattr(
        "sys.argv",
        ["python_project.py", "--repo-root", str(tmp_path), "--coverage-only"],
    )
    assert python_project.main() == 0
    assert capsys.readouterr().out == "proj\n"


def test_main_group_with_no_group_by_prints_nothing(monkeypatch, tmp_path, capsys):
    monkeypatch.setattr("sys.stdin", io.StringIO(""))
    monkeypatch.setattr(
        "sys.argv", ["python_project.py", "--repo-root", str(tmp_path), "--group"]
    )
    assert python_project.main() == 0
    assert capsys.readouterr().out == ""


def test_main_refuses_without_repo_root(monkeypatch):
    monkeypatch.setattr("sys.argv", ["python_project.py", "--root-declares"])
    with pytest.raises(SystemExit):
        python_project.main()


def test_main_root_declares_looks_for_a_lowercase_pyproject_toml(monkeypatch, tmp_path, capsys):
    seen = []
    real = python_project.declares_project

    def spy(path, coverage_only=False):
        seen.append(path)
        return real(path, coverage_only=coverage_only)

    monkeypatch.setattr(python_project, "declares_project", spy)
    (tmp_path / "pyproject.toml").write_text("[tool.coverage.run]\n")
    monkeypatch.setattr(
        "sys.argv", ["python_project.py", "--repo-root", str(tmp_path), "--root-declares"]
    )
    assert python_project.main() == 0
    assert capsys.readouterr().out == "1\n"
    assert seen == [os.path.join(str(tmp_path), "pyproject.toml")]


def test_main_help_documents_every_option(monkeypatch, capsys):
    monkeypatch.setenv("COLUMNS", "200")
    monkeypatch.setattr("sys.argv", ["python_project.py", "--help"])
    with pytest.raises(SystemExit):
        python_project.main()
    out = capsys.readouterr().out
    assert (
        "print 1/0: does the repo root's own pyproject.toml declare "
        "[tool.coverage.run] or [tool.pytest.ini_options]?"
    ) in out
    assert (
        "restrict --root-declares, or the default find mode, to "
        "[tool.coverage.run] alone"
    ) in out
    assert "print '<owning-dir>\\t<file>' per changed file on stdin" in out
    assert "a directory --group assigns changed files to; repeatable" in out
