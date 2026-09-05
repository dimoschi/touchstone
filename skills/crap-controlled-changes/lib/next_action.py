#!/usr/bin/env python3
"""Decision Policy state machine for crap-check.

Reads per-function report rows on stdin, tracks refactor attempts per
function across runs in a JSON state file (kept under .git/, keyed by
branch), and emits a single NEXT_ACTION directive:

    WRITE_TESTS > REFACTOR > SURFACE_TO_USER > COMMIT_OK

Exit 0 iff the directive is COMMIT_OK.

An attempt is consumed only when a function we previously directed a
refactor for comes back still failing with changed metrics; identical
re-runs are free, and work done under a WRITE_TESTS directive never
burns a refactor attempt.

`--accept <id>` records a user-approved score for a surfaced function;
acceptance is revoked automatically if the function later worsens.
"""

import argparse
import json
import os
import re
import sys

ROW = re.compile(
    r'^(?P<id>\S+)\s+complexity=(?P<cc>\S+)\s+coverage=(?P<cov>\S+?)%?\s+'
    r'CRAP=(?P<crap>\S+)\s+'
    r'(?P<status>OK|SOFT|HARD|NEEDS_TESTS|OK_MAIN|HARD_MAIN)\s+'
    r'\((?P<tag>new|unchanged|worsened)\)\s*$'
)

MAX_ATTEMPTS = {'SOFT': 1, 'HARD': 2, 'HARD_MAIN': 2}
EPS = 0.05


def score(status, cc, crap):
    if status.endswith('_MAIN'):
        return float(cc)
    return 0.0 if crap == 'n/a' else float(crap)


def load_state(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def save_state(path, state):
    with open(path, 'w') as f:
        json.dump(state, f, indent=1, sort_keys=True)


def metrics_str(r):
    if r['status'].endswith('_MAIN'):
        return f"complexity={r['cc']}"
    return f"CRAP={r['crap']}, complexity={r['cc']}, coverage={r['cov']}%"


def surface_text(r):
    fid = r['id']
    if r['status'] == 'HARD_MAIN':
        return (f'"{fid} is at complexity {r["cc"]} (>5) and two extraction '
                f'attempts did not get it under. main should stay thin. '
                f'Options: (a) extract further into a testable sibling package, '
                f'(b) accept the violation. Which?"')
    if r['status'] == 'SOFT':
        return (f'"{fid} lands at CRAP={r["crap"]} (complexity={r["cc"]}, '
                f'coverage={r["cov"]}%). One refactor pass did not clear it '
                f'without pushing complexity into the caller. Recommend '
                f'accepting at {r["crap"]}. Approve, or try a different split?"')
    return (f'"I can\'t get {fid} below CRAP=8 without changing its contract '
            f'(CRAP={r["crap"]}, complexity={r["cc"]}, coverage={r["cov"]}%). '
            f'Options: (a) split along a clear axis, (b) introduce a '
            f'strategy/dispatch table, (c) accept the violation. Which?"')


def refactor_hint(r):
    if r['status'] == 'HARD_MAIN':
        return ('main should stay thin (complexity <= 5): extract the logic '
                'into a testable sibling package; main keeps wiring only')
    return 'one focused pass: extract a helper or flatten a conditional'


def run(args):
    state = load_state(args.state_file)
    bstate = state.get(args.branch, {})

    if args.accept:
        entry = bstate.get(args.accept)
        if not entry or 'score' not in entry:
            print(f"next-action: no recorded state for '{args.accept}' on "
                  f"branch '{args.branch}'; run crap-check.sh first", file=sys.stderr)
            return 2
        entry['accepted'] = True
        entry['accepted_score'] = entry['score']
        entry['directed'] = False
        state[args.branch] = bstate
        save_state(args.state_file, state)
        print(f"next-action: recorded user acceptance of {args.accept} at "
              f"score {entry['score']}; re-run crap-check.sh")
        return 0

    rows = []
    for line in sys.stdin:
        m = ROW.match(line)
        if m:
            r = m.groupdict()
            r['score'] = score(r['status'], r['cc'], r['crap'])
            rows.append(r)

    notes = []
    needs_tests = []
    refactor = []
    surfaced = []
    new_bstate = {}

    for r in rows:
        fid, st = r['id'], r['status']
        if st in ('OK', 'OK_MAIN'):
            continue
        if st == 'NEEDS_TESTS':
            needs_tests.append(r)
            continue

        entry = bstate.get(fid)
        if entry and entry.get('accepted'):
            if r['score'] <= entry['accepted_score'] + EPS:
                notes.append(f"{fid} accepted by user at "
                             f"{'complexity' if st.endswith('_MAIN') else 'CRAP'}"
                             f"={r['crap'] if not st.endswith('_MAIN') else r['cc']}")
                new_bstate[fid] = entry
                continue
            entry = dict(entry, accepted=False)

        if r['tag'] == 'unchanged':
            metric = f"complexity={r['cc']}" if st.endswith('_MAIN') else f"CRAP={r['crap']}"
            notes.append(f"{fid} remains at {metric} (unchanged in this PR)")
            continue

        attempts = entry['attempts'] if entry else 0
        cur_metrics = [r['cc'], r['cov'], r['crap']]
        if entry and entry.get('directed') and entry.get('metrics') != cur_metrics:
            attempts += 1
        r['attempts'] = attempts
        r['metrics'] = cur_metrics
        if attempts >= MAX_ATTEMPTS[st]:
            surfaced.append(r)
        else:
            refactor.append(r)

    print('== NEXT_ACTION ==')

    if needs_tests:
        print('WRITE_TESTS: coverage < 80% on new/worsened functions. A high CRAP')
        print('score here is a symptom of missing tests, not bad structure. Do NOT')
        print('edit source files. Invoke superpowers:test-driven-development, write')
        print('tests for these functions, see them pass, then re-run crap-check.sh:')
        for r in needs_tests:
            print(f"  - {r['id']} ({metrics_str(r)})")
        deferred = refactor + surfaced
        if deferred:
            print('Also failing, deferred until tests exist:')
            for r in deferred:
                print(f"  - {r['id']} ({metrics_str(r)})")
        for r in deferred:
            new_bstate[r['id']] = {'attempts': r['attempts'], 'metrics': r['metrics'],
                                   'directed': False, 'score': r['score']}
        verb_green = False
    elif refactor:
        print('REFACTOR: then re-run crap-check.sh. Do not commit yet.')
        for r in refactor:
            maxa = MAX_ATTEMPTS[r['status']]
            print(f"  - {r['id']} ({metrics_str(r)}) [{r['tag']}] "
                  f"attempt {r['attempts'] + 1} of {maxa}: {refactor_hint(r)}")
            new_bstate[r['id']] = {'attempts': r['attempts'], 'metrics': r['metrics'],
                                   'directed': True, 'score': r['score']}
        if surfaced:
            print(f"After these, {len(surfaced)} function(s) need a user decision "
                  f"(SURFACE_TO_USER will follow).")
            for r in surfaced:
                new_bstate[r['id']] = {'attempts': r['attempts'], 'metrics': r['metrics'],
                                       'directed': False, 'score': r['score']}
        verb_green = False
    elif surfaced:
        print('SURFACE_TO_USER: refactor attempts are exhausted. Do not edit')
        print('further. Ask the user, quoting per function:')
        for r in surfaced:
            print(f"  - {r['id']}: {surface_text(r)}")
            new_bstate[r['id']] = {'attempts': r['attempts'], 'metrics': r['metrics'],
                                   'directed': False, 'score': r['score']}
        print("If the user approves accepting a score, run:")
        print("  crap-check.sh --accept '<function-id>'   then re-run crap-check.sh")
        verb_green = False
    else:
        print('COMMIT_OK')
        for n in notes:
            print(f"  note for commit body: {n}")
        verb_green = True

    if notes and not verb_green:
        for n in notes:
            print(f"  note for commit body: {n}")

    state[args.branch] = new_bstate
    save_state(args.state_file, state)
    return 0 if verb_green else 1


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--state-file', required=True)
    p.add_argument('--branch', required=True)
    p.add_argument('--accept', metavar='FUNC_ID')
    sys.exit(run(p.parse_args()))


if __name__ == '__main__':
    main()
