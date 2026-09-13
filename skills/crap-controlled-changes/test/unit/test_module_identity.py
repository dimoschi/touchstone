"""Every gated module must be importable under the dotted name its path implies.

This is what makes the Python mutation gate able to attribute a test to a
mutant. mutmut keys a mutant on the file path turned into a dotted name
(`hooks/mutation-pr-gate.py` -> `hooks.mutation-pr-gate`, hyphens and all) and
records a test as covering it by reading `__module__` off the function the test
called. When the suites import a module under any other name -- a bare
`base_branch` off a sys.path insertion, or the underscore-folded
`mutation_pr_gate` -- the two never match, every mutant comes back "no tests",
and the gate reports the whole changed function as unkilled.

`mutmut_patterns.module_path` is the repo's own copy of that derivation, so
asserting against it keeps the pattern generator and the loader honest together:
if one changes its rule, this fails rather than the gate silently scoring
nothing.
"""

from __future__ import annotations

import ast
import inspect
import sys
import types
from pathlib import Path

import pytest

from mutmut_patterns import module_path

ROOT = Path(__file__).resolve().parents[4]
SOURCE_DIRS = (ROOT / "hooks", ROOT / "skills" / "crap-controlled-changes" / "lib")


def gated_modules() -> list[Path]:
    found = []
    for directory in SOURCE_DIRS:
        for path in sorted(directory.glob("*.py")):
            if path.name.startswith("test_") or path.name == "conftest.py":
                continue
            found.append(path.relative_to(ROOT))
    return found


MODULES = gated_modules()


def test_the_module_list_is_not_empty():
    # A glob that silently matches nothing would make every case below vacuous.
    assert len(MODULES) > 20


@pytest.mark.parametrize("rel", MODULES, ids=str)
def test_module_is_registered_under_its_path_derived_name(rel: Path):
    dotted = module_path(str(rel))
    module = sys.modules.get(dotted)
    assert module is not None, f"{rel} is not importable as {dotted!r}"
    assert module.__name__ == dotted


@pytest.mark.parametrize("rel", MODULES, ids=str)
def test_the_bare_name_is_an_alias_of_the_same_module(rel: Path):
    # The suites import by bare name and must keep working unchanged; an alias
    # to a *second* copy would mean tests exercise one object while the gate
    # mutates another.
    bare = rel.stem.replace("-", "_")
    dotted = module_path(str(rel))
    assert sys.modules.get(bare) is sys.modules.get(dotted)


@pytest.mark.parametrize("rel", MODULES, ids=str)
def test_functions_carry_the_dotted_module_name(rel: Path):
    # This is the value mutmut's trampoline actually records.
    dotted = module_path(str(rel))
    module = sys.modules[dotted]
    # Which names the file defines comes from its own AST, not from
    # __code__.co_filename. A name pulled in with `from base_branch import git`
    # rightly keeps the sibling's __module__, so it has to be excluded; and
    # under a mutation run mutmut wraps each public function in a decorator
    # defined in its own package, which moves co_filename out of this file
    # while functools.wraps keeps __module__ intact. The AST sees through both.
    tree = ast.parse((ROOT / rel).read_text(), filename=str(rel))
    defined = [
        node.name
        for node in tree.body
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))
    ]
    checked = [
        getattr(module, name)
        for name in defined
        if inspect.isfunction(getattr(module, name, None))
    ]
    assert checked, f"no functions found in {rel}"
    for func in checked:
        assert func.__module__ == dotted


def test_a_module_registered_from_another_tree_is_replaced(monkeypatch):
    """The conftest that owns a tree must hand out that tree's modules.

    Under a mutation run pytest's rootdir search reaches the original conftest
    as well as the one copied into mutants/, so the dotted names can already be
    taken by unmutated modules when the second one loads. Returning those would
    run the suites against unmutated code and leave every mutant looking
    uncovered, which reads as a red gate with no defect behind it.
    """
    import conftest

    rel = MODULES[0]
    dotted = module_path(str(rel))
    bare = rel.stem.replace("-", "_")

    impostor = types.ModuleType(dotted)
    impostor.__file__ = str(Path("/elsewhere") / rel.name)
    monkeypatch.setitem(sys.modules, dotted, impostor)
    monkeypatch.setitem(sys.modules, bare, impostor)

    reloaded = conftest._load(bare, set())

    assert reloaded is not impostor
    assert Path(reloaded.__file__) == ROOT / rel
    assert sys.modules[bare] is reloaded
