import json
import math

import pytest

import change_signals as cs
import crap_rows
import signal_base as sb

UNMEASURED = "unmeasured"
ENV = {"TOUCHSTONE_DEADCODE_VERSION": "v1"}


def ctx_of(repo, base, head, **config):
    settings = sb.Settings(**{"unsupported": (), "exempt": (), "deadcode_version": "v1", **config})
    return sb.load_ctx(str(repo.root), f"{base}..{head}", settings)


def lines(n, prefix="l"):
    return "".join(f"{prefix}{i}\n" for i in range(1, n + 1))


@pytest.fixture
def sized(repo):
    repo.write("a.py", lines(10))
    repo.write("b.go", lines(5))
    repo.write("bin.dat", b"\x00\x01")
    repo.write("keep.txt", "same\n")
    base = repo.commit("base")
    head_a = lines(10).replace("l2\n", "") + lines(3, "new")
    repo.write("a.py", head_a)
    (repo.root / "b.go").unlink()
    repo.write("src/d.py", lines(6))
    repo.write("bin.dat", b"\x00\x02")
    head = repo.commit("head")
    return ctx_of(repo, base, head)


def test_the_lines_added_and_removed_leave_out_binary_files(sized):
    got = cs.size_lines(sized)
    assert got["la"]["value"] == 9
    assert got["ld"]["value"] == 6


def test_the_lines_of_touched_files_are_counted_at_the_base_and_new_files_are_zero(sized):
    assert cs.size_lines(sized)["lt"]["value"] == 15


def test_added_over_touched_is_rounded_to_three_places(sized):
    assert cs.size_lines(sized)["la_lt"]["value"] == 0.6


def test_added_over_touched_keeps_three_decimals(repo):
    repo.write("a.py", lines(3))
    base = repo.commit("base")
    repo.write("a.py", lines(3) + "x\n")
    head = repo.commit("head")
    assert cs.size_lines(ctx_of(repo, base, head))["la_lt"]["value"] == 0.333


def test_the_size_evidence_names_the_command_and_shows_the_numstat(sized):
    got = cs.size_lines(sized)
    command = f"git diff --numstat --no-renames {sized.base} {sized.head}"
    for name in ("la", "ld"):
        assert got[name]["evidence"]["command"] == command
        assert got[name]["evidence"]["exit"] == 0
    assert "3\t1\ta.py" in got["la"]["evidence"]["output"]
    assert "-\t-\tbin.dat" in got["la"]["evidence"]["output"]
    assert got["lt"]["evidence"]["output"] == "3 touched text file(s)"
    assert got["la_lt"]["evidence"]["output"] == "9 / 15"


def test_added_over_touched_is_unmeasured_when_the_base_side_is_empty(repo):
    repo.write("README.md", "x\n")
    base = repo.commit("base")
    repo.write("new.py", lines(4))
    head = repo.commit("head")
    got = cs.size_lines(ctx_of(repo, base, head))
    assert got["la"]["value"] == 4
    assert got["lt"]["value"] == 0
    assert got["la_lt"]["value"] == UNMEASURED
    assert got["la_lt"]["reason"] == "the touched files have no lines at the base, so there is no ratio"


def test_an_empty_range_has_zero_lines_and_no_ratio(repo):
    repo.write("a.py", "x\n")
    base = repo.commit("base")
    head = repo.commit("empty")
    got = cs.size_lines(ctx_of(repo, base, head))
    assert [got[n]["value"] for n in ("la", "ld", "lt")] == [0, 0, 0]
    assert got["la_lt"]["value"] == UNMEASURED


@pytest.mark.parametrize("text,count", [("", 0), ("one", 1), ("one\n", 1), ("one\ntwo", 2), ("one\n\n", 2)])
def test_base_lines_counts_a_last_line_without_a_newline(repo, text, count):
    repo.write("f.txt", text)
    base = repo.commit("base")
    repo.write("f.txt", text + "more\n")
    head = repo.commit("head")
    assert cs.size_lines(ctx_of(repo, base, head))["lt"]["value"] == count


def test_files_and_directories_count_every_changed_path_including_binaries(sized):
    got = cs.spread(sized)
    assert got["files"]["value"] == 4
    assert got["directories"]["value"] == 2


def test_the_spread_evidence_lists_what_it_counted(sized):
    got = cs.spread(sized)
    assert got["files"]["evidence"]["output"] == "a.py\nb.go\nbin.dat\nsrc/d.py"
    assert got["directories"]["evidence"]["output"] == ".\nsrc"
    assert got["files"]["evidence"]["command"] == f"git diff --numstat --no-renames {sized.base} {sized.head}"


def test_files_in_one_directory_count_it_once(repo):
    repo.write("a/x.py", "1\n")
    base = repo.commit("base")
    repo.write("a/x.py", "2\n")
    repo.write("a/y.py", "2\n")
    repo.write("a/b/z.py", "2\n")
    head = repo.commit("head")
    got = cs.spread(ctx_of(repo, base, head))
    assert (got["files"]["value"], got["directories"]["value"]) == (3, 2)


@pytest.mark.parametrize("path", [
    "go.mod", "go.sum", "composer.json", "composer.lock", "pyproject.toml", "uv.lock",
    "requirements.txt", "requirements-dev.txt", "svc/go.mod", "a/b/requirements_test.txt",
])
def test_dependency_surface_is_true_for_a_dependency_manifest(repo, path):
    repo.write(path, "x\n")
    base = repo.commit("base")
    repo.write(path, "y\n")
    head = repo.commit("head")
    got = cs.dependency_surface(ctx_of(repo, base, head))
    assert got["value"] is True
    assert got["evidence"]["output"] == path


@pytest.mark.parametrize("path", [
    "go.modx", "mygo.mod", "requirements.md", "docs/requirements", "composer.json.bak", "pyproject.toml.orig",
    "src/go.mod.go", "README.md",
])
def test_dependency_surface_is_false_for_anything_else(repo, path):
    repo.write(path, "x\n")
    base = repo.commit("base")
    repo.write(path, "y\n")
    head = repo.commit("head")
    got = cs.dependency_surface(ctx_of(repo, base, head))
    assert got["value"] is False
    assert got["evidence"]["output"] == ""


def test_dependency_surface_lists_every_manifest_that_changed(repo):
    repo.write("a.py", "x\n")
    base = repo.commit("base")
    repo.write("go.mod", "m\n")
    repo.write("a.py", "y\n")
    repo.write("uv.lock", "m\n")
    head = repo.commit("head")
    got = cs.dependency_surface(ctx_of(repo, base, head))
    assert got["evidence"]["output"] == "go.mod\nuv.lock"
    assert got["evidence"]["command"] == f"git diff --numstat --no-renames {base} {head}"


@pytest.fixture
def rows_repo(repo):
    repo.write("a.py", "x\n")
    base = repo.commit("base")
    repo.write("a.py", "y\n")
    head = repo.commit("head")
    return repo, ctx_of(repo, base, head)


def record(repo, text, branch="feat"):
    crap_rows.record(str(repo.root / ".git" / "crap-check-rows.json"), branch, text)


ROWS = (
    "lib/a.py::f  complexity=2  coverage=100.0%  CRAP=2.0  OK  (new)\n"
    "lib/a.py::g  complexity=7  coverage=62.5%   CRAP=7.5  OK  (worsened)\n"
    "lib/a.py::h  complexity=9  coverage=10.0%   CRAP=12.0  OK  (unchanged)\n"
)


def test_crap_max_and_coverage_min_read_the_new_and_worsened_rows_only(rows_repo):
    repo, ctx = rows_repo
    record(repo, ROWS)
    got = cs.crap_signals(ctx)
    assert got["crap_max"]["value"] == 7.5
    assert got["coverage_min"]["value"] == 62.5


def test_the_crap_evidence_names_the_record_and_the_row_it_came_from(rows_repo):
    repo, ctx = rows_repo
    record(repo, ROWS)
    got = cs.crap_signals(ctx)
    path = str(repo.root / ".git" / "crap-check-rows.json")
    assert got["crap_max"]["evidence"] == {
        "command": f"read {path} [feat]", "exit": 0, "output": "lib/a.py::g CRAP=7.5 (2 row(s))"}
    assert got["coverage_min"]["evidence"]["output"] == "lib/a.py::g coverage=62.5 (2 row(s))"


def test_a_row_without_a_number_is_left_out(rows_repo):
    repo, ctx = rows_repo
    record(repo, ROWS + "lib/m.py::main  complexity=3  coverage=n/a  CRAP=n/a  OK_MAIN  (new)\n")
    got = cs.crap_signals(ctx)
    assert got["crap_max"]["value"] == 7.5
    assert got["coverage_min"]["value"] == 62.5


def test_crap_signals_are_unmeasured_when_no_row_has_a_number(rows_repo):
    repo, ctx = rows_repo
    record(repo, "lib/m.py::main  complexity=3  coverage=n/a  CRAP=n/a  OK_MAIN  (new)\n")
    got = cs.crap_signals(ctx)
    for name in ("crap_max", "coverage_min"):
        assert got[name]["value"] == UNMEASURED
        assert got[name]["reason"].startswith("no CRAP row tagged new or worsened with a ")


def test_crap_signals_are_unmeasured_without_a_record(rows_repo):
    repo, ctx = rows_repo
    got = cs.crap_signals(ctx)
    assert got["crap_max"]["value"] == UNMEASURED
    assert got["crap_max"]["reason"] == "no CRAP row tagged new or worsened with a CRAP score on branch feat"
    assert got["coverage_min"]["reason"] == "no CRAP row tagged new or worsened with a coverage on branch feat"


def test_crap_signals_ignore_rows_of_other_branches(rows_repo):
    repo, ctx = rows_repo
    record(repo, ROWS, branch="other")
    assert cs.crap_signals(ctx)["crap_max"]["value"] == UNMEASURED


def test_crap_signals_are_unmeasured_when_only_unchanged_rows_exist(rows_repo):
    repo, ctx = rows_repo
    record(repo, "lib/a.py::h  complexity=9  coverage=10.0%  CRAP=12.0  OK  (unchanged)\n")
    assert cs.crap_signals(ctx)["coverage_min"]["value"] == UNMEASURED


def test_crap_signals_read_the_branch_of_a_detached_head_as_detached(rows_repo):
    repo, ctx = rows_repo
    repo.git("checkout", "-q", "--detach")
    record(repo, ROWS, branch="detached")
    assert cs.crap_signals(ctx)["crap_max"]["value"] == 7.5


def test_crap_signals_read_the_record_of_a_linked_worktree_from_its_own_git_dir(rows_repo, tmp_path):
    repo, ctx = rows_repo
    repo.git("branch", "other")
    work = tmp_path / "wt"
    repo.git("worktree", "add", "-q", str(work), "other")
    git_dir = repo.git("-C", str(work), "rev-parse", "--absolute-git-dir")
    crap_rows.record(f"{git_dir}/crap-check-rows.json", "other", ROWS)
    linked = ctx._replace(repo=str(work))
    assert cs.crap_signals(linked)["crap_max"]["value"] == 7.5


def runs_dir(repo):
    return repo.root / ".claude" / "touchstone-runs"


def finding(file, outcome="reproduced", **fields):
    return {"id": "f1", "file": file, "reproducer_run": {"outcome": outcome, "exit_code": 1}, **fields}


def record_run(repo, name, findings, **fields):
    repo.write(f".claude/touchstone-runs/{name}.json", json.dumps({"unresolved_findings": findings, **fields}))


@pytest.fixture
def defect_repo(repo):
    for name in ("a.py", "b.py", "c.py", "d.py"):
        repo.write(name, "x\n")
    base = repo.commit("base")
    for name in ("a.py", "b.py", "d.py"):
        repo.write(name, "y\n")
    head = repo.commit("head")
    return repo, ctx_of(repo, base, head)


def test_defect_files_counts_range_files_that_an_earlier_run_reproduced_a_defect_in(defect_repo):
    repo, ctx = defect_repo
    record_run(repo, "21", [finding("a.py"), finding("b.py", outcome="passed"), finding("c.py")])
    record_run(repo, "22", [finding("a.py"), finding("./d.py")])
    got = cs.defect_files(ctx)
    assert got["value"] == 2
    assert got["evidence"]["output"] == "a.py\nd.py"
    assert got["evidence"]["exit"] == 0
    assert got["evidence"]["command"] == f"read {runs_dir(repo)}/*.json"


def test_defect_files_is_zero_when_no_record_names_a_range_file(defect_repo):
    repo, ctx = defect_repo
    record_run(repo, "21", [finding("c.py")])
    record_run(repo, "22", [])
    got = cs.defect_files(ctx)
    assert got["value"] == 0
    assert got["evidence"]["output"] == "no reproduced defect in a range file, in 2 record(s)"


def test_defect_files_skips_records_that_cannot_be_read_or_are_malformed(defect_repo):
    repo, ctx = defect_repo
    repo.write(".claude/touchstone-runs/bad.json", "{not json")
    repo.write(".claude/touchstone-runs/list.json", "[1, 2]")
    repo.write(".claude/touchstone-runs/nofindings.json", json.dumps({"task": "t"}))
    repo.write(".claude/touchstone-runs/odd.json", json.dumps({"unresolved_findings": "none"}))
    record_run(repo, "ok", ["not a dict", {"file": "a.py"}, {"file": 3, "reproducer_run": {"outcome": "reproduced"}},
                            {"file": "b.py", "reproducer_run": "reproduced"}, finding("a.py")])
    got = cs.defect_files(ctx)
    assert got["value"] == 1
    assert got["evidence"]["output"] == "a.py"


def test_defect_files_is_unmeasured_without_a_records_directory(defect_repo):
    repo, ctx = defect_repo
    got = cs.defect_files(ctx)
    assert got["value"] == UNMEASURED
    assert got["reason"] == f"no run records directory at {runs_dir(repo)}"


def test_defect_files_reads_the_main_checkouts_records_from_a_linked_worktree(defect_repo, tmp_path):
    repo, ctx = defect_repo
    record_run(repo, "21", [finding("a.py")])
    repo.git("branch", "other")
    work = tmp_path / "wt"
    repo.git("worktree", "add", "-q", str(work), "other")
    got = cs.defect_files(ctx._replace(repo=str(work)))
    assert got["value"] == 1


def test_every_signal_has_exactly_one_producer():
    produced = [name for names, _ in cs.PRODUCERS for name in names]
    assert sorted(produced) == sorted(cs.NAMES)
    assert len(cs.NAMES) == 14


def test_compute_gives_every_name_in_order_with_a_value_and_evidence(sized, stubs):
    got = cs.compute(sized)
    assert list(got) == list(cs.NAMES)
    for name, found in got.items():
        value = found["value"]
        assert value is True or value is False or value == UNMEASURED or (
            isinstance(value, (int, float)) and math.isfinite(value)), name
        assert set(found["evidence"]) == {"command", "exit", "output"}
        assert (value == UNMEASURED) == ("reason" in found and found["reason"] != ""), name


def test_a_producer_that_crashes_makes_only_its_own_signals_unmeasured(sized, stubs, monkeypatch):
    def boom(ctx):
        raise RuntimeError("kaboom")

    producers = tuple((names, boom if names[0] == "files" else fn) for names, fn in cs.PRODUCERS)
    monkeypatch.setattr(cs, "PRODUCERS", producers)
    got = cs.compute(sized)
    for name in ("files", "directories"):
        assert got[name]["value"] == UNMEASURED
        assert got[name]["reason"] == f"{name} failed: RuntimeError: kaboom"
    assert got["la"]["value"] == 9


def test_render_prints_the_markers_around_one_compact_json_line():
    values = {"la": sb.signal(3, command="c", code=0, output="o")}
    text = cs.render("a..b", values)
    first, body, last = text.split("\n")[:3]
    assert (first, last) == ("TOUCHSTONE_SIGNALS a..b", "TOUCHSTONE_SIGNALS_END")
    assert text.endswith("TOUCHSTONE_SIGNALS_END\n")
    assert body == '{"range":"a..b","values":{"la":{"value":3,"evidence":{"command":"c","exit":0,"output":"o"}}}}'


def run_main(capsys, argv, env=ENV):
    code = cs.main(argv, env)
    out = capsys.readouterr()
    return code, out.out, out.err


def test_main_prints_the_signals_for_the_range_and_nothing_else(sized, stubs, capsys):
    code, out, err = run_main(capsys, [sized.repo, sized.rng])
    lines_ = out.split("\n")
    assert code == 0 and err == ""
    assert lines_[0] == f"TOUCHSTONE_SIGNALS {sized.rng}"
    assert lines_[2] == "TOUCHSTONE_SIGNALS_END" and lines_[3] == ""
    body = json.loads(lines_[1])
    assert body["range"] == sized.rng
    assert list(body["values"]) == list(cs.NAMES)
    assert body["values"]["la"]["value"] == 9


def test_main_hands_the_settings_from_the_environment_to_the_signals(repo, stubs, capsys):
    repo.write("README.md", "x\n")
    repo.write("web/app.ts", "let a\n")
    base = repo.commit("base")
    repo.write("README.md", "y\n")
    repo.write("web/app.ts", "let b\n")
    head = repo.commit("head")
    rng = f"{base}..{head}"
    env = {**ENV, "TOUCHSTONE_UNSUPPORTED_SPEC": "*.ts\n"}
    _, out, _ = run_main(capsys, [str(repo.root), rng], env)
    api = json.loads(out.split("\n")[1])["values"]["api_broken"]
    assert api["value"] == UNMEASURED and "web/app.ts" in api["reason"]
    env["TOUCHSTONE_EXEMPT_SPEC"] = ":(glob,exclude,top)web/**\n"
    _, out, _ = run_main(capsys, [str(repo.root), rng], env)
    api = json.loads(out.split("\n")[1])["values"]["api_broken"]
    assert api["reason"] == "no Go, PHP or Python file changed"


@pytest.mark.parametrize("argv", [[], ["only-one"], ["a", "b", "c"]])
def test_main_refuses_the_wrong_number_of_arguments(capsys, argv):
    code, out, err = run_main(capsys, argv)
    assert code == 2 and out == ""
    assert err.startswith("usage: change-signals.sh <absolute-repo-path> <base>..<head>")


def test_main_refuses_a_range_it_cannot_resolve(sized, capsys):
    code, out, err = run_main(capsys, [sized.repo, f"{sized.base}..nope"])
    assert (code, out) == (2, "")
    assert err == "change-signals: cannot resolve nope\n"


def test_main_refuses_a_malformed_range(sized, capsys):
    code, out, err = run_main(capsys, [sized.repo, "nodots"])
    assert (code, out) == (2, "")
    assert "range must be <base>..<head>" in err


def test_main_refuses_a_missing_deadcode_version(sized, capsys):
    code, out, err = run_main(capsys, [sized.repo, sized.rng], env={})
    assert (code, out) == (2, "")
    assert "TOUCHSTONE_DEADCODE_VERSION" in err


def test_main_reads_the_process_environment_by_default(sized, stubs, capsys, monkeypatch):
    monkeypatch.setenv("TOUCHSTONE_DEADCODE_VERSION", "v1")
    monkeypatch.setattr("sys.argv", ["change_signals.py", sized.repo, sized.rng])
    assert cs.main() == 0
    assert capsys.readouterr().out.startswith("TOUCHSTONE_SIGNALS ")
