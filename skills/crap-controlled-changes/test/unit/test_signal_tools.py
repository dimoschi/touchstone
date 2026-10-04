import json
import os

import pytest

import signal_base as sb
import signal_tools as st

UNMEASURED = "unmeasured"


def settings(**fields):
    return sb.Settings(**{"unsupported": (), "exempt": (), "deadcode_version": "v1", **fields})


def fake(**fields):
    ctx = sb.Ctx(repo="/r", rng="b..h", base="b", head="h", at_head=True, rows=[], status={},
                 gated=(), unsupported=(), added={}, settings=settings())
    return ctx._replace(**fields)


def change(repo, base_files, head_files, delete=(), **config):
    for rel, text in base_files.items():
        repo.write(rel, text)
    base = repo.commit("base")
    for rel, text in head_files.items():
        repo.write(rel, text)
    for rel in delete:
        (repo.root / rel).unlink()
    head = repo.commit("head")
    return sb.load_ctx(str(repo.root), f"{base}..{head}", settings(**config))


def part(value, **fields):
    return sb.signal(value, **fields)


def test_combine_lets_a_proof_stand_over_what_could_not_be_checked():
    parts = [part(False), sb.unmeasured("no tool"), part(True, output="found")]
    assert st.combine(parts)["evidence"]["output"] == "found"


def test_combine_reports_unmeasured_rather_than_false_when_any_part_is():
    got = st.combine([part(False), sb.unmeasured("no tool")])
    assert got["value"] == UNMEASURED and got["reason"] == "no tool"


def test_combine_gives_every_reason_a_part_could_not_tell_once():
    got = st.combine([sb.unmeasured("no apidiff", command="apidiff"), part(False),
                      sb.unmeasured("no griffe"), sb.unmeasured("no apidiff")])
    assert got["reason"] == "no apidiff; no griffe"
    assert got["evidence"]["command"] == "apidiff"


def test_combine_can_take_false_as_the_proof():
    parts = [part(True, output="same"), sb.unmeasured("no tool"), part(False, output="differs")]
    assert st.combine(parts, proof=False)["evidence"]["output"] == "differs"
    assert st.combine(parts[:2], proof=False)["reason"] == "no tool"
    assert st.combine(parts[:1], proof=False)["evidence"]["output"] == "same"


def test_combine_of_clean_parts_is_the_first_clean_one():
    assert st.combine([part(False, output="a"), part(False, output="b")])["evidence"]["output"] == "a"


def test_semantic_refuses_to_run_tools_when_head_is_not_the_range_head():
    called = []
    got = st.semantic(fake(at_head=False, gated=("a.py",)), {"python": lambda c, f: called.append(f)})
    assert got["value"] == UNMEASURED
    assert "HEAD" in got["reason"]
    assert called == []


def test_semantic_hands_each_language_only_its_own_gated_files():
    seen = {}
    ctx = fake(gated=("a.go", "b.py", "c.py", "d.php", "e.md"))
    st.semantic(ctx, {"go": lambda c, f: seen.setdefault("go", f) and [part(False)],
                      "python": lambda c, f: seen.setdefault("python", f) and [part(False)],
                      "php": lambda c, f: seen.setdefault("php", f) and [part(False)]})
    assert seen == {"go": ["a.go"], "python": ["b.py", "c.py"], "php": ["d.php"]}


def test_semantic_skips_a_language_that_did_not_change():
    got = st.semantic(fake(gated=("a.py",)), {"go": lambda c, f: pytest.fail("no Go changed"),
                                              "python": lambda c, f: [part(False)]})
    assert got["value"] is False


def test_semantic_with_no_go_php_or_python_file_is_unmeasured():
    got = st.semantic(fake(gated=("README.md",)), {"python": lambda c, f: [part(False)]})
    assert got["value"] == UNMEASURED
    assert got["reason"] == "no Go, PHP or Python file changed"


def test_semantic_cannot_say_false_with_a_file_in_an_unsupported_language():
    ctx = fake(gated=("a.py", "web/app.ts"), unsupported=("web/app.ts",))
    got = st.semantic(ctx, {"python": lambda c, f: [part(False)]})
    assert got["value"] == UNMEASURED
    assert "web/app.ts" in got["reason"]


def test_semantic_still_reports_a_proof_beside_an_unsupported_file():
    ctx = fake(gated=("a.py", "web/app.ts"), unsupported=("web/app.ts",))
    assert st.semantic(ctx, {"python": lambda c, f: [part(True)]})["value"] is True


def test_semantic_with_only_an_unsupported_file_is_unmeasured_for_that_reason():
    got = st.semantic(fake(gated=("web/app.ts",), unsupported=("web/app.ts",)), {})
    assert got["value"] == UNMEASURED and "web/app.ts" in got["reason"]


APIDIFF = """
args = sys.argv[1:]
if '-w' in args:
    sys.exit({write_code})
sys.stdout.write({out!r})
sys.stderr.write({err!r})
sys.exit({code})
"""


def apidiff(stubs, out="", err="", code=0, write_code=0):
    stubs.add("apidiff", APIDIFF.format(out=out, err=err, code=code, write_code=write_code))


GO_MOD = "module example.com/m\n\ngo 1.22\n"


def go_change(repo, **config):
    return change(repo, {"go.mod": GO_MOD, "a.go": "package m\n\nfunc A() {}\n"},
                  {"a.go": "package m\n"}, **config)


def test_api_broken_in_go_reads_the_incompatible_changes_apidiff_prints(repo, stubs):
    apidiff(stubs, out="- A: removed\n")
    got = st.api_broken(go_change(repo))
    assert got["value"] is True
    assert got["evidence"]["output"] == "- A: removed"
    assert "-incompatible" in got["evidence"]["command"]
    assert got["evidence"]["exit"] == 0


def test_api_broken_in_go_is_false_when_apidiff_prints_nothing(repo, stubs):
    apidiff(stubs)
    assert st.api_broken(go_change(repo))["value"] is False


def test_api_broken_in_go_ignores_what_apidiff_says_on_stderr(repo, stubs):
    apidiff(stubs, err="Ignoring internal package example.com/m/internal/x\n")
    assert st.api_broken(go_change(repo))["value"] is False


def test_api_broken_in_go_exports_the_base_api_then_compares_it_with_head(repo, stubs):
    apidiff(stubs)
    ctx = go_change(repo)
    st.api_broken(ctx)
    write, compare = stubs.calls("apidiff")
    assert write["args"][:2] == ["-m", "-w"] and write["args"][3] == "example.com/m"
    assert write["cwd"].endswith("/base") or write["cwd"].endswith("/base/.")
    export = write["args"][2]
    assert compare["args"] == ["-m", "-incompatible", export, "example.com/m"]
    assert os.path.realpath(compare["cwd"]) == os.path.realpath(str(repo.root))


def test_api_broken_in_go_runs_apidiff_from_the_module_directory(repo, stubs):
    apidiff(stubs)
    ctx = change(repo, {"svc/go.mod": "module example.com/svc\n", "svc/a.go": "package svc\n"},
                 {"svc/a.go": "package svc\n\nfunc B() {}\n"})
    st.api_broken(ctx)
    write, compare = stubs.calls("apidiff")
    assert write["cwd"].endswith("/base/svc")
    assert write["args"][3] == compare["args"][3] == "example.com/svc"
    assert os.path.realpath(compare["cwd"]) == os.path.realpath(str(repo.root / "svc"))


def test_api_broken_in_go_checks_every_module_that_changed(repo, stubs):
    apidiff(stubs, out="- X: removed\n")
    ctx = change(repo,
                 {"one/go.mod": "module example.com/one\n", "one/a.go": "package one\n",
                  "two/go.mod": "module example.com/two\n", "two/a.go": "package two\n"},
                 {"one/a.go": "package one\n\nfunc B() {}\n", "two/a.go": "package two\n\nfunc B() {}\n"})
    assert st.api_broken(ctx)["value"] is True
    assert len(stubs.calls("apidiff")) == 4


def test_api_broken_in_go_is_unmeasured_when_apidiff_is_missing(repo, stubs):
    got = st.api_broken(go_change(repo))
    assert got["value"] == UNMEASURED
    assert "could not run apidiff" in got["reason"]


def test_api_broken_in_go_is_unmeasured_when_the_base_api_cannot_be_read(repo, stubs):
    apidiff(stubs, write_code=1)
    got = st.api_broken(go_change(repo))
    assert got["value"] == UNMEASURED
    assert got["reason"].startswith("apidiff could not read the base API")


def test_api_broken_in_go_is_unmeasured_when_the_comparison_fails(repo, stubs):
    apidiff(stubs, err="loading example.com/m: no packages\n", code=1)
    got = st.api_broken(go_change(repo))
    assert got["value"] == UNMEASURED
    assert got["reason"] == "exit 1: loading example.com/m: no packages"
    assert got["evidence"]["exit"] == 1


def test_api_broken_in_go_gives_up_on_a_slow_apidiff(repo, stubs, monkeypatch):
    stubs.add("apidiff", "import time; time.sleep(30)")
    monkeypatch.setattr(st, "run_tool", lambda argv, cwd: sb.run_tool(argv, cwd, timeout=0.2))
    got = st.api_broken(go_change(repo))
    assert got["value"] == UNMEASURED and "timed out" in got["reason"]


def test_api_broken_in_go_has_nothing_to_break_in_a_module_new_in_the_range(repo, stubs):
    ctx = change(repo, {"README.md": "x\n"}, {"go.mod": GO_MOD, "a.go": "package m\n"})
    got = st.api_broken(ctx)
    assert got["value"] is False
    assert "new module" in got["evidence"]["output"]
    assert stubs.calls("apidiff") == []


def test_api_broken_in_go_cannot_measure_a_file_no_module_owns(repo, stubs):
    apidiff(stubs)
    ctx = change(repo, {"a.go": "package m\n"}, {"a.go": "package m\n\nfunc B() {}\n"})
    got = st.api_broken(ctx)
    assert got["value"] == UNMEASURED
    assert "go.mod" in got["reason"]


GRIFFE_RECORD = "src/pkg/mod.py:3: f(b): Parameter was removed\n"


def griffe(stubs, out="", err="", code=0):
    stubs.add("griffe", out=out, err=err, code=code)


def py_change(repo, **config):
    return change(repo, {"src/pkg/__init__.py": "", "src/pkg/mod.py": "def f(a, b):\n    pass\n"},
                  {"src/pkg/mod.py": "def f(a):\n    pass\n"}, **config)


def test_api_broken_in_python_reads_the_breakages_griffe_prints(repo, stubs):
    griffe(stubs, err=GRIFFE_RECORD, code=1)
    got = st.api_broken(py_change(repo))
    assert got["value"] is True
    assert got["evidence"]["output"] == GRIFFE_RECORD.strip()
    assert got["evidence"]["exit"] == 1


def test_api_broken_in_python_is_false_when_griffe_finds_nothing(repo, stubs):
    griffe(stubs)
    assert st.api_broken(py_change(repo))["value"] is False


def test_api_broken_in_python_asks_griffe_about_the_top_level_package(repo, stubs):
    griffe(stubs)
    ctx = change(repo, {"src/pkg/__init__.py": "", "src/pkg/sub/__init__.py": "", "src/pkg/sub/m.py": "x = 1\n"},
                 {"src/pkg/sub/m.py": "x = 2\n"})
    st.api_broken(ctx)
    [call] = stubs.calls("griffe")
    assert call["args"] == ["check", "pkg", "-s", "src", "-a", ctx.base, "--no-color"]
    assert os.path.realpath(call["cwd"]) == os.path.realpath(str(repo.root))


def test_api_broken_in_python_searches_the_repo_root_for_a_package_there(repo, stubs):
    griffe(stubs)
    ctx = change(repo, {"pkg/__init__.py": "", "pkg/m.py": "x = 1\n"}, {"pkg/m.py": "x = 2\n"})
    st.api_broken(ctx)
    assert stubs.calls("griffe")[0]["args"][:4] == ["check", "pkg", "-s", "."]


def test_api_broken_in_python_asks_once_per_package(repo, stubs):
    griffe(stubs)
    ctx = change(repo,
                 {"a/__init__.py": "", "a/m.py": "x = 1\n", "a/n.py": "x = 1\n", "b/__init__.py": "", "b/m.py": "x = 1\n"},
                 {"a/m.py": "x = 2\n", "a/n.py": "x = 2\n", "b/m.py": "x = 2\n"})
    st.api_broken(ctx)
    assert [c["args"][1] for c in stubs.calls("griffe")] == ["a", "b"]


def test_api_broken_in_python_is_unmeasured_when_griffe_fails_without_a_breakage(repo, stubs):
    griffe(stubs, err='Traceback (most recent call last):\n  File "x.py", line 3, in <module>\nImportError: boom\n',
           code=1)
    got = st.api_broken(py_change(repo))
    assert got["value"] == UNMEASURED
    assert got["reason"] == "exit 1: Traceback (most recent call last):"


def test_api_broken_in_python_does_not_take_a_docstring_warning_for_a_breakage(repo, stubs):
    griffe(stubs, err="griffe: src/pkg/mod.py:2: No type or annotation for parameter 'x'\n", code=1)
    assert st.api_broken(py_change(repo))["value"] == UNMEASURED


def test_api_broken_in_python_is_unmeasured_when_griffe_is_missing(repo, stubs):
    got = st.api_broken(py_change(repo))
    assert got["value"] == UNMEASURED and "could not run griffe" in got["reason"]


def test_api_broken_in_python_has_nothing_to_break_in_a_package_new_in_the_range(repo, stubs):
    ctx = change(repo, {"README.md": "x\n"}, {"newpkg/__init__.py": "", "newpkg/m.py": "x = 1\n"})
    got = st.api_broken(ctx)
    assert got["value"] is False
    assert "new package" in got["evidence"]["output"]
    assert stubs.calls("griffe") == []


def test_api_broken_in_python_cannot_measure_a_file_outside_any_package(repo, stubs):
    griffe(stubs)
    ctx = change(repo, {"scripts/tool.py": "x = 1\n"}, {"scripts/tool.py": "x = 2\n"})
    got = st.api_broken(ctx)
    assert got["value"] == UNMEASURED
    assert "scripts/tool.py" in got["reason"]


def test_api_broken_in_python_still_proves_a_break_beside_a_loose_file(repo, stubs):
    griffe(stubs, err=GRIFFE_RECORD, code=1)
    ctx = change(repo, {"src/pkg/__init__.py": "", "src/pkg/mod.py": "x = 1\n", "tool.py": "x = 1\n"},
                 {"src/pkg/mod.py": "x = 2\n", "tool.py": "x = 2\n"})
    assert st.api_broken(ctx)["value"] is True


def test_api_broken_in_python_ignores_test_files(repo, stubs):
    ctx = change(repo, {"tests/test_a.py": "x = 1\n", "pkg/__init__.py": ""}, {"tests/test_a.py": "x = 2\n"})
    got = st.api_broken(ctx)
    assert got["value"] is False
    assert "only test files" in got["evidence"]["output"]
    assert stubs.calls("griffe") == []


def php_change(repo, **config):
    return change(repo, {"composer.json": "{}\n", "src/A.php": "<?php\nclass A {}\n"},
                  {"src/A.php": "<?php\nclass B {}\n"}, **config)


def test_api_broken_in_php_reads_the_bc_lines_the_tool_prints(repo, stubs):
    stubs.add("roave-backward-compatibility-check",
              out="", err="[BC] REMOVED: Class A was removed\n1 backwards-incompatible changes detected\n", code=3)
    got = st.api_broken(php_change(repo))
    assert got["value"] is True
    assert got["evidence"]["output"] == "[BC] REMOVED: Class A was removed"
    assert got["evidence"]["exit"] == 3


def test_api_broken_in_php_compares_against_the_base_commit(repo, stubs):
    stubs.add("roave-backward-compatibility-check")
    ctx = php_change(repo)
    st.api_broken(ctx)
    [call] = stubs.calls("roave-backward-compatibility-check")
    assert call["args"] == [f"--from={ctx.base}"]
    assert os.path.realpath(call["cwd"]) == os.path.realpath(str(repo.root))


def test_api_broken_in_php_is_false_when_the_tool_finds_nothing(repo, stubs):
    stubs.add("roave-backward-compatibility-check", err="No backwards-incompatible changes detected\n")
    assert st.api_broken(php_change(repo))["value"] is False


def test_api_broken_in_php_is_unmeasured_when_the_tool_fails_without_a_bc_line(repo, stubs):
    stubs.add("roave-backward-compatibility-check", err="composer install failed\n", code=1)
    got = st.api_broken(php_change(repo))
    assert got["value"] == UNMEASURED
    assert got["reason"] == "exit 1: composer install failed"


def test_api_broken_in_php_is_unmeasured_when_the_tool_is_missing(repo, stubs):
    got = st.api_broken(php_change(repo))
    assert got["value"] == UNMEASURED
    assert "could not run roave-backward-compatibility-check" in got["reason"]


def test_api_broken_in_php_finds_the_tool_under_vendor_bin(repo, stubs):
    stubs.add("roave-backward-compatibility-check", err="[BC] CHANGED: x\n", code=3,
              into=repo.root / "vendor" / "bin")
    got = st.api_broken(php_change(repo))
    assert got["value"] is True
    assert got["evidence"]["command"].startswith(str(repo.root / "vendor" / "bin"))


def test_api_broken_in_php_ignores_test_files(repo, stubs):
    ctx = change(repo, {"tests/FooTest.php": "<?php\n"}, {"tests/FooTest.php": "<?php\n// x\n"})
    got = st.api_broken(ctx)
    assert got["value"] is False and "only test files" in got["evidence"]["output"]


def gosec_json(repo, line, rule="G204", errors=None):
    return json.dumps({
        "Golang errors": errors or {},
        "Issues": [{"severity": "HIGH", "rule_id": rule, "details": "x",
                    "file": str(repo.root.resolve() / "a.go"), "line": line}],
        "Stats": {}})


def go_security_change(repo):
    return change(repo, {"go.mod": GO_MOD, "a.go": "package m\n\nfunc A() {}\n\nfunc B() {}\n"},
                  {"a.go": "package m\n\nfunc A() {}\n\nfunc B() {}\n\nfunc C() {}\n"})


def test_security_pattern_in_go_flags_a_finding_on_an_added_line(repo, stubs):
    stubs.add("gosec", out=gosec_json(repo, "6"))
    got = st.security_pattern(go_security_change(repo))
    assert got["value"] is True
    assert got["evidence"]["output"] == "a.go:6 G204"


def test_security_pattern_in_go_ignores_a_finding_on_a_line_the_range_did_not_add(repo, stubs):
    stubs.add("gosec", out=gosec_json(repo, "3"))
    got = st.security_pattern(go_security_change(repo))
    assert got["value"] is False
    assert got["evidence"]["output"] == "1 finding(s) in scanned files, none on added lines"


def test_security_pattern_in_go_reads_a_line_span(repo, stubs):
    stubs.add("gosec", out=gosec_json(repo, "5-6"))
    assert st.security_pattern(go_security_change(repo))["value"] is True


def test_security_pattern_in_go_runs_gosec_over_each_changed_module(repo, stubs):
    stubs.add("gosec", out=json.dumps({"Golang errors": {}, "Issues": []}))
    st.security_pattern(go_security_change(repo))
    [call] = stubs.calls("gosec")
    assert call["args"] == ["-fmt=json", "-no-fail", "./..."]
    assert os.path.realpath(call["cwd"]) == os.path.realpath(str(repo.root))


def test_security_pattern_in_go_is_unmeasured_when_gosec_could_not_load_a_package(repo, stubs):
    stubs.add("gosec", out=json.dumps({"Golang errors": {"a.go": [{"line": 1, "error": "undefined: x"}]},
                                      "Issues": []}))
    got = st.security_pattern(go_security_change(repo))
    assert got["value"] == UNMEASURED
    assert "undefined: x" in got["reason"]


def test_security_pattern_in_go_still_reports_a_finding_beside_a_load_error(repo, stubs):
    stubs.add("gosec", out=gosec_json(repo, "6", errors={"b.go": [{"error": "x"}]}))
    assert st.security_pattern(go_security_change(repo))["value"] is True


def test_security_pattern_in_go_is_unmeasured_when_gosec_prints_no_json(repo, stubs):
    stubs.add("gosec", err="gosec: fatal\n", code=1)
    got = st.security_pattern(go_security_change(repo))
    assert got["value"] == UNMEASURED
    assert got["reason"] == "exit 1: gosec: fatal"


def test_security_pattern_in_go_is_unmeasured_when_gosec_is_missing(repo, stubs):
    got = st.security_pattern(go_security_change(repo))
    assert got["value"] == UNMEASURED and "could not run gosec" in got["reason"]


def bandit_json(results=(), errors=()):
    return json.dumps({"errors": list(errors), "results": list(results), "metrics": {}})


def bandit_result(filename="./a.py", lines=(3,), test_id="B602"):
    return {"filename": filename, "line_number": lines[0], "line_range": list(lines), "test_id": test_id}


PY_BASE = {"a.py": "x = 1\ny = 2\nz = 3\n", "tests/test_a.py": "x = 1\n", "gone.py": "x = 1\n"}
PY_HEAD = {"a.py": "x = 1\ny = 2\nz = 3\nsubprocess.call(x, shell=True)\n", "tests/test_a.py": "x = 2\n"}


def py_security_change(repo):
    return change(repo, PY_BASE, {**PY_HEAD, "b.py": "x = 1\n"}, delete=("gone.py",))


def test_security_pattern_in_python_flags_a_finding_on_an_added_line(repo, stubs):
    stubs.add("bandit", out=bandit_json([bandit_result(lines=(4,))]), code=1)
    got = st.security_pattern(py_security_change(repo))
    assert got["value"] is True
    assert got["evidence"]["output"] == "a.py:4 B602"


def test_security_pattern_in_python_ignores_a_finding_on_an_older_line(repo, stubs):
    stubs.add("bandit", out=bandit_json([bandit_result(lines=(2,))]), code=1)
    assert st.security_pattern(py_security_change(repo))["value"] is False


def test_security_pattern_in_python_reads_every_line_of_a_multi_line_finding(repo, stubs):
    stubs.add("bandit", out=bandit_json([bandit_result(lines=(2, 3, 4))]), code=1)
    assert st.security_pattern(py_security_change(repo))["value"] is True


def test_security_pattern_in_python_scans_changed_source_that_still_exists(repo, stubs):
    stubs.add("bandit", out=bandit_json())
    st.security_pattern(py_security_change(repo))
    [call] = stubs.calls("bandit")
    assert call["args"] == ["-f", "json", "a.py", "b.py"]
    assert os.path.realpath(call["cwd"]) == os.path.realpath(str(repo.root))


def test_security_pattern_in_python_is_unmeasured_when_bandit_skipped_a_file(repo, stubs):
    stubs.add("bandit", out=bandit_json(errors=[{"filename": "./a.py", "reason": "syntax error"}]))
    got = st.security_pattern(py_security_change(repo))
    assert got["value"] == UNMEASURED
    assert "syntax error" in got["reason"]


def test_security_pattern_in_python_is_unmeasured_when_bandit_prints_no_json(repo, stubs):
    stubs.add("bandit", err="boom\n", code=2)
    got = st.security_pattern(py_security_change(repo))
    assert got["value"] == UNMEASURED and got["reason"] == "exit 2: boom"


def test_security_pattern_in_python_is_unmeasured_when_bandit_prints_something_else(repo, stubs):
    stubs.add("bandit", out="[1, 2]")
    assert st.security_pattern(py_security_change(repo))["value"] == UNMEASURED


def test_security_pattern_in_python_is_unmeasured_when_bandit_is_missing(repo, stubs):
    got = st.security_pattern(py_security_change(repo))
    assert got["value"] == UNMEASURED and "could not run bandit" in got["reason"]


def test_security_pattern_in_python_has_nothing_to_scan_when_only_tests_changed(repo, stubs):
    ctx = change(repo, {"tests/test_a.py": "x = 1\n"}, {"tests/test_a.py": "x = 2\n"})
    got = st.security_pattern(ctx)
    assert got["value"] is False
    assert stubs.calls("bandit") == []


def opengrep_json(results=(), errors=()):
    return json.dumps({"version": "1", "results": list(results), "errors": list(errors)})


def opengrep_result(path="src/A.php", start=3, end=3, rule="touchstone-php-eval"):
    return {"check_id": rule, "path": path, "start": {"line": start}, "end": {"line": end}}


def php_security_change(repo):
    return change(repo, {"src/A.php": "<?php\nclass A {}\n"},
                  {"src/A.php": "<?php\nclass A {}\neval($x);\n", "src/Old.php": "<?php\n"})


def test_security_pattern_in_php_flags_a_finding_on_an_added_line(repo, stubs):
    stubs.add("opengrep", out=opengrep_json([opengrep_result()]))
    got = st.security_pattern(php_security_change(repo))
    assert got["value"] is True
    assert got["evidence"]["output"] == "src/A.php:3 touchstone-php-eval"


def test_security_pattern_in_php_ignores_a_finding_on_an_older_line(repo, stubs):
    stubs.add("opengrep", out=opengrep_json([opengrep_result(start=2, end=2)]))
    assert st.security_pattern(php_security_change(repo))["value"] is False


def test_security_pattern_in_php_scans_with_the_rules_this_plugin_ships(repo, stubs):
    stubs.add("opengrep", out=opengrep_json())
    st.security_pattern(php_security_change(repo))
    [call] = stubs.calls("opengrep")
    assert call["args"] == ["scan", "-f", st.PHP_RULES, "--json", "src/A.php", "src/Old.php"]
    assert os.path.isfile(st.PHP_RULES)


def test_the_php_rules_name_each_pattern_they_exist_for():
    text = open(st.PHP_RULES).read()
    for rule in ("touchstone-php-eval", "touchstone-php-exec-family", "touchstone-php-unserialize",
                 "touchstone-php-include-variable"):
        assert f"id: {rule}" in text


def test_security_pattern_in_php_is_unmeasured_when_opengrep_reports_errors(repo, stubs):
    stubs.add("opengrep", out=opengrep_json(errors=[{"message": "parse error in src/A.php"}]))
    got = st.security_pattern(php_security_change(repo))
    assert got["value"] == UNMEASURED and "parse error" in got["reason"]


def test_security_pattern_in_php_has_nothing_to_scan_when_only_tests_changed(repo, stubs):
    ctx = change(repo, {"tests/FooTest.php": "<?php\n"}, {"tests/FooTest.php": "<?php\n// x\n"})
    got = st.security_pattern(ctx)
    assert got["value"] is False
    assert stubs.calls("opengrep") == []


def test_security_pattern_in_php_is_unmeasured_when_opengrep_is_missing(repo, stubs):
    got = st.security_pattern(php_security_change(repo))
    assert got["value"] == UNMEASURED and "could not run opengrep" in got["reason"]


def test_security_pattern_across_languages_is_true_if_any_language_is(repo, stubs):
    stubs.add("opengrep", out=opengrep_json([opengrep_result()]))
    ctx = change(repo, {"src/A.php": "<?php\nclass A {}\n", "a.py": "x = 1\n"},
                 {"src/A.php": "<?php\nclass A {}\neval($x);\n", "a.py": "x = 2\n"})
    assert st.security_pattern(ctx)["value"] is True


def test_security_pattern_with_a_missing_tool_for_one_language_is_unmeasured_not_false(repo, stubs):
    stubs.add("opengrep", out=opengrep_json())
    ctx = change(repo, {"src/A.php": "<?php\n", "a.py": "x = 1\n"}, {"src/A.php": "<?php\n// x\n", "a.py": "x = 2\n"})
    got = st.security_pattern(ctx)
    assert got["value"] == UNMEASURED and "could not run bandit" in got["reason"]


DIFFT = """
import sys
old, new = sys.argv[-2:]
if sys.argv[1:3] != ['--check-only', '--exit-code']:
    sys.exit(2)
sys.exit(0 if open(old).read().split() == open(new).read().split() else 1)
"""


def test_semantic_noop_is_true_when_difft_sees_no_syntactic_change(repo, stubs):
    stubs.add("difft", DIFFT)
    ctx = change(repo, {"a.py": "x = 1\n", "b.go": "package m\n"}, {"a.py": "x   =   1\n\n", "b.go": "package   m\n"})
    got = st.semantic_noop(ctx)
    assert got["value"] is True
    assert got["evidence"]["output"] == "a.py: no syntactic change"
    assert got["evidence"]["exit"] == 0


def test_semantic_noop_is_false_when_difft_sees_a_change(repo, stubs):
    stubs.add("difft", DIFFT)
    ctx = change(repo, {"a.py": "x = 1\n", "b.py": "y = 1\n"}, {"a.py": "x   =   1\n", "b.py": "y = 2\n"})
    got = st.semantic_noop(ctx)
    assert got["value"] is False
    assert got["evidence"]["exit"] == 1


def test_semantic_noop_compares_the_base_and_head_blobs_under_the_original_name(repo, stubs):
    stubs.add("difft", "sys.exit(0)")
    st.semantic_noop(change(repo, {"dir/a.py": "old\n"}, {"dir/a.py": "new\n"}))
    [call] = stubs.calls("difft")
    old, new = call["args"][2:]
    assert os.path.basename(old) == os.path.basename(new) == "a.py"
    assert old != new


def test_semantic_noop_hands_difft_the_two_flags_the_check_needs(repo, stubs):
    stubs.add("difft", DIFFT)
    st.semantic_noop(change(repo, {"a.py": "x = 1\n"}, {"a.py": "x = 1 \n"}))
    [call] = stubs.calls("difft")
    assert call["args"][:2] == ["--check-only", "--exit-code"]


@pytest.mark.parametrize("base,head,delete,word", [
    ({}, {"new.py": "x = 1\n"}, (), "status A"),
    ({"old.py": "x = 1\n"}, {}, ("old.py",), "status D"),
])
def test_semantic_noop_is_false_for_a_file_that_was_added_or_deleted(repo, stubs, base, head, delete, word):
    stubs.add("difft", DIFFT)
    ctx = change(repo, {**base, "keep.py": "k = 1\n"}, head, delete=delete)
    got = st.semantic_noop(ctx)
    assert got["value"] is False
    assert word in got["evidence"]["output"]


def test_semantic_noop_is_false_for_a_binary_file_that_changed(repo, stubs):
    stubs.add("difft", DIFFT)
    ctx = change(repo, {"a.bin": b"\x00\x01"}, {"a.bin": b"\x00\x02"})
    got = st.semantic_noop(ctx)
    assert got["value"] is False and "binary" in got["evidence"]["output"]


def test_semantic_noop_is_unmeasured_when_difft_fails(repo, stubs):
    stubs.add("difft", err="bad input\n", code=2)
    got = st.semantic_noop(change(repo, {"a.py": "x = 1\n"}, {"a.py": "x = 2\n"}))
    assert got["value"] == UNMEASURED
    assert got["reason"] == "exit 2: bad input"


def test_semantic_noop_is_unmeasured_when_difft_is_missing(repo, stubs):
    got = st.semantic_noop(change(repo, {"a.py": "x = 1\n"}, {"a.py": "x = 2\n"}))
    assert got["value"] == UNMEASURED and "could not run difft" in got["reason"]


def test_semantic_noop_would_rather_report_a_change_than_a_failure(repo, stubs):
    ctx = change(repo, {"a.py": "x = 1\n"}, {"a.py": "x = 2\n", "new.py": "y = 1\n"})
    assert st.semantic_noop(ctx)["value"] is False


def test_semantic_noop_is_unmeasured_when_one_file_cannot_be_compared_and_the_rest_are_unchanged(repo, stubs):
    stubs.add("difft", "sys.exit(0 if sys.argv[-1].endswith('ok.py') else 2)")
    ctx = change(repo, {"ok.py": "x = 1\n", "bad.py": "x = 1\n"}, {"ok.py": "x = 1 \n", "bad.py": "x = 1 \n"})
    got = st.semantic_noop(ctx)
    assert got["value"] == UNMEASURED


def test_semantic_noop_of_an_empty_range_is_unmeasured(repo, stubs):
    repo.write("a.py", "x = 1\n")
    repo.commit("base")
    repo.commit("empty")
    ctx = sb.load_ctx(str(repo.root), "HEAD~1..HEAD", settings())
    got = st.semantic_noop(ctx)
    assert got["value"] == UNMEASURED and got["reason"] == "no changed file"


def test_semantic_noop_does_not_need_head_to_be_the_range_head(repo, stubs):
    stubs.add("difft", DIFFT)
    ctx = change(repo, {"a.py": "x = 1\n"}, {"a.py": "x  = 1\n"})
    assert st.semantic_noop(ctx._replace(at_head=False))["value"] is True


GO_SRC = """package m

func Live() int {
	return 1
}

func Dead() int {
	return 2
}

func Third() int { return 3 }
"""


def deadcode(stubs, by_dir, code=0, err=""):
    """A `go` that answers `go run ...deadcode...` per directory it is run in."""
    stubs.add("go", f"""
table = {by_dir!r}
here = os.path.basename(os.getcwd())
if here not in table:
    sys.stderr.write('deadcode: no main packages\\n'); sys.exit(1)
if {code}:
    sys.stderr.write({err!r}); sys.exit({code})
sys.stdout.write(table[here])
""")


def dead_json(*funcs, file="a.go"):
    return json.dumps([{"Name": "m", "Path": "example.com/m", "Funcs": [
        {"Name": n, "Position": {"File": file, "Line": line, "Col": 6}, "Generated": False} for n, line in funcs]}])


def go_reach_change(repo, head_src=GO_SRC, **config):
    return change(repo, {"go.mod": GO_MOD, "a.go": "package m\n"}, {"a.go": head_src}, **config)


def test_reachable_is_true_when_a_changed_function_is_not_listed_as_dead(repo, stubs):
    deadcode(stubs, {"repo": dead_json(("Dead", 7), ("Third", 11))})
    got = st.reachable(go_reach_change(repo))
    assert got["value"] is True
    assert got["evidence"]["output"] == "a.go:3 reachable"


def test_reachable_is_false_when_every_changed_function_is_listed_as_dead(repo, stubs):
    deadcode(stubs, {"repo": dead_json(("Live", 3), ("Dead", 7), ("Third", 11))})
    got = st.reachable(go_reach_change(repo))
    assert got["value"] is False
    assert got["evidence"]["output"] == "a.go:3 unreachable\na.go:7 unreachable\na.go:11 unreachable"


def test_reachable_counts_only_functions_that_hold_an_added_line(repo, stubs):
    deadcode(stubs, {"repo": dead_json(("Live", 3))})
    ctx = change(repo, {"go.mod": GO_MOD, "a.go": GO_SRC}, {"a.go": GO_SRC.replace("return 2", "return 22")})
    got = st.reachable(ctx)
    assert got["value"] is True
    assert got["evidence"]["output"] == "a.go:7 reachable"


def test_reachable_reads_a_single_line_function(repo, stubs):
    deadcode(stubs, {"repo": dead_json(("Live", 3), ("Dead", 7))})
    ctx = change(repo, {"go.mod": GO_MOD, "a.go": GO_SRC}, {"a.go": GO_SRC.replace("return 3", "return 33")})
    got = st.reachable(ctx)
    assert got["value"] is True and got["evidence"]["output"] == "a.go:11 reachable"


def test_reachable_reads_a_null_report_as_every_function_reachable(repo, stubs):
    deadcode(stubs, {"repo": "null\n"})
    assert st.reachable(go_reach_change(repo))["value"] is True


def test_reachable_runs_deadcode_from_the_module_root_with_a_filter_for_its_module(repo, stubs):
    deadcode(stubs, {"repo": "null"})
    st.reachable(go_reach_change(repo, deadcode_version="v9.9.9"))
    [call] = stubs.calls("go")
    assert call["args"] == ["run", "golang.org/x/tools/cmd/deadcode@v9.9.9", "-json",
                            "-filter=^example\\.com/m", "./..."]
    assert os.path.realpath(call["cwd"]) == os.path.realpath(str(repo.root))


def test_reachable_judges_a_library_from_the_module_that_replaces_it(repo, stubs):
    deadcode(stubs, {"app": dead_json(("Dead", 7), ("Third", 11), file="../lib/a.go")})
    ctx = change(
        repo,
        {"lib/go.mod": "module example.com/lib\n", "lib/a.go": "package lib\n",
         "app/go.mod": "module example.com/app\n\nreplace example.com/lib => ../lib\n", "app/main.go": "package main\n"},
        {"lib/a.go": GO_SRC.replace("package m", "package lib")})
    got = st.reachable(ctx)
    assert got["value"] is True
    assert got["evidence"]["output"] == "lib/a.go:3 reachable"
    dirs = [os.path.basename(c["cwd"]) for c in stubs.calls("go")]
    assert dirs == ["app", "lib"]


def test_reachable_is_false_only_when_every_root_that_has_a_main_lists_the_function(repo, stubs):
    listed = dead_json(("Live", 3), ("Dead", 7), ("Third", 11), file="../lib/a.go")
    deadcode(stubs, {"app": listed, "lib": dead_json(("Live", 3), ("Dead", 7), ("Third", 11), file="a.go")})
    ctx = change(
        repo,
        {"lib/go.mod": "module example.com/lib\n", "lib/a.go": "package lib\n",
         "app/go.mod": "module example.com/app\n\nreplace example.com/lib => ../lib\n", "app/main.go": "package main\n"},
        {"lib/a.go": GO_SRC.replace("package m", "package lib")})
    assert st.reachable(ctx)["value"] is False


def test_reachable_is_unmeasured_when_no_root_has_a_main_package(repo, stubs):
    deadcode(stubs, {})
    got = st.reachable(go_reach_change(repo))
    assert got["value"] == UNMEASURED
    assert got["reason"] == "no main package reaches module ."


def test_reachable_is_unmeasured_when_deadcode_cannot_build_the_module(repo, stubs):
    deadcode(stubs, {"repo": "[]"}, code=1, err="deadcode: a.go:1: syntax error\n")
    got = st.reachable(go_reach_change(repo))
    assert got["value"] == UNMEASURED
    assert got["reason"] == "exit 1: deadcode: a.go:1: syntax error"


def test_reachable_is_unmeasured_when_go_is_missing(repo, stubs):
    got = st.reachable(go_reach_change(repo))
    assert got["value"] == UNMEASURED and "could not run go" in got["reason"]


def test_reachable_is_unmeasured_without_a_changed_function(repo, stubs):
    ctx = change(repo, {"go.mod": GO_MOD, "a.go": GO_SRC}, {"a.go": GO_SRC + "\n// trailing note\n"})
    got = st.reachable(ctx)
    assert got["value"] == UNMEASURED and "no changed Go function" in got["reason"]
    assert stubs.calls("go") == []


def test_reachable_ignores_test_files_and_deleted_files(repo, stubs):
    ctx = change(repo, {"go.mod": GO_MOD, "a_test.go": "package m\n", "gone.go": GO_SRC},
                 {"a_test.go": GO_SRC}, delete=("gone.go",))
    assert st.reachable(ctx)["value"] == UNMEASURED
    assert stubs.calls("go") == []


def test_reachable_is_unmeasured_when_head_is_not_the_range_head(repo, stubs):
    got = st.reachable(go_reach_change(repo)._replace(at_head=False))
    assert got["value"] == UNMEASURED and "HEAD" in got["reason"]


def test_reachable_answers_for_go_only(repo, stubs):
    ctx = change(repo, {"a.py": "x = 1\n"}, {"a.py": "x = 2\n"})
    got = st.reachable(ctx)
    assert got["value"] == UNMEASURED and "no changed Go function" in got["reason"]


def test_func_spans_runs_from_the_func_line_to_the_closing_brace_at_column_zero():
    text = "package m\n\nfunc A() {\n\tif x {\n\t}\n}\n\nfunc (t T) B() {\n}\n"
    assert st.func_spans(text) == [(3, 6), (8, 9)]


def test_func_spans_treats_a_one_line_function_as_one_line():
    assert st.func_spans("func A() int { return 1 }\n\nfunc B() {}\n") == [(1, 1), (3, 3)]


def test_func_spans_ignores_closing_braces_outside_a_function():
    text = "type T struct {\n\tx int\n}\n\nfunc A() {\n}\n"
    assert st.func_spans(text) == [(5, 6)]


def test_func_spans_ends_a_function_that_never_closes_on_the_last_line():
    assert st.func_spans("func A() {\n\tx := 1\n") == [(1, 2)]


def test_func_spans_of_text_without_functions_is_empty():
    assert st.func_spans("package m\n") == []


def test_the_four_tool_signals_are_registered_under_their_names():
    assert sorted(st.SIGNALS) == ["api_broken", "reachable", "security_pattern", "semantic_noop"]
