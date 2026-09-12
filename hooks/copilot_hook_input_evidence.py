#!/usr/bin/env python3
"""Helpers for recording exact Copilot hook stdin bytes during smoke tests."""

from __future__ import annotations

import os
import stat
import tempfile
from pathlib import Path

EVIDENCE_ENV = "TOUCHSTONE_HOOK_INPUT_EVIDENCE_DIR"


def record_hook_input(hook_key: str, raw: bytes) -> None:
    """Write the raw hook payload to a locked-down evidence directory if enabled."""
    value = os.environ.get(EVIDENCE_ENV)
    if not value:
        return

    evidence_dir = Path(value)
    evidence_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(evidence_dir, stat.S_IRWXU)

    fd, path = tempfile.mkstemp(prefix=f"{hook_key}-", suffix=".json", dir=evidence_dir)
    with os.fdopen(fd, "wb") as handle:
        handle.write(raw)
    os.chmod(path, stat.S_IRUSR | stat.S_IWUSR)
