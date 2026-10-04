#!/usr/bin/env python3
"""The CRAP rows of this branch's green gate runs, kept for later reading.

    crap_rows.py record <rows.json> <branch>        (gate output on stdin)

A green run prints one row per measured function. next_action.py consumes them
and nothing keeps them, so the numbers a change was held to were gone the moment
the commit landed. This keeps the latest row of every function, per branch.

A function's tag is relative to the commit before it, so a function this branch
added reads `unchanged` on the next commit that touches it. The stronger tag
stays (new over worsened over unchanged), with the latest numbers, so the record
still answers what the branch added or made worse.
"""

import argparse
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


def record(path, branch, text):
    store = scored_ledger.load(path)
    store[branch] = merge(store.get(branch, {}), parse(text))
    scored_ledger.save(path, store)


def latest(path, branch):
    return scored_ledger.load(path).get(branch, {})


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument('command', choices=['record'])
    parser.add_argument('rows_file')
    parser.add_argument('branch')
    args = parser.parse_args(argv)
    record(args.rows_file, args.branch, sys.stdin.read())
    return 0


if __name__ == '__main__':
    sys.exit(main())
