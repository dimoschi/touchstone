#!/usr/bin/env python3
"""Derive mutmut mutant-name patterns for functions changed vs a git base.

Usage: mutmut_patterns.py <base-ref>   (changed .py files on stdin, one per line)

For each changed file, maps `git diff -U0 <base>` hunks to line ranges, walks
the current AST, and emits one TSV row per function overlapping a change:
    <pattern> TAB <file> TAB <lineno> TAB <qualname>

mutmut 3 rewrites functions with an `x_` prefix and names method mutants with
U+01C1 separators (`pkg.mod.xǁClassǁmethod__mutmut_N`), so patterns
must be derived, not guessed: a pattern set that matches nothing makes
`mutmut run` print an AssertionError yet exit 0.
"""

import ast
import subprocess
import sys

SEP = 'ǁ'


def changed_ranges(base, path):
    out = subprocess.run(
        ['git', 'diff', '-U0', base, '--', path],
        capture_output=True, text=True, check=True).stdout
    ranges = []
    for line in out.splitlines():
        if not line.startswith('@@'):
            continue
        new = line.split('+')[1].split(' ')[0]
        start, _, count = new.partition(',')
        start, count = int(start), int(count) if count else 1
        if count:
            ranges.append((start, start + count - 1))
    return ranges


def module_path(path):
    p = path[:-3] if path.endswith('.py') else path
    if p.startswith('src/'):
        p = p[4:]
    mod = p.replace('/', '.')
    if mod.endswith('.__init__'):
        mod = mod[:-len('.__init__')]
    return mod


def emit(path, base):
    ranges = changed_ranges(base, path)
    if not ranges:
        return
    with open(path) as f:
        tree = ast.parse(f.read(), filename=path)
    mod = module_path(path)

    def walk(node, cls):
        for child in ast.iter_child_nodes(node):
            if isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef)):
                lo, hi = child.lineno, child.end_lineno
                if any(a <= hi and b >= lo for a, b in ranges):
                    if cls:
                        pat = f"{mod}.x{SEP}{cls}{SEP}{child.name}__mutmut_*"
                        qual = f"{cls}.{child.name}"
                    else:
                        pat = f"{mod}.x_{child.name}__mutmut_*"
                        qual = child.name
                    print(f"{pat}\t{path}\t{child.lineno}\t{qual}")
                walk(child, cls)
            elif isinstance(child, ast.ClassDef):
                walk(child, child.name)
            else:
                walk(child, cls)

    walk(tree, None)


def main():
    base = sys.argv[1]
    for line in sys.stdin:
        path = line.strip()
        if path:
            emit(path, base)


if __name__ == '__main__':
    main()
