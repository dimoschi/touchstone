"""Shared vocabulary of the change-risk signals (see risk_signals.py).

An entry is `{"value": true|false|<number>, "evidence": str}` or
`{"value": "unmeasured", "reason": str}`. `measured` and `unmeasured` build them,
and every string is cut to LIMIT characters.
"""

import os
import re
from posixpath import basename

LIMIT = 400

LANGUAGES = {'.go': 'go', '.py': 'python', '.php': 'php'}
NON_SOURCE = {'.md', '.rst', '.txt', '.adoc', '.json', '.yaml', '.yml', '.toml', '.lock',
              '.ini', '.cfg', '.csv', '.png', '.jpg', '.jpeg', '.gif', '.svg', '.ico',
              '.webp', '.bmp'}
HUNK = re.compile(r'^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@')
DIFF_FILE = re.compile(r'^diff --git .*$', re.MULTILINE)


def truncate(text, limit=LIMIT):
    return text if len(text) <= limit else text[:limit - 3] + '...'


def measured(value, evidence):
    return {'value': value, 'evidence': truncate(evidence)}


def unmeasured(reason):
    return {'value': 'unmeasured', 'reason': truncate(reason)}


def language_of(path):
    """'go', 'python', 'php', None for a non-source file, else 'other:<ext>'.

    A file with an extension this table does not know is not assumed harmless:
    no semantic tool supports it, so the signals that need one say unmeasured.
    """
    name = basename(path)
    ext = os.path.splitext(name)[1].lower()
    if ext in LANGUAGES:
        return LANGUAGES[ext]
    if ext in NON_SOURCE or name == 'LICENSE':
        return None
    return f'other:{ext or name}'


def language_name(lang):
    """'.js' for 'other:.js'; any other language as it is."""
    return lang[len('other:'):] if lang.startswith('other:') else lang


def by_language(paths):
    """language -> paths, leaving out files that have no language."""
    groups = {}
    for path in paths:
        lang = language_of(path)
        if lang is not None:
            groups.setdefault(lang, []).append(path)
    return groups


def _join(parts, key):
    """Each distinct text once, so ten files missing one tool say so once."""
    return '; '.join(dict.fromkeys(p[key] for p in parts))


def _with(parts, value):
    return [p for p in parts if p['value'] == value]


def _summary(value, hit):
    if value == 'unmeasured':
        return unmeasured(_join(hit, 'reason'))
    return measured(value, _join(hit, 'evidence'))


def _combine(parts, precedence, otherwise, empty_evidence):
    if not parts:
        return measured(False, empty_evidence)
    for value in precedence:
        hit = _with(parts, value)
        if hit:
            return _summary(value, hit)
    return measured(otherwise, _join(parts, 'evidence'))


def combine_any(parts, empty_evidence):
    """True if any part is true, else unmeasured if any is, else false."""
    return _combine(parts, (True, 'unmeasured'), False, empty_evidence)


def combine_all(parts, empty_evidence):
    """False if any part is false, else unmeasured if any is, else true."""
    return _combine(parts, (False, 'unmeasured'), True, empty_evidence)


def new_span(header):
    m = HUNK.match(header)
    if not m:
        return range(0)
    start = int(m.group(1))
    return range(start, start + int(m.group(2) or 1))


def chunk_hunks(chunk):
    """(new path or None, hunk header lines) of one file's part of a diff."""
    path, hunks = None, []
    for line in chunk.splitlines():
        if line.startswith('@@'):
            hunks.append(line)
        # Only the header names the file: after the first hunk, a line that
        # starts with '+++ ' is added content, not a header.
        elif not hunks and line.startswith('+++ b/'):
            path = line[6:]
    return path, hunks


def added_lines(diff):
    """path -> the new-side line numbers a `git diff -U0` adds or replaces."""
    found = {}
    for chunk in DIFF_FILE.split(diff)[1:]:
        path, hunks = chunk_hunks(chunk)
        if path:
            found.setdefault(path, set()).update(*(new_span(h) for h in hunks))
    return found
