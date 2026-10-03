import risk_core
import risk_reach
from risk_tools import git

SOURCE = [
    'package m',                  # 1
    '',                           # 2
    'import "fmt"',               # 3
    '',                           # 4
    'func Foo(a int) int {',      # 5
    '\tx := a + 1',               # 6
    '\treturn x',                 # 7
    '}',                          # 8
    '',                           # 9
    'var table = []int{',         # 10
    '\t1,',                       # 11
    '}',                          # 12
    '',                           # 13
    'func (t T) Bar() {',         # 14
    '\tfmt.Println()',            # 15
    '}',                          # 16
]


def test_enclosing_func_finds_the_declaration_above_a_body_line():
    assert risk_reach.enclosing_func(SOURCE, 6) == 5
    assert risk_reach.enclosing_func(SOURCE, 7) == 5
    assert risk_reach.enclosing_func(SOURCE, 15) == 14


def test_enclosing_func_counts_the_signature_and_the_closing_brace():
    assert risk_reach.enclosing_func(SOURCE, 5) == 5
    assert risk_reach.enclosing_func(SOURCE, 8) == 5
    assert risk_reach.enclosing_func(SOURCE, 16) == 14


def test_enclosing_func_is_none_outside_any_function():
    assert risk_reach.enclosing_func(SOURCE, 1) is None
    assert risk_reach.enclosing_func(SOURCE, 3) is None
    assert risk_reach.enclosing_func(SOURCE, 11) is None
    assert risk_reach.enclosing_func(SOURCE, 10) is None
    assert risk_reach.enclosing_func(SOURCE, 12) is None


def test_enclosing_func_clamps_a_line_past_the_end_of_the_file():
    assert risk_reach.enclosing_func(SOURCE, 99) == 14


def test_unreachable_funcs_maps_deadcode_lines_to_repository_paths():
    text = ('s.go:9:6: unreachable func: unused\n'
            'sub/t.go:13:10: unreachable func: T.M\n'
            'not a finding\n')
    assert risk_reach.unreachable_funcs(text, 'svc') == {('svc/s.go', 9), ('svc/sub/t.go', 13)}
    assert risk_reach.unreachable_funcs('main.go:2:6: unreachable func: f\n', '.') == {
        ('main.go', 2)}


FAKE_DEADCODE = '''
echo "$(pwd) $@" >> "$TOOL_LOG"
[ -n "$DEADCODE_STDERR" ] && echo "$DEADCODE_STDERR" >&2
[ -f "$TOOL_REPORT" ] && cat "$TOOL_REPORT"
exit "${DEADCODE_RC:-0}"
'''

GO_MOD = 'module example.com/m\n\ngo 1.22\n'
M_GO = 'package m\n\nfunc Foo() int {\n\treturn 1\n}\n\nfunc Bar() int {\n\treturn 2\n}\n'


def fake_deadcode(install_tool, monkeypatch, tmp_path_factory, report=None, rc=0, stderr=''):
    out = tmp_path_factory.mktemp('deadcode')
    monkeypatch.setenv('TOOL_LOG', str(out / 'calls'))
    monkeypatch.setenv('TOOL_REPORT', str(out / 'report'))
    monkeypatch.setenv('DEADCODE_RC', str(rc))
    monkeypatch.setenv('DEADCODE_STDERR', stderr)
    if report is not None:
        (out / 'report').write_text(report)
    install_tool('deadcode', FAKE_DEADCODE)
    return out / 'calls'


def added(repo, base, head):
    diff = git(str(repo.path), 'diff', '-U0', '--no-color', '--no-renames', f'{base}..{head}')
    return risk_core.added_lines(diff.stdout.decode())


def signal(repo, base, head, paths):
    diff = git(str(repo.path), 'diff', '-U0', '--no-color', '--no-renames', f'{base}..{head}')
    return risk_reach.reach_signal(
        str(repo.path), head, risk_core.by_language(paths), added(repo, base, head),
        risk_core.gap_lines(diff.stdout.decode()))


def edit_foo(repo):
    base = repo.commit({'go.mod': GO_MOD, 'm.go': M_GO})
    head = repo.commit({'m.go': M_GO.replace('return 1', 'return 10')})
    return base, head


def test_a_changed_function_reachable_from_main_raises_the_signal(
        repo, install_tool, monkeypatch, tmp_path_factory):
    log = fake_deadcode(install_tool, monkeypatch, tmp_path_factory,
                        report='m.go:7:6: unreachable func: Bar\n')
    base, head = edit_foo(repo)
    sig = signal(repo, base, head, ['m.go'])
    assert sig == {'value': True, 'evidence': 'reachable from a main package: m.go:3'}
    assert log.read_text().split()[1:] == ['-generated', '-filter=^example\\.com/m', './...']


def test_a_changed_function_deadcode_reports_unreachable_is_false(
        repo, install_tool, monkeypatch, tmp_path_factory):
    fake_deadcode(install_tool, monkeypatch, tmp_path_factory,
                  report='m.go:3:6: unreachable func: Foo\n')
    base, head = edit_foo(repo)
    sig = signal(repo, base, head, ['m.go'])
    assert sig == {'value': False, 'evidence': 'deadcode: every changed function in module . '
                                               'is unreachable from a main package'}


GUARDED_GO = ('package m\n\nfunc Foo(n int) int {\n\tif n < 0 {\n\t\treturn 0\n\t}\n'
              '\treturn n\n}\n\nfunc Bar() int {\n\treturn 2\n}\n')


def test_a_reachable_function_that_only_lost_lines_raises_the_signal(
        repo, install_tool, monkeypatch, tmp_path_factory):
    fake_deadcode(install_tool, monkeypatch, tmp_path_factory,
                  report='m.go:7:6: unreachable func: Bar\n')
    base = repo.commit({'go.mod': GO_MOD, 'm.go': GUARDED_GO})
    unguarded = GUARDED_GO.replace('\tif n < 0 {\n\t\treturn 0\n\t}\n', '')
    head = repo.commit({'m.go': unguarded.replace('return 2', 'return 3')})
    sig = signal(repo, base, head, ['m.go'])
    assert sig == {'value': True, 'evidence': 'reachable from a main package: m.go:3'}


def test_deleting_a_whole_function_does_not_mark_its_neighbours_changed(
        repo, install_tool, monkeypatch, tmp_path_factory):
    fake_deadcode(install_tool, monkeypatch, tmp_path_factory)
    base = repo.commit({'go.mod': GO_MOD, 'm.go': M_GO})
    head = repo.commit({'m.go': M_GO.replace('\nfunc Bar() int {\n\treturn 2\n}\n', '')})
    sig = signal(repo, base, head, ['m.go'])
    assert sig == {'value': 'unmeasured', 'reason': 'no changed line sits inside a Go function'}


M_TEST_GO = 'package m\n\nimport "testing"\n\nfunc TestFoo(t *testing.T) {\n\t_ = Foo()\n}\n'


def test_a_range_that_only_changes_go_tests_is_not_reachable(
        repo, install_tool, monkeypatch, tmp_path_factory):
    log = fake_deadcode(install_tool, monkeypatch, tmp_path_factory)
    base = repo.commit({'go.mod': GO_MOD, 'm.go': M_GO, 'm_test.go': M_TEST_GO})
    head = repo.commit({'m_test.go': M_TEST_GO.replace('_ = Foo()', '_ = Foo() + 1')})
    sig = signal(repo, base, head, ['m_test.go'])
    assert sig == {'value': False, 'evidence': 'every changed Go file is a _test.go file: no '
                                               'main package calls test code, and deadcode '
                                               'does not load it'}
    assert not log.exists()


def test_a_test_file_changed_beside_unreachable_code_does_not_make_it_reachable(
        repo, install_tool, monkeypatch, tmp_path_factory):
    fake_deadcode(install_tool, monkeypatch, tmp_path_factory,
                  report='m.go:3:6: unreachable func: Foo\n')
    base = repo.commit({'go.mod': GO_MOD, 'm.go': M_GO, 'm_test.go': M_TEST_GO})
    head = repo.commit({'m.go': M_GO.replace('return 1', 'return 10'),
                        'm_test.go': M_TEST_GO.replace('_ = Foo()', '_ = Foo() + 1')})
    sig = signal(repo, base, head, ['m.go', 'm_test.go'])
    assert sig == {'value': False, 'evidence': 'deadcode: every changed function in module . '
                                               'is unreachable from a main package'}


GENERATED_GO = ('// Code generated by gen. DO NOT EDIT.\n\npackage m\n\n'
                'func Gen() int {\n\treturn 1\n}\n')
LISTS_GENERATED_ONLY_WHEN_ASKED = '''
case " $* " in *" -generated "*) cat "$TOOL_REPORT" ;; esac
exit 0
'''


def test_a_changed_function_in_a_generated_file_is_judged_like_any_other(
        repo, install_tool, monkeypatch, tmp_path_factory):
    fake_deadcode(install_tool, monkeypatch, tmp_path_factory,
                  report='gen.go:5:6: unreachable func: Gen\n')
    install_tool('deadcode', LISTS_GENERATED_ONLY_WHEN_ASKED)
    base = repo.commit({'go.mod': GO_MOD, 'gen.go': GENERATED_GO})
    head = repo.commit({'gen.go': GENERATED_GO.replace('return 1', 'return 2')})
    sig = signal(repo, base, head, ['gen.go'])
    assert sig == {'value': False, 'evidence': 'deadcode: every changed function in module . '
                                               'is unreachable from a main package'}


def test_a_module_with_no_main_package_is_unmeasured(repo, install_tool, monkeypatch,
                                                      tmp_path_factory):
    fake_deadcode(install_tool, monkeypatch, tmp_path_factory, rc=1,
                  stderr='deadcode: no main packages')
    base, head = edit_foo(repo)
    sig = signal(repo, base, head, ['m.go'])
    assert sig == {'value': 'unmeasured', 'reason': 'module . has no main package, so '
                                                    'reachability is undecidable'}


def test_a_deadcode_failure_is_unmeasured_with_its_message(repo, install_tool, monkeypatch,
                                                           tmp_path_factory):
    fake_deadcode(install_tool, monkeypatch, tmp_path_factory, rc=2, stderr='load failed')
    base, head = edit_foo(repo)
    sig = signal(repo, base, head, ['m.go'])
    assert sig == {'value': 'unmeasured', 'reason': 'deadcode exited 2 on module .: load failed'}


def test_a_nested_module_reports_paths_relative_to_itself(repo, install_tool, monkeypatch,
                                                           tmp_path_factory):
    log = fake_deadcode(install_tool, monkeypatch, tmp_path_factory,
                        report='s.go:7:6: unreachable func: Bar\n')
    base = repo.commit({'go.mod': GO_MOD, 'svc/go.mod': 'module example.com/svc\n',
                        'svc/s.go': M_GO})
    head = repo.commit({'svc/s.go': M_GO.replace('return 1', 'return 10')})
    sig = signal(repo, base, head, ['svc/s.go'])
    assert sig == {'value': True, 'evidence': 'reachable from a main package: svc/s.go:3'}
    assert log.read_text().split()[0].endswith('/svc')


def test_added_lines_outside_every_function_leave_nothing_to_judge(
        repo, install_tool, monkeypatch, tmp_path_factory):
    fake_deadcode(install_tool, monkeypatch, tmp_path_factory)
    base = repo.commit({'go.mod': GO_MOD, 'm.go': M_GO})
    head = repo.commit({'m.go': M_GO.replace('package m\n', 'package m\n\nvar x = 1\n')})
    sig = signal(repo, base, head, ['m.go'])
    assert sig == {'value': 'unmeasured', 'reason': 'no changed line sits inside a Go function'}


def test_missing_deadcode_is_unmeasured_and_named(repo, hide_tool):
    hide_tool('deadcode')
    base, head = edit_foo(repo)
    assert signal(repo, base, head, ['m.go']) == {
        'value': 'unmeasured', 'reason': 'deadcode is not on PATH'}


def test_a_language_with_no_reachability_tool_is_unmeasured(repo):
    base = repo.commit({'a.py': 'x = 1\n', 'web/app.js': 'x\n'})
    head = repo.commit({'a.py': 'x = 2\n', 'web/app.js': 'y\n'})
    assert signal(repo, base, head, ['a.py'])['reason'] == (
        'no reachability tool supports python files (e.g. a.py)')
    assert signal(repo, base, head, ['web/app.js'])['reason'] == (
        'no reachability tool supports .js files (e.g. web/app.js)')


def test_a_diff_with_no_source_file_is_false_with_that_evidence(repo):
    base = repo.commit({'README.md': 'a\n'})
    head = repo.commit({'README.md': 'b\n'})
    assert signal(repo, base, head, ['README.md']) == {
        'value': False, 'evidence': 'no source files changed'}


def test_enclosing_func_reaches_a_declaration_on_the_first_line():
    assert risk_reach.enclosing_func(['func F() {', '\tx()', '}'], 2) == 1


def test_enclosing_func_ignores_an_indented_closing_brace():
    lines = ['func F() {', '\tif x {', '\t}', '\ty()', '}']
    assert risk_reach.enclosing_func(lines, 4) == 1


def test_enclosing_func_stops_at_a_closing_brace_with_trailing_space():
    lines = ['func F() {', '}  ', 'var x = 1']
    assert risk_reach.enclosing_func(lines, 3) is None


def test_file_lines_reads_utf8_and_replaces_undecodable_bytes(tmp_path):
    (tmp_path / 'a.go').write_bytes('x := "é"\n'.encode() + b'bad \xff byte\n')
    assert risk_reach.file_lines(str(tmp_path), 'a.go') == ['x := "é"', 'bad � byte']


def test_file_lines_opens_the_file_as_utf8_with_replacement(tmp_path, monkeypatch):
    (tmp_path / 'a.go').write_text('x\n')
    seen = {}
    real = open

    def spy(*args, **kwargs):
        seen.update(kwargs)
        return real(*args, **kwargs)

    monkeypatch.setattr(risk_reach, 'open', spy, raising=False)
    risk_reach.file_lines(str(tmp_path), 'a.go')
    assert seen == {'encoding': 'utf-8', 'errors': 'replace'}


def test_file_lines_of_a_missing_file_is_empty(tmp_path):
    assert risk_reach.file_lines(str(tmp_path), 'gone.go') == []


def test_gap_func_is_none_when_the_gap_follows_the_closing_brace():
    assert risk_reach.gap_func(SOURCE, 8) is None


def test_gap_func_names_the_function_when_both_neighbours_sit_in_it():
    assert risk_reach.gap_func(SOURCE, 7) == 5
    assert risk_reach.gap_func(SOURCE, 6) == 5


def test_changed_funcs_reads_a_path_that_only_has_added_lines_or_only_gaps(tmp_path):
    (tmp_path / 'a.go').write_text('\n'.join(SOURCE[4:8]) + '\n')
    (tmp_path / 'b.go').write_text('\n'.join(SOURCE[4:8]) + '\n')
    edits = ({'a.go': {2}}, {'b.go': {2}})
    assert risk_reach.changed_funcs(str(tmp_path), edits, ['a.go', 'b.go']) == {
        ('a.go', 1), ('b.go', 1)}


def test_describe_live_joins_the_functions_with_a_comma_and_space():
    assert risk_reach.describe_live([('a.go', 3), ('b.go', 9)]) == (
        'reachable from a main package: a.go:3, b.go:9')


def test_module_part_runs_the_deadcode_tool_by_its_lowercase_name(
        repo, install_tool, monkeypatch, tmp_path_factory):
    log = fake_deadcode(install_tool, monkeypatch, tmp_path_factory)
    install_tool('deadcode', 'basename "$0" >> "$TOOL_LOG"\n')
    repo.commit({'go.mod': GO_MOD, 'm.go': M_GO})
    risk_reach.module_part(str(repo.path), '.', {('m.go', 3)})
    assert log.read_text().split() == ['deadcode']


def test_module_part_says_false_not_none_when_every_function_is_unreachable(
        repo, install_tool, monkeypatch, tmp_path_factory):
    fake_deadcode(install_tool, monkeypatch, tmp_path_factory,
                  report='m.go:3:6: unreachable func: Foo\n')
    repo.commit({'go.mod': GO_MOD, 'm.go': M_GO})
    part = risk_reach.module_part(str(repo.path), '.', {('m.go', 3)})
    assert part['value'] is False


def test_deadcode_part_with_no_module_to_judge_says_no_go_function_changed(
        repo, install_tool, monkeypatch):
    install_tool('deadcode', 'exit 0\n')
    monkeypatch.setattr(risk_reach, 'changed_funcs', lambda *a: {('m.go', 3)})
    monkeypatch.setattr(risk_reach, 'by_module', lambda *a: {})
    assert risk_reach.deadcode_part(str(repo.path), ['m.go'], ({}, {})) == {
        'value': False, 'evidence': 'no Go function changed'}


def test_go_part_over_test_files_only_is_false_not_none(tmp_path):
    part = risk_reach.go_part(str(tmp_path), ['m_test.go'], ({}, {}))
    assert part['value'] is False
