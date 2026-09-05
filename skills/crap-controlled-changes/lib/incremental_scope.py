#!/usr/bin/env python3
"""Narrow a language's changed-source list to what a follow-up commit dirtied.

Usage: incremental_scope.py <go|php|py> <invalidated-paths-file>
       candidate source paths on stdin, narrowed list on stdout

`invalidated-paths-file` holds every changed path the mutation ledger does not
already record as measured, plus every path the diff deletes: the union of
"needs measuring" and "cannot be measured". Splitting them apart is unnecessary
because a deleted path does not exist on disk, so existence separates the two.

A candidate survives narrowing when it is in that set. Everything left over
(`invalidated - narrowed`) is a path that invalidates a measurement without
being measurable itself, and each kind matters:

  - a changed or deleted test file un-kills mutants in a source whose own blob
    never changed, which is the whole reason tests are in the ledger key
  - a changed generated file (mocks, sqlc output) is excluded from mutation but
    can still decide whether a mutant survives
  - a deleted source changes its package's behaviour with nothing left to mutate

Go closes over those by directory, since a package is a directory and the source
that a test kills mutants in sits beside it. PHP and Python keep their tests in a
separate tree with no reliable mapping back, so they fall back to the full
candidate list rather than guess; narrowing there only pays off while no test
file changed.

Deliberately not closed: a changed source in another package that a surviving
mutant's kill depends on. That needs a reverse-dependency closure, which is a lot
of machinery for a narrow case; mutation-check.sh --full is the escape hatch and
prints what it skipped either way.
"""

import os
import sys

EXT = {'go': '.go', 'php': '.php', 'py': '.py'}


def read_lines(stream):
    return [line.strip() for line in stream if line.strip()]


def closure(lang, candidates, invalidated):
    if lang != 'go':
        return set(candidates)
    dirs = {os.path.dirname(p) for p in invalidated}
    return {c for c in candidates if os.path.dirname(c) in dirs}


def main():
    lang, invalidated_path = sys.argv[1], sys.argv[2]
    with open(invalidated_path) as f:
        invalidated = {p for p in read_lines(f) if p.endswith(EXT[lang])}

    # A deleted candidate has nothing to mutate, so it never enters the scope;
    # it stays in `invalidated` below and pulls its package back in instead.
    candidates = [c for c in read_lines(sys.stdin) if os.path.exists(c)]
    narrowed = {c for c in candidates if c in invalidated}

    if invalidated - narrowed:
        narrowed |= closure(lang, candidates, invalidated - narrowed)

    for path in sorted(narrowed):
        print(path)


if __name__ == '__main__':
    main()
