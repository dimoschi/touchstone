#!/usr/bin/env python3
"""Emit normalized per-function rows from a go-crap JSON report.

Usage: parse_gocrap.py <report.json> [basename...]

Row format consumed by crap-check-go.sh's join, matching what crap4go's text
report was parsed into:
  <pkg>.<func> <pkg> <cyclomatic> <coverage> <crap>

go-crap reports `file` package-relative (a bare basename for a flat package), so
restricting the report to the changed files means matching basenames within the
package that was scanned. With no basenames given, every entry is emitted.

Receivers arrive as `*Type.Method` for pointer receivers; the star is stripped so
a function's id does not change when its receiver does, which would otherwise
reset its refactor-attempt count in crap-check-state.json.
"""

import json
import sys


def main():
    keep = set(sys.argv[2:])
    with open(sys.argv[1]) as f:
        doc = json.load(f)
    for e in doc.get('entries') or []:
        if keep and e.get('file') not in keep:
            continue
        pkg = e.get('package') or '?'
        func = str(e.get('function', '?')).lstrip('*')
        print(f"{pkg}.{func} {pkg} {e.get('cyclomatic', 0)} "
              f"{float(e.get('coverage', 0)):.1f} {float(e.get('crap', 0)):.1f}")


if __name__ == '__main__':
    main()
