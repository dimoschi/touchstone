"""Unit tests for assertion_discrimination.py.

The records come from what a suite prints, so the parser is exercised
against output lines shaped like the real suites'. `find_reports` runs
against a throwaway scratch git repo, since git archive and a real suite run
are the whole point of it; the same orchestration replayed against this
repo's own history (the ranges the ticket cites) lives in
scripts/test-assertion-discrimination.sh.
"""

from __future__ import annotations

import subprocess

from assertion_discrimination import Record, candidates_of, records_of, surviving


def test_records_of_reads_ok_and_fail_lines_under_their_header():
    out = (
        '== scenario A: first\n'
        '  ok:   halted at Worktree ("Worktree")\n'
        '  FAIL: the note names the branch (got false, want true)\n'
        '\n'
        '== scenario B: second\n'
        '  ok:   halted at Worktree ("Worktree")\n'
    )
    assert records_of('workflows/tests/test-x.sh', out) == [
        Record('workflows/tests/test-x.sh', '== scenario A: first', 'halted at Worktree', 1, True),
        Record('workflows/tests/test-x.sh', '== scenario A: first', 'the note names the branch', 1, False),
        Record('workflows/tests/test-x.sh', '== scenario B: second', 'halted at Worktree', 1, True),
    ]


def test_records_of_gives_the_same_identity_to_a_passing_and_a_failing_line():
    passing = records_of('f', '== h\n  ok:   carries the full ticket (problem section) (true)\n')
    failing = records_of('f', '== h\n  FAIL: carries the full ticket (problem section) (got false, want true)\n')
    assert passing[0].key == failing[0].key


def test_records_of_numbers_a_repeated_label_within_one_header():
    out = '== h\n  ok:   step ran (1)\n  ok:   step ran (2)\n== g\n  ok:   step ran (3)\n'
    assert [(r.header, r.n) for r in records_of('f', out)] == [('== h', 1), ('== h', 2), ('== g', 1)]


def test_records_of_ignores_an_aborted_line_and_other_output():
    out = '== h\n  ABORTED: scenarioX: boom\nsome log line\n  ok:   real (true)\nOK\n'
    assert [r.label for r in records_of('f', out)] == ['real']


def test_records_of_leaves_the_header_none_before_any_header():
    assert records_of('f', '  ok:   early (true)\n')[0].header is None


def test_candidates_of_are_passing_head_records_absent_from_base():
    base = [Record('a.sh', '== h', 'old', 1, True)]
    head = [Record('a.sh', '== h', 'old', 1, True),
            Record('a.sh', '== h', 'new', 1, True),
            Record('a.sh', '== h', 'new but failing', 1, False)]
    assert [r.label for r in candidates_of(base, head)] == ['new']


def test_candidates_of_treats_a_record_moved_to_another_file_as_not_new():
    base = [Record('old-file.sh', '== h', 'moved', 1, True)]
    head = [Record('new-file.sh', '== h', 'moved', 1, True)]
    assert candidates_of(base, head) == []


def test_surviving_drops_a_candidate_the_counterfactual_failed():
    pending = [Record('a.sh', '== h', 'guarded', 1, True), Record('a.sh', '== h', 'vacuous', 1, True)]
    run = [Record('a.sh', '== h', 'guarded', 1, False), Record('a.sh', '== h', 'vacuous', 1, True)]
    assert [r.label for r in surviving(pending, run)] == ['vacuous']


def test_surviving_keeps_a_candidate_missing_from_the_counterfactual_run():
    """A scenario that threw before reaching an assertion is not evidence that
    the assertion discriminates."""
    pending = [Record('a.sh', '== h', 'unreached', 1, True)]
    assert surviving(pending, []) == pending


def test_find_reports_does_not_report_a_moved_scenario(tmp_path):
    from assertion_discrimination import find_reports

    _init_scratch_repo(tmp_path)
    (tmp_path / 'workflows' / 'tests').mkdir(parents=True)
    (tmp_path / 'workflows' / 'deliver-pipeline.js').write_text("const NOTE = 'ok'\n")
    check_line = 'echo "== static: NOTE"\ncheck "NOTE is present" "$(grep -c \'NOTE\' "$SCRIPT" || true)" 1'
    (tmp_path / 'workflows' / 'tests' / 'test-a.sh').write_text(_SUITE_TEMPLATE.format(checks=check_line))
    base = _commit_all(tmp_path, 'base: the check lives in test-a.sh')

    (tmp_path / 'workflows' / 'tests' / 'test-a.sh').unlink()
    (tmp_path / 'workflows' / 'tests' / 'test-b.sh').write_text(_SUITE_TEMPLATE.format(checks=check_line))
    (tmp_path / 'workflows' / 'deliver-pipeline.js').write_text("const NOTE = 'ok'\nconst MORE = 'x'\n")
    head = _commit_all(tmp_path, 'head: the same check, moved to test-b.sh')

    assert find_reports(str(tmp_path), base, head) == []


def test_added_lines_reads_pure_additions_from_a_unified_diff():
    from assertion_discrimination import added_lines
    diff = (
        "diff --git a/f b/f\n"
        "index 111..222 100644\n"
        "--- a/f\n"
        "+++ b/f\n"
        "@@ -2,0 +3,2 @@ some context\n"
        "+first added line\n"
        "+second added line\n"
        "@@ -10 +12 @@ some other context\n"
        "-old line\n"
        "+new line\n"
    )
    assert added_lines(diff) == [3, 4, 12]


def test_line_blank_string_mutants_blanks_each_literal_on_the_line():
    from assertion_discrimination import line_blank_string_mutants
    content = "x\nconst s = 'Re-run without existingBranch to cut one'\ny\n"
    mutants = line_blank_string_mutants(content, 2)
    assert len(mutants) == 1
    assert mutants[0] == "x\nconst s = ''\ny\n"


def test_line_blank_string_mutants_skips_an_already_empty_literal():
    from assertion_discrimination import line_blank_string_mutants
    content = "const s = ''\n"
    assert line_blank_string_mutants(content, 1) == []


def test_line_blank_string_mutants_skips_an_equality_comparison_operand():
    # gh-96: blanking a string used as a `===`/`!==` operand reroutes which
    # branch of a conditional runs, the same collateral-damage risk a
    # whole-line deletion mutant carries -- not a text change the assertion
    # under test claims to depend on.
    from assertion_discrimination import line_blank_string_mutants
    content = "  : halt_reason === 'ambiguous'\n"
    assert line_blank_string_mutants(content, 1) == []


def test_line_blank_string_mutants_skips_an_inequality_comparison_operand():
    from assertion_discrimination import line_blank_string_mutants
    content = "  : halt_reason !== 'ambiguous'\n"
    assert line_blank_string_mutants(content, 1) == []


def test_line_blank_string_mutants_still_blanks_a_non_comparison_literal_on_a_comparison_line():
    from assertion_discrimination import line_blank_string_mutants
    content = "  check('label', halt_reason === 'ambiguous', true)\n"
    mutants = line_blank_string_mutants(content, 1)
    assert mutants == ["  check('', halt_reason === 'ambiguous', true)\n"]


def _init_scratch_repo(path):
    subprocess.run(['git', 'init', '-q', str(path)], check=True)
    subprocess.run(['git', '-C', str(path), 'config', 'user.email', 't@t'], check=True)
    subprocess.run(['git', '-C', str(path), 'config', 'user.name', 'test'], check=True)
    subprocess.run(['git', '-C', str(path), 'config', 'commit.gpgsign', 'false'], check=True)


def _commit_all(path, message):
    subprocess.run(['git', '-C', str(path), 'add', '-A'], check=True)
    subprocess.run(['git', '-C', str(path), 'commit', '-q', '-m', message], check=True)
    return subprocess.run(['git', '-C', str(path), 'rev-parse', 'HEAD'],
                           capture_output=True, text=True, check=True).stdout.strip()


_SUITE_TEMPLATE = '''#!/usr/bin/env bash
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${{BASH_SOURCE[0]}}")/../.." && pwd)"
SCRIPT="$REPO_ROOT/workflows/deliver-pipeline.js"
failures=0
check() {{
  local label="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then
    echo "  ok:   $label ($got)"
  else
    echo "  FAIL: $label (got $got, want $want)"
    failures=$((failures + 1))
  fi
}}
{checks}
echo ""
if [ "$failures" -eq 0 ]; then echo OK; exit 0; else echo "FAILED: $failures"; exit 1; fi
'''


def test_find_reports_flags_a_check_no_version_of_the_script_could_ever_fail(tmp_path):
    from assertion_discrimination import find_reports

    _init_scratch_repo(tmp_path)
    (tmp_path / 'workflows' / 'tests').mkdir(parents=True)
    (tmp_path / 'workflows' / 'deliver-pipeline.js').write_text("const NOTE = 'ok'\n")
    (tmp_path / 'workflows' / 'tests' / 'test-static.sh').write_text(_SUITE_TEMPLATE.format(
        checks='check "a pre-existing check" "$(grep -c \'NOTE\' "$SCRIPT" || true)" 1'
    ))
    base = _commit_all(tmp_path, 'base: before either new check')

    (tmp_path / 'workflows' / 'deliver-pipeline.js').write_text("const NOTE = 'ok'\nconst GOOD = 'GOOD_TOKEN'\n")
    (tmp_path / 'workflows' / 'tests' / 'test-static.sh').write_text(_SUITE_TEMPLATE.format(
        checks='check "a pre-existing check" "$(grep -c \'NOTE\' "$SCRIPT" || true)" 1\n'
               'check "no NEVER_WRITTEN reference remains" '
               '"$(grep -c \'NEVER_WRITTEN\' "$SCRIPT" || true)" 0\n'
               'check "GOOD_TOKEN is present" "$(grep -c \'GOOD_TOKEN\' "$SCRIPT" || true)" 1'
    ))
    head = _commit_all(tmp_path, 'head: add a real, discriminating check alongside it')

    reports = find_reports(str(tmp_path), base, head)
    labels = {r.label for r in reports}
    assert 'a pre-existing check' not in labels
    assert 'GOOD_TOKEN is present' not in labels
    assert 'no NEVER_WRITTEN reference remains' in labels
    only = [r for r in reports if r.label == 'no NEVER_WRITTEN reference remains'][0]
    assert only.file == 'workflows/tests/test-static.sh'


def test_find_reports_does_not_flag_a_production_dependent_check_in_a_test_only_change(tmp_path):
    """gh-96: deliver-pipeline.js is untouched, so a revert is a no-op and
    there are no added lines to mutate -- no evidence exists either way for a
    check whose outcome could depend on production, so it must not be
    reported just because none was found."""
    from assertion_discrimination import find_reports

    _init_scratch_repo(tmp_path)
    (tmp_path / 'workflows' / 'tests').mkdir(parents=True)
    (tmp_path / 'workflows' / 'deliver-pipeline.js').write_text("const NOTE = 'ok'\n")
    (tmp_path / 'workflows' / 'tests' / 'test-static.sh').write_text(_SUITE_TEMPLATE.format(
        checks='check "a pre-existing check" "$(grep -c \'NOTE\' "$SCRIPT" || true)" 1'
    ))
    base = _commit_all(tmp_path, 'base: before the new coverage')

    (tmp_path / 'workflows' / 'tests' / 'test-static.sh').write_text(_SUITE_TEMPLATE.format(
        checks='check "a pre-existing check" "$(grep -c \'NOTE\' "$SCRIPT" || true)" 1\n'
               'check "NOTE also carries ok" "$(grep -c \'NOTE\' "$SCRIPT" || true)" 1'
    ))
    head = _commit_all(tmp_path, 'head: add coverage for existing behaviour, test-only')

    reports = find_reports(str(tmp_path), base, head)
    assert reports == []


def test_find_reports_falls_through_to_a_mutant_when_the_script_is_new_at_base(tmp_path):
    """gh-96's "presence guard saved by a mutant" rule: deliver-pipeline.js does
    not exist at base at all, so there is no revert to run; a presence check
    still has to be judged by mutating the one line that supports it."""
    from assertion_discrimination import find_reports

    _init_scratch_repo(tmp_path)
    (tmp_path / 'workflows' / 'tests').mkdir(parents=True)
    (tmp_path / 'README.md').write_text('placeholder\n')
    base = _commit_all(tmp_path, 'base: before deliver-pipeline.js exists at all')

    (tmp_path / 'workflows' / 'deliver-pipeline.js').write_text("const NOTE = 'ok'\nconst GOOD = 'GOOD_TOKEN'\n")
    (tmp_path / 'workflows' / 'tests' / 'test-static.sh').write_text(_SUITE_TEMPLATE.format(
        checks='check "GOOD_TOKEN is present" "$(grep -c \'GOOD_TOKEN\' "$SCRIPT" || true)" 1'
    ))
    head = _commit_all(tmp_path, 'head: the script and its first suite')

    reports = find_reports(str(tmp_path), base, head)
    assert reports == []


def test_find_reports_raises_when_a_suite_with_candidates_prints_no_records_at_head(tmp_path):
    from assertion_discrimination import find_reports, NoRecordsError

    _init_scratch_repo(tmp_path)
    (tmp_path / 'workflows' / 'tests').mkdir(parents=True)
    (tmp_path / 'workflows' / 'deliver-pipeline.js').write_text("const NOTE = 'ok'\n")
    (tmp_path / 'workflows' / 'tests' / 'test-static.sh').write_text(
        '#!/usr/bin/env bash\nexit 0\n'  # no harness sourced, no check() ever runs
    )
    base = _commit_all(tmp_path, 'base: an empty suite')

    # The new check is real source (so it is still a candidate), but an
    # unrelated setup failure before it means the run never reaches it.
    (tmp_path / 'workflows' / 'tests' / 'test-static.sh').write_text(
        _SUITE_TEMPLATE.format(checks='exit 3\ncheck "a brand new check" "$(grep -c \'NOTE\' "$SCRIPT" || true)" 1')
    )
    (tmp_path / 'workflows' / 'deliver-pipeline.js').write_text("const NOTE = 'ok'\nconst MORE = 'x'\n")
    head = _commit_all(tmp_path, 'head: the new check is unreachable behind a setup failure')

    import pytest
    with pytest.raises(NoRecordsError):
        find_reports(str(tmp_path), base, head)


def test_main_reports_lines_and_exits_1_when_something_is_found(monkeypatch, capsys):
    import assertion_discrimination as ad

    def fake_find_reports(repo, base, head):
        assert (repo, base, head) == ('.', 'base-sha', 'head-sha')
        return [ad.Report(file='workflows/tests/test-worktree-checks.sh',
                           header='== scenario BU', label='no reviewer finding was recorded',
                           reason='no counterfactual production script makes this assertion fail')]

    monkeypatch.setattr(ad, 'find_reports', fake_find_reports)
    rc = ad.main(['.', 'base-sha', 'head-sha'])
    out = capsys.readouterr().out
    assert rc == 1
    assert out.startswith('workflows/tests/test-worktree-checks.sh: [== scenario BU] ')
    assert 'no reviewer finding was recorded' in out


def test_main_exits_0_and_says_so_when_nothing_is_found(monkeypatch, capsys):
    import assertion_discrimination as ad
    monkeypatch.setattr(ad, 'find_reports', lambda repo, base, head: [])
    rc = ad.main(['.', 'base-sha', 'head-sha'])
    assert rc == 0
    assert 'no non-discriminating' in capsys.readouterr().out


def test_main_exits_4_on_no_records_error(monkeypatch, capsys):
    import assertion_discrimination as ad

    def raiser(repo, base, head):
        raise ad.NoRecordsError('workflows/tests/test-static.sh')

    monkeypatch.setattr(ad, 'find_reports', raiser)
    rc = ad.main(['.', 'base-sha', 'head-sha'])
    assert rc == 4
    assert 'test-static.sh' in capsys.readouterr().err


def test_main_exits_2_on_bad_usage():
    import assertion_discrimination as ad
    assert ad.main(['/repo', 'only-one-arg']) == 2


def test_main_exits_2_when_repo_path_is_not_a_directory():
    import assertion_discrimination as ad
    assert ad.main(['/no/such/path', 'base-sha', 'head-sha']) == 2


def test_added_lines_ignores_diff_header_noise_before_the_first_hunk():
    from assertion_discrimination import added_lines
    diff = (
        "diff --git a/f b/f\n"
        "new file mode 100644\n"
        "index 000..111\n"
        "--- /dev/null\n"
        "+++ b/f\n"
        "@@ -0,0 +1 @@\n"
        "+only line\n"
    )
    assert added_lines(diff) == [1]


def test_main_exits_2_when_find_reports_hits_a_runtime_error(monkeypatch, capsys):
    import assertion_discrimination as ad

    def raiser(repo, base, head):
        raise RuntimeError('archiving head from . failed')

    monkeypatch.setattr(ad, 'find_reports', raiser)
    rc = ad.main(['.', 'base-sha', 'head-sha'])
    assert rc == 2
    assert 'archiving head' in capsys.readouterr().err


def test_line_blank_string_mutants_keeps_scanning_past_an_already_empty_literal():
    from assertion_discrimination import line_blank_string_mutants
    assert len(line_blank_string_mutants("x = '' + 'real'\n", 1)) == 1


def test_line_blank_string_mutants_keeps_scanning_past_a_comparison_operand():
    from assertion_discrimination import line_blank_string_mutants
    assert len(line_blank_string_mutants("check(x === 'ambiguous', 'real')\n", 1)) == 1


def test_git_show_uses_the_exact_git_show_command(monkeypatch):
    import assertion_discrimination as ad
    calls = []

    class FakeProc:
        returncode = 0
        stdout = 'content\n'

    def fake_run(cmd, **kwargs):
        calls.append((cmd, kwargs))
        return FakeProc()

    monkeypatch.setattr(ad.subprocess, 'run', fake_run)
    result = ad.git_show('/repo', 'HEAD', 'a/b.txt')
    assert calls == [(['git', '-C', '/repo', 'show', 'HEAD:a/b.txt'],
                       {'capture_output': True, 'text': True})]
    assert result == 'content\n'


def test_git_show_returns_none_when_git_show_fails(monkeypatch):
    import assertion_discrimination as ad

    class FakeProc:
        returncode = 1
        stdout = 'should-be-ignored'

    monkeypatch.setattr(ad.subprocess, 'run', lambda *a, **k: FakeProc())
    assert ad.git_show('/repo', 'HEAD', 'missing.txt') is None


def test_list_suite_files_uses_the_exact_ls_tree_command(monkeypatch):
    import assertion_discrimination as ad
    calls = []

    class FakeProc:
        returncode = 0
        stdout = 'workflows/tests/test-a.sh\nREADME.md\n'

    def fake_run(cmd, **kwargs):
        calls.append((cmd, kwargs))
        return FakeProc()

    monkeypatch.setattr(ad.subprocess, 'run', fake_run)
    result = ad.list_suite_files('/repo', 'HEAD')
    assert calls == [(['git', '-C', '/repo', 'ls-tree', '-r', '--name-only', 'HEAD'],
                       {'capture_output': True, 'text': True, 'check': True})]
    assert result == ['workflows/tests/test-a.sh']


def test_archive_tree_uses_the_exact_git_archive_and_tar_commands(monkeypatch, tmp_path):
    import io
    import assertion_discrimination as ad
    calls = {}

    class FakePopen:
        def __init__(self, cmd, stdout=None):
            calls['popen_cmd'] = cmd
            self.stdout = io.BytesIO()

        def wait(self):
            return 0

    class FakeCompleted:
        returncode = 0
        stderr = ''

    def fake_run(cmd, **kwargs):
        calls['run_cmd'] = cmd
        calls['run_kwargs'] = kwargs
        return FakeCompleted()

    monkeypatch.setattr(ad.subprocess, 'Popen', FakePopen)
    monkeypatch.setattr(ad.subprocess, 'run', fake_run)
    dest = tmp_path / 'out'
    ad.archive_tree('/repo', 'HEAD', str(dest))
    assert calls['popen_cmd'] == ['git', '-C', '/repo', 'archive', 'HEAD']
    assert calls['run_cmd'] == ['tar', '-x', '-C', str(dest)]
    assert calls['run_kwargs']['capture_output'] is True
    assert calls['run_kwargs']['text'] is True


def test_archive_tree_raises_when_git_archive_fails_even_if_tar_exits_zero(tmp_path):
    from assertion_discrimination import archive_tree
    _init_scratch_repo(tmp_path)
    (tmp_path / 'a.txt').write_text('hi\n')
    _commit_all(tmp_path, 'seed')
    dest = tmp_path / 'out'
    import pytest
    with pytest.raises(RuntimeError) as exc_info:
        archive_tree(str(tmp_path), 'no-such-rev', str(dest))
    message = str(exc_info.value)
    assert 'no-such-rev' in message
    assert str(tmp_path) in message


def test_run_suite_uses_the_exact_bash_command(monkeypatch):
    import assertion_discrimination as ad
    calls = {}

    class FakeProc:
        returncode = 0
        stdout = 'out'
        stderr = 'err'

    def fake_run(cmd, **kwargs):
        calls['cmd'] = cmd
        calls['kwargs'] = kwargs
        return FakeProc()

    monkeypatch.setattr(ad.subprocess, 'run', fake_run)
    stdout, rc = ad.run_suite('/path/to/suite.sh')
    assert calls['cmd'] == ['bash', '/path/to/suite.sh']
    assert calls['kwargs'] == {'capture_output': True, 'text': True}
    assert stdout == 'outerr'
    assert rc == 0


def test_diff_added_lines_uses_the_exact_git_diff_command(monkeypatch):
    import assertion_discrimination as ad
    calls = {}

    class FakeProc:
        stdout = ''

    def fake_run(cmd, **kwargs):
        calls['cmd'] = cmd
        calls['kwargs'] = kwargs
        return FakeProc()

    monkeypatch.setattr(ad.subprocess, 'run', fake_run)
    ad.diff_added_lines('/repo', 'base', 'head', 'path/to/file.js')
    assert calls['cmd'] == ['git', '-C', '/repo', 'diff', '-U0', 'base', 'head', '--', 'path/to/file.js']
    assert calls['kwargs'] == {'capture_output': True, 'text': True}


def test_main_argv_default_slices_off_only_the_program_name(monkeypatch):
    import assertion_discrimination as ad
    monkeypatch.setattr(ad.sys, 'argv', ['prog', '.', 'BASE_A', 'HEAD_A'])
    captured = {}

    def fake_find_reports(repo, base, head):
        captured['args'] = (repo, base, head)
        return []

    monkeypatch.setattr(ad, 'find_reports', fake_find_reports)
    ad.main()
    assert captured['args'] == ('.', 'BASE_A', 'HEAD_A')


def test_main_prints_the_actual_usage_message_to_stderr_not_stdout(capsys):
    import assertion_discrimination as ad
    rc = ad.main(['only-one-arg'])
    assert rc == 2
    out = capsys.readouterr()
    assert 'usage:' in out.err
    assert 'usage:' not in out.out


def test_main_exact_no_reports_message(monkeypatch, capsys):
    import assertion_discrimination as ad
    monkeypatch.setattr(ad, 'find_reports', lambda repo, base, head: [])
    ad.main(['.', 'b', 'h'])
    assert capsys.readouterr().out == 'assertion-discrimination: no non-discriminating new assertion found\n'
