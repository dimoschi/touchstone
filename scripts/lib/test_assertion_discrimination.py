"""Unit tests for assertion_discrimination.py's source parser and classifier.

Parsing is exercised against small strings shaped like the real suites
(workflows/tests/test-static.sh's plain bash checks, workflows/tests/test-worktree-checks.sh's
JS-in-heredoc checks), not against the repo's own files: those change shape
over time and a parser test pinned to today's line numbers would break on an
unrelated edit. `find_reports`'s own orchestration runs against a throwaway
scratch git repo instead of pinned strings, since git archive and a real
suite run are the whole point of it; the same orchestration replayed against
this repo's real history (the historical ranges this ticket cites) lives in
scripts/test-assertion-discrimination.sh, where a `node`-backed JS scenario is
available.
"""

from __future__ import annotations

import subprocess

from assertion_discrimination import Call, parse_suite_source


BASH_SUITE = '''#!/usr/bin/env bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/harness.sh"

echo "== static: the join reads only v.id, never v.title"
check "no v.title reference remains" \\
  "$(grep -c 'v\\.title' "$SCRIPT" || true)" 0

echo "== static: a second section"
check "EXECUTE_RESULT lists id, exit_code, output in its required array" \\
  "$(grep -c "required: \\['id', 'exit_code', 'output'\\]" "$SCRIPT" || true)" 1

finish
'''


def test_parses_two_bash_calls_with_line_continuation():
    calls = parse_suite_source('workflows/tests/test-static.sh', BASH_SUITE)
    assert [c.kind for c in calls] == ['bash', 'bash']
    first, second = calls
    assert first.label == 'no v.title reference remains'
    assert '$SCRIPT' in first.got_src
    assert first.want_src.strip() == '0'
    assert second.label == "EXECUTE_RESULT lists id, exit_code, output in its required array"
    assert second.want_src.strip() == '1'


def test_bash_call_line_numbers_span_the_continuation():
    calls = parse_suite_source('workflows/tests/test-static.sh', BASH_SUITE)
    first = calls[0]
    # 1-based; "check ..." itself starts the line after the section's echo.
    assert first.start_line == 5
    assert first.end_line == 6


def test_bash_call_section_is_the_preceding_echo_header():
    calls = parse_suite_source('workflows/tests/test-static.sh', BASH_SUITE)
    assert calls[0].scenario == '== static: the join reads only v.id, never v.title'
    assert calls[1].scenario == '== static: a second section'


JS_SUITE = '''#!/usr/bin/env bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/harness.sh"

run_js_scenarios <<'JS_EOF'
async function scenarioBM() {
  console.log('\\n== scenario BM')
  const { result } = await run({ args: {} })
  check('halted at Worktree', result.halted_at, 'Worktree')
  check('the note does not recommend cutting a new branch',
    (result.note ?? '').includes('Re-run without existingBranch to cut one'), false)
}

async function scenarioBN() {
  console.log('\\n== scenario BN')
  const { captured } = await run({ args: {} })
  const p = captured.calls.find(c => c.label === 'branch:existing')?.prompt ?? ''
  check('cutting a new branch is safe advice here: the lookup already ' +
    'covered every worktree and branch for this ticket and found none',
    p.includes('Re-run without existingBranch to cut one'), true)
}

async function scenarioNoRun() {
  console.log('\\n== scenario NoRun: pure git premise, never touches deliver-pipeline.js')
  check('a file with a commit in the range reports non-empty', 'yes', 'yes')
}

const SCENARIOS = [scenarioBM, scenarioBN, scenarioNoRun]
JS_EOF

finish
'''


def test_parses_js_calls_inside_the_heredoc():
    calls = parse_suite_source('workflows/tests/test-worktree-checks.sh', JS_SUITE)
    assert [c.kind for c in calls] == ['js', 'js', 'js', 'js']
    labels = [c.label for c in calls]
    assert 'halted at Worktree' in labels
    assert 'the note does not recommend cutting a new branch' in labels


def test_js_call_scenario_is_the_enclosing_console_log_header():
    calls = parse_suite_source('workflows/tests/test-worktree-checks.sh', JS_SUITE)
    by_label = {c.label: c for c in calls}
    assert by_label['halted at Worktree'].scenario == '== scenario BM'
    assert by_label['the note does not recommend cutting a new branch'].scenario == '== scenario BM'


def test_js_label_concatenation_is_evaluated():
    calls = parse_suite_source('workflows/tests/test-worktree-checks.sh', JS_SUITE)
    by_scenario = {c.scenario: c for c in calls if c.scenario == '== scenario BN'}
    assert by_scenario['== scenario BN'].label == (
        'cutting a new branch is safe advice here: the lookup already '
        'covered every worktree and branch for this ticket and found none'
    )


def test_bash_call_dependent_flag_tracks_a_script_reference():
    calls = parse_suite_source('workflows/tests/test-static.sh', BASH_SUITE)
    assert calls[0].dependent is True


def test_js_call_dependent_flag_excludes_a_scenario_that_never_calls_run():
    calls = parse_suite_source('workflows/tests/test-worktree-checks.sh', JS_SUITE)
    by_label = {c.label: c for c in calls}
    assert by_label['halted at Worktree'].dependent is True
    assert by_label['a file with a commit in the range reports non-empty'].dependent is False


def test_select_candidates_drops_a_call_unchanged_since_base():
    from assertion_discrimination import select_candidates
    from collections import Counter
    calls = parse_suite_source('workflows/tests/test-worktree-checks.sh', JS_SUITE)
    by_label = {c.label: c for c in calls}
    base_counts = Counter({by_label['halted at Worktree'].text: 1})
    candidates = select_candidates(calls, base_counts)
    labels = {c.label for c in candidates}
    assert 'halted at Worktree' not in labels
    assert 'the note does not recommend cutting a new branch' in labels


def test_select_candidates_drops_a_call_unchanged_after_a_pure_file_move():
    # gh-118: the same call's text, byte for byte, surviving in counts built
    # from a different file entirely must still exclude it -- moving
    # assertions between files selects nothing.
    from assertion_discrimination import select_candidates
    from collections import Counter
    calls = parse_suite_source('workflows/tests/test-worktree-checks.sh', JS_SUITE)
    moved_elsewhere = parse_suite_source('workflows/test-fix-loop-join.sh', JS_SUITE)
    base_counts = Counter(c.text for c in moved_elsewhere)
    assert select_candidates(calls, base_counts) == []


def test_select_candidates_excludes_non_dependent_calls_even_when_new():
    from assertion_discrimination import select_candidates
    from collections import Counter
    calls = parse_suite_source('workflows/tests/test-worktree-checks.sh', JS_SUITE)
    candidates = select_candidates(calls, Counter())
    labels = {c.label for c in candidates}
    assert 'a file with a commit in the range reports non-empty' not in labels


def test_select_candidates_reports_a_genuinely_new_copy_of_a_duplicated_text():
    # gh-96: a boilerplate check copy-pasted into a new scenario has the same
    # text as one already at base, but the copy is still new source that
    # deserves judging -- set membership alone would drop it.
    from assertion_discrimination import select_candidates
    from collections import Counter
    calls = parse_suite_source('workflows/tests/test-worktree-checks.sh', JS_SUITE)
    by_label = {c.label: c for c in calls}
    duplicated = by_label['halted at Worktree']
    base_counts = Counter({duplicated.text: 1})  # one pre-existing occurrence
    head_calls = [duplicated, duplicated]  # base's original plus a fresh copy
    candidates = select_candidates(head_calls, base_counts)
    assert candidates == [duplicated]


def test_extract_statuses_reads_ok_and_fail_lines_in_order():
    from assertion_discrimination import extract_statuses
    stdout = (
        "== scenario BM\n"
        "  ok:   halted at Worktree (\"Worktree\")\n"
        "  FAIL: the note does not recommend cutting a new branch (got true, want false)\n"
        "  ABORTED: scenarioBM: boom\n"
    )
    assert extract_statuses(stdout) == [
        ('ok', 'halted at Worktree ("Worktree")'),
        ('FAIL', 'the note does not recommend cutting a new branch (got true, want false)'),
    ]


def test_match_call_status_is_positional_and_stops_at_a_mismatch():
    from assertion_discrimination import match_call_status
    calls = parse_suite_source('workflows/tests/test-worktree-checks.sh', JS_SUITE)
    scenario_calls = [c for c in calls if c.scenario == '== scenario BM']
    stdout = (
        "  ok:   halted at Worktree (\"Worktree\")\n"
        "  ok:   the note does not recommend cutting a new branch (false)\n"
    )
    statuses = match_call_status(scenario_calls, stdout)
    assert statuses[scenario_calls[0]] == 'ok'
    assert statuses[scenario_calls[1]] == 'ok'


def test_match_call_status_marks_unreached_calls_as_none():
    from assertion_discrimination import match_call_status
    calls = parse_suite_source('workflows/tests/test-worktree-checks.sh', JS_SUITE)
    scenario_calls = [c for c in calls if c.scenario == '== scenario BM']
    stdout = "  ok:   halted at Worktree (\"Worktree\")\n"  # scenario aborted before the 2nd check
    statuses = match_call_status(scenario_calls, stdout)
    assert statuses[scenario_calls[0]] == 'ok'
    assert statuses[scenario_calls[1]] is None


LOOP_SUITE = '''#!/usr/bin/env bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/harness.sh"

run_js_scenarios <<'JS_EOF'
async function scenarioLoop() {
  console.log('\\n== scenario Loop')
  for (const label of ['a', 'b']) {
    check(`${label} one`, true, true)
    check(`${label} two`, true, true)
  }
  check('after the loop', true, true)
}

const SCENARIOS = [scenarioLoop]
JS_EOF

finish
'''


def _loop_suite_calls():
    calls = parse_suite_source('workflows/tests/test-settled-decisions.sh', LOOP_SUITE)
    return [c for c in calls if c.scenario == '== scenario Loop']


def test_match_call_status_resyncs_after_a_check_printed_twice_by_a_loop():
    from assertion_discrimination import match_call_status
    calls = _loop_suite_calls()
    stdout = (
        "  ok:   a one (true)\n"
        "  ok:   a two (true)\n"
        "  ok:   b one (true)\n"
        "  ok:   b two (true)\n"
        "  ok:   after the loop (true)\n"
    )
    statuses = match_call_status(calls, stdout)
    assert statuses[calls[0]] == 'ok'  # the `one` check, both iterations ok
    assert statuses[calls[1]] == 'ok'  # the `two` check, both iterations ok
    assert statuses[calls[2]] == 'ok'  # 'after the loop', not misaligned


def test_match_call_status_marks_a_loop_body_call_fail_if_any_iteration_fails():
    from assertion_discrimination import match_call_status
    calls = _loop_suite_calls()
    stdout = (
        "  ok:   a one (true)\n"
        "  FAIL: a two (got false, want true)\n"
        "  ok:   b one (true)\n"
        "  ok:   b two (true)\n"
        "  ok:   after the loop (true)\n"
    )
    statuses = match_call_status(calls, stdout)
    assert statuses[calls[0]] == 'ok'
    assert statuses[calls[1]] == 'FAIL'
    assert statuses[calls[2]] == 'ok'


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


def test_is_bare_literal_is_true_for_a_js_call_comparing_two_constants():
    from assertion_discrimination import _is_bare_literal
    calls = parse_suite_source('workflows/tests/test-worktree-checks.sh', JS_SUITE)
    tautology = next(c for c in calls if c.label == 'a file with a commit in the range reports non-empty')
    assert tautology.got_src == "'yes'" and tautology.want_src == "'yes'"
    assert _is_bare_literal(tautology) is True


def test_is_bare_literal_is_false_for_a_js_call_referencing_a_captured_value():
    from assertion_discrimination import _is_bare_literal
    calls = parse_suite_source('workflows/tests/test-worktree-checks.sh', JS_SUITE)
    real = next(c for c in calls if c.label == 'halted at Worktree')
    assert _is_bare_literal(real) is False


def test_is_bare_literal_is_false_for_a_bash_call_referencing_script(tmp_path):
    from assertion_discrimination import _is_bare_literal
    calls = parse_suite_source('workflows/tests/test-static.sh', BASH_SUITE)
    assert _is_bare_literal(calls[0]) is False


def test_is_bare_literal_is_true_for_a_bash_call_with_no_expansion():
    from assertion_discrimination import _is_bare_literal
    calls = parse_suite_source(
        'workflows/tests/test-static.sh',
        'source harness.sh\ncheck "always true" "yes" "yes"\n',
    )
    assert _is_bare_literal(calls[0]) is True


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
    head = _commit_all(tmp_path, 'head: the new check is unreachable behind a setup failure')

    import pytest
    with pytest.raises(NoRecordsError):
        find_reports(str(tmp_path), base, head)


def test_main_reports_lines_and_exits_1_when_something_is_found(monkeypatch, capsys):
    import assertion_discrimination as ad

    def fake_find_reports(repo, base, head):
        assert (repo, base, head) == ('.', 'base-sha', 'head-sha')
        return [ad.Report(file='workflows/tests/test-worktree-checks.sh', line=426,
                           scenario='scenarioBU', label='no reviewer finding was recorded',
                           reason='no counterfactual production script makes this assertion fail')]

    monkeypatch.setattr(ad, 'find_reports', fake_find_reports)
    rc = ad.main(['.', 'base-sha', 'head-sha'])
    out = capsys.readouterr().out
    assert rc == 1
    assert 'workflows/tests/test-worktree-checks.sh:426' in out
    assert 'scenarioBU' in out
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


def test_strip_shell_word_unescapes_a_double_quoted_word():
    from assertion_discrimination import _strip_shell_word
    assert _strip_shell_word('"a \\"quoted\\" word"') == 'a "quoted" word'


def test_strip_shell_word_leaves_a_word_with_expansion_unchanged():
    from assertion_discrimination import _strip_shell_word
    assert _strip_shell_word('"$(echo hi)"') == '"$(echo hi)"'


def test_strip_shell_word_leaves_a_bare_unquoted_word_unchanged():
    from assertion_discrimination import _strip_shell_word
    assert _strip_shell_word('0') == '0'


def test_eval_js_string_literal_rejects_a_mismatched_quote_pair():
    from assertion_discrimination import _eval_js_string_literal
    assert _eval_js_string_literal("'unterminated\"") is None


def test_eval_js_string_literal_rejects_a_bare_token():
    from assertion_discrimination import _eval_js_string_literal
    assert _eval_js_string_literal('true') is None


def test_eval_js_string_literal_evaluates_a_double_quoted_literal():
    from assertion_discrimination import _eval_js_string_literal
    assert _eval_js_string_literal('"plain"') == 'plain'


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


def test_bash_call_supports_a_bare_top_level_single_quoted_label():
    source = (
        "check 'a bare single-quoted label' \"$(grep -c 'FOO' \"$SCRIPT\" || true)\" 1\n"
    )
    calls = parse_suite_source('workflows/tests/test-static.sh', source)
    assert len(calls) == 1
    assert calls[0].label == 'a bare single-quoted label'


def test_is_header_line_matches_a_leading_double_equals():
    from assertion_discrimination import _is_header_line
    assert _is_header_line('== a header') is True
    assert _is_header_line('  == an indented header') is True
    assert _is_header_line('  ok:   not a header') is False


def test_split_output_by_group_puts_pre_header_lines_in_the_none_group():
    from assertion_discrimination import _split_output_by_group
    stdout = "leading noise\n== first\n  ok:   a (1)\n== second\n  ok:   b (2)\n"
    blocks = _split_output_by_group(stdout, [None, '== first', '== second'])
    assert blocks[None] == 'leading noise'
    assert 'ok:   a (1)' in blocks['== first']
    assert 'ok:   b (2)' in blocks['== second']


def test_split_output_by_group_fills_an_unowned_header_with_its_own_block():
    from assertion_discrimination import _split_output_by_group
    # A header with no check of its own (see suite_ordered_groups) still
    # consumes one block, keeping every later header correctly aligned.
    stdout = "== empty section\nnarration only\n== real section\n  ok:   c (1)\n"
    blocks = _split_output_by_group(stdout, [None, '== empty section', '== real section'])
    assert blocks[None] == ''
    assert blocks['== empty section'] == '== empty section\nnarration only'
    assert 'ok:   c (1)' in blocks['== real section']


def test_scenario_execution_order_reads_the_modern_scenarios_array():
    from assertion_discrimination import _scenario_execution_order
    body = "const SCENARIOS = [scenarioA, scenarioB]\n"
    assert _scenario_execution_order(body) == ['scenarioA', 'scenarioB']


def test_scenario_execution_order_reads_the_historical_inline_for_loop():
    from assertion_discrimination import _scenario_execution_order
    body = "for (const scenario of [scenarioA, scenarioB]) {\n  await scenario()\n}\n"
    assert _scenario_execution_order(body) == ['scenarioA', 'scenarioB']


def test_scenario_execution_order_is_empty_without_either_form():
    from assertion_discrimination import _scenario_execution_order
    assert _scenario_execution_order("async function scenarioA() {}\n") == []


COMMENT_SUITE = '''#!/usr/bin/env bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/harness.sh"

echo "== static: real assertions only"
# not trip this, so the check is the exact old phrase, not the bare word.
check "the real assertion after the comment" "$(grep -c 'v\\.title' "$SCRIPT" || true)" 0
'''


def test_bash_check_word_inside_a_comment_is_not_parsed_as_a_call():
    # A phantom Call here would misalign match_call_status against every real
    # call that follows it in the same section.
    calls = parse_suite_source('workflows/tests/test-static.sh', COMMENT_SUITE)
    assert len(calls) == 1
    assert calls[0].label == 'the real assertion after the comment'


def test_bash_comment_blanking_preserves_line_numbers():
    calls = parse_suite_source('workflows/tests/test-static.sh', COMMENT_SUITE)
    assert calls[0].start_line == 6


REGEX_ARG_SUITE = '''#!/usr/bin/env bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/harness.sh"

run_js_scenarios <<'JS_EOF'
async function scenarioFV() {
  console.log('\\n== scenario FV')
  const { captured } = await run({ args: {} })
  const runPrompt = captured.calls.find(c => c.label === 'implementer')?.prompt ?? ''
  check('it demands one at a time, in order',
    /one at a time, in the order given/.test(runPrompt), true)
  check('a second call right after the regex', runPrompt.length > 0, true)
}

const SCENARIOS = [scenarioFV]
JS_EOF

finish
'''


def test_js_call_args_are_not_split_on_a_comma_inside_a_regex_literal():
    calls = parse_suite_source('workflows/tests/test-reproducer-exitline.sh', REGEX_ARG_SUITE)
    labels = [c.label for c in calls]
    assert 'it demands one at a time, in order' in labels
    assert 'a second call right after the regex' in labels


def test_scan_js_regex_body_skips_a_comma_inside_a_character_class():
    from assertion_discrimination import _scan_js_regex_body
    text = '/[,]/.test(x)'
    assert _scan_js_regex_body(text, 0) == text.index('/', 1) + 1


def test_scan_js_regex_body_treats_an_escaped_slash_as_literal():
    from assertion_discrimination import _scan_js_regex_body
    text = r'/a\/b/.test(x)'
    assert _scan_js_regex_body(text, 0) == text.index('/', 4) + 1


def test_scan_js_regex_literal_consumes_trailing_flags():
    from assertion_discrimination import _scan_js_regex_literal
    text = '/abc/gi, true'
    assert text[_scan_js_regex_literal(text, 0):].startswith(', true')


def test_split_top_level_keeps_a_comma_inside_a_flagged_regex_literal():
    from assertion_discrimination import _split_top_level, _JS_QUOTES, _JS_BRACKETS
    parts = _split_top_level("/a,b/gi.test(x), true", ',', _JS_QUOTES, _JS_BRACKETS)
    assert len(parts) == 2
