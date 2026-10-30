#!/usr/bin/env python3
"""Duplicates a staged change introduces, found with dryer's structural comparison.

Usage: dup_scan.py [--root DIR] --threshold T --changes FILE --pool FILE

--changes holds `git diff --cached -M --name-status` for the staged Go and Python
files, and --pool one repo-relative path per line for every tracked Go and Python
file to compare them against. Forms are read from the index (`:path`) and, for
what the change replaced, from HEAD (`HEAD:path` of each changed file, a rename's
old name and a deleted file included), through one `git cat-file --batch`, so the
working tree never matters.

dryer is imported, never run as a command: its CLI writes .metrics/dry.edn into
the project and cannot compare a blob. It is not importable outside the
environment lib/uv-pinned.sh builds, so this is run through that.

Prints one line per introduced pair, best score first:
  DUPLICATE score=0.91 a.py:3-12 b.py:5-14 key=<side>|<side>
A side is "<file>#<digest of the form's normalized structure>x<copies>", copies
being how many forms of that structure the file holds, so an acceptance of a
same-file pair covers those copies and not a further one. A pair is introduced
when either side occurs more often among the staged file's forms in the index
than at HEAD, its structure occurs more often across the whole change, and the
two files hold more pairs than the same comparison finds at HEAD: a new copy, a
third copy, or an edit that brings a pair up to the threshold. A duplicate that
was already at HEAD, in a file only edited elsewhere, moved to another file,
renamed with its file, or with one of its copies edited, is therefore not
reported.

Paths dryer's own walk would skip (tests, vendor/, testdata/, build/ and the
rest of its SKIP_DIRS) are dropped from both sides with dryer's own rules.
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
    from dryer.discover import SKIP_DIRS, is_test_file, language_of
    from dryer.extract import entries_in_source
    from dryer.shape import jaccard
    return SimpleNamespace(language_of=language_of, entries_in_source=entries_in_source,
                           jaccard=jaccard, skip_dirs=SKIP_DIRS, is_test_file=is_test_file)


def _scanned(path, dryer):
    """Whether dryer's own walk would read `path`: not a test, not under vendor/,
    testdata/, build/ or another directory it skips."""
    return not dryer.is_test_file(path) and not dryer.skip_dirs.intersection(path.split("/"))


def _kept(entry):
    return entry.end_line - entry.start_line + 1 >= MIN_LINES and entry.nodes >= MIN_NODES


def entries_of(blobs, name, path, dryer):
    """The comparable forms of `path` as git holds it under `name`."""
    language = dryer.language_of(path)
    data = blobs.read(name)
    if language not in LANGUAGES or data is None:
        return []
    found, _ = dryer.entries_in_source(language, data.decode(errors="replace"), path, path)
    return [entry for entry in found if _kept(entry)]


def _digest(entry):
    structure = "\n".join(sorted(entry.fingerprints))
    return hashlib.sha1(structure.encode()).hexdigest()[:12]


def _identity(entry):
    return entry.file, _digest(entry)


def side_key(entry, copies):
    return f"{entry.file}#{_digest(entry)}x{copies[_identity(entry)]}"


def _more_often(now, before):
    was = Counter(before)
    return {key for key, count in Counter(now).items() if count > was[key]}


def fresh_forms(now, before):
    """Identities that occur more often now than at HEAD, counting every copy.

    A structure that occurs no more often across the whole change was moved, to
    another file or under another name, and no copy of it was added.
    """
    added = _more_often(map(_digest, now), map(_digest, before))
    return {form for form in _more_often(map(_identity, now), map(_identity, before))
            if form[1] in added}


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


def _files(left, right):
    return tuple(sorted((left.file, right.file)))


def _between(found):
    return Counter(_files(left, right) for _, left, right in found)


def introduced(found, fresh, before):
    """The pairs in `found` with a fresh side, between two files that hold more
    pairs now than in `before`, the same comparison at HEAD.

    Editing one copy of a pair already at HEAD changes its structure but adds no
    pair, so it is not reported."""
    grown = _between(found) - _between(before)
    for score, left, right in found:
        if (_identity(left) in fresh or _identity(right) in fresh) and _files(left, right) in grown:
            first, second = sorted((left, right), key=_span)
            yield score, first, second


def line_for(score, first, second, copies):
    key = "|".join(sorted((side_key(first, copies), side_key(second, copies))))
    return (f"DUPLICATE score={score:.2f} {first.file}:{first.start_line}-{first.end_line} "
            f"{second.file}:{second.start_line}-{second.end_line} key={key}")


def _paths(listing):
    with open(listing) as handle:
        return [line.rstrip("\n") for line in handle if line.strip()]


def _changes(listing):
    """[(path at HEAD, path in the index, None when deleted)] from `git diff --name-status`."""
    changes = []
    for line in _paths(listing):
        status, *paths = line.split("\t")
        changes.append((paths[0], None if status.startswith("D") else paths[-1]))
    return changes


def _forms(blobs, prefix, paths, dryer):
    """{path: its forms, read from git under prefix + path}."""
    return {path: entries_of(blobs, f"{prefix}{path}", path, dryer) for path in paths}


def _replaced(blobs, changes, dryer):
    """The forms at HEAD of what the change replaced, labelled by where they went."""
    return [entry for old, new in changes
            for entry in entries_of(blobs, f"HEAD:{old}", new or old, dryer)]


def _flatten(forms, paths):
    return [entry for path in paths for entry in forms[path]]


def _best_first(found):
    score, first, second = found
    return (-score, _span(first), _span(second))


def _selected(args, dryer):
    """(changes, pool paths) less what dryer's own walk would skip."""
    changes = [change for change in _changes(args.changes)
               if _scanned(change[1] or change[0], dryer)]
    return changes, [path for path in _paths(args.pool) if _scanned(path, dryer)]


def scan(args, dryer):
    """The DUPLICATE line of every pair the staged files introduce, best score first."""
    changes, pool_paths = _selected(args, dryer)
    staged_paths = [new for _, new in changes if new]
    with Blobs(args.root) as blobs:
        index = _forms(blobs, ":", dict.fromkeys(pool_paths + staged_paths), dryer)
        before = _replaced(blobs, changes, dryer)
    staged, everything = _flatten(index, staged_paths), _flatten(index, index)
    unchanged = _flatten(index, index.keys() - set(staged_paths))
    fresh = fresh_forms(staged, before)
    found = introduced(list(pairs(staged, everything, args.threshold, dryer.jaccard)), fresh,
                       pairs(before, unchanged + before, args.threshold, dryer.jaccard))
    copies = Counter(map(_identity, everything))
    return [line_for(*pair, copies) for pair in sorted(found, key=_best_first)]


def _arguments(argv):
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default=".")
    parser.add_argument("--threshold", type=float, required=True)
    parser.add_argument("--changes", required=True)
    parser.add_argument("--pool", required=True)
    return parser.parse_args(argv)


def main(argv=None):
    args = _arguments(argv)
    for line in scan(args, _dryer()):
        print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main())
