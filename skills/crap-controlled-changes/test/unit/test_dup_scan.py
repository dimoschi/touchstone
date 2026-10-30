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
    calls = []

    def language_of(path):
        return {".py": "python", ".go": "go", ".txt": "text"}.get(str(path)[str(path).rfind("."):])

    def entries_in_source(language, source, path, file):
        calls.append((path, file))
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
    module("dryer.discover", language_of=language_of, SKIP_DIRS={"testdata", "build"},
           is_test_file=lambda path: str(path).rsplit("/", 1)[-1].startswith("test_"))
    module("dryer.extract", entries_in_source=entries_in_source)
    module("dryer.shape", jaccard=jaccard)
    return calls


def key_of(path, fingerprints, copies=1):
    digest = hashlib.sha1("\n".join(sorted(fingerprints.split(","))).encode()).hexdigest()
    return f"{path}#{digest[:12]}x{copies}"


def scan(repo, staged, threshold=0.8, pool=None, extra=()):
    """Scan what `git diff --cached --name-status` would list: `staged` paths as
    modified, unless a name-status line is given whole."""
    lists = repo.root.parent
    changes = (p if "\t" in p else f"M\t{p}" for p in staged)
    (lists / "changes.txt").write_text("".join(f"{line}\n" for line in changes))
    paths = [p.split("\t")[-1] for p in staged if not p.startswith("D\t")]
    pool = paths if pool is None else pool
    (lists / "pool.txt").write_text("".join(f"{p}\n" for p in pool))
    return dup_scan.main(["--root", str(repo.root), "--threshold", str(threshold),
                          "--changes", str(lists / "changes.txt"),
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


def test_editing_a_function_that_is_already_duplicated_does_not_introduce_it(repo, dryer, capsys):
    committed(repo, {"a.py": form("f", BODY), "b.py": form("g", BODY)})
    stage(repo, {"b.py": form("g", CLOSE)})
    scan(repo, ["b.py"], pool=["a.py", "b.py"])
    assert capsys.readouterr().out == ""


def test_an_edit_that_brings_a_pair_up_to_the_threshold_introduces_it(repo, dryer, capsys):
    committed(repo, {"a.py": form("f", BODY), "b.py": form("g", OTHER)})
    stage(repo, {"b.py": form("g", CLOSE)})
    scan(repo, ["b.py"], pool=["a.py", "b.py"])
    assert capsys.readouterr().out.split()[2:4] == ["a.py:1-10", "b.py:1-10"]


def test_editing_a_duplicated_function_reports_only_the_partner_it_newly_matches(repo, dryer, capsys):
    committed(repo, {"a.py": form("f", BODY), "b.py": form("g", BODY), "c.py": form("h", CLOSE)})
    stage(repo, {"b.py": form("g", CLOSE)})
    scan(repo, ["b.py"], threshold=0.9, pool=["a.py", "b.py", "c.py"])
    assert [line.split()[2:4] for line in capsys.readouterr().out.splitlines()] == [
        ["b.py:1-10", "c.py:1-10"]]


def test_a_rename_introduces_no_duplicate_that_was_already_at_head(repo, dryer, capsys):
    committed(repo, {"a.py": form("f", BODY), "c.py": form("g", BODY)})
    repo.git("mv", "a.py", "b.py")
    scan(repo, ["R100\ta.py\tb.py"], pool=["b.py", "c.py"])
    assert capsys.readouterr().out == ""


def test_a_rename_that_changes_a_duplicated_functions_structure_does_not_introduce_it(repo, dryer, capsys):
    committed(repo, {"a.py": form("f", BODY), "c.py": form("g", BODY)})
    repo.git("mv", "a.py", "b.py")
    stage(repo, {"b.py": form("f", CLOSE)})
    scan(repo, ["R090\ta.py\tb.py"], pool=["b.py", "c.py"])
    assert capsys.readouterr().out == ""


def test_a_function_moved_to_another_staged_file_is_not_a_new_copy(repo, dryer, capsys):
    committed(repo, {"a.py": form("f", BODY) + form("x", OTHER, 20, 30), "c.py": form("g", BODY)})
    stage(repo, {"a.py": form("x", OTHER, 20, 30), "b.py": form("f", BODY)})
    scan(repo, ["a.py", "b.py"], pool=["a.py", "b.py", "c.py"])
    assert capsys.readouterr().out == ""


def test_a_function_moved_out_of_a_deleted_file_is_not_a_new_copy(repo, dryer, capsys):
    committed(repo, {"a.py": form("f", BODY), "c.py": form("g", BODY)})
    repo.git("rm", "-q", "a.py")
    stage(repo, {"b.py": form("f", BODY)})
    scan(repo, ["D\ta.py", "A\tb.py"], pool=["b.py", "c.py"])
    assert capsys.readouterr().out == ""


def test_a_new_copy_does_not_report_the_pair_its_siblings_already_formed(repo, dryer, capsys):
    committed(repo, {"a.py": form("f", BODY), "c.py": form("g", BODY)})
    stage(repo, {"a.py": form("f", BODY) + form("x", OTHER, 20, 30), "b.py": form("h", BODY)})
    scan(repo, ["a.py", "b.py"], pool=["a.py", "b.py", "c.py"])
    reported = [line.split()[2:4] for line in capsys.readouterr().out.splitlines()]
    assert sorted(reported) == [["a.py:1-10", "b.py:1-10"], ["b.py:1-10", "c.py:1-10"]]


def test_a_third_copy_in_one_file_is_introduced(repo, dryer, capsys):
    two = form("f", BODY, 1, 10) + form("g", BODY, 11, 20)
    committed(repo, {"a.py": two})
    stage(repo, {"a.py": two + form("h", BODY, 21, 30)})
    scan(repo, ["a.py"])
    out = capsys.readouterr().out.splitlines()
    assert len(out) == 3
    assert all(line.startswith("DUPLICATE score=1.00 a.py:") for line in out)


def test_a_key_counts_the_copies_of_a_structure_the_file_holds(repo, dryer, capsys):
    stage(repo, {"a.py": form("f", BODY, 1, 10) + form("g", BODY, 11, 20)})
    scan(repo, ["a.py"])
    key = key_of("a.py", BODY, copies=2)
    assert capsys.readouterr().out == f"DUPLICATE score=1.00 a.py:1-10 a.py:11-20 key={key}|{key}\n"


def test_a_further_copy_in_the_file_gives_every_pair_a_new_key(repo, dryer, capsys):
    stage(repo, {"a.py": "".join(form(name, BODY, start, start + 9)
                                  for name, start in (("f", 1), ("g", 11), ("h", 21)))})
    scan(repo, ["a.py"])
    key = key_of("a.py", BODY, copies=3)
    keys = [line.split("key=")[1] for line in capsys.readouterr().out.splitlines()]
    assert keys == [f"{key}|{key}"] * 3


def test_copies_in_another_file_do_not_change_a_pairs_key(repo, dryer, capsys):
    committed(repo, {"a.py": form("f", BODY), "c.py": form("g", BODY)})
    stage(repo, {"b.py": form("h", BODY)})
    scan(repo, ["b.py"], pool=["a.py", "b.py", "c.py"])
    keys = sorted(line.split("key=")[1] for line in capsys.readouterr().out.splitlines())
    assert keys == sorted([f"{key_of('a.py', BODY)}|{key_of('b.py', BODY)}",
                           f"{key_of('b.py', BODY)}|{key_of('c.py', BODY)}"])


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


def test_a_staged_file_in_a_directory_dryer_skips_is_not_scanned(repo, dryer, capsys):
    committed(repo, {"a.py": form("f", BODY)})
    stage(repo, {"pkg/testdata/b.py": form("g", BODY)})
    scan(repo, ["pkg/testdata/b.py"], pool=["a.py", "pkg/testdata/b.py"])
    assert capsys.readouterr().out == ""


def test_a_file_in_a_directory_dryer_skips_is_not_a_partner(repo, dryer, capsys):
    committed(repo, {"build/a.py": form("f", BODY)})
    stage(repo, {"b.py": form("g", BODY)})
    scan(repo, ["b.py"], pool=["build/a.py", "b.py"])
    assert capsys.readouterr().out == ""


def test_a_file_dryer_counts_as_a_test_is_not_scanned(repo, dryer, capsys):
    committed(repo, {"a.py": form("f", BODY)})
    stage(repo, {"test_b.py": form("g", BODY)})
    scan(repo, ["test_b.py"], pool=["a.py", "test_b.py"])
    assert capsys.readouterr().out == ""


def test_a_file_renamed_out_of_a_directory_dryer_skips_is_scanned_by_its_new_name(repo, dryer, capsys):
    committed(repo, {"testdata/a.py": form("f", OTHER), "c.py": form("g", BODY)})
    repo.git("mv", "testdata/a.py", "b.py")
    stage(repo, {"b.py": form("f", BODY)})
    scan(repo, ["R010\ttestdata/a.py\tb.py"], pool=["b.py", "c.py"])
    assert capsys.readouterr().out.split()[2:4] == ["b.py:1-10", "c.py:1-10"]


def test_a_copy_elsewhere_does_not_make_an_unchanged_form_in_a_grown_file_pair_new(repo, dryer, capsys):
    committed(repo, {"a.py": form("f", BODY), "g.py": form("g", BODY)})
    stage(repo, {"a.py": form("f", BODY) + form("h", CLOSE, 20, 30), "k.py": form("k", BODY)})
    scan(repo, ["a.py", "k.py"], pool=["a.py", "g.py", "k.py"])
    assert ["a.py:1-10", "g.py:1-10"] not in [
        line.split()[2:4] for line in capsys.readouterr().out.splitlines()]


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


def test_dryer_is_given_the_path_as_both_its_path_and_its_file(repo, dryer):
    stage(repo, {"a.py": form("f", BODY)})
    scan(repo, ["a.py"])
    assert dryer == [("a.py", "a.py")]


def test_blobs_starts_git_by_that_name_in_the_given_root(repo, monkeypatch):
    started = []
    real = dup_scan.subprocess.Popen

    def spy(command, **kwargs):
        started.append(command)
        return real(command, **kwargs)

    monkeypatch.setattr(dup_scan.subprocess, "Popen", spy)
    with dup_scan.Blobs(str(repo.root)):
        pass
    assert started == [["git", "-C", str(repo.root), "cat-file", "--batch"]]


def test_a_missing_name_with_spaces_in_it_reads_as_none(repo):
    committed(repo, {"a.py": "old\n"})
    with dup_scan.Blobs(str(repo.root)) as blobs:
        assert blobs.read("HEAD:my dir/missing.py") is None


def test_paths_keeps_trailing_spaces_and_letters_and_skips_blank_lines(tmp_path):
    listing = tmp_path / "paths.txt"
    listing.write_text("a b.py \n\nsrc/TeX\n")
    assert dup_scan._paths(str(listing)) == ["a b.py ", "src/TeX"]


def test_changes_pairs_the_old_path_with_the_new_one_and_none_for_a_deletion(tmp_path):
    listing = tmp_path / "changes.txt"
    listing.write_text("M\tmy dir/a.py\nR100\told name.py\tnew name.py\nD\tgone.py\nd\tlower.py\n")
    assert dup_scan._changes(str(listing)) == [
        ("my dir/a.py", "my dir/a.py"), ("old name.py", "new name.py"),
        ("gone.py", None), ("lower.py", "lower.py")]


def test_the_repository_defaults_to_the_current_directory(repo, dryer, monkeypatch, capsys):
    committed(repo, {"a.py": form("f", BODY)})
    stage(repo, {"b.py": form("g", BODY)})
    lists = repo.root.parent
    (lists / "changes.txt").write_text("M\tb.py\n")
    (lists / "pool.txt").write_text("a.py\nb.py\n")
    monkeypatch.chdir(repo.root)
    assert dup_scan.main(["--threshold", "0.8", "--changes", str(lists / "changes.txt"),
                          "--pool", str(lists / "pool.txt")]) == 0
    assert capsys.readouterr().out.count("DUPLICATE") == 1


@pytest.mark.parametrize("omitted", ["--threshold", "--changes", "--pool"])
def test_every_option_but_the_root_is_required(tmp_path, capsys, omitted):
    given = {"--threshold": "0.8", "--changes": str(tmp_path / "c"), "--pool": str(tmp_path / "p")}
    del given[omitted]
    with pytest.raises(SystemExit) as refused:
        dup_scan.main([arg for pair in given.items() for arg in pair])
    assert refused.value.code == 2
    assert omitted in capsys.readouterr().err
