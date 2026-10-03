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
CONFIG = {'.json', '.yaml', '.yml', '.toml', '.lock', '.ini', '.cfg'}
NON_SOURCE = CONFIG | {'.md', '.rst', '.txt', '.adoc', '.csv', '.png', '.jpg', '.jpeg', '.gif',
                       '.svg', '.ico', '.webp', '.bmp'}
HUNK = re.compile(r'^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@')
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


def analysed_language_of(path):
    """`language_of`, except that a config file is not harmless to an analyser.

    difft reads config formats, so `language_of` leaves them without a language;
    gosec, bandit, opengrep, apidiff, griffe and deadcode read none of them, and a
    change to a deploy manifest or a CI workflow must read unmeasured, not clean.
    """
    ext = os.path.splitext(basename(path))[1].lower()
    return f'other:{ext}' if ext in CONFIG else language_of(path)


def by_language(paths):
    """language -> paths, leaving out files that have no language."""
    groups = {}
    for path in paths:
        lang = analysed_language_of(path)
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


def span(start, count):
    first = int(start)
    return range(first, first + int(count or 1))


def new_span(header):
    m = HUNK.match(header)
    return span(*m.group(3, 4)) if m else range(0)


def old_span(header):
    m = HUNK.match(header)
    return span(*m.group(1, 2)) if m else range(0)


def header_path(line):
    """The new-side path a '+++ ' header names, or None for /dev/null.

    Reads a diff made with core.quotePath on, where git quotes a name that holds
    a non-ASCII byte, a quote, a backslash or a control character (octal and
    one-letter escapes), and appends a tab to one that holds a space.
    """
    name = line[4:].rstrip('\t')
    if name.startswith('"'):
        name = name[1:-1].encode('ascii').decode('unicode_escape').encode('latin-1').decode(
            'utf-8', 'replace')
    return name[2:] if name.startswith('b/') else None


def chunk_hunks(chunk):
    """(new path or None, hunk header lines) of one file's part of a diff."""
    path, hunks = None, []
    for line in chunk.splitlines():
        if line.startswith('@@'):
            hunks.append(line)
        # Only the header names the file: after the first hunk, a line that
        # starts with '+++ ' is added content, not a header.
        elif not hunks and line.startswith('+++ '):
            path = header_path(line)
    return path, hunks


def hunk_lines(diff, span_of):
    found = {}
    for chunk in DIFF_FILE.split(diff)[1:]:
        path, hunks = chunk_hunks(chunk)
        if path:
            found.setdefault(path, set()).update(*(span_of(h) for h in hunks))
    return found


def added_lines(diff):
    """path -> the new-side line numbers a `git diff -U0` adds or replaces."""
    return hunk_lines(diff, new_span)


def gap_span(header):
    m = HUNK.match(header)
    return {int(m.group(3))} if m and m.group(4) == '0' and m.group(3) != '0' else set()


def gap_lines(diff):
    """path -> the new-side line after which a `git diff -U0` hunk only deletes."""
    return hunk_lines(diff, gap_span)


def removed_lines(diff):
    """path -> the old-side line numbers a `git diff -U0` deletes or replaces.

    Keyed by the new-side path, so a file the diff deletes has no entry."""
    return hunk_lines(diff, old_span)
