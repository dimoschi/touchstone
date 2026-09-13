import io
import json
from types import SimpleNamespace

import scored_ledger


def test_save_and_load_round_trip(tmp_path):
    path = tmp_path / "ledger.json"
    scored_ledger.save(str(path), {"br": {"a.go": "blob1"}})
    assert scored_ledger.load(str(path)) == {"br": {"a.go": "blob1"}}


def test_load_missing_or_invalid_returns_empty(tmp_path):
    assert scored_ledger.load(str(tmp_path / "nope.json")) == {}
    bad = tmp_path / "bad.json"
    bad.write_text("{not json")
    assert scored_ledger.load(str(bad)) == {}


def test_pairs_from_stdin_skips_malformed_lines(monkeypatch):
    monkeypatch.setattr("sys.stdin", io.StringIO("a.go blob1\nmalformed\nb.go blob2 extra\n"))
    assert list(scored_ledger.pairs_from_stdin()) == [("a.go", "blob1")]


def test_entry_blob_and_source_legacy_string_form():
    assert scored_ledger.entry_blob("blob1") == "blob1"
    assert scored_ledger.entry_source("blob1") == "measured"


def test_entry_blob_and_source_dict_form():
    entry = {"blob": "blob1", "source": "marked"}
    assert scored_ledger.entry_blob(entry) == "blob1"
    assert scored_ledger.entry_source(entry) == "marked"


def test_entry_blob_and_source_none_entry():
    assert scored_ledger.entry_blob(None) is None
    assert scored_ledger.entry_source(None) == "measured"


def test_entry_source_dict_without_source_key_defaults_measured():
    assert scored_ledger.entry_source({"blob": "b"}) == "measured"


def test_parse_opts_positional_source_and_flags():
    opts = scored_ledger.parse_opts(["marked", "--commit", "abc", "--tools", "fp"])
    assert opts["source"] == "marked"
    assert opts["commit"] == "abc"
    assert opts["tools"] == "fp"
    assert opts["borrow"] is False


def test_parse_opts_borrow_flag():
    opts = scored_ledger.parse_opts(["--borrow", "--head", "HEAD~1"])
    assert opts["borrow"] is True
    assert opts["head"] == "HEAD~1"
    assert opts["source"] == "measured"


def test_parse_opts_unknown_flag_raises():
    try:
        scored_ledger.parse_opts(["--bogus", "x"])
        assert False, "expected SystemExit"
    except SystemExit as exc:
        assert "unknown option" in str(exc.code)


def test_parse_opts_flag_missing_value_raises():
    try:
        scored_ledger.parse_opts(["--tools"])
        assert False, "expected SystemExit"
    except SystemExit as exc:
        assert "unknown option" in str(exc.code)


def test_reachable_caches_subprocess_result(monkeypatch):
    calls = []

    def fake_run(*args, **kwargs):
        calls.append(args)
        return SimpleNamespace(returncode=0)

    monkeypatch.setattr(scored_ledger.subprocess, "run", fake_run)
    cache = {}
    assert scored_ledger.reachable("abc", "HEAD", cache) is True
    assert scored_ledger.reachable("abc", "HEAD", cache) is True
    assert len(calls) == 1


def test_reachable_false_on_nonzero_returncode(monkeypatch):
    monkeypatch.setattr(scored_ledger.subprocess, "run", lambda *a, **k: SimpleNamespace(returncode=1))
    assert scored_ledger.reachable("abc", "HEAD", {}) is False


def test_shares_requires_commit_tools_and_measured_source():
    assert scored_ledger.shares({"commit": "c", "tools": "t", "source": "measured"}) is True
    assert scored_ledger.shares({"commit": "", "tools": "t", "source": "measured"}) is False
    assert scored_ledger.shares({"commit": "c", "tools": "", "source": "measured"}) is False
    assert scored_ledger.shares({"commit": "c", "tools": "t", "source": "marked"}) is False


def test_borrowable_missing_record_is_false():
    assert scored_ledger.borrowable({}, "a.go", "blob1", {"tools": "t", "head": "HEAD"}, {}) is False


def test_borrowable_tools_mismatch_is_false():
    shared = {"a.go": {"blob1": {"tools": "other", "source": "measured", "commit": "c"}}}
    assert scored_ledger.borrowable(shared, "a.go", "blob1", {"tools": "t", "head": "HEAD"}, {}) is False


def test_borrowable_non_measured_source_is_false():
    shared = {"a.go": {"blob1": {"tools": "t", "source": "marked", "commit": "c"}}}
    assert scored_ledger.borrowable(shared, "a.go", "blob1", {"tools": "t", "head": "HEAD"}, {}) is False


def test_borrowable_true_when_reachable(monkeypatch):
    shared = {"a.go": {"blob1": {"tools": "t", "source": "measured", "commit": "c"}}}
    monkeypatch.setattr(scored_ledger, "reachable", lambda commit, head, cache: True)
    assert scored_ledger.borrowable(shared, "a.go", "blob1", {"tools": "t", "head": "HEAD"}, {}) is True


def test_borrowable_missing_commit_is_false():
    shared = {"a.go": {"blob1": {"tools": "t", "source": "measured", "commit": ""}}}
    assert scored_ledger.borrowable(shared, "a.go", "blob1", {"tools": "t", "head": "HEAD"}, {}) is False


def test_classify_scored_match_returns_its_source():
    scored = {"a.go": {"blob": "blob1", "source": "marked"}}
    assert scored_ledger.classify("a.go", "blob1", scored, {}, {"tools": "t", "head": "H"}, {}) == "marked"


def test_classify_falls_back_to_borrowed(monkeypatch):
    shared = {"a.go": {"blob1": {"tools": "t", "source": "measured", "commit": "c"}}}
    monkeypatch.setattr(scored_ledger, "reachable", lambda *a, **k: True)
    assert scored_ledger.classify("a.go", "blob1", {}, shared, {"tools": "t", "head": "H"}, {}) == "borrowed"


def test_classify_unscored_when_nothing_matches():
    assert scored_ledger.classify("a.go", "blob1", {}, {}, {"tools": "t", "head": "H"}, {}) == "unscored"


def test_do_record_writes_ledger_and_optionally_shares(tmp_path, capsys):
    path = tmp_path / "ledger.json"
    monkeypatch_stdin = io.StringIO("a.go blob1\nb.go blob2\n")
    import sys
    sys.stdin = monkeypatch_stdin
    opts = scored_ledger.parse_opts(["measured", "--commit", "c1", "--tools", "fp"])
    rc = scored_ledger.do_record(str(path), "br", opts)
    assert rc == 0
    store = json.loads(path.read_text())
    assert store["br"]["a.go"] == {"blob": "blob1", "source": "measured"}
    assert store[".." + "blobs"]["a.go"]["blob1"]["commit"] == "c1"
    assert "scored=2 source=measured" in capsys.readouterr().out


def test_do_record_without_sharing_does_not_write_shared_namespace(tmp_path):
    path = tmp_path / "ledger.json"
    import sys
    sys.stdin = io.StringIO("a.go blob1\n")
    opts = scored_ledger.parse_opts(["marked"])
    scored_ledger.do_record(str(path), "br", opts)
    store = json.loads(path.read_text())
    assert store["br"]["a.go"] == {"blob": "blob1", "source": "marked"}
    assert scored_ledger.SHARED not in store


def test_do_anchor_no_sharing_is_a_no_op(tmp_path):
    path = tmp_path / "ledger.json"
    opts = scored_ledger.parse_opts([])
    assert scored_ledger.do_anchor(str(path), "br", opts) == 0
    assert not path.exists()


def test_do_anchor_only_anchors_measured_matching_blobs(tmp_path, capsys):
    path = tmp_path / "ledger.json"
    path.write_text(json.dumps({
        "br": {
            "a.go": {"blob": "blob1", "source": "measured"},
            "b.go": {"blob": "blob2", "source": "marked"},
            "c.go": {"blob": "blob3", "source": "measured"},
        }
    }))
    import sys
    sys.stdin = io.StringIO("a.go blob1\nb.go blob2\nc.go different-blob\n")
    opts = scored_ledger.parse_opts(["measured", "--commit", "c1", "--tools", "fp"])
    rc = scored_ledger.do_anchor(str(path), "br", opts)
    assert rc == 0
    store = json.loads(path.read_text())
    assert list(store[scored_ledger.SHARED].keys()) == ["a.go"]
    assert "anchored=1" in capsys.readouterr().out


def test_do_verify_all_scored_returns_zero(tmp_path):
    path = tmp_path / "ledger.json"
    path.write_text(json.dumps({"br": {"a.go": {"blob": "blob1", "source": "measured"}}}))
    import sys
    sys.stdin = io.StringIO("a.go blob1\n")
    opts = scored_ledger.parse_opts([])
    assert scored_ledger.do_verify(str(path), "br", opts) == 0


def test_do_verify_reports_unscored_and_branch_unknown(tmp_path, capsys):
    path = tmp_path / "ledger.json"
    path.write_text(json.dumps({}))
    import sys
    sys.stdin = io.StringIO("a.go blob1\n")
    opts = scored_ledger.parse_opts([])
    rc = scored_ledger.do_verify(str(path), "br", opts)
    assert rc == 1
    out = capsys.readouterr().out
    assert "branch_unknown=1" in out
    assert "unscored=a.go" in out


def test_do_verify_reports_marked_entries(tmp_path, capsys):
    path = tmp_path / "ledger.json"
    path.write_text(json.dumps({"br": {"a.go": {"blob": "blob1", "source": "marked"}}}))
    import sys
    sys.stdin = io.StringIO("a.go blob1\n")
    opts = scored_ledger.parse_opts([])
    rc = scored_ledger.do_verify(str(path), "br", opts)
    assert rc == 0
    assert "marked=a.go" in capsys.readouterr().out


def test_do_verify_borrows_from_shared_namespace(tmp_path, capsys, monkeypatch):
    path = tmp_path / "ledger.json"
    path.write_text(json.dumps({
        "..blobs": {"a.go": {"blob1": {"tools": "fp", "source": "measured", "commit": "c1"}}},
    }))
    import sys
    sys.stdin = io.StringIO("a.go blob1\n")
    monkeypatch.setattr(scored_ledger, "reachable", lambda *a, **k: True)
    opts = scored_ledger.parse_opts(["--borrow", "--tools", "fp", "--head", "HEAD"])
    rc = scored_ledger.do_verify(str(path), "br", opts)
    assert rc == 0
    assert "borrowed=a.go" in capsys.readouterr().out


def test_do_verify_merges_legacy_ledger(tmp_path):
    path = tmp_path / "ledger.json"
    path.write_text(json.dumps({}))
    legacy = tmp_path / "legacy.json"
    legacy.write_text(json.dumps({"br": {"a.go": {"blob": "blob1", "source": "measured"}}}))
    import sys
    sys.stdin = io.StringIO("a.go blob1\n")
    opts = scored_ledger.parse_opts(["--legacy", str(legacy)])
    assert scored_ledger.do_verify(str(path), "br", opts) == 0


def test_main_record_rejects_invalid_source(monkeypatch, tmp_path, capsys):
    path = tmp_path / "ledger.json"
    monkeypatch.setattr("sys.argv", ["scored_ledger.py", "record", str(path), "br", "bogus"])
    rc = scored_ledger.main()
    assert rc == 2
    assert "source must be measured or marked" in capsys.readouterr().err


def test_main_dispatches_record_anchor_and_verify(monkeypatch, tmp_path):
    path = tmp_path / "ledger.json"
    monkeypatch.setattr("sys.stdin", io.StringIO("a.go blob1\n"))
    monkeypatch.setattr("sys.argv", ["scored_ledger.py", "record", str(path), "br"])
    assert scored_ledger.main() == 0

    monkeypatch.setattr("sys.stdin", io.StringIO("a.go blob1\n"))
    monkeypatch.setattr("sys.argv", ["scored_ledger.py", "anchor", str(path), "br"])
    assert scored_ledger.main() == 0

    monkeypatch.setattr("sys.stdin", io.StringIO("a.go blob1\n"))
    monkeypatch.setattr("sys.argv", ["scored_ledger.py", "verify", str(path), "br"])
    assert scored_ledger.main() == 0
