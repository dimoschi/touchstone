"""crapper_spans.py with crapper replaced by a stand-in.

The stand-in mirrors the parts of crapper's API the script reads, as they are at
the pinned commit: `functions_in_file` returns Function-like records whose
`namespace` is the module (Python) or import path (Go) plus any class or
receiver, `_module_namespace` and `package_namespace` build that prefix, and
`_package_clause` reads the package name off a parsed tree.
"""

import sys
import types
from dataclasses import dataclass

import pytest

import crapper_spans


@dataclass(frozen=True)
class Function:
    name: str
    namespace: str
    complexity: int
    start_line: int
    end_line: int
    path: str
    language: str


@pytest.fixture
def crapper(monkeypatch):
    """Install a stand-in crapper; `.found` maps a path to the functions it holds."""
    state = types.SimpleNamespace(found={}, seen=[], package="calc", go_namespace="example.com/m/calc")

    def functions_in_file(language, source, path, root):
        state.seen.append((language, source, path, root))
        return state.found[path]

    def module_namespace(path, root):
        return path[:-len(".py")].replace("/", ".")

    def package_namespace(path, package):
        state.seen.append(("package_namespace", path, package))
        return state.go_namespace

    def parse(source, language):
        return source.encode(), types.SimpleNamespace(root_node=object())

    def package_clause(data, root):
        return state.package

    def module(name, **attributes):
        made = types.ModuleType(name)
        vars(made).update(attributes)
        monkeypatch.setitem(sys.modules, name, made)
        return made

    package = module("crapper")
    languages = module("crapper.languages", functions_in_file=functions_in_file)
    languages.python = module("crapper.languages.python", _module_namespace=module_namespace)
    languages.golang = module("crapper.languages.golang", package_namespace=package_namespace,
                              _package_clause=package_clause)
    treesitter = module("crapper.languages.treesitter", parse=parse,
                        absolute_path=lambda path, root: f"{root}/{path}")
    package.languages = languages
    languages.treesitter = treesitter
    return state


def run(tmp_path, *files):
    return crapper_spans.main(["--root", str(tmp_path), *files])


def test_a_function_is_one_row_of_file_span_complexity_and_name(tmp_path, crapper, capsys):
    (tmp_path / "pkg").mkdir()
    (tmp_path / "pkg/mod.py").write_text("source")
    crapper.found["pkg/mod.py"] = [Function("f", "pkg.mod", 3, 4, 9, "pkg/mod.py", "python")]
    assert run(tmp_path, "pkg/mod.py") == 0
    assert capsys.readouterr().out == "pkg/mod.py\t4\t9\t3\tf\t\n"
    assert crapper.seen == [("python", "source", "pkg/mod.py", str(tmp_path))]


def test_a_method_is_named_by_its_classes(tmp_path, crapper, capsys):
    (tmp_path / "mod.py").write_text("")
    crapper.found["mod.py"] = [
        Function("m", "mod.Outer.Inner", 1, 2, 3, "mod.py", "python"),
        Function("n", "mod.Outer", 2, 5, 6, "mod.py", "python"),
    ]
    run(tmp_path, "mod.py")
    assert capsys.readouterr().out.splitlines() == [
        "mod.py\t2\t3\t1\tOuter.Inner.m\t",
        "mod.py\t5\t6\t2\tOuter.n\t",
    ]


def test_a_go_function_is_named_by_its_package(tmp_path, crapper, capsys):
    (tmp_path / "calc.go").write_text("package calc")
    crapper.found["calc.go"] = [Function("Branchy", "example.com/m/calc", 4, 10, 20, "calc.go", "go")]
    run(tmp_path, "calc.go")
    assert capsys.readouterr().out == "calc.go\t10\t20\t4\tcalc.Branchy\tcalc\n"


def test_a_go_method_is_named_by_package_and_receiver(tmp_path, crapper, capsys):
    (tmp_path / "calc.go").write_text("package calc")
    crapper.found["calc.go"] = [Function("Run", "example.com/m/calc.Widget", 2, 1, 5, "calc.go", "go")]
    run(tmp_path, "calc.go")
    assert capsys.readouterr().out == "calc.go\t1\t5\t2\tcalc.Widget.Run\tcalc\n"
    assert ("package_namespace", f"{tmp_path}/calc.go", "calc") in crapper.seen


def test_the_go_package_clause_decides_the_package_not_the_directory(tmp_path, crapper, capsys):
    (tmp_path / "x.go").write_text("package other")
    crapper.package = "other"
    crapper.found["x.go"] = [Function("F", "example.com/m/calc", 1, 1, 2, "x.go", "go")]
    run(tmp_path, "x.go")
    assert capsys.readouterr().out == "x.go\t1\t2\t1\tother.F\tother\n"


def test_a_file_that_is_not_utf8_is_still_read(tmp_path, crapper, capsys):
    (tmp_path / "a.py").write_bytes(b"x = '\xff'\n")
    crapper.found["a.py"] = [Function("f", "a", 1, 1, 2, "a.py", "python")]
    assert run(tmp_path, "a.py") == 0
    assert capsys.readouterr().out == "a.py\t1\t2\t1\tf\t\n"
    assert crapper.seen[0][1] == "x = '\ufffd'\n"


def test_every_file_is_read_before_anything_is_printed(tmp_path, crapper, capsys):
    (tmp_path / "a.py").write_text("")
    crapper.found["a.py"] = [Function("f", "a", 1, 1, 2, "a.py", "python")]
    with pytest.raises(FileNotFoundError):
        run(tmp_path, "a.py", "missing.py")
    assert capsys.readouterr().out == ""


def test_a_file_that_is_neither_go_nor_python_is_refused(tmp_path, crapper, capsys):
    (tmp_path / "a.rb").write_text("")
    with pytest.raises(SystemExit) as refused:
        run(tmp_path, "a.rb")
    assert "a.rb" in str(refused.value)
    assert capsys.readouterr().out == ""


def test_a_file_with_no_functions_prints_nothing(tmp_path, crapper, capsys):
    (tmp_path / "a.py").write_text("X = 1")
    crapper.found["a.py"] = []
    assert run(tmp_path, "a.py") == 0
    assert capsys.readouterr().out == ""


def test_a_missing_crapper_is_an_error_not_an_empty_report(tmp_path, monkeypatch):
    monkeypatch.setitem(sys.modules, "crapper", None)
    (tmp_path / "a.py").write_text("")
    with pytest.raises(ImportError):
        run(tmp_path, "a.py")
