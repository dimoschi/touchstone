#!/usr/bin/env python3
"""Detect a Python project living in a subdirectory of the repo.

    <repo-relative changed paths on stdin> | python_project.py --repo-root <abs>
    python_project.py --repo-root <abs> --root-declares
    <repo-relative changed paths on stdin> | python_project.py --repo-root <abs> \
      --group --group-by <dir> [--group-by <dir> ...]

Prints, one per line, the distinct repo-relative directories that are the
nearest `pyproject.toml`-owning ancestor of a changed file, strictly below
the repo root, where that `pyproject.toml` declares `[tool.coverage.run]` or
`[tool.pytest.ini_options]`. Empty output means the repo's Python project (if
any) sits at the root, exactly where crap-check-python.sh already runs from.

`--root-declares` answers a different question and ignores stdin: does the
repo root's *own* pyproject.toml declare one of the two sections? A workspace
member can carry its own qualifying pyproject.toml purely for its own
standalone use, without being a separate project the gate needs to measure
from; when the root already declares [tool.coverage.run], it is the answer
regardless of what a member's pyproject.toml says. A root that declares only
[tool.pytest.ini_options] is weaker: that section says nothing about where
coverage.py should measure from, so it cannot license skipping a member's own
[tool.coverage.run] the same way. `--coverage-only` narrows both
`--root-declares` and the default find mode to that one section, so a caller
can ask the two questions this distinction requires: does the root's own
coverage config win outright, and if not, does some member's own coverage
config exist that the root does not reproduce?

`--group` prints "<owning-dir>\t<file>" per changed file, once the caller has
already settled on the set of directories to measure from (a diff can span
more than one Python project; each file needs its own coverage run scoped to
its own directory, not one run from an arbitrary pick among them). A file
outside every `--group-by` directory is assigned the first one, since that
can only happen for a file the caller's own directory list did not account
for.

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
COVERAGE_SECTION_RE = re.compile(r"^\s*\[tool\.coverage\.run\]\s*$")


def declares_project(pyproject_path, coverage_only=False):
    """True if pyproject_path has a [tool.coverage.run] or
    [tool.pytest.ini_options] table header. `coverage_only` narrows that to
    [tool.coverage.run] alone: that is the section coverage.py actually
    resolves relative paths from, so it is the only one that can make a
    directory authoritative over a *different* directory's own such section
    (see --root-declares below)."""
    pattern = COVERAGE_SECTION_RE if coverage_only else SECTION_RE
    try:
        with open(pyproject_path, encoding="utf-8") as fh:
            for line in fh:
                if pattern.match(line):
                    return True
    except OSError:
        return False
    return False


def find_project_dirs(changed, repo_root, coverage_only=False):
    """Sorted repo-relative dirs: the nearest pyproject.toml-owning ancestor
    of each changed file, strictly below repo_root, whose pyproject.toml
    declares one of the two sections (or just [tool.coverage.run], with
    `coverage_only`)."""
    found = set()
    for rel in changed:
        d = os.path.dirname(rel)
        while d not in ("", "."):
            candidate = os.path.join(repo_root, d, "pyproject.toml")
            if declares_project(candidate, coverage_only=coverage_only):
                found.add(os.path.normpath(d))
                break
            parent = os.path.dirname(d)
            # An absolute rel (only reachable via a hand-set CRAP_FILES; both
            # real call sites feed repo-relative paths) walks up to "/", whose
            # own dirname is itself, so the loop above would never see "" or
            # "." and spin forever.
            if parent == d:
                break
            d = parent
    return sorted(found)


def _candidate_match_len(d, cand):
    """None if `cand` does not own directory `d`; its match length otherwise
    ("." always owns, at length 0, the weakest match)."""
    if cand == ".":
        return 0
    if d == cand or d.startswith(cand + os.sep):
        return len(cand)
    return None


def owning_dir(rel, candidates):
    """The `candidates` entry (repo-relative, normalized) that owns `rel`:
    the longest one that is `rel`'s own directory or an ancestor of it, "."
    matching anything. `candidates[0]` if none of them do."""
    d = os.path.normpath(os.path.dirname(rel)) or "."
    best, best_len = None, -1
    for cand in candidates:
        length = _candidate_match_len(d, cand)
        if length is not None and length > best_len:
            best, best_len = cand, length
    return best if best is not None else candidates[0]


def _read_changed():
    return [os.path.normpath(p) for p in sys.stdin.read().splitlines() if p.strip()]


def _cmd_group(changed, group_by):
    candidates = [os.path.normpath(d) for d in group_by]
    for rel in changed:
        print(f"{owning_dir(rel, candidates)}\t{rel}")


def _cmd_find(changed, repo_root, coverage_only=False):
    for d in find_project_dirs(changed, repo_root, coverage_only=coverage_only):
        print(d)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo-root", required=True)
    ap.add_argument("--root-declares", action="store_true",
                     help="print 1/0: does the repo root's own pyproject.toml "
                          "declare [tool.coverage.run] or [tool.pytest.ini_options]?")
    ap.add_argument("--coverage-only", action="store_true",
                     help="restrict --root-declares, or the default find mode, to "
                          "[tool.coverage.run] alone")
    ap.add_argument("--group", action="store_true",
                     help="print '<owning-dir>\\t<file>' per changed file on stdin")
    ap.add_argument("--group-by", action="append", default=[],
                     help="a directory --group assigns changed files to; repeatable")
    args = ap.parse_args()

    repo_root = os.path.abspath(args.repo_root)

    if args.root_declares:
        declares = declares_project(os.path.join(repo_root, "pyproject.toml"),
                                     coverage_only=args.coverage_only)
        print(1 if declares else 0)
        return 0

    changed = _read_changed()
    if args.group:
        _cmd_group(changed, args.group_by)
    else:
        _cmd_find(changed, repo_root, coverage_only=args.coverage_only)
    return 0


if __name__ == "__main__":
    sys.exit(main())
