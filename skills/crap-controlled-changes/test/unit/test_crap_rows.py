import io
import json

import pytest

import crap_rows

GREEN = (
    "== python ==\n"
    "lib/a.py::f  complexity=2   coverage=100.0%  CRAP=2.0  OK           (new)\n"
    "lib/a.py::g  complexity=5   coverage=80.0%   CRAP=5.2  OK           (worsened)\n"
    "lib/a.py::h  complexity=1   coverage=n/a     CRAP=n/a  OK_MAIN      (unchanged)\n"
    "\n"
    "== NEXT_ACTION ==\n"
    "COMMIT_OK\n"
)


def row(**fields):
    base = {"complexity": "2", "coverage": "100.0", "crap": "2.0", "status": "OK", "tag": "new"}
    return {**base, **fields}


def test_parse_reads_every_gate_row_and_nothing_else():
    assert crap_rows.parse(GREEN) == {
        "lib/a.py::f": row(),
        "lib/a.py::g": row(complexity="5", coverage="80.0", crap="5.2", tag="worsened"),
        "lib/a.py::h": row(complexity="1", coverage="n/a", crap="n/a", status="OK_MAIN", tag="unchanged"),
    }


def test_parse_of_text_without_rows_is_empty():
    assert crap_rows.parse("no staged source files\n") == {}


def test_merge_keeps_the_latest_row_per_function_and_the_ones_not_rerun():
    stored = {"a::f": row(crap="9.0"), "a::old": row(crap="1.0")}
    merged = crap_rows.merge(stored, {"a::f": row(crap="3.0"), "a::g": row(crap="4.0")})
    assert merged == {"a::f": row(crap="3.0"), "a::old": row(crap="1.0"), "a::g": row(crap="4.0")}


@pytest.mark.parametrize("was,now,kept", [
    ("new", "unchanged", "new"),
    ("new", "worsened", "new"),
    ("worsened", "unchanged", "worsened"),
    ("worsened", "new", "new"),
    ("unchanged", "worsened", "worsened"),
    ("unchanged", "new", "new"),
    ("unchanged", "unchanged", "unchanged"),
    ("new", "new", "new"),
])
def test_merge_keeps_the_stronger_tag_with_the_latest_numbers(was, now, kept):
    merged = crap_rows.merge({"a::f": row(tag=was, crap="9.0")}, {"a::f": row(tag=now, crap="3.0")})
    assert merged == {"a::f": row(tag=kept, crap="3.0")}


def test_merge_does_not_change_what_it_was_given():
    stored = {"a::f": row()}
    crap_rows.merge(stored, {"a::f": row(tag="unchanged")})
    assert stored == {"a::f": row()}


def test_record_writes_rows_under_the_branch_and_keeps_other_branches(tmp_path):
    path = tmp_path / "rows.json"
    path.write_text(json.dumps({"other": {"x::y": row()}}))
    crap_rows.record(str(path), "feat", GREEN)
    saved = json.loads(path.read_text())
    assert saved["other"] == {"x::y": row()}
    assert sorted(saved["feat"]) == ["lib/a.py::f", "lib/a.py::g", "lib/a.py::h"]


def test_record_folds_a_second_run_into_the_first(tmp_path):
    path = tmp_path / "rows.json"
    crap_rows.record(str(path), "feat", GREEN)
    crap_rows.record(
        str(path), "feat",
        "lib/a.py::f  complexity=3   coverage=90.0%  CRAP=3.1  OK  (unchanged)\n",
    )
    assert crap_rows.latest(str(path), "feat")["lib/a.py::f"] == row(complexity="3", coverage="90.0", crap="3.1")


def test_latest_is_empty_without_a_file_or_a_branch(tmp_path):
    path = tmp_path / "rows.json"
    assert crap_rows.latest(str(path), "feat") == {}
    path.write_text(json.dumps({"other": {"x::y": row()}}))
    assert crap_rows.latest(str(path), "feat") == {}


def test_latest_is_empty_when_the_file_is_not_json(tmp_path):
    path = tmp_path / "rows.json"
    path.write_text("{broken")
    assert crap_rows.latest(str(path), "feat") == {}


def test_main_records_the_rows_on_stdin(tmp_path, monkeypatch):
    path = tmp_path / "rows.json"
    monkeypatch.setattr("sys.stdin", io.StringIO(GREEN))
    assert crap_rows.main(["record", str(path), "feat"]) == 0
    assert sorted(json.loads(path.read_text())["feat"]) == ["lib/a.py::f", "lib/a.py::g", "lib/a.py::h"]


def test_main_refuses_anything_but_record(capsys):
    with pytest.raises(SystemExit) as stop:
        crap_rows.main(["forget", "rows.json", "feat"])
    assert stop.value.code == 2
    assert "invalid choice" in capsys.readouterr().err
