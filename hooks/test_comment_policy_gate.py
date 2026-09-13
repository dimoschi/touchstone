import io
import json
import subprocess
from pathlib import Path

from conftest import load_script

gate = load_script(Path(__file__).resolve().parent / "comment-policy-gate.py")


def _git(*args, cwd):
    subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True)


def _repo(tmp_path):
    _git("init", "-q", "-b", "main", str(tmp_path), cwd=tmp_path.parent)
    return tmp_path


def _commit(repo):
    _git("add", "-A", cwd=repo)
    _git("-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false",
         "commit", "-q", "-m", "x", cwd=repo)


def _run(monkeypatch, payload):
    monkeypatch.setattr("sys.stdin", io.StringIO(json.dumps(payload)))
    return gate.main()


def _edit(path, old_string, new_string):
    return {
        "tool_name": "Edit",
        "tool_input": {"file_path": str(path), "old_string": old_string, "new_string": new_string},
        "cwd": str(Path(path).parent),
    }


def _write(path, content):
    return {
        "tool_name": "Write",
        "tool_input": {"file_path": str(path), "content": content},
        "cwd": str(Path(path).parent),
    }


# --- pure helpers -----------------------------------------------------------


def test_new_comment_lines_for_write_with_no_tracked_baseline_is_every_content_line():
    assert gate.new_comment_lines("Write", {"content": "# a\n# b"}, None) == ["# a", "# b"]


def test_new_comment_lines_for_write_non_string_content_is_empty():
    assert gate.new_comment_lines("Write", {"content": None}, None) == []


def test_new_comment_lines_for_write_excludes_lines_already_in_head(tmp_path):
    repo = _repo(tmp_path)
    path = repo / "task.py"
    path.write_text("# keep\npackage x\n")
    _commit(repo)
    lines = gate.new_comment_lines("Write", {"content": "# keep\n# added\npackage x"}, path)
    assert lines == ["# added"]


def test_new_comment_lines_for_edit_excludes_unchanged_lines():
    old = "# keep\npackage x"
    new = "# keep\n# added\npackage x"
    assert gate.new_comment_lines("Edit", {"old_string": old, "new_string": new}, None) == ["# added"]


def test_new_comment_lines_for_multi_edit_unions_all_edits():
    edits = [
        {"old_string": "a", "new_string": "a\n# one"},
        {"old_string": "b", "new_string": "b\n# two"},
    ]
    assert gate.new_comment_lines("MultiEdit", {"edits": edits}, None) == ["# one", "# two"]


def test_new_comment_lines_unknown_tool_is_empty():
    assert gate.new_comment_lines("Bash", {"command": "ls"}, None) == []


def test_new_comment_lines_for_edit_non_string_new_string_is_empty():
    assert gate.new_comment_lines("Edit", {"old_string": "a", "new_string": None}, None) == []


def test_new_comment_lines_for_multi_edit_non_list_edits_is_empty():
    assert gate.new_comment_lines("MultiEdit", {"edits": "not-a-list"}, None) == []


def test_comment_text_strips_prefix_and_whitespace():
    assert gate.comment_text("   #   hush now  ", "#") == "hush now"


def test_comment_text_none_for_non_comment_line():
    assert gate.comment_text("x = 1", "#") is None


def test_load_policy_missing_file_is_empty():
    assert gate.load_policy(Path("/definitely/not/a/real/policy-file")) == []


def test_load_policy_ignores_blank_and_hash_lines(tmp_path):
    marker = tmp_path / ".comment-gated"
    marker.write_text("\n# a reason for the next rule\nhush\n")
    patterns = gate.load_policy(marker)
    assert len(patterns) == 1
    assert patterns[0].search("hush now")


def test_load_policy_bad_regex_exits_2_naming_file_and_line(tmp_path, capsys):
    marker = tmp_path / ".comment-gated"
    marker.write_text("good\n(unclosed\n")
    rc = 0
    try:
        gate.load_policy(marker)
    except SystemExit as exc:
        rc = exc.code
    assert rc == 2
    err = capsys.readouterr().err
    assert str(marker) in err
    assert "line 2" in err


def test_load_policy_non_ascii_rule_compiles_regardless_of_locale(tmp_path):
    marker = tmp_path / ".comment-gated"
    marker.write_bytes("—\n".encode("utf-8"))
    patterns = gate.load_policy(marker)
    assert len(patterns) == 1
    assert patterns[0].search("an em dash — right here")


def test_load_policy_undecodable_bytes_exit_2_not_a_crash(tmp_path, capsys):
    marker = tmp_path / ".comment-gated"
    marker.write_bytes(b"\xff\xfehush\n")
    rc = 0
    try:
        gate.load_policy(marker)
    except SystemExit as exc:
        rc = exc.code
    assert rc == 2
    assert str(marker) in capsys.readouterr().err


def test_load_policy_rule_starting_with_hash_needs_escaping_but_then_compiles(tmp_path):
    marker = tmp_path / ".comment-gated"
    marker.write_text(r"\#\d+" + "\n")
    patterns = gate.load_policy(marker)
    assert len(patterns) == 1
    assert patterns[0].search("see ticket #123")


# --- end-to-end via main() --------------------------------------------------


def test_no_marker_file_is_a_no_op(monkeypatch, tmp_path):
    repo = _repo(tmp_path)
    path = repo / "task.py"
    payload = _write(path, "# hush, do not tell\nprint(1)\n")
    assert _run(monkeypatch, payload) == 0


def test_empty_marker_file_is_a_no_op(monkeypatch, tmp_path):
    repo = _repo(tmp_path)
    (repo / ".comment-gated").write_text("")
    path = repo / "task.py"
    payload = _write(path, "# hush, do not tell\nprint(1)\n")
    assert _run(monkeypatch, payload) == 0


def test_comment_only_marker_file_is_a_no_op(monkeypatch, tmp_path):
    repo = _repo(tmp_path)
    (repo / ".comment-gated").write_text("# no rules yet\n\n")
    path = repo / "task.py"
    payload = _write(path, "# hush, do not tell\nprint(1)\n")
    assert _run(monkeypatch, payload) == 0


def test_matching_new_comment_is_blocked(monkeypatch, tmp_path, capsys):
    repo = _repo(tmp_path)
    (repo / ".comment-gated").write_text("hush\n")
    path = repo / "task.py"
    payload = _write(path, "# hush, do not tell\nprint(1)\n")
    rc = _run(monkeypatch, payload)
    assert rc == 2
    assert "comment-policy:" in capsys.readouterr().err


def test_same_text_in_code_rather_than_comment_is_allowed(monkeypatch, tmp_path):
    repo = _repo(tmp_path)
    (repo / ".comment-gated").write_text("hush\n")
    path = repo / "task.py"
    payload = _write(path, 'print("hush, do not tell")\n')
    assert _run(monkeypatch, payload) == 0


def test_hash_prefixed_line_inside_a_string_literal_is_flagged_like_any_other_line(monkeypatch, tmp_path, capsys):
    # Detection is prefix-based, not a parser: a heredoc/string line whose first
    # non-space character happens to be the comment prefix is indistinguishable
    # from a real comment. That is the documented false-positive direction.
    repo = _repo(tmp_path)
    (repo / ".comment-gated").write_text("hush\n")
    path = repo / "task.py"
    payload = _write(path, 'text = """\n# hush, do not tell\n"""\n')
    rc = _run(monkeypatch, payload)
    assert rc == 2
    assert "comment-policy:" in capsys.readouterr().err


def test_comment_already_present_before_write_is_not_flagged(monkeypatch, tmp_path):
    repo = _repo(tmp_path)
    (repo / ".comment-gated").write_text("hush\n")
    path = repo / "task.py"
    path.write_text("# hush, already here\nprint(1)\n")
    _commit(repo)
    payload = _write(path, "# hush, already here\nprint(1)\nprint(2)\n")
    assert _run(monkeypatch, payload) == 0


def test_newly_added_comment_in_write_over_a_tracked_file_is_flagged(monkeypatch, tmp_path, capsys):
    repo = _repo(tmp_path)
    (repo / ".comment-gated").write_text("hush\n")
    path = repo / "task.py"
    path.write_text("print(1)\n")
    _commit(repo)
    payload = _write(path, "# hush, new\nprint(1)\n")
    rc = _run(monkeypatch, payload)
    assert rc == 2
    assert "comment-policy:" in capsys.readouterr().err


def test_write_over_a_tracked_non_utf8_file_does_not_crash_and_flags_new_content(monkeypatch, tmp_path, capsys):
    repo = _repo(tmp_path)
    (repo / ".comment-gated").write_text("hush\n")
    path = repo / "task.php"
    path.write_bytes(b"<?php\n// caf\xe9 latin1 comment\n")
    _commit(repo)
    payload = _write(path, "<?php\n// hush, new\n")
    rc = _run(monkeypatch, payload)
    assert rc == 2
    assert "comment-policy:" in capsys.readouterr().err


def test_write_over_a_tracked_non_utf8_file_does_not_flag_an_untouched_comment(monkeypatch, tmp_path):
    repo = _repo(tmp_path)
    (repo / ".comment-gated").write_text("hush\n")
    path = repo / "task.php"
    path.write_bytes(b"<?php\n// hush, untouched\n$x = \"caf\xe9\";\n")
    _commit(repo)
    payload = _write(path, '<?php\n// hush, untouched\n$x = "cafe";\n')
    assert _run(monkeypatch, payload) == 0


def test_comment_already_present_before_edit_is_not_flagged(monkeypatch, tmp_path):
    repo = _repo(tmp_path)
    (repo / ".comment-gated").write_text("hush\n")
    path = repo / "task.py"
    path.write_text("# hush, already here\nprint(1)\n")
    payload = _edit(path, "print(1)", "print(2)")
    assert _run(monkeypatch, payload) == 0


def test_newly_added_comment_in_edit_is_flagged(monkeypatch, tmp_path, capsys):
    repo = _repo(tmp_path)
    (repo / ".comment-gated").write_text("hush\n")
    path = repo / "task.py"
    path.write_text("print(1)\n")
    payload = _edit(path, "print(1)", "# hush, new\nprint(1)")
    rc = _run(monkeypatch, payload)
    assert rc == 2
    assert "comment-policy:" in capsys.readouterr().err


def test_unknown_extension_produces_no_findings(monkeypatch, tmp_path):
    repo = _repo(tmp_path)
    (repo / ".comment-gated").write_text("hush\n")
    path = repo / "task.rkt"
    payload = _write(path, "; hush, do not tell\n")
    assert _run(monkeypatch, payload) == 0


def test_malformed_payload_missing_cwd_is_a_no_op(monkeypatch):
    payload = {"tool_name": "Write", "tool_input": {"file_path": "/x/task.py", "content": "# hush"}}
    assert _run(monkeypatch, payload) == 0


def test_non_edit_tool_is_a_no_op(monkeypatch, tmp_path):
    repo = _repo(tmp_path)
    (repo / ".comment-gated").write_text("hush\n")
    payload = {"tool_name": "Bash", "tool_input": {"command": "echo hush"}, "cwd": str(repo)}
    assert _run(monkeypatch, payload) == 0


def test_no_path_in_tool_input_is_a_no_op(monkeypatch, tmp_path):
    repo = _repo(tmp_path)
    (repo / ".comment-gated").write_text("hush\n")
    payload = {"tool_name": "Write", "tool_input": {"content": "# hush"}, "cwd": str(repo)}
    assert _run(monkeypatch, payload) == 0


def test_bad_regex_in_marker_exits_2_via_main(monkeypatch, tmp_path, capsys):
    repo = _repo(tmp_path)
    (repo / ".comment-gated").write_text("(unclosed\n")
    path = repo / "task.py"
    payload = _write(path, "# anything\n")
    rc = None
    try:
        _run(monkeypatch, payload)
    except SystemExit as exc:
        rc = exc.code
    assert rc == 2
    assert str(repo / ".comment-gated") in capsys.readouterr().err


def test_copilot_post_tool_use_relative_path_resolves_against_cwd(monkeypatch, tmp_path, capsys):
    repo = _repo(tmp_path)
    (repo / ".comment-gated").write_text("hush\n")
    payload = {
        "hook_event_name": "PostToolUse",
        "session_id": "copilot-session",
        "cwd": str(repo),
        "tool_name": "Write",
        "tool_input": {"path": "task.py", "content": "# hush, do not tell\n"},
    }
    rc = _run(monkeypatch, payload)
    assert rc == 2
    assert "comment-policy:" in capsys.readouterr().err


def test_policy_in_a_linked_worktree_is_read_from_that_worktree_not_the_main_checkout(monkeypatch, tmp_path, capsys):
    main = tmp_path / "main"
    _git("init", "-q", "-b", "main", str(main), cwd=tmp_path)
    (main / "README.md").write_text("x\n")
    _commit(main)
    wt = tmp_path / "wt"
    _git("worktree", "add", "-q", "-b", "feature", str(wt), cwd=main)
    (main / ".comment-gated").write_text("only-in-main\n")
    (wt / ".comment-gated").write_text("hush\n")
    path = wt / "task.py"
    payload = _write(path, "# hush, do not tell\nprint(1)\n")
    rc = _run(monkeypatch, payload)
    assert rc == 2
    assert "comment-policy:" in capsys.readouterr().err


def test_unchanged_comment_in_a_non_utf8_file_is_not_reported_as_new(
        monkeypatch, tmp_path, capsys):
    """A tracked file whose committed bytes are not valid UTF-8.

    Review of this hook raised the opposite: that `_committed_lines` decoding
    with errors='replace' would leave every line of a Write looking new, so an
    untouched human comment would be flagged and the help text would tell the
    agent to reword it.

    It does not, and the reason is the point. The harness decodes a file for
    the agent the same lossy way, so the content a Write carries and the
    baseline agree exactly. The reproduction that showed otherwise built the
    payload by decoding the file as latin-1, which nothing here produces.

    Locked because the argument is easy to re-derive from the wrong premise.
    """
    repo = _repo(tmp_path)
    (repo / ".comment-gated").write_text("hush\n")
    target = repo / "task.php"
    target.write_bytes(b"<?php\n// caf\xe9 hush, do not tell\n// keeper\n")
    _commit(repo)

    as_the_agent_sees_it = target.read_text(encoding="utf-8", errors="replace")
    assert "�" in as_the_agent_sees_it

    rc = _run(monkeypatch, _write(target, as_the_agent_sees_it))
    assert rc == 0
    assert capsys.readouterr().err == ""


def test_a_genuinely_new_comment_in_a_non_utf8_file_is_still_reported(
        monkeypatch, tmp_path, capsys):
    """The counterpart: lossy decoding must not blind the gate entirely."""
    repo = _repo(tmp_path)
    (repo / ".comment-gated").write_text("hush\n")
    target = repo / "task.php"
    target.write_bytes(b"<?php\n// caf\xe9 hush, do not tell\n")
    _commit(repo)

    content = target.read_text(encoding="utf-8", errors="replace") + "// hush, newly added\n"
    rc = _run(monkeypatch, _write(target, content))
    assert rc == 2
    assert "hush, newly added" in capsys.readouterr().err
