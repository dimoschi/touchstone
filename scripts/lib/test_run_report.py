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
        '  risk signals: none recorded (2 run(s) missing them)\n'
    )


def test_render_lists_several_halt_stages_and_versions():
    recs = [record(halted_at='Fix'), record(halted_at='Review'), record(pipeline_version='0.27.0')]
    out = render(summarise(recs))
    assert '  halted: Fix 1, Review 1\n' in out
    assert out.count('pipeline ') == 2
    assert '(2 run(s) missing them)\npipeline 0.27.0: 1 run(s)\n' in out


def test_render_says_none_for_no_halts_and_no_median():
    recs = [without(record(), 'size')]
    out = render(summarise(recs))
    assert '  halted: none\n' in out
    assert '  output tokens per changed line: median n/a (0 measured, 1 missing)\n' in out


def test_render_of_no_records():
    assert render({}) == 'no run records found\n'


def signals(**entries):
    return {'range': 'a..b', 'signals': entries}


def measured(value):
    return {'value': value, 'evidence': 'e'}


UNKNOWN = {'value': 'unmeasured', 'reason': 'r'}


def test_a_boolean_signal_groups_runs_by_value_with_each_groups_outcomes():
    recs = [
        record(risk_signals=signals(dependency_surface=measured(True)), fix_rounds=3,
               halted_at='Fix', unresolved_findings=[{'id': 'f1'}, {'id': 'f2'}]),
        record(risk_signals=signals(dependency_surface=measured(True)), fix_rounds=1),
        record(risk_signals=signals(dependency_surface=measured(False)), fix_rounds=0),
    ]
    groups = summarise(recs)['0.26.1']['risk']['signals']['dependency_surface']['groups']
    assert list(groups) == ['true', 'false']
    assert groups['true'] == {
        'runs': 2, 'fix_rounds': {'median': 2.0, 'measured': 2, 'missing': 0}, 'halted': 1,
        'blocking': {'total': 2, 'missing': 0}}
    assert groups['false']['runs'] == 1
    assert groups['false']['halted'] == 0


def test_a_numeric_signal_splits_at_its_median():
    recs = [record(risk_signals=signals(la=measured(v)), fix_rounds=r)
            for v, r in ((10, 0), (20, 1), (30, 4))]
    sig = summarise(recs)['0.26.1']['risk']['signals']['la']
    assert sig['median'] == 20
    assert list(sig['groups']) == ['<= median', '> median']
    assert sig['groups']['<= median']['runs'] == 2
    assert sig['groups']['> median']['fix_rounds']['median'] == 4


def test_unmeasured_and_missing_signals_are_their_own_groups():
    recs = [
        record(risk_signals=signals(la=measured(5), files=UNKNOWN)),
        record(risk_signals={'range': 'a..b', 'unmeasured': 'the probe failed'}),
        record(risk_signals=signals(files=measured(2))),
        without(record(), 'risk_signals'),
        record(risk_signals=None),
        record(risk_signals='not a block'),
    ]
    risk = summarise(recs)['0.26.1']['risk']
    assert (risk['recorded'], risk['missing']) == (3, 3)
    assert list(risk['signals']) == ['la', 'files']
    assert {k: g['runs'] for k, g in risk['signals']['la']['groups'].items()} == {
        '<= median': 1, 'unmeasured': 1, 'missing': 4}
    assert {k: g['runs'] for k, g in risk['signals']['files']['groups'].items()} == {
        '<= median': 1, 'unmeasured': 2, 'missing': 3}


def test_a_value_that_is_neither_a_boolean_nor_a_number_counts_as_missing():
    recs = [record(risk_signals=signals(la={'value': 'big', 'evidence': 'e'})),
            record(risk_signals=signals(la='broken')),
            record(risk_signals=signals(la=measured(True)))]
    groups = summarise(recs)['0.26.1']['risk']['signals']['la']['groups']
    assert {k: g['runs'] for k, g in groups.items()} == {'true': 1, 'missing': 2}


def test_signals_in_runs_with_no_findings_or_rounds_still_group():
    recs = [record(risk_signals=signals(api_broken=measured(False)), fix_rounds=None,
                   unresolved_findings=None)]
    group = summarise(recs)['0.26.1']['risk']['signals']['api_broken']['groups']['false']
    assert group['fix_rounds'] == {'median': None, 'measured': 0, 'missing': 1}
    assert group['blocking'] == {'total': 0, 'missing': 1}


def test_render_lists_each_signals_groups_with_their_outcomes():
    recs = [
        record(risk_signals=signals(la=measured(10), api_broken=measured(True)), fix_rounds=0),
        record(risk_signals=signals(la=measured(30), api_broken=UNKNOWN), fix_rounds=2,
               halted_at='Fix', unresolved_findings=[{'id': 'f1'}]),
        without(record(), 'risk_signals'),
    ]
    out = render(summarise(recs))
    assert out.endswith(
        '  risk signals: 2 run(s) recorded them, 1 missing\n'
        '    la (median 20)\n'
        '      <= median: 1 run(s), median fix rounds 0, halted 0, blocking findings 0 (0 missing)\n'
        '      > median: 1 run(s), median fix rounds 2, halted 1, blocking findings 1 (0 missing)\n'
        '      missing: 1 run(s), median fix rounds 1, halted 0, blocking findings 0 (0 missing)\n'
        '    api_broken\n'
        '      true: 1 run(s), median fix rounds 0, halted 0, blocking findings 0 (0 missing)\n'
        '      unmeasured: 1 run(s), median fix rounds 2, halted 1, blocking findings 1 '
        '(0 missing)\n'
        '      missing: 1 run(s), median fix rounds 1, halted 0, blocking findings 0 (0 missing)\n')


def test_render_says_so_when_every_recorded_block_is_a_failed_probe():
    recs = [record(risk_signals={'range': 'a..b', 'unmeasured': 'the probe failed'})]
    assert render(summarise(recs)).endswith(
        '  risk signals: 1 run(s) recorded them, 0 missing\n'
        '    no signal was measured in any of them\n')


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
