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
from fnmatch import fnmatchcase
from posixpath import basename, dirname

from risk_core import measured, unmeasured
from risk_tools import cat_file, git

BEGIN = 'TOUCHSTONE_RISK_SIGNALS'
END = 'TOUCHSTONE_RISK_SIGNALS_END'

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


def git_signals(repo, base, head):
    range_ = f'{base}..{head}'
    rows = numstat_rows(repo, range_)
    return {
        'la': la_signal(rows, range_),
        'ld': ld_signal(rows, range_),
        'la_per_lt': la_per_lt_signal(repo, base, rows),
        'files': files_signal(rows, range_),
        'directories': directories_signal(rows),
        'dependency_surface': dependency_signal(rows),
    }
