#!/usr/bin/env python3
"""Emit normalized survivor rows from mutago's agentic JSON report.

Usage: parse_mutago.py <mutago-agentic.json> [path-prefix] [allowed-file...]

Row format shared by all mutation-check modules:
  <file>:<line>  <mutator>  SURVIVED  id=<id>
with indented description and kill-hint lines under each row.

mutago resolves a file target to its enclosing package and mutates every file
in it, so the report routinely names files the caller excluded on purpose
(generated mocks, sqlc output). Passing the caller's file list restricts the
report to it; omitting it reports everything.

Mutants inside `func main()` are dropped and listed on stderr instead of
blocking. The entry point wires up live dependencies and is reachable only by
re-execing the binary, so a survivor there measures the absence of an
integration harness, not a gap in the unit suite. This mirrors the
complexity-only rule crap-check-go.sh applies to package main.

Two deliberate boundaries, both scoped to whatever this module is handed:
mutation-check.sh excludes a command's entry file (cmd/<x>/main.go) from
GO_FILES upstream, so nothing in it reaches here to be exempted or listed.
  - Only `func main()` itself, in a file that does reach this module. Helpers
    in a main package are ordinary testable code and keep blocking, whether
    they sit above or below main.
  - Closures inside main's body (`defer func(){...}()` and friends) are inside
    the span, so they are exempt too. They are entry-point wiring by the same
    argument, but this is the one place the gate stops looking, and a defer in
    main is where a rollback bug hid here before. Do not read the complexity
    <= 5 rule in crap-check-go.sh as a backstop for that: next_action.py demotes
    every row tagged `unchanged` to a note, and a main package's tag turns on
    complexity alone, so an existing main keeps whatever complexity it already
    had and only an increase blocks. It is a ratchet, not a cap.
"""

import json
import os
import subprocess
import sys

HELPER = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'mainrange.go')


def main_func_spans(paths):
    """Map path -> (start, end) line span of `func main()`, via go/ast.

    Exactness is the point: the span is a hole in the gate, and the brace-matching
    approximation this replaced swallowed a whole helper following a single-line
    `func main() { ... }`. Any failure yields no spans, so every mutant blocks.
    """
    if not paths:
        return {}
    try:
        out = subprocess.run(
            ['go', 'run', HELPER],
            input='\n'.join(paths),
            capture_output=True, text=True, check=True,
        ).stdout
    except (OSError, subprocess.CalledProcessError) as exc:
        print(f"parse_mutago: cannot locate func main ({exc}); exempting nothing",
              file=sys.stderr)
        return {}
    spans = {}
    for row in out.splitlines():
        parts = row.split('\t')
        if len(parts) == 3:
            spans[parts[0]] = (int(parts[1]), int(parts[2]))
    return spans


def total_mutants_count(summary_path):
    """mutago-summary.json's totalMutantsCount.

    Not the agentic report: the agentic report lists escaped mutants only, so
    it cannot say whether zero escaped means everything was killed or nothing
    was generated.
    """
    with open(summary_path) as f:
        summary = json.load(f)
    return summary.get('totalMutantsCount', 0)


def collect_rows(doc, prefix, allowed):
    rows = []
    for m in doc.get('mutants') or []:
        # Targets go to mutago as ./path and come back that way; strip it so a
        # submodule prefix does not compose to "mod/./file.go".
        f_name = str(m.get('file', '?')).removeprefix('./')
        if allowed and f_name not in allowed:
            continue
        try:
            line = int(m.get('line'))
        except (TypeError, ValueError):
            line = None
        rows.append((f"{prefix}{f_name}", line, m))
    return rows


def print_survivor(disk_path, m):
    loc = f"{disk_path}:{m.get('line', '?')}"
    print(f"{loc:<42} {m.get('mutator', '?'):<26} SURVIVED  id={m.get('id', '')}")
    if m.get('description'):
        print(f"    {m['description']}")
    if m.get('kill_hint'):
        print(f"    kill hint: {m['kill_hint']}")


def in_span(span, line):
    return span is not None and line is not None and span[0] <= line <= span[1]


def print_exempt(exempt):
    # stderr so the row capture in mutation-check-go.sh stays clean. Never
    # silent: an exemption the user cannot see is a gate that shrank without
    # telling anyone.
    print(f"mutation-check[go]: {len(exempt)} mutant(s) exempted, inside func main():",
          file=sys.stderr)
    for row in exempt:
        print(f"    {row}", file=sys.stderr)


def report_survivors(path, prefix, allowed):
    with open(path) as f:
        doc = json.load(f)

    rows = collect_rows(doc, prefix, allowed)
    spans = main_func_spans(sorted({r[0] for r in rows}))

    exempt = []
    for disk_path, line, m in rows:
        if in_span(spans.get(disk_path), line):
            loc = f"{disk_path}:{m.get('line', '?')}"
            exempt.append(f"{loc:<42} {m.get('mutator', '?')}")
            continue
        print_survivor(disk_path, m)

    if exempt:
        print_exempt(exempt)


def main():
    if len(sys.argv) > 2 and sys.argv[1] == '--total':
        print(total_mutants_count(sys.argv[2]))
        return
    path = sys.argv[1]
    prefix = sys.argv[2] if len(sys.argv) > 2 else ''
    allowed = {a.removeprefix('./') for a in sys.argv[3:]}
    report_survivors(path, prefix, allowed)


if __name__ == '__main__':
    main()
