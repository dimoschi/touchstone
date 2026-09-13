import inspect
import io
import runpy

import deadcode_testonly


def _run(monkeypatch, lines, capsys):
    monkeypatch.setattr("sys.stdin", io.StringIO("\n".join(lines)))
    rc = deadcode_testonly.main()
    return rc, capsys.readouterr().out


def test_test_only_package_is_reported(monkeypatch, capsys):
    rc, out = _run(monkeypatch, [
        "root|modA|modA modTestHelper|",
    ], capsys)
    assert rc == 0
    assert out == "modTestHelper\n"


def test_package_used_by_prod_is_not_reported(monkeypatch, capsys):
    rc, out = _run(monkeypatch, ["root|modA|modA|"], capsys)
    assert rc == 0
    assert out == ""


def test_malformed_lines_are_skipped(monkeypatch, capsys):
    rc, out = _run(monkeypatch, ["not-enough-pipes", "modA|||"], capsys)
    assert rc == 0
    assert out == ""


def test_output_is_sorted_across_imports_and_xtest_imports(monkeypatch, capsys):
    rc, out = _run(monkeypatch, ["root|modA|modZ|modY"], capsys)
    assert out == "modY\nmodZ\n"


def test_module_guard_calls_main_when_run_as_a_script(monkeypatch):
    # Runs the file's own `if __name__ == '__main__':` line in-process (via
    # runpy, not a subprocess coverage can't see), since this file is small
    # enough that leaving that one line uncovered drops it under the gate's
    # 80% per-function floor.
    monkeypatch.setattr("sys.stdin", io.StringIO(""))
    module_path = inspect.getsourcefile(deadcode_testonly)
    try:
        runpy.run_path(module_path, run_name="__main__")
    except SystemExit as exc:
        assert exc.code == 0
