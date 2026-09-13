import io
import json
import os
import stat
from pathlib import Path

import pytest

import copilot_session_evidence as cse


def test_canonical_path_absolute_no_cwd_needed(tmp_path):
    target = tmp_path / "a.py"
    target.write_text("x")
    assert cse.canonical_path(str(target)) == str(target.resolve())


def test_canonical_path_relative_without_cwd_raises():
    with pytest.raises(cse.SessionEvidenceError, match="needs cwd"):
        cse.canonical_path("a.py")


def test_canonical_path_relative_with_cwd(tmp_path):
    assert cse.canonical_path("a.py", tmp_path) == str((tmp_path / "a.py").resolve())


def test_session_evidence_error_str_with_and_without_boundary_note():
    plain = cse.SessionEvidenceError("plain message")
    assert str(plain) == "plain message"
    noted = cse.SessionEvidenceError("plain message", boundary_note=True)
    assert cse.TRUST_BOUNDARY_NOTE in str(noted)


def _env_state_dir(monkeypatch, tmp_path):
    state_dir = tmp_path / "state"
    monkeypatch.setenv(cse.STATE_ENV, str(state_dir))
    monkeypatch.delenv(cse.XDG_STATE_ENV, raising=False)
    return state_dir


def test_read_session_paths_missing_state_dir_returns_empty(monkeypatch, tmp_path):
    _env_state_dir(monkeypatch, tmp_path)
    assert cse.read_session_paths("s1") == set()


def test_read_session_paths_requires_session_id():
    with pytest.raises(cse.SessionEvidenceError, match="session_id is required"):
        cse.read_session_paths("")
    with pytest.raises(cse.SessionEvidenceError):
        cse.read_session_paths(None)


def test_state_dir_default_uses_xdg_state_home(monkeypatch, tmp_path):
    monkeypatch.delenv(cse.STATE_ENV, raising=False)
    xdg = tmp_path / "xdg"
    monkeypatch.setenv(cse.XDG_STATE_ENV, str(xdg))
    d = cse._state_dir(create=True)
    assert d == xdg / cse.STATE_SUBDIR
    assert d.is_dir()
    assert stat.S_IMODE(d.stat().st_mode) == stat.S_IRWXU


def test_state_dir_default_falls_back_to_home(monkeypatch, tmp_path):
    monkeypatch.delenv(cse.STATE_ENV, raising=False)
    monkeypatch.delenv(cse.XDG_STATE_ENV, raising=False)
    home = tmp_path / "home"
    monkeypatch.setenv(cse.HOME_ENV, str(home))
    d = cse._state_dir(create=True)
    assert d == home / ".local" / "state" / cse.STATE_SUBDIR


def test_state_dir_no_env_at_all_raises(monkeypatch):
    monkeypatch.delenv(cse.STATE_ENV, raising=False)
    monkeypatch.delenv(cse.XDG_STATE_ENV, raising=False)
    monkeypatch.delenv(cse.HOME_ENV, raising=False)
    with pytest.raises(cse.SessionEvidenceError, match="could not determine state dir"):
        cse._state_dir(create=False)


def test_validated_base_dir_rejects_relative(monkeypatch):
    monkeypatch.setenv("SOME_VAR", "relative/path")
    with pytest.raises(cse.SessionEvidenceError, match="must be an absolute path"):
        cse._validated_base_dir("SOME_VAR")


def test_validated_base_dir_none_when_unset(monkeypatch):
    monkeypatch.delenv("SOME_VAR", raising=False)
    assert cse._validated_base_dir("SOME_VAR") is None


def test_state_dir_rejects_symlinked_directory(monkeypatch, tmp_path):
    real = tmp_path / "real"
    real.mkdir(mode=0o700)
    link = tmp_path / "link"
    link.symlink_to(real)
    monkeypatch.setenv(cse.STATE_ENV, str(link))
    with pytest.raises(cse.SessionEvidenceError, match="must not be a symlink"):
        cse._state_dir(create=False)


def test_state_dir_rejects_group_or_world_permissions(monkeypatch, tmp_path):
    state_dir = tmp_path / "state"
    # mkdir(mode=...) is masked by the process umask, so a strict umask (077)
    # would silently narrow 0o755 to 0o700 and this test would never see the
    # permissions it means to reject. chmod is not subject to umask.
    state_dir.mkdir()
    os.chmod(state_dir, 0o755)
    monkeypatch.setenv(cse.STATE_ENV, str(state_dir))
    with pytest.raises(cse.SessionEvidenceError, match="owner-only permissions"):
        cse._state_dir(create=False)


def test_state_dir_rejects_non_directory(monkeypatch, tmp_path):
    state_path = tmp_path / "state"
    state_path.write_text("not a dir")
    monkeypatch.setenv(cse.STATE_ENV, str(state_path))
    with pytest.raises(cse.SessionEvidenceError, match="is not a directory"):
        cse._state_dir(create=False)


def test_state_dir_create_is_idempotent_on_an_already_secure_dir(monkeypatch, tmp_path):
    state_dir = tmp_path / "state"
    monkeypatch.setenv(cse.STATE_ENV, str(state_dir))
    first = cse._state_dir(create=True)
    second = cse._state_dir(create=True)
    assert first == second
    assert stat.S_IMODE(second.stat().st_mode) == stat.S_IRWXU


def test_write_and_read_record_round_trip(monkeypatch, tmp_path):
    state_dir = _env_state_dir(monkeypatch, tmp_path)
    cse._write_record(cse._state_dir(create=True), "s1", ["/a", "/b"])
    assert cse.read_session_paths("s1") == {"/a", "/b"}


def test_read_record_missing_ok_returns_empty_shape(tmp_path):
    result = cse._read_record(tmp_path / "nope.json", "s1", missing_ok=True)
    assert result == {"session_id": "s1", "paths": []}


def test_read_record_missing_not_ok_raises(tmp_path):
    with pytest.raises(cse.SessionEvidenceError, match="missing session evidence"):
        cse._read_record(tmp_path / "nope.json", "s1", missing_ok=False)


def test_read_record_rejects_symlinked_record(tmp_path):
    real = tmp_path / "real.json"
    real.write_text(json.dumps({"session_id": "s1", "paths": []}))
    os.chmod(real, 0o600)
    link = tmp_path / "link.json"
    link.symlink_to(real)
    with pytest.raises(cse.SessionEvidenceError, match="must not be a symlink"):
        cse._read_record(link, "s1", missing_ok=True)


def test_read_record_rejects_group_readable_file(tmp_path):
    rec = tmp_path / "rec.json"
    rec.write_text(json.dumps({"session_id": "s1", "paths": []}))
    os.chmod(rec, 0o644)
    with pytest.raises(cse.SessionEvidenceError, match="owner-only permissions"):
        cse._read_record(rec, "s1", missing_ok=True)


def test_read_record_rejects_non_regular_file(tmp_path):
    d = tmp_path / "adir.json"
    d.mkdir(mode=0o700)
    with pytest.raises(cse.SessionEvidenceError, match="must be a regular file"):
        cse._read_record(d, "s1", missing_ok=True)


def test_read_record_rejects_invalid_json(tmp_path):
    rec = tmp_path / "rec.json"
    rec.write_text("{not json")
    os.chmod(rec, 0o600)
    with pytest.raises(cse.SessionEvidenceError, match="invalid session evidence"):
        cse._read_record(rec, "s1", missing_ok=True)


def test_read_record_rejects_non_object_payload(tmp_path):
    rec = tmp_path / "rec.json"
    rec.write_text("[1, 2]")
    os.chmod(rec, 0o600)
    with pytest.raises(cse.SessionEvidenceError, match="record is not an object"):
        cse._read_record(rec, "s1", missing_ok=True)


def test_read_record_rejects_wrong_session_id(tmp_path):
    rec = tmp_path / "rec.json"
    rec.write_text(json.dumps({"session_id": "other", "paths": []}))
    os.chmod(rec, 0o600)
    with pytest.raises(cse.SessionEvidenceError, match="wrong session_id"):
        cse._read_record(rec, "s1", missing_ok=True)


def test_read_record_rejects_non_list_paths(tmp_path):
    rec = tmp_path / "rec.json"
    rec.write_text(json.dumps({"session_id": "s1", "paths": "not-a-list"}))
    os.chmod(rec, 0o600)
    with pytest.raises(cse.SessionEvidenceError, match="paths must be a string list"):
        cse._read_record(rec, "s1", missing_ok=True)


def test_read_record_rejects_non_string_path_entries(tmp_path):
    rec = tmp_path / "rec.json"
    rec.write_text(json.dumps({"session_id": "s1", "paths": [1, 2]}))
    os.chmod(rec, 0o600)
    with pytest.raises(cse.SessionEvidenceError, match="paths must be a string list"):
        cse._read_record(rec, "s1", missing_ok=True)


def test_write_record_rejects_existing_unsafe_record(monkeypatch, tmp_path):
    state_dir = _env_state_dir(monkeypatch, tmp_path)
    d = cse._state_dir(create=True)
    target = cse._session_path(d, "s1")
    target.write_text(json.dumps({"session_id": "s1", "paths": []}))
    os.chmod(target, 0o644)
    with pytest.raises(cse.SessionEvidenceError, match="owner-only permissions"):
        cse._write_record(d, "s1", ["/a"])


def test_main_invalid_json_stdin_fails(monkeypatch, capsys):
    monkeypatch.setattr("sys.stdin", io.StringIO("not json"))
    assert cse.main() == 2
    assert "invalid JSON hook payload" in capsys.readouterr().err


def test_main_malformed_payload_fails(monkeypatch, capsys):
    monkeypatch.setattr("sys.stdin", io.StringIO(json.dumps({"nope": True})))
    assert cse.main() == 2
    assert "malformed hook payload" in capsys.readouterr().err


def test_main_ignores_non_copilot_or_non_post_tool_use(monkeypatch):
    payload = {
        "hook_event_name": "PreToolUse",
        "session_id": "s1",
        "cwd": "/tmp",
        "tool_name": "Read",
        "tool_input": {"path": "/a"},
    }
    monkeypatch.setattr("sys.stdin", io.StringIO(json.dumps(payload)))
    assert cse.main() == 0


def test_main_ignores_non_read_tool(monkeypatch):
    payload = {
        "hook_event_name": "PostToolUse",
        "session_id": "s1",
        "cwd": "/tmp",
        "tool_name": "Edit",
        "tool_input": {"path": "/a"},
        "tool_result": {"result_type": "success"},
    }
    monkeypatch.setattr("sys.stdin", io.StringIO(json.dumps(payload)))
    assert cse.main() == 0


def test_result_type_rejects_non_mapping_payload():
    with pytest.raises(cse.SessionEvidenceError, match="malformed hook payload"):
        cse._result_type([1, 2])


def test_result_type_requires_tool_result_mapping():
    with pytest.raises(cse.SessionEvidenceError, match="missing tool_result"):
        cse._result_type({"tool_result": "nope"})


def test_result_type_requires_result_type_string():
    with pytest.raises(cse.SessionEvidenceError, match="missing tool_result.result_type"):
        cse._result_type({"tool_result": {}})


def test_main_non_success_result_type_is_a_no_op(monkeypatch):
    payload = {
        "hook_event_name": "PostToolUse",
        "session_id": "s1",
        "cwd": "/tmp",
        "tool_name": "Read",
        "tool_input": {"path": "/a"},
        "tool_result": {"result_type": "error"},
    }
    monkeypatch.setattr("sys.stdin", io.StringIO(json.dumps(payload)))
    assert cse.main() == 0


def test_payload_path_requires_path_and_cwd():
    with pytest.raises(cse.SessionEvidenceError, match="missing usable tool_input.path"):
        cse._payload_path({}, Path("/tmp"))
    with pytest.raises(cse.SessionEvidenceError, match="missing cwd"):
        cse._payload_path({"path": "a.py"}, None)


def test_main_records_a_successful_read(monkeypatch, tmp_path):
    _env_state_dir(monkeypatch, tmp_path)
    target = tmp_path / "CONTRIBUTING.md"
    target.write_text("guide")
    payload = {
        "hook_event_name": "PostToolUse",
        "session_id": "s1",
        "cwd": str(tmp_path),
        "tool_name": "Read",
        "tool_input": {"path": "CONTRIBUTING.md"},
        "tool_result": {"result_type": "success"},
    }
    monkeypatch.setattr("sys.stdin", io.StringIO(json.dumps(payload)))
    assert cse.main() == 0
    assert cse.read_session_paths("s1") == {str(target.resolve())}


def test_main_appends_to_an_existing_session_record(monkeypatch, tmp_path):
    _env_state_dir(monkeypatch, tmp_path)
    a = tmp_path / "a.md"
    a.write_text("x")
    b = tmp_path / "b.md"
    b.write_text("y")

    def read(target_name):
        payload = {
            "hook_event_name": "PostToolUse",
            "session_id": "s1",
            "cwd": str(tmp_path),
            "tool_name": "Read",
            "tool_input": {"path": target_name},
            "tool_result": {"result_type": "success"},
        }
        return json.dumps(payload)

    monkeypatch.setattr("sys.stdin", io.StringIO(read("a.md")))
    assert cse.main() == 0
    monkeypatch.setattr("sys.stdin", io.StringIO(read("b.md")))
    assert cse.main() == 0
    assert cse.read_session_paths("s1") == {str(a.resolve()), str(b.resolve())}


def test_canonical_path_resolve_failure_is_reported(monkeypatch, tmp_path):
    def boom(self, strict=False):
        raise OSError("loop")

    monkeypatch.setattr(Path, "resolve", boom)
    with pytest.raises(cse.SessionEvidenceError, match="could not canonicalize path"):
        cse.canonical_path(str(tmp_path / "a.py"))


def test_lstat_generic_os_error_is_wrapped(monkeypatch, tmp_path):
    def boom(path):
        raise PermissionError("denied")

    monkeypatch.setattr(cse.os, "lstat", boom)
    with pytest.raises(cse.SessionEvidenceError, match="could not inspect"):
        cse._lstat(tmp_path / "x", label="thing", missing_ok=True)


def test_read_record_missing_ok_false_but_lstat_returns_none_is_defensive(monkeypatch, tmp_path):
    # _lstat never actually returns None when missing_ok=False (it raises
    # instead), so this branch of _read_record only guards a hypothetical
    # future _lstat change; force it via a stub to keep it covered.
    monkeypatch.setattr(cse, "_lstat", lambda *a, **k: None)
    with pytest.raises(cse.SessionEvidenceError, match="missing session evidence"):
        cse._read_record(tmp_path / "x", "s1", missing_ok=False)


def test_state_dir_mkdir_failure_is_wrapped(monkeypatch, tmp_path):
    monkeypatch.setenv(cse.STATE_ENV, str(tmp_path / "state"))

    def boom(*a, **k):
        raise OSError("cannot create")

    monkeypatch.setattr(Path, "mkdir", boom)
    with pytest.raises(cse.SessionEvidenceError, match="could not create"):
        cse._state_dir(create=True)


def test_state_dir_chmod_failure_is_wrapped(monkeypatch, tmp_path):
    state_dir = tmp_path / "state"
    state_dir.mkdir(mode=0o700)
    monkeypatch.setenv(cse.STATE_ENV, str(state_dir))

    def boom(*a, **k):
        raise OSError("cannot chmod")

    monkeypatch.setattr(cse.os, "chmod", boom)
    with pytest.raises(cse.SessionEvidenceError, match="could not secure"):
        cse._state_dir(create=True)


def test_write_record_wraps_os_error(monkeypatch, tmp_path):
    state_dir = tmp_path / "state"
    state_dir.mkdir(mode=0o700)

    def boom(*a, **k):
        raise OSError("cannot fchmod")

    monkeypatch.setattr(cse.os, "fchmod", boom)
    with pytest.raises(cse.SessionEvidenceError, match="could not write session evidence"):
        cse._write_record(state_dir, "s1", ["/a"])


def test_open_nofollow_wraps_os_error(monkeypatch, tmp_path):
    def boom(*a, **k):
        raise OSError("cannot open")

    monkeypatch.setattr(cse.os, "open", boom)
    with pytest.raises(cse.SessionEvidenceError, match="could not open"):
        cse._open_nofollow(tmp_path / "x", cse.os.O_RDONLY, label="thing")


def test_open_directory_wraps_os_error(monkeypatch, tmp_path):
    def boom(*a, **k):
        raise OSError("cannot open dir")

    monkeypatch.setattr(cse.os, "open", boom)
    with pytest.raises(cse.SessionEvidenceError, match="could not open"):
        cse._open_directory(tmp_path, label="thing")


def test_main_session_evidence_error_is_reported(monkeypatch, tmp_path, capsys):
    monkeypatch.delenv(cse.STATE_ENV, raising=False)
    monkeypatch.delenv(cse.XDG_STATE_ENV, raising=False)
    monkeypatch.delenv(cse.HOME_ENV, raising=False)
    payload = {
        "hook_event_name": "PostToolUse",
        "session_id": "s1",
        "cwd": str(tmp_path),
        "tool_name": "Read",
        "tool_input": {"path": "a.md"},
        "tool_result": {"result_type": "success"},
    }
    monkeypatch.setattr("sys.stdin", io.StringIO(json.dumps(payload)))
    rc = cse.main()
    assert rc == 2
    assert "could not determine state dir" in capsys.readouterr().err
