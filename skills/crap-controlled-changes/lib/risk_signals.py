#!/usr/bin/env python3
"""Deterministic change-risk signals for a commit range.

    risk_signals.py <repo-root> <base>..<head>

Prints exactly three lines and exits 0:

    TOUCHSTONE_RISK_SIGNALS <range>
    {"signals": {<key>: <entry>, ...}}
    TOUCHSTONE_RISK_SIGNALS_END

Every key in KEYS is always present. An entry is `{"value": true|false|<number>,
"evidence": "<what produced it>"}` or `{"value": "unmeasured", "reason": "<why>"}`.
A signal that could not be measured is never reported as false: a missing tool or
a language no tool supports says `unmeasured` and names the cause. Each evidence
or reason string is cut to LIMIT characters, which keeps the block small enough
for a model to relay verbatim.

Exit 2, with no markers on stdout, for a bad argument, a path that is not a
repository, or a range that does not resolve.

The signals are measurements only. No path convention feeds any of them; the
package-manager file names are the one exception, because the package managers
fix those names, not the team.
"""

import json
import re
import sys
from fnmatch import fnmatchcase
from functools import partial
from posixpath import basename, dirname

from risk_api import api_signal
from risk_core import added_lines, by_language, measured, unmeasured
from risk_history import crap_signals, prior_defect_signal
from risk_noop import name_status, semantic_noop_signal
from risk_reach import reach_signal
from risk_security import security_signal
from risk_tools import cat_file, git

BEGIN = 'TOUCHSTONE_RISK_SIGNALS'
END = 'TOUCHSTONE_RISK_SIGNALS_END'
KEYS = ('la', 'ld', 'la_per_lt', 'files', 'directories', 'dependency_surface', 'semantic_noop',
        'api_broken', 'security_pattern', 'crap_max', 'coverage_min', 'entry_reachable',
        'prior_defect_files')
RANGE = re.compile(r'((?!-)\S+?)\.\.((?!-)\S+)')

DEPENDENCY_FILES = {'go.mod', 'go.sum', 'composer.json', 'composer.lock', 'pyproject.toml',
                    'uv.lock'}


def parse_numstat(raw):
    """Rows of `git diff --numstat -z`; a binary file's `-` counts are read as 0."""
    rows = []
    for record in raw.split('\0'):
        if not record:
            continue
        added, removed, path = record.split('\t', 2)
        binary = added == '-'
        rows.append({'added': 0 if binary else int(added),
                     'removed': 0 if binary else int(removed),
                     'path': path, 'binary': binary})
    return rows


def render_block(range_, signals):
    body = json.dumps({'signals': signals}, separators=(',', ':'))
    return f'{BEGIN} {range_}\n{body}\n{END}\n'


def numstat_rows(repo, range_):
    done = git(repo, 'diff', '--numstat', '-z', '--no-renames', range_)
    return parse_numstat(done.stdout.decode('utf-8', 'replace'))


def text_line_count(repo, rev, path):
    data = cat_file(repo, rev, path)
    if data is None:
        return None
    return data.count(b'\n') + (1 if data and not data.endswith(b'\n') else 0)


def _total_signal(rows, range_, field, noun):
    total = sum(r[field] for r in rows)
    return measured(total, f'{total} {noun} line(s) over {len(rows)} changed path(s) in git '
                           f'diff --numstat --no-renames {range_}; a binary file counts 0')


def la_signal(rows, range_):
    return _total_signal(rows, range_, 'added', 'added')


def ld_signal(rows, range_):
    return _total_signal(rows, range_, 'removed', 'removed')


def files_signal(rows, range_):
    return measured(len(rows), f'{len(rows)} changed path(s) in git diff --numstat '
                               f'--no-renames {range_}')


def directories_signal(rows):
    dirs = sorted({dirname(r['path']) or '.' for r in rows})
    return measured(len(dirs), f"{len(dirs)} distinct director(ies) hold the changed paths: "
                               f"{', '.join(dirs)}")


def is_dependency_file(path):
    name = basename(path)
    return name in DEPENDENCY_FILES or fnmatchcase(name, 'requirements*.txt')


def dependency_signal(rows):
    hits = [r['path'] for r in rows if is_dependency_file(r['path'])]
    if hits:
        return measured(True, 'package-manager manifest or lockfile changed: ' + ', '.join(hits))
    return measured(False, 'no package-manager manifest or lockfile changed')


def base_text_lines(repo, base, rows):
    """Base-revision line counts of the text files a range modifies or deletes;
    a new file has no base revision and is left out."""
    counts = (text_line_count(repo, base, r['path']) for r in rows if not r['binary'])
    return [n for n in counts if n is not None]


def la_per_lt_signal(repo, base, rows):
    """LA over text files, divided by LT: the lines those base files held."""
    known = base_text_lines(repo, base, rows)
    la, lt = sum(r['added'] for r in rows if not r['binary']), sum(known)
    if not lt:
        return unmeasured('LT is 0: every touched file is new (LT counts the base-revision '
                          'lines of the text files the range modifies or deletes)')
    return measured(la / lt, f'LA {la} added line(s) in text files / LT {lt} line(s) at the '
                             f'base revision of {len(known)} modified or deleted text file(s)')


def git_signals(repo, base, range_, rows):
    return {
        'la': la_signal(rows, range_),
        'ld': ld_signal(rows, range_),
        'la_per_lt': la_per_lt_signal(repo, base, rows),
        'files': files_signal(rows, range_),
        'directories': directories_signal(rows),
        'dependency_surface': dependency_signal(rows),
    }


def diff_of(repo, range_):
    done = git(repo, 'diff', '-U0', '--no-color', '--no-renames', range_)
    return done.stdout.decode('utf-8', 'replace')


def noop_probe(repo, base, head, range_):
    return semantic_noop_signal(repo, base, head, name_status(repo, range_))


def guarded(name, probe):
    """One probe's entry; a probe that raises is unmeasured, never a missing key."""
    try:
        return probe()
    except Exception as exc:
        return unmeasured(f'{name} failed: {exc!r}')


def crap_pair(repo, range_):
    try:
        return crap_signals(repo, range_)
    except Exception as exc:
        failed = unmeasured(f'crap_max failed: {exc!r}')
        return failed, failed


def collect(repo, base, head):
    range_ = f'{base}..{head}'
    rows = numstat_rows(repo, range_)
    paths = [r['path'] for r in rows]
    groups, added = by_language(paths), added_lines(diff_of(repo, range_))
    signals = git_signals(repo, base, range_, rows)
    signals['semantic_noop'] = guarded(
        'semantic_noop', partial(noop_probe, repo, base, head, range_))
    signals['api_broken'] = guarded('api_broken', partial(api_signal, repo, base, head, groups))
    signals['security_pattern'] = guarded(
        'security_pattern', partial(security_signal, repo, head, groups, added))
    signals['crap_max'], signals['coverage_min'] = crap_pair(repo, range_)
    signals['entry_reachable'] = guarded(
        'entry_reachable', partial(reach_signal, repo, head, groups, added))
    signals['prior_defect_files'] = guarded(
        'prior_defect_files', partial(prior_defect_signal, repo, paths))
    return signals


def parse_range(text):
    m = RANGE.fullmatch(text)
    return None if not m or '...' in text else m.groups()


def check_range(repo, base, head):
    for ref in (base, head):
        done = git(repo, 'rev-parse', '--verify', '--quiet', f'{ref}^{{commit}}')
        if done.returncode != 0:
            raise ValueError(f'{ref} does not resolve to a commit')


def fail(message):
    print(f'risk-signals: {message}', file=sys.stderr)
    return 2


def main(argv):
    if len(argv) != 2:
        return fail('usage: risk_signals.py <repo-root> <base>..<head>')
    repo, range_ = argv
    parsed = parse_range(range_)
    if parsed is None:
        return fail(f'{range_!r} is not <base>..<head>')
    try:
        check_range(repo, *parsed)
    except ValueError as exc:
        return fail(str(exc))
    sys.stdout.write(render_block(range_, collect(repo, *parsed)))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
