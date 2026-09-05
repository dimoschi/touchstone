#!/usr/bin/env python3
"""Explain why a Go file is outside the current build, and what enabling it costs.

Usage:
  buildtag_diagnosis.py tags <file>            -> required tags, one per line
  buildtag_diagnosis.py conflicts <dir> <tag>  -> count of *_test.go excluded by <tag>

A file the build omits produces no mutants, so the gate has to refuse: reporting a
pass on code nothing compiled is worse than reporting nothing. But "set the tag" is
only half an answer, because a tag that pulls one file in pushes out every test file
constrained against it, and mutants those tests would have killed then survive for a
reason that has nothing to do with the code. Counting them turns the refusal into a
choice between measuring this path in a run of its own and leaving it out.

Constraints are read, not evaluated: a term is required when it appears without `!`
in the constraint line, so `integration && !windows` requires `integration` alone.
That is deliberately approximate. It names the tag a human needs in the common case
and is only ever used to write an error message, never to decide a verdict.
"""

import os
import re
import sys

TERM = re.compile(r'!?[A-Za-z0-9_.]+')


def constraint(path):
    """The build-constraint expression of a Go file, or '' when it has none.

    Only lines above the package clause count; a `//go:build` further down is an
    ordinary comment and gcc-style `+build` lines are the pre-1.17 spelling.
    """
    try:
        with open(path, errors='replace') as f:
            lines = f.readlines()
    except OSError:
        return ''
    parts = []
    for line in lines:
        stripped = line.strip()
        if stripped.startswith('package '):
            break
        if stripped.startswith('//go:build '):
            return stripped[len('//go:build '):].strip()
        if stripped.startswith('// +build '):
            parts.append(stripped[len('// +build '):].strip())
    return ' '.join(parts)


def required_tags(expr):
    return [t for t in TERM.findall(expr)
            if not t.startswith('!') and t not in ('true', 'false')]


def negated_tags(expr):
    return {t[1:] for t in TERM.findall(expr) if t.startswith('!')}


def main():
    mode = sys.argv[1]

    if mode == 'tags':
        for tag in dict.fromkeys(required_tags(constraint(sys.argv[2]))):
            print(tag)
        return 0

    root, tag = sys.argv[2], sys.argv[3]
    count = 0
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in ('.git', 'vendor', 'testdata')]
        for name in filenames:
            if not name.endswith('_test.go'):
                continue
            if tag in negated_tags(constraint(os.path.join(dirpath, name))):
                count += 1
    print(count)
    return 0


if __name__ == '__main__':
    sys.exit(main())
