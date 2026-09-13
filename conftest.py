"""Shared pytest setup for the unit suites under hooks/ and skills/crap-controlled-changes/lib/.

Both directories sit outside any package (this repo ships as a plugin, not a
Python package), so their modules are made importable by name here rather than
via a `src/` layout or `pyproject.toml`. Module basenames do not collide across
the two directories, so both can share one `sys.path` insertion.

Every module is loaded under the dotted name its path implies
(`hooks/mutation-pr-gate.py` -> `hooks.mutation-pr-gate`, hyphens kept) and then
aliased in `sys.modules` under its bare name, so the suites keep importing
`base_branch` while the module itself reports the dotted name. The mutation gate
needs that: mutmut keys a mutant on the path-derived dotted name and decides a
test covers it by reading `__module__` off the function the test called, so a
module loaded as `base_branch` or `mutation_pr_gate` matches nothing and every
mutant comes back "no tests". test_module_identity.py locks the agreement.

The same file is copied into mutants/ during a mutation run (it is listed in
setup.cfg's source_paths), where ROOT resolves to that tree, so the suites there
import the mutated copies rather than the originals.
"""

from __future__ import annotations

import ast
import importlib.util
import sys
from pathlib import Path
from types import ModuleType

ROOT = Path(__file__).resolve().parent
HOOKS_DIR = ROOT / "hooks"
LIB_DIR = ROOT / "skills" / "crap-controlled-changes" / "lib"

for directory in (HOOKS_DIR, LIB_DIR):
    path_str = str(directory)
    if path_str not in sys.path:
        sys.path.insert(0, path_str)


def _dotted_name(path: Path) -> str:
    """The name mutmut derives from a path: parts joined by dots, suffix dropped."""
    return ".".join(path.relative_to(ROOT).with_suffix("").parts)


def _gated_modules() -> dict[str, Path]:
    found = {}
    for directory in (HOOKS_DIR, LIB_DIR):
        for file in sorted(directory.glob("*.py")):
            if file.name.startswith("test_") or file.name == "conftest.py":
                continue
            found[file.stem.replace("-", "_")] = file
    return found


_GATED = _gated_modules()


def _sibling_imports(source: str, filename: str) -> set[str]:
    """Bare names this source imports that are themselves gated modules."""
    names: set[str] = set()
    for node in ast.walk(ast.parse(source, filename=filename)):
        if isinstance(node, ast.Import):
            names.update(alias.name.split(".")[0] for alias in node.names)
        elif isinstance(node, ast.ImportFrom) and node.level == 0 and node.module:
            names.add(node.module.split(".")[0])
    return {name for name in names if name in _GATED}


def _load(bare: str, loading: set[str]) -> ModuleType:
    file = _GATED[bare]
    dotted = _dotted_name(file)
    cached = sys.modules.get(dotted)
    # Same dotted name, different file means a copy of this repo's conftest in
    # another tree got there first. During a mutation run pytest's rootdir
    # search walks up out of mutants/ and loads the original conftest too,
    # which registers the unmutated modules under these exact names; handing
    # those back would run every test against unmutated code and report each
    # mutant as covered by nothing. Whichever tree this conftest lives in wins
    # for its own modules.
    if cached is not None and Path(getattr(cached, "__file__", "")) == file:
        return cached
    loading.add(bare)
    # Dependencies first. Several hooks import each other at module scope, and a
    # sibling reached before this loader gets to it would be imported off
    # sys.path under its bare name, leaving a second copy with the wrong
    # __name__ that the tests would exercise while the gate mutated the other.
    source = file.read_text()
    for dep in _sibling_imports(source, str(file)):
        if dep not in loading:
            _load(dep, loading)
    module = importlib.util.module_from_spec(
        spec := importlib.util.spec_from_file_location(dotted, file)
    )
    sys.modules[dotted] = module
    sys.modules[bare] = module
    spec.loader.exec_module(module)
    loading.discard(bare)
    return module


for _bare in _GATED:
    _load(_bare, set())


def load_script(path: Path) -> ModuleType:
    """Import a hyphen-named script (not a valid module name) by file path.

    Kept as the suites' entry point for the eight hyphen-named hooks. The module
    is already loaded by the time a test calls this, so it returns that object
    rather than a second copy.
    """
    bare = Path(path).stem.replace("-", "_")
    if bare in _GATED:
        return _load(bare, set())
    spec = importlib.util.spec_from_file_location(bare, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[bare] = module
    spec.loader.exec_module(module)
    return module
