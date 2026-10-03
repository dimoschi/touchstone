import risk_api
from risk_core import by_language

# Mimics `apidiff -m -w FILE MODULE` (writes the cwd) and
# `apidiff -m -incompatible OLD NEW` (prints APIDIFF_REPORT's file, exit 0).
FAKE_APIDIFF = '''
echo "$@" >> "$APIDIFF_LOG"
if [ "$2" = "-w" ]; then
  [ -n "$APIDIFF_WRITE_FAILS" ] && { echo 'cannot load module' >&2; exit 1; }
  pwd > "$3"; exit 0
fi
[ -f "$APIDIFF_REPORT" ] && cat "$APIDIFF_REPORT"
exit 0
'''

GO_MOD = 'module example.com/m\n\ngo 1.22\n'


def go_api(install_tool, monkeypatch, tmp_path_factory, report=None, write_fails=False):
    out = tmp_path_factory.mktemp('apidiff')
    monkeypatch.setenv('APIDIFF_LOG', str(out / 'calls'))
    monkeypatch.setenv('APIDIFF_REPORT', str(out / 'report'))
    if write_fails:
        monkeypatch.setenv('APIDIFF_WRITE_FAILS', '1')
    if report is not None:
        (out / 'report').write_text(report)
    install_tool('apidiff', FAKE_APIDIFF)
    return out / 'calls'


def signal(repo, base, head, paths):
    return risk_api.api_signal(str(repo.path), base, head, by_language(paths))


def test_an_incompatible_go_change_is_api_broken(repo, install_tool, monkeypatch,
                                                  tmp_path_factory):
    log = go_api(install_tool, monkeypatch, tmp_path_factory, report='Foo: removed\n')
    base = repo.commit({'go.mod': GO_MOD, 'm.go': 'package m\nfunc Foo() {}\n'})
    head = repo.commit({'m.go': 'package m\n'})
    sig = signal(repo, base, head, ['m.go'])
    assert sig == {'value': True, 'evidence': 'apidiff -incompatible: Foo: removed'}
    calls = log.read_text().splitlines()
    assert [c.split()[:2] for c in calls] == [['-m', '-w'], ['-m', '-w'], ['-m', '-incompatible']]
    assert all(c.endswith('example.com/m') for c in calls[:2])


def test_a_compatible_go_change_is_not_api_broken(repo, install_tool, monkeypatch,
                                                   tmp_path_factory):
    go_api(install_tool, monkeypatch, tmp_path_factory)
    base = repo.commit({'go.mod': GO_MOD, 'm.go': 'package m\n'})
    head = repo.commit({'m.go': 'package m\nfunc Foo() {}\n'})
    sig = signal(repo, base, head, ['m.go'])
    assert sig == {'value': False, 'evidence': 'apidiff -incompatible: no incompatible '
                                               'change in module .'}


def test_each_changed_go_module_is_compared_on_its_own(repo, install_tool, monkeypatch,
                                                        tmp_path_factory):
    log = go_api(install_tool, monkeypatch, tmp_path_factory)
    base = repo.commit({'go.mod': GO_MOD, 'm.go': 'package m\n',
                        'svc/go.mod': 'module example.com/svc\n', 'svc/s.go': 'package s\n'})
    head = repo.commit({'m.go': 'package m\n// c\n', 'svc/s.go': 'package s\n// c\n'})
    sig = signal(repo, base, head, ['m.go', 'svc/s.go'])
    assert sig['value'] is False
    mods = [c.split()[-1] for c in log.read_text().splitlines() if ' -w ' in f' {c} ']
    assert sorted(mods) == ['example.com/m', 'example.com/m', 'example.com/svc', 'example.com/svc']


def test_a_go_module_new_in_the_range_has_no_api_to_break(repo, install_tool, monkeypatch,
                                                         tmp_path_factory):
    log = go_api(install_tool, monkeypatch, tmp_path_factory)
    base = repo.commit({'README.md': 'x\n'})
    head = repo.commit({'go.mod': GO_MOD, 'm.go': 'package m\n'})
    sig = signal(repo, base, head, ['m.go'])
    assert sig == {'value': False, 'evidence': 'module . is new in this range: no earlier API '
                                               'to break'}
    assert not log.exists()


def test_a_go_export_failure_is_unmeasured_with_the_tool_message(repo, install_tool, monkeypatch,
                                                                 tmp_path_factory):
    go_api(install_tool, monkeypatch, tmp_path_factory, write_fails=True)
    base = repo.commit({'go.mod': GO_MOD, 'm.go': 'package m\n'})
    head = repo.commit({'m.go': 'package m\n// c\n'})
    sig = signal(repo, base, head, ['m.go'])
    assert sig['value'] == 'unmeasured'
    assert sig['reason'] == 'apidiff could not read module . at the base revision: cannot load module'


def test_a_go_module_without_a_module_path_is_unmeasured(repo, install_tool, monkeypatch,
                                                         tmp_path_factory):
    go_api(install_tool, monkeypatch, tmp_path_factory)
    base = repo.commit({'go.mod': '// no module line\n', 'm.go': 'package m\n'})
    head = repo.commit({'m.go': 'package m\n// c\n'})
    sig = signal(repo, base, head, ['m.go'])
    assert sig == {'value': 'unmeasured', 'reason': 'go.mod of module . names no module path'}


def test_missing_apidiff_is_unmeasured_and_named(repo, hide_tool):
    hide_tool('apidiff')
    base = repo.commit({'go.mod': GO_MOD, 'm.go': 'package m\n'})
    head = repo.commit({'m.go': 'package m\n// c\n'})
    assert signal(repo, base, head, ['m.go']) == {
        'value': 'unmeasured', 'reason': 'apidiff is not on PATH'}


# Mimics `griffe check -a <base> -b <head> -s <search> <package>`: a breakage goes
# to stderr and exit 1, a crash prints a traceback and exits 1 too.
FAKE_GRIFFE = '''
echo "$@" >> "$GRIFFE_LOG"
if [ "$GRIFFE_MODE" = break ]; then echo 'pkg/mod.py:1: f(b): Parameter was removed' >&2; exit 1; fi
if [ "$GRIFFE_MODE" = crash ]; then echo 'Traceback (most recent call last):' >&2; exit 1; fi
exit 0
'''


def griffe(install_tool, monkeypatch, tmp_path_factory, mode='ok'):
    out = tmp_path_factory.mktemp('griffe')
    monkeypatch.setenv('GRIFFE_LOG', str(out / 'calls'))
    monkeypatch.setenv('GRIFFE_MODE', mode)
    install_tool('griffe', FAKE_GRIFFE)
    return out / 'calls'


PKG = {'pkg/__init__.py': '', 'pkg/mod.py': 'def f(a, b):\n    return a\n'}


def test_package_target_walks_up_to_the_top_of_the_package():
    files = {'src/pkg/__init__.py', 'src/pkg/sub/__init__.py', 'src/pkg/sub/m.py'}
    assert risk_api.package_target('src/pkg/sub/m.py', files) == ('src', 'pkg')
    assert risk_api.package_target('src/pkg/__init__.py', files) == ('src', 'pkg')


def test_package_target_of_a_package_at_the_repository_root():
    assert risk_api.package_target('pkg/m.py', {'pkg/__init__.py', 'pkg/m.py'}) == ('.', 'pkg')


def test_package_target_of_a_lone_module_is_the_module():
    assert risk_api.package_target('scripts/tool.py', {'scripts/tool.py'}) == ('scripts', 'tool')
    assert risk_api.package_target('tool.py', {'tool.py'}) == ('.', 'tool')


def test_a_python_breakage_is_api_broken(repo, install_tool, monkeypatch, tmp_path_factory):
    log = griffe(install_tool, monkeypatch, tmp_path_factory, mode='break')
    base = repo.commit(PKG)
    head = repo.commit({'pkg/mod.py': 'def f(a):\n    return a\n'})
    sig = signal(repo, base, head, ['pkg/mod.py'])
    assert sig == {'value': True, 'evidence': 'griffe check: pkg/mod.py:1: f(b): Parameter was '
                                              'removed'}
    assert log.read_text().split() == ['check', '-a', base, '-b', head, '-s', '.', 'pkg']


def test_a_python_change_without_breakage_is_not_api_broken(repo, install_tool, monkeypatch,
                                                            tmp_path_factory):
    griffe(install_tool, monkeypatch, tmp_path_factory)
    base = repo.commit(PKG)
    head = repo.commit({'pkg/mod.py': 'def f(a, b):\n    return b\n'})
    assert signal(repo, base, head, ['pkg/mod.py']) == {
        'value': False, 'evidence': 'griffe check: no breakage in pkg'}


def test_a_python_package_new_in_the_range_has_no_api_to_break(repo, install_tool, monkeypatch,
                                                              tmp_path_factory):
    log = griffe(install_tool, monkeypatch, tmp_path_factory, mode='break')
    base = repo.commit({'README.md': 'x\n'})
    head = repo.commit(PKG)
    assert signal(repo, base, head, ['pkg/mod.py']) == {
        'value': False, 'evidence': 'pkg is new in this range: no earlier API to break'}
    assert not log.exists()


def test_a_python_package_removed_in_the_range_is_unmeasured(repo, install_tool, monkeypatch,
                                                            tmp_path_factory):
    griffe(install_tool, monkeypatch, tmp_path_factory)
    base = repo.commit(PKG)
    head = repo.commit({'pkg/__init__.py': None, 'pkg/mod.py': None, 'keep.md': 'x\n'})
    sig = signal(repo, base, head, ['pkg/mod.py'])
    assert sig['value'] == 'unmeasured'
    assert sig['reason'] == 'pkg no longer exists at the head revision, which griffe cannot load'


def test_a_griffe_crash_is_unmeasured_not_a_breakage(repo, install_tool, monkeypatch,
                                                     tmp_path_factory):
    griffe(install_tool, monkeypatch, tmp_path_factory, mode='crash')
    base = repo.commit(PKG)
    head = repo.commit({'pkg/mod.py': 'def f(a):\n    return a\n'})
    sig = signal(repo, base, head, ['pkg/mod.py'])
    assert sig['value'] == 'unmeasured'
    assert sig['reason'] == 'griffe check exited 1 on pkg: Traceback (most recent call last):'


def test_missing_griffe_is_unmeasured_and_named(repo, hide_tool):
    hide_tool('griffe')
    base = repo.commit(PKG)
    head = repo.commit({'pkg/mod.py': 'def f(a):\n    return a\n'})
    assert signal(repo, base, head, ['pkg/mod.py']) == {
        'value': 'unmeasured', 'reason': 'griffe is not on PATH'}


# Mimics roave-backward-compatibility-check: exit 3 when it finds BC breaks.
FAKE_ROAVE = '''
echo "$@" >> "$ROAVE_LOG"
case "$ROAVE_MODE" in
  break) echo '[BC] REMOVED: Class Foo has been deleted'; exit 3;;
  crash) echo 'composer exploded' >&2; exit 2;;
esac
exit 0
'''


def roave(install_tool, monkeypatch, tmp_path_factory, mode='ok'):
    out = tmp_path_factory.mktemp('roave')
    monkeypatch.setenv('ROAVE_LOG', str(out / 'calls'))
    monkeypatch.setenv('ROAVE_MODE', mode)
    install_tool('roave-backward-compatibility-check', FAKE_ROAVE)
    return out / 'calls'


def test_a_php_bc_break_is_api_broken(repo, install_tool, monkeypatch, tmp_path_factory):
    log = roave(install_tool, monkeypatch, tmp_path_factory, mode='break')
    base = repo.commit({'composer.json': '{}\n', 'src/Bar.php': '<?php\nclass Bar {}\n'})
    head = repo.commit({'src/Bar.php': None, 'src/Baz.php': '<?php\nclass Baz {}\n'})
    sig = signal(repo, base, head, ['src/Bar.php'])
    assert sig == {'value': True, 'evidence': 'roave-backward-compatibility-check: '
                                              '[BC] REMOVED: Class Foo has been deleted'}
    assert log.read_text().split() == [f'--from={base}', f'--to={head}']


def test_a_php_change_without_bc_break_is_not_api_broken(repo, install_tool, monkeypatch,
                                                         tmp_path_factory):
    roave(install_tool, monkeypatch, tmp_path_factory)
    base = repo.commit({'composer.json': '{}\n', 'src/Bar.php': '<?php\n'})
    head = repo.commit({'src/Bar.php': '<?php\n// c\n'})
    assert signal(repo, base, head, ['src/Bar.php']) == {
        'value': False, 'evidence': 'roave-backward-compatibility-check: no BC break'}


def test_a_roave_failure_is_unmeasured(repo, install_tool, monkeypatch, tmp_path_factory):
    roave(install_tool, monkeypatch, tmp_path_factory, mode='crash')
    base = repo.commit({'src/Bar.php': '<?php\n'})
    head = repo.commit({'src/Bar.php': '<?php\n// c\n'})
    sig = signal(repo, base, head, ['src/Bar.php'])
    assert sig['value'] == 'unmeasured'
    assert sig['reason'] == ('roave-backward-compatibility-check exited 2: composer exploded')


def test_missing_roave_is_unmeasured_and_named(repo, hide_tool):
    hide_tool('roave-backward-compatibility-check')
    base = repo.commit({'src/Bar.php': '<?php\n'})
    head = repo.commit({'src/Bar.php': '<?php\n// c\n'})
    assert signal(repo, base, head, ['src/Bar.php']) == {
        'value': 'unmeasured', 'reason': 'roave-backward-compatibility-check is not on PATH'}


def test_a_language_no_tool_supports_is_unmeasured(repo):
    base = repo.commit({'web/app.js': 'x\n'})
    head = repo.commit({'web/app.js': 'y\n'})
    assert signal(repo, base, head, ['web/app.js']) == {
        'value': 'unmeasured',
        'reason': 'no API compatibility tool supports .js files (e.g. web/app.js)'}


def test_a_diff_with_no_source_file_is_false_with_that_evidence(repo):
    base = repo.commit({'README.md': 'a\n'})
    head = repo.commit({'README.md': 'b\n'})
    assert signal(repo, base, head, ['README.md']) == {
        'value': False, 'evidence': 'no source files changed'}


def test_languages_combine_so_one_break_wins_and_unknown_beats_clean(
        repo, install_tool, monkeypatch, tmp_path_factory):
    go_api(install_tool, monkeypatch, tmp_path_factory, report='Foo: removed\n')
    base = repo.commit({'go.mod': GO_MOD, 'm.go': 'package m\n', 'web/app.js': 'x\n'})
    head = repo.commit({'m.go': 'package m\n// c\n', 'web/app.js': 'y\n'})
    assert signal(repo, base, head, ['m.go', 'web/app.js'])['value'] is True
    monkeypatch.setenv('APIDIFF_REPORT', '/nonexistent/report')
    assert signal(repo, base, head, ['m.go', 'web/app.js'])['value'] == 'unmeasured'
