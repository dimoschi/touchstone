import json

import risk_core
import risk_signals


def row(path, added=1, removed=0, binary=False):
    return {'added': added, 'removed': removed, 'path': path, 'binary': binary}


def test_parse_numstat_reads_nul_separated_rows_and_flags_binary():
    raw = '3\t1\ta.py\x00-\t-\timg.png\x000\t5\tdir/b.go\x00'
    assert risk_signals.parse_numstat(raw) == [
        row('a.py', 3, 1), row('img.png', 0, 0, binary=True), row('dir/b.go', 0, 5)]


def test_parse_numstat_of_empty_output_is_no_rows():
    assert risk_signals.parse_numstat('') == []


def test_parse_numstat_keeps_a_tab_inside_the_path():
    assert risk_signals.parse_numstat('1\t0\ta\tb.py\x00') == [row('a\tb.py', 1, 0)]


def test_render_block_is_three_lines_with_one_json_line():
    signals = {'la': risk_core.measured(3, 'three')}
    block = risk_signals.render_block('aaa..bbb', signals)
    lines = block.split('\n')
    assert lines[0] == 'TOUCHSTONE_RISK_SIGNALS aaa..bbb'
    assert json.loads(lines[1]) == {'signals': signals}
    assert lines[2] == 'TOUCHSTONE_RISK_SIGNALS_END'
    assert lines[3] == '' and len(lines) == 4


def test_totals_sum_added_and_removed_lines_and_count_binary_as_zero():
    rows = [row('a.py', 3, 1), row('img.png', 0, 0, binary=True), row('b.go', 4, 6)]
    assert risk_signals.la_signal(rows, 'r') == {
        'value': 7, 'evidence': '7 added line(s) over 3 changed path(s) in git diff '
                                '--numstat --no-renames r; a binary file counts 0'}
    assert risk_signals.ld_signal(rows, 'r')['value'] == 7
    assert risk_signals.files_signal(rows, 'r')['value'] == 3


def test_directories_counts_distinct_dirnames_with_the_root_as_a_dot():
    rows = [row('a.py'), row('b.py'), row('src/c.py'), row('src/d.py'), row('src/x/e.py')]
    sig = risk_signals.directories_signal(rows)
    assert sig['value'] == 3
    assert sig['evidence'] == '3 distinct director(ies) hold the changed paths: ., src, src/x'


def test_dependency_surface_is_true_for_each_package_manager_file_name():
    for name in ('go.mod', 'go.sum', 'go.work', 'go.work.sum', 'composer.json', 'composer.lock',
                 'pyproject.toml', 'uv.lock', 'poetry.lock', 'Pipfile', 'Pipfile.lock',
                 'requirements.txt', 'requirements-dev.txt'):
        for prefix in ('', 'svc/api/'):
            sig = risk_signals.dependency_signal([row('a.py'), row(prefix + name)])
            assert sig['value'] is True, prefix + name
            assert prefix + name in sig['evidence']


def test_dependency_surface_is_false_for_other_names_that_only_look_similar():
    rows = [row(p) for p in ('mygo.mod', 'go.mod.md', 'package.json', 'requirements.md',
                             'docs/requirements.txt.bak', 'pyproject.toml.orig', 'a.py')]
    sig = risk_signals.dependency_signal(rows)
    assert sig == {'value': False, 'evidence': 'no package-manager manifest or lockfile changed'}


def test_numstat_rows_reads_the_range_from_a_repository(repo):
    base = repo.commit({'a.py': 'l1\nl2\n', 'b.py': 'x\n'})
    head = repo.commit({'a.py': 'l1\nL2\nl3\n', 'b.py': None, 'src/c.py': 'q\n'})
    rows = risk_signals.numstat_rows(str(repo.path), f'{base}..{head}')
    assert sorted((r['path'], r['added'], r['removed']) for r in rows) == [
        ('a.py', 2, 1), ('b.py', 0, 1), ('src/c.py', 1, 0)]


def test_diff_of_reads_added_lines_of_a_non_ascii_path_whatever_the_user_quoting_config(
        repo, monkeypatch):
    monkeypatch.setenv('GIT_CONFIG_COUNT', '1')
    monkeypatch.setenv('GIT_CONFIG_KEY_0', 'core.quotePath')
    monkeypatch.setenv('GIT_CONFIG_VALUE_0', 'false')
    base = repo.commit({'café.py': 'x = 1\n', 'a"é.py': 'x = 1\n'})
    head = repo.commit({'café.py': 'x = 1\ny = 2\n', 'a"é.py': 'x = 1\ny = 2\n'})
    diff = risk_signals.diff_of(str(repo.path), f'{base}..{head}')
    assert risk_core.added_lines(diff) == {'café.py': {2}, 'a"é.py': {2}}


def test_text_line_count_counts_lines_at_a_revision_and_none_when_absent(repo):
    base = repo.commit({'a.py': 'l1\nl2\nl3', 'e.txt': ''})
    assert risk_signals.text_line_count(str(repo.path), base, 'a.py') == 3
    assert risk_signals.text_line_count(str(repo.path), base, 'e.txt') == 0
    assert risk_signals.text_line_count(str(repo.path), base, 'missing.py') is None


def test_la_per_lt_matches_the_hand_count(repo):
    base = repo.commit({'a.py': ''.join(f'l{i}\n' for i in range(10)), 'b.py': '1\n2\n3\n4\n5\n',
                        'img.bin': b'\x00\x01\x02'})
    a_new = ''.join(f'l{i}\n' for i in range(10)).replace('l1\n', 'L1\n') + 'x\ny\n'
    head = repo.commit({'a.py': a_new, 'b.py': None, 'src/c.py': 'q\nw\ne\nr\n',
                        'img.bin': b'\x00\x01\x03\x04'})
    rows = risk_signals.numstat_rows(str(repo.path), f'{base}..{head}')
    sig = risk_signals.la_per_lt_signal(str(repo.path), base, rows)
    assert sig['value'] == 7 / 15
    assert sig['evidence'] == ('LA 7 added line(s) in text files / LT 15 line(s) at the base '
                               'revision of 2 modified or deleted text file(s)')


def test_la_per_lt_is_unmeasured_when_every_touched_file_is_new(repo):
    base = repo.commit({'keep.py': 'k\n'})
    head = repo.commit({'n1.py': 'a\n', 'n2.py': 'b\nc\n'})
    rows = risk_signals.numstat_rows(str(repo.path), f'{base}..{head}')
    sig = risk_signals.la_per_lt_signal(str(repo.path), base, rows)
    assert sig['value'] == 'unmeasured'
    assert sig['reason'].startswith('LT is 0: every touched file is new')


def test_git_signals_carries_the_six_git_only_keys_in_order(repo):
    base = repo.commit({'a.py': 'l1\n'})
    head = repo.commit({'a.py': 'l1\nl2\n', 'go.mod': 'module m\n'})
    range_ = f'{base}..{head}'
    rows = risk_signals.numstat_rows(str(repo.path), range_)
    signals = risk_signals.git_signals(str(repo.path), base, range_, rows)
    assert list(signals) == ['la', 'ld', 'la_per_lt', 'files', 'directories', 'dependency_surface']
    assert signals['la']['value'] == 2
    assert signals['dependency_surface']['value'] is True


def test_parse_range_splits_base_and_head_and_refuses_anything_else():
    assert risk_signals.parse_range('abc..def') == ('abc', 'def')
    assert risk_signals.parse_range('v1.2.0..feat/x') == ('v1.2.0', 'feat/x')
    for bad in ('abc', 'abc..', '..def', 'a...b', '', 'a b..c', 'a..b c', '-x..y', 'x..-y'):
        assert risk_signals.parse_range(bad) is None, bad


def test_check_range_accepts_two_commits_and_names_the_ref_that_does_not_resolve(repo):
    base = repo.commit({'a.py': '1\n'})
    head = repo.commit({'a.py': '2\n'})
    risk_signals.check_range(str(repo.path), base, head)
    for bad_base, bad_head, name in ((base, 'nosuchref', 'nosuchref'), ('nosuchref', head, 'nosuchref')):
        try:
            risk_signals.check_range(str(repo.path), bad_base, bad_head)
            assert False, 'expected ValueError'
        except ValueError as exc:
            assert str(exc) == f'{name} does not resolve to a commit'


NO_TOOLS = ('difft', 'apidiff', 'griffe', 'roave-backward-compatibility-check', 'gosec', 'bandit',
            'opengrep', 'deadcode')


def test_collect_returns_every_key_in_order_and_never_false_for_what_it_cannot_measure(
        repo, hide_tool):
    hide_tool(*NO_TOOLS)
    base = repo.commit({'a.go': 'package a\n', 'web/app.js': 'x\n', 'README.md': 'r\n'})
    head = repo.commit({'a.go': 'package a\n// c\n', 'web/app.js': 'y\n', 'README.md': 'q\n'})
    signals = risk_signals.collect(str(repo.path), base, head)
    assert list(signals) == list(risk_signals.KEYS)
    assert [signals[k]['value'] for k in ('la', 'ld', 'files', 'directories')] == [3, 2, 3, 2]
    assert signals['dependency_surface']['value'] is False
    assert signals['semantic_noop'] == {'value': 'unmeasured', 'reason': 'difft is not on PATH; '
                                        'no semantic tool supports .js files (e.g. web/app.js)'}
    assert 'apidiff is not on PATH' in signals['api_broken']['reason']
    assert 'gosec is not on PATH' in signals['security_pattern']['reason']
    assert 'deadcode is not on PATH' in signals['entry_reachable']['reason']
    assert signals['crap_max']['value'] == 'unmeasured'
    assert signals['coverage_min']['value'] == 'unmeasured'
    assert signals['prior_defect_files']['value'] == 'unmeasured'
    for entry in signals.values():
        assert set(entry) in ({'value', 'evidence'}, {'value', 'reason'})
        assert entry['value'] != 'unmeasured' or 'reason' in entry


def test_a_config_only_change_is_unmeasured_for_every_tool_backed_signal(repo, hide_tool):
    hide_tool(*NO_TOOLS)
    base = repo.commit({'deploy.yaml': 'privileged: false\n'})
    head = repo.commit({'deploy.yaml': 'privileged: true\n'})
    signals = risk_signals.collect(str(repo.path), base, head)
    for key, tool in (('api_broken', 'API compatibility'), ('security_pattern', 'security'),
                      ('entry_reachable', 'reachability')):
        assert signals[key] == {
            'value': 'unmeasured',
            'reason': f'no {tool} tool supports .yaml files (e.g. deploy.yaml)'}


def test_a_signal_that_raises_is_unmeasured_and_the_others_are_kept(repo, hide_tool, monkeypatch):
    hide_tool(*NO_TOOLS)

    def boom(*args):
        raise RuntimeError('tool exploded')

    monkeypatch.setattr(risk_signals, 'api_signal', boom)
    monkeypatch.setattr(risk_signals, 'crap_signals', boom)
    base = repo.commit({'a.py': '1\n'})
    head = repo.commit({'a.py': '2\n'})
    signals = risk_signals.collect(str(repo.path), base, head)
    assert signals['api_broken'] == {'value': 'unmeasured',
                                     'reason': "api_broken failed: RuntimeError('tool exploded')"}
    assert signals['crap_max'] == {'value': 'unmeasured',
                                   'reason': "crap_max failed: RuntimeError('tool exploded')"}
    assert signals['coverage_min'] == signals['crap_max']
    assert signals['la']['value'] == 1


def test_main_prints_the_three_line_block_for_the_range(repo, hide_tool, capsys):
    hide_tool(*NO_TOOLS)
    base = repo.commit({'a.py': '1\n'})
    head = repo.commit({'a.py': '1\n2\n'})
    assert risk_signals.main([str(repo.path), f'{base}..{head}']) == 0
    out, err = capsys.readouterr()
    lines = out.split('\n')
    assert lines[0] == f'TOUCHSTONE_RISK_SIGNALS {base}..{head}'
    assert list(json.loads(lines[1])['signals']) == list(risk_signals.KEYS)
    assert lines[2:] == ['TOUCHSTONE_RISK_SIGNALS_END', '']
    assert err == ''


def test_main_exits_2_with_nothing_on_stdout_for_a_bad_argument_or_range(repo, tmp_path_factory,
                                                                         capsys):
    head = repo.commit({'a.py': '1\n'})
    elsewhere = str(tmp_path_factory.mktemp('not-a-repo'))
    cases = [[], [str(repo.path)], [str(repo.path), 'nope'], [str(repo.path), f'{head}..nosuch'],
             [elsewhere, f'{head}..{head}']]
    for argv in cases:
        assert risk_signals.main(argv) == 2, argv
        out, err = capsys.readouterr()
        assert out == '' and err.startswith('risk-signals:'), (argv, out, err)
