import os
import subprocess

import risk_noop

# Mimics `difft --check-only --exit-code --ignore-comments <old> <new>`: comment
# lines are ignored, any other difference exits 1, a path named boom fails.
FAKE_DIFFT = '''
echo "$@" >> "$DIFFT_LOG"
case "$4" in *boom*) echo 'difft exploded' >&2; exit 2;; esac
if [ "$(grep -v '^//' "$4")" = "$(grep -v '^//' "$5")" ]; then exit 0; fi
exit 1
'''


def with_difft(install_tool, monkeypatch, tmp_path_factory):
    log = tmp_path_factory.mktemp('difft-log') / 'calls'
    monkeypatch.setenv('DIFFT_LOG', str(log))
    install_tool('difft', FAKE_DIFFT)
    return log


def test_name_status_reads_added_modified_and_deleted_paths(repo):
    base = repo.commit({'a.py': '1\n', 'b.py': '2\n'})
    head = repo.commit({'a.py': '1\n3\n', 'b.py': None, 'c.py': '4\n'})
    assert risk_noop.name_status(str(repo.path), f'{base}..{head}') == {
        'a.py': 'M', 'b.py': 'D', 'c.py': 'A'}


def test_comment_only_change_is_a_semantic_noop(repo, install_tool, monkeypatch, tmp_path_factory):
    log = with_difft(install_tool, monkeypatch, tmp_path_factory)
    base = repo.commit({'a.go': 'package a\nfunc A() {}\n'})
    head = repo.commit({'a.go': '// explains\npackage a\nfunc A() {}\n'})
    sig = risk_noop.semantic_noop_signal(str(repo.path), base, head, {'a.go': 'M'})
    assert sig == {'value': True, 'evidence': 'difft: no syntactic change in a.go'}
    flags = log.read_text().split()[:3]
    assert flags == ['--check-only', '--exit-code', '--ignore-comments']


def test_a_real_change_is_not_a_noop(repo, install_tool, monkeypatch, tmp_path_factory):
    with_difft(install_tool, monkeypatch, tmp_path_factory)
    base = repo.commit({'a.go': 'package a\nfunc A() {}\n'})
    head = repo.commit({'a.go': 'package a\nfunc B() {}\n'})
    sig = risk_noop.semantic_noop_signal(str(repo.path), base, head, {'a.go': 'M'})
    assert sig == {'value': False, 'evidence': 'difft: syntactic change in a.go'}


def test_difft_gets_the_base_and_head_contents_as_files(repo, install_tool, monkeypatch,
                                                       tmp_path_factory):
    install_tool('difft', 'cat "$4" > "$DIFFT_OLD"; cat "$5" > "$DIFFT_NEW"; exit 0\n')
    out = tmp_path_factory.mktemp('difft-out')
    monkeypatch.setenv('DIFFT_OLD', str(out / 'old'))
    monkeypatch.setenv('DIFFT_NEW', str(out / 'new'))
    base = repo.commit({'pkg/a.php': 'old body\n'})
    head = repo.commit({'pkg/a.php': 'new body\n'})
    risk_noop.semantic_noop_signal(str(repo.path), base, head, {'pkg/a.php': 'M'})
    assert (out / 'old').read_text() == 'old body\n'
    assert (out / 'new').read_text() == 'new body\n'


def test_an_added_or_deleted_file_is_not_a_noop_even_without_difft(repo, hide_tool):
    hide_tool('difft')
    base = repo.commit({'keep.go': 'package k\n', 'gone.go': 'package g\n'})
    head = repo.commit({'gone.go': None, 'new.go': 'package n\n'})
    statuses = {'gone.go': 'D', 'new.go': 'A'}
    sig = risk_noop.semantic_noop_signal(str(repo.path), base, head, statuses)
    assert sig['value'] is False
    assert 'gone.go is not a modification (git status D)' in sig['evidence']
    assert 'new.go is not a modification (git status A)' in sig['evidence']


def test_a_diff_with_no_source_file_is_false_with_that_evidence(repo):
    base = repo.commit({'README.md': 'a\n'})
    head = repo.commit({'README.md': 'b\n', 'cfg.json': '{}\n'})
    sig = risk_noop.semantic_noop_signal(
        str(repo.path), base, head, {'README.md': 'M', 'cfg.json': 'A'})
    assert sig == {'value': False, 'evidence': 'no source files changed'}


def test_a_language_no_tool_supports_is_unmeasured(repo, install_tool, monkeypatch,
                                                  tmp_path_factory):
    with_difft(install_tool, monkeypatch, tmp_path_factory)
    base = repo.commit({'a.go': 'package a\n', 'web/app.js': 'x\n'})
    head = repo.commit({'a.go': '// c\npackage a\n', 'web/app.js': 'y\n'})
    sig = risk_noop.semantic_noop_signal(
        str(repo.path), base, head, {'a.go': 'M', 'web/app.js': 'M'})
    assert sig['value'] == 'unmeasured'
    assert sig['reason'] == 'no semantic tool supports .js files (e.g. web/app.js)'


def test_a_real_change_outweighs_an_unsupported_language(repo, install_tool, monkeypatch,
                                                         tmp_path_factory):
    with_difft(install_tool, monkeypatch, tmp_path_factory)
    base = repo.commit({'a.go': 'package a\n', 'web/app.js': 'x\n'})
    head = repo.commit({'a.go': 'package b\n', 'web/app.js': 'y\n'})
    sig = risk_noop.semantic_noop_signal(
        str(repo.path), base, head, {'a.go': 'M', 'web/app.js': 'M'})
    assert sig['value'] is False


def test_missing_difft_is_unmeasured_and_named(repo, hide_tool):
    hide_tool('difft')
    base = repo.commit({'a.go': 'package a\n'})
    head = repo.commit({'a.go': '// c\npackage a\n'})
    sig = risk_noop.semantic_noop_signal(str(repo.path), base, head, {'a.go': 'M'})
    assert sig == {'value': 'unmeasured', 'reason': 'difft is not on PATH'}


def test_a_difft_failure_is_unmeasured_with_its_message(repo, install_tool, monkeypatch,
                                                       tmp_path_factory):
    with_difft(install_tool, monkeypatch, tmp_path_factory)
    base = repo.commit({'boom.go': 'package a\n'})
    head = repo.commit({'boom.go': '// c\npackage a\n'})
    sig = risk_noop.semantic_noop_signal(str(repo.path), base, head, {'boom.go': 'M'})
    assert sig['value'] == 'unmeasured'
    assert sig['reason'].startswith('difft exited 2 on boom.go: difft exploded')


def test_name_status_lists_a_rename_as_a_delete_and_an_add(repo):
    base = repo.commit({'old.py': 'same content here\nmore\n'})
    (repo.path / 'old.py').rename(repo.path / 'new.py')
    head = repo.commit({})
    assert risk_noop.name_status(str(repo.path), f'{base}..{head}') == {
        'old.py': 'D', 'new.py': 'A'}


def test_name_status_tolerates_a_path_that_is_not_utf8(monkeypatch):
    done = subprocess.CompletedProcess([], 0, b'M\0caf\xff.py\0', b'')
    monkeypatch.setattr(risk_noop, 'git', lambda *a: done)
    assert risk_noop.name_status('/r', 'a..b') == {'caf\ufffd.py': 'M'}


def test_write_revision_writes_nested_files_and_reuses_a_directory(repo, tmp_path):
    rev = repo.commit({'pkg/a.py': 'a\n', 'pkg/b.py': 'b\n'})
    for name in ('a', 'b'):
        risk_noop.write_revision(str(repo.path), rev, f'pkg/{name}.py',
                                 str(tmp_path / 'out' / 'pkg' / f'{name}.py'))
    assert (tmp_path / 'out' / 'pkg' / 'a.py').read_bytes() == b'a\n'
    assert (tmp_path / 'out' / 'pkg' / 'b.py').read_bytes() == b'b\n'


def test_write_revision_writes_an_empty_file_for_a_path_the_revision_lacks(repo, tmp_path):
    rev = repo.commit({'a.py': 'a\n'})
    dest = tmp_path / 'x' / 'gone.py'
    risk_noop.write_revision(str(repo.path), rev, 'gone.py', str(dest))
    assert dest.read_bytes() == b''


def test_difft_verdict_is_true_for_exit_0_with_the_path_as_evidence():
    done = subprocess.CompletedProcess([], 0, '', '')
    assert risk_noop.difft_verdict(done, 'a.go') == {
        'value': True, 'evidence': 'difft: no syntactic change in a.go'}


def test_difft_compares_the_base_and_head_copies_under_the_temporary_directory(
        repo, install_tool, monkeypatch, tmp_path_factory, tmp_path):
    elsewhere = tmp_path_factory.mktemp('cwd')
    log = with_difft(install_tool, monkeypatch, tmp_path_factory)
    base = repo.commit({'a.go': 'package a\n'})
    head = repo.commit({'a.go': '// c\npackage a\n'})
    work = tmp_path / 'work'
    work.mkdir()
    monkeypatch.chdir(elsewhere)
    risk_noop.difft_part(str(repo.path), base, head, 'a.go', str(work))
    assert log.read_text().split()[3:] == [str(work / 'base' / 'a.go'),
                                           str(work / 'head' / 'a.go')]
    assert os.listdir(elsewhere) == []
