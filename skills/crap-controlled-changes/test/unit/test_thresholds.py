import subprocess
import sys
from pathlib import Path

import pytest

import thresholds


def show(repo_root, name):
    done = subprocess.run(
        [sys.executable, thresholds.__file__, "--repo-root", str(repo_root), "--show", name],
        capture_output=True, text=True, check=True,
    )
    return done.stdout.strip()


def test_a_whole_setting_prints_without_a_decimal_tail(tmp_path):
    """gocognit -over and complexipy -mx both take an integer."""
    assert show(tmp_path, "cognitive") == "15"
    assert show(tmp_path, "hard") == "8"


def test_the_cli_reports_a_configured_setting(tmp_path):
    (tmp_path / ".crap-gated").write_text("cognitive-complexity = 20\n")
    assert show(tmp_path, "cognitive") == "20"


def test_the_cli_reports_the_derived_coverage_minimum(tmp_path):
    assert float(show(tmp_path, "min-coverage")) == pytest.approx(17.8, abs=0.1)


def test_a_fractional_setting_keeps_its_decimal(tmp_path):
    (tmp_path / ".crap-gated").write_text("crap-soft = 6.5\n")
    assert show(tmp_path, "soft") == "6.5"


def test_a_comment_may_itself_contain_an_equals_sign(tmp_path):
    assert marker(tmp_path, "crap-hard = 10  # was = 8\n") == \
        thresholds.DEFAULTS._replace(hard=10)


def test_a_complexity_beyond_the_cap_is_clamped_not_left_negative(tmp_path):
    """A negative ratio to a fractional power is complex, not a low number."""
    assert thresholds.implied_coverage(20, 8) == 100


def test_a_complexity_far_under_the_cap_is_clamped_to_no_requirement():
    assert thresholds.implied_coverage(1, 8) == 0


def test_min_coverage_starts_at_the_smallest_possible_complexity():
    """A cap under 2 is already binding at complexity 1."""
    assert thresholds.min_coverage(1.5) == pytest.approx(thresholds.implied_coverage(1, 1.5))
    assert thresholds.min_coverage(1.5) != 100


def test_coverage_exactly_at_the_minimum_is_enough():
    at_minimum = thresholds.min_coverage(thresholds.DEFAULTS.hard)
    assert status(1, at_minimum) == "OK"


def test_a_passing_score_is_never_reopened_by_the_coverage_term():
    """cc=2 at 20% has a dominating coverage term but a CRAP score of 4.0."""
    assert thresholds.crap(2, 20) < thresholds.DEFAULTS.soft
    assert 2 * (1 - 20 / 100) ** 3 > 1
    assert status(2, 20) == "OK"


def test_a_coverage_term_exactly_equal_to_the_complexity_term_is_not_a_testing_gap():
    """cc=8 at 50%: 8 * 0.5^3 is exactly 1.0, so the terms are level."""
    assert 8 * (1 - 50 / 100) ** 3 == 1.0
    assert status(8, 50) == "HARD"


def test_a_coverage_term_just_over_the_complexity_term_is_a_testing_gap():
    assert 3 * (1 - 25 / 100) ** 3 > 1
    assert status(3, 25) == "NEEDS_TESTS"


def test_the_cli_refuses_a_call_missing_a_required_flag(tmp_path):
    for argv in ([], ["--repo-root", str(tmp_path)], ["--show", "hard"]):
        with pytest.raises(SystemExit):
            thresholds.main(argv)


def test_the_cli_refuses_a_setting_it_does_not_have(tmp_path):
    with pytest.raises(SystemExit):
        thresholds.main(["--repo-root", str(tmp_path), "--show", "elegance"])


def test_main_reports_a_setting_on_stdout(tmp_path, capsys):
    assert thresholds.main(["--repo-root", str(tmp_path), "--show", "main"]) == 0
    assert capsys.readouterr().out == "5\n"


def test_main_reports_the_derived_minimum_from_the_configured_cap(tmp_path, capsys):
    (tmp_path / ".crap-gated").write_text("crap-hard = 10\n")
    assert thresholds.main(["--repo-root", str(tmp_path), "--show", "min-coverage"]) == 0
    assert float(capsys.readouterr().out) == pytest.approx(thresholds.min_coverage(10))


def test_the_pathspec_reader_skips_every_setting_key(tmp_path):
    """The three gates read this same marker as gitignore-style patterns.

    A key thresholds.py knows but lib/unsupported-sources.sh does not becomes an
    exemption pattern, which silently drops paths from measurement.
    """
    settings = "".join(f"{key} = 1\n" for key in thresholds.SETTINGS)
    (tmp_path / ".crap-gated").write_text(settings + "vendor/**\n")
    lib = Path(thresholds.__file__).parent / "unsupported-sources.sh"
    done = subprocess.run(
        ["bash", "-c", f'source "{lib}"; crap_exempt_pathspecs "$1"', "_", str(tmp_path)],
        capture_output=True, text=True, check=True,
    )
    assert done.stdout.split() == [":(glob,exclude,top)vendor/**"]


def test_defaults_are_the_values_the_gate_shipped_with():
    assert thresholds.DEFAULTS.soft == 6
    assert thresholds.DEFAULTS.hard == 8
    assert thresholds.DEFAULTS.main == 5
    assert thresholds.DEFAULTS.cognitive == 15


def test_a_repo_with_no_marker_gets_the_defaults(tmp_path):
    assert thresholds.load(str(tmp_path)) == thresholds.DEFAULTS


def test_an_empty_marker_gets_the_defaults(tmp_path):
    (tmp_path / ".crap-gated").write_text("")
    assert thresholds.load(str(tmp_path)) == thresholds.DEFAULTS


def marker(tmp_path, text):
    (tmp_path / ".crap-gated").write_text(text)
    return thresholds.load(str(tmp_path))


def test_each_setting_is_read_from_the_marker(tmp_path):
    got = marker(tmp_path, "crap-soft = 8\ncrap-hard = 10\n"
                           "main-complexity = 7\ncognitive-complexity = 20\n")
    assert got == thresholds.Thresholds(soft=8, hard=10, main=7, cognitive=20)


def test_settings_the_marker_omits_keep_their_default(tmp_path):
    assert marker(tmp_path, "crap-hard = 10\n") == thresholds.DEFAULTS._replace(hard=10)


def test_exemption_patterns_are_not_settings(tmp_path):
    assert marker(tmp_path, "workflows/*.js\nlib/mainrange.go\n") == thresholds.DEFAULTS


def test_a_commented_out_setting_is_ignored(tmp_path):
    assert marker(tmp_path, "# crap-hard = 10\n") == thresholds.DEFAULTS


def test_a_trailing_comment_is_stripped_from_the_value(tmp_path):
    assert marker(tmp_path, "crap-hard = 10  # branch budget of 9\n") == \
        thresholds.DEFAULTS._replace(hard=10)


def test_an_unknown_key_is_ignored(tmp_path):
    assert marker(tmp_path, "crap-medium = 7\n") == thresholds.DEFAULTS


def test_a_malformed_value_falls_back_to_the_default(tmp_path):
    assert marker(tmp_path, "crap-hard = ten\n") == thresholds.DEFAULTS


def test_a_non_finite_setting_is_rejected(tmp_path):
    assert marker(tmp_path, "crap-hard = inf\n") == thresholds.DEFAULTS
    assert marker(tmp_path, "crap-hard = nan\n") == thresholds.DEFAULTS


def test_whitespace_around_a_setting_does_not_matter(tmp_path):
    assert marker(tmp_path, "   crap-hard=10   \n") == thresholds.DEFAULTS._replace(hard=10)


def test_an_unreadable_marker_falls_back_to_the_defaults(tmp_path):
    (tmp_path / ".crap-gated").mkdir()
    assert thresholds.load(str(tmp_path)) == thresholds.DEFAULTS


def test_crap_matches_the_published_formula():
    assert thresholds.crap(3, 100) == 3
    assert thresholds.crap(8, 0) == 72
    assert thresholds.crap(10, 80) == pytest.approx(10.8)


def test_implied_coverage_is_where_that_complexity_reaches_the_cap():
    for cc in (3, 4, 5, 6, 7):
        assert thresholds.crap(cc, thresholds.implied_coverage(cc, 8)) == pytest.approx(8)


def test_a_complexity_the_cap_passes_untested_implies_no_coverage():
    assert thresholds.implied_coverage(1, 8) == 0
    assert thresholds.implied_coverage(2, 8) == 0


def test_a_complexity_the_cap_cannot_pass_implies_full_coverage():
    assert thresholds.implied_coverage(9, 8) == 100


def test_min_coverage_is_the_lowest_non_zero_requirement_any_complexity_has():
    for hard in (6, 8, 10, 12):
        every = [thresholds.implied_coverage(cc, hard) for cc in range(1, 40)]
        assert thresholds.min_coverage(hard) == pytest.approx(min(c for c in every if c > 0))


def test_the_shipped_hard_cap_requires_about_18_percent():
    assert thresholds.min_coverage(8) == pytest.approx(17.8, abs=0.1)


def test_a_higher_cap_asks_for_less_coverage():
    assert thresholds.min_coverage(10) < thresholds.min_coverage(8) < thresholds.min_coverage(6)


def test_a_cap_nothing_can_satisfy_asks_for_full_coverage():
    assert thresholds.min_coverage(0.5) == 100


def status(cc, cov, tag="new", th=thresholds.DEFAULTS):
    return thresholds.classify(cc, thresholds.crap(cc, cov), cov, tag, False, th)


def test_the_bands_follow_the_crap_score():
    assert status(6, 100) == "OK"
    assert status(7, 100) == "SOFT"
    assert status(8, 100) == "SOFT"
    assert status(9, 100) == "HARD"


def test_the_bands_move_with_the_configured_caps():
    loose = thresholds.DEFAULTS._replace(soft=8, hard=10)
    assert status(8, 100, th=loose) == "OK"
    assert status(10, 100, th=loose) == "SOFT"
    assert status(11, 100, th=loose) == "HARD"


def test_a_function_below_the_derived_minimum_owes_tests():
    assert status(1, 0) == "NEEDS_TESTS"
    assert status(2, 0) == "NEEDS_TESTS"


def test_a_trivial_function_a_test_merely_reaches_is_covered_enough():
    assert status(1, 100) == "OK"
    assert status(2, 50) == "OK"


def test_an_undertested_function_is_sent_to_tests_not_to_refactoring():
    assert status(5, 30) == "NEEDS_TESTS"
    assert status(3, 10) == "NEEDS_TESTS"


def test_a_well_covered_but_complex_function_is_sent_to_refactoring():
    assert status(9, 100) == "HARD"
    assert status(9, 80) == "HARD"
    assert status(5, 60) == "SOFT"


def test_a_function_this_branch_did_not_worsen_is_never_held_for_tests():
    assert status(1, 0, tag="unchanged") == "OK"
    assert status(5, 30, tag="unchanged") == "HARD"


def test_a_worsened_function_is_held_to_the_same_rule_as_a_new_one():
    assert status(1, 0, tag="worsened") == "NEEDS_TESTS"


def test_a_row_with_no_coverage_figure_is_judged_on_its_score_alone():
    assert thresholds.classify(6, 6, None, "new", False, thresholds.DEFAULTS) == "OK"
    assert thresholds.classify(9, 9, None, "new", False, thresholds.DEFAULTS) == "HARD"


def test_a_main_package_function_is_judged_on_complexity_alone():
    th = thresholds.DEFAULTS
    assert thresholds.classify(5, 5, None, "new", True, th) == "OK_MAIN"
    assert thresholds.classify(6, 6, None, "new", True, th) == "HARD_MAIN"


def test_the_main_package_cap_is_configurable():
    th = thresholds.DEFAULTS._replace(main=7)
    assert thresholds.classify(7, 7, None, "new", True, th) == "OK_MAIN"
    assert thresholds.classify(8, 8, None, "new", True, th) == "HARD_MAIN"
