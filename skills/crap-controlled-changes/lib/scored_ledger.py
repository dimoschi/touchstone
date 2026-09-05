#!/usr/bin/env python3
"""Record of which source content a gate has actually scored.

Usage:
  scored_ledger.py record <ledger.json> <branch> [source]
                          [--commit <sha>] [--tools <fingerprint>]
                                                  ("<path> <blob>" on stdin)
  scored_ledger.py verify <ledger.json> <branch>
                          [--borrow] [--head <ref>] [--tools <fingerprint>]
                                                  ("<path> <blob>" on stdin)

Identity is the git blob SHA, so a path counts as scored only while its content
is byte-for-byte what a green run measured. Blobs are content-addressed, which
is what makes this survive amend, rebase, and unrelated commits landing in
between: none of them change the blob of an already-scored file.

`source` is `measured` (default) or `marked`. A measured entry was scored by a
green run; a marked one was adopted by `crap-check.sh --mark-scored` without
being measured at all. The two used to be written identically, so a
user-approved adoption became indistinguishable from a real pass the moment it
was recorded and nothing downstream could report which it had relied on.

Records live under the branch that measured them. `--commit` additionally files
them under a shared namespace so a later branch can borrow one, which is what
makes a merge free: merging preserves blobs, so every file a branch measured
enters the base branch byte-identical and used to be re-measured from scratch.
`--borrow` opts a verify into consulting that namespace, under two guards. The
measuring commit must be reachable from `--head`, or an abandoned branch's
record would vouch for content whose kill depended on code that never landed;
and `--tools` must match what measured it, since a mutation result belongs to a
tool version, not only to a blob. Both are conservative: a miss re-measures.

`verify` prints one `unscored=<path>` line per path whose current blob is not in
the ledger, `marked=<path>` for each path satisfied only by an adoption,
`borrowed=<path>` for each satisfied by another branch's record, plus
`branch_unknown=1` when the branch has no ledger entry of its own and something
is unscored (never scored vs. scored-then-changed are different problems and get
different advice). Exit 0 iff every path on stdin is scored, whether measured,
marked or borrowed: adoption is a deliberate user override, so it satisfies the
gate, it just says so.

Entries written before `source` existed are bare blob strings. Those are read as
`measured`, which is what they were: `--mark-scored` predates this field but was
rare, and treating the ambiguous case as the stricter label would spray warnings
over ledgers that are genuinely fine.
"""

import contextlib
import fcntl
import json
import os
import subprocess
import sys

# Git forbids '..' in a ref name, so this can never collide with a branch.
SHARED = '..blobs'


# A truncated write reads back as invalid JSON, which load() would swallow as an
# empty ledger, silently reporting every scored file as unscored. Replace the
# file atomically so a killed run leaves the previous ledger intact.
def save(path, store):
    tmp = f"{path}.tmp{os.getpid()}"
    with open(tmp, 'w') as f:
        json.dump(store, f, indent=1, sort_keys=True)
    os.replace(tmp, path)


def load(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


# The whole file is rewritten, so two runs finishing together lose one's records
# without this. Parallel worktrees share the ledger, so that race is routine.
@contextlib.contextmanager
def locked(path):
    with open(f"{path}.lock", 'w') as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        yield


def pairs_from_stdin():
    for line in sys.stdin:
        parts = line.split()
        if len(parts) == 2:
            yield parts[0], parts[1]


def entry_blob(entry):
    return entry if isinstance(entry, str) else (entry or {}).get('blob')


def entry_source(entry):
    return 'measured' if isinstance(entry, str) else (entry or {}).get('source', 'measured')


def parse_opts(argv):
    opts = {'source': 'measured', 'commit': '', 'tools': '', 'head': 'HEAD', 'legacy': '',
            'borrow': False}
    rest = list(argv)
    if rest and not rest[0].startswith('--'):
        opts['source'] = rest.pop(0)
    while rest:
        flag = rest.pop(0)
        if flag == '--borrow':
            opts['borrow'] = True
        elif flag.startswith('--') and flag[2:] in opts and rest:
            opts[flag[2:]] = rest.pop(0)
        else:
            raise SystemExit(f"unknown option {flag}")
    return opts


def reachable(commit, head, cache):
    if commit not in cache:
        cache[commit] = subprocess.run(
            ['git', 'merge-base', '--is-ancestor', commit, head],
            capture_output=True, check=False).returncode == 0
    return cache[commit]


# An adoption is a user override for one branch, not a measurement, so it never
# travels: writing it is refused here as well as at the read below.
def shares(opts):
    return bool(opts['commit']) and bool(opts['tools']) and opts['source'] == 'measured'


def borrowable(shared, path, blob, opts, cache):
    record = shared.get(path, {}).get(blob)
    if not record or not opts['tools'] or record.get('tools') != opts['tools']:
        return False
    if record.get('source') != 'measured':
        return False
    return bool(record.get('commit')) and reachable(record['commit'], opts['head'], cache)


def classify(path, blob, scored, shared, opts, cache):
    entry = scored.get(path) if scored else None
    if entry_blob(entry) == blob:
        return entry_source(entry)
    if borrowable(shared, path, blob, opts, cache):
        return 'borrowed'
    return 'unscored'


def do_record(path, branch, opts):
    with locked(path):
        store = load(path)
        scored = store.setdefault(branch, {})
        shared = store.setdefault(SHARED, {}) if shares(opts) else None
        n = 0
        for p, blob in pairs_from_stdin():
            scored[p] = {'blob': blob, 'source': opts['source']}
            if shared is not None:
                shared.setdefault(p, {})[blob] = {
                    'commit': opts['commit'], 'tools': opts['tools'], 'source': opts['source']}
            n += 1
        save(path, store)
    print(f"scored={n} source={opts['source']}")
    return 0


# Anchored to the commit that carries the blob, not the parent the index was
# scored against, or a sibling branch cut from that parent would inherit the claim.
def do_anchor(path, branch, opts):
    if not shares(opts):
        return 0
    with locked(path):
        store = load(path)
        scored = store.get(branch) or {}
        shared = store.setdefault(SHARED, {})
        n = 0
        for p, blob in pairs_from_stdin():
            entry = scored.get(p)
            if entry_blob(entry) != blob or entry_source(entry) != 'measured':
                continue
            shared.setdefault(p, {})[blob] = {
                'commit': opts['commit'], 'tools': opts['tools'], 'source': 'measured'}
            n += 1
        save(path, store)
    print(f"anchored={n}")
    return 0


def do_verify(path, branch, opts):
    store = load(path)
    scored = store.get(branch)
    # A ledger that moved leaves records behind it. Reading the old location keeps
    # an in-flight branch's measurement valid without rewriting anything into the
    # new one; writes only ever go to `path`.
    if opts['legacy']:
        stale = load(opts['legacy']).get(branch)
        if stale:
            scored = {**stale, **(scored or {})}
    shared = store.get(SHARED, {}) if opts['borrow'] else {}
    cache, found = {}, {'unscored': [], 'marked': [], 'borrowed': []}
    for p, blob in pairs_from_stdin():
        verdict = classify(p, blob, scored, shared, opts, cache)
        if verdict in found:
            found[verdict].append(p)
    if scored is None and found['unscored']:
        print("branch_unknown=1")
    for kind in ('unscored', 'marked', 'borrowed'):
        for p in found[kind]:
            print(f"{kind}={p}")
    return 1 if found['unscored'] else 0


def main():
    mode, path, branch = sys.argv[1], sys.argv[2], sys.argv[3]
    opts = parse_opts(sys.argv[4:])
    if mode == 'record':
        if opts['source'] not in ('measured', 'marked'):
            print(f"source must be measured or marked, got {opts['source']!r}", file=sys.stderr)
            return 2
        return do_record(path, branch, opts)
    if mode == 'anchor':
        return do_anchor(path, branch, opts)
    return do_verify(path, branch, opts)


if __name__ == '__main__':
    sys.exit(main())
