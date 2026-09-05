#!/usr/bin/env python3
"""Decide reachability for symbols in one module using every root that can see it.

deadcode builds its call graph from the main packages in the module it runs in.
A shared library module (db/, testsupport/) has no main of its own that uses it,
so analysing it alone reports its whole exported API as unreachable while the
consumer that calls it sits in another module, invisible.

This takes the findings of several analysis roots and reports a symbol as dead
only when every root that actually built its package agrees it is unreachable.
A root whose build does not include the package casts no vote: silence there
means "not analysed", not "reachable".

Usage:
  deadcode_scope.py <added-keys> <mod-dir> <mod-path> <manifest>

<manifest> has one root per line: "<root-dir>\t<findings-file>\t<pkgs-file>".
<findings-file> holds that root's deadcode output, paths already repo-relative.
<pkgs-file> holds `go list -deps ./...` for the root, one import path per line.
<test-findings-file> holds the same root's `deadcode -test` output, and
<testonly-file> the packages no non-test file imports (deadcode_testonly.py).
For those packages the -test pass decides: a package only tests import has no
other consumer by construction, so "reachable from a test" is the only liveness
question there is. Everywhere else the no--test pass decides on its own, which
is what keeps the helper-plus-its-own-test loophole shut.

Prints deadcode-format lines for the dead symbols only, so the caller can pipe
them into deadcode_accepted.py unchanged. Symbols no root built are listed on
stderr and counted, because unanalysed is not a pass.
Exit: 0 always; the caller decides what to do with the output.
"""

import os
import re
import sys

FINDING = re.compile(r'^(?P<file>[^:]+):(?P<line>\d+):(?P<col>\d+): unreachable func: (?P<name>\S+)')


def package_of(repo_file, mod_dir, mod_path):
    """Import path of the package holding repo_file."""
    rel = os.path.relpath(os.path.dirname(repo_file), mod_dir)
    return mod_path if rel == '.' else f"{mod_path}/{rel}"


def read_lines(path):
    with open(path) as f:
        return [ln.rstrip('\n') for ln in f if ln.strip()]


def findings_map(path):
    """Findings keyed "<file>|<symbol>", the same key shape as the added list."""
    out = {}
    for line in read_lines(path):
        m = FINDING.match(line)
        if m:
            out[f"{m.group('file')}|{m.group('name')}"] = line
    return out


def main():
    added_path, mod_dir, mod_path, manifest_path = sys.argv[1:5]

    added = set(read_lines(added_path))
    roots = []
    for line in read_lines(manifest_path):
        root, findings_file, pkgs_file, test_findings_file, testonly_file = line.split('\t')
        roots.append({
            'dir': root,
            'unreachable': findings_map(findings_file),
            'pkgs': set(read_lines(pkgs_file)),
            'test_unreachable': findings_map(test_findings_file),
            'testonly': set(read_lines(testonly_file)),
        })

    unanalysed = []
    for key in sorted(added):
        repo_file = key.split('|', 1)[0]
        if os.path.relpath(repo_file, mod_dir).startswith('..'):
            continue
        pkg = package_of(repo_file, mod_dir, mod_path)

        voters = [r for r in roots if pkg in r['pkgs']]
        if not voters:
            unanalysed.append((key, pkg))
            continue

        # Alive as soon as one root that built the package does not report it.
        # In a package only tests import, the -test pass gets the deciding vote:
        # nothing else can reach it, so a test caller is the liveness it was
        # written for. A helper there that no test calls is still dead.
        verdicts = []
        for r in voters:
            found = r['unreachable'].get(key)
            if found is not None and pkg in r['testonly'] \
                    and r['test_unreachable'].get(key) is None:
                found = None
            verdicts.append(found)
        if all(v is not None for v in verdicts):
            print(verdicts[0])

    if unanalysed:
        print(f"deadcode-check: {len(unanalysed)} symbol(s) in '{mod_dir}' were NOT analysed:",
              file=sys.stderr)
        for key, pkg in unanalysed:
            print(f"  {key}  (package {pkg} is in no main package's build)", file=sys.stderr)
        print("  This is not a pass for them; nothing could decide reachability.",
              file=sys.stderr)
    return 0


if __name__ == '__main__':
    sys.exit(main())
