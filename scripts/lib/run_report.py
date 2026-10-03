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
UNMEASURED, MISSING = 'unmeasured', 'missing'
GROUP_ORDER = ('true', 'false', '<= median', '> median', UNMEASURED, MISSING)


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


def _rounds_of(recs):
    return _median_of([r.get('fix_rounds') if _number(r.get('fix_rounds')) else None
                       for r in recs])


def _usable(value):
    return value == UNMEASURED or isinstance(value, bool) or _number(value)


def _entry_value(signals, key):
    entry = signals.get(key) if isinstance(signals, dict) else None
    value = entry.get('value') if isinstance(entry, dict) else None
    return value if _usable(value) else MISSING


def _risk_value(rec, key):
    """One signal of one run: its value, UNMEASURED, or MISSING when the run
    recorded no usable entry for it."""
    block = rec.get('risk_signals')
    if not isinstance(block, dict):
        return MISSING
    signals = block.get('signals')
    if signals is None:
        return UNMEASURED if isinstance(block.get('unmeasured'), str) else MISSING
    return _entry_value(signals, key)


def _signal_keys(recs):
    """Every signal any run recorded, in the order first seen."""
    keys = {}
    for rec in recs:
        block = rec.get('risk_signals')
        signals = block.get('signals') if isinstance(block, dict) else None
        keys.update(dict.fromkeys(signals if isinstance(signals, dict) else ()))
    return list(keys)


def _group_label(value, median):
    if value in (UNMEASURED, MISSING):
        return value
    if isinstance(value, bool):
        return 'true' if value else 'false'
    return '<= median' if value <= median else '> median'


def _group_stats(recs):
    return {
        'runs': len(recs), 'fix_rounds': _rounds_of(recs),
        'halted': sum(1 for r in recs if r.get('halted_at')),
        'blocking': _total_of([r.get('unresolved_findings') for r in recs]),
    }


def _numeric_median(values):
    numbers = [v for v in values if _number(v)]
    return statistics.median(numbers) if numbers else None


def _grouped(recs, values, median):
    grouped = {}
    for rec, value in zip(recs, values):
        grouped.setdefault(_group_label(value, median), []).append(rec)
    return {g: _group_stats(grouped[g]) for g in GROUP_ORDER if g in grouped}


def _signal_groups(recs, key):
    values = [_risk_value(r, key) for r in recs]
    median = _numeric_median(values)
    return {'median': median, 'groups': _grouped(recs, values, median)}


def _risk_of(recs):
    recorded = sum(1 for r in recs if isinstance(r.get('risk_signals'), dict))
    return {'recorded': recorded, 'missing': len(recs) - recorded,
            'signals': {k: _signal_groups(recs, k) for k in _signal_keys(recs)}}


def _summary_of(recs):
    return {
        'runs': len(recs), 'outcomes': _outcomes_of(recs), 'halts': _halts_of(recs),
        'tokens_per_line': _median_of([_per_line(r) for r in recs]),
        'fix_rounds': _rounds_of(recs),
        'blocking': _total_of([r.get('unresolved_findings') for r in recs]),
        'notes': _total_of([r.get('notes') for r in recs]),
        'risk': _risk_of(recs),
    }


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


def _render_group(label, g):
    b = g['blocking']
    return (f"      {label}: {g['runs']} run(s), median fix rounds {_fmt(g['fix_rounds']['median'])}, "
            f"halted {g['halted']}, blocking findings {b['total']} ({b['missing']} missing)\n")


def _render_signal(key, signal):
    median = signal['median']
    title = key if median is None else f'{key} (median {median:g})'
    groups = ''.join(_render_group(label, g) for label, g in signal['groups'].items())
    return f'    {title}\n{groups}'


def _render_risk(risk):
    if not risk['recorded']:
        return f"  risk signals: none recorded ({risk['missing']} run(s) missing them)\n"
    head = f"  risk signals: {risk['recorded']} run(s) recorded them, {risk['missing']} missing\n"
    if not risk['signals']:
        return head + '    no signal was measured in any of them\n'
    return head + ''.join(_render_signal(k, s) for k, s in risk['signals'].items())


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
        + _render_risk(s['risk'])
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
