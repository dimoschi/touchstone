#!/usr/bin/env python3
"""Join crapper's Go function spans with a `go test -coverprofile` into CRAP rows.

Usage: parse_gocover.py <spans.tsv> <profile> <modpath> <moddir>
           [--root DIR --built FILE] [--unmeasured-out FILE] [--zero-fill-unmeasured]

  spans.tsv   lib/crapper_spans.py's rows for the changed files, repo-relative
  profile     the module's coverage profile; its paths start with <modpath>
  moddir      the module's directory in the repo, "." for the root module
  --built     files `go list` says the default build includes (absolute paths, one
              per line), judged against --root; a changed file it leaves out, a
              _windows.go on macOS or a `//go:build ignore`, is not scored unless
              the profile has blocks for it: the coverage command may build it
              with tags or a GOOS `go list` does not see
  --unmeasured-out
              where to write the changed files the profile has no block for
  --zero-fill-unmeasured
              score those at 0.0% instead of dropping them (the HEAD baseline)

Emits one space-separated row per function:
  <pkg>.<func> <pkg> <complexity> <coverage> <crap>

Coverage keeps the block rules of the tool this replaced, so that scores do not move: blocks
are counted once per (first line, last line) and count as run if any copy ran,
each goes to the function whose span holds its first line, and coverage is the
share of those blocks that ran, 0 for a function with none.

A changed file whose functions the profile has no block for was not measured: a
package nothing tested produces none, and so does a profile of other packages.
It is reported rather than read as 0%.
"""

import argparse
import os
import posixpath
import sys

import thresholds


def load_spans(path):
    """[(file, start, end, complexity, name, package)] from crapper_spans.py's rows."""
    spans = []
    with open(path) as handle:
        for line in handle:
            file, start, end, cc, name, package = line.rstrip("\n").split("\t")
            spans.append((file, int(start), int(end), int(cc), name, package))
    return spans


def _block(line):
    """(profile path, first line, last line, ran) for one profile line, or None."""
    fields = line.split()
    if len(fields) != 3 or ":" not in fields[0] or "," not in fields[0]:
        return None
    path, _, position = fields[0].rpartition(":")
    first, _, last = position.partition(",")
    try:
        return path, int(first.split(".")[0]), int(last.split(".")[0]), int(fields[2]) > 0
    except ValueError:
        return None


def _repo_path(profile_path, modpath, moddir):
    prefix = modpath + "/"
    if not profile_path.startswith(prefix):
        return None
    return posixpath.normpath(posixpath.join(moddir, profile_path[len(prefix):]))


def load_blocks(profile, modpath, moddir):
    """{repo file: {(first line, last line): ran}}, a block that ran in any copy having run."""
    files = {}
    with open(profile) as handle:
        for line in handle:
            block = _block(line)
            file = block and _repo_path(block[0], modpath, moddir)
            if file:
                seen = files.setdefault(file, {})
                key = (block[1], block[2])
                seen[key] = seen.get(key, False) or block[3]
    return files


def coverage(span, blocks):
    ran = [done for (first, _), done in blocks.items() if span[1] <= first <= span[2]]
    return 100.0 * sum(ran) / len(ran) if ran else 0.0


def built_files(listing, root):
    real = os.path.realpath
    with open(listing) as handle:
        built = {real(line.strip()) for line in handle if line.strip()}
    return lambda file: real(os.path.join(root, file)) in built


def unmeasured_files(spans, blocks):
    return sorted({span[0] for span in spans if span[0] not in blocks})


def row(span, cov):
    _, _, _, cc, name, package = span
    return f"{name} {package} {cc} {cov:.1f} {thresholds.crap(cc, cov):.1f}"


def _arguments(argv):
    parser = argparse.ArgumentParser()
    parser.add_argument("spans")
    parser.add_argument("profile")
    parser.add_argument("modpath")
    parser.add_argument("moddir")
    parser.add_argument("--root")
    parser.add_argument("--built")
    parser.add_argument("--unmeasured-out")
    parser.add_argument("--zero-fill-unmeasured", action="store_true")
    return parser.parse_args(argv)


def wanted_spans(args, blocks):
    spans = load_spans(args.spans)
    if not args.built:
        return spans
    built = built_files(args.built, args.root)
    return [span for span in spans if span[0] in blocks or built(span[0])]


def rows(spans, blocks, dropped):
    for span in spans:
        if span[0] not in dropped:
            yield row(span, coverage(span, blocks.get(span[0], {})))


def main(argv=None):
    args = _arguments(argv)
    blocks = load_blocks(args.profile, args.modpath, args.moddir)
    spans = wanted_spans(args, blocks)
    unmeasured = unmeasured_files(spans, blocks)
    if args.unmeasured_out:
        with open(args.unmeasured_out, "w") as handle:
            handle.writelines(f"{file}\n" for file in unmeasured)
    for line in rows(spans, blocks, set() if args.zero_fill_unmeasured else set(unmeasured)):
        print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main())
