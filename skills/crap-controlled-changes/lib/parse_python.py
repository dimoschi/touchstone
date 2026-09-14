#!/usr/bin/env python3
"""Join radon complexity with coverage.py per-function coverage into CRAP rows.

Reads:
  argv[1]                 - path to radon `cc -j` JSON
  argv[2]                 - path to `coverage json` output
  --unmeasured-out <path> - optional; write unmeasured repo-relative paths here
  env CRAP_CHANGED_FILES  - newline-separated repo-relative paths to filter on
  env CRAP_REPO_ROOT      - repo root, used to resolve file paths
  env CRAP_COV_ROOT       - directory `coverage json` ran in, default CRAP_REPO_ROOT

Emits to stdout, tab-separated, one function/method per line:
  <id>\t<complexity>\t<coverage_pct>\t<crap>

<id> is "<relpath>::<name>"; <name> is "<Class>.<method>" for methods. CRAP =
cc**2 * (1 - cov/100)**3 + cc.

A changed file with radon blocks that is absent from the coverage JSON (or
present with no per-line data at all) was never measured, not measured at
0%, and gets no row here; see `unmeasured_files`. A function whose own
`start_line` does not match radon's `lineno` for that block (a decorator, a
line-shift) still reads 0.0 -- that is a pre-existing join miss, not an
absence, and turning it into a refusal would flag every such mismatch.
"""

import argparse
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


def _resolve_cov_key(path, repo_root, cov_root):
    """A coverage.py `files` key, joined against cov_root first if relative."""
    if cov_root is not None and not os.path.isabs(path):
        path = os.path.join(cov_root, path)
    return normrel(path, repo_root)


def _function_lines(fdata):
    """{start_line: percent_covered} for one coverage.py file entry."""
    by_line = {}
    for fn in fdata.get("functions", {}).values():
        start = fn.get("start_line")
        pct = fn.get("summary", {}).get("percent_covered")
        if start is not None and pct is not None:
            by_line[int(start)] = float(pct)
    return by_line


def load_coverage(cov_path, repo_root, cov_root=None):
    """Return {relpath: {start_line: percent_covered}}.

    `coverage json` keys relative paths to the directory it ran in, which is
    `cov_root` for a project measured from a subdirectory, not necessarily
    `repo_root`. Absolute keys already carry their own location and skip the
    join.
    """
    try:
        with open(cov_path) as fh:
            data = json.load(fh)
    except (OSError, json.JSONDecodeError):
        return {}
    return {
        _resolve_cov_key(path, repo_root, cov_root): _function_lines(fdata)
        for path, fdata in data.get("files", {}).items()
    }


def unmeasured_files(changed, cov, blocks):
    """Sorted repo-relative changed paths that have a radon block but no
    coverage data at all.

    A file missing from `cov`, or present with an empty per-line map, was
    never measured (coverage.py's per-file `functions` map is built from
    parsing the source, so every function of a file it *did* measure shows
    up, 0% included). Requiring a radon block excludes a changed file with
    nothing to score (constants-only, `__init__.py`), which would otherwise
    be reported as a refusal over noise.
    """
    has_block = {rel for rel, _, _, _ in blocks}
    out = set()
    for rel in changed:
        if rel not in has_block:
            continue
        by_line = cov.get(rel)
        if not by_line:
            out.add(rel)
    return sorted(out)


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


def _write_unmeasured(path, unmeasured):
    if not path:
        return
    with open(path, "w") as fh:
        for rel in sorted(unmeasured):
            fh.write(rel + "\n")


def _emit_rows(blocks, changed, unmeasured, cov):
    for rel, name, cc, lineno in blocks:
        if rel not in changed or rel in unmeasured:
            continue
        pct = cov.get(rel, {}).get(lineno, 0.0)
        sys.stdout.write(f"{rel}::{name}\t{cc}\t{pct:.1f}\t{crap(cc, pct):.1f}\n")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("radon_json")
    ap.add_argument("cov_json")
    ap.add_argument("--unmeasured-out")
    args = ap.parse_args()

    repo_root = os.path.abspath(os.environ.get("CRAP_REPO_ROOT", os.getcwd()))
    cov_root = os.path.abspath(os.environ.get("CRAP_COV_ROOT", repo_root))
    changed = {
        os.path.normpath(p)
        for p in os.environ.get("CRAP_CHANGED_FILES", "").splitlines()
        if p.strip()
    }
    if not changed:
        return 0

    cov = load_coverage(args.cov_json, repo_root, cov_root)
    blocks = load_radon(args.radon_json, repo_root)
    unmeasured = set(unmeasured_files(changed, cov, blocks))

    _write_unmeasured(args.unmeasured_out, unmeasured)
    _emit_rows(blocks, changed, unmeasured, cov)
    return 0


if __name__ == "__main__":
    sys.exit(main())
