import io
import json
import subprocess
from pathlib import Path

import copilot_session_evidence as cse
from conftest import load_script

gate = load_script(Path(__file__).resolve().parent / "contributing-gate.py")


def _git_init(path):
    subprocess.run(["git", "init", "-q", str(path)], cwd=path.parent, check=True)


def _repo(tmp_path, name, *, gated=True, guides=()):
    """guides: [(relative_path, content)]"""
    root = tmp_path / name
    (root / "internal").mkdir(parents=True)
    _git_init(root)
    if gated:
        (root / ".crap-gated").write_text("")
    for rel, content in guides:
        p = root / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(content)
    return root


def _legacy_payload(transcript, file_path):
    tool_input = {"file_path": file_path} if file_path else {}
    return json.dumps({"transcript_path": str(transcript), "tool_input": tool_input})


def _claude_payload(transcript, file_path, cwd):
    """The shape Claude Code actually sends: an event name and no host key."""
    return json.dumps({
        "hook_event_name": "PreToolUse",
        "session_id": "s1",
        "transcript_path": str(transcript),
        "cwd": str(cwd),
        "tool_name": "Edit",
        "tool_input": {"file_path": file_path},
    })


def _write_transcript(path, entries):
    """entries: list of (tool_name_or_None, file_path) for tool_use blocks,
    or a raw string line for something else."""
    lines = []
    for entry in entries:
        if isinstance(entry, str):
            lines.append(entry)
            continue
        name, file_path = entry
        lines.append(json.dumps({
            "message": {"content": [{"type": "tool_use", "name": name, "input": {"file_path": file_path}}]}
        }))
    path.write_text("\n".join(lines) + "\n")


def _run(monkeypatch, payload):
    monkeypatch.setattr("sys.stdin", io.StringIO(payload))
    return gate.main()


def test_claude_shaped_payload_honours_the_transcript(monkeypatch, tmp_path):
    """Regression: every earlier test used the legacy shape, so nothing
    exercised the payload Claude Code really sends. Classified as copilot, it
    reached gate_copilot, whose evidence no Claude-side hook writes, and every
    edit in a gated repo was refused."""
    repo = _repo(tmp_path, "guided", guides=[("CONTRIBUTING.md", "read me")])
    transcript = tmp_path / "read.jsonl"
    _write_transcript(transcript, [("Read", str(repo / "CONTRIBUTING.md"))])
    rc = _run(monkeypatch, _claude_payload(
        transcript, str(repo / "internal" / "app.go"), repo))
    assert rc == 0


def test_claude_shaped_payload_still_blocks_an_unread_guide(monkeypatch, tmp_path):
    repo = _repo(tmp_path, "guided", guides=[("CONTRIBUTING.md", "read me")])
    transcript = tmp_path / "empty.jsonl"
    _write_transcript(transcript, [("Read", str(repo / "somewhere-else.md"))])
    rc = _run(monkeypatch, _claude_payload(
        transcript, str(repo / "internal" / "app.go"), repo))
    assert rc == 2


def test_edit_with_unread_guide_is_blocked(monkeypatch, tmp_path):
    repo = _repo(tmp_path, "guided", guides=[("CONTRIBUTING.md", "read me")])
    missing = tmp_path / "missing.jsonl"
    rc = _run(monkeypatch, _legacy_payload(missing, str(repo / "internal" / "app.go")))
    assert rc == 2


def test_write_into_nonexistent_directory_is_blocked(monkeypatch, tmp_path):
    repo = _repo(tmp_path, "guided", guides=[("CONTRIBUTING.md", "read me")])
    missing = tmp_path / "missing.jsonl"
    rc = _run(monkeypatch, _legacy_payload(missing, str(repo / "internal" / "new" / "pkg" / "app.go")))
    assert rc == 2


def test_edit_after_reading_guide_this_session_is_allowed(monkeypatch, tmp_path, capsys):
    repo = _repo(tmp_path, "guided", guides=[("CONTRIBUTING.md", "read me")])
    transcript = tmp_path / "read.jsonl"
    _write_transcript(transcript, [("Read", str(repo / "CONTRIBUTING.md"))])
    rc = _run(monkeypatch, _legacy_payload(transcript, str(repo / "internal" / "app.go")))
    assert rc == 0


def test_editing_the_guide_itself_is_not_gated(monkeypatch, tmp_path):
    repo = _repo(tmp_path, "guided", guides=[("CONTRIBUTING.md", "read me")])
    missing = tmp_path / "missing.jsonl"
    rc = _run(monkeypatch, _legacy_payload(missing, str(repo / "CONTRIBUTING.md")))
    assert rc == 0


def test_grep_naming_the_path_does_not_count(monkeypatch, tmp_path):
    repo = _repo(tmp_path, "guided", guides=[("CONTRIBUTING.md", "read me")])
    transcript = tmp_path / "grep.jsonl"
    _write_transcript(transcript, [("Grep", str(repo / "CONTRIBUTING.md"))])
    rc = _run(monkeypatch, _legacy_payload(transcript, str(repo / "internal" / "app.go")))
    assert rc == 2


def test_block_message_quoting_the_path_does_not_count(monkeypatch, tmp_path):
    repo = _repo(tmp_path, "guided", guides=[("CONTRIBUTING.md", "read me")])
    transcript = tmp_path / "echo.jsonl"
    line = json.dumps({"message": {"content": [{"type": "tool_result", "content": f"read {repo}/CONTRIBUTING.md"}]}})
    _write_transcript(transcript, [line])
    rc = _run(monkeypatch, _legacy_payload(transcript, str(repo / "internal" / "app.go")))
    assert rc == 2


def test_unreadable_transcript_says_so_instead_of_blaming_the_guide(
        monkeypatch, tmp_path, capsys):
    """A transcript the gate cannot open is not evidence that the guide is
    unread. Reporting it as one is unactionable: the agent re-reads the guide,
    is refused again, and nothing says why."""
    repo = _repo(tmp_path, "guided", guides=[("CONTRIBUTING.md", "read me")])
    missing = tmp_path / "nope.jsonl"
    rc = _run(monkeypatch, _legacy_payload(missing, str(repo / "internal" / "app.go")))
    err = capsys.readouterr().err
    assert rc == 2
    assert str(missing) in err
    assert 'Read it before editing' not in err


def test_payload_with_no_transcript_path_says_so(monkeypatch, tmp_path, capsys):
    repo = _repo(tmp_path, "guided", guides=[("CONTRIBUTING.md", "read me")])
    payload = json.dumps({"tool_input": {"file_path": str(repo / "internal" / "app.go")}})
    rc = _run(monkeypatch, payload)
    err = capsys.readouterr().err
    assert rc == 2
    assert ': the hook payload carried no transcript_path\n' in err
    assert 'Read it before editing' not in err


def test_read_is_found_after_unrelated_and_non_read_lines(monkeypatch, tmp_path):
    """The scan must keep going past lines it rejects.

    Every earlier transcript put the Read first or alone, so nothing noticed
    whether a rejected line stopped the scan instead of skipping it.
    """
    repo = _repo(tmp_path, "guided", guides=[("CONTRIBUTING.md", "read me")])
    transcript = tmp_path / "mixed.jsonl"
    _write_transcript(transcript, [
        json.dumps({"message": {"content": [{"type": "text", "text": "chatter"}]}}),
        ("Grep", str(repo / "CONTRIBUTING.md")),
        ("Read", str(repo / "unrelated.md")),
        ("Read", str(repo / "CONTRIBUTING.md")),
    ])
    rc = _run(monkeypatch, _legacy_payload(transcript, str(repo / "internal" / "app.go")))
    assert rc == 0


def test_read_of_an_undecodable_transcript_still_finds_the_guide(monkeypatch, tmp_path):
    """errors='replace' keeps the scan alive on a transcript with invalid
    UTF-8; a stricter or dropping mode loses the line or raises."""
    repo = _repo(tmp_path, "guided", guides=[("CONTRIBUTING.md", "read me")])
    transcript = tmp_path / "latin1.jsonl"
    good = json.dumps({"message": {"content": [
        {"type": "tool_use", "name": "Read",
         "input": {"file_path": str(repo / "CONTRIBUTING.md")}}]}})
    transcript.write_bytes(b'{"note": "caf\xe9 tool_use CONTRIBUTING.md"}\n'
                           + good.encode() + b"\n")
    rc = _run(monkeypatch, _legacy_payload(transcript, str(repo / "internal" / "app.go")))
    assert rc == 0


def test_block_without_a_usable_path_does_not_stop_the_scan(monkeypatch, tmp_path):
    repo = _repo(tmp_path, "guided", guides=[("CONTRIBUTING.md", "read me")])
    transcript = tmp_path / "nopath.jsonl"
    noisy = json.dumps({"message": {"content": [
        {"type": "tool_use", "name": "Read", "input": {}},
        {"type": "tool_use", "name": "Read",
         "input": {"file_path": str(repo / "CONTRIBUTING.md")}}]}})
    transcript.write_text(noisy + "\n")
    rc = _run(monkeypatch, _legacy_payload(transcript, str(repo / "internal" / "app.go")))
    assert rc == 0


def test_refusal_names_every_unread_guide(monkeypatch, tmp_path, capsys):
    repo = _repo(tmp_path, "multi", guides=[
        ("CONTRIBUTING.md", "main guide"),
        ("docs/DEVELOPMENT.md", "dev guide"),
    ])
    missing = tmp_path / "missing.jsonl"
    _write_transcript(missing, [("Read", str(repo / "nothing.md"))])
    rc = _run(monkeypatch, _legacy_payload(missing, str(repo / "internal" / "app.go")))
    err = capsys.readouterr().err
    assert rc == 2
    assert f'  {repo / "CONTRIBUTING.md"}' in err
    assert f'  {repo / "docs" / "DEVELOPMENT.md"}' in err


def test_unparseable_line_before_the_read_does_not_stop_the_scan(monkeypatch, tmp_path):
    repo = _repo(tmp_path, "guided", guides=[("CONTRIBUTING.md", "read me")])
    transcript = tmp_path / "broken-then-good.jsonl"
    good = json.dumps({"message": {"content": [
        {"type": "tool_use", "name": "Read",
         "input": {"file_path": str(repo / "CONTRIBUTING.md")}}]}})
    transcript.write_text("tool_use CONTRIBUTING.md but not json {\n" + good + "\n")
    rc = _run(monkeypatch, _legacy_payload(transcript, str(repo / "internal" / "app.go")))
    assert rc == 0


def test_non_read_block_before_the_read_block_does_not_stop_the_scan(
        monkeypatch, tmp_path):
    repo = _repo(tmp_path, "guided", guides=[("CONTRIBUTING.md", "read me")])
    transcript = tmp_path / "blocks.jsonl"
    line = json.dumps({"message": {"content": [
        {"type": "tool_use", "name": "Grep",
         "input": {"file_path": str(repo / "CONTRIBUTING.md")}},
        "not even a dict",
        {"type": "tool_use", "name": "Read", "input": "CONTRIBUTING.md"},
        {"type": "tool_use", "name": "Read",
         "input": {"file_path": str(repo / "CONTRIBUTING.md")}}]}})
    transcript.write_text(line + "\n")
    rc = _run(monkeypatch, _legacy_payload(transcript, str(repo / "internal" / "app.go")))
    assert rc == 0


def test_refusal_lists_the_guides_one_per_line(monkeypatch, tmp_path, capsys):
    repo = _repo(tmp_path, "multi", guides=[
        ("CONTRIBUTING.md", "main guide"),
        ("docs/DEVELOPMENT.md", "dev guide"),
    ])
    missing = tmp_path / "missing.jsonl"
    _write_transcript(missing, [("Read", str(repo / "nothing.md"))])
    rc = _run(monkeypatch, _legacy_payload(missing, str(repo / "internal" / "app.go")))
    err = capsys.readouterr().err
    assert rc == 2
    assert f'  {repo / "CONTRIBUTING.md"}\n  {repo / "docs" / "DEVELOPMENT.md"}' in err


def test_multiple_guides_all_must_be_read(monkeypatch, tmp_path):
    repo = _repo(tmp_path, "multi", guides=[
        ("CONTRIBUTING.md", "main guide"),
        ("docs/DEVELOPMENT.md", "dev guide"),
    ])
    only_one = tmp_path / "one.jsonl"
    _write_transcript(only_one, [("Read", str(repo / "CONTRIBUTING.md"))])
    rc = _run(monkeypatch, _legacy_payload(only_one, str(repo / "internal" / "app.go")))
    assert rc == 2

    both = tmp_path / "both.jsonl"
    _write_transcript(both, [
        ("Read", str(repo / "CONTRIBUTING.md")),
        ("Read", str(repo / "docs" / "DEVELOPMENT.md")),
    ])
    rc = _run(monkeypatch, _legacy_payload(both, str(repo / "internal" / "app.go")))
    assert rc == 0


def test_repo_reached_through_symlink_is_the_same_repo(monkeypatch, tmp_path):
    repo = _repo(tmp_path, "guided", guides=[("CONTRIBUTING.md", "read me")])
    link = tmp_path / "link"
    link.symlink_to(repo)

    missing = tmp_path / "missing.jsonl"
    rc = _run(monkeypatch, _legacy_payload(missing, str(link / "internal" / "app.go")))
    assert rc == 2

    read_link = tmp_path / "read-link.jsonl"
    _write_transcript(read_link, [("Read", str(link / "CONTRIBUTING.md"))])
    rc = _run(monkeypatch, _legacy_payload(read_link, str(repo / "internal" / "app.go")))
    assert rc == 0

    read_real = tmp_path / "read.jsonl"
    _write_transcript(read_real, [("Read", str(repo / "CONTRIBUTING.md"))])
    rc = _run(monkeypatch, _legacy_payload(read_real, str(link / "internal" / "app.go")))
    assert rc == 0


def test_gated_repo_with_no_guide_is_allowed(monkeypatch, tmp_path):
    repo = _repo(tmp_path, "bare", guides=[])
    missing = tmp_path / "missing.jsonl"
    rc = _run(monkeypatch, _legacy_payload(missing, str(repo / "internal" / "app.go")))
    assert rc == 0


def test_guide_present_but_repo_not_gated_is_allowed(monkeypatch, tmp_path):
    repo = _repo(tmp_path, "ungated", gated=False, guides=[("CONTRIBUTING.md", "x")])
    missing = tmp_path / "missing.jsonl"
    rc = _run(monkeypatch, _legacy_payload(missing, str(repo / "internal" / "app.go")))
    assert rc == 0


def test_path_in_no_repository_at_all_is_allowed(monkeypatch, tmp_path):
    missing = tmp_path / "missing.jsonl"
    rc = _run(monkeypatch, _legacy_payload(missing, str(tmp_path / "loose" / "scratch.go")))
    assert rc == 0


def test_no_file_path_in_tool_input_is_allowed(monkeypatch, tmp_path):
    missing = tmp_path / "missing.jsonl"
    rc = _run(monkeypatch, _legacy_payload(missing, ""))
    assert rc == 0


def test_invalid_json_stdin_is_allowed(monkeypatch):
    monkeypatch.setattr("sys.stdin", io.StringIO("not json"))
    assert gate.main() == 0


def test_legacy_non_dict_tool_input_is_allowed(monkeypatch, tmp_path):
    payload = json.dumps({"transcript_path": str(tmp_path / "t.jsonl"), "tool_input": "nope"})
    assert _run(monkeypatch, payload) == 0


def test_nearest_dir_returns_none_when_no_ancestor_exists(monkeypatch, tmp_path):
    monkeypatch.setattr(Path, "is_dir", lambda self: False)
    assert gate.nearest_dir(tmp_path / "a" / "b") is None


def test_resolved_falls_back_when_resolve_raises(monkeypatch, tmp_path):
    def boom(self, strict=False):
        raise OSError("loop")

    monkeypatch.setattr(Path, "resolve", boom)
    target = tmp_path / "a.py"
    assert gate.resolved(str(target)) == str(target.expanduser())


def test_read_in_session_skips_unparseable_matching_line(tmp_path):
    repo = _repo(tmp_path, "guided", guides=[("CONTRIBUTING.md", "read me")])
    transcript = tmp_path / "broken.jsonl"
    transcript.write_text("tool_use mentions CONTRIBUTING.md but is not json {\n")
    guides = [repo / "CONTRIBUTING.md"]
    assert gate.read_in_session(transcript, guides) == set()


def test_read_in_session_skips_read_block_with_non_dict_input(tmp_path):
    repo = _repo(tmp_path, "guided", guides=[("CONTRIBUTING.md", "read me")])
    transcript = tmp_path / "weird.jsonl"
    line = json.dumps({
        "message": {"content": [{"type": "tool_use", "name": "Read", "input": "CONTRIBUTING.md as a string"}]}
    })
    transcript.write_text(line + "\n")
    guides = [repo / "CONTRIBUTING.md"]
    assert gate.read_in_session(transcript, guides) == set()


def test_legacy_missing_toplevel_after_gated_check_is_allowed(monkeypatch, tmp_path):
    repo = _repo(tmp_path, "guided", guides=[("CONTRIBUTING.md", "read me")])
    target = repo / "internal" / "app.go"
    # gate_claude's only `git()` call after the is_gated check is this exact
    # show-toplevel lookup, so a plain stub covers it without a passthrough
    # branch that would never run.
    monkeypatch.setattr(gate, "git", lambda path, *args: None)
    missing = tmp_path / "missing.jsonl"
    rc = _run(monkeypatch, _legacy_payload(missing, str(target)))
    assert rc == 0


def test_copilot_editing_the_only_guide_itself_is_allowed(monkeypatch, tmp_path):
    monkeypatch.setenv(cse.STATE_ENV, str(tmp_path / "state"))
    repo = _repo(tmp_path, "guided", guides=[("CONTRIBUTING.md", "read me")])
    rc = _run(monkeypatch, _copilot_pre("copilot-self", repo, "Edit", "CONTRIBUTING.md"))
    assert rc == 0



def _copilot_pre(session_id, cwd, tool_name, file_path):
    tool_input = {} if file_path is None else {"path": file_path}
    return json.dumps({
        "hook_event_name": "PreToolUse",
        "host": "copilot",
        "session_id": session_id,
        "cwd": str(cwd),
        "tool_name": tool_name,
        "tool_input": tool_input,
    })


def _record_copilot_read(monkeypatch, session_id, cwd, tool_name, file_path, result_type="success"):
    payload = json.dumps({
        "hook_event_name": "PostToolUse",
        "host": "copilot",
        "session_id": session_id,
        "cwd": str(cwd),
        "tool_name": tool_name,
        "tool_input": {"path": file_path},
        "tool_result": {"result_type": result_type},
    })
    monkeypatch.setattr("sys.stdin", io.StringIO(payload))
    assert cse.main() == 0


def test_copilot_same_session_after_post_read_allows_multiple_edits(monkeypatch, tmp_path):
    monkeypatch.setenv(cse.STATE_ENV, str(tmp_path / "state"))
    repo = _repo(tmp_path, "guided", guides=[("CONTRIBUTING.md", "read me")])
    _record_copilot_read(monkeypatch, "copilot-same", repo, "Read", "CONTRIBUTING.md")
    assert _run(monkeypatch, _copilot_pre("copilot-same", repo, "Edit", "internal/app.go")) == 0
    assert _run(monkeypatch, _copilot_pre("copilot-same", repo, "Write", "internal/second.go")) == 0


def test_copilot_different_session_still_blocks(monkeypatch, tmp_path):
    monkeypatch.setenv(cse.STATE_ENV, str(tmp_path / "state"))
    repo = _repo(tmp_path, "guided", guides=[("CONTRIBUTING.md", "read me")])
    _record_copilot_read(monkeypatch, "copilot-same", repo, "Read", "CONTRIBUTING.md")
    assert _run(monkeypatch, _copilot_pre("copilot-other", repo, "Edit", "internal/app.go")) == 2


def test_copilot_agent_side_marker_file_does_not_count(monkeypatch, tmp_path):
    state = tmp_path / "state"
    monkeypatch.setenv(cse.STATE_ENV, str(state))
    repo = _repo(tmp_path, "guided", guides=[("CONTRIBUTING.md", "read me")])
    state.mkdir(mode=0o700)
    (state / "copilot-agent-marker.txt").write_text("agent says it already read the guide")
    assert _run(monkeypatch, _copilot_pre("copilot-marker", repo, "Edit", "internal/app.go")) == 2


def test_copilot_grep_does_not_count(monkeypatch, tmp_path):
    monkeypatch.setenv(cse.STATE_ENV, str(tmp_path / "state"))
    repo = _repo(tmp_path, "guided", guides=[("CONTRIBUTING.md", "read me")])
    _record_copilot_read(monkeypatch, "copilot-grep", repo, "Grep", "CONTRIBUTING.md")
    assert _run(monkeypatch, _copilot_pre("copilot-grep", repo, "Edit", "internal/app.go")) == 2


def test_copilot_failed_read_does_not_count(monkeypatch, tmp_path):
    monkeypatch.setenv(cse.STATE_ENV, str(tmp_path / "state"))
    repo = _repo(tmp_path, "guided", guides=[("CONTRIBUTING.md", "read me")])
    _record_copilot_read(monkeypatch, "copilot-failed", repo, "Read", "CONTRIBUTING.md", result_type="error")
    assert _run(monkeypatch, _copilot_pre("copilot-failed", repo, "Edit", "internal/app.go")) == 2


def test_copilot_wrong_path_does_not_count(monkeypatch, tmp_path):
    monkeypatch.setenv(cse.STATE_ENV, str(tmp_path / "state"))
    repo = _repo(tmp_path, "guided", guides=[("CONTRIBUTING.md", "read me"), ("README.md", "x")])
    _record_copilot_read(monkeypatch, "copilot-wrong", repo, "Read", "README.md")
    assert _run(monkeypatch, _copilot_pre("copilot-wrong", repo, "Edit", "internal/app.go")) == 2


def test_copilot_missing_path_denies_with_detail(monkeypatch, tmp_path, capsys):
    monkeypatch.setenv(cse.STATE_ENV, str(tmp_path / "state"))
    repo = _repo(tmp_path, "guided", guides=[("CONTRIBUTING.md", "read me")])
    rc = _run(monkeypatch, _copilot_pre("copilot-missing", repo, "Edit", None))
    assert rc == 2
    assert "tool_input.path" in capsys.readouterr().err


def test_copilot_relative_cwd_read_allows_relative_edit(monkeypatch, tmp_path):
    monkeypatch.setenv(cse.STATE_ENV, str(tmp_path / "state"))
    repo = _repo(tmp_path, "guided", guides=[("CONTRIBUTING.md", "read me")])
    _record_copilot_read(monkeypatch, "copilot-relative", repo, "Read", "CONTRIBUTING.md")
    assert _run(monkeypatch, _copilot_pre("copilot-relative", repo, "MultiEdit", "internal/app.go")) == 0


def test_copilot_symlink_and_real_path_are_equivalent(monkeypatch, tmp_path):
    monkeypatch.setenv(cse.STATE_ENV, str(tmp_path / "state"))
    repo = _repo(tmp_path, "guided", guides=[("CONTRIBUTING.md", "read me")])
    link = tmp_path / "link"
    link.symlink_to(repo)

    _record_copilot_read(monkeypatch, "copilot-link", link, "Read", "CONTRIBUTING.md")
    assert _run(monkeypatch, _copilot_pre("copilot-link", repo, "Edit", "internal/app.go")) == 0

    _record_copilot_read(monkeypatch, "copilot-same2", repo, "Read", "CONTRIBUTING.md")
    assert _run(monkeypatch, _copilot_pre("copilot-same2", link, "Edit", "internal/app.go")) == 0


def test_copilot_multiple_guides_must_all_be_read(monkeypatch, tmp_path):
    monkeypatch.setenv(cse.STATE_ENV, str(tmp_path / "state"))
    repo = _repo(tmp_path, "multi", guides=[
        ("CONTRIBUTING.md", "main guide"),
        ("docs/DEVELOPMENT.md", "dev guide"),
    ])
    _record_copilot_read(monkeypatch, "copilot-multi", repo, "Read", "CONTRIBUTING.md")
    assert _run(monkeypatch, _copilot_pre("copilot-multi", repo, "Edit", "internal/app.go")) == 2
    _record_copilot_read(monkeypatch, "copilot-multi", repo, "Read", "docs/DEVELOPMENT.md")
    assert _run(monkeypatch, _copilot_pre("copilot-multi", repo, "Edit", "internal/app.go")) == 0


def test_copilot_missing_state_dir_denies_with_detail(monkeypatch, tmp_path, capsys):
    monkeypatch.delenv(cse.STATE_ENV, raising=False)
    monkeypatch.delenv(cse.XDG_STATE_ENV, raising=False)
    monkeypatch.delenv(cse.HOME_ENV, raising=False)
    repo = _repo(tmp_path, "guided", guides=[("CONTRIBUTING.md", "read me")])
    rc = _run(monkeypatch, _copilot_pre("copilot-same", repo, "Edit", "internal/app.go"))
    assert rc == 2
    assert "could not determine state dir" in capsys.readouterr().err


def test_copilot_corrupt_session_state_denies_with_detail(monkeypatch, tmp_path, capsys):
    state = tmp_path / "state"
    monkeypatch.setenv(cse.STATE_ENV, str(state))
    repo = _repo(tmp_path, "guided", guides=[("CONTRIBUTING.md", "read me")])
    _record_copilot_read(monkeypatch, "copilot-bad-state", repo, "Read", "CONTRIBUTING.md")
    for f in state.glob("*.json"):
        f.write_text("not json")
    rc = _run(monkeypatch, _copilot_pre("copilot-bad-state", repo, "Edit", "internal/app.go"))
    assert rc == 2
    assert "invalid session evidence" in capsys.readouterr().err


def test_copilot_edit_tool_not_in_edit_tools_is_allowed(monkeypatch, tmp_path):
    monkeypatch.setenv(cse.STATE_ENV, str(tmp_path / "state"))
    repo = _repo(tmp_path, "guided", guides=[("CONTRIBUTING.md", "read me")])
    assert _run(monkeypatch, _copilot_pre("copilot-bash", repo, "Bash", "internal/app.go")) == 0


def test_copilot_edit_outside_any_repo_is_allowed(monkeypatch, tmp_path):
    monkeypatch.setenv(cse.STATE_ENV, str(tmp_path / "state"))
    payload = json.dumps({
        "hook_event_name": "PreToolUse",
        "host": "copilot",
        "session_id": "s1",
        "cwd": str(tmp_path),
        "tool_name": "Edit",
        "tool_input": {},
    })
    assert _run(monkeypatch, payload) == 0


def test_copilot_ungated_repo_with_guide_is_allowed(monkeypatch, tmp_path):
    monkeypatch.setenv(cse.STATE_ENV, str(tmp_path / "state"))
    repo = _repo(tmp_path, "ungated", gated=False, guides=[("CONTRIBUTING.md", "x")])
    assert _run(monkeypatch, _copilot_pre("copilot-ungated", repo, "Edit", "internal/app.go")) == 0


def test_copilot_missing_path_ungated_repo_is_allowed(monkeypatch, tmp_path):
    monkeypatch.setenv(cse.STATE_ENV, str(tmp_path / "state"))
    repo = _repo(tmp_path, "bare", guides=[])
    assert _run(monkeypatch, _copilot_pre("copilot-bare", repo, "Edit", None)) == 0
