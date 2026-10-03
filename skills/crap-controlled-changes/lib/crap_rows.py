#!/usr/bin/env python3
"""Keeps the per-function figures a green CRAP gate computed, keyed by tree SHA.

    <report rows on stdin> | crap_rows.py record <store.json> --tree <tree-sha>

The gate prints a complexity, a coverage and a CRAP score for every changed
function, then keeps only the failing ones. A function that passed left no
trace, so nothing could say how complex or how untested the code a branch
changed had been. This keeps the whole report, keyed by the tree of the commit
the gate let through, so the figures can be read back for any commit in a range.

An empty report (a commit with no scorable source) is recorded too, since "the
gate ran and found nothing" differs from "the gate never ran on this tree", but
it never replaces rows already recorded for the same tree.
"""

import argparse
import sys

import scored_ledger
from next_action import ROW


def number(text):
    try:
        return float(text)
    except ValueError:
        return None


def parse_rows(lines):
    rows = []
    for line in lines:
        m = ROW.match(line)
        if m:
            rows.append({'id': m['id'], 'cc': number(m['cc']), 'cov': number(m['cov']),
                         'crap': number(m['crap']), 'status': m['status'], 'tag': m['tag']})
    return rows


def record(store_path, tree, rows):
    with scored_ledger.locked(store_path):
        store = scored_ledger.load(store_path)
        if rows or tree not in store:
            store[tree] = rows
            scored_ledger.save(store_path, store)


def rows_for_tree(store_path, tree):
    """The rows recorded for `tree`, or None when nothing was recorded."""
    return scored_ledger.load(store_path).get(tree)


def main(argv):
    parser = argparse.ArgumentParser(prog='crap_rows.py')
    parser.add_argument('command', choices=['record'])
    parser.add_argument('store')
    parser.add_argument('--tree', required=True)
    args = parser.parse_args(argv)
    record(args.store, args.tree, parse_rows(sys.stdin))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
