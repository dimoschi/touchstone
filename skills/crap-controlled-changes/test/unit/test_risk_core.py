import risk_core


def test_truncate_keeps_short_text_and_caps_long_text_at_the_limit():
    assert risk_core.truncate('abc') == 'abc'
    assert risk_core.truncate('x' * 400) == 'x' * 400
    cut = risk_core.truncate('x' * 401)
    assert len(cut) == 400
    assert cut.endswith('...')


def test_measured_and_unmeasured_shapes():
    assert risk_core.measured(3, 'three') == {'value': 3, 'evidence': 'three'}
    assert risk_core.unmeasured('no tool') == {'value': 'unmeasured', 'reason': 'no tool'}
    assert len(risk_core.measured(True, 'e' * 900)['evidence']) == 400
    assert len(risk_core.unmeasured('r' * 900)['reason']) == 400


DIFF = (
    'diff --git a/a.py b/a.py\n'
    '--- a/a.py\n'
    '+++ b/a.py\n'
    '@@ -2 +2 @@\n'
    '-old\n'
    '+new\n'
    '@@ -9,0 +10,2 @@\n'
    '+x\n'
    '+y\n'
    '@@ -20,3 +23,0 @@\n'
    '-gone\n'
    '@@ -30,0 +31 @@\n'
    '+++ b/fake\n'
    'diff --git a/b.py b/b.py\n'
    'deleted file mode 100644\n'
    '--- a/b.py\n'
    '+++ /dev/null\n'
    '@@ -1,2 +0,0 @@\n'
    '-q\n'
    'diff --git a/new.go b/new.go\n'
    '--- /dev/null\n'
    '+++ b/new.go\n'
    '@@ -0,0 +1,3 @@\n'
    '+a\n'
)


def test_added_lines_reads_new_side_spans_from_hunk_headers():
    assert risk_core.added_lines(DIFF) == {'a.py': {2, 10, 11, 31}, 'new.go': {1, 2, 3}}


def test_added_lines_of_empty_diff_is_empty():
    assert risk_core.added_lines('') == {}


def test_removed_lines_reads_old_side_spans_from_hunk_headers():
    assert risk_core.removed_lines(DIFF) == {'a.py': {2, 20, 21, 22}, 'new.go': set()}


def test_removed_lines_of_empty_diff_is_empty():
    assert risk_core.removed_lines('') == {}


def test_gap_lines_are_the_new_side_line_each_pure_deletion_follows():
    assert risk_core.gap_lines(DIFF) == {'a.py': {23}, 'new.go': set()}
    assert risk_core.gap_lines(header_diff('+++ b/x').replace('@@ -1 +1 @@', '@@ -1 +0,0 @@')) == {
        'x': set()}


def header_diff(header):
    return f'diff --git a/x b/x\n--- a/x\n{header}\n@@ -1 +1 @@\n-a\n+b\n'


def test_added_lines_reads_a_path_git_quotes_back_to_the_real_name():
    for header, name in (('+++ "b/caf\\303\\251.py"', 'café.py'),
                         ('+++ "b/a\\"b.py"', 'a"b.py'),
                         ('+++ "b/back\\\\slash.py"', 'back\\slash.py'),
                         ('+++ "b/tab\\there.py"', 'tab\there.py')):
        assert risk_core.added_lines(header_diff(header)) == {name: {1}}, header


def test_added_lines_drops_the_tab_git_appends_to_a_path_holding_a_space():
    assert risk_core.added_lines(header_diff('+++ b/my file.py\t')) == {'my file.py': {1}}


def test_added_lines_ignores_a_hunk_header_it_cannot_read():
    assert risk_core.added_lines('diff --git a/x b/x\n+++ b/x\n@@ nonsense @@\n') == {'x': set()}


def test_language_of_maps_source_extensions():
    assert risk_core.language_of('cmd/main.go') == 'go'
    assert risk_core.language_of('pkg/mod.py') == 'python'
    assert risk_core.language_of('src/A.php') == 'php'


def test_language_of_gives_no_language_to_non_source_files():
    for path in ('README.md', 'a/b.json', 'c.yaml', 'c.yml', 'x.toml', 'go.sum.lock', 'LICENSE',
                 'logo.PNG', 'notes.txt', 'doc.rst', 'doc.adoc', 'a.ini', 'a.cfg', 'a.csv'):
        assert risk_core.language_of(path) is None, path


def test_language_of_marks_every_other_file_as_an_unsupported_extension():
    assert risk_core.language_of('web/app.js') == 'other:.js'
    assert risk_core.language_of('run.sh') == 'other:.sh'
    assert risk_core.language_of('Makefile') == 'other:Makefile'


def test_language_name_is_the_extension_for_an_unsupported_language():
    assert risk_core.language_name('other:.js') == '.js'
    assert risk_core.language_name('other:Makefile') == 'Makefile'
    assert risk_core.language_name('python') == 'python'


def test_by_language_does_not_assume_a_config_file_harmless():
    paths = ['deploy.yaml', 'ci/build.yml', 'cfg/app.json', 'pyproject.toml', 'setup.cfg',
             'tox.ini', 'poetry.lock', 'README.md']
    assert risk_core.by_language(paths) == {
        'other:.yaml': ['deploy.yaml'], 'other:.yml': ['ci/build.yml'],
        'other:.json': ['cfg/app.json'], 'other:.toml': ['pyproject.toml'],
        'other:.cfg': ['setup.cfg'], 'other:.ini': ['tox.ini'], 'other:.lock': ['poetry.lock']}


def test_by_language_reads_a_config_extension_in_any_case():
    assert risk_core.by_language(['DEPLOY.YAML']) == {'other:.yaml': ['DEPLOY.YAML']}


def test_by_language_groups_source_paths_and_drops_files_with_no_language():
    assert risk_core.by_language(['a.go', 'README.md', 'b.go', 'c.py', 'd.js']) == {
        'go': ['a.go', 'b.go'], 'python': ['c.py'], 'other:.js': ['d.js']}


def test_combine_any_is_true_when_any_part_is_true():
    parts = [risk_core.measured(False, 'a clean'), risk_core.unmeasured('b unknown'),
             risk_core.measured(True, 'c broke')]
    assert risk_core.combine_any(parts, 'none') == {'value': True, 'evidence': 'c broke'}


def test_combine_any_is_unmeasured_when_nothing_is_true_but_something_is_unknown():
    parts = [risk_core.measured(False, 'a clean'), risk_core.unmeasured('b unknown'),
             risk_core.unmeasured('d unknown')]
    assert risk_core.combine_any(parts, 'none') == {
        'value': 'unmeasured', 'reason': 'b unknown; d unknown'}


def test_combine_any_is_false_when_every_part_is_false():
    parts = [risk_core.measured(False, 'a clean'), risk_core.measured(False, 'b clean')]
    assert risk_core.combine_any(parts, 'none') == {
        'value': False, 'evidence': 'a clean; b clean'}


def test_combining_says_each_distinct_reason_once():
    parts = [risk_core.unmeasured('apidiff is not on PATH'),
             risk_core.unmeasured('apidiff is not on PATH'),
             risk_core.unmeasured('griffe is not on PATH')]
    assert risk_core.combine_any(parts, 'none')['reason'] == (
        'apidiff is not on PATH; griffe is not on PATH')


def test_combine_any_of_no_parts_is_false_with_the_given_evidence():
    assert risk_core.combine_any([], 'no source files changed') == {
        'value': False, 'evidence': 'no source files changed'}


def test_combine_all_is_false_when_any_part_is_false_even_if_another_is_unknown():
    parts = [risk_core.measured(True, 'a same'), risk_core.unmeasured('b unknown'),
             risk_core.measured(False, 'c differs')]
    assert risk_core.combine_all(parts, 'none') == {'value': False, 'evidence': 'c differs'}


def test_combine_all_is_unmeasured_when_nothing_is_false_but_something_is_unknown():
    parts = [risk_core.measured(True, 'a same'), risk_core.unmeasured('b unknown')]
    assert risk_core.combine_all(parts, 'none') == {'value': 'unmeasured', 'reason': 'b unknown'}


def test_combine_all_is_true_when_every_part_is_true():
    parts = [risk_core.measured(True, 'a same'), risk_core.measured(True, 'b same')]
    assert risk_core.combine_all(parts, 'none') == {'value': True, 'evidence': 'a same; b same'}


def test_combine_all_of_no_parts_is_false_with_the_given_evidence():
    assert risk_core.combine_all([], 'no source files changed') == {
        'value': False, 'evidence': 'no source files changed'}
