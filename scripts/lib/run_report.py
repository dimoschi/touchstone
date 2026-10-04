"""Summarise the delivery pipeline's run records, per pipeline version.

Reads every `.claude/touchstone-runs/*.json` under a repo. A record whose
outcome is still `open` is refreshed from `gh pr view` and rewritten first.
Every measure reads only fields the pipeline wrote or gh returned; a record
missing one is counted as missing, never estimated.

Each change-risk signal the records carry is also reported per version, with
runs grouped by the value it took: true, false, unmeasured, or a number below or
above the median of the measured ones.
"""

from __future__ import annotations

import json
import statistics
import subprocess
import sys
from pathlib import Path

OUTCOMES = ('merged', 'closed', 'open', 'none')
UNMEASURED = 'unmeasured'
BUCKET_ORDER = ('true', 'false', '<=', '>', UNMEASURED, 'missing')
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


def _values_of(rec):
    signals = rec.get('signals')
    values = signals.get('values') if isinstance(signals, dict) else None
    return values if isinstance(values, dict) else {}


def _value_of(rec, name):
    entry = _values_of(rec).get(name)
    return entry.get('value') if isinstance(entry, dict) else None


def _bucket(value, split):
    if isinstance(value, bool):
        return 'true' if value else 'false'
    if value == UNMEASURED:
        return UNMEASURED
    if _number(value):
        return f'<= {split:.10g}' if value <= split else f'> {split:.10g}'
    return 'missing'


def _rank(bucket):
    return next(i for i, prefix in enumerate(BUCKET_ORDER) if bucket.startswith(prefix))


def _median_split(values):
    numbers = [v for v in values if _number(v)]
    return statistics.median(numbers) if numbers else None


def _by_value(recs, name):
    values = [_value_of(rec, name) for rec in recs]
    split = _median_split(values)
    groups = {}
    for rec, value in zip(recs, values):
        groups.setdefault(_bucket(value, split), []).append(rec)
    return {'split': split,
            'groups': {b: _measures_of(groups[b]) for b in sorted(groups, key=_rank)}}


def _signals_of(recs):
    names = dict.fromkeys(name for rec in recs for name in _values_of(rec))
    return {name: _by_value(recs, name) for name in names}


def _measures_of(recs):
    rounds = [r.get('fix_rounds') if _number(r.get('fix_rounds')) else None for r in recs]
    return {
        'runs': len(recs), 'outcomes': _outcomes_of(recs), 'halts': _halts_of(recs),
        'tokens_per_line': _median_of([_per_line(r) for r in recs]),
        'fix_rounds': _median_of(rounds),
        'blocking': _total_of([r.get('unresolved_findings') for r in recs]),
        'notes': _total_of([r.get('notes') for r in recs]),
    }


def _summary_of(recs):
    return {**_measures_of(recs), 'signals': _signals_of(recs)}


def _version_key(version):
    parts = version.split('.')
    return (not all(p.isdigit() for p in parts), [int(p) for p in parts if p.isdigit()])


def summarise(records):
    groups = {}
    for rec in records:
        groups.setdefault(version_of(rec) or 'unknown', []).append(rec)
    return {v: _summary_of(groups[v]) for v in sorted(groups, key=_version_key)}


def _fmt(median):
    return 'n/a' if median is None else f'{median:.0f}'


def _render_group(bucket, g):
    fr, b = g['fix_rounds'], g['blocking']
    return (f"      {bucket}: {g['runs']} run(s), fix rounds median {_fmt(fr['median'])}, "
            f"halted {sum(g['halts'].values())}, blocking findings {b['total']} ({b['missing']} missing)\n")


def _render_signal(name, signal):
    split = '' if signal['split'] is None else f" (numbers split at the median {signal['split']:.10g})"
    return f'    {name}{split}\n' + ''.join(_render_group(b, g) for b, g in signal['groups'].items())


def _render_signals(signals):
    if not signals:
        return ''
    return '  signals:\n' + ''.join(_render_signal(name, signal) for name, signal in signals.items())


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
    ) + _render_signals(s['signals'])


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
