"""Summarise the delivery pipeline's run records, per pipeline version.

Reads every `.claude/touchstone-runs/*.json` under a repo. A record whose
outcome is still `open` is refreshed from `gh pr view` and rewritten first.
Every measure reads only fields the pipeline wrote or gh returned; a record
missing one is counted as missing, never estimated.
"""

from __future__ import annotations

import json
import statistics
import subprocess
import sys
from pathlib import Path

OUTCOMES = ('merged', 'closed', 'open', 'none')
RUNS_DIR = Path('.claude') / 'touchstone-runs'


def version_of(rec):
    pv = rec.get('pipeline_version')
    if isinstance(pv, dict):
        pv = pv.get('executed')
    return pv if isinstance(pv, str) else None


def _number(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def output_tokens(rec):
    spend = rec.get('stage_spend')
    if not isinstance(spend, dict) or not all(_number(v) for v in spend.values()):
        return None
    return sum(spend.values())


def changed_lines(rec):
    size = rec.get('size')
    churn = size.get('totalChurn') if isinstance(size, dict) else None
    return churn if _number(churn) and churn > 0 else None


def outcome_of(view):
    if view.get('mergedAt'):
        return 'merged'
    return {'MERGED': 'merged', 'CLOSED': 'closed', 'OPEN': 'open'}.get(view.get('state'))


def gh_view(repo, number):
    try:
        done = subprocess.run(['gh', 'pr', 'view', str(number), '--json', 'state,mergedAt'],
                              cwd=repo, capture_output=True, text=True)
    except FileNotFoundError:
        return None
    return json.loads(done.stdout) if done.returncode == 0 else None


def refresh_open(path, rec, view):
    number = rec.get('pr_number')
    if rec.get('outcome') != 'open' or not isinstance(number, int):
        return
    answer = view(number)
    outcome = outcome_of(answer) if answer else None
    if outcome and outcome != 'open':
        rec['outcome'] = outcome
        path.write_text(json.dumps(rec, indent=2) + '\n')


def load_records(runs_dir):
    loaded, unreadable = [], []
    for path in sorted(Path(runs_dir).glob('*.json')):
        try:
            loaded.append((path, json.loads(path.read_text())))
        except (OSError, ValueError):
            unreadable.append(path.name)
    return loaded, unreadable


def _median_of(values):
    measured = [v for v in values if v is not None]
    return {'median': statistics.median(measured) if measured else None,
            'measured': len(measured), 'missing': len(values) - len(measured)}


def _total_of(lists):
    present = [x for x in lists if isinstance(x, list)]
    return {'total': sum(len(x) for x in present), 'missing': len(lists) - len(present)}


def _per_line(rec):
    tokens, lines = output_tokens(rec), changed_lines(rec)
    return tokens / lines if tokens is not None and lines is not None else None


def _outcomes_of(recs):
    outcomes = dict.fromkeys(OUTCOMES + ('missing',), 0)
    for rec in recs:
        outcome = rec.get('outcome')
        outcomes[outcome if outcome in OUTCOMES else 'missing'] += 1
    return outcomes


def _halts_of(recs):
    halts = {}
    for stage in (r.get('halted_at') for r in recs):
        if stage:
            halts[stage] = halts.get(stage, 0) + 1
    return halts


def _summary_of(recs):
    rounds = [r.get('fix_rounds') if _number(r.get('fix_rounds')) else None for r in recs]
    return {
        'runs': len(recs), 'outcomes': _outcomes_of(recs), 'halts': _halts_of(recs),
        'tokens_per_line': _median_of([_per_line(r) for r in recs]),
        'fix_rounds': _median_of(rounds),
        'blocking': _total_of([r.get('unresolved_findings') for r in recs]),
        'notes': _total_of([r.get('notes') for r in recs]),
    }


def _version_key(version):
    if version == 'unknown':
        return (1, [])
    return (0, [int(p) if p.isdigit() else -1 for p in version.split('.')])


def summarise(records):
    groups = {}
    for rec in records:
        groups.setdefault(version_of(rec) or 'unknown', []).append(rec)
    return {v: _summary_of(groups[v]) for v in sorted(groups, key=_version_key)}


def _fmt(median):
    return 'n/a' if median is None else f'{median:.0f}'


def _render_one(version, s):
    outcomes = ', '.join(f'{k} {n}' for k, n in s['outcomes'].items())
    halts = ', '.join(f'{k} {n}' for k, n in s['halts'].items()) or 'none'
    tpl, fr, b, n = s['tokens_per_line'], s['fix_rounds'], s['blocking'], s['notes']
    return (
        f"pipeline {version}: {s['runs']} run(s)\n"
        f'  outcome: {outcomes}\n'
        f'  halted: {halts}\n'
        f"  output tokens per changed line: median {_fmt(tpl['median'])} "
        f"({tpl['measured']} measured, {tpl['missing']} missing)\n"
        f"  fix rounds: median {_fmt(fr['median'])} ({fr['measured']} measured, {fr['missing']} missing)\n"
        f"  blocking findings {b['total']} ({b['missing']} missing), "
        f"notes {n['total']} ({n['missing']} missing)\n"
    )


def render(summary):
    if not summary:
        return 'no run records found\n'
    return ''.join(_render_one(v, s) for v, s in summary.items())


def main(argv, view=gh_view):
    repo = Path(argv[0]) if argv else Path.cwd()
    loaded, unreadable = load_records(repo / RUNS_DIR)
    for path, rec in loaded:
        refresh_open(path, rec, lambda number: view(repo, number))
    sys.stdout.write(render(summarise([rec for _, rec in loaded])))
    if unreadable:
        sys.stdout.write(f"unreadable: {', '.join(unreadable)}\n")
    return 0
