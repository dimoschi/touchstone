import io
import json

import deadcode_accepted


def test_load_missing_file_returns_empty(tmp_path):
    assert deadcode_accepted.load(str(tmp_path / "nope.json")) == {}


def test_load_invalid_json_returns_empty(tmp_path):
    bad = tmp_path / "s.json"
    bad.write_text("{not json")
    assert deadcode_accepted.load(str(bad)) == {}


def test_add_appends_and_is_idempotent(monkeypatch, tmp_path, capsys):
    store = tmp_path / "store.json"
    monkeypatch.setattr("sys.argv", ["deadcode_accepted.py", "add", str(store), "br", "f.go|Sym"])
    assert deadcode_accepted.main() == 0
    assert json.loads(store.read_text()) == {"br": ["f.go|Sym"]}
    assert deadcode_accepted.main() == 0
    assert json.loads(store.read_text()) == {"br": ["f.go|Sym"]}
    assert "recorded user acceptance" in capsys.readouterr().out


def test_remove_missing_key_fails(monkeypatch, tmp_path, capsys):
    store = tmp_path / "store.json"
    store.write_text(json.dumps({"br": ["f.go|Sym"]}))
    monkeypatch.setattr("sys.argv", ["deadcode_accepted.py", "remove", str(store), "br", "other|Sym"])
    assert deadcode_accepted.main() == 1
    assert "not accepted" in capsys.readouterr().err


def test_remove_drops_key_and_empties_branch(monkeypatch, tmp_path, capsys):
    store = tmp_path / "store.json"
    store.write_text(json.dumps({"br": ["f.go|Sym"]}))
    monkeypatch.setattr("sys.argv", ["deadcode_accepted.py", "remove", str(store), "br", "f.go|Sym"])
    assert deadcode_accepted.main() == 0
    assert json.loads(store.read_text()) == {}
    assert "revoked acceptance" in capsys.readouterr().out


def test_report_filters_to_added_keys_and_splits_accepted(monkeypatch, tmp_path, capsys):
    store = tmp_path / "store.json"
    store.write_text(json.dumps({"br": ["f.go|Accepted"]}))
    added = tmp_path / "added.txt"
    added.write_text("f.go|Accepted\nf.go|Unaccepted\n")
    findings = (
        "f.go:1:1: unreachable func: Accepted\n"
        "f.go:2:1: unreachable func: Unaccepted\n"
        "f.go:3:1: unreachable func: NotAdded\n"
        "garbage line\n"
    )
    monkeypatch.setattr("sys.stdin", io.StringIO(findings))
    monkeypatch.setattr("sys.argv", ["deadcode_accepted.py", "report", str(store), "br", str(added)])
    rc = deadcode_accepted.main()
    out = capsys.readouterr().out
    assert "f.go:2  Unaccepted  UNREACHABLE  key=f.go|Unaccepted" in out
    assert "f.go:1  Accepted  ACCEPTED" in out
    assert "NotAdded" not in out
    assert "unreachable=1" in out
    assert rc == 1


def test_report_all_accepted_exits_zero(monkeypatch, tmp_path, capsys):
    store = tmp_path / "store.json"
    store.write_text(json.dumps({"br": ["f.go|Accepted"]}))
    added = tmp_path / "added.txt"
    added.write_text("f.go|Accepted\n")
    monkeypatch.setattr("sys.stdin", io.StringIO("f.go:1:1: unreachable func: Accepted\n"))
    monkeypatch.setattr("sys.argv", ["deadcode_accepted.py", "report", str(store), "br", str(added)])
    assert deadcode_accepted.main() == 0
