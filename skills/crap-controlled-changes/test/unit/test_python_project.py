import os

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
