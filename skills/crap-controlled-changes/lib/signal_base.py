"""What the change-risk signals share: the shape of one signal, how a tool is run,
and what a commit range holds.

A signal is {"value", "evidence", "reason"?}. The value is true, false, a number,
or "unmeasured", and an unmeasured one always says why. A signal never reports
false or zero for something it could not check.
"""

from __future__ import annotations

import re
import shlex
import subprocess
from pathlib import PurePosixPath
from typing import NamedTuple

UNMEASURED = 'unmeasured'
TOOL_TIMEOUT = 90
CUT = 400

LANGUAGES = {'.go': 'go', '.py': 'python', '.php': 'php'}
HUNK = re.compile(r'^@@ -\S+ \+(\d+)(?:,(\d+))? @@')


class SignalError(Exception):
    """The range cannot be measured at all: bad arguments or no such commit."""


def signal(value, *, reason='', command='', code=None, output=''):
    found = {'value': value,
             'evidence': {'command': command, 'exit': code, 'output': output[:CUT]}}
    if reason:
        found['reason'] = reason
    return found


def unmeasured(reason, **evidence):
    return signal(UNMEASURED, reason=reason, **evidence)


class Run(NamedTuple):
    command: str
    code: int | None
    out: str
    err: str
    problem: str


def run_tool(argv, cwd, timeout=TOOL_TIMEOUT):
    """Run a tool to the end or to its time limit; `problem` says why it did not finish."""
    command = shlex.join(argv)
    try:
        done = subprocess.run(argv, cwd=cwd, capture_output=True, errors='replace', timeout=timeout)
    except subprocess.TimeoutExpired:
        return Run(command, None, '', '', f'{argv[0]} timed out after {timeout:g} s')
    except OSError as error:
        return Run(command, None, '', '', f'could not run {argv[0]}: {error}')
    return Run(command, done.returncode, done.stdout, done.stderr, '')


def of_run(value, run, *, reason='', output=None):
    return signal(value, reason=reason, command=run.command, code=run.code,
                  output=run.out + run.err if output is None else output)


def why(run):
    """One line on why a run does not count: its problem, else its exit and first word."""
    if run.problem:
        return run.problem
    said = [line for line in (run.err + run.out).splitlines() if line.strip()]
    return f'exit {run.code}: {said[0]}' if said else f'exit {run.code}'


def lang_of(path):
    return LANGUAGES.get(PurePosixPath(path).suffix)


def is_test_file(path):
    p = PurePosixPath(path)
    return (p.name.startswith(('test_', 'conftest.'))
            or p.name.endswith(('_test.go', '_test.py', 'Test.php'))
            or bool({'tests', 'Tests'} & set(p.parts[:-1])))


def _target(header):
    """The path a diff's `+++` header names, None for a deleted file."""
    for line in header.splitlines():
        if line.startswith('+++ '):
            name = line[4:].split('\t')[0]
            if name == '/dev/null':
                return None
            return name[2:] if name.startswith('b/') else name
    return None


def _chunk_added(chunk):
    """(path, new-side line numbers) of one file's section of a -U0 diff."""
    split = chunk.find('\n@@')
    if split < 0:
        return None, set()
    lines = set()
    for line in chunk[split + 1:].splitlines():
        m = HUNK.match(line)
        if m:
            start = int(m[1])
            lines.update(range(start, start + int(m[2] if m[2] is not None else 1)))
    return _target(chunk[:split]), lines


def added_lines(diff):
    """{path: lines the diff added}, from `git diff -U0`.

    Split per file first, so an added line that reads `++ b/x` (shown as a `+++`
    line) is never taken for the next file's header.
    """
    added = {}
    for chunk in re.split(r'^diff --git ', diff, flags=re.M):
        path, lines = _chunk_added(chunk)
        if path and lines:
            added[path] = lines
    return added


class Settings(NamedTuple):
    unsupported: tuple
    exempt: tuple
    deadcode_version: str


def _lines(text):
    return tuple(line for line in text.splitlines() if line.strip())


def settings_from(env):
    version = env.get('TOUCHSTONE_DEADCODE_VERSION')
    if not version:
        raise SignalError('TOUCHSTONE_DEADCODE_VERSION is not set')
    return Settings(_lines(env.get('TOUCHSTONE_UNSUPPORTED_SPEC', '')),
                    _lines(env.get('TOUCHSTONE_EXEMPT_SPEC', '')), version)


class Ctx(NamedTuple):
    repo: str
    rng: str
    base: str
    head: str
    at_head: bool
    rows: list
    status: dict
    gated: tuple
    unsupported: tuple
    added: dict
    settings: Settings
    exempted: tuple = ()


def git(repo, *args):
    done = subprocess.run(['git', '-C', repo, '-c', 'core.quotepath=false', *args],
                          capture_output=True, errors='replace')
    if done.returncode != 0:
        raise SignalError(f'git {args[0]} failed: {done.stderr.strip()}')
    return done.stdout


def split_range(rng):
    base, *rest = rng.split('..')
    if len(rest) != 1 or not base or not rest[0] or rest[0].startswith('.'):
        raise SignalError(f'range must be <base>..<head>, got {rng!r}')
    return base, rest[0]


def resolve(repo, ref):
    done = subprocess.run(['git', '-C', repo, 'rev-parse', '--verify', '--quiet', f'{ref}^{{commit}}'],
                          capture_output=True, text=True)
    if done.returncode != 0:
        raise SignalError(f'cannot resolve {ref}')
    return done.stdout.strip()


def _names(text):
    return [name for name in text.split('\0') if name]


def _numstat_rows(text):
    rows = []
    for record in _names(text):
        added, removed, path = record.split('\t', 2)
        rows.append((None if added == '-' else int(added),
                     None if removed == '-' else int(removed), path))
    return rows


def _status_of(text):
    names = _names(text)
    return dict(zip(names[1::2], names[::2]))


def _diff(repo, base, head, *flags, specs=()):
    # added_lines parses hunks and the b/ prefix, so pin everything a user's diff config
    # can rewrite: an external diff tool (difftastic), prefixes, hunk merging, textconv.
    return git(repo, 'diff', '--no-ext-diff', '--no-textconv', '--dst-prefix=b/', '--inter-hunk-context=0',
               *flags, '--no-renames', base, head, '--', *specs)


def _paths(repo, base, head, specs):
    return tuple(_names(_diff(repo, base, head, '--name-only', '-z', specs=specs)))


def tree_is_head(repo, head):
    """Whether the working tree holds `head`: HEAD is it and no tracked file is edited, staged or not.

    The tools that read the working tree report lines of the files as they are on disk, and
    those lines are matched against the ones the commit range added.
    """
    return resolve(repo, 'HEAD') == head and not git(repo, 'status', '--porcelain', '--untracked-files=no')


def exempted_sources(status, gated):
    """The changed Go, PHP and Python files the marker exempts. They are not in `gated`, so no
    tool is handed them; a deleted one has nothing left to scan."""
    kept = set(gated)
    return tuple(path for path, code in status.items() if code != 'D' and lang_of(path) and path not in kept)


def load_ctx(repo, rng, settings):
    base_ref, head_ref = split_range(rng)
    base, head = resolve(repo, base_ref), resolve(repo, head_ref)
    # Not minus the marker's exemptions: a path it exempts is out of the CRAP gate's scope,
    # and no tool here reads a language that has none, exempt or not.
    unsupported = _paths(repo, base, head, settings.unsupported) if settings.unsupported else ()
    status = _status_of(_diff(repo, base, head, '--name-status', '-z'))
    gated = _paths(repo, base, head, ['.', *settings.exempt])
    return Ctx(
        repo=repo, rng=rng, base=base, head=head,
        at_head=tree_is_head(repo, head),
        rows=_numstat_rows(_diff(repo, base, head, '--numstat', '-z')),
        status=status,
        gated=gated,
        unsupported=unsupported,
        added=added_lines(_diff(repo, base, head, '-U0', '--no-color')),
        settings=settings,
        exempted=exempted_sources(status, gated))
