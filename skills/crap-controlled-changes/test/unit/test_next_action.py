import argparse
import io
import json

import next_action

ROW_OK = 'pkg.Fine                                           complexity=3   coverage=100.0%  CRAP=3.0  OK           (new)'
ROW_NEEDS = 'pkg.NeedsTests                                     complexity=5   coverage=40.0%  CRAP=12.0  NEEDS_TESTS  (new)'
ROW_HARD = 'pkg.Big                                            complexity=9   coverage=88.0%  CRAP=9.2  HARD         (new)'
ROW_SOFT = 'pkg.Softy                                          complexity=7   coverage=90.0%  CRAP=7.1  SOFT         (new)'
ROW_SOFT2 = 'pkg.Softy                                          complexity=7   coverage=92.0%  CRAP=7.5  SOFT         (new)'
ROW_SOFT_WORSE = 'pkg.Softy                                          complexity=9   coverage=92.0%  CRAP=9.0  HARD         (worsened)'
ROW_LEGACY = 'pkg.Legacy                                         complexity=12  coverage=50.0%  CRAP=22.5  HARD         (unchanged)'
ROW_MAIN = 'main.run                                           complexity=9   coverage=n/a    CRAP=n/a    HARD_MAIN    (new)'


def _run(monkeypatch, state_file, stdin_text, capsys, accept=None):
    monkeypatch.setattr("sys.stdin", io.StringIO(stdin_text))
    args = argparse.Namespace(state_file=str(state_file), branch="main", accept=accept)
    rc = next_action.run(args)
    return rc, capsys.readouterr().out


def test_score_uses_complexity_for_main_variants():
    assert next_action.score("HARD_MAIN", "9", "n/a") == 9.0
    assert next_action.score("OK_MAIN", "3", "n/a") == 3.0


def test_score_uses_crap_otherwise():
    assert next_action.score("HARD", "9", "9.2") == 9.2
    assert next_action.score("HARD", "9", "n/a") == 0.0


def test_load_state_missing_or_invalid_returns_empty(tmp_path):
    assert next_action.load_state(str(tmp_path / "nope.json")) == {}
    bad = tmp_path / "state.json"
    bad.write_text("{not json")
    assert next_action.load_state(str(bad)) == {}


def test_metrics_str_main_vs_normal():
    assert next_action.metrics_str({"status": "HARD_MAIN", "cc": "9"}) == "complexity=9"
    assert next_action.metrics_str({"status": "HARD", "crap": "9.2", "cc": "9", "cov": "88.0"}) == \
        "CRAP=9.2, complexity=9, coverage=88.0%"


def test_surface_text_all_three_variants():
    hard_main = next_action.surface_text({"id": "m.run", "status": "HARD_MAIN", "cc": "9"})
    assert "main should stay thin" in hard_main
    soft = next_action.surface_text({"id": "pkg.S", "status": "SOFT", "crap": "7.1", "cc": "7", "cov": "90.0"})
    assert "One refactor pass" in soft
    hard = next_action.surface_text({"id": "pkg.H", "status": "HARD", "crap": "9.2", "cc": "9", "cov": "88.0"})
    assert "split along a clear axis" in hard


def test_refactor_hint_main_vs_normal():
    assert "main should stay thin" in next_action.refactor_hint({"status": "HARD_MAIN"})
    assert "extract a helper" in next_action.refactor_hint({"status": "HARD"})


def test_t1_all_green_commit_ok(tmp_path, monkeypatch, capsys):
    state = tmp_path / "state.json"
    rc, out = _run(monkeypatch, state, ROW_OK + "\n", capsys)
    assert rc == 0
    assert "COMMIT_OK" in out


def test_t2_needs_tests_beats_hard(tmp_path, monkeypatch, capsys):
    state = tmp_path / "state.json"
    rc, out = _run(monkeypatch, state, ROW_NEEDS + "\n" + ROW_HARD + "\n", capsys)
    assert rc == 1
    assert "WRITE_TESTS" in out
    assert "pkg.NeedsTests" in out
    assert "REFACTOR" not in out
    assert "pkg.Big" in out


def test_t3_t4_t5_t6_t7_soft_attempt_lifecycle(tmp_path, monkeypatch, capsys):
    state = tmp_path / "state.json"

    # T3: first SOFT run -> REFACTOR, attempt 1 of 1
    rc, out = _run(monkeypatch, state, ROW_SOFT + "\n", capsys)
    assert rc == 1
    assert "REFACTOR" in out
    assert "attempt 1 of 1" in out

    # T4: identical re-run burns no attempt
    rc, out = _run(monkeypatch, state, ROW_SOFT + "\n", capsys)
    assert "attempt 1 of 1" in out

    # T5: metrics changed, still SOFT -> attempts exhausted -> SURFACE_TO_USER
    rc, out = _run(monkeypatch, state, ROW_SOFT2 + "\n", capsys)
    assert rc == 1
    assert "SURFACE_TO_USER" in out
    assert "--accept" in out

    # T6: user accepts -> COMMIT_OK with note
    rc = next_action.run(argparse.Namespace(state_file=str(state), branch="main", accept="pkg.Softy"))
    assert rc == 0
    capsys.readouterr()
    rc, out = _run(monkeypatch, state, ROW_SOFT2 + "\n", capsys)
    assert rc == 0
    assert "COMMIT_OK" in out
    assert "accepted" in out.lower()

    # T7: accepted function worsens -> acceptance revoked, gate red again
    rc, out = _run(monkeypatch, state, ROW_SOFT_WORSE + "\n", capsys)
    assert rc == 1
    assert "COMMIT_OK" not in out


def test_t8_hard_unchanged_legacy_passes_with_note(tmp_path, monkeypatch, capsys):
    state = tmp_path / "state.json"
    rc, out = _run(monkeypatch, state, ROW_LEGACY + "\n", capsys)
    assert rc == 0
    assert "COMMIT_OK" in out
    assert "remains at CRAP=22.5" in out


def test_t9_hard_main_new_refactor_with_thin_main_guidance(tmp_path, monkeypatch, capsys):
    state = tmp_path / "state.json"
    rc, out = _run(monkeypatch, state, ROW_MAIN + "\n", capsys)
    assert rc == 1
    assert "REFACTOR" in out
    assert "main" in out.lower()
    assert "extract" in out.lower()


def test_t10_hard_gets_two_attempts_before_surfacing(tmp_path, monkeypatch, capsys):
    state = tmp_path / "state.json"
    rc, out = _run(monkeypatch, state, ROW_HARD + "\n", capsys)
    assert "attempt 1 of 2" in out
    row2 = 'pkg.Big                                            complexity=9   coverage=90.0%  CRAP=9.1  HARD         (new)'
    rc, out = _run(monkeypatch, state, row2 + "\n", capsys)
    assert "attempt 2 of 2" in out
    row3 = 'pkg.Big                                            complexity=9   coverage=91.0%  CRAP=9.0  HARD         (new)'
    rc, out = _run(monkeypatch, state, row3 + "\n", capsys)
    assert "SURFACE_TO_USER" in out


def test_t11_passing_functions_stale_state_is_dropped(tmp_path, monkeypatch, capsys):
    state = tmp_path / "state.json"
    _run(monkeypatch, state, ROW_SOFT + "\n", capsys)
    ok_row = 'pkg.Softy                                          complexity=4   coverage=95.0%  CRAP=4.0  OK           (new)'
    rc, out = _run(monkeypatch, state, ok_row + "\n", capsys)
    assert rc == 0
    assert "pkg.Softy" not in state.read_text()


def test_refactor_and_surfaced_can_coexist_in_one_run(tmp_path, monkeypatch, capsys):
    state = tmp_path / "state.json"
    # First run: Softy goes to REFACTOR (attempt 1 of 1, one attempt allowed).
    _run(monkeypatch, state, ROW_SOFT + "\n", capsys)
    # Second run: Softy's metrics changed with attempts already spent -> surfaced;
    # Big appears fresh in the same run -> refactor. Both lists are non-empty.
    rc, out = _run(monkeypatch, state, ROW_SOFT2 + "\n" + ROW_HARD + "\n", capsys)
    assert rc == 1
    assert "REFACTOR" in out
    assert "pkg.Big" in out
    assert "need a user decision" in out


def test_notes_printed_alongside_a_red_verdict(tmp_path, monkeypatch, capsys):
    state = tmp_path / "state.json"
    rc, out = _run(monkeypatch, state, ROW_LEGACY + "\n" + ROW_NEEDS + "\n", capsys)
    assert rc == 1
    assert "WRITE_TESTS" in out
    assert "remains at CRAP=22.5" in out


def test_accept_with_no_recorded_state_errors(tmp_path, capsys):
    state = tmp_path / "state.json"
    rc = next_action.run(argparse.Namespace(state_file=str(state), branch="main", accept="pkg.Nope"))
    assert rc == 2
    assert "no recorded state" in capsys.readouterr().err


def test_unparseable_lines_are_ignored(tmp_path, monkeypatch, capsys):
    state = tmp_path / "state.json"
    rc, out = _run(monkeypatch, state, "not a report row\n", capsys)
    assert rc == 0
    assert "COMMIT_OK" in out


def test_main_entrypoint_exits_with_run_result(monkeypatch, tmp_path, capsys):
    state = tmp_path / "state.json"
    monkeypatch.setattr("sys.argv", ["next_action.py", "--state-file", str(state), "--branch", "main"])
    monkeypatch.setattr("sys.stdin", io.StringIO(ROW_OK + "\n"))
    try:
        next_action.main()
        assert False, "expected SystemExit"
    except SystemExit as exc:
        assert exc.code == 0


ROW_LOWCOV = 'pkg.LowCov                                        complexity=3   coverage=40.0%  CRAP=3.4  NEEDS_TESTS  (new)'
ROW_LOWCOV_THIN = 'pkg.LowCov                                        complexity=3   coverage=20.0%  CRAP=6.1  NEEDS_TESTS  (new)'


def test_needs_tests_row_can_be_accepted(tmp_path, monkeypatch, capsys):
    state = tmp_path / "state.json"
    rc, _ = _run(monkeypatch, state, ROW_LOWCOV, capsys)
    assert rc == 1
    assert next_action.run(
        argparse.Namespace(state_file=str(state), branch="main", accept="pkg.LowCov")) == 0
    capsys.readouterr()
    rc, out = _run(monkeypatch, state, ROW_LOWCOV, capsys)
    assert rc == 0
    assert "COMMIT_OK" in out
    assert "coverage=40.0%" in out


def test_accepted_coverage_falling_revokes_it(tmp_path, monkeypatch, capsys):
    state = tmp_path / "state.json"
    _run(monkeypatch, state, ROW_LOWCOV, capsys)
    next_action.run(
        argparse.Namespace(state_file=str(state), branch="main", accept="pkg.LowCov"))
    capsys.readouterr()
    rc, out = _run(monkeypatch, state, ROW_LOWCOV_THIN, capsys)
    assert rc == 1
    assert "COMMIT_OK" not in out


def test_accept_note_names_the_metric_each_status_is_judged_on(tmp_path):
    needs = {'id': 'pkg.A', 'status': 'NEEDS_TESTS', 'cov': '40.0', 'crap': '3.4', 'cc': '3'}
    main = {'id': 'main.run', 'status': 'HARD_MAIN', 'cov': 'n/a', 'crap': 'n/a', 'cc': '9'}
    plain = {'id': 'pkg.B', 'status': 'SOFT', 'cov': '90.0', 'crap': '7.1', 'cc': '7'}
    assert next_action.accept_note(needs) == 'pkg.A accepted by user at coverage=40.0% (CRAP=3.4)'
    assert next_action.accept_note(main) == 'main.run accepted by user at complexity=9'
    assert next_action.accept_note(plain) == 'pkg.B accepted by user at CRAP=7.1'


def test_an_acceptance_recorded_before_coverage_was_tracked_still_holds():
    row = {'score': 7.1, 'cov': '90.0', 'status': 'SOFT'}
    assert next_action.accepted_holds(row, {'accepted_score': 7.1}) is True


ROW_OK_MAIN = 'main.wire                                          complexity=3   coverage=n/a    CRAP=n/a    OK_MAIN      (new)'
ROW_MAIN_UNCHANGED = 'main.run                                           complexity=9   coverage=n/a    CRAP=n/a    HARD_MAIN    (unchanged)'
ROW_HARD_B = 'pkg.Big                                            complexity=9   coverage=90.0%  CRAP=9.1  HARD         (new)'
ROW_HARD_WORSE = 'pkg.Big                                            complexity=10  coverage=90.0%  CRAP=11.0  HARD         (new)'
ROW_HARD_UNCOVERED = 'pkg.Big                                            complexity=9   coverage=40.0%  CRAP=22.0  NEEDS_TESTS  (new)'
ROW_LOWCOV_SAME_CRAP_LESS_COV = 'pkg.LowCov                                        complexity=3   coverage=20.0%  CRAP=3.4  NEEDS_TESTS  (new)'


def test_coverage_is_the_row_percentage_or_none_for_a_main_row():
    assert next_action.coverage({'cov': '40.0'}) == 40.0
    assert next_action.coverage({'cov': 'n/a'}) is None


def test_recorded_entry_carries_the_rows_metrics_and_coverage():
    row = {'attempts': 1, 'metrics': ['3', '40.0', '3.4'], 'score': 3.4, 'cov': '40.0'}
    assert next_action.recorded(row, True) == {
        'attempts': 1, 'metrics': ['3', '40.0', '3.4'], 'directed': True,
        'score': 3.4, 'cov': 40.0}


def test_a_score_exactly_at_the_tolerance_still_holds():
    row = {'score': 7.0 + next_action.EPS, 'cov': 'n/a'}
    assert next_action.accepted_holds(row, {'accepted_score': 7.0}) is True


def test_coverage_exactly_at_the_tolerance_still_holds():
    row = {'score': 3.4, 'cov': repr(40.0 - next_action.EPS)}
    entry = {'accepted_score': 3.4, 'accepted_coverage': 40.0}
    assert next_action.accepted_holds(row, entry) is True


def test_coverage_below_the_accepted_level_revokes_at_an_unchanged_score():
    row = {'score': 3.4, 'cov': '20.0'}
    entry = {'accepted_score': 3.4, 'accepted_coverage': 40.0}
    assert next_action.accepted_holds(row, entry) is False


def test_commit_ok_prints_the_directive_and_nothing_else(tmp_path, monkeypatch, capsys):
    state = tmp_path / "state.json"
    rc, out = _run(monkeypatch, state, ROW_OK + "\n", capsys)
    assert rc == 0
    assert out == "== NEXT_ACTION ==\nCOMMIT_OK\n"


def test_a_note_on_a_green_run_is_printed_once(tmp_path, monkeypatch, capsys):
    state = tmp_path / "state.json"
    rc, out = _run(monkeypatch, state, ROW_LEGACY + "\n", capsys)
    assert rc == 0
    assert out == (
        "== NEXT_ACTION ==\n"
        "COMMIT_OK\n"
        "  note for commit body: pkg.Legacy remains at CRAP=22.5 (unchanged in this PR)\n")


def test_an_unchanged_main_row_notes_complexity_not_crap(tmp_path, monkeypatch, capsys):
    state = tmp_path / "state.json"
    rc, out = _run(monkeypatch, state, ROW_MAIN_UNCHANGED + "\n", capsys)
    assert rc == 0
    assert out == (
        "== NEXT_ACTION ==\n"
        "COMMIT_OK\n"
        "  note for commit body: main.run remains at complexity=9 (unchanged in this PR)\n")


def test_an_ok_main_row_is_skipped_like_an_ok_row(tmp_path, monkeypatch, capsys):
    state = tmp_path / "state.json"
    rc, out = _run(monkeypatch, state, ROW_OK_MAIN + "\n", capsys)
    assert rc == 0
    assert out == "== NEXT_ACTION ==\nCOMMIT_OK\n"
    assert json.loads(state.read_text()) == {"main": {}}


def test_a_passing_row_does_not_stop_the_scan(tmp_path, monkeypatch, capsys):
    state = tmp_path / "state.json"
    rc, out = _run(monkeypatch, state, ROW_OK + "\n" + ROW_SOFT + "\n", capsys)
    assert rc == 1
    assert "pkg.Softy" in out


def test_write_tests_directive_and_state_are_exact(tmp_path, monkeypatch, capsys):
    state = tmp_path / "state.json"
    rc, out = _run(monkeypatch, state, ROW_NEEDS + "\n" + ROW_HARD + "\n", capsys)
    assert rc == 1
    assert out == (
        "== NEXT_ACTION ==\n"
        "WRITE_TESTS: new/worsened functions are undertested for their\n"
        "complexity. A high CRAP score here is a symptom of missing tests,\n"
        "not bad structure. Do NOT edit source files. Invoke\n"
        "superpowers:test-driven-development, write tests for these\n"
        "functions, see them pass, then re-run crap-check.sh:\n"
        "  - pkg.NeedsTests (CRAP=12.0, complexity=5, coverage=40.0%)\n"
        "If one of these genuinely cannot be covered, ask the user, then on\n"
        "their approval: crap-check.sh --accept '<function-id>'\n"
        "Also failing, deferred until tests exist:\n"
        "  - pkg.Big (CRAP=9.2, complexity=9, coverage=88.0%)\n")
    assert json.loads(state.read_text()) == {"main": {
        "pkg.NeedsTests": {"attempts": 0, "metrics": ["5", "40.0", "12.0"],
                           "directed": False, "score": 12.0, "cov": 40.0},
        "pkg.Big": {"attempts": 0, "metrics": ["9", "88.0", "9.2"],
                    "directed": False, "score": 9.2, "cov": 88.0}}}


def test_refactor_directive_and_state_are_exact(tmp_path, monkeypatch, capsys):
    state = tmp_path / "state.json"
    rc, out = _run(monkeypatch, state, ROW_SOFT + "\n", capsys)
    assert rc == 1
    assert out == (
        "== NEXT_ACTION ==\n"
        "REFACTOR: then re-run crap-check.sh. Do not commit yet.\n"
        "  - pkg.Softy (CRAP=7.1, complexity=7, coverage=90.0%) [new] attempt 1 of 1: "
        "one focused pass: extract a helper or flatten a conditional\n")
    assert json.loads(state.read_text()) == {"main": {
        "pkg.Softy": {"attempts": 0, "metrics": ["7", "90.0", "7.1"],
                      "directed": True, "score": 7.1, "cov": 90.0}}}


def test_a_surfaced_row_deferred_behind_a_refactor_is_recorded_undirected(
        tmp_path, monkeypatch, capsys):
    state = tmp_path / "state.json"
    _run(monkeypatch, state, ROW_SOFT + "\n", capsys)
    rc, out = _run(monkeypatch, state, ROW_SOFT2 + "\n" + ROW_HARD + "\n", capsys)
    assert rc == 1
    assert out == (
        "== NEXT_ACTION ==\n"
        "REFACTOR: then re-run crap-check.sh. Do not commit yet.\n"
        "  - pkg.Big (CRAP=9.2, complexity=9, coverage=88.0%) [new] attempt 1 of 2: "
        "one focused pass: extract a helper or flatten a conditional\n"
        "After these, 1 function(s) need a user decision (SURFACE_TO_USER will follow).\n")
    assert json.loads(state.read_text()) == {"main": {
        "pkg.Big": {"attempts": 0, "metrics": ["9", "88.0", "9.2"],
                    "directed": True, "score": 9.2, "cov": 88.0},
        "pkg.Softy": {"attempts": 1, "metrics": ["7", "92.0", "7.5"],
                      "directed": False, "score": 7.5, "cov": 92.0}}}


def test_surface_directive_and_state_are_exact(tmp_path, monkeypatch, capsys):
    state = tmp_path / "state.json"
    _run(monkeypatch, state, ROW_SOFT + "\n", capsys)
    rc, out = _run(monkeypatch, state, ROW_SOFT2 + "\n", capsys)
    assert rc == 1
    assert out == (
        "== NEXT_ACTION ==\n"
        "SURFACE_TO_USER: refactor attempts are exhausted. Do not edit\n"
        "further. Ask the user, quoting per function:\n"
        "  - pkg.Softy: \"pkg.Softy lands at CRAP=7.5 (complexity=7, coverage=92.0%). "
        "One refactor pass did not clear it without pushing complexity into the caller. "
        "Recommend accepting at 7.5. Approve, or try a different split?\"\n"
        "If the user approves accepting a score, run:\n"
        "  crap-check.sh --accept '<function-id>'   then re-run crap-check.sh\n")
    assert json.loads(state.read_text()) == {"main": {
        "pkg.Softy": {"attempts": 1, "metrics": ["7", "92.0", "7.5"],
                      "directed": False, "score": 7.5, "cov": 92.0}}}


def test_accept_records_the_score_and_the_coverage_it_approved(tmp_path, monkeypatch, capsys):
    state = tmp_path / "state.json"
    _run(monkeypatch, state, ROW_LOWCOV + "\n", capsys)
    rc = next_action.run(
        argparse.Namespace(state_file=str(state), branch="main", accept="pkg.LowCov"))
    assert rc == 0
    assert capsys.readouterr().out == (
        "next-action: recorded user acceptance of pkg.LowCov at score 3.4; "
        "re-run crap-check.sh\n")
    assert json.loads(state.read_text()) == {"main": {
        "pkg.LowCov": {"attempts": 0, "metrics": ["3", "40.0", "3.4"],
                       "directed": False, "score": 3.4, "cov": 40.0,
                       "accepted": True, "accepted_score": 3.4,
                       "accepted_coverage": 40.0}}}


def test_coverage_falling_at_an_unchanged_score_revokes_the_acceptance(
        tmp_path, monkeypatch, capsys):
    state = tmp_path / "state.json"
    _run(monkeypatch, state, ROW_LOWCOV + "\n", capsys)
    next_action.run(
        argparse.Namespace(state_file=str(state), branch="main", accept="pkg.LowCov"))
    capsys.readouterr()
    rc, out = _run(monkeypatch, state, ROW_LOWCOV_SAME_CRAP_LESS_COV + "\n", capsys)
    assert rc == 1
    assert "WRITE_TESTS" in out


def test_a_held_acceptance_is_carried_forward_and_does_not_stop_the_scan(
        tmp_path, monkeypatch, capsys):
    state = tmp_path / "state.json"
    _run(monkeypatch, state, ROW_LOWCOV + "\n", capsys)
    next_action.run(
        argparse.Namespace(state_file=str(state), branch="main", accept="pkg.LowCov"))
    capsys.readouterr()
    rc, out = _run(monkeypatch, state, ROW_LOWCOV + "\n" + ROW_SOFT + "\n", capsys)
    assert rc == 1
    assert "pkg.Softy" in out
    assert json.loads(state.read_text())["main"]["pkg.LowCov"] == {
        "attempts": 0, "metrics": ["3", "40.0", "3.4"], "directed": False,
        "score": 3.4, "cov": 40.0, "accepted": True, "accepted_score": 3.4,
        "accepted_coverage": 40.0}


def test_revoking_an_acceptance_keeps_the_attempts_already_spent(
        tmp_path, monkeypatch, capsys):
    state = tmp_path / "state.json"
    _run(monkeypatch, state, ROW_HARD + "\n", capsys)
    _run(monkeypatch, state, ROW_HARD_B + "\n", capsys)
    next_action.run(
        argparse.Namespace(state_file=str(state), branch="main", accept="pkg.Big"))
    capsys.readouterr()
    rc, out = _run(monkeypatch, state, ROW_HARD_WORSE + "\n", capsys)
    assert rc == 1
    assert "attempt 2 of 2" in out


def test_a_needs_tests_row_keeps_the_attempts_already_spent(tmp_path, monkeypatch, capsys):
    state = tmp_path / "state.json"
    _run(monkeypatch, state, ROW_HARD + "\n", capsys)
    _run(monkeypatch, state, ROW_HARD_B + "\n", capsys)
    rc, out = _run(monkeypatch, state, ROW_HARD_UNCOVERED + "\n", capsys)
    assert rc == 1
    assert json.loads(state.read_text())["main"]["pkg.Big"]["attempts"] == 1
