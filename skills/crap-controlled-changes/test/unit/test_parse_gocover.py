import parse_gocover

MOD = "example.com/m"


def write(tmp_path, name, text):
    path = tmp_path / name
    path.write_text(text)
    return str(path)


def spans(tmp_path, *rows):
    return write(tmp_path, "spans.tsv", "".join("\t".join(map(str, row)) + "\n" for row in rows))


def profile(tmp_path, *lines):
    return write(tmp_path, "cover.out", "mode: set\n" + "".join(f"{line}\n" for line in lines))


def run(tmp_path, spans_file, profile_file, *extra, moddir="."):
    return parse_gocover.main([spans_file, profile_file, MOD, moddir, *extra])


def test_a_function_scores_the_share_of_its_blocks_that_ran(tmp_path, capsys):
    s = spans(tmp_path, ("calc.go", 3, 12, 4, "calc.Branchy", "calc"))
    p = profile(tmp_path,
                f"{MOD}/calc.go:4.10,5.12 1 1",
                f"{MOD}/calc.go:6.2,7.3 1 0",
                f"{MOD}/calc.go:8.2,9.3 1 0",
                f"{MOD}/calc.go:10.2,11.3 1 1")
    assert run(tmp_path, s, p) == 0
    assert capsys.readouterr().out == "calc.Branchy calc 4 50.0 6.0\n"


def test_a_block_belongs_to_the_function_holding_its_first_line(tmp_path, capsys):
    s = spans(tmp_path, ("a.go", 1, 5, 1, "m.A", "m"), ("a.go", 7, 12, 2, "m.B", "m"))
    p = profile(tmp_path,
                f"{MOD}/a.go:2.2,4.3 1 1",
                f"{MOD}/a.go:8.2,9.3 1 0",
                f"{MOD}/a.go:10.2,11.3 1 1")
    run(tmp_path, s, p)
    assert capsys.readouterr().out.splitlines() == ["m.A m 1 100.0 1.0", "m.B m 2 50.0 2.5"]


def test_a_block_counted_twice_counts_once_and_ran_if_either_ran(tmp_path, capsys):
    s = spans(tmp_path, ("a.go", 1, 9, 1, "m.A", "m"))
    p = profile(tmp_path,
                f"{MOD}/a.go:2.5,4.9 2 3",
                f"{MOD}/a.go:2.2,4.3 1 0",
                f"{MOD}/a.go:6.2,8.3 1 1")
    run(tmp_path, s, p)
    assert capsys.readouterr().out == "m.A m 1 100.0 1.0\n"


def test_a_block_on_a_functions_first_or_last_line_is_its_own(tmp_path, capsys):
    s = spans(tmp_path, ("a.go", 3, 6, 2, "m.A", "m"))
    p = profile(tmp_path,
                f"{MOD}/a.go:2.2,2.9 1 1",
                f"{MOD}/a.go:3.2,3.9 1 1",
                f"{MOD}/a.go:6.2,6.9 1 0",
                f"{MOD}/a.go:7.2,7.9 1 1")
    run(tmp_path, s, p)
    assert capsys.readouterr().out == "m.A m 2 50.0 2.5\n"


def test_a_function_with_no_block_reads_as_untested(tmp_path, capsys):
    s = spans(tmp_path, ("a.go", 1, 3, 1, "m.A", "m"), ("a.go", 5, 9, 3, "m.B", "m"))
    p = profile(tmp_path, f"{MOD}/a.go:6.2,8.3 1 1")
    run(tmp_path, s, p)
    assert capsys.readouterr().out.splitlines() == ["m.A m 1 0.0 2.0", "m.B m 3 100.0 3.0"]


def test_a_nested_module_is_found_under_its_directory(tmp_path, capsys):
    s = spans(tmp_path, ("svc/pkg/a.go", 1, 5, 1, "pkg.A", "pkg"))
    p = profile(tmp_path, f"{MOD}/pkg/a.go:2.2,4.3 1 1")
    run(tmp_path, s, p, moddir="svc")
    assert capsys.readouterr().out == "pkg.A pkg 1 100.0 1.0\n"


def test_a_profile_line_of_another_module_is_ignored(tmp_path, capsys):
    s = spans(tmp_path, ("a.go", 1, 5, 1, "m.A", "m"))
    p = profile(tmp_path, "other.org/x/a.go:2.2,4.3 1 1", f"{MOD}/a.go:2.2,4.3 1 0")
    run(tmp_path, s, p)
    assert capsys.readouterr().out == "m.A m 1 0.0 2.0\n"


def test_mode_and_malformed_lines_are_skipped(tmp_path, capsys):
    s = spans(tmp_path, ("a.go", 1, 5, 1, "m.A", "m"))
    p = profile(tmp_path, "not a profile line", f"{MOD}/a.go:bad 1 1",
                f"{MOD}/a.go:x.1,4.3 1 1", f"{MOD}/a.go:3.2,4.3 1 many",
                f"{MOD}/a.go:3.2,4.3 1 0 extra", f"{MOD}/a.go:2.2,4.3 1 1")
    run(tmp_path, s, p)
    assert capsys.readouterr().out == "m.A m 1 100.0 1.0\n"


def test_a_file_the_profile_never_mentions_is_unmeasured_not_zero(tmp_path, capsys):
    s = spans(tmp_path, ("a.go", 1, 5, 1, "m.A", "m"), ("b.go", 1, 5, 2, "m.B", "m"))
    p = profile(tmp_path, f"{MOD}/a.go:2.2,4.3 1 1")
    out = tmp_path / "unmeasured.txt"
    assert run(tmp_path, s, p, "--unmeasured-out", str(out)) == 0
    assert capsys.readouterr().out == "m.A m 1 100.0 1.0\n"
    assert out.read_text() == "b.go\n"


def test_zero_filling_keeps_an_unmeasured_file_as_untested_and_still_lists_it(tmp_path, capsys):
    s = spans(tmp_path, ("b.go", 1, 5, 2, "m.B", "m"))
    p = profile(tmp_path, f"{MOD}/a.go:2.2,4.3 1 1")
    out = tmp_path / "unmeasured.txt"
    run(tmp_path, s, p, "--zero-fill-unmeasured", "--unmeasured-out", str(out))
    assert capsys.readouterr().out == "m.B m 2 0.0 6.0\n"
    assert out.read_text() == "b.go\n"


def test_a_file_the_build_leaves_out_is_neither_scored_nor_unmeasured(tmp_path, capsys):
    s = spans(tmp_path, ("a.go", 1, 5, 1, "m.A", "m"), ("a_windows.go", 1, 5, 2, "m.W", "m"))
    p = profile(tmp_path, f"{MOD}/a.go:2.2,4.3 1 1")
    built = write(tmp_path, "built.txt", f"{tmp_path}/a.go\n")
    out = tmp_path / "unmeasured.txt"
    run(tmp_path, s, p, "--built", built, "--unmeasured-out", str(out), "--root", str(tmp_path))
    assert capsys.readouterr().out == "m.A m 1 100.0 1.0\n"
    assert out.read_text() == ""


def test_a_file_the_build_leaves_out_is_scored_when_the_profile_holds_its_blocks(tmp_path, capsys):
    s = spans(tmp_path, ("a_integration.go", 1, 5, 2, "m.I", "m"), ("a_windows.go", 1, 5, 2, "m.W", "m"))
    p = profile(tmp_path, f"{MOD}/a_integration.go:2.2,4.3 1 1")
    built = write(tmp_path, "built.txt", "")
    out = tmp_path / "unmeasured.txt"
    run(tmp_path, s, p, "--built", built, "--unmeasured-out", str(out), "--root", str(tmp_path))
    assert capsys.readouterr().out == "m.I m 2 100.0 2.0\n"
    assert out.read_text() == ""


def test_without_an_unmeasured_file_asked_for_none_is_written(tmp_path):
    s = spans(tmp_path, ("a.go", 1, 5, 1, "m.A", "m"))
    p = profile(tmp_path, f"{MOD}/a.go:2.2,4.3 1 1")
    assert run(tmp_path, s, p) == 0
    assert not (tmp_path / "unmeasured.txt").exists()


def test_a_span_row_with_a_space_in_its_path_is_read_whole(tmp_path, capsys):
    s = spans(tmp_path, ("my dir/a.go", 1, 5, 1, "m.A", "m"))
    p = profile(tmp_path, f"{MOD}/other.go:2.2,4.3 1 1")
    out = tmp_path / "unmeasured.txt"
    run(tmp_path, s, p, "--unmeasured-out", str(out))
    assert out.read_text() == "my dir/a.go\n"


def test_a_span_row_with_an_empty_package_is_read(tmp_path, capsys):
    s = spans(tmp_path, ("a.go", 1, 5, 1, "m.A", ""))
    p = profile(tmp_path, f"{MOD}/a.go:2.2,4.3 1 1")
    run(tmp_path, s, p)
    assert capsys.readouterr().out == "m.A  1 100.0 1.0\n"


def test_a_span_row_whose_package_ends_in_x_keeps_it(tmp_path, capsys):
    s = spans(tmp_path, ("a.go", 1, 5, 1, "ctX.A", "ctX"))
    p = profile(tmp_path, f"{MOD}/a.go:2.2,4.3 1 1")
    run(tmp_path, s, p)
    assert capsys.readouterr().out == "ctX.A ctX 1 100.0 1.0\n"


def test_a_profile_field_without_a_colon_is_not_a_block():
    assert parse_gocover._block("2.2,4.3 1 1") is None


def test_a_profile_field_without_a_comma_is_not_a_block():
    assert parse_gocover._block("a.go:2.2 1 1") is None


def test_a_block_is_split_at_the_last_colon_of_the_path():
    assert parse_gocover._block("m/a:b.go:2.2,4.3 1 1") == ("m/a:b.go", 2, 4, True)


def test_a_block_ends_at_the_first_comma_after_its_start():
    assert parse_gocover._block("m/a.go:2.2,4.3,5 1 1") == ("m/a.go", 2, 4, True)


def test_blocks_ending_on_the_same_line_stay_separate_blocks(tmp_path, capsys):
    s = spans(tmp_path, ("a.go", 1, 9, 2, "m.A", "m"))
    p = profile(tmp_path, f"{MOD}/a.go:2.2,4.3 1 1", f"{MOD}/a.go:3.2,4.3 1 0")
    run(tmp_path, s, p)
    assert capsys.readouterr().out == "m.A m 2 50.0 2.5\n"


def test_a_file_the_build_includes_but_the_profile_lacks_is_unmeasured(tmp_path, capsys):
    s = spans(tmp_path, ("a.go", 1, 5, 1, "m.A", "m"))
    p = profile(tmp_path, f"{MOD}/other.go:2.2,4.3 1 1")
    built = write(tmp_path, "built.txt", f"{tmp_path}/a.go\n")
    out = tmp_path / "unmeasured.txt"
    run(tmp_path, s, p, "--built", built, "--unmeasured-out", str(out), "--root", str(tmp_path))
    assert capsys.readouterr().out == ""
    assert out.read_text() == "a.go\n"
