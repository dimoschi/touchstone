#!/usr/bin/env python3
"""Record and read Copilot guide-read evidence by session.

The contributing gate uses this hook-owned state as operational evidence that a
Copilot PostToolUse Read hook completed successfully for the session. Ordinary
agent-written acknowledgement files do not satisfy that check.

This is not cryptographic proof. Local CLI hooks run with the invoking user's
privileges, so an agent with unrestricted shell access under that same UID can
alter any local hook state. These records are therefore operational evidence,
not a security boundary against same-UID arbitrary shell code. When that threat
model matters, the enforcement boundary is a future policy-level or root-owned
deployment, not these local files.
"""

from __future__ import annotations

import hashlib
import json
import os
import stat
import sys
import tempfile
from collections.abc import Mapping
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))
from hook_invocation import normalize_invocation

STATE_ENV = "TOUCHSTONE_HOOK_STATE_DIR"
OWNER_ONLY_MASK = 0o077
TRUST_BOUNDARY_NOTE = (
    "local CLI hooks run as the invoking user; same-UID shell code can modify "
    "local hook state, so this record is operational evidence rather than a "
    "security boundary. Use a policy-level or root-owned deployment when that "
    "threat model matters"
)


class SessionEvidenceError(RuntimeError):
    """State or payload could not be used safely."""

    def __init__(self, message: str, *, boundary_note: bool = False) -> None:
        self.message = message
        self.boundary_note = boundary_note
        super().__init__(message)

    def __str__(self) -> str:
        if not self.boundary_note:
            return self.message
        return f"{self.message} ({TRUST_BOUNDARY_NOTE})"


def canonical_path(path: str | Path, cwd: str | Path | None = None) -> str:
    """Canonical absolute path, resolving symlinks where the filesystem can."""
    candidate = Path(path)
    if not candidate.is_absolute():
        if cwd is None:
            raise SessionEvidenceError("relative file path needs cwd")
        candidate = Path(cwd) / candidate
    try:
        return str(candidate.resolve(strict=False))
    except (OSError, RuntimeError) as exc:
        raise SessionEvidenceError(f"could not canonicalize path {candidate}: {exc}") from exc


def read_session_paths(session_id: str) -> set[str]:
    """Canonical paths recorded for one Copilot session."""
    if not isinstance(session_id, str) or not session_id:
        raise SessionEvidenceError("session_id is required")

    state_dir = _state_dir(create=False)
    if not state_dir.exists():
        return set()

    record = _read_record(_session_path(state_dir, session_id), session_id, missing_ok=True)
    return set(record["paths"])


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except (json.JSONDecodeError, UnicodeDecodeError) as exc:
        return _fail(f"invalid JSON hook payload: {exc}")

    invocation = normalize_invocation(payload)
    if invocation is None:
        return _fail("malformed hook payload")
    if invocation.host != "copilot" or invocation.event != "post_tool_use":
        return 0
    if invocation.tool_name != "Read":
        return 0

    try:
        result_type = _result_type(payload)
        if result_type != "success":
            return 0
        state_dir = _state_dir(create=True)
        target = _payload_file_path(invocation.tool_input, invocation.cwd)
        prior = _read_record(_session_path(state_dir, invocation.session_id), invocation.session_id, missing_ok=True)
        paths = set(prior["paths"])
        paths.add(target)
        _write_record(state_dir, invocation.session_id, sorted(paths))
    except SessionEvidenceError as exc:
        return _fail(str(exc))
    return 0


def _result_type(payload: object) -> str:
    if not isinstance(payload, Mapping):
        raise SessionEvidenceError("malformed hook payload")
    tool_result = payload.get("tool_result")
    if not isinstance(tool_result, Mapping):
        raise SessionEvidenceError("PostToolUse Read payload missing tool_result")
    result_type = tool_result.get("result_type")
    if not isinstance(result_type, str) or not result_type:
        raise SessionEvidenceError("PostToolUse Read payload missing tool_result.result_type")
    return result_type


def _payload_file_path(tool_input: Mapping[str, object], cwd: Path | None) -> str:
    value = tool_input.get("file_path")
    if not isinstance(value, str) or not value:
        raise SessionEvidenceError("PostToolUse Read payload missing usable tool_input.file_path")
    if cwd is None:
        raise SessionEvidenceError("PostToolUse Read payload missing cwd")
    return canonical_path(value, cwd)


def _state_dir(*, create: bool) -> Path:
    value = os.environ.get(STATE_ENV)
    if not value:
        raise SessionEvidenceError(f"{STATE_ENV} is required")

    state_dir = Path(value)
    status = _lstat(state_dir, label=STATE_ENV, missing_ok=True)
    if status is not None:
        _require_private_directory(status, label=STATE_ENV, path=state_dir)
    if create:
        if status is None:
            try:
                state_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
            except OSError as exc:
                raise SessionEvidenceError(f"could not create {STATE_ENV}: {exc}") from exc
        try:
            os.chmod(state_dir, stat.S_IRWXU)
        except OSError as exc:
            raise SessionEvidenceError(f"could not secure {STATE_ENV}: {exc}") from exc
        secured = _lstat(state_dir, label=STATE_ENV, missing_ok=False)
        assert secured is not None
        _require_private_directory(secured, label=STATE_ENV, path=state_dir)
    return state_dir


def _session_path(state_dir: Path, session_id: str) -> Path:
    digest = hashlib.sha256(session_id.encode("utf-8")).hexdigest()
    return state_dir / f"{digest}.json"


def _read_record(path: Path, session_id: str, *, missing_ok: bool) -> dict[str, Any]:
    status = _lstat(path, label=f"session evidence for {session_id}", missing_ok=missing_ok)
    if status is None:
        if missing_ok:
            return {"session_id": session_id, "paths": []}
        raise SessionEvidenceError(f"missing session evidence for {session_id}")
    _require_safe_record(status, session_id=session_id, path=path)

    try:
        fd = _open_nofollow(path, os.O_RDONLY, label=f"session evidence for {session_id}")
        with os.fdopen(fd, "r", encoding="utf-8") as handle:
            payload = json.load(handle)
    except (OSError, json.JSONDecodeError) as exc:
        raise SessionEvidenceError(f"invalid session evidence for {session_id}: {exc}") from exc
    if not isinstance(payload, dict):
        raise SessionEvidenceError(f"invalid session evidence for {session_id}: record is not an object")
    if payload.get("session_id") != session_id:
        raise SessionEvidenceError(f"invalid session evidence for {session_id}: wrong session_id")
    paths = payload.get("paths")
    if not isinstance(paths, list) or any(not isinstance(path, str) or not path for path in paths):
        raise SessionEvidenceError(f"invalid session evidence for {session_id}: paths must be a string list")
    return {"session_id": session_id, "paths": paths}


def _write_record(state_dir: Path, session_id: str, paths: list[str]) -> None:
    target = _session_path(state_dir, session_id)
    existing = _lstat(target, label=f"session evidence for {session_id}", missing_ok=True)
    if existing is not None:
        _require_safe_record(existing, session_id=session_id, path=target)
    payload = {"session_id": session_id, "paths": paths}
    fd, tmp_name = tempfile.mkstemp(
        dir=state_dir,
        prefix=f"{target.stem}.",
        suffix=".tmp",
    )
    dir_fd = _open_directory(state_dir, label=STATE_ENV)
    try:
        os.fchmod(fd, stat.S_IRUSR | stat.S_IWUSR)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, separators=(",", ":"), sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(
            Path(tmp_name).name,
            target.name,
            src_dir_fd=dir_fd,
            dst_dir_fd=dir_fd,
        )
    except OSError as exc:
        raise SessionEvidenceError(f"could not write session evidence for {session_id}: {exc}") from exc
    finally:
        os.close(dir_fd)
        try:
            os.unlink(tmp_name)
        except FileNotFoundError:
            pass


def _lstat(path: Path, *, label: str, missing_ok: bool) -> os.stat_result | None:
    try:
        return os.lstat(path)
    except FileNotFoundError:
        if missing_ok:
            return None
        raise SessionEvidenceError(f"missing {label}: {path}")
    except OSError as exc:
        raise SessionEvidenceError(f"could not inspect {label}: {exc}") from exc


def _open_nofollow(path: Path, flags: int, *, label: str) -> int:
    open_flags = flags
    if hasattr(os, "O_NOFOLLOW"):
        open_flags |= os.O_NOFOLLOW
    try:
        return os.open(path, open_flags)
    except OSError as exc:
        raise SessionEvidenceError(f"could not open {label}: {exc}") from exc


def _open_directory(path: Path, *, label: str) -> int:
    flags = os.O_RDONLY
    if hasattr(os, "O_DIRECTORY"):
        flags |= os.O_DIRECTORY
    try:
        return os.open(path, flags)
    except OSError as exc:
        raise SessionEvidenceError(f"could not open {label}: {exc}") from exc


def _require_private_directory(status: os.stat_result, *, label: str, path: Path) -> None:
    if stat.S_ISLNK(status.st_mode):
        raise SessionEvidenceError(
            f"{label} must not be a symlink: {path}",
            boundary_note=True,
        )
    if not stat.S_ISDIR(status.st_mode):
        raise SessionEvidenceError(f"{label} is not a directory: {path}", boundary_note=True)
    if stat.S_IMODE(status.st_mode) & OWNER_ONLY_MASK:
        raise SessionEvidenceError(
            f"{label} must have owner-only permissions: {path}",
            boundary_note=True,
        )


def _require_safe_record(status: os.stat_result, *, session_id: str, path: Path) -> None:
    if stat.S_ISLNK(status.st_mode):
        raise SessionEvidenceError(
            f"unsafe session evidence for {session_id}: record must not be a symlink: {path}",
            boundary_note=True,
        )
    if not stat.S_ISREG(status.st_mode):
        raise SessionEvidenceError(
            f"unsafe session evidence for {session_id}: record must be a regular file: {path}",
            boundary_note=True,
        )
    if stat.S_IMODE(status.st_mode) & OWNER_ONLY_MASK:
        raise SessionEvidenceError(
            f"unsafe session evidence for {session_id}: record must have owner-only permissions: {path}",
            boundary_note=True,
        )


def _fail(message: str) -> int:
    print(f"copilot-session-evidence: {message}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
