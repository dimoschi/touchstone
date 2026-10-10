import io
import json
from pathlib import Path

from conftest import load_script

gate_pipe = load_script(Path(__file__).resolve().parent / "gate-pipe-gate.py")


def test_pipes_a_gate_detects_pipe_after_gate_name():
    assert gate_pipe.pipes_a_gate("mutation-check.sh | tail -45") is True


def test_pipes_a_gate_false_when_gate_not_piped():
    assert gate_pipe.pipes_a_gate("mutation-check.sh > /tmp/out.log 2>&1") is False


def test_pipes_a_gate_false_when_pipe_unrelated_to_gate():
    assert gate_pipe.pipes_a_gate("echo hi | grep hi && mutation-check.sh") is False


def test_pipes_a_gate_false_for_or_and_semicolon_after_gate():
    assert gate_pipe.pipes_a_gate("crap-check.sh || echo failed") is False
    assert gate_pipe.pipes_a_gate("crap-check.sh; echo done") is False


def test_pipes_a_gate_checks_each_segment_independently():
    assert gate_pipe.pipes_a_gate("echo hi | grep hi; crap-check.sh | cat") is True


def _run(monkeypatch, cmd):
    monkeypatch.setattr("sys.stdin", io.StringIO(json.dumps({"tool_input": {"command": cmd}})))
    return gate_pipe.main()


def test_main_allows_non_piped_command(monkeypatch):
    assert _run(monkeypatch, "crap-check.sh") == 0


def test_main_blocks_piped_gate(monkeypatch, capsys):
    assert _run(monkeypatch, "crap-check.sh | tail") == 2
    assert "gate-pipe-gate" in capsys.readouterr().err


def test_main_ignores_quoted_pipe_in_commit_message(monkeypatch):
    cmd = 'git commit -m "crap-check.sh | tail is bad, do not do it"'
    assert _run(monkeypatch, cmd) == 0


def test_pipes_a_gate_false_for_clobber_redirect():
    assert gate_pipe.pipes_a_gate('mutation-check.sh /r --verify >|"$d/v.log" 2>&1') is False


def test_pipes_a_gate_true_for_real_pipe_beside_clobber_redirect():
    assert gate_pipe.pipes_a_gate('mutation-check.sh /r >|/tmp/a.log | tail') is True


def test_pipes_a_gate_true_for_stderr_pipe():
    assert gate_pipe.pipes_a_gate('mutation-check.sh /r |& tail') is True


def test_main_allows_gate_with_clobber_redirect(monkeypatch):
    cmd = '{ mutation-check.sh /r --verify >|"$d/mutation-verify.log" 2>&1; e=$?; }'
    assert _run(monkeypatch, cmd) == 0


def test_pipes_a_gate_true_for_brace_group_piped():
    assert gate_pipe.pipes_a_gate("{ mutation-check.sh /r; } | tail") is True


def test_pipes_a_gate_true_for_subshell_piped():
    assert gate_pipe.pipes_a_gate("(crap-check.sh /r && true) | tail") is True


def test_pipes_a_gate_true_for_nested_group_piped():
    assert gate_pipe.pipes_a_gate("( { crap-check.sh /r; }; echo x ) |& tail") is True


def test_pipes_a_gate_true_for_pipe_inside_group():
    assert gate_pipe.pipes_a_gate("{ crap-check.sh /r | tail; }") is True


def test_pipes_a_gate_false_for_group_redirected_to_file():
    assert gate_pipe.pipes_a_gate("{ mutation-check.sh /r; } > /tmp/g.log 2>&1") is False
    assert gate_pipe.pipes_a_gate("(crap-check.sh /r) >/tmp/g.log; echo x | cat") is False


def test_pipes_a_gate_false_after_group_closes_and_list_continues():
    assert gate_pipe.pipes_a_gate("{ crap-check.sh /r; } > /tmp/g; git status | cat") is False


def test_pipes_a_gate_true_for_gate_after_group_without_gate():
    assert gate_pipe.pipes_a_gate("{ echo a; }; crap-check.sh /r | tail") is True


def test_pipes_a_gate_true_for_gate_after_closed_group_in_same_frame():
    assert gate_pipe.pipes_a_gate("( (echo a); crap-check.sh /r ) | tail") is True


def test_pipes_a_gate_ignores_stray_closing_brace():
    assert gate_pipe.pipes_a_gate("echo } ; crap-check.sh /r | tail") is True


def test_pipes_a_gate_false_for_quoted_heredoc_body():
    cmd = "cat > /tmp/f <<'EOF'\nrun crap-check.sh | tail\nEOF\necho done | cat"
    assert gate_pipe.pipes_a_gate(cmd) is False


def test_pipes_a_gate_false_for_unquoted_and_dash_heredoc_bodies():
    cmd = 'cat <<EOF > /tmp/a\n$(crap-check.sh) | x\nEOF\ncat <<-"END" >/tmp/b\n\tmutation-check.sh | y\n\tEND\n'
    assert gate_pipe.pipes_a_gate(cmd) is False


def test_pipes_a_gate_reads_command_line_after_heredoc_body():
    cmd = "cat > /tmp/f <<'EOF'\nplain text\nEOF\ncrap-check.sh /r | tail"
    assert gate_pipe.pipes_a_gate(cmd) is True


def test_pipes_a_gate_true_for_pipe_on_heredoc_line():
    cmd = "crap-check.sh /r <<EOF | tail\nbody\nEOF"
    assert gate_pipe.pipes_a_gate(cmd) is True


def test_pipes_a_gate_skips_two_heredoc_bodies_on_one_line():
    cmd = "cat <<A <<B\ncrap-check.sh | x\nA\ncrap-check.sh | y\nB\ncrap-check.sh | tail"
    assert gate_pipe.pipes_a_gate(cmd) is True
    assert gate_pipe.pipes_a_gate(cmd.rsplit("\n", 1)[0]) is False


def test_pipes_a_gate_false_for_unterminated_heredoc():
    assert gate_pipe.pipes_a_gate("cat <<EOF\ncrap-check.sh | tail") is False


def test_pipes_a_gate_herestring_is_not_a_heredoc():
    assert gate_pipe.pipes_a_gate("cat <<< x\ncrap-check.sh | tail") is True


def test_pipes_a_gate_false_for_quoted_pipe_before_gate():
    assert gate_pipe.pipes_a_gate('echo "a | b" && crap-check.sh') is False
    assert gate_pipe.pipes_a_gate("echo 'a | b' && crap-check.sh") is False


def test_pipes_a_gate_false_for_escaped_pipe():
    assert gate_pipe.pipes_a_gate("crap-check.sh /r \\| tail") is False


def test_pipes_a_gate_true_for_pipe_without_spaces():
    assert gate_pipe.pipes_a_gate("crap-check.sh /r|tail") is True


def test_pipes_a_gate_false_for_stderr_redirect_forms():
    assert gate_pipe.pipes_a_gate("crap-check.sh /r &>/tmp/a; echo a | cat") is False
    assert gate_pipe.pipes_a_gate("crap-check.sh /r 2>&1 >>/tmp/a & echo a | cat") is False


def test_pipes_a_gate_newline_ends_a_pipeline_element():
    assert gate_pipe.pipes_a_gate("crap-check.sh /r > /tmp/a\necho a | cat") is False


def test_main_blocks_brace_group_piped(monkeypatch):
    assert _run(monkeypatch, "{ mutation-check.sh /r; } | tail") == 2


def test_main_allows_quoted_heredoc_body(monkeypatch):
    assert _run(monkeypatch, "cat > f <<'EOF'\ncrap-check.sh | tail\nEOF") == 0


def test_main_allows_payload_without_command(monkeypatch):
    monkeypatch.setattr("sys.stdin", io.StringIO(json.dumps({"tool_input": {}})))
    assert gate_pipe.main() == 0


def test_pipes_a_gate_false_for_group_without_gate_piped():
    assert gate_pipe.pipes_a_gate("{ echo a; } | tail; crap-check.sh /r") is False


def test_pipes_a_gate_searches_each_heredoc_body_from_where_it_starts():
    cmd = "cat <<A <<B\nB\ncrap-check.sh | tail\nA\nB\n"
    assert gate_pipe.pipes_a_gate(cmd) is False


def test_pipes_a_gate_true_for_multiline_loops_piped():
    assert gate_pipe.pipes_a_gate("for r in a b\ndo\n  mutation-check.sh $r\ndone | tail") is True
    assert gate_pipe.pipes_a_gate("while read r\ndo\n  mutation-check.sh $r\ndone | tail") is True


def test_pipes_a_gate_true_for_multiline_if_piped():
    cmd = "if true\nthen\n  echo a\nelif false\nthen\n  mutation-check.sh /r\nelse\n  echo b\nfi | tail"
    assert gate_pipe.pipes_a_gate(cmd) is True


def test_pipes_a_gate_true_for_case_piped():
    cmd = "case $x in\n  a) mutation-check.sh /r;;\n  *) echo b;;\nesac | tail"
    assert gate_pipe.pipes_a_gate(cmd) is True


def test_pipes_a_gate_false_for_keyword_compound_redirected():
    cmd = "for r in a b; do mutation-check.sh $r; done > /tmp/g.log; echo a | cat"
    assert gate_pipe.pipes_a_gate(cmd) is False


def test_pipes_a_gate_keywords_count_only_in_command_position():
    assert gate_pipe.pipes_a_gate("echo if; crap-check.sh /r; fi | tail") is False
    assert gate_pipe.pipes_a_gate("if true; then echo fi; crap-check.sh /r; fi | tail") is True


def test_pipes_a_gate_reads_heredoc_fed_to_a_shell():
    assert gate_pipe.pipes_a_gate("bash -s <<'EOF'\nmutation-check.sh /r | tail\nEOF") is True
    assert gate_pipe.pipes_a_gate("bash <<EOF\nmutation-check.sh /r | tail\nEOF\n") is True
    assert gate_pipe.pipes_a_gate("/bin/sh -e <<-X\n\tmutation-check.sh /r | tail\n\tX") is True
    assert gate_pipe.pipes_a_gate("env zsh <<EOF\nmutation-check.sh /r | tail\nEOF") is True


def test_pipes_a_gate_shell_heredoc_body_without_pipe_allowed():
    assert gate_pipe.pipes_a_gate("bash <<'EOF'\nmutation-check.sh /r > /tmp/g\nEOF\necho a | cat") is False


def test_pipes_a_gate_shell_only_counts_in_the_heredoc_command():
    assert gate_pipe.pipes_a_gate("bash x.sh; cat <<'EOF'\nmutation-check.sh | tail\nEOF") is False
    assert gate_pipe.pipes_a_gate("fish <<'EOF'\nmutation-check.sh | tail\nEOF") is False


def test_pipes_a_gate_reads_substitution_in_unquoted_heredoc():
    assert gate_pipe.pipes_a_gate("cat <<EOF\n$(mutation-check.sh /r | tail)\nEOF") is True
    assert gate_pipe.pipes_a_gate("cat <<EOF\nx $(echo a) y $(mutation-check.sh /r | tail)\nEOF") is True


def test_pipes_a_gate_ignores_substitution_in_quoted_heredoc():
    assert gate_pipe.pipes_a_gate("cat <<'EOF'\n$(mutation-check.sh /r | tail)\nEOF") is False


def test_pipes_a_gate_substitution_in_heredoc_ends_at_its_line():
    assert gate_pipe.pipes_a_gate("cat <<EOF\n$(mutation-check.sh /r) | x\nEOF") is False


def test_pipes_a_gate_arithmetic_shift_is_not_a_heredoc():
    assert gate_pipe.pipes_a_gate("echo $((1 << 3))\ncrap-check.sh /r | tail") is True
    assert gate_pipe.pipes_a_gate("(( x << (1 + 1) ))\ncrap-check.sh /r | tail") is True


def test_pipes_a_gate_true_for_quoted_gate_path():
    assert gate_pipe.pipes_a_gate('"$SKILL_DIR/crap-check.sh" /r | tail') is True
    assert gate_pipe.pipes_a_gate("'/opt/s/crap-check.sh' | tail") is True
    assert gate_pipe.pipes_a_gate('"mutation-check.sh" /r | tail') is True


def test_pipes_a_gate_true_for_substitution_running_a_gate_piped():
    assert gate_pipe.pipes_a_gate("echo $(crap-check.sh /r; true) | tail") is True


def test_pipes_a_gate_false_for_gate_name_inside_a_longer_word():
    assert gate_pipe.pipes_a_gate("cp crap-check.sh.bak /tmp/x | cat") is False


def test_pipes_a_gate_false_for_gate_mentioned_inside_quoted_text():
    assert gate_pipe.pipes_a_gate('echo "see crap-check.sh" | cat') is False
    assert gate_pipe.pipes_a_gate('echo "crap-check.sh is a gate" | cat') is False


def test_pipes_a_gate_false_for_gate_name_as_a_search_argument():
    assert gate_pipe.pipes_a_gate('grep -rn "crap-check.sh" hooks | head') is False
    assert gate_pipe.pipes_a_gate("rg 'mutation-check.sh' -l | wc -l") is False
    assert gate_pipe.pipes_a_gate('git grep -n "crap-check.sh" -- hooks | head -20') is False
    assert gate_pipe.pipes_a_gate('echo "crap-check.sh" | wc') is False
    assert gate_pipe.pipes_a_gate("grep -rn crap-check.sh hooks | head") is False


def test_pipes_a_gate_true_for_gate_after_prefix_words():
    assert gate_pipe.pipes_a_gate("A=1 time nohup crap-check.sh /r | tail") is True
    assert gate_pipe.pipes_a_gate("env -i B=2 command crap-check.sh /r | tail") is True
    assert gate_pipe.pipes_a_gate("! exec crap-check.sh /r | tail") is True
    assert gate_pipe.pipes_a_gate("timeout 600 crap-check.sh /r | tail") is True


def test_pipes_a_gate_true_for_gate_run_by_an_interpreter():
    assert gate_pipe.pipes_a_gate('bash "$SKILL_DIR/crap-check.sh" /r | tail') is True
    assert gate_pipe.pipes_a_gate("/bin/bash -e /x/crap-check.sh /r | tail") is True
    assert gate_pipe.pipes_a_gate("source /x/mutation-check.sh | tail") is True
    assert gate_pipe.pipes_a_gate(". /x/mutation-check.sh | tail") is True
    assert gate_pipe.pipes_a_gate('bash -c "crap-check.sh" | tail') is True
    assert gate_pipe.pipes_a_gate('eval "crap-check.sh" | tail') is True


def test_pipes_a_gate_true_for_gate_after_double_dash():
    assert gate_pipe.pipes_a_gate("uv run -- crap-check.sh /r | tail") is True


def test_pipes_a_gate_true_for_glued_quoted_prefix_path():
    assert gate_pipe.pipes_a_gate('"$D"/crap-check.sh /r | tail') is True


def test_pipes_a_gate_true_for_gate_continued_with_backslash_newline():
    assert gate_pipe.pipes_a_gate("bash /x/crap-check.sh\\\n  --base main 2>&1 | tail") is True
