import json
import os

import crap_rows
import risk_history


def row(fid, cc, cov, crap):
    return {'id': fid, 'cc': cc, 'cov': cov, 'crap': crap, 'status': 'OK', 'tag': 'new'}


def record_for(repo, sha, rows):
    tree = repo.git('rev-parse', f'{sha}^{{tree}}').strip()
    store = os.path.join(str(repo.path), '.git', 'crap-check-rows.json')
    crap_rows.record(store, tree, rows)


def test_crap_max_and_coverage_min_read_the_figures_of_every_commit_in_the_range(repo):
    base = repo.commit({'a.py': '1\n'})
    first = repo.commit({'a.py': '2\n'})
    head = repo.commit({'a.py': '3\n'})
    record_for(repo, first, [row('lib/a.py::f', 3.0, 100.0, 3.0), row('lib/a.py::g', 7.0, 55.5, 9.5)])
    record_for(repo, head, [row('lib/b.py::h', 2.0, 80.0, 2.4)])
    crap, cov = risk_history.crap_signals(str(repo.path), f'{base}..{head}')
    assert crap == {'value': 9.5, 'evidence': 'highest CRAP 9.5 at lib/a.py::g (complexity 7, '
                                              'coverage 55.5%), over 3 function row(s) in 2 '
                                              'commit(s)'}
    assert cov == {'value': 55.5, 'evidence': 'lowest coverage 55.5% at lib/a.py::g (complexity '
                                              '7, CRAP 9.5), over 3 function row(s) in 2 '
                                              'commit(s)'}


def test_a_commit_with_no_recorded_figures_makes_both_unmeasured(repo):
    base = repo.commit({'a.py': '1\n'})
    first = repo.commit({'a.py': '2\n'})
    head = repo.commit({'a.py': '3\n'})
    record_for(repo, first, [row('lib/a.py::f', 3.0, 100.0, 3.0)])
    crap, cov = risk_history.crap_signals(str(repo.path), f'{base}..{head}')
    reason = (f'no per-function CRAP figures were recorded for 1 of 2 commit(s) in the range '
              f'(e.g. {head[:8]})')
    assert crap == {'value': 'unmeasured', 'reason': reason}
    assert cov == {'value': 'unmeasured', 'reason': reason}


def test_no_recorded_store_at_all_is_unmeasured(repo):
    base = repo.commit({'a.py': '1\n'})
    head = repo.commit({'a.py': '2\n'})
    crap, _ = risk_history.crap_signals(str(repo.path), f'{base}..{head}')
    assert crap['value'] == 'unmeasured'
    assert 'no per-function CRAP figures were recorded for 1 of 1 commit(s)' in crap['reason']


def test_commits_that_were_gated_but_scored_nothing_are_unmeasured_not_zero(repo):
    base = repo.commit({'a.py': '1\n'})
    head = repo.commit({'README.md': 'docs\n'})
    record_for(repo, head, [])
    crap, cov = risk_history.crap_signals(str(repo.path), f'{base}..{head}')
    reason = 'no changed function was scored in any of the 1 commit(s) in the range'
    assert crap == {'value': 'unmeasured', 'reason': reason}
    assert cov == {'value': 'unmeasured', 'reason': reason}


def test_a_function_with_no_crap_or_coverage_is_left_out_of_that_figure(repo):
    base = repo.commit({'a.go': '1\n'})
    head = repo.commit({'a.go': '2\n'})
    record_for(repo, head, [{'id': 'main.run', 'cc': 9.0, 'cov': None, 'crap': None,
                             'status': 'HARD_MAIN', 'tag': 'new'},
                            row('lib.f', 2.0, 90.0, 2.1)])
    crap, cov = risk_history.crap_signals(str(repo.path), f'{base}..{head}')
    assert crap['value'] == 2.1
    assert cov['value'] == 90.0


def test_only_main_functions_leave_no_crap_score_to_report(repo):
    base = repo.commit({'a.go': '1\n'})
    head = repo.commit({'a.go': '2\n'})
    record_for(repo, head, [{'id': 'main.run', 'cc': 9.0, 'cov': None, 'crap': None,
                             'status': 'HARD_MAIN', 'tag': 'new'}])
    crap, cov = risk_history.crap_signals(str(repo.path), f'{base}..{head}')
    assert crap == {'value': 'unmeasured', 'reason': 'no scored function carries a CRAP score'}
    assert cov == {'value': 'unmeasured', 'reason': 'no scored function carries a coverage figure'}


def test_an_empty_range_is_unmeasured(repo):
    head = repo.commit({'a.py': '1\n'})
    crap, cov = risk_history.crap_signals(str(repo.path), f'{head}..{head}')
    assert crap == {'value': 'unmeasured', 'reason': 'the range has no commits'}
    assert cov == crap


def test_a_merge_commit_is_not_a_commit_the_gate_should_have_scored(repo):
    base = repo.commit({'a.py': '1\n'})
    repo.git('checkout', '-q', '-b', 'side')
    side = repo.commit({'b.py': '1\n'})
    repo.git('checkout', '-q', '-')
    main = repo.commit({'c.py': '1\n'})
    repo.git('merge', '-q', '--no-ff', '-m', 'merge', 'side')
    head = repo.git('rev-parse', 'HEAD').strip()
    for sha in (side, main):
        record_for(repo, sha, [row('f', 1.0, 100.0, 1.0)])
    crap, _ = risk_history.crap_signals(str(repo.path), f'{base}..{head}')
    assert crap['value'] == 1.0


def write_record(repo, name, body):
    runs = repo.path / '.claude' / 'touchstone-runs'
    runs.mkdir(parents=True, exist_ok=True)
    (runs / name).write_text(body if isinstance(body, str) else json.dumps(body))


def finding(path, outcome):
    return {'file': path, 'reproducer_run': {'outcome': outcome}}


def test_a_changed_path_with_an_earlier_reproduced_defect_is_true(repo):
    repo.commit({'README.md': 'x\n'})
    write_record(repo, 'gh-1.json', {'unresolved_findings': [
        finding('src/a.go', 'reproduced'), finding('src/b.go', 'errored'), {'file': 'c.go'}]})
    sig = risk_history.prior_defect_signal(str(repo.path), ['src/a.go', 'src/z.go'])
    assert sig == {'value': True, 'evidence': 'a reproduced defect was left open in an earlier '
                                              'run on a path this range changes: src/a.go '
                                              '(gh-1.json)'}


def test_a_defect_that_did_not_reproduce_does_not_count(repo):
    repo.commit({'README.md': 'x\n'})
    write_record(repo, 'gh-1.json', {'unresolved_findings': [
        finding('src/b.go', 'errored'), finding('src/b.go', 'passed'), {'file': 'src/b.go'}]})
    sig = risk_history.prior_defect_signal(str(repo.path), ['src/b.go'])
    assert sig == {'value': False, 'evidence': '1 run record(s) read; none left a reproduced '
                                               'defect open on a path this range changes'}


def test_a_leading_dot_slash_in_a_finding_path_still_matches(repo):
    repo.commit({'README.md': 'x\n'})
    write_record(repo, 'gh-2.json', {'unresolved_findings': [finding('./src/a.go', 'reproduced')]})
    assert risk_history.prior_defect_signal(str(repo.path), ['src/a.go'])['value'] is True


def test_no_run_records_is_unmeasured(repo):
    repo.commit({'README.md': 'x\n'})
    sig = risk_history.prior_defect_signal(str(repo.path), ['src/a.go'])
    assert sig == {'value': 'unmeasured',
                   'reason': 'no readable run record under .claude/touchstone-runs'}


def test_records_that_cannot_be_read_are_unmeasured(repo):
    repo.commit({'README.md': 'x\n'})
    write_record(repo, 'broken.json', '{not json')
    write_record(repo, 'list.json', '[]')
    sig = risk_history.prior_defect_signal(str(repo.path), ['src/a.go'])
    assert sig['value'] == 'unmeasured'


def test_malformed_findings_in_a_record_are_ignored(repo):
    repo.commit({'README.md': 'x\n'})
    write_record(repo, 'gh-4.json', {'unresolved_findings': [
        'text', {'reproducer_run': {'outcome': 'reproduced'}},
        {'file': 'src/a.go', 'reproducer_run': 'bad'}, finding('src/a.go', 'reproduced')]})
    write_record(repo, 'gh-5.json', {'unresolved_findings': 'nope'})
    sig = risk_history.prior_defect_signal(str(repo.path), ['src/a.go'])
    assert sig['value'] is True
    assert sig['evidence'].endswith('src/a.go (gh-4.json)')


def test_a_record_without_findings_still_counts_as_read(repo):
    repo.commit({'README.md': 'x\n'})
    write_record(repo, 'gh-3.json', {'halted_at': 'Review'})
    sig = risk_history.prior_defect_signal(str(repo.path), ['src/a.go'])
    assert sig['value'] is False


def test_records_are_read_from_the_main_checkout_of_a_linked_worktree(repo, tmp_path_factory):
    repo.commit({'README.md': 'x\n'})
    write_record(repo, 'gh-1.json', {'unresolved_findings': [finding('src/a.go', 'reproduced')]})
    linked = tmp_path_factory.mktemp('linked') / 'wt'
    repo.git('worktree', 'add', '-q', '-b', 'wt', str(linked))
    assert risk_history.prior_defect_signal(str(linked), ['src/a.go'])['value'] is True
