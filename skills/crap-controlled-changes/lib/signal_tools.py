"""The change-risk signals that need a tool run over the change: api_broken,
security_pattern, semantic_noop and reachable.

Three rules hold for all of them. A signal is false only when every tool that
applies ran to the end over every changed file of its language; a tool that is
missing, errors or runs past its limit makes it unmeasured, never false. A
non-zero exit is a finding only when the output holds the tool's own finding
record, since the same exit code also means the tool broke. And a proof stands
whatever else could not be checked: one language showing a break is true even if
another language's tool was missing.

The tools that read the working tree run at HEAD, so they only count when HEAD
is the range's head.
"""

import json
import os
import re
import shutil
import subprocess
import tempfile
from pathlib import PurePosixPath

import go_modules
from signal_base import (UNMEASURED, git, is_test_file, lang_of, of_run, run_tool, signal,
                         unmeasured, why)

LIB_DIR = os.path.dirname(os.path.abspath(__file__))
PHP_RULES = os.path.join(LIB_DIR, 'opengrep-php.yml')
PHP_BC = 'roave-backward-compatibility-check'
# assert_used fires on every assert, so any change that adds a test would read as a security finding.
BANDIT_SKIPPED = 'B101'
HEAD_MOVED = ('HEAD is not the range head, so a tool run over the working tree '
              'would measure other code')
GRIFFE_RECORD = re.compile(r'^\S[^:\n]*:\d+: [^:\n]+: \S')
GO_LIST_BUILT = ''.join('{{range .%s}}{{$.Dir}}/{{.}}{{"\\n"}}{{end}}' % field
                        for field in ('GoFiles', 'CgoFiles', 'TestGoFiles', 'XTestGoFiles'))


def of_value(parts, wanted):
    return [part for part in parts if part['value'] == wanted]


def reasons(parts):
    return '; '.join(dict.fromkeys(part['reason'] for part in parts))


def combine(parts, proof=True):
    """The first part showing `proof`; else unmeasured, giving every reason; else the first."""
    proved, unknown = of_value(parts, proof), of_value(parts, UNMEASURED)
    if proved:
        return proved[0]
    if unknown:
        return {**unknown[0], 'reason': reasons(unknown)}
    return parts[0]


def language_parts(ctx, handlers):
    parts = []
    for lang, handler in handlers.items():
        files = [path for path in ctx.gated if lang_of(path) == lang]
        if files:
            parts.extend(handler(ctx, files))
    return parts


def semantic(ctx, handlers):
    """Run each language's handler over its changed files and combine what they say."""
    if not ctx.at_head:
        return unmeasured(HEAD_MOVED)
    parts = language_parts(ctx, handlers)
    if ctx.unsupported:
        parts.append(unmeasured('changed file(s) in a language no tool here covers: '
                                + ', '.join(ctx.unsupported)))
    return combine(parts) if parts else unmeasured('no Go, PHP or Python file changed')


def failed(run):
    return bool(run.problem) or run.code != 0


def judged(run, records):
    """A tool's verdict: its findings if it printed any, unmeasured if it did not finish."""
    if records:
        return of_run(True, run, output='\n'.join(records))
    if failed(run):
        return of_run(UNMEASURED, run, reason=why(run))
    return of_run(False, run)


def report_lines(text):
    return [line for line in text.splitlines() if line.strip()]


def sources(files):
    return [path for path in files if not is_test_file(path)]


def only_tests(language):
    return [signal(False, output=f'only test files changed in {language}')]


def module_files(ctx, files):
    """{module directory: the `files` it owns}"""
    moddirs = go_modules.module_dirs(ctx.repo)
    groups = {}
    for path in files:
        groups.setdefault(go_modules.owning_module(path, moddirs, ctx.repo), []).append(path)
    return groups


def go_modules_of(ctx, files):
    return set(module_files(ctx, files))


def at_base(ctx, path):
    done = subprocess.run(['git', '-C', ctx.repo, 'cat-file', '-e', f'{ctx.base}:{path}'],
                          capture_output=True)
    return done.returncode == 0


def unpack_base(ctx, dest):
    archive = subprocess.run(['git', '-C', ctx.repo, 'archive', '--format=tar', ctx.base],
                             capture_output=True, check=True)
    os.makedirs(dest)
    subprocess.run(['tar', '-x', '-C', dest], input=archive.stdout, capture_output=True, check=True)


def go_module_api(ctx, tmp, mod):
    if not os.path.isfile(os.path.join(ctx.repo, mod, 'go.mod')):
        return unmeasured(f'no go.mod owns the changed Go file(s) in {mod}')
    old = os.path.join(tmp, 'base', mod)
    if not os.path.isfile(os.path.join(old, 'go.mod')):
        return signal(False, output=f'{mod} is a new module in this range')
    modpath = go_modules.modpath(ctx.repo, mod)
    export = os.path.join(tmp, 'api.export')
    wrote = run_tool(['apidiff', '-m', '-w', export, modpath], cwd=old)
    if failed(wrote):
        return of_run(UNMEASURED, wrote, reason=f'apidiff could not read the base API: {why(wrote)}')
    diffed = run_tool(['apidiff', '-m', '-incompatible', export, modpath], cwd=os.path.join(ctx.repo, mod))
    return judged(diffed, report_lines(diffed.out))


def go_api(ctx, files):
    modules = sorted(go_modules_of(ctx, files))
    with tempfile.TemporaryDirectory() as tmp:
        unpack_base(ctx, os.path.join(tmp, 'base'))
        return [go_module_api(ctx, tmp, mod) for mod in modules]


def top_package(repo, path):
    """(directory, its parent) of the outermost package holding `path`, or None."""
    here, chain = PurePosixPath(path).parent, []
    while str(here) != '.' and os.path.isfile(os.path.join(repo, str(here), '__init__.py')):
        chain.append(here)
        here = here.parent
    return (str(chain[-1]), str(chain[-1].parent)) if chain else None


def griffe_part(ctx, pkgdir, search):
    if not at_base(ctx, f'{pkgdir}/__init__.py'):
        return signal(False, output=f'{pkgdir} is a new package in this range')
    run = run_tool(['griffe', 'check', PurePosixPath(pkgdir).name, '-s', search, '-a', ctx.base,
                    '--no-color'], cwd=ctx.repo)
    return judged(run, [line for line in (run.out + run.err).splitlines() if GRIFFE_RECORD.match(line)])


def packages_of(repo, changed):
    """The (directory, search path) of each package holding `changed`, and the files in none."""
    tops = {path: top_package(repo, path) for path in changed}
    packages = sorted({top for top in tops.values() if top})
    loose = sorted(path for path, top in tops.items() if top is None)
    return packages, loose


def python_api(ctx, files):
    changed = sources(files)
    if not changed:
        return only_tests('Python')
    packages, loose = packages_of(ctx.repo, changed)
    parts = [griffe_part(ctx, *top) for top in packages]
    if loose:
        parts.append(unmeasured('Python file(s) outside any package: ' + ', '.join(loose)))
    return parts


def php_tool(repo):
    local = os.path.join(repo, 'vendor', 'bin', PHP_BC)
    return shutil.which(PHP_BC) or (local if os.access(local, os.X_OK) else PHP_BC)


def php_api(ctx, files):
    if not sources(files):
        return only_tests('PHP')
    run = run_tool([php_tool(ctx.repo), f'--from={ctx.base}'], cwd=ctx.repo)
    return [judged(run, [line for line in (run.out + run.err).splitlines()
                         if line.lstrip().startswith('[BC]')])]


def api_broken(ctx):
    return semantic(ctx, {'go': go_api, 'python': python_api, 'php': php_api})


def parse_json(text):
    try:
        data = json.loads(text)
    except ValueError:
        return None
    return data if isinstance(data, dict) else None


def repo_path(ctx, path):
    """`path` as the repo-relative name the diff uses, whatever way the tool wrote it."""
    if not os.path.isabs(path):
        return os.path.normpath(path)
    return os.path.relpath(os.path.realpath(path), os.path.realpath(ctx.repo))


def span(text):
    first, _, last = str(text).partition('-')
    return range(int(first), int(last or first) + 1)


def skipped(errors):
    return json.dumps(errors, sort_keys=True)[:200] if errors else ''


def scan_part(ctx, run, extract):
    """A scanner's verdict over the added lines: findings on them, or what it skipped."""
    data = parse_json(run.out)
    if data is None:
        return of_run(UNMEASURED, run, reason=why(run))
    found, left_out = extract(ctx, data)
    hits = [f'{path}:{min(lines)} {rule}' for path, lines, rule in found
            if ctx.added.get(path, set()).intersection(lines)]
    if hits:
        return of_run(True, run, output='\n'.join(hits))
    if left_out:
        return of_run(UNMEASURED, run, reason=f'the scan skipped input: {left_out}')
    return of_run(False, run, output=f'{len(found)} finding(s) in scanned files, none on added lines')


def gosec_findings(ctx, data):
    found = [(repo_path(ctx, issue['file']), span(issue['line']), issue['rule_id'])
             for issue in data.get('Issues') or []]
    return found, skipped(data.get('Golang errors'))


def bandit_findings(ctx, data):
    found = [(repo_path(ctx, result['filename']), result['line_range'], result['test_id'])
             for result in data.get('results') or []]
    return found, skipped(data.get('errors'))


def opengrep_findings(ctx, data):
    # opengrep prefixes each rule id with the dotted path of the rules file's directory.
    found = [(repo_path(ctx, result['path']),
              range(result['start']['line'], result['end']['line'] + 1),
              result['check_id'].rsplit('.', 1)[-1])
             for result in data.get('results') or []]
    return found, skipped(data.get('errors'))


def existing(ctx, files):
    return [path for path in files if ctx.status.get(path) != 'D']


def unbuilt(ctx, changed, run):
    """The `changed` files that a `go list` run does not list as built."""
    built = {repo_path(ctx, line) for line in report_lines(run.out)}
    return [path for path in changed if path not in built]


def left_out(ctx, mod, files):
    """The part for changed files gosec never loaded. It scans the packages `go list ./...`
    finds for this host and does not say which file it dropped."""
    changed = existing(ctx, files)
    if not changed:
        return []
    run = run_tool(['go', 'list', '-e', '-f', GO_LIST_BUILT, './...'], cwd=os.path.join(ctx.repo, mod))
    if failed(run):
        return [of_run(UNMEASURED, run, reason=f'could not list the Go files the build holds: {why(run)}')]
    missing = unbuilt(ctx, changed, run)
    if not missing:
        return []
    return [of_run(UNMEASURED, run, reason='changed Go file(s) gosec could not load, because the build here '
                   'leaves them out (a build constraint, or a directory ./... skips): ' + ', '.join(missing))]


def go_security(ctx, files):
    parts = []
    for mod, mod_files in sorted(module_files(ctx, files).items()):
        run = run_tool(['gosec', '-fmt=json', '-no-fail', '-tests', './...'], cwd=os.path.join(ctx.repo, mod))
        parts.append(scan_part(ctx, run, gosec_findings))
        parts.extend(left_out(ctx, mod, mod_files))
    return parts


def scannable(ctx, files):
    return sources(existing(ctx, files))


def nothing_added(language):
    return [signal(False, output=f'every changed {language} file was deleted')]


def python_security(ctx, files):
    scan = existing(ctx, files)
    if not scan:
        return nothing_added('Python')
    run = run_tool(['bandit', '-f', 'json', '-s', BANDIT_SKIPPED, *scan], cwd=ctx.repo)
    return [scan_part(ctx, run, bandit_findings)]


def php_security(ctx, files):
    scan = existing(ctx, files)
    if not scan:
        return nothing_added('PHP')
    run = run_tool(['opengrep', 'scan', '-f', PHP_RULES, '--json', *scan], cwd=ctx.repo)
    return [scan_part(ctx, run, opengrep_findings)]


def security_pattern(ctx):
    return semantic(ctx, {'go': go_security, 'python': python_security, 'php': php_security})


def blob_to(ctx, ref, path, tmp, sub):
    data = subprocess.run(['git', '-C', ctx.repo, 'cat-file', 'blob', f'{ref}:{path}'],
                          capture_output=True, check=True).stdout
    dest = os.path.join(tmp, sub, PurePosixPath(path).name)
    os.makedirs(os.path.dirname(dest))
    with open(dest, 'wb') as out:
        out.write(data)
    return dest


def noop_file(ctx, tmp, index, row):
    """One file's verdict: True when difft sees no syntactic change, False when it does."""
    added, _, path = row
    status = ctx.status.get(path)
    if status != 'M' or added is None:
        return signal(False, output=f'{path}: status {status}' + (' (binary)' if added is None else ''))
    run = run_tool(['difft', '--check-only', '--exit-code', blob_to(ctx, ctx.base, path, tmp, f'{index}/a'),
                    blob_to(ctx, ctx.head, path, tmp, f'{index}/b')], cwd=tmp)
    value = {0: True, 1: False}.get(run.code, UNMEASURED)
    return of_run(value, run, reason=why(run) if value == UNMEASURED else '',
                  output=f'{path}: no syntactic change' if value is True else None)


def semantic_noop(ctx):
    if not ctx.rows:
        return unmeasured('no changed file')
    with tempfile.TemporaryDirectory() as tmp:
        verdicts = [noop_file(ctx, tmp, i, row) for i, row in enumerate(ctx.rows)]
    return combine(verdicts, proof=False)


def func_end(lines, number):
    """The line the function opened on line `number` ends on."""
    if lines[number - 1].rstrip().endswith('}'):
        return number
    return next((n for n in range(number + 1, len(lines) + 1) if lines[n - 1] == '}'), len(lines))


def func_spans(text):
    """(first, last) line of each top-level function, reading gofmt's layout: a function
    opens on a line starting `func` and ends at the next `}` in column zero."""
    lines = text.splitlines()
    return [(number, func_end(lines, number)) for number, line in enumerate(lines, 1)
            if line.startswith('func ')]


def changed_functions(ctx, files):
    """(path, first line) of every function in `files` that holds a line the range added."""
    found = []
    for path in files:
        added = ctx.added.get(path, set())
        found += [(path, first) for first, last in func_spans(git(ctx.repo, 'show', f'{ctx.head}:{path}'))
                  if not added.isdisjoint(range(first, last + 1))]
    return found


def dead_set(ctx, root, text):
    """(path, line) of every function a deadcode run from `root` lists as unreachable."""
    return {(repo_path(ctx, os.path.join(root, func['Position']['File'])), func['Position']['Line'])
            for package in json.loads(text) or [] for func in package['Funcs']}


def deadcode_run(ctx, modpath, root):
    return run_tool(['go', 'run', f'golang.org/x/tools/cmd/deadcode@{ctx.settings.deadcode_version}',
                     '-json', '-filter=^' + modpath.replace('.', '\\.'), './...'],
                    cwd=os.path.join(ctx.repo, root))


def is_live(func, dead_sets):
    return any(func not in dead for dead in dead_sets)


def reach_verdict(funcs, dead_sets, last):
    live = [func for func in funcs if is_live(func, dead_sets)]
    shown, word = (live, 'reachable') if live else (funcs, 'unreachable')
    return of_run(bool(live), last, output='\n'.join(f'{path}:{line} {word}' for path, line in shown))


def reach_part(ctx, mod, funcs):
    modpath = go_modules.modpath(ctx.repo, mod)
    dead_sets, last = [], None
    for root in sorted(go_modules.roots(ctx.repo, mod)):
        run = deadcode_run(ctx, modpath, root)
        if 'no main packages' in run.err:
            continue
        if failed(run):
            return of_run(UNMEASURED, run, reason=why(run))
        dead_sets.append(dead_set(ctx, root, run.out))
        last = run
    if not dead_sets:
        return unmeasured(f'no main package reaches module {mod}')
    return reach_verdict(funcs, dead_sets, last)


def go_sources(ctx):
    return scannable(ctx, [path for path in ctx.gated if lang_of(path) == 'go'])


def by_module(ctx, funcs):
    moddirs = go_modules.module_dirs(ctx.repo)
    groups = {}
    for path, first in funcs:
        groups.setdefault(go_modules.owning_module(path, moddirs, ctx.repo), []).append((path, first))
    return groups


def beyond_go(ctx):
    """The changed source files deadcode cannot read: Python, PHP, or a language no tool covers."""
    others = [path for path in ctx.gated if lang_of(path) in ('python', 'php')]
    return sorted(set(scannable(ctx, [*others, *ctx.unsupported])))


def reachable(ctx):
    if not ctx.at_head:
        return unmeasured(HEAD_MOVED)
    groups = by_module(ctx, changed_functions(ctx, go_sources(ctx)))
    parts = [reach_part(ctx, mod, funcs) for mod, funcs in sorted(groups.items())]
    parts = parts or [unmeasured('no changed Go function in a non-test file')]
    unread = beyond_go(ctx)
    if unread:
        parts.append(unmeasured('deadcode reads Go only, so these changed file(s) were not measured: '
                                + ', '.join(unread)))
    return combine(parts)


SIGNALS = {
    'api_broken': api_broken,
    'security_pattern': security_pattern,
    'semantic_noop': semantic_noop,
    'reachable': reachable,
}
