#!/usr/bin/env python3
"""Turns a baseline and a current measurement into the gate's report rows.

The join, the new/worsened tag and the status were an awk program inside each of
crap-check-go.sh, crap-check-php.sh and crap-check-python.sh. Three copies meant
any change to the policy was a three-file edit, and the modules could disagree
about what a row meant while all reporting green.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import thresholds

EPS = 0.05

# Go carries the package so `package main` can be scored on complexity alone.
# The other modules have no equivalent and measure one column fewer.
#
# lib/parse_gocrap.py separates Go's columns with spaces, which its ids never
# contain; the other two use tabs because a PHP or Python id is a file path and
# can. Splitting Go on tabs alone yields one field and measures nothing.
LAYOUTS = {
    "go": {"width": 50, "packaged": True, "sep": None},
    "plain": {"width": 60, "packaged": False, "sep": "\t"},
}


def parse_rows(text, packaged, sep):
    """{function id: row} for one measurement file."""
    rows = {}
    for line in text.splitlines():
        fields = line.split(sep)
        if len(fields) < (5 if packaged else 4):
            continue
        rows[fields[0]] = {
            "id": fields[0],
            "pkg": fields[1] if packaged else "",
            "cc": fields[-3],
            "cov": fields[-2],
            "crap": fields[-1],
        }
    return rows


def score(row):
    """The number compared against a threshold, and across the diff."""
    if row["pkg"] == "main":
        return float(row["cc"])
    return 0.0 if row["crap"] == "n/a" else float(row["crap"])


def tag(row, base):
    """Whether this branch added the function, worsened it, or left it alone."""
    was = base.get(row["id"])
    if was is None:
        return "new"
    return "worsened" if score(row) > score(was) + EPS else "unchanged"


def format_row(row, status, tag_name, width):
    """One report row, in the format lib/next_action.py parses."""
    if row["pkg"] == "main":
        measured = "coverage=n/a    CRAP=n/a  "
    else:
        measured = f"coverage={row['cov']}%  CRAP={row['crap']}"
    return (f"{row['id']:<{width}} complexity={row['cc']:<2}  "
            f"{measured}  {status:<11}  ({tag_name})")


def classify(base_text, cur_text, layout, th):
    """One report row per measured function, current joined onto baseline."""
    packaged, sep = LAYOUTS[layout]["packaged"], LAYOUTS[layout]["sep"]
    base = parse_rows(base_text, packaged, sep)
    rows = []
    for row in parse_rows(cur_text, packaged, sep).values():
        tag_name = tag(row, base)
        is_main = row["pkg"] == "main"
        cov = None if is_main or row["cov"] == "n/a" else float(row["cov"])
        status = thresholds.classify(
            float(row["cc"]), score(row), cov, tag_name, is_main, th
        )
        rows.append(format_row(row, status, tag_name, LAYOUTS[layout]["width"]))
    return rows


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", required=True)
    parser.add_argument("--current", required=True)
    parser.add_argument("--layout", choices=sorted(LAYOUTS), required=True)
    parser.add_argument("--repo-root", required=True)
    args = parser.parse_args(argv)
    # An unreadable measurement raises rather than reporting no rows: every
    # caller treats an empty row set as "nothing to score, clean pass".
    base, current = Path(args.base).read_text(), Path(args.current).read_text()
    th = thresholds.load(args.repo_root)
    for row in classify(base, current, args.layout, th):
        print(row)
    return 0


if __name__ == "__main__":
    sys.exit(main())
