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
    return risk_reach.reach_signal(
        str(repo.path), head, risk_core.by_language(paths), added(repo, base, head))


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
    assert log.read_text().split()[1:] == ['-filter=^example\\.com/m', './...']


def test_a_changed_function_deadcode_reports_unreachable_is_false(
        repo, install_tool, monkeypatch, tmp_path_factory):
    fake_deadcode(install_tool, monkeypatch, tmp_path_factory,
                  report='m.go:3:6: unreachable func: Foo\n')
    base, head = edit_foo(repo)
    sig = signal(repo, base, head, ['m.go'])
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
    assert sig == {'value': 'unmeasured', 'reason': 'no added line sits inside a Go function'}


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
