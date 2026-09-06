#!/usr/bin/env python3
"""Resolve Go files to their enclosing module, and walk the `replace` graph.

    <files on stdin> | go_modules.py group     -> moddir \t pkgdir \t repopath \t modpath
    go_modules.py roots <moddir>               -> every module that reaches it
    go_modules.py modpath <moddir>             -> the module path from its go.mod

Every Go gate needs the same answer to "which module owns this file", because
each one has to run its tool from inside a module. That resolution lived three
times over, once in each of deadcode-check.sh, crap-check-go.sh and
mutation-check-go.sh, as bash 4 associative arrays. Three copies of a rule that
decides *what gets measured* can drift apart while all three gates still report
green, which is the failure this file exists to prevent.

Paths are repo-relative throughout; the repo root is git's toplevel. A module
directory is "." for the root module, matching the historic shell behaviour.
"""

import os
import subprocess
import sys
from pathlib import PurePosixPath


def repo_root():
    out = subprocess.run(['git', 'rev-parse', '--show-toplevel'],
                         capture_output=True, text=True)
    if out.returncode != 0:
        sys.exit('go_modules: not inside a git repo')
    return out.stdout.strip()


def module_dirs(root):
    """Every directory holding a go.mod, repo-relative, '.' for the root."""
    out = subprocess.run(['git', 'ls-files', '*go.mod'],
                         capture_output=True, text=True, cwd=root)
    dirs = set()
    for line in out.stdout.splitlines():
        if line.strip():
            dirs.add(str(PurePosixPath(line).parent))
    # An untracked go.mod still defines a module for a tool running inside it,
    # and the root one is the common case in a single-module repo.
    if os.path.isfile(os.path.join(root, 'go.mod')):
        dirs.add('.')
    return dirs


def owning_module(path, moddirs, root):
    """Nearest ancestor directory of `path` that holds a go.mod, else '.'.

    Both a tracked go.mod (moddirs, from git) and one merely present on disk
    count. The untracked case is not hypothetical: a change that adds a module
    stages its .go files while go.mod is still untracked, and resolving those
    files to the parent module would measure them from the wrong root.

    The walk itself is over the path, so a file that no longer exists still
    resolves: the mutation gate reads a list that can name deleted files.
    """
    d = PurePosixPath(path).parent
    while True:
        cand = str(d)
        if cand in moddirs or os.path.isfile(os.path.join(root, cand, 'go.mod')):
            return cand
        if cand in ('.', '/', ''):
            return '.'
        d = d.parent


def modpath(root, moddir):
    """The module path declared in <moddir>/go.mod, or '' if unreadable."""
    gomod = os.path.join(root, moddir, 'go.mod')
    try:
        with open(gomod, encoding='utf-8', errors='replace') as fh:
            for line in fh:
                if line.startswith('module '):
                    return line.split(None, 1)[1].strip()
    except OSError:
        pass
    return ''


def local_replacements(root, moddir):
    """Module dirs that <moddir>/go.mod replaces with a local relative path.

    Only `=> ./x` and `=> ../x` forms: a replace pointing at a published
    version is not another directory in this repo.
    """
    gomod = os.path.join(root, moddir, 'go.mod')
    deps = set()
    try:
        with open(gomod, encoding='utf-8', errors='replace') as fh:
            lines = fh.readlines()
    except OSError:
        return deps

    in_block = False
    for raw in lines:
        line = raw.split('//', 1)[0].strip()
        if not line:
            continue
        if line.startswith('replace') and line.endswith('('):
            in_block = True
            continue
        if in_block and line == ')':
            in_block = False
            continue
        if not in_block and not line.startswith('replace '):
            continue
        if '=>' not in line:
            continue
        target = line.split('=>', 1)[1].strip().split()[0]
        if not target.startswith('.'):
            continue
        # The target is relative to the replacing module's own directory.
        resolved = os.path.normpath(os.path.join(moddir, target))
        deps.add('.' if resolved in ('', '.') else resolved)
    return deps


def roots(root, target):
    """`target` plus every module that reaches it through local replaces.

    A library module's callers live in another module, so analysing only the
    module a file sits in reports the whole exported API of a shared package as
    unreachable. Transitive on purpose: a module two replaces away still builds
    the code, and stopping at one hop was a false positive an --accept would
    have frozen in.
    """
    moddirs = module_dirs(root)
    edges = {m: local_replacements(root, m) for m in moddirs}
    want = {target}
    changed = True
    while changed:
        changed = False
        for m, deps in edges.items():
            if m not in want and deps & want:
                want.add(m)
                changed = True
    return want


def cmd_group(root):
    moddirs = module_dirs(root)
    rows = []
    for line in sys.stdin:
        f = line.strip()
        if not f:
            continue
        mod = owning_module(f, moddirs, root)
        pkg = str(PurePosixPath(f).parent)
        rel = f if mod == '.' else str(PurePosixPath(f).relative_to(mod))
        rows.append((mod, pkg, f, './' + rel))
    # Sorted so callers iterating modules get a stable order, and so a module's
    # files arrive together without the caller grouping them again.
    for row in sorted(rows):
        print('\t'.join(row))


def main(argv):
    if len(argv) < 2:
        sys.exit(__doc__)
    root = repo_root()
    cmd = argv[1]

    if cmd == 'group':
        cmd_group(root)
    elif cmd == 'roots':
        if len(argv) < 3:
            sys.exit('usage: go_modules.py roots <moddir>')
        for m in sorted(roots(root, argv[2])):
            print(m)
    elif cmd == 'modpath':
        if len(argv) < 3:
            sys.exit('usage: go_modules.py modpath <moddir>')
        print(modpath(root, argv[2]))
    else:
        sys.exit(f'go_modules: unknown command {cmd!r}')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
