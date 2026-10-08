"""Unit tests for run_report.py, over fixture run records shaped like the ones
the delivery pipeline returns, including records from before a field existed.
"""

from __future__ import annotations

import json
import subprocess

import pytest

from run_report import (
    changed_lines,
    gh_view,
    load_records,
    main,
    outcome_of,
    output_tokens,
    refresh_open,
    render,
    summarise,
    version_of,
)


def record(**fields):
    base = {
        'task': 't',
        'pipeline_version': {'executed': '0.26.1', 'base_branch': '0.26.1'},
        'stage_spend': {'triage': 1000, 'implement': 9000},
        'size': {'totalChurn': 50, 'codeChurn': 40},
        'fix_rounds': 1,
        'unresolved_findings': [],
        'notes': [],
        'outcome': 'merged',
        'pr_number': 7,
    }
    base.update(fields)
    return {k: v for k, v in base.items() if v is not None}


def without(rec, *keys):
    return {k: v for k, v in rec.items() if k not in keys}


def test_version_of_reads_the_executed_version():
    assert version_of(record()) == '0.26.1'


def test_version_of_accepts_a_plain_string():
    assert version_of(record(pipeline_version='0.19.0')) == '0.19.0'


def test_version_of_is_none_for_a_record_from_before_the_field():
    assert version_of(without(record(), 'pipeline_version')) is None
    assert version_of(record(pipeline_version={'base_branch': '0.2'})) is None


def test_version_of_is_none_for_a_version_that_is_not_a_string():
    assert version_of(record(pipeline_version={'executed': 26})) is None


def test_output_tokens_sums_every_stage():
    assert output_tokens(record()) == 10000


def test_output_tokens_is_none_without_stage_spend():
    assert output_tokens(without(record(), 'stage_spend')) is None
    assert output_tokens(record(stage_spend={'triage': 'lots'})) is None


def test_changed_lines_reads_total_churn():
    assert changed_lines(record()) == 50


def test_changed_lines_is_none_without_a_usable_size():
    assert changed_lines(without(record(), 'size')) is None
    assert changed_lines(record(size={'totalChurn': 0})) is None
    assert changed_lines(record(size={'files': 2})) is None


def test_changed_lines_counts_a_single_changed_line():
    assert changed_lines(record(size={'totalChurn': 1})) == 1


@pytest.mark.parametrize('state,want', [
    ({'state': 'MERGED', 'mergedAt': '2026-09-01T00:00:00Z'}, 'merged'),
    ({'state': 'MERGED'}, 'merged'),
    ({'state': 'CLOSED', 'mergedAt': None}, 'closed'),
    ({'state': 'OPEN', 'mergedAt': None}, 'open'),
    ({'state': 'WEIRD'}, None),
])
def test_outcome_of_maps_the_gh_state(state, want):
    assert outcome_of(state) == want


def test_outcome_of_trusts_merged_at_over_state():
    assert outcome_of({'state': 'CLOSED', 'mergedAt': '2026-09-01T00:00:00Z'}) == 'merged'


def test_summarise_groups_by_version_and_counts_runs():
    summary = summarise([record(), record(), without(record(), 'pipeline_version')])
    assert list(summary) == ['0.26.1', 'unknown']
    assert summary['0.26.1']['runs'] == 2
    assert summary['unknown']['runs'] == 1


def test_summarise_orders_versions_numerically_and_unknown_last():
    recs = [without(record(), 'pipeline_version'), record(pipeline_version='0.10.0'),
            record(pipeline_version='0.9.0')]
    assert list(summarise(recs)) == ['0.9.0', '0.10.0', 'unknown']


def test_summarise_sorts_a_version_that_is_not_dotted_integers_after_the_rest():
    recs = [record(pipeline_version='1.x'), record(pipeline_version='0.9.0')]
    assert list(summarise(recs)) == ['0.9.0', '1.x']


def test_summarise_counts_outcomes_and_missing_ones():
    recs = [record(), record(outcome='closed'), record(outcome='none'),
            without(record(), 'outcome'), record(outcome='bogus')]
    assert summarise(recs)['0.26.1']['outcomes'] == {
        'merged': 1, 'closed': 1, 'open': 0, 'none': 1, 'missing': 2}


def test_summarise_counts_halts_by_stage():
    recs = [record(halted_at='Fix'), record(halted_at='Fix'), record(halted_at='Review'), record()]
    assert summarise(recs)['0.26.1']['halts'] == {'Fix': 2, 'Review': 1}


def test_summarise_takes_medians_and_counts_what_it_could_not_measure():
    recs = [
        record(stage_spend={'a': 1000}, size={'totalChurn': 10}, fix_rounds=0),
        record(stage_spend={'a': 3000}, size={'totalChurn': 10}, fix_rounds=3),
        record(stage_spend={'a': 9000}, size={'totalChurn': 10}),
        without(record(), 'size', 'fix_rounds'),
    ]
    s = summarise(recs)['0.26.1']
    assert s['tokens_per_line'] == {'median': 300.0, 'measured': 3, 'missing': 1}
    assert s['fix_rounds'] == {'median': 1.0, 'measured': 3, 'missing': 1}


def test_summarise_counts_fix_rounds_that_are_not_a_number_as_missing():
    s = summarise([record(fix_rounds='two'), record(fix_rounds=2)])['0.26.1']
    assert s['fix_rounds'] == {'median': 2, 'measured': 1, 'missing': 1}


def test_summarise_has_no_median_when_nothing_was_measured():
    s = summarise([without(record(), 'size', 'fix_rounds')])['0.26.1']
    assert s['tokens_per_line'] == {'median': None, 'measured': 0, 'missing': 1}
    assert s['fix_rounds'] == {'median': None, 'measured': 0, 'missing': 1}


def test_summarise_totals_blocking_findings_and_notes():
    recs = [
        record(unresolved_findings=[{'id': 'f1'}, {'id': 'f2'}], notes=[{'title': 'n'}]),
        record(notes=[{'title': 'n'}, {'title': 'm'}]),
        without(record(), 'unresolved_findings', 'notes'),
    ]
    s = summarise(recs)['0.26.1']
    assert s['blocking'] == {'total': 2, 'missing': 1}
    assert s['notes'] == {'total': 3, 'missing': 1}


def test_render_prints_every_measure_per_version():
    recs = [record(halted_at='Fix', unresolved_findings=[{'id': 'f1'}]), record()]
    assert render(summarise(recs)) == (
        'pipeline 0.26.1: 2 run(s)\n'
        '  outcome: merged 2, closed 0, open 0, none 0, missing 0\n'
        '  halted: Fix 1\n'
        '  output tokens per changed line: median 200 (2 measured, 0 missing)\n'
        '  fix rounds: median 1 (2 measured, 0 missing)\n'
        '  blocking findings 1 (0 missing), notes 0 (0 missing)\n'
    )


def test_render_lists_several_halt_stages_and_versions():
    recs = [record(halted_at='Fix'), record(halted_at='Review'), record(pipeline_version='0.27.0')]
    out = render(summarise(recs))
    assert '  halted: Fix 1, Review 1\n' in out
    assert out.count('pipeline ') == 2
    assert '0 missing)\npipeline 0.27.0: 1 run(s)\n' in out


def test_render_says_none_for_no_halts_and_no_median():
    recs = [without(record(), 'size')]
    out = render(summarise(recs))
    assert '  halted: none\n' in out
    assert '  output tokens per changed line: median n/a (0 measured, 1 missing)\n' in out


def test_render_of_no_records():
    assert render({}) == 'no run records found\n'


def signals(**values):
    return {'range': 'a..b', 'values': {name: {'value': value, 'evidence': {}} if value != 'unmeasured'
                                         else {'value': value, 'reason': 'no tool', 'evidence': {}}
                                         for name, value in values.items()}}


def groups_of(recs, name):
    return summarise(recs)['0.26.1']['signals'][name]['groups']


def test_signals_group_runs_by_the_value_a_signal_took():
    recs = [
        record(signals=signals(api_broken=True), fix_rounds=3, halted_at='Fix',
               unresolved_findings=[{'id': 'f1'}, {'id': 'f2'}]),
        record(signals=signals(api_broken=True), fix_rounds=1),
        record(signals=signals(api_broken=False), fix_rounds=0),
        record(signals=signals(api_broken='unmeasured'), fix_rounds=2, halted_at='Review'),
        record(),
    ]
    got = groups_of(recs, 'api_broken')
    assert list(got) == ['true', 'false', 'unmeasured', 'missing']
    assert got['true']['runs'] == 2
    assert got['true']['fix_rounds'] == {'median': 2.0, 'measured': 2, 'missing': 0}
    assert got['true']['halts'] == {'Fix': 1}
    assert got['true']['blocking'] == {'total': 2, 'missing': 0}
    assert got['false']['runs'] == 1 and got['false']['halts'] == {}
    assert got['unmeasured']['halts'] == {'Review': 1}
    assert got['missing']['runs'] == 1


def test_a_number_signal_is_split_at_the_median_of_the_measured_values():
    recs = [record(signals=signals(la=v), fix_rounds=r) for v, r in [(1, 0), (2, 1), (3, 2), (10, 3)]]
    summary = summarise(recs)['0.26.1']['signals']['la']
    assert summary['split'] == 2.5
    assert list(summary['groups']) == ['<= 2.5', '> 2.5']
    assert summary['groups']['<= 2.5']['runs'] == 2
    assert summary['groups']['> 2.5']['fix_rounds']['median'] == 2.5


def test_a_value_equal_to_the_median_sits_in_the_lower_group():
    recs = [record(signals=signals(la=v)) for v in (1, 5, 9)]
    got = groups_of(recs, 'la')
    assert (got['<= 5']['runs'], got['> 5']['runs']) == (2, 1)


def test_a_number_signal_whose_values_all_agree_has_only_the_lower_group():
    got = groups_of([record(signals=signals(la=4)), record(signals=signals(la=4))], 'la')
    assert list(got) == ['<= 4']


def test_zero_is_a_measured_number_not_a_missing_one():
    got = groups_of([record(signals=signals(la=0)), record(signals=signals(la=2))], 'la')
    assert got['<= 1']['runs'] == 1


def test_numbers_and_booleans_and_unmeasured_can_share_a_signal():
    recs = [record(signals=signals(x=1)), record(signals=signals(x=3)), record(signals=signals(x='unmeasured')),
            record(signals=signals(x=True))]
    assert list(groups_of(recs, 'x')) == ['true', '<= 2', '> 2', 'unmeasured']


@pytest.mark.parametrize('bad', [
    {'values': {'la': {'evidence': {}}}},
    {'values': {'la': {'value': None}}},
    {'values': {'la': {'value': 'maybe'}}},
    {'values': {'la': 7}},
    {'values': {'other': {'value': 1}}},
    {'values': [1]},
    {'range': 'a..b'},
    'none',
    None,
])
def test_a_record_with_no_usable_entry_for_a_signal_is_counted_as_missing(bad):
    recs = [record(signals=signals(la=1)), record(signals=bad)]
    got = groups_of(recs, 'la')
    assert got['missing']['runs'] == 1


def test_signal_names_come_from_the_records_in_the_order_first_seen():
    recs = [record(signals=signals(b=True, a=True)), record(signals=signals(c=1, a=False))]
    assert list(summarise(recs)['0.26.1']['signals']) == ['b', 'a', 'c']


def test_a_version_with_no_recorded_signals_has_none():
    assert summarise([record(), record()])['0.26.1']['signals'] == {}


def test_signals_are_summarised_per_pipeline_version():
    recs = [record(signals=signals(a=True)), record(pipeline_version='0.27.0', signals=signals(b=True))]
    got = summarise(recs)
    assert list(got['0.26.1']['signals']) == ['a']
    assert list(got['0.27.0']['signals']) == ['b']


def test_render_prints_each_signal_after_the_version_block():
    recs = [
        record(signals=signals(api_broken=True, la=10), fix_rounds=3, halted_at='Fix',
               unresolved_findings=[{'id': 'f1'}]),
        record(signals=signals(api_broken=False, la=2), fix_rounds=0),
        record(),
    ]
    assert render(summarise(recs)) == (
        'pipeline 0.26.1: 3 run(s)\n'
        '  outcome: merged 3, closed 0, open 0, none 0, missing 0\n'
        '  halted: Fix 1\n'
        '  output tokens per changed line: median 200 (3 measured, 0 missing)\n'
        '  fix rounds: median 1 (3 measured, 0 missing)\n'
        '  blocking findings 1 (0 missing), notes 0 (0 missing)\n'
        '  signals:\n'
        '    api_broken\n'
        '      true: 1 run(s), fix rounds median 3, halted 1, blocking findings 1 (0 missing)\n'
        '      false: 1 run(s), fix rounds median 0, halted 0, blocking findings 0 (0 missing)\n'
        '      missing: 1 run(s), fix rounds median 1, halted 0, blocking findings 0 (0 missing)\n'
        '    la (numbers split at the median 6)\n'
        '      <= 6: 1 run(s), fix rounds median 0, halted 0, blocking findings 0 (0 missing)\n'
        '      > 6: 1 run(s), fix rounds median 3, halted 1, blocking findings 1 (0 missing)\n'
        '      missing: 1 run(s), fix rounds median 1, halted 0, blocking findings 0 (0 missing)\n'
    )


def test_render_says_n_a_for_a_group_with_no_fix_rounds_and_counts_missing_findings():
    recs = [record(signals=signals(a=True), unresolved_findings=None, fix_rounds=None)]
    assert '      true: 1 run(s), fix rounds median n/a, halted 0, blocking findings 0 (1 missing)\n' in render(summarise(recs))


def test_render_orders_a_signals_groups_true_false_numbers_unmeasured_missing():
    recs = [record(), record(signals=signals(x='unmeasured')), record(signals=signals(x=5)),
            record(signals=signals(x=1)), record(signals=signals(x=False)), record(signals=signals(x=True))]
    out = render(summarise(recs))
    order = [line.split(':')[0].strip() for line in out.splitlines() if line.startswith('      ')]
    assert order == ['true', 'false', '<= 3', '> 3', 'unmeasured', 'missing']


def test_render_formats_a_large_median_without_an_exponent():
    recs = [record(signals=signals(x=1234567)), record(signals=signals(x=1234569))]
    assert '(numbers split at the median 1234568)' in render(summarise(recs))


def write(dirpath, name, rec):
    path = dirpath / name
    path.write_text(json.dumps(rec))
    return path


def test_load_records_reads_every_json_file_and_counts_unreadable(tmp_path):
    write(tmp_path, '1.json', record())
    (tmp_path / '2.json').write_text('{not json')
    (tmp_path / 'notes.txt').write_text('ignored')
    loaded, unreadable = load_records(tmp_path)
    assert [p.name for p, _ in loaded] == ['1.json']
    assert unreadable == ['2.json']


def test_load_records_of_a_missing_directory(tmp_path):
    assert load_records(tmp_path / 'nope') == ([], [])


def test_refresh_open_rewrites_an_open_record_from_gh(tmp_path):
    path = write(tmp_path, '1.json', record(outcome='open', pr_number=12))
    asked = []
    rec = json.loads(path.read_text())
    refresh_open(path, rec, lambda n: asked.append(n) or {'state': 'MERGED', 'mergedAt': 'x'})
    assert asked == [12]
    assert rec['outcome'] == 'merged'
    assert path.read_text() == json.dumps(rec, indent=2) + '\n'


def test_refresh_open_leaves_a_settled_record_alone(tmp_path):
    path = write(tmp_path, '1.json', record(outcome='merged'))
    before = path.read_text()
    refresh_open(path, json.loads(before), lambda n: pytest.fail('gh must not be asked'))
    assert path.read_text() == before


def test_refresh_open_needs_a_pr_number(tmp_path):
    path = write(tmp_path, '1.json', record(outcome='open', pr_number=None))
    rec = json.loads(path.read_text())
    refresh_open(path, rec, lambda n: pytest.fail('gh must not be asked'))
    assert rec['outcome'] == 'open'


def test_refresh_open_keeps_the_record_when_gh_has_no_answer(tmp_path):
    path = write(tmp_path, '1.json', record(outcome='open', pr_number=12))
    before = path.read_text()
    rec = json.loads(before)
    refresh_open(path, rec, lambda n: None)
    assert rec['outcome'] == 'open'
    assert path.read_text() == before


def test_refresh_open_does_not_rewrite_a_pr_still_open(tmp_path):
    path = write(tmp_path, '1.json', record(outcome='open', pr_number=12))
    before = path.read_text()
    refresh_open(path, json.loads(before), lambda n: {'state': 'OPEN', 'mergedAt': None})
    assert path.read_text() == before


def test_gh_view_parses_what_gh_prints(monkeypatch, tmp_path):
    seen = {}

    def fake_run(cmd, **kwargs):
        seen['cmd'] = cmd
        seen['cwd'] = kwargs.get('cwd')
        seen['kwargs'] = kwargs
        return subprocess.CompletedProcess(cmd, 0, stdout='{"state": "OPEN", "mergedAt": null}', stderr='')

    monkeypatch.setattr(subprocess, 'run', fake_run)
    assert gh_view(tmp_path, 12) == {'state': 'OPEN', 'mergedAt': None}
    assert seen['cmd'] == ['gh', 'pr', 'view', '12', '--json', 'state,mergedAt']
    assert seen['cwd'] == tmp_path
    assert seen['kwargs'] == {'cwd': tmp_path, 'capture_output': True, 'text': True}


def test_gh_view_is_none_when_gh_fails(monkeypatch, tmp_path):
    monkeypatch.setattr(subprocess, 'run',
                        lambda cmd, **kw: subprocess.CompletedProcess(cmd, 1, stdout='', stderr='no'))
    assert gh_view(tmp_path, 12) is None


def test_gh_view_is_none_when_gh_is_missing(monkeypatch, tmp_path):
    def missing(cmd, **kw):
        raise FileNotFoundError('gh')

    monkeypatch.setattr(subprocess, 'run', missing)
    assert gh_view(tmp_path, 12) is None


def test_main_refreshes_and_prints_the_report(tmp_path, capsys):
    runs = tmp_path / '.claude' / 'touchstone-runs'
    runs.mkdir(parents=True)
    write(runs, '1.json', record(outcome='open', pr_number=3))
    (runs / '2.json').write_text('{broken')
    (runs / '3.json').write_text('{broken')
    rc = main([str(tmp_path)], view=lambda repo, n: {'state': 'CLOSED', 'mergedAt': None})
    out = capsys.readouterr().out
    assert rc == 0
    assert 'outcome: merged 0, closed 1, open 0, none 0, missing 0' in out
    assert 'unreadable: 2.json, 3.json\n' in out


def test_main_defaults_to_the_current_directory(tmp_path, capsys, monkeypatch):
    monkeypatch.chdir(tmp_path)
    assert main([], view=lambda repo, n: None) == 0
    assert capsys.readouterr().out == 'no run records found\n'


def test_main_passes_the_repo_to_gh(tmp_path, capsys):
    runs = tmp_path / '.claude' / 'touchstone-runs'
    runs.mkdir(parents=True)
    write(runs, '1.json', record(outcome='open', pr_number=3))
    seen = []
    main([str(tmp_path)], view=lambda repo, n: seen.append((repo, n)))
    assert seen == [(tmp_path, 3)]
