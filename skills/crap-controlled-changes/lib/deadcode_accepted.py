#!/usr/bin/env python3
"""Per-branch store of user-accepted unreachable symbols for deadcode-check.

Usage:
  deadcode_accepted.py add <store.json> <branch> <key>
  deadcode_accepted.py report <store.json> <branch> <added-keys-file>
      (deadcode's line-oriented output on stdin)

`report` keeps only the symbols this diff added, splits them into accepted and
unaccepted, prints one line per finding, and exits 1 if any are unaccepted.

A key is "<repo-relative-file>|<symbol>". Matching on both means a symbol name
reused in two packages cannot mask a finding in the other.
"""

import json
import os
import re
import sys

FINDING = re.compile(r'^(?P<file>[^:]+):(?P<line>\d+):\d+: unreachable func: (?P<name>\S+)')


def load(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def save(path, store):
    tmp = f"{path}.tmp{os.getpid()}"
    with open(tmp, 'w') as f:
        json.dump(store, f, indent=1, sort_keys=True)
    os.replace(tmp, path)


def main():
    mode, path, branch = sys.argv[1], sys.argv[2], sys.argv[3]
    store = load(path)

    if mode == 'add':
        keys = store.setdefault(branch, [])
        if sys.argv[4] not in keys:
            keys.append(sys.argv[4])
        save(path, store)
        print(f"deadcode-check: recorded user acceptance of {sys.argv[4]} "
              f"on branch '{branch}'; re-run deadcode-check.sh")
        return 0

    if mode == 'remove':
        keys = store.get(branch, [])
        if sys.argv[4] not in keys:
            print(f"deadcode-check: {sys.argv[4]} is not accepted on branch "
                  f"'{branch}'; nothing to revoke", file=sys.stderr)
            return 1
        keys.remove(sys.argv[4])
        if not keys:
            store.pop(branch)
        save(path, store)
        print(f"deadcode-check: revoked acceptance of {sys.argv[4]} "
              f"on branch '{branch}'; re-run deadcode-check.sh")
        return 0

    with open(sys.argv[4]) as f:
        added = {line.strip() for line in f if line.strip()}
    accepted = set(store.get(branch, []))

    unaccepted, noted = [], []
    for line in sys.stdin:
        m = FINDING.match(line.strip())
        if not m:
            continue
        key = f"{m.group('file')}|{m.group('name')}"
        if key not in added:
            continue
        entry = (m.group('file'), m.group('line'), m.group('name'), key)
        (noted if key in accepted else unaccepted).append(entry)

    for f_, ln, name, key in unaccepted:
        print(f"{f_}:{ln}  {name}  UNREACHABLE  key={key}")
    for f_, ln, name, _ in noted:
        print(f"{f_}:{ln}  {name}  ACCEPTED")
    print(f"unreachable={len(unaccepted)}")
    return 1 if unaccepted else 0


if __name__ == '__main__':
    sys.exit(main())
