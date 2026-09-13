import io
import json

import mutation_accepted


def test_load_missing_file_returns_empty(tmp_path):
    assert mutation_accepted.load(str(tmp_path / "nope.json")) == {}


def test_load_invalid_json_returns_empty(tmp_path):
    bad = tmp_path / "store.json"
    bad.write_text("{not json")
    assert mutation_accepted.load(str(bad)) == {}


def test_add_records_new_id_and_is_idempotent(monkeypatch, tmp_path, capsys):
    store = tmp_path / "store.json"
    monkeypatch.setattr("sys.argv", ["mutation_accepted.py", "add", str(store), "br", "id-1"])
    mutation_accepted.main()
    assert json.loads(store.read_text()) == {"br": ["id-1"]}
    assert "recorded user acceptance of id-1" in capsys.readouterr().out

    # adding the same id again does not duplicate it
    mutation_accepted.main()
    assert json.loads(store.read_text()) == {"br": ["id-1"]}


def test_filter_splits_accepted_and_unaccepted(monkeypatch, tmp_path, capsys):
    store = tmp_path / "store.json"
    store.write_text(json.dumps({"br": ["id-1"]}))
    lines = (
        "path.py:1  Mutator  SURVIVED  id=id-1\n"
        "path.py:2  Mutator  SURVIVED  id=id-2\n"
        "not a survivor row at all\n"
    )
    monkeypatch.setattr("sys.stdin", io.StringIO(lines))
    monkeypatch.setattr("sys.argv", ["mutation_accepted.py", "filter", str(store), "br"])
    mutation_accepted.main()
    out = capsys.readouterr().out
    assert "unaccepted=1" in out
    assert "accepted=id-1" in out
    assert "id-2" not in out.split("unaccepted=1")[0]
