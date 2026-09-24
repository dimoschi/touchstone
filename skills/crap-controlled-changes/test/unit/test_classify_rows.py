import pytest

import classify_rows
import next_action
import thresholds

TH = thresholds.DEFAULTS


def plain(base, current, th=TH):
    return classify_rows.classify(base, current, "plain", th)


def go(base, current, th=TH):
    return classify_rows.classify(base, current, "go", th)


def parsed(line):
    match = next_action.ROW.match(line)
    assert match, f"next_action cannot parse the row this module printed: {line!r}"
    return match.groupdict()


def test_a_function_absent_from_the_baseline_is_new():
    [row] = plain("", "mod.py::f\t3\t100.0\t3.0")
    assert parsed(row) == {"id": "mod.py::f", "cc": "3", "cov": "100.0",
                           "crap": "3.0", "status": "OK", "tag": "new"}


def test_a_function_at_the_same_score_is_unchanged():
    [row] = plain("mod.py::f\t3\t100.0\t3.0", "mod.py::f\t3\t100.0\t3.0")
    assert parsed(row)["tag"] == "unchanged"


def test_a_function_that_scores_worse_is_worsened():
    [row] = plain("mod.py::f\t3\t100.0\t3.0", "mod.py::f\t5\t100.0\t5.0")
    assert parsed(row)["tag"] == "worsened"


def test_a_score_that_barely_moves_is_not_worsened():
    [row] = plain("mod.py::f\t3\t100.0\t3.00", "mod.py::f\t3\t100.0\t3.02")
    assert parsed(row)["tag"] == "unchanged"


def test_a_new_undertested_function_owes_tests():
    [row] = plain("", "mod.py::f\t1\t0.0\t2.0")
    assert parsed(row)["status"] == "NEEDS_TESTS"


def test_an_untouched_undertested_function_is_left_alone():
    [row] = plain("mod.py::f\t1\t0.0\t2.0", "mod.py::f\t1\t0.0\t2.0")
    assert parsed(row)["status"] == "OK"


def test_the_configured_caps_decide_the_band():
    loose = TH._replace(soft=8, hard=10)
    [row] = plain("", "mod.py::f\t8\t100.0\t8.0", th=loose)
    assert parsed(row)["status"] == "OK"


def test_a_main_package_function_is_scored_on_complexity_with_no_coverage():
    [row] = go("", "main.run main 4 0.0 16.0")
    assert parsed(row) == {"id": "main.run", "cc": "4", "cov": "n/a",
                           "crap": "n/a", "status": "OK_MAIN", "tag": "new"}


def test_a_main_package_function_over_its_cap_is_hard():
    [row] = go("", "main.run main 9 0.0 90.0")
    assert parsed(row)["status"] == "HARD_MAIN"


def test_the_main_package_cap_is_configurable():
    [row] = go("", "main.run main 7 0.0 49.0", th=TH._replace(main=7))
    assert parsed(row)["status"] == "OK_MAIN"


def test_a_non_main_go_function_is_scored_on_crap():
    [row] = go("", "app.Run app 3 100.0 3.0")
    assert parsed(row) == {"id": "app.Run", "cc": "3", "cov": "100.0",
                           "crap": "3.0", "status": "OK", "tag": "new"}


def test_a_function_with_no_crap_figure_is_scored_as_zero():
    [row] = plain("", "mod.py::f\t3\tn/a\tn/a")
    assert parsed(row)["status"] == "OK"


def test_blank_lines_in_a_measurement_are_skipped():
    assert plain("", "\n\nmod.py::f\t3\t100.0\t3.0\n\n") == \
        plain("", "mod.py::f\t3\t100.0\t3.0")


def test_a_plain_row_carries_no_package():
    rows = classify_rows.parse_rows("mod.py::f\t3\t100.0\t3.0", False, "\t")
    assert rows["mod.py::f"] == {"id": "mod.py::f", "pkg": "", "cc": "3",
                                 "cov": "100.0", "crap": "3.0"}


def test_a_go_row_carries_its_package():
    rows = classify_rows.parse_rows("app.Run app 3 100.0 3.0", True, None)
    assert rows["app.Run"]["pkg"] == "app"


def test_a_plain_id_may_contain_a_space():
    """PHP and Python ids are file paths, which is why those rows are tab-separated.

    Asserted on the row text rather than through next_action.ROW, which matches
    an id as \\S+ and so cannot carry one either way.
    """
    [row] = plain("", "src/My File.php::C::m\t3\t100.0\t3.0")
    assert row.startswith("src/My File.php::C::m ")


def test_a_baseline_id_with_a_space_still_joins():
    same = "src/My File.php::C::m\t3\t100.0\t3.0"
    [row] = plain(same, same)
    assert row.endswith("(unchanged)")


def test_a_go_row_missing_its_package_column_is_not_measured():
    assert go("", "app.Run 3 100.0 3.0") == []


def test_a_row_with_no_crap_figure_scores_zero_not_one():
    assert classify_rows.score({"pkg": "", "cc": "3", "crap": "n/a"}) == 0.0


def test_a_score_exactly_one_epsilon_worse_is_not_yet_worsened():
    [row] = plain("mod.py::f\t3\t100.0\t3.00", "mod.py::f\t3\t100.0\t3.05")
    assert parsed(row)["tag"] == "unchanged"


def test_a_main_package_baseline_is_compared_on_complexity_too():
    """Comparing a main row against its CRAP would hide a complexity increase."""
    [row] = go("main.run main 3 0.0 30.0", "main.run main 5 0.0 50.0")
    assert parsed(row)["tag"] == "worsened"


def test_an_undertested_row_reaches_the_tests_directive_through_this_module():
    [row] = plain("", "mod.py::f\t5\t30.0\t13.6")
    assert parsed(row)["status"] == "NEEDS_TESTS"


def test_the_cli_refuses_a_call_missing_any_required_flag(tmp_path):
    """One flag at a time: dropping two leaves the other's own check to fire."""
    (tmp_path / "m.tsv").write_text("")
    complete = ["--base", str(tmp_path / "m.tsv"), "--current", str(tmp_path / "m.tsv"),
                "--layout", "plain", "--repo-root", str(tmp_path)]
    for flag in range(0, len(complete), 2):
        with pytest.raises(SystemExit):
            classify_rows.main(complete[:flag] + complete[flag + 2:])


def test_the_cli_refuses_a_layout_it_does_not_have(tmp_path):
    (tmp_path / "m.tsv").write_text("")
    with pytest.raises(SystemExit):
        classify_rows.main(["--base", str(tmp_path / "m.tsv"),
                            "--current", str(tmp_path / "m.tsv"),
                            "--layout", "perl", "--repo-root", str(tmp_path)])


def measurement(tmp_path, current):
    (tmp_path / "base.tsv").write_text("")
    (tmp_path / "cur.tsv").write_text(current)
    return ["--base", str(tmp_path / "base.tsv"), "--current", str(tmp_path / "cur.tsv"),
            "--layout", "plain", "--repo-root", str(tmp_path)]


def test_the_cli_prints_a_row_per_measured_function(tmp_path, capsys):
    assert classify_rows.main(measurement(tmp_path, "mod.py::f\t3\t100.0\t3.0\n")) == 0
    assert parsed(capsys.readouterr().out.strip())["id"] == "mod.py::f"


def test_the_cli_takes_its_thresholds_from_the_named_repo(tmp_path, capsys):
    argv = measurement(tmp_path, "mod.py::f\t8\t100.0\t8.0\n")
    (tmp_path / ".crap-gated").write_text("crap-soft = 8\n")
    assert classify_rows.main(argv) == 0
    assert parsed(capsys.readouterr().out.strip())["status"] == "OK"


def test_an_unreadable_measurement_raises_rather_than_reporting_no_rows(tmp_path):
    """Every caller reads an empty row set as "nothing to score, clean pass"."""
    argv = measurement(tmp_path, "")
    (tmp_path / "cur.tsv").unlink()
    with pytest.raises(OSError):
        classify_rows.main(argv)


def test_every_measured_function_gets_exactly_one_row():
    out = plain("", "a.py::f\t1\t100.0\t1.0\nb.py::g\t2\t100.0\t2.0")
    assert [parsed(r)["id"] for r in out] == ["a.py::f", "b.py::g"]
