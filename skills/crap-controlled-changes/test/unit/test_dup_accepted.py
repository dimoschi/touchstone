import io
import json

import pytest

import dup_accepted

KEY = "a.py#111111111111|b.py#222222222222"
LINE = f"DUPLICATE score=0.91 a.py:3-12 b.py:5-14 key={KEY}\n"


def run(monkeypatch, *argv, stdin=""):
    monkeypatch.setattr("sys.stdin", io.StringIO(stdin))
    return dup_accepted.main(list(argv))


def test_add_records_the_key_for_the_branch_and_is_idempotent(monkeypatch, tmp_path, capsys):
    store = tmp_path / "store.json"
    assert run(monkeypatch, "add", str(store), "br", KEY) == 0
    assert run(monkeypatch, "add", str(store), "br", KEY) == 0
    assert json.loads(store.read_text()) == {"br": [KEY]}
    assert capsys.readouterr().out.startswith(
        f"dup-check: recorded user acceptance of {KEY} on branch 'br'")


def test_add_keeps_other_branches_accepted_keys(monkeypatch, tmp_path):
    store = tmp_path / "store.json"
    store.write_text(json.dumps({"other": ["x|y"]}))
    assert run(monkeypatch, "add", str(store), "br", KEY) == 0
    assert json.loads(store.read_text()) == {"other": ["x|y"], "br": [KEY]}


def test_remove_drops_the_key_and_an_emptied_branch(monkeypatch, tmp_path, capsys):
    store = tmp_path / "store.json"
    store.write_text(json.dumps({"br": [KEY], "other": ["x|y"]}))
    assert run(monkeypatch, "remove", str(store), "br", KEY) == 0
    assert json.loads(store.read_text()) == {"other": ["x|y"]}
    assert capsys.readouterr().out.startswith(
        f"dup-check: revoked acceptance of {KEY} on branch 'br'")


def test_remove_keeps_a_branchs_remaining_keys(monkeypatch, tmp_path):
    store = tmp_path / "store.json"
    store.write_text(json.dumps({"br": [KEY, "x|y"]}))
    assert run(monkeypatch, "remove", str(store), "br", KEY) == 0
    assert json.loads(store.read_text()) == {"br": ["x|y"]}


def test_remove_of_a_key_that_was_never_accepted_fails(monkeypatch, tmp_path, capsys):
    store = tmp_path / "store.json"
    store.write_text(json.dumps({"br": ["x|y"]}))
    assert run(monkeypatch, "remove", str(store), "br", KEY) == 1
    assert f"{KEY} is not accepted on branch 'br'" in capsys.readouterr().err
    assert json.loads(store.read_text()) == {"br": ["x|y"]}


def test_report_lists_an_unaccepted_duplicate_and_exits_one(monkeypatch, tmp_path, capsys):
    store = tmp_path / "store.json"
    assert run(monkeypatch, "report", str(store), "br", stdin=LINE + "noise\n") == 1
    out = capsys.readouterr().out
    assert out == (f"a.py:3-12  b.py:5-14  score=0.91  DUPLICATE  key={KEY}\n"
                   "duplicates=1\n")


def test_report_notes_an_accepted_duplicate_and_exits_zero(monkeypatch, tmp_path, capsys):
    store = tmp_path / "store.json"
    store.write_text(json.dumps({"br": [KEY]}))
    assert run(monkeypatch, "report", str(store), "br", stdin=LINE) == 0
    assert capsys.readouterr().out == (
        "a.py:3-12  b.py:5-14  score=0.91  ACCEPTED\n"
        "duplicates=0\n")


def test_an_acceptance_on_another_branch_does_not_count(monkeypatch, tmp_path, capsys):
    store = tmp_path / "store.json"
    store.write_text(json.dumps({"other": [KEY]}))
    assert run(monkeypatch, "report", str(store), "br", stdin=LINE) == 1


def test_report_with_no_duplicates_exits_zero(monkeypatch, tmp_path, capsys):
    assert run(monkeypatch, "report", str(tmp_path / "none.json"), "br", stdin="") == 0
    assert capsys.readouterr().out == "duplicates=0\n"


def test_report_reads_paths_that_contain_spaces(monkeypatch, tmp_path, capsys):
    line = "DUPLICATE score=0.90 my dir/a.py:1-9 b.py:2-10 key=my dir/a.py#1|b.py#2\n"
    assert run(monkeypatch, "report", str(tmp_path / "s.json"), "br", stdin=line) == 1
    assert "my dir/a.py:1-9  b.py:2-10  score=0.90  DUPLICATE  key=my dir/a.py#1|b.py#2" \
        in capsys.readouterr().out


def test_an_unknown_mode_is_refused(monkeypatch, tmp_path):
    with pytest.raises(SystemExit) as stop:
        run(monkeypatch, "nope", str(tmp_path / "s.json"), "br")
    assert stop.value.code == 2


@pytest.mark.parametrize("mode", ["add", "remove"])
def test_add_and_remove_need_a_key(monkeypatch, tmp_path, mode):
    store = tmp_path / "s.json"
    with pytest.raises(SystemExit) as stop:
        run(monkeypatch, mode, str(store), "br")
    assert stop.value.code == 2
    assert not store.exists()


def test_remove_on_a_branch_that_has_no_accepted_keys_fails(monkeypatch, tmp_path, capsys):
    store = tmp_path / "store.json"
    store.write_text(json.dumps({"other": [KEY]}))
    assert run(monkeypatch, "remove", str(store), "br", KEY) == 1
    assert f"{KEY} is not accepted on branch 'br'" in capsys.readouterr().err
    assert json.loads(store.read_text()) == {"other": [KEY]}


def test_report_keeps_reading_after_a_line_that_is_not_a_finding(monkeypatch, tmp_path, capsys):
    assert run(monkeypatch, "report", str(tmp_path / "s.json"), "br", stdin="noise\n" + LINE) == 1
    assert capsys.readouterr().out == (f"a.py:3-12  b.py:5-14  score=0.91  DUPLICATE  key={KEY}\n"
                                       "duplicates=1\n")


def test_an_unknown_mode_is_refused_even_when_a_key_is_given(monkeypatch, tmp_path):
    with pytest.raises(SystemExit) as stop:
        run(monkeypatch, "nope", str(tmp_path / "s.json"), "br", KEY)
    assert stop.value.code == 2


@pytest.mark.parametrize("mode", ["add", "remove"])
def test_the_refusal_to_run_without_a_key_names_the_mode(monkeypatch, tmp_path, capsys, mode):
    with pytest.raises(SystemExit):
        run(monkeypatch, mode, str(tmp_path / "s.json"), "br")
    assert f"{mode} needs a key" in capsys.readouterr().err
