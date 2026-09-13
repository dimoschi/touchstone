import argparse
import io

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
