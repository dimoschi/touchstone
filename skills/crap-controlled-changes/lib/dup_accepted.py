#!/usr/bin/env python3
"""Per-branch store of user-accepted duplicate pairs for dup-check.

Usage:
  dup_accepted.py add <store.json> <branch> <key>
  dup_accepted.py remove <store.json> <branch> <key>
  dup_accepted.py report <store.json> <branch>
      (dup_scan.py's DUPLICATE lines on stdin)

`report` splits the duplicates into accepted and unaccepted, prints one line per
finding, and exits 1 if any are unaccepted.

A key is "<side>|<side>", the two sides sorted, exactly as dup_scan.py prints it.
A side is "<repo-relative-file>#<digest of the function's structure>", so an
acceptance follows the duplicated code and lapses as soon as either function's
shape changes, rather than silently covering whatever lands at those lines next.
"""

import argparse
import re
import sys

from deadcode_accepted import load, save

FINDING = re.compile(
    r"^DUPLICATE score=(?P<score>\S+) (?P<a>.+?:\d+-\d+) (?P<b>.+?:\d+-\d+) key=(?P<key>.+)$")


def add(store, branch, key):
    keys = store.setdefault(branch, [])
    if key not in keys:
        keys.append(key)


def remove(store, branch, key):
    keys = store.get(branch, [])
    if key not in keys:
        return False
    keys.remove(key)
    if not keys:
        store.pop(branch)
    return True


def report(store, branch, lines):
    accepted = set(store.get(branch, []))
    unaccepted = 0
    for line in lines:
        found = FINDING.match(line.strip())
        if not found:
            continue
        ok = found["key"] in accepted
        unaccepted += not ok
        verdict = "ACCEPTED" if ok else f"DUPLICATE  key={found['key']}"
        print(f"{found['a']}  {found['b']}  score={found['score']}  {verdict}")
    print(f"duplicates={unaccepted}")
    return 1 if unaccepted else 0


def edit(mode, path, branch, key):
    store = load(path)
    if mode == "add":
        add(store, branch, key)
        message = "recorded user acceptance of"
    elif not remove(store, branch, key):
        print(f"dup-check: {key} is not accepted on branch '{branch}'; nothing to revoke",
              file=sys.stderr)
        return 1
    else:
        message = "revoked acceptance of"
    save(path, store)
    print(f"dup-check: {message} {key} on branch '{branch}'; re-run dup-check.sh")
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=["add", "remove", "report"])
    parser.add_argument("store")
    parser.add_argument("branch")
    parser.add_argument("key", nargs="?")
    args = parser.parse_args(argv)
    if args.mode == "report":
        return report(load(args.store), args.branch, sys.stdin)
    if not args.key:
        parser.error(f"{args.mode} needs a key")
    return edit(args.mode, args.store, args.branch, args.key)


if __name__ == "__main__":
    sys.exit(main())
