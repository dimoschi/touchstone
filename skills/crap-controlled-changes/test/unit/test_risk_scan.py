import os

import risk_core
import risk_scan


def test_no_source_files_is_false_with_that_evidence(repo):
    head = repo.commit({'README.md': 'x\n'})
    assert risk_scan.scan_head({}, 'tool', str(repo.path), head, {}, {}) == {
        'value': False, 'evidence': 'no source files changed'}


def test_a_handler_gets_the_head_tree_its_paths_and_the_added_lines(repo):
    head = repo.commit({'a.go': 'package a\n'})
    seen = {}

    def handler(head_root, paths, added):
        seen['file'] = open(os.path.join(head_root, 'a.go')).read()
        seen['paths'], seen['added'] = paths, added
        return risk_core.measured(True, 'found')

    sig = risk_scan.scan_head({'go': handler}, 'tool', str(repo.path), head,
                              {'go': ['a.go']}, {'a.go': {1}})
    assert sig == {'value': True, 'evidence': 'found'}
    assert seen == {'file': 'package a\n', 'paths': ['a.go'], 'added': {'a.go': {1}}}


def test_a_language_without_a_handler_is_unmeasured_naming_the_kind_of_tool(repo):
    head = repo.commit({'a.py': 'x = 1\n', 'web/app.js': 'x\n'})
    groups = {'python': ['a.py'], 'other:.js': ['web/app.js']}
    sig = risk_scan.scan_head({}, 'security tool', str(repo.path), head, groups, {})
    assert sig == {'value': 'unmeasured', 'reason': 'no security tool supports .js files '
                                                    '(e.g. web/app.js); no security tool '
                                                    'supports python files (e.g. a.py)'}


def test_languages_combine_so_one_finding_wins(repo):
    head = repo.commit({'a.go': 'x\n', 'b.py': 'y\n'})
    handlers = {'go': lambda *_: risk_core.measured(False, 'go clean'),
                'python': lambda *_: risk_core.measured(True, 'python found')}
    sig = risk_scan.scan_head(handlers, 'tool', str(repo.path), head,
                              {'go': ['a.go'], 'python': ['b.py']}, {})
    assert sig == {'value': True, 'evidence': 'python found'}


def test_the_head_tree_is_unpacked_in_a_temporary_directory_removed_afterwards(repo):
    import tempfile
    head = repo.commit({'a.go': 'package a\n'})
    seen = []

    def handler(head_root, paths, added):
        seen.append(head_root)
        return risk_core.measured(False, 'ok')

    risk_scan.scan_head({'go': handler}, 'tool', str(repo.path), head, {'go': ['a.go']}, {})
    assert os.path.dirname(seen[0]) != tempfile.gettempdir()
    assert not os.path.exists(seen[0])
