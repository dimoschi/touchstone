"""crapper_spans.py with crapper replaced by a stand-in.

The stand-in mirrors the parts of crapper's API the script reads, as they are at
the pinned commit: `functions_in_file` returns Function-like records whose
`namespace` is the module (Python) or import path (Go) plus any class or
receiver, `_module_namespace` builds the Python prefix, `_package_clause` reads
the package name off a parsed tree, and the tree-sitter helpers walk a tree of
nodes shaped like tree-sitter-go's.
"""

import sys
import types
from dataclasses import dataclass, field

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


@dataclass(frozen=True)
class Node:
    type: str
    children: tuple = ()
    text: str = ""
    row: int = 0
    fields: dict = field(default_factory=dict)

    @property
    def start_point(self):
        return (self.row, 0)

    def child_by_field_name(self, name):
        return self.fields[name]


def method(line, receiver):
    """`func (s <receiver>) M()` on <line>, reduced to the nodes the script reads."""
    written = Node("type", text=receiver)
    declaration = Node("parameter_declaration", (Node("identifier", text="s"), written),
                       fields={"type": written})
    return Node("method_declaration", (Node("parameter_list", (declaration,)),), row=line - 1)


@pytest.fixture
def crapper(monkeypatch):
    """Install a stand-in crapper; `.found` maps a path to the functions it holds,
    `.methods` to the method declarations its Go tree holds."""
    state = types.SimpleNamespace(found={}, seen=[], package="calc", methods=[])

    def functions_in_file(language, source, path, root):
        state.seen.append((language, source, path, root))
        return state.found[path]

    def module_namespace(path, root):
        return path[:-len(".py")].replace("/", ".")

    def parse(source, language):
        tree = Node("source_file", tuple(state.methods))
        return source.encode(), types.SimpleNamespace(root_node=tree)

    def package_clause(data, root):
        return state.package

    def descendants(node):
        stack = [node]
        while stack:
            current = stack.pop()
            yield current
            stack.extend(reversed(current.children))

    def child_of_type(node, *kinds):
        return next((child for child in node.children if child.type in kinds), None)

    def module(name, **attributes):
        made = types.ModuleType(name)
        vars(made).update(attributes)
        monkeypatch.setitem(sys.modules, name, made)
        return made

    package = module("crapper")
    languages = module("crapper.languages", functions_in_file=functions_in_file)
    languages.python = module("crapper.languages.python", _module_namespace=module_namespace)
    languages.golang = module("crapper.languages.golang", _package_clause=package_clause)
    treesitter = module("crapper.languages.treesitter", parse=parse, descendants=descendants,
                        child_of_type=child_of_type, start_line=lambda node: node.row + 1,
                        node_text=lambda data, node: node.text)
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
    crapper.methods = [method(1, "*Widget")]
    run(tmp_path, "calc.go")
    assert capsys.readouterr().out == "calc.go\t1\t5\t2\tcalc.Widget.Run\tcalc\n"


def test_a_go_method_keeps_the_type_parameters_its_receiver_declares(tmp_path, crapper, capsys):
    (tmp_path / "gen.go").write_text("package calc")
    crapper.found["gen.go"] = [
        Function("Push", "example.com/m/calc.Stack", 1, 5, 7, "gen.go", "go"),
        Function("Len", "example.com/m/calc.Stack", 1, 9, 11, "gen.go", "go"),
        Function("Run", "example.com/m/calc.Widget", 2, 13, 15, "gen.go", "go"),
        Function("Plain", "example.com/m/calc", 1, 17, 19, "gen.go", "go"),
    ]
    crapper.methods = [method(5, "*Stack[T]"), method(9, "Stack[T]"), method(13, "Widget")]
    run(tmp_path, "gen.go")
    assert capsys.readouterr().out.splitlines() == [
        "gen.go\t5\t7\t1\tcalc.Stack[T].Push\tcalc",
        "gen.go\t9\t11\t1\tcalc.Stack[T].Len\tcalc",
        "gen.go\t13\t15\t2\tcalc.Widget.Run\tcalc",
        "gen.go\t17\t19\t1\tcalc.Plain\tcalc",
    ]


def test_a_go_method_id_has_no_whitespace_however_the_receiver_is_spaced(tmp_path, crapper, capsys):
    (tmp_path / "gen.go").write_text("package calc")
    crapper.found["gen.go"] = [
        Function("Get", "example.com/m/calc.Map", 1, 5, 7, "gen.go", "go"),
        Function("Put", "example.com/m/calc.Map", 1, 9, 11, "gen.go", "go"),
        Function("Len", "example.com/m/calc.Stack", 1, 13, 15, "gen.go", "go"),
    ]
    crapper.methods = [method(5, "*Map[K, V]"), method(9, "Map[K,  V]"), method(13, "* Stack[T]")]
    run(tmp_path, "gen.go")
    assert capsys.readouterr().out.splitlines() == [
        "gen.go\t5\t7\t1\tcalc.Map[K,V].Get\tcalc",
        "gen.go\t9\t11\t1\tcalc.Map[K,V].Put\tcalc",
        "gen.go\t13\t15\t1\tcalc.Stack[T].Len\tcalc",
    ]


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
