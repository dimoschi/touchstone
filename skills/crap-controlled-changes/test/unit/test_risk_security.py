import json
import os

import risk_core
import risk_security
from risk_tools import git

GOSEC_JSON = json.dumps({'Golang errors': {}, 'Issues': [
    {'severity': 'MEDIUM', 'confidence': 'HIGH', 'rule_id': 'G401', 'file': '/work/m.go',
     'details': 'Use of weak cryptographic primitive', 'line': '9', 'column': '7'},
    {'severity': 'MEDIUM', 'confidence': 'HIGH', 'rule_id': 'G204', 'file': '/work/svc/s.go',
     'details': 'Subprocess launched with variable', 'line': '14-16', 'column': '9'}]})

BANDIT_JSON = json.dumps({'errors': [], 'results': [
    {'filename': './a.py', 'issue_text': 'Use of weak MD5 hash', 'line_number': 6,
     'line_range': [6], 'test_id': 'B324'},
    {'filename': 'pkg/b.py', 'issue_text': 'shell=True', 'line_number': 10,
     'line_range': [10, 11, 12], 'test_id': 'B602'},
    {'filename': 'c.py', 'issue_text': 'no range', 'line_number': 3, 'test_id': 'B101'}]})

OPENGREP_JSON = json.dumps({'version': '1', 'errors': [], 'results': [
    {'check_id': 'touchstone-php-eval', 'path': 'a.php',
     'start': {'line': 8, 'col': 5}, 'end': {'line': 8, 'col': 13}},
    {'check_id': 'touchstone-php-weak-hash', 'path': 'src/b.php',
     'start': {'line': 4, 'col': 12}, 'end': {'line': 6, 'col': 19}}]})


def test_gosec_findings_read_the_issue_span_relative_to_the_root():
    assert risk_security.gosec_findings(GOSEC_JSON, '/work') == [
        ('m.go', 9, 9, 'G401 Use of weak cryptographic primitive'),
        ('svc/s.go', 14, 16, 'G204 Subprocess launched with variable')]


def test_gosec_findings_with_no_issues_key_is_empty():
    assert risk_security.gosec_findings('{"Golang errors": {}}', '/work') == []


def test_bandit_findings_use_the_line_range_or_the_line_number():
    assert risk_security.bandit_findings(BANDIT_JSON) == [
        ('a.py', 6, 6, 'B324 Use of weak MD5 hash'),
        ('pkg/b.py', 10, 12, 'B602 shell=True'),
        ('c.py', 3, 3, 'B101 no range')]


def test_opengrep_findings_read_start_and_end_lines():
    assert risk_security.opengrep_findings(OPENGREP_JSON) == [
        ('a.php', 8, 8, 'touchstone-php-eval'),
        ('src/b.php', 4, 6, 'touchstone-php-weak-hash')]


def test_a_finding_counts_only_when_its_span_overlaps_an_added_line():
    findings = [('m.go', 9, 9, 'on a changed line'), ('m.go', 20, 22, 'span reaches one'),
                ('m.go', 30, 30, 'unchanged line'), ('other.go', 9, 9, 'other file')]
    added = {'m.go': {9, 22}}
    assert risk_security.overlapping(findings, added) == [
        ('m.go', 9, 9, 'on a changed line'), ('m.go', 20, 22, 'span reaches one')]


def test_a_span_that_ends_one_line_before_an_added_line_does_not_overlap():
    assert risk_security.overlapping([('m.go', 5, 6, 'x')], {'m.go': {7}}) == []
    assert risk_security.overlapping([('m.go', 8, 9, 'x')], {'m.go': {7}}) == []
    assert risk_security.overlapping([('m.go', 6, 7, 'x')], {'m.go': {7}}) != []
    assert risk_security.overlapping([('m.go', 7, 8, 'x')], {'m.go': {7}}) != []


def added(repo, base, head):
    diff = git(str(repo.path), 'diff', '-U0', '--no-color', '--no-renames', f'{base}..{head}')
    return risk_core.added_lines(diff.stdout.decode())


def signal(repo, base, head, paths):
    return risk_security.security_signal(
        str(repo.path), head, risk_core.by_language(paths), added(repo, base, head))


GOSEC_FAKE = '''
echo "$@" >> "$TOOL_LOG"
[ -f "$TOOL_REPORT" ] || { echo 'gosec failed' >&2; exit 2; }
sed "s#@ROOT@#$(pwd)#g" "$TOOL_REPORT"
exit 1
'''


def fake_report(monkeypatch, tmp_path_factory, text=None):
    out = tmp_path_factory.mktemp('report')
    monkeypatch.setenv('TOOL_LOG', str(out / 'calls'))
    monkeypatch.setenv('TOOL_REPORT', str(out / 'report'))
    if text is not None:
        (out / 'report').write_text(text)
    return out / 'calls'


def go_issue(line, file='@ROOT@/m.go'):
    return json.dumps({'Issues': [{'rule_id': 'G401', 'details': 'weak hash', 'file': file,
                                   'line': str(line)}]})


GO_BASE = {'go.mod': 'module example.com/m\n', 'm.go': 'package m\n\nfunc A() {}\n'}


def test_a_gosec_finding_on_an_added_line_is_a_security_pattern(
        repo, install_tool, monkeypatch, tmp_path_factory):
    log = fake_report(monkeypatch, tmp_path_factory, go_issue(3))
    install_tool('gosec', GOSEC_FAKE)
    base = repo.commit(GO_BASE)
    head = repo.commit({'m.go': 'package m\n\nfunc A() { _ = 1 }\n'})
    sig = signal(repo, base, head, ['m.go'])
    assert sig == {'value': True, 'evidence': 'gosec: G401 weak hash at m.go:3'}
    assert log.read_text().split() == ['-fmt=json', '-quiet', './...']


def test_a_gosec_finding_on_an_unchanged_line_leaves_it_false(
        repo, install_tool, monkeypatch, tmp_path_factory):
    fake_report(monkeypatch, tmp_path_factory, go_issue(3))
    install_tool('gosec', GOSEC_FAKE)
    base = repo.commit({**GO_BASE, 'm.go': 'package m\n\nfunc A() {}\n\nfunc B() {}\n'})
    head = repo.commit({'m.go': 'package m\n\nfunc A() {}\n\nfunc B() { _ = 1 }\n'})
    sig = signal(repo, base, head, ['m.go'])
    assert sig == {'value': False, 'evidence': 'gosec: 1 finding(s), none on a line this '
                                               'range added'}


def test_gosec_runs_in_each_changed_module_and_maps_paths_to_the_repository(
        repo, install_tool, monkeypatch, tmp_path_factory):
    fake_report(monkeypatch, tmp_path_factory, go_issue(1, '@ROOT@/s.go'))
    install_tool('gosec', GOSEC_FAKE)
    base = repo.commit({**GO_BASE, 'svc/go.mod': 'module example.com/svc\n',
                        'svc/s.go': 'package s\n'})
    head = repo.commit({'svc/s.go': 'package s // x\n'})
    sig = signal(repo, base, head, ['svc/s.go'])
    assert sig == {'value': True, 'evidence': 'gosec: G401 weak hash at svc/s.go:1'}


def test_an_unreadable_gosec_report_is_unmeasured(repo, install_tool, monkeypatch,
                                                  tmp_path_factory):
    fake_report(monkeypatch, tmp_path_factory)
    install_tool('gosec', GOSEC_FAKE)
    base = repo.commit(GO_BASE)
    head = repo.commit({'m.go': 'package m\n\nfunc A() { _ = 1 }\n'})
    sig = signal(repo, base, head, ['m.go'])
    assert sig == {'value': 'unmeasured', 'reason': 'gosec exited 2 without a readable report: '
                                                    'gosec failed'}


def test_a_gosec_failure_exit_is_unmeasured_even_with_a_report(
        repo, install_tool, monkeypatch, tmp_path_factory):
    fake_report(monkeypatch, tmp_path_factory, go_issue(3))
    install_tool('gosec', GOSEC_FAKE.replace('exit 1', 'exit 4'))
    base = repo.commit(GO_BASE)
    head = repo.commit({'m.go': 'package m\n\nfunc A() { _ = 1 }\n'})
    sig = signal(repo, base, head, ['m.go'])
    assert sig['value'] == 'unmeasured'
    assert sig['reason'].startswith('gosec exited 4')


BANDIT_FAKE = '''
echo "$@" >> "$TOOL_LOG"
cat "$TOOL_REPORT"
exit 1
'''


def py_issue(line):
    return json.dumps({'results': [{'filename': './a.py', 'issue_text': 'weak md5',
                                    'line_number': line, 'line_range': [line],
                                    'test_id': 'B324'}]})


def test_a_bandit_finding_on_an_added_line_is_a_security_pattern(
        repo, install_tool, monkeypatch, tmp_path_factory):
    log = fake_report(monkeypatch, tmp_path_factory, py_issue(2))
    install_tool('bandit', BANDIT_FAKE)
    base = repo.commit({'a.py': 'import hashlib\nx = 1\n', 'gone.py': 'y = 1\n'})
    head = repo.commit({'a.py': 'import hashlib\nx = hashlib.md5\n', 'gone.py': None})
    sig = signal(repo, base, head, ['a.py', 'gone.py'])
    assert sig == {'value': True, 'evidence': 'bandit: B324 weak md5 at a.py:2'}
    assert log.read_text().split() == ['-q', '-f', 'json', '--', 'a.py']


def test_a_bandit_finding_on_an_unchanged_line_leaves_it_false(
        repo, install_tool, monkeypatch, tmp_path_factory):
    fake_report(monkeypatch, tmp_path_factory, py_issue(1))
    install_tool('bandit', BANDIT_FAKE)
    base = repo.commit({'a.py': 'import hashlib\nx = 1\n'})
    head = repo.commit({'a.py': 'import hashlib\nx = 2\n'})
    sig = signal(repo, base, head, ['a.py'])
    assert sig['value'] is False


def test_python_files_all_deleted_leave_nothing_to_scan(repo, install_tool, monkeypatch,
                                                        tmp_path_factory):
    log = fake_report(monkeypatch, tmp_path_factory, py_issue(1))
    install_tool('bandit', BANDIT_FAKE)
    base = repo.commit({'a.py': 'x = 1\n', 'keep.md': 'k\n'})
    head = repo.commit({'a.py': None})
    sig = signal(repo, base, head, ['a.py'])
    assert sig == {'value': False, 'evidence': 'bandit: no changed Python file exists at the '
                                               'head revision'}
    assert not log.exists()


OPENGREP_FAKE = '''
echo "$@" >> "$TOOL_LOG"
cat "$TOOL_REPORT"
exit 0
'''


def php_issue(line):
    return json.dumps({'results': [{'check_id': 'touchstone-php-eval', 'path': 'a.php',
                                    'start': {'line': line}, 'end': {'line': line}}]})


def test_an_opengrep_finding_on_an_added_line_is_a_security_pattern(
        repo, install_tool, monkeypatch, tmp_path_factory):
    log = fake_report(monkeypatch, tmp_path_factory, php_issue(3))
    install_tool('opengrep', OPENGREP_FAKE)
    base = repo.commit({'a.php': '<?php\nfunction f($c) {\n    return 1;\n}\n'})
    head = repo.commit({'a.php': '<?php\nfunction f($c) {\n    return eval($c);\n}\n'})
    sig = signal(repo, base, head, ['a.php'])
    assert sig == {'value': True, 'evidence': 'opengrep: touchstone-php-eval at a.php:3'}
    args = log.read_text().split()
    assert args[:5] == ['scan', '--json', '--quiet', '--config', risk_security.PHP_RULES]
    assert args[5:] == ['a.php']


def test_an_opengrep_finding_on_an_unchanged_line_leaves_it_false(
        repo, install_tool, monkeypatch, tmp_path_factory):
    fake_report(monkeypatch, tmp_path_factory, php_issue(2))
    install_tool('opengrep', OPENGREP_FAKE)
    base = repo.commit({'a.php': '<?php\nfunction f($c) {\n    return 1;\n}\n'})
    head = repo.commit({'a.php': '<?php\nfunction f($c) {\n    return 2;\n}\n'})
    assert signal(repo, base, head, ['a.php'])['value'] is False


def test_the_shipped_php_rules_file_exists():
    assert os.path.isfile(risk_security.PHP_RULES)


def test_each_missing_tool_is_unmeasured_and_named(repo, hide_tool):
    hide_tool('gosec', 'bandit', 'opengrep')
    base = repo.commit({'go.mod': 'module m\n', 'a.go': 'package a\n', 'b.py': 'x = 1\n',
                        'c.php': '<?php\n'})
    head = repo.commit({'a.go': 'package a // x\n', 'b.py': 'x = 2\n', 'c.php': '<?php // x\n'})
    sig = signal(repo, base, head, ['a.go'])
    assert sig == {'value': 'unmeasured', 'reason': 'gosec is not on PATH'}
    assert signal(repo, base, head, ['b.py'])['reason'] == 'bandit is not on PATH'
    assert signal(repo, base, head, ['c.php'])['reason'] == 'opengrep is not on PATH'


def test_a_language_no_tool_supports_is_unmeasured(repo):
    base = repo.commit({'web/app.js': 'x\n'})
    head = repo.commit({'web/app.js': 'y\n'})
    assert signal(repo, base, head, ['web/app.js']) == {
        'value': 'unmeasured',
        'reason': 'no security tool supports .js files (e.g. web/app.js)'}


def test_a_diff_with_no_source_file_is_false_with_that_evidence(repo):
    base = repo.commit({'README.md': 'a\n'})
    head = repo.commit({'README.md': 'b\n'})
    assert signal(repo, base, head, ['README.md']) == {
        'value': False, 'evidence': 'no source files changed'}
