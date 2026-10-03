"""The entry_reachable signal: changed code that a main package can reach.

Only Go has a reachability tool here: `deadcode` builds a call graph from every
main package and lists what it cannot reach. A changed function is one whose
body or signature holds a line the range added, in a file other than a `_test.go`
file: deadcode loads no test file, so a function in one is never listed and
would read as reachable. The signal is true when any changed function is
reachable and false when all are not; a module with no main
package (a library's entry points are its exported API, which no call graph
sees), a language without a tool, or a missing tool is unmeasured.
"""

import os
import re

import go_modules
from risk_core import combine_any, measured, unmeasured
from risk_scan import scan_head
from risk_tools import missing, run, tail

UNREACHABLE = re.compile(r'^(?P<path>[^:\n]+):(?P<line>\d+):\d+: unreachable func: ',
                         re.MULTILINE)


def enclosing_func(lines, n):
    """1-based line of the top-level `func` holding line `n`, else None.

    Reads gofmt layout: a declaration starts a line, and a `}` at the start of
    a line ends the declaration above it, so a line below one is outside any
    function.
    """
    n = min(n, len(lines))
    for i in range(n, 0, -1):
        text = lines[i - 1]
        if text.startswith('func '):
            return i
        if i != n and text.rstrip() == '}':
            return None
    return None


def unreachable_funcs(text, moddir):
    """{(repo path, declaration line)} deadcode reports from inside `moddir`."""
    return {(os.path.normpath(os.path.join(moddir, m['path'])), int(m['line']))
            for m in UNREACHABLE.finditer(text)}


def file_lines(head_root, path):
    try:
        with open(os.path.join(head_root, path), encoding='utf-8', errors='replace') as fh:
            return fh.read().splitlines()
    except OSError:
        return []


def changed_funcs(head_root, added, paths):
    found = set()
    for path in paths:
        lines = file_lines(head_root, path)
        decls = (enclosing_func(lines, n) for n in sorted(added.get(path, ())))
        found.update((path, decl) for decl in decls if decl)
    return found


def by_module(head_root, funcs):
    groups = {}
    for path, line in funcs:
        module = go_modules.owning_module(path, set(), head_root)
        groups.setdefault(module, set()).add((path, line))
    return groups


def describe_live(live):
    return 'reachable from a main package: ' + ', '.join(f'{path}:{line}' for path, line in live)


def module_part(head_root, moddir, funcs):
    modpath = go_modules.modpath(head_root, moddir)
    done = run(['deadcode', '-generated', f'-filter=^{re.escape(modpath)}', './...'],
               cwd=os.path.join(head_root, moddir))
    if 'no main packages' in done.stderr:
        return unmeasured(f'module {moddir} has no main package, so reachability is undecidable')
    if done.returncode != 0:
        return unmeasured(f'deadcode exited {done.returncode} on module {moddir}: '
                          f'{tail(done.stderr)}')
    live = sorted(funcs - unreachable_funcs(done.stdout, moddir))
    if live:
        return measured(True, describe_live(live))
    return measured(False, f'deadcode: every changed function in module {moddir} is '
                           f'unreachable from a main package')


def deadcode_part(head_root, sources, added):
    gap = missing('deadcode')
    if gap:
        return unmeasured(gap)
    funcs = changed_funcs(head_root, added, sources)
    if not funcs:
        return unmeasured('no added line sits inside a Go function')
    modules = sorted(by_module(head_root, funcs).items())
    return combine_any([module_part(head_root, m, fs) for m, fs in modules],
                       'no Go function changed')


def go_part(head_root, paths, added):
    sources = [p for p in paths if not p.endswith('_test.go')]
    if not sources:
        return measured(False, 'every changed Go file is a _test.go file: no main package '
                               'calls test code, and deadcode does not load it')
    return deadcode_part(head_root, sources, added)


HANDLERS = {'go': go_part}


def reach_signal(repo, head, groups, added):
    return scan_head(HANDLERS, 'reachability tool', repo, head, groups, added)
