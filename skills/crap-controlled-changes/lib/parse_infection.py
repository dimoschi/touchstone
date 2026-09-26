#!/usr/bin/env python3
"""Emit normalized survivor rows from infection's JSON report.

Usage: parse_infection.py <infection-report.json> [repo-root]

Escaped entries carry mutator name, absolute file path, start line, and a
unified diff; uncovered mutants are survivors too (no test even executes
the line).
"""

import json
import os
import sys


# Both sides are resolved: infection reports /private/var/... where $PWD says
# /var/..., so a plain prefix test leaves every row absolute. The path also lands
# in the mutant id, which the accept ledger matches across worktrees.
def rows(entries, root):
    root = os.path.realpath(root) if root else ''
    for e in entries:
        m = e.get('mutator') or {}
        path = m.get('originalFilePath', '?')
        real = os.path.realpath(path) if path != '?' else path
        if root and real.startswith(root + os.sep):
            path = real[len(root) + 1:]
        loc = f"{path}:{m.get('originalStartLine', '?')}"
        mut = m.get('mutatorName', '?')
        print(f"{loc:<42} {mut:<26} SURVIVED  id={mut}@{loc}")
        diff = (e.get('diff') or '').strip()
        for line in diff.splitlines():
            if line.startswith(('+', '-')) and not line.startswith(('+++', '---')):
                print(f"    {line}")


def total_count(doc):
    """Mutants infection actually generated, per its own stats block.

    escaped/uncovered being empty is not evidence of a killed run: it is the
    same shape as a run that generated nothing, so the caller needs this count
    to tell the two apart.
    """
    return (doc.get('stats') or {}).get('totalMutantsCount', 0)


def main():
    if len(sys.argv) > 2 and sys.argv[1] == '--total':
        with open(sys.argv[2]) as f:
            doc = json.load(f)
        print(total_count(doc))
        return
    with open(sys.argv[1]) as f:
        doc = json.load(f)
    root = sys.argv[2] if len(sys.argv) > 2 else ''
    rows(doc.get('escaped') or [], root)
    rows(doc.get('uncovered') or [], root)


if __name__ == '__main__':
    main()
