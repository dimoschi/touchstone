#!/usr/bin/env python3
"""Copy an infection config with a JSON report logger injected.

Usage: infection_config.py <src-config> <dest-config> <absolute-report-path>

infection 0.34 has no `--logger-json` CLI flag (only logger-html, logger-text,
logger-summary-json, logger-github, logger-gitlab), and the per-mutant report the
gate parses is reachable only through the `logs.json` **config** key. So the run
needs a config, and the repo's own settings (source directories, excludes,
bootstrap, mutators, phpUnit paths) have to survive the injection or the run
measures something different from what the repo means to test.

The caller must place <dest-config> in the same directory as <src-config>:
ConfigurationFactory resolves every relative path against dirname(config), so a
copy written to /tmp would silently look for source directories in /tmp. The
report path is required to be absolute for the same reason.

A config that is not valid JSON is refused rather than guessed at. infection also
accepts JSON5 (comments, trailing commas), which no stdlib parser reads, and a
half-parsed config would drop settings without saying so.
"""

import json
import os
import sys


def main():
    src, dest, report = sys.argv[1], sys.argv[2], sys.argv[3]

    if not os.path.isabs(report):
        print(f"infection_config: report path must be absolute, got {report!r}",
              file=sys.stderr)
        return 2

    try:
        with open(src) as f:
            config = json.load(f)
    except ValueError as exc:
        print(f"infection_config: cannot parse {src} as JSON ({exc}).", file=sys.stderr)
        print("  A JSON5 config (comments, trailing commas) cannot be read here, and",
              file=sys.stderr)
        print("  the gate has to inject logs.json to get a per-mutant report.",
              file=sys.stderr)
        print("  Provide an infection.json the gate can extend.", file=sys.stderr)
        return 2

    config.setdefault('logs', {})['json'] = report
    with open(dest, 'w') as f:
        json.dump(config, f, indent=2)
    return 0


if __name__ == '__main__':
    sys.exit(main())
