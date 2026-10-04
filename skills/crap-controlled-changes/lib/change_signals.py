#!/usr/bin/env python3
"""Deterministic change-risk signals for one commit range.

    change_signals.py <absolute-repo-path> <base>..<head>

Prints the markers, one compact JSON line and the end marker, exactly:

    TOUCHSTONE_SIGNALS <base>..<head>
    {"range": ..., "values": {<name>: {"value", "evidence", "reason"?}}}
    TOUCHSTONE_SIGNALS_END

Every name is always present. A value is true, false, a number, or "unmeasured"
with the reason it could not be established. Nothing here judges the change: the
signals are recorded so that later work can ask which of them predicted trouble.

Exit 0 once printed, 2 for bad arguments or a range that does not resolve. The
change-signals.sh wrapper supplies the settings that live in shell:
TOUCHSTONE_UNSUPPORTED_SPEC, TOUCHSTONE_EXEMPT_SPEC and TOUCHSTONE_DEADCODE_VERSION.
"""

import fnmatch
import json
import os
import posixpath
import re
import subprocess
import sys
from pathlib import PurePosixPath

import crap_rows
import signal_tools
from signal_base import SignalError, git, load_ctx, settings_from, signal, unmeasured

NAMES = ('la', 'ld', 'lt', 'la_lt', 'files', 'directories', 'dependency_surface', 'api_broken',
         'security_pattern', 'semantic_noop', 'crap_max', 'coverage_min', 'reachable',
         'defect_files')
DEPENDENCY_FILES = {'go.mod', 'go.sum', 'composer.json', 'composer.lock', 'pyproject.toml', 'uv.lock'}
STRONG_TAGS = ('new', 'worsened')
CRAP = {'key': 'crap', 'label': 'CRAP', 'pick': max, 'what': 'CRAP score'}
COVERAGE = {'key': 'coverage', 'label': 'coverage', 'pick': min, 'what': 'coverage'}
LINE_SUFFIX = re.compile(r':\d+(?:-\d+)?$')
WORKTREE_DIR = re.compile(r'^\.claude/worktrees/[^/]+/')
USAGE = 'usage: change-signals.sh <absolute-repo-path> <base>..<head>'


def numstat_command(ctx):
    return f'git diff --numstat --no-renames {ctx.base} {ctx.head}'


def numstat_text(ctx):
    return '\n'.join(f"{'-' if a is None else a}\t{'-' if r is None else r}\t{p}" for a, r, p in ctx.rows)


def base_lines(ctx, path):
    done = subprocess.run(['git', '-C', ctx.repo, 'cat-file', 'blob', f'{ctx.base}:{path}'],
                          capture_output=True)
    if done.returncode != 0:
        return 0
    data = done.stdout
    return data.count(b'\n') + (1 if data and not data.endswith(b'\n') else 0)


def ratio_signal(added, touched):
    if not touched:
        return unmeasured('the touched files have no lines at the base, so there is no ratio')
    return signal(round(added / touched, 3), command='la / lt', code=0, output=f'{added} / {touched}')


def size_lines(ctx):
    text_rows = [row for row in ctx.rows if row[0] is not None]
    added = sum(a for a, _, _ in text_rows)
    removed = sum(r for _, r, _ in text_rows)
    touched = sum(base_lines(ctx, path) for _, _, path in text_rows)
    shown = dict(command=numstat_command(ctx), code=0, output=numstat_text(ctx))
    return {
        'la': signal(added, **shown),
        'ld': signal(removed, **shown),
        'lt': signal(touched, command=f'git cat-file blob {ctx.base}:<path> (each touched text file)',
                     code=0, output=f'{len(text_rows)} touched text file(s)'),
        'la_lt': ratio_signal(added, touched),
    }


def changed_paths(ctx):
    return [path for _, _, path in ctx.rows]


def spread(ctx):
    paths = changed_paths(ctx)
    directories = sorted({str(PurePosixPath(path).parent) for path in paths})
    command = numstat_command(ctx)
    return {
        'files': signal(len(paths), command=command, code=0, output='\n'.join(paths)),
        'directories': signal(len(directories), command=command, code=0, output='\n'.join(directories)),
    }


def is_dependency_file(path):
    name = PurePosixPath(path).name
    return name in DEPENDENCY_FILES or fnmatch.fnmatchcase(name, 'requirements*.txt')


def dependency_surface(ctx):
    touched = [path for path in changed_paths(ctx) if is_dependency_file(path)]
    return signal(bool(touched), command=numstat_command(ctx), code=0, output='\n'.join(touched))


def branch_of(repo):
    try:
        return git(repo, 'symbolic-ref', '--quiet', '--short', 'HEAD').strip()
    except SignalError:
        return 'detached'


def common_git_dir(repo):
    return os.path.join(repo, git(repo, 'rev-parse', '--git-common-dir').strip())


def worst(rows, measure, command, branch):
    """The row with the highest (or lowest) value of a measure, leaving out rows that have none."""
    numbers = []
    for fid, row in rows.items():
        try:
            numbers.append((float(row[measure['key']]), fid, row[measure['key']]))
        except ValueError:
            continue
    if not numbers:
        return unmeasured(
            f"no CRAP row tagged new or worsened with a {measure['what']} on branch {branch}",
            command=command, code=0)
    value, fid, text = measure['pick'](numbers)
    return signal(value, command=command, code=0,
                  output=f"{fid} {measure['label']}={text} ({len(numbers)} row(s))")


def crap_signals(ctx):
    path = os.path.join(common_git_dir(ctx.repo), 'crap-check-rows.json')
    branch = branch_of(ctx.repo)
    rows = {fid: row for fid, row in crap_rows.latest(path, branch).items() if row['tag'] in STRONG_TAGS}
    command = f'read {path} [{branch}]'
    return {
        'crap_max': worst(rows, CRAP, command, branch),
        'coverage_min': worst(rows, COVERAGE, command, branch),
    }


def main_checkout(repo):
    return os.path.dirname(os.path.normpath(common_git_dir(repo)))


def repo_relative(file, root):
    """`file` as the repo-relative path a diff names, whether a lens wrote it absolute,
    from inside a worktree of `root`, or with a trailing :line or :start-end."""
    name = LINE_SUFFIX.sub('', file)
    if os.path.isabs(name):
        name = os.path.relpath(name, root)
    return WORKTREE_DIR.sub('', posixpath.normpath(name))


def reproduced_file(finding, root):
    run, file = finding.get('reproducer_run'), finding.get('file')
    if isinstance(run, dict) and run.get('outcome') == 'reproduced' and isinstance(file, str):
        return repo_relative(file, root)
    return None


def findings_of(record):
    found = record.get('unresolved_findings') if isinstance(record, dict) else None
    return [f for f in found if isinstance(f, dict)] if isinstance(found, list) else []


def load_record(path):
    try:
        with open(path, encoding='utf-8') as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


def records_in(directory):
    """The run records under `directory` that parse as JSON."""
    paths = [os.path.join(directory, name) for name in sorted(os.listdir(directory))
             if name.endswith('.json')]
    return [record for record in map(load_record, paths) if record is not None]


def reproduced_in(records, root):
    return {reproduced_file(f, root) for record in records for f in findings_of(record)}


def defect_files(ctx):
    root = main_checkout(ctx.repo)
    directory = os.path.join(root, '.claude', 'touchstone-runs')
    if not os.path.isdir(directory):
        return unmeasured(f'no run records directory at {directory}')
    records = records_in(directory)
    hit = sorted(reproduced_in(records, root) & set(changed_paths(ctx)))
    return signal(len(hit), command=f'read {directory}/*.json', code=0,
                  output='\n'.join(hit) or f'no reproduced defect in a range file, in {len(records)} record(s)')


def one(name, produce):
    return (name,), lambda ctx: {name: produce(ctx)}


PRODUCERS = (
    (('la', 'ld', 'lt', 'la_lt'), size_lines),
    (('files', 'directories'), spread),
    one('dependency_surface', dependency_surface),
    one('api_broken', signal_tools.SIGNALS['api_broken']),
    one('security_pattern', signal_tools.SIGNALS['security_pattern']),
    one('semantic_noop', signal_tools.SIGNALS['semantic_noop']),
    (('crap_max', 'coverage_min'), crap_signals),
    one('reachable', signal_tools.SIGNALS['reachable']),
    one('defect_files', defect_files),
)


def guarded(names, produce, ctx):
    """What `produce` gives, or every one of `names` unmeasured if it breaks."""
    try:
        return produce(ctx)
    except Exception as error:
        return {name: unmeasured(f'{name} failed: {type(error).__name__}: {error}') for name in names}


def compute(ctx):
    values = {}
    for names, produce in PRODUCERS:
        values.update(guarded(names, produce, ctx))
    return {name: values[name] for name in NAMES}


def render(rng, values):
    body = json.dumps({'range': rng, 'values': values}, separators=(',', ':'), allow_nan=False)
    return f'TOUCHSTONE_SIGNALS {rng}\n{body}\nTOUCHSTONE_SIGNALS_END\n'


def main(argv=None, env=None):
    argv = sys.argv[1:] if argv is None else argv
    env = os.environ if env is None else env
    if len(argv) != 2:
        print(USAGE, file=sys.stderr)
        return 2
    try:
        ctx = load_ctx(argv[0], argv[1], settings_from(env))
    except SignalError as error:
        print(f'change-signals: {error}', file=sys.stderr)
        return 2
    sys.stdout.write(render(ctx.rng, compute(ctx)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
