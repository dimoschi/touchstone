#!/usr/bin/env python3
"""Record exact hook stdin for smoke assertions, then run the real hook."""

from __future__ import annotations

import os
import stat
import subprocess
import sys
import tempfile
from pathlib import Path

EVIDENCE_ENV = "TOUCHSTONE_HOOK_INPUT_EVIDENCE_DIR"


def main() -> int:
    if len(sys.argv) != 3:
        print(
            "usage: copilot-hook-smoke-logger.py <runner-path> <hook-key>",
            file=sys.stderr,
        )
        return 2

    runner = Path(sys.argv[1])
    hook_key = sys.argv[2]
    raw = sys.stdin.buffer.read()

    try:
        evidence_dir = _evidence_dir()
        _write_evidence(evidence_dir, hook_key, raw)
    except OSError as exc:
        print(f"copilot-hook-smoke-logger: could not record hook stdin: {exc}", file=sys.stderr)
        return 1

    try:
        result = subprocess.run(
            [sys.executable, str(runner), hook_key],
            input=raw,
            capture_output=True,
            check=False,
        )
    except OSError as exc:
        print(f"copilot-hook-smoke-logger: could not start runner: {exc}", file=sys.stderr)
        return 1

    sys.stdout.buffer.write(result.stdout)
    sys.stderr.buffer.write(result.stderr)
    return result.returncode


def _evidence_dir() -> Path:
    value = os.environ.get(EVIDENCE_ENV)
    if not value:
        raise OSError(f"{EVIDENCE_ENV} is required")

    path = Path(value)
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(path, stat.S_IRWXU)
    return path


def _write_evidence(evidence_dir: Path, hook_key: str, raw: bytes) -> None:
    fd, path = tempfile.mkstemp(prefix=f"{hook_key}-", suffix=".json", dir=evidence_dir)
    with os.fdopen(fd, "wb") as handle:
        handle.write(raw)
    os.chmod(path, stat.S_IRUSR | stat.S_IWUSR)


if __name__ == "__main__":
    raise SystemExit(main())
