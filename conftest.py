"""Shared pytest setup for the unit suites under hooks/ and skills/crap-controlled-changes/lib/.

Both directories sit outside any package (this repo ships as a plugin, not a
Python package), so their modules are made importable by name here rather than
via a `src/` layout or `pyproject.toml`. Module basenames do not collide across
the two directories, so both can share one `sys.path` insertion.
"""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
HOOKS_DIR = ROOT / "hooks"
LIB_DIR = ROOT / "skills" / "crap-controlled-changes" / "lib"

for directory in (HOOKS_DIR, LIB_DIR):
    path_str = str(directory)
    if path_str not in sys.path:
        sys.path.insert(0, path_str)


def load_script(path: Path):
    """Import a hyphen-named script (not a valid module name) by file path.

    Running the module executes any top-level `sys.path.insert` it carries,
    which is harmless: it re-inserts a directory already on sys.path above.
    """
    name = path.stem.replace("-", "_")
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module
