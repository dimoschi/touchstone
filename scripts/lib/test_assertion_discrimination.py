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


def test_no_records_error_keeps_the_file_it_was_given():
    from assertion_discrimination import NoRecordsError
    assert NoRecordsError('workflows/tests/test-static.sh').file == 'workflows/tests/test-static.sh'


def test_collapse_ws_folds_a_run_of_whitespace_to_one_space():
    from assertion_discrimination import _collapse_ws
    assert _collapse_ws('a   b\tc') == 'a b c'


def test_line_of_counts_only_newlines_before_the_given_index():
    # A newline at index 0 must count; starting the scan at index 1 (rather
    # than 0) would silently drop it and under-report the line number.
    from assertion_discrimination import _line_of
    assert _line_of('\nabc', 4) == 2


def test_advance_in_quote_treats_a_backslash_as_an_escape():
    from assertion_discrimination import _advance_in_quote
    stack = ['"']
    assert _advance_in_quote('\\"x', 0, '"', stack) == 2
    assert stack == ['"']  # the escaped quote must not have closed it


def test_advance_balanced_treats_a_backslash_as_an_escape_outside_any_quote():
    from assertion_discrimination import _advance_balanced
    stack = ['(']
    assert _advance_balanced('\\)', 0, '(', ')', "'\"", stack) == 2
    assert stack == ['(']  # the escaped ')' must not have closed the bracket


def test_scan_balanced_stops_cleanly_at_an_unterminated_bracket():
    from assertion_discrimination import _scan_balanced
    assert _scan_balanced('(', 0, '(', ')', '') == 1


def test_is_matching_closer_is_false_for_a_non_closer_that_happens_to_match_the_stack_top():
    from assertion_discrimination import _is_matching_closer
    assert _is_matching_closer('x', {')'}, ['x']) is False


def test_top_quote_is_none_when_the_stack_top_is_a_bracket_not_a_quote():
    from assertion_discrimination import _top_quote
    assert _top_quote(['('], "'\"") is None


def test_regex_literal_starts_at_is_false_right_after_an_identifier():
    from assertion_discrimination import _regex_literal_starts_at
    assert _regex_literal_starts_at('a/', 1) is False


def test_regex_literal_starts_at_looks_past_trailing_whitespace_before_the_slash():
    from assertion_discrimination import _regex_literal_starts_at
    assert _regex_literal_starts_at('a  /', 3) is False


def test_scan_js_regex_body_treats_a_backslash_as_a_two_character_escape():
    from assertion_discrimination import _scan_js_regex_body
    assert _scan_js_regex_body(r'/\//', 0) == 4


def test_scan_js_regex_body_stops_cleanly_at_an_unterminated_literal():
    from assertion_discrimination import _scan_js_regex_body
    assert _scan_js_regex_body('/abc', 0) == 4


def test_scan_js_regex_body_escape_skips_exactly_the_escaped_character():
    from assertion_discrimination import _scan_js_regex_body
    assert _scan_js_regex_body(r'/\y/Z/', 0) == 4


def test_scan_js_regex_body_a_slash_inside_a_character_class_does_not_close_it():
    from assertion_discrimination import _scan_js_regex_body
    assert _scan_js_regex_body('/[/]/', 0) == 5


def test_scan_js_regex_body_only_a_real_bracket_opens_a_character_class():
    # A literal 'X' in the body must never be mistaken for '[' or ']'.
    from assertion_discrimination import _scan_js_regex_body
    assert _scan_js_regex_body('/[X/]/', 0) == 6


def test_skip_js_regex_flags_stops_cleanly_at_the_end_of_text():
    from assertion_discrimination import _skip_js_regex_flags
    assert _skip_js_regex_flags('g', 0) == 1


def test_advance_split_treats_a_backslash_as_a_two_character_escape():
    from assertion_discrimination import _advance_split
    assert _advance_split('\\x', 0, "'\"`", {'(': ')'}, {')'}, []) == 2


def test_advance_split_does_not_start_a_regex_literal_inside_an_open_bracket():
    from assertion_discrimination import _advance_split
    assert _advance_split('(/x/)', 1, "'\"`", {'(': ')'}, {')'}, ['(']) == 2


def test_split_top_level_resets_start_to_right_after_the_separator():
    from assertion_discrimination import _split_top_level
    assert _split_top_level('a,b', ',', '', {}) == ['a', 'b']


def test_split_top_level_advances_by_exactly_one_past_the_separator():
    from assertion_discrimination import _split_top_level
    assert _split_top_level('a,,b', ',', '', {}) == ['a', '', 'b']


def test_scan_single_quote_finds_the_match_starting_right_after_the_opener():
    from assertion_discrimination import _scan_single_quote
    assert _scan_single_quote("''", 0) == 2


def test_scan_double_quote_stops_cleanly_at_an_unterminated_quote():
    from assertion_discrimination import _scan_double_quote
    assert _scan_double_quote('"abc', 0) == 4


def test_scan_double_quote_escape_skips_exactly_the_escaped_character():
    from assertion_discrimination import _scan_double_quote
    assert _scan_double_quote('"\\"x"', 0) == 5


def test_scan_double_quote_escape_advance_is_relative_to_the_backslash():
    from assertion_discrimination import _scan_double_quote
    assert _scan_double_quote('"\\z"W"', 0) == 4


def test_skip_bash_whitespace_stops_cleanly_at_the_end_of_text():
    from assertion_discrimination import _skip_bash_whitespace
    assert _skip_bash_whitespace(' ', 0) == 1


def test_skip_bash_whitespace_does_not_treat_x_as_whitespace():
    from assertion_discrimination import _skip_bash_whitespace
    assert _skip_bash_whitespace('X', 0) == 0


def test_skip_bash_whitespace_line_continuation_advances_by_exactly_two():
    from assertion_discrimination import _skip_bash_whitespace
    assert _skip_bash_whitespace('\\\nz', 0) == 2


def test_skip_one_bash_token_treats_a_backslash_as_a_two_character_escape():
    from assertion_discrimination import _skip_one_bash_token
    assert _skip_one_bash_token('\\x', 0) == 2


def test_skip_one_bash_token_command_substitution_starts_scanning_right_after_the_paren():
    from assertion_discrimination import _skip_one_bash_token
    assert _skip_one_bash_token('$(a)', 0) == 4


def test_skip_one_bash_token_command_substitution_closes_only_on_a_real_close_paren():
    from assertion_discrimination import _skip_one_bash_token
    assert _skip_one_bash_token('$(a)b', 0) == 4


def test_skip_bash_word_stops_cleanly_at_the_end_of_text():
    from assertion_discrimination import _skip_bash_word
    assert _skip_bash_word('a', 0) == 1


def test_skip_bash_word_does_not_treat_x_as_a_word_terminator():
    from assertion_discrimination import _skip_bash_word
    assert _skip_bash_word('X', 0) == 1


def test_skip_to_newline_stops_cleanly_at_the_end_of_text():
    from assertion_discrimination import _skip_to_newline
    assert _skip_to_newline('a', 0) == 1


def test_skip_to_newline_advances_by_exactly_one_each_step():
    from assertion_discrimination import _skip_to_newline
    assert _skip_to_newline('abc', 0) == 3


def test_skip_to_newline_advance_does_not_jump_back_to_a_fixed_index():
    from assertion_discrimination import _skip_to_newline
    assert _skip_to_newline('a\nbcZ', 3) == 5


def test_read_bash_call_stops_at_exactly_three_words():
    from assertion_discrimination import _read_bash_call
    words, _end = _read_bash_call('a b c d\n', 0)
    assert words == ['a', 'b', 'c']


def test_read_bash_call_stops_cleanly_at_trailing_whitespace_with_no_third_word():
    from assertion_discrimination import _read_bash_call
    words, _end = _read_bash_call('a b  ', 0)
    assert words == ['a', 'b']


def test_read_bash_call_a_bare_newline_ends_the_call_even_with_fewer_than_three_words():
    from assertion_discrimination import _read_bash_call
    words, _end = _read_bash_call('a b\nc', 0)
    assert words == ['a', 'b']


def test_is_quoted_with_is_false_when_only_the_closing_quote_matches():
    from assertion_discrimination import _is_quoted_with
    assert _is_quoted_with('xq', 'q') is False


def test_is_quoted_with_is_true_for_a_minimal_two_character_quoted_word():
    from assertion_discrimination import _is_quoted_with
    assert _is_quoted_with('""', '"') is True


def test_blank_to_newline_writes_a_single_space_and_stops_cleanly_at_the_end():
    from assertion_discrimination import _blank_to_newline
    out = list('a')
    assert _blank_to_newline(out, 'a', 0) == 1
    assert out == [' ']


def test_blank_bash_comments_blanks_a_comment_starting_at_the_very_first_character():
    from assertion_discrimination import _blank_bash_comments
    assert _blank_bash_comments('#x\n') == '  \n'


def test_blank_bash_comments_does_not_treat_a_literal_x_as_whitespace():
    from assertion_discrimination import _blank_bash_comments
    assert _blank_bash_comments('X#c\n') == 'X#c\n'


def test_blank_bash_comments_a_hash_after_a_word_and_space_is_not_a_comment():
    # at_word_start only goes back to True at a newline (or the very start),
    # never merely because whitespace followed a word.
    from assertion_discrimination import _blank_bash_comments
    assert _blank_bash_comments('ab #c\n') == 'ab #c\n'


def test_parse_bash_calls_skips_a_malformed_call_but_keeps_scanning():
    from assertion_discrimination import _parse_bash_calls
    calls = _parse_bash_calls('f.sh', 'check bad\ncheck "good" "x" "y"\n', ([], []))
    assert len(calls) == 1
    assert calls[0].label == 'good'
    assert calls[0].label_src == '"good"'
    assert 'good' in calls[0].text


def test_parse_bash_calls_dependent_flag_also_checks_want_src():
    from assertion_discrimination import _parse_bash_calls
    calls = _parse_bash_calls('f.sh', 'check "label" "x" "$SCRIPT"\n', ([], []))
    assert calls[0].dependent is True


def test_heredoc_spans_finds_the_real_multiline_closing_delimiter():
    from assertion_discrimination import _heredoc_spans
    source = "x\nrun_js_scenarios <<'EOF'\nbody\nEOF\nafter\n"
    spans = _heredoc_spans(source)
    assert len(spans) == 1
    body_start, body_end, first_line = spans[0]
    assert source[body_end:].startswith('EOF\nafter\n')
    assert first_line == 3


def test_heredoc_spans_search_for_the_closer_starts_at_the_body_not_the_whole_source():
    from assertion_discrimination import _heredoc_spans
    source = "EOF\nrun_js_scenarios <<'EOF'\nbody\nEOF\nafter\n"
    spans = _heredoc_spans(source)
    body_start, body_end, _first_line = spans[0]
    assert body_end > body_start
    assert source[body_end:].startswith('EOF\nafter\n')


def test_heredoc_spans_an_unterminated_heredoc_extends_to_the_end_of_source():
    from assertion_discrimination import _heredoc_spans
    source = "run_js_scenarios <<'EOF'\nbody without a closing delimiter\n"
    spans = _heredoc_spans(source)
    _body_start, body_end, _first_line = spans[0]
    assert body_end == len(source)


def test_js_scenario_at_is_none_before_any_scenario_function():
    from assertion_discrimination import _js_scenario_at
    assert _js_scenario_at('some text with no scenario def', 5) is None


def test_scenario_calls_run_is_false_without_a_scenario_name():
    from assertion_discrimination import _scenario_calls_run
    assert _scenario_calls_run('anything', None) is False


def test_scenario_calls_run_finds_the_function_even_when_not_first_in_the_body():
    from assertion_discrimination import _scenario_calls_run
    body = "// comment\nasync function scenarioX() {\n  await run()\n}\n"
    assert _scenario_calls_run(body, 'scenarioX') is True


def test_scenario_calls_run_is_false_when_the_named_function_is_not_found():
    from assertion_discrimination import _scenario_calls_run
    assert _scenario_calls_run('async function other() {}\n', 'scenarioX') is False


def test_scenario_calls_run_does_not_see_past_its_own_closing_brace():
    from assertion_discrimination import _scenario_calls_run
    body = "async function scenarioX() {\n  console.log(1)\n}\nawait run()\n"
    assert _scenario_calls_run(body, 'scenarioX') is False


def test_is_bare_js_literal_is_true_for_a_minimal_two_character_literal():
    from assertion_discrimination import _is_bare_js_literal
    assert _is_bare_js_literal("''") is True


def test_unescape_js_string_a_trailing_backslash_is_kept_literal():
    from assertion_discrimination import _unescape_js_string
    assert _unescape_js_string('\\') == '\\'


def test_unescape_js_string_escape_advance_is_exactly_two():
    from assertion_discrimination import _unescape_js_string
    assert _unescape_js_string('\\n') == '\n'


def test_unescape_js_string_an_unmapped_escape_falls_back_to_itself():
    from assertion_discrimination import _unescape_js_string
    assert _unescape_js_string('\\q') == 'q'


def test_unescape_js_string_unmapped_escape_fallback_is_the_escaped_char_not_an_earlier_one():
    from assertion_discrimination import _unescape_js_string
    assert _unescape_js_string('a\\q') == 'aq'


def test_unescape_js_string_unmapped_escape_fallback_is_not_a_later_char():
    from assertion_discrimination import _unescape_js_string
    assert _unescape_js_string('\\qZ') == 'qZ'


def test_unescape_js_string_escape_advance_is_relative_not_absolute():
    from assertion_discrimination import _unescape_js_string
    assert _unescape_js_string('a\\n') == 'a\n'


def test_scenario_header_texts_does_not_attribute_a_later_functions_header_to_an_earlier_one():
    from assertion_discrimination import _scenario_header_texts
    body = (
        "async function scenarioA() {\n"
        "  doSomething()\n"
        "}\n"
        "async function scenarioB() {\n"
        "  console.log('\\n== scenario B')\n"
        "}\n"
    )
    result = _scenario_header_texts(body)
    assert 'scenarioA' not in result
    assert result['scenarioB'] == '== scenario B'


def test_bash_headers_excludes_a_header_looking_line_at_a_heredocs_own_start():
    from assertion_discrimination import _bash_headers, _heredoc_spans
    source = "run_js_scenarios <<'EOF'\necho \"== fake header inside heredoc\"\nEOF\n"
    heredocs = _heredoc_spans(source)
    _positions, texts = _bash_headers(source, heredocs)
    assert texts == []


def test_bash_headers_keeps_a_header_landing_exactly_at_a_heredocs_own_end():
    # A heredoc's own end offset is the first character after it, so the span is half-open.
    from assertion_discrimination import _bash_headers
    prefix = 'before\n'
    source = prefix + 'echo "== right after"\n'
    heredocs = [(0, len(prefix), 1)]
    _positions, texts = _bash_headers(source, heredocs)
    assert texts == ['== right after']


def test_js_header_texts_ordered_follows_the_scenarios_array_order():
    from assertion_discrimination import _js_header_texts_ordered, _heredoc_spans
    source = (
        "run_js_scenarios <<'EOF'\n"
        "async function scenarioA() {\n"
        "  console.log('\\n== A')\n"
        "}\n"
        "async function scenarioB() {\n"
        "  console.log('\\n== B')\n"
        "}\n"
        "const SCENARIOS = [scenarioB, scenarioA]\n"
        "EOF\n"
    )
    heredocs = _heredoc_spans(source)
    assert _js_header_texts_ordered(heredocs, source) == ['== B', '== A']


def test_parse_js_calls_skips_a_malformed_call_but_keeps_scanning():
    from assertion_discrimination import _parse_js_calls
    source = (
        "run_js_scenarios <<'EOF'\n"
        "async function scenarioX() {\n"
        "  check('only one arg')\n"
        "  check('good', 1, 1)\n"
        "}\n"
        "EOF\n"
    )
    calls = _parse_js_calls('f.sh', source)
    assert len(calls) == 1
    assert calls[0].label == 'good'
    assert calls[0].file == 'f.sh'
    assert calls[0].label_src == "'good'"
    assert 'good' in calls[0].text


def test_parse_js_calls_line_numbers_account_for_the_heredocs_own_offset():
    from assertion_discrimination import _parse_js_calls
    source = (
        "x\n"
        "run_js_scenarios <<'EOF'\n"
        "async function scenarioY() {\n"
        "  check('solo',\n"
        "    1, 1)\n"
        "}\n"
        "EOF\n"
    )
    calls = _parse_js_calls('f.sh', source)
    assert len(calls) == 1
    assert calls[0].start_line == 4
    assert calls[0].end_line == 5


def test_resolve_loop_gap_marks_a_never_reached_call_as_none_not_empty_string():
    from assertion_discrimination import _resolve_loop_gap
    calls = _loop_suite_calls()
    gap_calls = calls[:2]
    result = _resolve_loop_gap(gap_calls, [('ok', 'a one (true)')])
    assert result[gap_calls[1]] is None


_SUITE3 = 'source harness.sh\ncheck "first" "1" "1"\ncheck "second" "1" "1"\ncheck "third" "1" "1"\n'


def test_match_call_status_stops_cleanly_once_every_call_is_matched():
    from assertion_discrimination import match_call_status
    calls = parse_suite_source('f.sh', _SUITE3)
    stdout = "  ok:   first (1)\n  ok:   second (1)\n  ok:   third (1)\n  ok:   an extra trailing status (1)\n"
    statuses = match_call_status(calls, stdout)
    assert len(statuses) == 3
    assert statuses[calls[2]] == 'ok'


def test_match_call_status_break_on_mismatch_leaves_the_rest_marked_none():
    from assertion_discrimination import match_call_status
    calls = parse_suite_source('f.sh', _SUITE3)
    stdout = "  ok:   first (1)\n  ok:   unexpected (1)\n  ok:   third (1)\n"
    statuses = match_call_status(calls, stdout)
    assert statuses[calls[0]] == 'ok'
    assert calls[1] in statuses and statuses[calls[1]] is None
    assert calls[2] in statuses and statuses[calls[2]] is None


def test_match_call_status_counters_advance_by_exactly_one():
    from assertion_discrimination import match_call_status
    calls = parse_suite_source('f.sh', _SUITE3)
    stdout = "  ok:   first (1)\n  ok:   second (1)\n  ok:   third (1)\n"
    statuses = match_call_status(calls, stdout)
    assert statuses[calls[0]] == 'ok'
    assert statuses[calls[1]] == 'ok'
    assert statuses[calls[2]] == 'ok'


def test_label_gap_end_stops_cleanly_when_every_call_is_label_less():
    from assertion_discrimination import _label_gap_end
    gap_only = _loop_suite_calls()[:2]
    assert _label_gap_end(gap_only, 0) == 2


def test_label_gap_end_stops_at_the_first_labeled_call():
    from assertion_discrimination import _label_gap_end
    calls = _loop_suite_calls()
    assert _label_gap_end(calls, 0) == 2


_LOOP3_SUITE = '''#!/usr/bin/env bash
source harness.sh
run_js_scenarios <<'JS_EOF'
async function scenarioLoop3() {
  console.log('\\n== scenario Loop3')
  for (const label of ['a']) {
    check(`${label} one`, true, true)
    check(`${label} two`, true, true)
    check(`${label} three`, true, true)
  }
  check('after the loop', true, true)
}
const SCENARIOS = [scenarioLoop3]
JS_EOF
finish
'''


def test_label_gap_end_advances_by_exactly_one_over_a_longer_run():
    from assertion_discrimination import _label_gap_end
    calls = [c for c in parse_suite_source('f.sh', _LOOP3_SUITE) if c.scenario == '== scenario Loop3']
    assert _label_gap_end(calls, 0) == 3


def test_label_gap_stop_consumes_every_remaining_status_without_a_next_label():
    from assertion_discrimination import _label_gap_stop
    assert _label_gap_stop([('ok', 'a'), ('ok', 'b')], 0, None) == 2


def test_label_gap_stop_stops_at_the_first_status_carrying_the_next_label():
    from assertion_discrimination import _label_gap_stop
    assert _label_gap_stop([('ok', 'x (1)'), ('ok', 'y (1)')], 0, 'y') == 1


def test_label_gap_stop_advances_by_exactly_one():
    from assertion_discrimination import _label_gap_stop
    assert _label_gap_stop([('ok', 'a'), ('ok', 'b'), ('ok', 'c')], 0, None) == 3


def test_find_label_gap_next_label_is_none_when_the_gap_reaches_the_end_of_calls():
    from assertion_discrimination import _find_label_gap
    calls = _loop_suite_calls()[:2]
    gap_end, _gap_stop = _find_label_gap(calls, 0, [('ok', 'a one (true)'), ('ok', 'a two (true)')], 0)
    assert gap_end == 2


def test_is_diff_header_noise_is_true_for_a_plus_plus_plus_line_alone():
    from assertion_discrimination import _is_diff_header_noise
    assert _is_diff_header_noise('+++ b/file') is True


def test_is_diff_header_noise_is_true_for_a_dash_dash_dash_line_alone():
    from assertion_discrimination import _is_diff_header_noise
    assert _is_diff_header_noise('--- a/file') is True


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


def test_group_by_scenario_per_file_keys_by_the_calls_own_scenario():
    from assertion_discrimination import _group_by_scenario_per_file
    calls = parse_suite_source('workflows/tests/test-static.sh', BASH_SUITE)
    grouped = _group_by_scenario_per_file(calls)
    file_groups = grouped['workflows/tests/test-static.sh']
    assert set(file_groups.keys()) == {calls[0].scenario, calls[1].scenario}


def test_parse_calls_at_tags_calls_with_the_given_file_path(tmp_path):
    from assertion_discrimination import _parse_calls_at
    _init_scratch_repo(tmp_path)
    (tmp_path / 'workflows' / 'tests').mkdir(parents=True)
    (tmp_path / 'workflows' / 'tests' / 'test-static.sh').write_text(BASH_SUITE)
    head = _commit_all(tmp_path, 'seed')
    calls = _parse_calls_at(str(tmp_path), head, 'workflows/tests/test-static.sh')
    assert calls[0].file == 'workflows/tests/test-static.sh'


def test_parse_calls_at_parses_a_file_missing_at_that_rev_as_empty_source(monkeypatch):
    import assertion_discrimination as ad
    monkeypatch.setattr(ad, 'git_show', lambda repo, rev, file: None)
    seen = {}

    def fake_parse(file, source):
        seen['source'] = source
        return []

    monkeypatch.setattr(ad, 'parse_suite_source', fake_parse)
    ad._parse_calls_at('/repo', 'HEAD', 'missing.sh')
    assert seen['source'] == ''


def test_build_head_index_treats_a_file_missing_at_head_as_empty_source(monkeypatch):
    import assertion_discrimination as ad
    monkeypatch.setattr(ad, 'list_suite_files', lambda repo, head: ['a.sh'])
    monkeypatch.setattr(ad, 'git_show', lambda repo, rev, file: None)
    monkeypatch.setattr(ad, 'parse_suite_source', lambda file, source: [])
    head_index = ad._build_head_index('/repo', 'HEAD')
    assert head_index.sources == {'a.sh': ''}


def test_try_counterfactual_copies_the_tree_under_the_given_tmp_dir(monkeypatch, tmp_path):
    import pathlib
    import assertion_discrimination as ad
    head_tree = tmp_path / 'head'
    (head_tree / 'workflows').mkdir(parents=True)
    (head_tree / 'workflows' / 'deliver-pipeline.js').write_text('old\n')
    tmp = tmp_path / 'work'
    tmp.mkdir()
    seen = {}

    def fake_survivors(tree, head, pending):
        # observed before _try_counterfactual's own cleanup removes `tree`
        seen['tree'] = tree
        seen['script'] = pathlib.Path(tree, 'workflows', 'deliver-pipeline.js').read_text()
        return pending

    monkeypatch.setattr(ad, '_survivors_of_counterfactual', fake_survivors)
    result = ad._try_counterfactual(str(tmp), 'revert', str(head_tree), 'NEW_SCRIPT', object(), ['pending'])
    assert result == ['pending']
    assert seen['tree'] == str(tmp / 'revert')
    assert seen['script'] == 'NEW_SCRIPT'
    assert not (tmp / 'revert').exists()


def test_run_mutant_sweep_treats_a_pipeline_script_missing_at_head_as_empty(monkeypatch):
    import assertion_discrimination as ad
    monkeypatch.setattr(ad, 'git_show', lambda repo, rev, file: None)
    seen = {}

    def fake_mutant_contents(head_script, repo, base, head):
        seen['head_script'] = head_script
        return []

    monkeypatch.setattr(ad, '_mutant_contents', fake_mutant_contents)
    result = ad._run_mutant_sweep('/repo', 'BASE', 'HEAD', '/tmp', '/tree', object(), ['pending'])
    assert seen['head_script'] == ''
    assert result == ['pending']


def test_run_counterfactuals_names_the_revert_tree_revert(monkeypatch):
    import assertion_discrimination as ad
    monkeypatch.setattr(ad, 'git_show', lambda repo, rev, file: {'BASE': 'old', 'HEAD': 'new'}[rev])
    seen = {}

    def fake_try_counterfactual(tmp, name, head_tree, script_content, head, pending):
        seen['name'] = name
        return pending

    monkeypatch.setattr(ad, '_try_counterfactual', fake_try_counterfactual)
    monkeypatch.setattr(ad, '_run_mutant_sweep', lambda *a: a[-1])
    ad._run_counterfactuals('/repo', 'BASE', 'HEAD', '/tmp', '/tree', object(), ['pending'])
    assert seen['name'] == 'revert'


def test_is_bare_literal_checks_want_src_for_a_dollar_sign_specifically():
    from assertion_discrimination import _is_bare_literal
    calls = parse_suite_source('f.sh', 'check "label" "1" "$FOO"\n')
    assert _is_bare_literal(calls[0]) is False


def test_is_bare_literal_recognizes_a_bare_js_boolean_or_number_via_the_regex():
    from assertion_discrimination import _is_bare_literal
    source = (
        "run_js_scenarios <<'EOF'\n"
        "async function scenarioZ() {\n"
        "  check('x', true, 123)\n"
        "}\n"
        "const SCENARIOS = [scenarioZ]\n"
        "EOF\n"
    )
    calls = parse_suite_source('f.sh', source)
    assert _is_bare_literal(calls[0]) is True


def test_find_reports_reports_every_field_correctly_and_sorted_by_file_then_line(tmp_path):
    from assertion_discrimination import find_reports

    _init_scratch_repo(tmp_path)
    (tmp_path / 'workflows' / 'tests').mkdir(parents=True)
    (tmp_path / 'workflows' / 'deliver-pipeline.js').write_text("const NOTE = 'ok'\n")
    (tmp_path / 'workflows' / 'tests' / 'test-static.sh').write_text(_SUITE_TEMPLATE.format(
        checks='check "a pre-existing check" "$(grep -c \'NOTE\' "$SCRIPT" || true)" 1'
    ))
    base = _commit_all(tmp_path, 'base')

    (tmp_path / 'workflows' / 'deliver-pipeline.js').write_text(
        "const NOTE = 'ok'\nconst SECOND = 'x'\nconst THIRD = 'y'\n"
    )
    (tmp_path / 'workflows' / 'tests' / 'test-static.sh').write_text(_SUITE_TEMPLATE.format(
        checks='check "a pre-existing check" "$(grep -c \'NOTE\' "$SCRIPT" || true)" 1\n'
               'echo "== a real section"\n'
               'check "no NEVER_B reference remains" "$(grep -c \'NEVER_B\' "$SCRIPT" || true)" 0\n'
               'check "no NEVER_A reference remains" "$(grep -c \'NEVER_A\' "$SCRIPT" || true)" 0'
    ))
    head = _commit_all(tmp_path, 'head')

    reports = find_reports(str(tmp_path), base, head)
    assert len(reports) == 2
    first, second = reports
    assert first.file == second.file == 'workflows/tests/test-static.sh'
    assert first.line < second.line
    assert first.scenario == '== a real section' == second.scenario
    assert first.label == 'no NEVER_B reference remains'
    assert second.label == 'no NEVER_A reference remains'
    assert first.reason == 'no counterfactual production script makes this assertion fail'


def test_find_reports_archives_head_under_a_touchstone_prefixed_tmp_dir(monkeypatch):
    import os
    import assertion_discrimination as ad
    seen = {}
    monkeypatch.setattr(ad, 'archive_tree', lambda repo, rev, dest: seen.setdefault('dest', dest))
    monkeypatch.setattr(ad, '_collect_candidates', lambda repo, base, head: (object(), ['candidate']))
    monkeypatch.setattr(ad, '_passing_at_head', lambda tree, head, candidates: candidates)
    monkeypatch.setattr(ad, '_run_counterfactuals', lambda *a: [])
    ad.find_reports('/repo', 'BASE', 'HEAD')
    assert os.path.basename(seen['dest']) == 'head'
    assert os.path.basename(os.path.dirname(seen['dest'])).startswith('touchstone-assertion-discrimination-')


def test_find_reports_reports_the_label_source_text_when_no_literal_label_is_known(monkeypatch):
    import assertion_discrimination as ad
    call = Call(kind='js', file='f.sh', start_line=1, end_line=1, scenario=None,
                label_src='dynamicLabel', label=None, got_src='true', want_src='true',
                text='check(dynamicLabel, true, true)', dependent=True)
    monkeypatch.setattr(ad, 'archive_tree', lambda repo, rev, dest: None)
    monkeypatch.setattr(ad, '_collect_candidates', lambda repo, base, head: (object(), [call]))
    monkeypatch.setattr(ad, '_passing_at_head', lambda tree, head, candidates: candidates)
    monkeypatch.setattr(ad, '_run_counterfactuals', lambda *a: [call])
    reports = ad.find_reports('/repo', 'BASE', 'HEAD')
    assert reports[0].label == 'dynamicLabel'


def test_parse_suite_source_blanks_heredoc_bodies_so_a_bash_check_word_inside_is_not_parsed():
    source = (
        "run_js_scenarios <<'EOF'\n"
        '// check "a" "b" "c"\n'
        "async function scenarioX() { check('x', 1, 1) }\n"
        "EOF\n"
    )
    calls = parse_suite_source('f.sh', source)
    assert len(calls) == 1
    assert calls[0].kind == 'js'


def test_parse_suite_source_blanking_preserves_positions_for_header_lookup_after_a_heredoc():
    source = (
        "run_js_scenarios <<'EOF'\n"
        "async function scenarioX() { check('x', 1, 1) }\n"
        "EOF\n"
        'echo "== first real header"\n'
        'check "after the heredoc" "1" "1"\n'
        'echo "== second real header"\n'
    )
    calls = parse_suite_source('f.sh', source)
    bash_call = next(c for c in calls if c.kind == 'bash')
    assert bash_call.scenario == '== first real header'


def test_parse_suite_source_tags_js_calls_with_the_given_file_path():
    calls = parse_suite_source('workflows/tests/test-worktree-checks.sh', JS_SUITE)
    js_calls = [c for c in calls if c.kind == 'js']
    assert js_calls
    assert all(c.file == 'workflows/tests/test-worktree-checks.sh' for c in js_calls)


def test_suite_ordered_groups_passes_heredocs_through_to_bash_headers():
    from assertion_discrimination import suite_ordered_groups
    assert suite_ordered_groups('echo "== only a header"\n') == [None, '== only a header']


def test_suite_ordered_groups_passes_source_through_to_js_header_texts_ordered():
    from assertion_discrimination import suite_ordered_groups
    source = (
        "run_js_scenarios <<'EOF'\n"
        "async function scenarioX() {\n"
        "  console.log('\\n== js header')\n"
        "}\n"
        "const SCENARIOS = [scenarioX]\n"
        "EOF\n"
    )
    assert suite_ordered_groups(source) == [None, '== js header']


def test_print_report_omits_the_scenario_bracket_when_there_is_none(capsys):
    from assertion_discrimination import _print_report, Report
    r = Report(file='f.sh', line=1, scenario=None, label='x', reason='y')
    _print_report(r)
    assert capsys.readouterr().out == 'f.sh:1: "x": y\n'


def test_parse_args_usage_message_is_exact():
    from assertion_discrimination import _parse_args
    assert _parse_args([]) == 'usage: assertion_discrimination.py <repo> <base-sha> <head-sha>'


def test_gather_reports_returns_exit_code_zero_on_success(monkeypatch):
    import assertion_discrimination as ad
    monkeypatch.setattr(ad, 'find_reports', lambda repo, base, head: [])
    _reports, code = ad._gather_reports('.', 'b', 'h')
    assert code == 0


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


def test_require_records_raises_with_the_actual_file_name():
    from assertion_discrimination import _require_records, NoRecordsError
    import pytest
    with pytest.raises(NoRecordsError) as exc_info:
        _require_records({'workflows/tests/test-static.sh': False})
    assert exc_info.value.file == 'workflows/tests/test-static.sh'


_TWO_SECTION_SUITE = (
    '#!/usr/bin/env bash\n'
    'failures=0\n'
    'check() { local label="$1" got="$2" want="$3"; if [ "$got" = "$want" ]; then '
    'echo "  ok:   $label ($got)"; else echo "  FAIL: $label (got $got, want $want)"; '
    'failures=$((failures+1)); fi; }\n'
    'echo "== section A"\n'
    'check "a" "1" "1"\n'
    'echo "== section B"\n'
    'check "b" "1" "1"\n'
    'echo ""\n'
    'if [ "$failures" -eq 0 ]; then exit 0; else exit 1; fi\n'
)


def test_run_groups_looks_up_each_groups_own_block_by_its_own_scenario(tmp_path):
    from assertion_discrimination import _run_groups, HeadIndex
    rel = 'workflows/tests/test-groups.sh'
    (tmp_path / 'workflows' / 'tests').mkdir(parents=True)
    (tmp_path / rel).write_text(_TWO_SECTION_SUITE)
    calls = parse_suite_source(rel, _TWO_SECTION_SUITE)
    head = HeadIndex(calls={rel: calls}, sources={rel: _TWO_SECTION_SUITE})
    results = _run_groups(str(tmp_path), head, calls)
    for _file, group, statuses, _saw_record in results:
        for c in group:
            assert statuses[c] == 'ok'


def test_run_groups_defaults_to_an_empty_block_for_a_scenario_the_run_never_printed(tmp_path):
    from assertion_discrimination import _run_groups, HeadIndex, Call
    rel = 'workflows/tests/test-groups.sh'
    (tmp_path / 'workflows' / 'tests').mkdir(parents=True)
    (tmp_path / rel).write_text(_TWO_SECTION_SUITE)
    orphan = Call(kind='bash', file=rel, start_line=1, end_line=1,
                  scenario='== a scenario the suite never prints',
                  label_src='"orphan"', label='orphan', got_src='"1"', want_src='"1"',
                  text='orphan', dependent=False)
    head = HeadIndex(calls={rel: [orphan]}, sources={rel: _TWO_SECTION_SUITE})
    results = _run_groups(str(tmp_path), head, [orphan])
    [(_file, group, statuses, _saw_record)] = results
    assert group == [orphan]
    assert statuses[orphan] is None


def test_passing_at_head_saw_record_tracks_each_files_own_history(monkeypatch):
    # gh-96: crafts two _run_groups entries for the same file with differing
    # this_run_had_records, which real _run_groups output never does (every
    # entry for one file shares one run's saw_any_record) -- the only way to
    # exercise saw_record's own merge instead of always seeing it as a no-op.
    import assertion_discrimination as ad
    call_a = Call(kind='bash', file='f', start_line=1, end_line=1, scenario='s1',
                  label_src='"a"', label='a', got_src='"1"', want_src='"1"',
                  text='a', dependent=False)
    call_b = Call(kind='bash', file='f', start_line=2, end_line=2, scenario='s2',
                  label_src='"b"', label='b', got_src='"1"', want_src='"1"',
                  text='b', dependent=False)

    def fake_run_groups(tree, head, calls):
        return [
            ('f', [call_a], {call_a: 'ok'}, True),
            ('f', [call_b], {call_b: 'ok'}, False),
        ]

    monkeypatch.setattr(ad, '_run_groups', fake_run_groups)
    passing = ad._passing_at_head('tree', object(), [call_a, call_b])
    assert passing == [call_a, call_b]
