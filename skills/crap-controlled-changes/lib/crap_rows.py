#!/usr/bin/env python3
"""The CRAP rows of this branch's green gate runs, kept for later reading.

    crap_rows.py record <rows.json> <branch> <repo>        (gate output on stdin)

A green run prints one row per measured function. next_action.py consumes them
and nothing keeps them, so the numbers a change was held to were gone the moment
the commit landed. This keeps the latest row of every function, per branch.

A function's tag is relative to the commit before it, so a function this branch
added reads `unchanged` on the next commit that touches it. The stronger tag
stays (new over worsened over unchanged), with the latest numbers, so the record
still answers what the branch added or made worse.

The file lives in the common git dir and outlives a branch, and the pipeline cuts
a redone ticket's branch again under the same name. A row therefore counts only
while the commit that carried it is in history. The gate scores the index before
that commit exists, so a row names the HEAD it ran against and the tree it
scored; the commit is the one after that HEAD in the history asked about, with
that tree. A commit rewritten into a different tree (amend, rebase) ends the claim
of its rows.
"""

import argparse
import subprocess
import sys

import next_action
import scored_ledger

STRENGTH = {'unchanged': 0, 'worsened': 1, 'new': 2}


def parse(text):
    """{function id: row} for every gate row in `text`; anything else is skipped."""
    rows = {}
    for line in text.splitlines():
        m = next_action.ROW.match(line)
        if m:
            rows[m['id']] = {'complexity': m['cc'], 'coverage': m['cov'], 'crap': m['crap'],
                             'status': m['status'], 'tag': m['tag']}
    return rows


def merge(stored, rows):
    """`stored` with each of `rows` laid over it, keeping the stronger tag."""
    merged = dict(stored)
    for fid, row in rows.items():
        was = stored.get(fid, {}).get('tag', 'unchanged')
        merged[fid] = {**row, 'tag': max(was, row['tag'], key=STRENGTH.get)}
    return merged


def git(repo, *args):
    done = subprocess.run(['git', '-C', repo, *args], capture_output=True, text=True, check=True)
    return done.stdout.strip()


def trees_after(repo, head, since):
    """The trees of the commits in the history of `head` that are not in the history of `since`."""
    done = subprocess.run(['git', '-C', repo, 'log', '--format=%T', head, '--not', since],
                          capture_output=True, text=True)
    return set(done.stdout.split()) if done.returncode == 0 else set()


def landed(repo, rows, head):
    """The `rows` whose commit is in the history of `head`."""
    trees = {}
    kept = {}
    for fid, row in rows.items():
        since = row.get('head', '')
        if since not in trees:
            trees[since] = trees_after(repo, head, since)
        if row.get('tree') in trees[since]:
            kept[fid] = row
    return kept


def record(path, branch, text, repo):
    head, tree = git(repo, 'rev-parse', 'HEAD'), git(repo, 'write-tree')
    fresh = {fid: {**row, 'head': head, 'tree': tree} for fid, row in parse(text).items()}
    with scored_ledger.locked(path):
        store = scored_ledger.load(path)
        store[branch] = merge(landed(repo, store.get(branch, {}), head), fresh)
        scored_ledger.save(path, store)


def latest(path, branch, repo, head):
    return landed(repo, scored_ledger.load(path).get(branch, {}), head)


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument('command', choices=['record'])
    parser.add_argument('rows_file')
    parser.add_argument('branch')
    parser.add_argument('repo')
    args = parser.parse_args(argv)
    record(args.rows_file, args.branch, sys.stdin.read(), args.repo)
    return 0


if __name__ == '__main__':
    sys.exit(main())
