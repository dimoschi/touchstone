#!/usr/bin/env python3
"""Record and read Copilot guide-read evidence by session.

The contributing gate needs proof that this Copilot session read the repo's
guide. Copilot's PostToolUse Read event is the only reliable source: it is
emitted by the harness after a tool run succeeds, so a writer-created note
cannot fake it.
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


class SessionEvidenceError(RuntimeError):
    """State or payload could not be used safely."""


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
    if state_dir.exists() and not state_dir.is_dir():
        raise SessionEvidenceError(f"{STATE_ENV} is not a directory: {state_dir}")
    if create:
        try:
            state_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
        except OSError as exc:
            raise SessionEvidenceError(f"could not create {STATE_ENV}: {exc}") from exc
        try:
            os.chmod(state_dir, stat.S_IRWXU)
        except OSError as exc:
            raise SessionEvidenceError(f"could not secure {STATE_ENV}: {exc}") from exc
    return state_dir


def _session_path(state_dir: Path, session_id: str) -> Path:
    digest = hashlib.sha256(session_id.encode("utf-8")).hexdigest()
    return state_dir / f"{digest}.json"


def _read_record(path: Path, session_id: str, *, missing_ok: bool) -> dict[str, Any]:
    if not path.exists():
        if missing_ok:
            return {"session_id": session_id, "paths": []}
        raise SessionEvidenceError(f"missing session evidence for {session_id}")

    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
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
    payload = {"session_id": session_id, "paths": paths}
    fd, tmp_name = tempfile.mkstemp(
        dir=state_dir,
        prefix=f"{target.stem}.",
        suffix=".tmp",
    )
    try:
        os.fchmod(fd, stat.S_IRUSR | stat.S_IWUSR)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, separators=(",", ":"), sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp_name, target)
    except OSError as exc:
        raise SessionEvidenceError(f"could not write session evidence for {session_id}: {exc}") from exc
    finally:
        try:
            os.unlink(tmp_name)
        except FileNotFoundError:
            pass


def _fail(message: str) -> int:
    print(f"copilot-session-evidence: {message}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
