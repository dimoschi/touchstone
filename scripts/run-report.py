#!/usr/bin/env python3
"""Summarise this repo's delivery run records per pipeline version.

    scripts/run-report.py [<repo>]

<repo> defaults to the current directory; the records are read from
<repo>/.claude/touchstone-runs/. See scripts/lib/run_report.py.
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / 'lib'))

from run_report import main  # noqa: E402

sys.exit(main(sys.argv[1:]))
