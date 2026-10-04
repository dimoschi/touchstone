import shlex
import sys

import pytest

import signal_base as sb


def run_of(code=0, out="", err="", problem="", command="tool --x"):
    return sb.Run(command=command, code=code, out=out, err=err, problem=problem)


def test_signal_carries_value_and_evidence():
    assert sb.signal(3, command="git diff", code=0, output="3 lines") == {
        "value": 3, "evidence": {"command": "git diff", "exit": 0, "output": "3 lines"}}


def test_signal_has_a_reason_only_when_given_one():
    assert "reason" not in sb.signal(True)
    assert sb.signal(sb.UNMEASURED, reason="why")["reason"] == "why"


def test_signal_cuts_the_output_to_400_characters():
    assert len(sb.signal(1, output="x" * 400)["evidence"]["output"]) == 400
    assert len(sb.signal(1, output="x" * 401)["evidence"]["output"]) == 400
    assert sb.signal(1, output="a" * 399 + "b" + "c")["evidence"]["output"].endswith("b")


def test_unmeasured_names_its_reason_and_keeps_the_evidence():
    got = sb.unmeasured("tool missing", command="apidiff -m", code=None)
    assert got == {"value": "unmeasured", "reason": "tool missing",
                   "evidence": {"command": "apidiff -m", "exit": None, "output": ""}}


def test_of_run_takes_its_evidence_from_the_run():
    got = sb.of_run(False, run_of(code=1, out="o\n", err="e\n"))
    assert got == {"value": False, "evidence": {"command": "tool --x", "exit": 1, "output": "o\ne\n"}}


def test_of_run_can_override_the_output_and_add_a_reason():
    got = sb.of_run(sb.UNMEASURED, run_of(code=2, out="raw"), reason="boom", output="summary")
    assert got["evidence"]["output"] == "summary"
    assert got["reason"] == "boom"


def test_run_tool_captures_both_streams_and_the_exit_code(tmp_path):
    script = "import sys; print('out'); print('err', file=sys.stderr); sys.exit(3)"
    argv = [sys.executable, "-c", script]
    got = sb.run_tool(argv, cwd=str(tmp_path))
    assert (got.code, got.out, got.err, got.problem) == (3, "out\n", "err\n", "")
    assert got.command == shlex.join(argv)


def test_run_tool_runs_in_the_given_directory(tmp_path):
    got = sb.run_tool([sys.executable, "-c", "import os; print(os.getcwd())"], cwd=str(tmp_path))
    assert got.out.strip() == str(tmp_path.resolve())


def test_run_tool_reports_a_missing_tool_as_a_problem(tmp_path):
    got = sb.run_tool(["no-such-tool-for-signals", "-x"], cwd=str(tmp_path))
    assert got.code is None
    assert got.problem.startswith("could not run no-such-tool-for-signals")
    assert got.command == "no-such-tool-for-signals -x"


def test_run_tool_gives_up_on_a_tool_that_runs_too_long(tmp_path):
    got = sb.run_tool([sys.executable, "-c", "import time; time.sleep(30)"], cwd=str(tmp_path), timeout=0.2)
    assert got.code is None
    assert got.problem == f"{sys.executable} timed out after 0.2 s"


def test_run_tool_keeps_output_that_is_not_utf8(tmp_path):
    script = "import sys; sys.stdout.buffer.write(b'a\\xffb')"
    assert sb.run_tool([sys.executable, "-c", script], cwd=str(tmp_path)).out == "a�b"


def test_the_tool_timeout_is_90_seconds():
    assert sb.TOOL_TIMEOUT == 90


def test_why_prefers_the_problem():
    assert sb.why(run_of(code=None, problem="could not run x")) == "could not run x"


def test_why_names_the_exit_and_the_first_line_the_tool_said():
    assert sb.why(run_of(code=2, err="\n\nfatal: nope\nmore\n")) == "exit 2: fatal: nope"
    assert sb.why(run_of(code=2, out="only stdout\n")) == "exit 2: only stdout"


def test_why_with_nothing_said_is_just_the_exit():
    assert sb.why(run_of(code=4)) == "exit 4"


@pytest.mark.parametrize("path,lang", [
    ("a.go", "go"), ("pkg/x.py", "python"), ("src/A.php", "php"),
    ("a.ts", None), ("README.md", None), ("Makefile", None), ("a.go.orig", None),
])
def test_lang_of_goes_by_extension(path, lang):
    assert sb.lang_of(path) == lang


@pytest.mark.parametrize("path", [
    "a_test.go", "pkg/b_test.go", "test_a.py", "pkg/test_a.py", "pkg/a_test.py",
    "conftest.py", "pkg/conftest.py", "tests/a.py", "x/tests/y/a.py", "src/Tests/A.php",
    "src/FooTest.php",
])
def test_is_test_file_recognises_each_languages_conventions(path):
    assert sb.is_test_file(path) is True


@pytest.mark.parametrize("path", [
    "a.go", "pkg/attest.py", "latest.py", "src/Foo.php", "src/testing/a.py", "mytests/a.py",
    "tests.py", "pkg/contest.py",
])
def test_is_test_file_leaves_ordinary_source_alone(path):
    assert sb.is_test_file(path) is False


DIFF = """\
diff --git a/a.py b/a.py
index 1..2 100644
--- a/a.py
+++ b/a.py
@@ -3 +3,2 @@ def f():
-old
+new
+new2
@@ -10,2 +11 @@
-x
-y
+z
@@ -20,2 +20,0 @@
-gone
-gone2
diff --git a/new.py b/new.py
new file mode 100644
--- /dev/null
+++ b/new.py
@@ -0,0 +1,3 @@
+a
+b
+c
diff --git a/old.py b/old.py
deleted file mode 100644
--- a/old.py
+++ /dev/null
@@ -1,2 +0,0 @@
-a
-b
diff --git a/with space.py b/with space.py
--- a/with space.py
+++ b/with space.py\t
@@ -1 +1 @@
-a
+b
diff --git a/bin.dat b/bin.dat
Binary files a/bin.dat and b/bin.dat differ
"""


def test_added_lines_reads_the_new_side_of_every_hunk():
    got = sb.added_lines(DIFF)
    assert got["a.py"] == {3, 4, 11}
    assert got["new.py"] == {1, 2, 3}
    assert got["with space.py"] == {1}


def test_added_lines_skips_deleted_files_pure_deletions_and_binaries():
    got = sb.added_lines(DIFF)
    assert "old.py" not in got
    assert "bin.dat" not in got
    assert 20 not in got["a.py"]


def test_added_lines_does_not_mistake_an_added_line_for_a_file_header():
    diff = ("diff --git a/a.py b/a.py\n--- a/a.py\n+++ b/a.py\n@@ -1 +1,2 @@\n"
            "+first\n+++ b/evil.py\n")
    assert sb.added_lines(diff) == {"a.py": {1, 2}}


def test_added_lines_of_an_empty_diff_is_empty():
    assert sb.added_lines("") == {}


def test_settings_read_one_pathspec_per_line_and_skip_blank_ones():
    env = {"TOUCHSTONE_UNSUPPORTED_SPEC": "*.ts\n*.rs\n\n",
           "TOUCHSTONE_EXEMPT_SPEC": ":(glob,exclude,top)web/**\n",
           "TOUCHSTONE_DEADCODE_VERSION": "v0.49.0"}
    assert sb.settings_from(env) == sb.Settings(
        unsupported=("*.ts", "*.rs"), exempt=(":(glob,exclude,top)web/**",), deadcode_version="v0.49.0")


def test_settings_allow_empty_lists():
    got = sb.settings_from({"TOUCHSTONE_DEADCODE_VERSION": "v1"})
    assert got.unsupported == () and got.exempt == ()


def test_settings_refuse_a_missing_deadcode_version():
    with pytest.raises(sb.SignalError, match="TOUCHSTONE_DEADCODE_VERSION"):
        sb.settings_from({})


def no_settings(**fields):
    return sb.Settings(**{"unsupported": (), "exempt": (), "deadcode_version": "v1", **fields})


@pytest.fixture
def changed(repo):
    repo.write("keep.py", "a\nb\nc\n")
    repo.write("gone.go", "package x\n")
    repo.write("bin.dat", b"\x00\x01")
    repo.write("web/app.ts", "let a = 1\n")
    base = repo.commit("base")
    repo.write("keep.py", "a\nb\nc\nd\n")
    repo.write("new dir/new.php", "<?php\n")
    repo.write("bin.dat", b"\x00\x02")
    repo.write("web/app.ts", "let a = 2\n")
    (repo.root / "gone.go").unlink()
    head = repo.commit("head")
    return repo, base, head


def test_load_ctx_resolves_the_range_to_commits(changed):
    repo, base, head = changed
    ctx = sb.load_ctx(str(repo.root), f"{base}..{head}", no_settings())
    assert (ctx.repo, ctx.rng, ctx.base, ctx.head) == (str(repo.root), f"{base}..{head}", base, head)
    assert ctx.at_head is True


def test_load_ctx_accepts_refs_and_echoes_the_range_as_given(changed):
    repo, base, head = changed
    ctx = sb.load_ctx(str(repo.root), "HEAD~1..HEAD", no_settings())
    assert (ctx.base, ctx.head, ctx.rng) == (base, head, "HEAD~1..HEAD")


def test_load_ctx_knows_when_head_is_not_the_range_head(changed):
    repo, base, head = changed
    repo.write("later.py", "x\n")
    repo.commit("later")
    assert sb.load_ctx(str(repo.root), f"{base}..{head}", no_settings()).at_head is False


def test_load_ctx_reads_numstat_rows_with_binaries_as_none(changed):
    repo, base, head = changed
    rows = sb.load_ctx(str(repo.root), f"{base}..{head}", no_settings()).rows
    assert sorted(rows, key=lambda r: r[2]) == [
        (None, None, "bin.dat"), (0, 1, "gone.go"), (1, 0, "keep.py"),
        (1, 0, "new dir/new.php"), (1, 1, "web/app.ts")]


def test_load_ctx_reads_the_status_of_each_path(changed):
    repo, base, head = changed
    status = sb.load_ctx(str(repo.root), f"{base}..{head}", no_settings()).status
    assert status == {"bin.dat": "M", "gone.go": "D", "keep.py": "M",
                      "new dir/new.php": "A", "web/app.ts": "M"}


def test_load_ctx_lists_added_lines(changed):
    repo, base, head = changed
    ctx = sb.load_ctx(str(repo.root), f"{base}..{head}", no_settings())
    assert ctx.added["keep.py"] == {4}
    assert ctx.added["new dir/new.php"] == {1}


@pytest.mark.parametrize("how", ["config", "environment"])
def test_load_ctx_lists_added_lines_whatever_external_diff_tool_the_user_set(repo, tmp_path, monkeypatch, how):
    tool = tmp_path / "fake-difft"
    tool.write_text('#!/bin/sh\necho "$1 --- 1/1 --- Python"\n')
    tool.chmod(0o755)
    repo.write("a.py", "a\n")
    base = repo.commit("base")
    repo.write("a.py", "a\nb\n")
    head = repo.commit("head")
    if how == "config":
        repo.git("config", "diff.external", str(tool))
    else:
        monkeypatch.setenv("GIT_EXTERNAL_DIFF", str(tool))
    ctx = sb.load_ctx(str(repo.root), f"{base}..{head}", no_settings())
    assert ctx.added == {"a.py": {2}}


def test_load_ctx_without_exemptions_gates_every_changed_path(changed):
    repo, base, head = changed
    ctx = sb.load_ctx(str(repo.root), f"{base}..{head}", no_settings())
    assert sorted(ctx.gated) == ["bin.dat", "gone.go", "keep.py", "new dir/new.php", "web/app.ts"]
    assert ctx.unsupported == ()


def test_load_ctx_drops_exempt_paths_from_the_gated_ones(changed):
    repo, base, head = changed
    settings = no_settings(exempt=(":(glob,exclude,top)web/**",))
    ctx = sb.load_ctx(str(repo.root), f"{base}..{head}", settings)
    assert "web/app.ts" not in ctx.gated
    assert "keep.py" in ctx.gated


def test_load_ctx_names_changed_files_in_an_unsupported_language(changed):
    repo, base, head = changed
    ctx = sb.load_ctx(str(repo.root), f"{base}..{head}", no_settings(unsupported=("*.ts", "*.rs")))
    assert ctx.unsupported == ("web/app.ts",)


def test_load_ctx_does_not_count_an_exempt_path_as_unsupported(changed):
    repo, base, head = changed
    settings = no_settings(unsupported=("*.ts",), exempt=(":(glob,exclude,top)web/**",))
    assert sb.load_ctx(str(repo.root), f"{base}..{head}", settings).unsupported == ()


@pytest.mark.parametrize("rng", ["", "abc", "..abc", "abc..", "a...b", "a..b..c"])
def test_load_ctx_refuses_a_range_that_is_not_base_dot_dot_head(changed, rng):
    repo, *_ = changed
    with pytest.raises(sb.SignalError, match="range"):
        sb.load_ctx(str(repo.root), rng, no_settings())


def test_load_ctx_refuses_a_ref_it_cannot_resolve(changed):
    repo, base, head = changed
    with pytest.raises(sb.SignalError, match="cannot resolve nope"):
        sb.load_ctx(str(repo.root), f"{base}..nope", no_settings())
    with pytest.raises(sb.SignalError, match="cannot resolve gone"):
        sb.load_ctx(str(repo.root), f"gone..{head}", no_settings())


def test_load_ctx_refuses_a_directory_that_is_not_a_repository(tmp_path):
    with pytest.raises(sb.SignalError):
        sb.load_ctx(str(tmp_path), "a..b", no_settings())


def test_git_reports_a_failing_command_with_what_git_said(tmp_path):
    with pytest.raises(sb.SignalError, match="git status failed: .*not a git repository"):
        sb.git(str(tmp_path), "status")
