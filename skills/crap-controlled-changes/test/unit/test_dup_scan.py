"""dup_scan.py against a throwaway repo, with dryer replaced by a stand-in.

The stand-in reads "<name> <start> <end> <nodes> <fp>,<fp>,..." lines as the
forms a file contains, so a test states the structure it wants compared instead
of writing code a parser would have to agree with.
"""

import hashlib
import sys
import types
from dataclasses import dataclass

import pytest

import dup_scan

BODY = "a,b,c,d,e,f,g,h,i"
CLOSE = "a,b,c,d,e,f,g,h,j"
OTHER = "p,q,r,s,t,u,v,w,x"


@dataclass(frozen=True)
class Entry:
    language: str
    file: str
    start_line: int
    end_line: int
    nodes: int
    fingerprints: frozenset


def form(name, fingerprints, start=1, end=10, nodes=30):
    return f"{name} {start} {end} {nodes} {fingerprints}\n"


@pytest.fixture
def dryer(monkeypatch):
    def language_of(path):
        return {".py": "python", ".go": "go", ".txt": "text"}.get(str(path)[str(path).rfind("."):])

    def entries_in_source(language, source, path, file):
        found = []
        for line in source.splitlines():
            _, start, end, nodes, fps = line.split()
            found.append(Entry(language, file, int(start), int(end), int(nodes),
                               frozenset(fps.split(","))))
        return found, None

    def jaccard(left, right):
        return len(left & right) / len(left | right)

    def module(name, **attributes):
        made = types.ModuleType(name)
        vars(made).update(attributes)
        monkeypatch.setitem(sys.modules, name, made)

    module("dryer")
    module("dryer.discover", language_of=language_of)
    module("dryer.extract", entries_in_source=entries_in_source)
    module("dryer.shape", jaccard=jaccard)


def key_of(path, fingerprints):
    digest = hashlib.sha1("\n".join(sorted(fingerprints.split(","))).encode()).hexdigest()
    return f"{path}#{digest[:12]}"


def scan(repo, staged, threshold=0.8, pool=None, extra=()):
    lists = repo.root.parent
    (lists / "staged.txt").write_text("".join(f"{p}\n" for p in staged))
    pool = staged if pool is None else pool
    (lists / "pool.txt").write_text("".join(f"{p}\n" for p in pool))
    return dup_scan.main(["--root", str(repo.root), "--threshold", str(threshold),
                          "--staged", str(lists / "staged.txt"),
                          "--pool", str(lists / "pool.txt"), *extra])


def committed(repo, files):
    for path, content in files.items():
        repo.write(path, content)
    repo.commit("base")


def stage(repo, files):
    for path, content in files.items():
        repo.write(path, content)
    repo.git("add", "-A")


def test_a_new_function_matching_an_existing_one_is_reported(repo, dryer, capsys):
    committed(repo, {"a.py": form("f", BODY)})
    stage(repo, {"b.py": form("g", CLOSE, start=4, end=15)})
    assert scan(repo, ["b.py"], pool=["a.py", "b.py"]) == 0
    assert capsys.readouterr().out == (
        "DUPLICATE score=0.80 a.py:1-10 b.py:4-15 "
        f"key={'|'.join(sorted([key_of('a.py', BODY), key_of('b.py', CLOSE)]))}\n")


def test_a_pair_below_the_threshold_is_not_reported(repo, dryer, capsys):
    committed(repo, {"a.py": form("f", BODY)})
    stage(repo, {"b.py": form("g", CLOSE)})
    scan(repo, ["b.py"], threshold=0.81, pool=["a.py", "b.py"])
    assert capsys.readouterr().out == ""


def test_a_pair_exactly_at_the_threshold_is_reported(repo, dryer, capsys):
    committed(repo, {"a.py": form("f", BODY)})
    stage(repo, {"b.py": form("g", CLOSE)})
    scan(repo, ["b.py"], threshold=0.8, pool=["a.py", "b.py"])
    assert "DUPLICATE" in capsys.readouterr().out


def test_a_duplicate_already_at_head_is_not_introduced_by_an_unrelated_edit(repo, dryer, capsys):
    committed(repo, {"a.py": form("f", BODY), "b.py": form("g", BODY)})
    stage(repo, {"b.py": form("g", BODY) + form("extra", OTHER, start=20, end=30)})
    scan(repo, ["b.py"], pool=["a.py", "b.py"])
    assert capsys.readouterr().out == ""


def test_editing_a_function_that_is_already_duplicated_introduces_it_anew(repo, dryer, capsys):
    committed(repo, {"a.py": form("f", BODY), "b.py": form("g", BODY)})
    stage(repo, {"b.py": form("g", CLOSE)})
    scan(repo, ["b.py"], pool=["a.py", "b.py"])
    assert "DUPLICATE" in capsys.readouterr().out


def test_a_third_copy_in_one_file_is_introduced(repo, dryer, capsys):
    two = form("f", BODY, 1, 10) + form("g", BODY, 11, 20)
    committed(repo, {"a.py": two})
    stage(repo, {"a.py": two + form("h", BODY, 21, 30)})
    scan(repo, ["a.py"])
    out = capsys.readouterr().out.splitlines()
    assert len(out) == 3
    assert all(line.startswith("DUPLICATE score=1.00 a.py:") for line in out)


def test_a_new_file_has_nothing_at_head_to_count_against(repo, dryer, capsys):
    committed(repo, {"a.py": form("f", BODY)})
    stage(repo, {"b.py": form("g", BODY)})
    scan(repo, ["b.py"], pool=["a.py", "b.py"])
    assert capsys.readouterr().out.count("DUPLICATE") == 1


def test_a_pair_is_introduced_when_only_the_other_side_is_new(repo, dryer, capsys):
    committed(repo, {"a.py": form("f", BODY)})
    stage(repo, {"a.py": form("f", BODY) + form("extra", OTHER, 20, 30), "b.py": form("g", BODY)})
    scan(repo, ["a.py", "b.py"])
    assert capsys.readouterr().out.count("DUPLICATE") == 1


def test_a_pair_with_both_sides_staged_is_reported_once(repo, dryer, capsys):
    stage(repo, {"a.py": form("f", BODY), "b.py": form("g", BODY)})
    scan(repo, ["a.py", "b.py"])
    assert capsys.readouterr().out.count("DUPLICATE") == 1


def test_a_form_is_never_paired_with_itself(repo, dryer, capsys):
    stage(repo, {"a.py": form("f", BODY)})
    scan(repo, ["a.py"])
    assert capsys.readouterr().out == ""


def test_forms_in_different_languages_are_not_compared(repo, dryer, capsys):
    committed(repo, {"a.py": form("f", BODY)})
    stage(repo, {"b.go": form("g", BODY)})
    scan(repo, ["b.go"], pool=["a.py", "b.go"])
    assert capsys.readouterr().out == ""


def test_two_files_in_a_language_dryer_does_not_know_are_not_compared(repo, dryer, capsys):
    stage(repo, {"a.txt": form("f", BODY), "b.txt": form("g", BODY)})
    scan(repo, ["a.txt", "b.txt"])
    assert capsys.readouterr().out == ""


def test_a_short_form_is_ignored(repo, dryer, capsys):
    committed(repo, {"a.py": form("f", BODY)})
    stage(repo, {"b.py": form("g", BODY, start=1, end=3)})
    scan(repo, ["b.py"], pool=["a.py", "b.py"])
    assert capsys.readouterr().out == ""


def test_a_form_of_exactly_the_minimum_size_is_compared(repo, dryer, capsys):
    committed(repo, {"a.py": form("f", BODY, start=1, end=4, nodes=20)})
    stage(repo, {"b.py": form("g", BODY, start=1, end=4, nodes=20)})
    scan(repo, ["b.py"], pool=["a.py", "b.py"])
    assert "DUPLICATE" in capsys.readouterr().out


def test_a_form_with_too_few_nodes_is_ignored(repo, dryer, capsys):
    committed(repo, {"a.py": form("f", BODY, nodes=19)})
    stage(repo, {"b.py": form("g", BODY, nodes=19)})
    scan(repo, ["b.py"], pool=["a.py", "b.py"])
    assert capsys.readouterr().out == ""


def test_a_file_in_a_language_dryer_does_not_know_is_skipped(repo, dryer, capsys):
    committed(repo, {"a.py": form("f", BODY)})
    stage(repo, {"notes.txt": form("g", BODY)})
    scan(repo, ["notes.txt"], pool=["a.py", "notes.txt"])
    assert capsys.readouterr().out == ""


def test_the_index_version_is_scanned_not_the_working_tree(repo, dryer, capsys):
    committed(repo, {"a.py": form("f", BODY)})
    stage(repo, {"b.py": form("g", OTHER)})
    repo.write("b.py", form("g", BODY))
    scan(repo, ["b.py"], pool=["a.py", "b.py"])
    assert capsys.readouterr().out == ""


def test_bytes_that_are_not_utf8_do_not_stop_the_scan(repo, dryer, capsys):
    committed(repo, {"a.py": form("f", BODY)})
    stage(repo, {"b.py": form("g", BODY).encode() + b"\xff\xfe 1 1 1 z\n"})
    scan(repo, ["b.py"], pool=["a.py", "b.py"])
    assert capsys.readouterr().out.count("DUPLICATE") == 1


def test_output_is_ordered_by_score_then_position(repo, dryer, capsys):
    committed(repo, {"a.py": form("f", BODY, 1, 10) + form("g", CLOSE, 11, 20)})
    stage(repo, {"b.py": form("h", BODY)})
    scan(repo, ["b.py"], pool=["a.py", "b.py"])
    lines = capsys.readouterr().out.splitlines()
    assert [line.split()[1] for line in lines] == ["score=1.00", "score=0.80"]


def test_a_path_that_is_not_in_the_index_has_no_forms(repo, dryer, capsys):
    committed(repo, {"a.py": form("f", BODY)})
    scan(repo, ["gone.py"], pool=["a.py", "gone.py"])
    assert capsys.readouterr().out == ""


def test_blobs_reads_the_index_and_a_commit_and_says_none_when_absent(repo):
    committed(repo, {"a.py": "old\n"})
    stage(repo, {"a.py": "new\n"})
    with dup_scan.Blobs(str(repo.root)) as blobs:
        assert blobs.read(":a.py") == b"new\n"
        assert blobs.read("HEAD:a.py") == b"old\n"
        assert blobs.read("HEAD:missing.py") is None
        assert blobs.read(":a.py") == b"new\n"


def test_a_blob_reads_back_whole_when_it_holds_blank_lines(repo):
    committed(repo, {"a.py": "x\n\n\ny\n"})
    with dup_scan.Blobs(str(repo.root)) as blobs:
        assert blobs.read("HEAD:a.py") == b"x\n\n\ny\n"
        assert blobs.read("HEAD:a.py") == b"x\n\n\ny\n"


def test_a_missing_dryer_is_an_error_not_an_empty_report(repo, monkeypatch):
    monkeypatch.setitem(sys.modules, "dryer", None)
    stage(repo, {"a.py": form("f", BODY)})
    with pytest.raises(ImportError):
        scan(repo, ["a.py"])
