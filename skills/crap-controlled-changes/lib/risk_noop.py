"""The semantic_noop signal: a range that changes comments or formatting only.

True only when every changed file was modified (not added or deleted) and
`difft --check-only --exit-code --ignore-comments` reports no syntactic change
for each. It is the one signal whose true value may lower review effort, so it
is conservative: one file that differs makes it false, and a file in a language
no tool supports, or a tool that is missing, makes it unmeasured.
"""

import os
import tempfile
from posixpath import dirname

from risk_core import (NO_SOURCE_CHANGED, combine_all, language_name, language_of, measured,
                       unmeasured)
from risk_tools import cat_file, git, missing, run, tail

DIFFT = ['difft', '--check-only', '--exit-code', '--ignore-comments']


def name_status(repo, range_):
    """path -> git's status letter (A, M, D, ...) for every changed path."""
    done = git(repo, 'diff', '--name-status', '-z', '--no-renames', range_)
    fields = done.stdout.decode(errors='replace').split('\0')
    return dict(zip(fields[1::2], fields[0::2]))


def write_revision(repo, rev, path, dest):
    os.makedirs(dirname(dest), exist_ok=True)
    with open(dest, 'wb') as out:
        out.write(cat_file(repo, rev, path) or b'')


def difft_verdict(done, path):
    if done.returncode == 0:
        return measured(True, f'difft: no syntactic change in {path}')
    if done.returncode == 1:
        return measured(False, f'difft: syntactic change in {path}')
    return unmeasured(f'difft exited {done.returncode} on {path}: {tail(done.stderr)}')


def difft_part(repo, base, head, path, tmp):
    old, new = (os.path.join(tmp, side, path) for side in ('base', 'head'))
    write_revision(repo, base, path, old)
    write_revision(repo, head, path, new)
    return difft_verdict(run([*DIFFT, old, new]), path)


def file_part(repo, base, head, path, status, tmp, gap):
    lang = language_of(path)
    if lang and lang.startswith('other:'):
        return unmeasured(f'no semantic tool supports {language_name(lang)} files (e.g. {path})')
    if status != 'M':
        return measured(False, f'{path} is not a modification (git status {status})')
    if gap:
        return unmeasured(gap)
    return difft_part(repo, base, head, path, tmp)


def semantic_noop_signal(repo, base, head, statuses):
    if not any(language_of(p) for p in statuses):
        return measured(False, NO_SOURCE_CHANGED)
    gap = missing('difft')
    with tempfile.TemporaryDirectory() as tmp:
        parts = [file_part(repo, base, head, p, statuses[p], tmp, gap) for p in sorted(statuses)]
    return combine_all(parts)
