"""The api_broken signal: a public API the range breaks, asked of one tool per language.

Go uses `apidiff -incompatible` (it exits 0 either way, so a non-empty stdout is
the finding), Python `griffe check`, PHP Roave BackwardCompatibilityCheck. A
language with no tool, or a tool that is missing, is unmeasured rather than
false. Where the package or module did not exist at the base revision there is
no earlier API to break, which is a measured false.
"""

import os
import re
import tempfile
from posixpath import basename, dirname, splitext

import go_modules
from risk_core import combine_any, language_name, measured, unmeasured
from risk_tools import git, missing, run, tail, unpack

ROAVE = 'roave-backward-compatibility-check'
ROAVE_BC_BREAK = 3
BREAKAGE = re.compile(r'^\S+:\d+: .+$', re.MULTILINE)


def apidiff_export(cwd, modpath, out, side, moddir):
    """None on success, else the unmeasured part saying why."""
    done = run(['apidiff', '-m', '-w', out, modpath], cwd=cwd)
    if done.returncode == 0:
        return None
    return unmeasured(f'apidiff could not read module {moddir} at the {side} revision: '
                      f'{tail(done.stderr)}')


def apidiff_compare(old, new, moddir):
    done = run(['apidiff', '-m', '-incompatible', old, new])
    if done.returncode != 0:
        return unmeasured(f'apidiff -incompatible exited {done.returncode} on module {moddir}: '
                          f'{tail(done.stderr)}')
    if done.stdout.strip():
        return measured(True, f'apidiff -incompatible: {tail(done.stdout)}')
    return measured(False, f'apidiff -incompatible: no incompatible change in module {moddir}')


def apidiff_between(base_dir, head_dir, modpath, moddir, tmp):
    out = tempfile.mkdtemp(dir=tmp)
    old, new = os.path.join(out, 'base.api'), os.path.join(out, 'head.api')
    failed = (apidiff_export(base_dir, modpath, old, 'base', moddir)
              or apidiff_export(head_dir, modpath, new, 'head', moddir))
    return failed or apidiff_compare(old, new, moddir)


def go_module_part(repo, base, head_root, moddir, tmp):
    base_root = unpack(repo, base, tmp, () if moddir == '.' else (moddir,))
    base_dir, head_dir = os.path.join(base_root, moddir), os.path.join(head_root, moddir)
    if not os.path.isfile(os.path.join(base_dir, 'go.mod')):
        return measured(False, f'module {moddir} is new in this range: no earlier API to break')
    modpath = go_modules.modpath(head_root, moddir)
    if not modpath:
        return unmeasured(f'go.mod of module {moddir} names no module path')
    return apidiff_between(base_dir, head_dir, modpath, moddir, tmp)


def go_part(repo, base, head, paths, tmp):
    gap = missing('apidiff')
    if gap:
        return unmeasured(gap)
    head_root = unpack(repo, head, tmp)
    moddirs = sorted({go_modules.owning_module(p, set(), head_root) for p in paths})
    return combine_any([go_module_part(repo, base, head_root, m, tmp) for m in moddirs],
                       'no Go module changed')


def tree_files(repo, rev):
    done = git(repo, 'ls-tree', '-r', '--name-only', '-z', rev)
    return set(done.stdout.decode(errors='replace').split('\0')) - {''}


def package_target(path, files):
    """The (search path, package) griffe loads for a changed Python file: the
    topmost directory above it that is still a package, else the module itself."""
    top, directory = None, dirname(path)
    while directory and f'{directory}/__init__.py' in files:
        top, directory = directory, dirname(directory)
    if top:
        return (dirname(top) or '.', basename(top))
    return (dirname(path) or '.', splitext(basename(path))[0])


def exists_in(search, package, files):
    stem = package if search == '.' else f'{search}/{package}'
    return f'{stem}.py' in files or any(f.startswith(f'{stem}/') for f in files)


def griffe_verdict(done, package):
    # griffe prints each breakage on stderr and exits 1, and a crash exits 1 too:
    # only a line shaped like a breakage counts as one.
    text = done.stderr + done.stdout
    breakages = BREAKAGE.findall(text)
    if done.returncode == 0:
        return measured(False, f'griffe check: no breakage in {package}')
    if done.returncode == 1 and breakages:
        return measured(True, 'griffe check: ' + '; '.join(breakages))
    return unmeasured(f'griffe check exited {done.returncode} on {package}: {tail(text)}')


def griffe_part(repo, base, head, target, base_files, head_files):
    search, package = target
    if not exists_in(search, package, base_files):
        return measured(False, f'{package} is new in this range: no earlier API to break')
    if not exists_in(search, package, head_files):
        return unmeasured(f'{package} no longer exists at the head revision, which griffe '
                          f'cannot load')
    done = run(['griffe', 'check', '-a', base, '-b', head, '-s', search, package], cwd=repo)
    return griffe_verdict(done, package)


def python_part(repo, base, head, paths, tmp):
    gap = missing('griffe')
    if gap:
        return unmeasured(gap)
    base_files, head_files = tree_files(repo, base), tree_files(repo, head)
    targets = sorted({package_target(p, head_files if p in head_files else base_files)
                      for p in paths})
    return combine_any([griffe_part(repo, base, head, t, base_files, head_files)
                        for t in targets], 'no Python package changed')


def php_part(repo, base, head, paths, tmp):
    gap = missing(ROAVE)
    if gap:
        return unmeasured(gap)
    done = run([ROAVE, f'--from={base}', f'--to={head}'], cwd=repo)
    text = done.stdout + done.stderr
    if done.returncode == ROAVE_BC_BREAK:
        return measured(True, f'{ROAVE}: {tail(text)}')
    if done.returncode == 0:
        return measured(False, f'{ROAVE}: no BC break')
    return unmeasured(f'{ROAVE} exited {done.returncode}: {tail(text)}')


HANDLERS = {'go': go_part, 'python': python_part, 'php': php_part}


def language_part(lang, repo, base, head, paths, tmp):
    handler = HANDLERS.get(lang)
    if handler is None:
        return unmeasured(f'no API compatibility tool supports {language_name(lang)} files '
                          f'(e.g. {paths[0]})')
    return handler(repo, base, head, paths, tmp)


def api_signal(repo, base, head, groups):
    """`groups` is risk_core.by_language over the changed paths."""
    with tempfile.TemporaryDirectory() as tmp:
        parts = [language_part(lang, repo, base, head, paths, tmp)
                 for lang, paths in sorted(groups.items())]
    return combine_any(parts, 'no source files changed')
