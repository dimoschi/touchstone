#!/usr/bin/env python3
"""Record exact hook stdin for smoke assertions, then run the real hook."""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

from copilot_hook_input_evidence import record_hook_input


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
        record_hook_input(hook_key, raw)
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


if __name__ == "__main__":
    raise SystemExit(main())
