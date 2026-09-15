import os
import signal

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
