"""Signals that come from this repository's own history, not from the diff.

crap_max and coverage_min read the per-function figures `crap-check.sh` recorded
for each commit of the range (see crap_rows.py), keeping the functions each commit
changed (see risk_changed.py). prior_defect_files reads the
delivery run records under `.claude/touchstone-runs` for paths where an earlier
run left a defect open that its own reproducer had demonstrated. A commit the
gate never recorded, or a repository with no run records, makes the signal
unmeasured: the absence of a record is not evidence of a clean history.
"""

import json
import os
from pathlib import Path

import crap_rows
import risk_changed
from risk_core import measured, unmeasured
from risk_tools import git

RUNS_DIR = os.path.join('.claude', 'touchstone-runs')
WORKTREES = ['.claude', 'worktrees']


def common_dir(repo):
    out = git(repo, 'rev-parse', '--git-common-dir').stdout.decode().strip()
    return os.path.realpath(os.path.join(repo, out))


def commits_of(repo, range_):
    """[sha, tree] of each non-merge commit in the range: a merge authors nothing."""
    done = git(repo, 'log', '--no-merges', '--format=%H %T', range_)
    return [line.split() for line in done.stdout.decode().splitlines() if line.strip()]


def recorded_entries(repo, range_):
    """[(sha, rows or None)] for each non-merge commit in the range; None means
    the gate recorded nothing for that commit's tree."""
    store = os.path.join(common_dir(repo), 'crap-check-rows.json')
    return [(sha, crap_rows.rows_for_tree(store, tree)) for sha, tree in commits_of(repo, range_)]


def lacking_of(entries):
    return [sha for sha, rows in entries if rows is None]


def changed_rows(repo, sha, rows):
    """The rows of the functions the commit edited: the gate scores every function
    in each file it stages, so the rest describe code the commit never touched."""
    if not rows:
        return []
    ids = risk_changed.changed_ids(repo, sha)
    return [row for row in rows if row['id'] in ids]


def rows_of(repo, entries):
    return [row for sha, rows in entries for row in changed_rows(repo, sha, rows)]


def figures_problem(count, lacking, rows):
    if not count:
        return 'the range has no commits'
    if lacking:
        return (f'no per-function CRAP figures were recorded for {len(lacking)} of {count} '
                f'commit(s) in the range (e.g. {lacking[0][:8]})')
    if not rows:
        return f'no changed function was scored in any of the {count} commit(s) in the range'
    return None


def fmt(number):
    return 'n/a' if number is None else f'{number:g}'


def crap_signal(rows, count):
    scored = [r for r in rows if r['crap'] is not None]
    if not scored:
        return unmeasured('no scored function carries a CRAP score')
    worst = max(scored, key=lambda r: r['crap'])
    return measured(worst['crap'],
                    f"highest CRAP {fmt(worst['crap'])} at {worst['id']} (complexity "
                    f"{fmt(worst['cc'])}, coverage {fmt(worst['cov'])}%), over {len(rows)} "
                    f"changed function(s) in {count} commit(s)")


def coverage_signal(rows, count):
    scored = [r for r in rows if r['cov'] is not None]
    if not scored:
        return unmeasured('no scored function carries a coverage figure')
    worst = min(scored, key=lambda r: r['cov'])
    return measured(worst['cov'],
                    f"lowest coverage {fmt(worst['cov'])}% at {worst['id']} (complexity "
                    f"{fmt(worst['cc'])}, CRAP {fmt(worst['crap'])}), over {len(rows)} "
                    f"changed function(s) in {count} commit(s)")


def crap_signals(repo, range_):
    """(crap_max, coverage_min) entries for the range."""
    entries = recorded_entries(repo, range_)
    rows = rows_of(repo, entries)
    problem = figures_problem(len(entries), lacking_of(entries), rows)
    if problem:
        return unmeasured(problem), unmeasured(problem)
    return crap_signal(rows, len(entries)), coverage_signal(rows, len(entries))


def read_record(path):
    try:
        with open(path) as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


def checkout_root(repo):
    return os.path.dirname(common_dir(repo))


def run_records(repo):
    """[(file name, record)] for every readable run record of the main checkout."""
    runs = Path(checkout_root(repo)) / RUNS_DIR
    found = [(p.name, read_record(p)) for p in sorted(runs.glob('*.json'))]
    return [(name, record) for name, record in found if record is not None]


def is_reproduced(finding):
    run = finding.get('reproducer_run') if isinstance(finding, dict) else None
    return isinstance(run, dict) and run.get('outcome') == 'reproduced' \
        and isinstance(finding.get('file'), str)


def checkout_relative(path, root):
    """`path` as a repository-relative path.

    A reviewer may write a finding's file as an absolute path, under the main
    checkout or under a ticket's worktree inside it (`.claude/worktrees/<ticket>/`),
    so both prefixes are removed; an absolute path outside the checkout is left as it is.
    """
    if not os.path.isabs(path):
        return os.path.normpath(path)
    rel = os.path.relpath(os.path.realpath(path), root)
    if rel == os.pardir or rel.startswith(os.pardir + os.sep):
        return os.path.normpath(path)
    parts = rel.split(os.sep)
    return os.sep.join(parts[3:]) if parts[:2] == WORKTREES else rel


def reproduced_files(record, root):
    findings = record.get('unresolved_findings')
    if not isinstance(findings, list):
        return set()
    return {checkout_relative(f['file'], root) for f in findings if is_reproduced(f)}


def prior_defect_signal(repo, paths):
    records = run_records(repo)
    if not records:
        return unmeasured(f'no readable run record under {RUNS_DIR}')
    root = checkout_root(repo)
    changed = {os.path.normpath(p) for p in paths}
    hits = [f'{path} ({name})' for name, record in records
            for path in sorted(reproduced_files(record, root) & changed)]
    if hits:
        return measured(True, 'a reproduced defect was left open in an earlier run on a path '
                              'this range changes: ' + ', '.join(hits))
    return measured(False, f'{len(records)} run record(s) read; none left a reproduced defect '
                           f'open on a path this range changes')
