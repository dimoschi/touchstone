import io
import json
import threading
import time

import pytest

import crap_rows
import scored_ledger

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


def staged_tree(repo):
    repo.git("add", "-A")
    return repo.git("write-tree")


def stored(repo, branch="feat"):
    return json.loads(open(repo.rows_path).read())[branch]


def test_record_writes_rows_under_the_branch_and_keeps_other_branches(repo):
    repo.commit("base")
    with open(repo.rows_path, "w") as f:
        json.dump({"other": {"x::y": row()}}, f)
    crap_rows.record(repo.rows_path, "feat", GREEN, str(repo.root))
    saved = json.load(open(repo.rows_path))
    assert saved["other"] == {"x::y": row()}
    assert sorted(saved["feat"]) == ["lib/a.py::f", "lib/a.py::g", "lib/a.py::h"]


def test_record_stamps_each_row_with_the_head_and_the_staged_tree_it_was_measured_against(repo):
    base = repo.commit("base")
    repo.write("a.py", "y\n")
    tree = staged_tree(repo)
    crap_rows.record(repo.rows_path, "feat", GREEN, str(repo.root))
    for fid in ("lib/a.py::f", "lib/a.py::g", "lib/a.py::h"):
        assert (stored(repo)[fid]["head"], stored(repo)[fid]["tree"]) == (base, tree)


def test_record_folds_a_second_run_into_the_first(repo):
    repo.commit("base")
    repo.land(GREEN)
    repo.land("lib/a.py::f  complexity=3   coverage=90.0%  CRAP=3.1  OK  (unchanged)\n")
    got = stored(repo)["lib/a.py::f"]
    assert (got["complexity"], got["coverage"], got["crap"], got["tag"]) == ("3", "90.0", "3.1", "new")
    assert "lib/a.py::g" in stored(repo)


def test_record_replaces_a_run_whose_commit_never_landed(repo):
    repo.commit("base")
    repo.write("a.py", "y\n")
    staged_tree(repo)
    crap_rows.record(repo.rows_path, "feat", "lib/a.py::f  complexity=9  coverage=10.0%  CRAP=9.0  OK  (new)\n",
                     str(repo.root))
    crap_rows.record(repo.rows_path, "feat", "lib/a.py::g  complexity=1  coverage=100.0%  CRAP=1.0  OK  (new)\n",
                     str(repo.root))
    assert sorted(stored(repo)) == ["lib/a.py::g"]


def test_record_drops_the_rows_of_an_earlier_attempt_at_a_branch_cut_again(repo):
    base = repo.commit("base")
    repo.land("lib/a.py::f  complexity=5  coverage=100.0%  CRAP=5.0  OK  (new)\n")
    repo.git("reset", "-q", "--hard", base)
    repo.land("lib/a.py::f  complexity=2  coverage=100.0%  CRAP=2.0  OK  (unchanged)\n"
              "lib/b.py::g  complexity=1  coverage=100.0%  CRAP=1.0  OK  (new)\n")
    assert {fid: r["tag"] for fid, r in stored(repo).items()} == {"lib/a.py::f": "unchanged", "lib/b.py::g": "new"}


def test_record_keeps_the_rows_of_the_branchs_earlier_commits(repo):
    repo.commit("base")
    repo.land("lib/a.py::f  complexity=2  coverage=100.0%  CRAP=2.0  OK  (new)\n")
    repo.land("lib/b.py::g  complexity=1  coverage=100.0%  CRAP=1.0  OK  (new)\n")
    assert sorted(stored(repo)) == ["lib/a.py::f", "lib/b.py::g"]


def test_record_keeps_every_worktrees_rows_when_runs_overlap(repo, tmp_path, monkeypatch):
    repo.commit("base")
    load = scored_ledger.load

    def slow_load(path):
        store = load(path)
        time.sleep(0.05)
        return store

    monkeypatch.setattr(scored_ledger, "load", slow_load)
    branches = [f"b{n}" for n in range(8)]
    for name in branches:
        repo.git("worktree", "add", "-q", "-b", name, str(tmp_path / name))
    threads = [threading.Thread(target=crap_rows.record, args=(repo.rows_path, name, GREEN, str(tmp_path / name)))
               for name in branches]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    assert sorted(json.load(open(repo.rows_path))) == branches


def test_latest_reads_the_rows_of_commits_in_the_history_of_the_head(repo):
    repo.commit("base")
    head = repo.land(GREEN)
    assert sorted(crap_rows.latest(repo.rows_path, "feat", str(repo.root), head)) == [
        "lib/a.py::f", "lib/a.py::g", "lib/a.py::h"]


def test_latest_leaves_out_rows_whose_commit_never_landed(repo):
    head = repo.commit("base")
    repo.write("a.py", "y\n")
    staged_tree(repo)
    crap_rows.record(repo.rows_path, "feat", GREEN, str(repo.root))
    assert crap_rows.latest(repo.rows_path, "feat", str(repo.root), head) == {}


def test_latest_leaves_out_rows_of_an_earlier_attempt_cut_again_from_the_same_base(repo):
    base = repo.commit("base")
    repo.land(GREEN)
    repo.git("reset", "-q", "--hard", base)
    head = repo.commit("work without a gate")
    assert crap_rows.latest(repo.rows_path, "feat", str(repo.root), head) == {}


def test_latest_leaves_out_rows_of_an_earlier_attempt_cut_again_from_a_newer_base(repo):
    base = repo.commit("base")
    repo.land(GREEN)
    repo.git("reset", "-q", "--hard", base)
    repo.commit("main moved on")
    head = repo.commit("work without a gate")
    assert crap_rows.latest(repo.rows_path, "feat", str(repo.root), head) == {}


def test_latest_leaves_out_rows_of_commits_after_the_head(repo):
    repo.commit("base")
    first = repo.land("lib/a.py::f  complexity=2  coverage=100.0%  CRAP=2.0  OK  (new)\n")
    repo.land("lib/b.py::g  complexity=1  coverage=100.0%  CRAP=1.0  OK  (new)\n")
    assert sorted(crap_rows.latest(repo.rows_path, "feat", str(repo.root), first)) == ["lib/a.py::f"]


def test_latest_is_empty_without_a_file_or_a_branch(repo):
    head = repo.commit("base")
    assert crap_rows.latest(repo.rows_path, "feat", str(repo.root), head) == {}
    with open(repo.rows_path, "w") as f:
        json.dump({"other": {"x::y": row()}}, f)
    assert crap_rows.latest(repo.rows_path, "feat", str(repo.root), head) == {}


def test_latest_is_empty_when_the_file_is_not_json(repo):
    head = repo.commit("base")
    with open(repo.rows_path, "w") as f:
        f.write("{broken")
    assert crap_rows.latest(repo.rows_path, "feat", str(repo.root), head) == {}


def test_latest_is_empty_for_rows_kept_without_a_head_and_tree(repo):
    head = repo.commit("base")
    with open(repo.rows_path, "w") as f:
        json.dump({"feat": {"x::y": row()}}, f)
    assert crap_rows.latest(repo.rows_path, "feat", str(repo.root), head) == {}


def test_main_records_the_rows_on_stdin(repo, monkeypatch):
    repo.commit("base")
    monkeypatch.setattr("sys.stdin", io.StringIO(GREEN))
    assert crap_rows.main(["record", repo.rows_path, "feat", str(repo.root)]) == 0
    assert sorted(stored(repo)) == ["lib/a.py::f", "lib/a.py::g", "lib/a.py::h"]


def test_main_refuses_anything_but_record(capsys):
    with pytest.raises(SystemExit) as stop:
        crap_rows.main(["forget", "rows.json", "feat", "."])
    assert stop.value.code == 2
    assert "invalid choice" in capsys.readouterr().err
