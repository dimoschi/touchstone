#!/usr/bin/env python3
"""Join radon complexity with coverage.py per-function coverage into CRAP rows.

Reads:
  argv[1]                 - path to radon `cc -j` JSON
  argv[2]                 - path to `coverage json` output
  env CRAP_CHANGED_FILES  - newline-separated repo-relative paths to filter on
  env CRAP_REPO_ROOT      - repo root, used to resolve file paths

Emits to stdout, tab-separated, one function/method per line:
  <id>\t<complexity>\t<coverage_pct>\t<crap>

<id> is "<relpath>::<name>"; <name> is "<Class>.<method>" for methods. Coverage
is coverage.py's per-function percent_covered (0.0 if the function was never
executed). CRAP = cc**2 * (1 - cov/100)**3 + cc.
"""

import json
import os
import sys


def normrel(path, repo_root):
    if os.path.isabs(path):
        try:
            return os.path.normpath(os.path.relpath(path, repo_root))
        except ValueError:
            return os.path.normpath(path)
    return os.path.normpath(path)


def load_coverage(cov_path, repo_root):
    """Return {relpath: {start_line: percent_covered}}."""
    try:
        with open(cov_path) as fh:
            data = json.load(fh)
    except (OSError, json.JSONDecodeError):
        return {}
    out = {}
    for path, fdata in data.get("files", {}).items():
        rel = normrel(path, repo_root)
        by_line = {}
        for fn in fdata.get("functions", {}).values():
            start = fn.get("start_line")
            pct = fn.get("summary", {}).get("percent_covered")
            if start is not None and pct is not None:
                by_line[int(start)] = float(pct)
        out[rel] = by_line
    return out


def load_radon(radon_path, repo_root):
    """Return list of (relpath, name, cc, lineno) for function/method blocks."""
    try:
        with open(radon_path) as fh:
            data = json.load(fh)
    except (OSError, json.JSONDecodeError):
        return []
    blocks = []
    for path, items in data.items():
        rel = normrel(path, repo_root)
        for b in items:
            if b.get("type") not in ("function", "method"):
                continue
            name = b["name"]
            cls = b.get("classname")
            if cls:
                name = f"{cls}.{name}"
            blocks.append((rel, name, int(b["complexity"]), int(b["lineno"])))
    return blocks


def crap(cc, cov):
    return cc ** 2 * (1 - cov / 100) ** 3 + cc


def main():
    radon_path = sys.argv[1]
    cov_path = sys.argv[2]
    repo_root = os.path.abspath(os.environ.get("CRAP_REPO_ROOT", os.getcwd()))
    changed = {
        os.path.normpath(p)
        for p in os.environ.get("CRAP_CHANGED_FILES", "").splitlines()
        if p.strip()
    }
    if not changed:
        return 0

    cov = load_coverage(cov_path, repo_root)
    for rel, name, cc, lineno in load_radon(radon_path, repo_root):
        if rel not in changed:
            continue
        pct = cov.get(rel, {}).get(lineno, 0.0)
        sys.stdout.write(f"{rel}::{name}\t{cc}\t{pct:.1f}\t{crap(cc, pct):.1f}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
