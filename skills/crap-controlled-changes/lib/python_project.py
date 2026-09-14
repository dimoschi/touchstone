#!/usr/bin/env python3
"""Detect a Python project living in a subdirectory of the repo.

    <repo-relative changed paths on stdin> | python_project.py --repo-root <abs>

Prints, one per line, the distinct repo-relative directories that are the
nearest `pyproject.toml`-owning ancestor of a changed file, strictly below
the repo root, where that `pyproject.toml` declares `[tool.coverage.run]` or
`[tool.pytest.ini_options]`. Empty output means the repo's Python project (if
any) sits at the root, exactly where crap-check-python.sh already runs from.

The two sections are detected with a line scan for the header, not
`tomllib`: `tomllib` only ships from Python 3.11, and the gate has to run on
whatever python3 a user has (macOS system python is 3.9). Presence of the
header is all that is needed here, not the table's contents.
"""

import argparse
import os
import re
import sys

SECTION_RE = re.compile(r"^\s*\[(tool\.coverage\.run|tool\.pytest\.ini_options)\]\s*$")


def declares_project(pyproject_path):
    """True if pyproject_path has a [tool.coverage.run] or
    [tool.pytest.ini_options] table header."""
    try:
        with open(pyproject_path, encoding="utf-8") as fh:
            for line in fh:
                if SECTION_RE.match(line):
                    return True
    except OSError:
        return False
    return False


def find_project_dirs(changed, repo_root):
    """Sorted repo-relative dirs: the nearest pyproject.toml-owning ancestor
    of each changed file, strictly below repo_root, whose pyproject.toml
    declares one of the two sections."""
    found = set()
    for rel in changed:
        d = os.path.dirname(rel)
        while d not in ("", "."):
            candidate = os.path.join(repo_root, d, "pyproject.toml")
            if declares_project(candidate):
                found.add(os.path.normpath(d))
                break
            d = os.path.dirname(d)
    return sorted(found)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo-root", required=True)
    args = ap.parse_args()

    repo_root = os.path.abspath(args.repo_root)
    changed = [
        os.path.normpath(p)
        for p in sys.stdin.read().splitlines()
        if p.strip()
    ]
    for d in find_project_dirs(changed, repo_root):
        print(d)
    return 0


if __name__ == "__main__":
    sys.exit(main())
