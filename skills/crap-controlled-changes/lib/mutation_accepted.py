#!/usr/bin/env python3
"""Per-branch store of user-accepted (equivalent) mutants for mutation-check.

Usage:
  mutation_accepted.py add <store.json> <branch> <id>
  mutation_accepted.py filter <store.json> <branch>   (survivor rows on stdin)

`filter` reads the captured module output, splits survivors into accepted and
unaccepted by their id= token, and prints:
  unaccepted=<count>
  accepted=<id>        (one line per accepted survivor present in the input)
"""

import json
import re
import sys

ID_ROW = re.compile(r' SURVIVED\s+id=(\S+)')


def load(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def main():
    mode, path, branch = sys.argv[1], sys.argv[2], sys.argv[3]
    store = load(path)

    if mode == 'add':
        ids = store.setdefault(branch, [])
        if sys.argv[4] not in ids:
            ids.append(sys.argv[4])
        with open(path, 'w') as f:
            json.dump(store, f, indent=1, sort_keys=True)
        print(f"mutation-check: recorded user acceptance of {sys.argv[4]} "
              f"on branch '{branch}'; re-run mutation-check.sh")
        return

    accepted = set(store.get(branch, []))
    unaccepted = 0
    seen_accepted = []
    for line in sys.stdin:
        m = ID_ROW.search(line)
        if not m:
            continue
        if m.group(1) in accepted:
            seen_accepted.append(m.group(1))
        else:
            unaccepted += 1
    print(f"unaccepted={unaccepted}")
    for i in seen_accepted:
        print(f"accepted={i}")


if __name__ == '__main__':
    main()
