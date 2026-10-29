#!/usr/bin/env python3
"""Duplicates a staged change introduces, found with dryer's structural comparison.

Usage: dup_scan.py [--root DIR] --threshold T --staged FILE --pool FILE

--staged and --pool name files holding one repo-relative path per line: the
staged Go and Python files, and every tracked Go and Python file to compare them
against. Forms are read from the index (`:path`) and, for the staged files, from
HEAD, through one `git cat-file --batch`, so the working tree never matters.

dryer is imported, never run as a command: its CLI writes .metrics/dry.edn into
the project and cannot compare a blob. It is not importable outside the
environment lib/uv-pinned.sh builds, so this is run through that.

Prints one line per introduced pair, best score first:
  DUPLICATE score=0.91 a.py:3-12 b.py:5-14 key=<side>|<side>
A side is "<file>#<digest of the form's normalized structure>". A pair is
introduced when either side occurs more often among the staged file's forms in
the index than at HEAD: a new copy, a third copy, or a form whose structure
changed. A duplicate that was already at HEAD, in a file only edited elsewhere,
is therefore not reported.
"""

import argparse
import hashlib
import subprocess
import sys
from collections import Counter
from types import SimpleNamespace

LANGUAGES = {"go", "python"}
# dryer's own command-line defaults.
MIN_LINES = 4
MIN_NODES = 20


class Blobs:
    """`git cat-file --batch`: any number of object names, one process."""

    def __init__(self, root):
        self._git = subprocess.Popen(
            ["git", "-C", root, "cat-file", "--batch"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE)

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self._git.stdin.close()
        self._git.stdout.close()
        self._git.wait()

    def read(self, name):
        """The object's bytes, or None when git has no such object."""
        self._git.stdin.write(name.encode() + b"\n")
        self._git.stdin.flush()
        header = self._git.stdout.readline().split()
        if header[-1] == b"missing":
            return None
        return self._git.stdout.read(int(header[2]) + 1)[:-1]


def _dryer():
    from dryer.discover import language_of
    from dryer.extract import entries_in_source
    from dryer.shape import jaccard
    return SimpleNamespace(language_of=language_of, entries_in_source=entries_in_source,
                           jaccard=jaccard)


def _kept(entry):
    return entry.end_line - entry.start_line + 1 >= MIN_LINES and entry.nodes >= MIN_NODES


def entries_of(blobs, name, path, dryer):
    """The comparable forms of `path` as git holds it under `name`."""
    language = dryer.language_of(path)
    data = blobs.read(name)
    if language not in LANGUAGES or data is None:
        return []
    found, _ = dryer.entries_in_source(language, data.decode("utf-8", "replace"), path, path)
    return [entry for entry in found if _kept(entry)]


def side_key(entry):
    structure = "\n".join(sorted(entry.fingerprints))
    return f"{entry.file}#{hashlib.sha1(structure.encode()).hexdigest()[:12]}"


def new_keys(now, before):
    """Side keys that occur more often now than at HEAD, counting every copy."""
    was = Counter(map(side_key, before))
    return {key for key, count in Counter(map(side_key, now)).items() if count > was[key]}


def _span(entry):
    return (entry.file, entry.start_line, entry.end_line)


def pairs(staged, pool, threshold, jaccard):
    """{unordered pair of spans: (score, first, second)} at or above the threshold."""
    found = {}
    for left in staged:
        for right in pool:
            if left.language != right.language or _span(left) == _span(right):
                continue
            score = jaccard(left.fingerprints, right.fingerprints)
            if score >= threshold:
                found.setdefault(frozenset((_span(left), _span(right))), (score, left, right))
    return found.values()


def introduced(found, fresh):
    for score, left, right in found:
        if side_key(left) in fresh or side_key(right) in fresh:
            first, second = sorted((left, right), key=_span)
            yield score, first, second


def line_for(score, first, second):
    key = "|".join(sorted((side_key(first), side_key(second))))
    return (f"DUPLICATE score={score:.2f} {first.file}:{first.start_line}-{first.end_line} "
            f"{second.file}:{second.start_line}-{second.end_line} key={key}")


def _paths(listing):
    with open(listing) as handle:
        return [line.rstrip("\n") for line in handle if line.strip()]


def _forms(blobs, prefix, paths, dryer):
    """{path: its forms, read from git under prefix + path}."""
    return {path: entries_of(blobs, f"{prefix}{path}", path, dryer) for path in paths}


def _flatten(forms, paths):
    return [entry for path in paths for entry in forms[path]]


def _best_first(found):
    score, first, second = found
    return (-score, _span(first), _span(second))


def scan(args, dryer):
    """Every pair the staged files introduce, best score first."""
    staged_paths, pool_paths = _paths(args.staged), _paths(args.pool)
    with Blobs(args.root) as blobs:
        index = _forms(blobs, ":", dict.fromkeys(pool_paths + staged_paths), dryer)
        head = _forms(blobs, "HEAD:", staged_paths, dryer)
    staged = _flatten(index, staged_paths)
    fresh = new_keys(staged, _flatten(head, staged_paths))
    found = introduced(pairs(staged, _flatten(index, index), args.threshold, dryer.jaccard), fresh)
    return sorted(found, key=_best_first)


def _arguments(argv):
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default=".")
    parser.add_argument("--threshold", type=float, required=True)
    parser.add_argument("--staged", required=True)
    parser.add_argument("--pool", required=True)
    return parser.parse_args(argv)


def main(argv=None):
    args = _arguments(argv)
    for found in scan(args, _dryer()):
        print(line_for(*found))
    return 0


if __name__ == "__main__":
    sys.exit(main())
