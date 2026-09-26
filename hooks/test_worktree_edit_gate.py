import io
import json
import subprocess
from pathlib import Path

from conftest import load_script

gate = load_script(Path(__file__).resolve().parent / "worktree-edit-gate.py")


def _git_init(path):
    subprocess.run(["git", "init", "-q", str(path)], cwd=path.parent, check=True)


def _repo(tmp_path, name="repo"):
    root = tmp_path / name
    root.mkdir(parents=True)
    _git_init(root)
    return root


def _worktree(root, name="wt"):
    wt = root.parent / f"{root.name}-{name}"
    subprocess.run(
        ["git", "-C", str(root), "worktree", "add", "-q", "-b", f"{name}-branch", str(wt)],
        check=True, capture_output=True, text=True,
    )
    return wt


def _header(label, worktree):
    return (
        f"[touchstone: {label}]\n"
        f"Work in the git worktree at {worktree}. Every command, git included, acts "
        f"on that tree.\n\n"
        f"Ticket 1: stub\n"
        f"Repo worktree: {worktree}\nBranch: fix/gh-1-stub (base main)\n\n"
        f"Implement this task.\n"
    )


def _write_transcript(path, entries):
    path.parent.mkdir(parents=True, exist_ok=True)
    lines = [json.dumps(e) for e in entries]
    path.write_text("\n".join(lines) + "\n")


def _subagent_transcript(parent, agent_id):
    dest = Path(str(parent)[: -len(".jsonl")]) / "subagents"
    dest.mkdir(parents=True, exist_ok=True)
    return dest / f"agent-{agent_id}.jsonl"


def _payload(*, tool_name="Edit", path, cwd, transcript=None, agent_id=None):
    payload = {
        "hook_event_name": "PreToolUse",
        "session_id": "s1",
        "cwd": str(cwd),
        "tool_name": tool_name,
        "tool_input": {"file_path": path},
    }
    if transcript is not None:
        payload["transcript_path"] = str(transcript)
    if agent_id is not None:
        payload["agent_id"] = agent_id
    return json.dumps(payload)


def _run(monkeypatch, payload):
    monkeypatch.setattr("sys.stdin", io.StringIO(payload))
    return gate.main()


def _active_run(monkeypatch, tmp_path, wt, path, *, label="implementer"):
    # The parent transcript itself is never opened: subagent_transcript only
    # needs its path to derive the sibling subagents/ directory.
    parent = tmp_path / "s1.jsonl"
    sub = _subagent_transcript(parent, "a1")
    _write_transcript(sub, [
        {"type": "user", "message": {"content": _header(label, wt)}},
    ])
    return _run(monkeypatch, _payload(
        path=str(path), cwd=str(wt), transcript=parent, agent_id="a1"))


def test_edit_in_main_checkout_is_refused_and_names_the_worktree(monkeypatch, tmp_path, capsys):
    repo = _repo(tmp_path)
    wt = _worktree(repo)
    rc = _active_run(monkeypatch, tmp_path, wt, repo / "app.py")
    err = capsys.readouterr().err
    assert rc == 2
    assert str(wt.resolve()) in err
    assert str((repo / "app.py").resolve()) in err


def test_the_same_edit_inside_the_worktree_is_allowed(monkeypatch, tmp_path):
    repo = _repo(tmp_path)
    wt = _worktree(repo)
    rc = _active_run(monkeypatch, tmp_path, wt, wt / "app.py")
    assert rc == 0


def test_edit_to_main_checkout_with_no_agent_id_is_allowed(monkeypatch, tmp_path):
    """The invoking session sends no agent_id, so it is never refused."""
    repo = _repo(tmp_path)
    rc = _run(monkeypatch, _payload(path=str(repo / "app.py"), cwd=str(repo)))
    assert rc == 0


def test_subagent_with_no_transcript_on_disk_is_allowed(monkeypatch, tmp_path):
    """No opt-in marker exists for this gate, so a missing subagent transcript
    fails open rather than refusing every subagent's first edit."""
    repo = _repo(tmp_path)
    parent = tmp_path / "s1.jsonl"
    rc = _run(monkeypatch, _payload(
        path=str(repo / "app.py"), cwd=str(repo), transcript=parent, agent_id="ghost"))
    assert rc == 0


def test_subagent_with_no_touchstone_header_is_allowed(monkeypatch, tmp_path):
    """Not every subagent is a pipeline treeAgent dispatch."""
    repo = _repo(tmp_path)
    parent = tmp_path / "s1.jsonl"
    sub = _subagent_transcript(parent, "a1")
    _write_transcript(sub, [{"type": "user", "message": {"content": "just do the task"}}])
    rc = _run(monkeypatch, _payload(
        path=str(repo / "app.py"), cwd=str(repo), transcript=parent, agent_id="a1"))
    assert rc == 0


def test_header_without_a_worktree_line_is_allowed(monkeypatch, tmp_path):
    repo = _repo(tmp_path)
    parent = tmp_path / "s1.jsonl"
    sub = _subagent_transcript(parent, "a1")
    _write_transcript(sub, [
        {"type": "user", "message": {"content": "[touchstone: setup]\nno worktree yet\n"}},
    ])
    rc = _run(monkeypatch, _payload(
        path=str(repo / "app.py"), cwd=str(repo), transcript=parent, agent_id="a1"))
    assert rc == 0


def test_an_indented_header_still_counts(monkeypatch, tmp_path):
    """The real transcript wraps every line of the harness-computed prompt
    with two leading spaces, so the header and worktree lines are indented,
    not at column zero."""
    repo = _repo(tmp_path)
    wt = _worktree(repo)
    parent = tmp_path / "s1.jsonl"
    sub = _subagent_transcript(parent, "a1")
    indented = "\n".join(f"  {line}" if line else line
                          for line in _header("implementer", wt).split("\n"))
    _write_transcript(sub, [{"type": "user", "message": {"content": indented}}])
    rc = _run(monkeypatch, _payload(
        path=str(repo / "app.py"), cwd=str(repo), transcript=parent, agent_id="a1"))
    assert rc == 2


def test_a_later_transcript_entry_naming_the_header_does_not_count(monkeypatch, tmp_path):
    """Only the first type=='user' entry is read; a later one quoting the same
    two lines back is the agent's own words, not the dispatch header."""
    repo = _repo(tmp_path)
    wt = _worktree(repo)
    parent = tmp_path / "s1.jsonl"
    sub = _subagent_transcript(parent, "a1")
    _write_transcript(sub, [
        {"type": "user", "message": {"content": "no header on the first message"}},
        {"type": "assistant", "message": {"content": _header("implementer", wt)}},
    ])
    rc = _run(monkeypatch, _payload(
        path=str(repo / "app.py"), cwd=str(repo), transcript=parent, agent_id="a1"))
    assert rc == 0


def test_another_worktree_under_claude_worktrees_is_refused(monkeypatch, tmp_path):
    """Only the agent's own ticket worktree is exempt. A session running in a
    worktree of its own (EnterWorktree puts it under .claude/worktrees/) is
    where a stray relative path lands, so another worktree is refused too."""
    repo = _repo(tmp_path)
    other_wt = repo / ".claude" / "worktrees" / "gh-2-other"
    other_wt.mkdir(parents=True)
    subprocess.run(
        ["git", "-C", str(repo), "worktree", "add", "-q", "-b", "other-branch", str(other_wt)],
        check=True, capture_output=True, text=True,
    )
    wt = _worktree(repo)
    rc = _active_run(monkeypatch, tmp_path, wt, other_wt / "app.py")
    assert rc == 2


def test_a_path_inside_the_git_common_dir_is_never_refused(monkeypatch, tmp_path):
    repo = _repo(tmp_path)
    wt = _worktree(repo)
    rc = _active_run(monkeypatch, tmp_path, wt, repo / ".git" / "some-ledger.json")
    assert rc == 0


def test_existing_branch_reuse_where_the_worktree_is_the_main_checkout_is_allowed(
        monkeypatch, tmp_path):
    """20-setup-worktree.js.part allows the existingBranch mode to reuse the
    main checkout as its own 'worktree'; that must never be refused."""
    repo = _repo(tmp_path)
    rc = _active_run(monkeypatch, tmp_path, repo, repo / "app.py")
    assert rc == 0


def test_a_relative_path_is_resolved_against_the_payload_cwd(monkeypatch, tmp_path):
    """The ticket's exact failure mode: a relative tool_input path joined with
    the wrong cwd lands in the main checkout unnoticed."""
    repo = _repo(tmp_path)
    wt = _worktree(repo)
    parent = tmp_path / "s1.jsonl"
    sub = _subagent_transcript(parent, "a1")
    _write_transcript(sub, [
        {"type": "user", "message": {"content": _header("implementer", wt)}},
    ])
    rc = _run(monkeypatch, _payload(path="app.py", cwd=str(repo), transcript=parent, agent_id="a1"))
    assert rc == 2


def test_a_relative_path_resolved_against_the_worktree_cwd_is_allowed(monkeypatch, tmp_path):
    repo = _repo(tmp_path)
    wt = _worktree(repo)
    parent = tmp_path / "s1.jsonl"
    sub = _subagent_transcript(parent, "a1")
    _write_transcript(sub, [
        {"type": "user", "message": {"content": _header("implementer", wt)}},
    ])
    rc = _run(monkeypatch, _payload(path="app.py", cwd=str(wt), transcript=parent, agent_id="a1"))
    assert rc == 0


def test_a_target_outside_the_repo_entirely_is_allowed(monkeypatch, tmp_path):
    repo = _repo(tmp_path)
    wt = _worktree(repo)
    elsewhere = tmp_path / "unrelated"
    elsewhere.mkdir()
    rc = _active_run(monkeypatch, tmp_path, wt, elsewhere / "scratch.py")
    assert rc == 0


def test_non_edit_tool_is_allowed(monkeypatch, tmp_path):
    repo = _repo(tmp_path)
    rc = _run(monkeypatch, _payload(tool_name="Bash", path=str(repo / "app.py"), cwd=str(repo)))
    assert rc == 0


def test_no_usable_path_is_allowed(monkeypatch, tmp_path):
    payload = json.dumps({
        "hook_event_name": "PreToolUse", "cwd": str(tmp_path),
        "tool_name": "Edit", "tool_input": {},
    })
    assert _run(monkeypatch, payload) == 0


def test_invalid_json_stdin_is_allowed(monkeypatch):
    monkeypatch.setattr("sys.stdin", io.StringIO("not json"))
    assert gate.main() == 0


def test_non_dict_json_stdin_is_allowed(monkeypatch):
    monkeypatch.setattr("sys.stdin", io.StringIO("[1, 2, 3]"))
    assert gate.main() == 0


def test_non_dict_tool_input_is_allowed(monkeypatch, tmp_path):
    payload = json.dumps({
        "hook_event_name": "PreToolUse", "cwd": str(tmp_path),
        "tool_name": "Edit", "tool_input": "nope", "agent_id": "a1",
    })
    assert _run(monkeypatch, payload) == 0


def test_agent_id_with_no_transcript_path_at_all_is_allowed(monkeypatch, tmp_path):
    repo = _repo(tmp_path)
    payload = json.dumps({
        "hook_event_name": "PreToolUse", "cwd": str(repo),
        "tool_name": "Edit", "tool_input": {"file_path": str(repo / "app.py")},
        "agent_id": "a1",
    })
    assert _run(monkeypatch, payload) == 0


def test_transcript_with_no_user_entry_at_all_is_allowed(monkeypatch, tmp_path):
    repo = _repo(tmp_path)
    parent = tmp_path / "s1.jsonl"
    sub = _subagent_transcript(parent, "a1")
    _write_transcript(sub, [{"type": "assistant", "message": {"content": "chatter only"}}])
    rc = _run(monkeypatch, _payload(
        path=str(repo / "app.py"), cwd=str(repo), transcript=parent, agent_id="a1"))
    assert rc == 0


def test_transcript_that_cannot_be_opened_is_allowed(monkeypatch, tmp_path):
    """A directory in the transcript's place raises OSError on open(), not
    evidence of anything -- this hook has no opt-in marker to fail closed
    behind, so it stays silent rather than guessing."""
    repo = _repo(tmp_path)
    parent = tmp_path / "s1.jsonl"
    sub = _subagent_transcript(parent, "a1")
    sub.mkdir()  # a directory where the transcript file would be
    rc = _run(monkeypatch, _payload(
        path=str(repo / "app.py"), cwd=str(repo), transcript=parent, agent_id="a1"))
    assert rc == 0


def test_worktree_gone_from_disk_is_allowed(monkeypatch, tmp_path):
    """repo_common_root resolves nothing for a path that is no longer a repo
    at all -- the worktree was removed after the header was written."""
    repo = _repo(tmp_path)
    ghost = tmp_path / "ghost-worktree"
    ghost.mkdir()
    parent = tmp_path / "s1.jsonl"
    sub = _subagent_transcript(parent, "a1")
    _write_transcript(sub, [
        {"type": "user", "message": {"content": _header("implementer", ghost)}},
    ])
    rc = _run(monkeypatch, _payload(
        path=str(repo / "app.py"), cwd=str(repo), transcript=parent, agent_id="a1"))
    assert rc == 0


def test_content_as_a_list_of_text_blocks_is_read(monkeypatch, tmp_path):
    """A non-dict block and a dict block of another type sit alongside the
    real one, the same as a real transcript's tool_use and image blocks
    would, and must not contribute to the joined text."""
    repo = _repo(tmp_path)
    wt = _worktree(repo)
    parent = tmp_path / "s1.jsonl"
    sub = _subagent_transcript(parent, "a1")
    _write_transcript(sub, [
        {"type": "user", "message": {"content": [
            "not even a dict",
            {"type": "tool_use", "name": "Read", "input": {}},
            {"type": "text", "text": _header("implementer", wt)},
        ]}},
    ])
    rc = _run(monkeypatch, _payload(
        path=str(repo / "app.py"), cwd=str(repo), transcript=parent, agent_id="a1"))
    assert rc == 2


def test_content_of_unrecognised_shape_is_allowed(monkeypatch, tmp_path):
    repo = _repo(tmp_path)
    parent = tmp_path / "s1.jsonl"
    sub = _subagent_transcript(parent, "a1")
    _write_transcript(sub, [{"type": "user", "message": {"content": 5}}])
    rc = _run(monkeypatch, _payload(
        path=str(repo / "app.py"), cwd=str(repo), transcript=parent, agent_id="a1"))
    assert rc == 0


def test_unparseable_line_before_the_user_entry_does_not_stop_the_scan(monkeypatch, tmp_path):
    repo = _repo(tmp_path)
    wt = _worktree(repo)
    parent = tmp_path / "s1.jsonl"
    sub = _subagent_transcript(parent, "a1")
    sub.parent.mkdir(parents=True, exist_ok=True)
    sub.write_text(
        "not even json {\n"
        + json.dumps({"type": "assistant", "message": {"content": "ignored"}}) + "\n"
        + json.dumps({"type": "user", "message": {"content": _header("implementer", wt)}}) + "\n"
    )
    rc = _run(monkeypatch, _payload(
        path=str(repo / "app.py"), cwd=str(repo), transcript=parent, agent_id="a1"))
    assert rc == 2


def test_entry_text_skips_non_text_blocks_and_textless_ones():
    entry = {"message": {"content": [
        {"type": "image"}, {"type": "text"}, {"type": "text", "text": "a"}]}}
    assert gate._entry_text(entry) == "\n\na"


def test_entry_text_of_a_non_dict_message_is_none():
    assert gate._entry_text({"message": "a bare string"}) is None


def test_first_user_entry_reads_past_undecodable_bytes(tmp_path):
    transcript = tmp_path / "agent-a1.jsonl"
    user = {"type": "user", "message": {"content": "hi"}}
    transcript.write_bytes(b'\xff\xfe not json\n' + json.dumps(user).encode() + b"\n")
    assert gate._first_user_entry(transcript) == user


def test_edit_target_falls_back_to_dot_for_a_missing_empty_or_non_string_cwd():
    base = {"tool_name": "Edit", "tool_input": {"file_path": "a.py"}}
    assert gate._edit_target(base) == ("a.py", ".")
    assert gate._edit_target({**base, "cwd": ""}) == ("a.py", ".")
    assert gate._edit_target({**base, "cwd": None}) == ("a.py", ".")
    assert gate._edit_target({**base, "cwd": "/w"}) == ("a.py", "/w")


def test_a_non_string_transcript_path_names_no_worktree():
    assert gate._active_worktree_for({"agent_id": "a1", "transcript_path": 123}) is None
