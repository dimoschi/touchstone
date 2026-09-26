"""Find a `check()` assertion in the workflow test suites that no counterfactual
production script makes fail.

A suite here is either a plain bash script (`check "label" "$got" "$want"`,
one `[` `]`-free string comparison) or a bash script that hands a block of JS
to `workflows/tests/harness.sh`'s `run_js_scenarios` (`check(label, got,
want)`, evaluated with `JSON.stringify`). Both print `ok:` or `FAIL:` lines in
the same shape, so a suite's real pass/fail signal for a given assertion is
read off its own stdout rather than re-implemented here.

This module owns parsing (finding every `check` call, its source span, and
the scenario or section it sits in) and classification (is a given call new
or changed between two revisions, and does it discriminate). Running suites
against a git tree and generating mutants is scripts/check-assertions-discriminate.sh's
job, via `run_suite` and `git_show`/`git_archive` below.
"""

from __future__ import annotations

import fnmatch
import os
import re
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass

# Suite files this check judges. A file move between the two (gh-118 split
# test-fix-loop-join.sh into workflows/tests/test-*.sh) needs no special
# case: select_candidates already drops a call whose text is unchanged,
# wherever it now lives.
SUITE_GLOBS = ('workflows/tests/test-*.sh', 'workflows/test-fix-loop-join.sh')

# Relative to the repo root, the one file every counterfactual swaps.
PIPELINE_SCRIPT = 'workflows/deliver-pipeline.js'


@dataclass(frozen=True)
class Report:
    file: str
    line: int
    scenario: str | None
    label: str
    reason: str


class NoRecordsError(Exception):
    """A suite with at least one candidate assertion printed no ok/FAIL line
    at all when run at head: a setup problem in that suite, not a verdict on
    any assertion in it."""

    def __init__(self, file: str):
        super().__init__(f'{file} printed no check records when run at head')
        self.file = file


@dataclass(frozen=True)
class Call:
    kind: str            # 'bash' or 'js'
    file: str             # suite-relative path, forward slashes
    start_line: int        # 1-based, inclusive
    end_line: int          # 1-based, inclusive
    scenario: str | None    # JS: enclosing `async function scenarioXxx`; bash: the last `== ...` echo header
    label_src: str
    label: str | None       # the label's runtime string value, or None if it is not a literal (or literal concatenation)
    got_src: str
    want_src: str
    text: str                 # the whole call's source, whitespace-collapsed, for identity matching across revisions
    dependent: bool           # can this call's outcome plausibly depend on deliver-pipeline.js at all?


def _collapse_ws(s: str) -> str:
    return re.sub(r'\s+', ' ', s).strip()


def _line_of(source: str, index: int) -> int:
    return source.count('\n', 0, index) + 1


def _advance_in_quote(text: str, i: int, top: str, stack: list[str]) -> int:
    """One character's worth of bookkeeping while `top` (the innermost open
    quote) is still open; returns the next index. Shared by `_scan_balanced`
    and `_split_top_level`'s bookkeeping, since both track the same quote
    stack the same way once a quote is open.

    Treats a backslash as escaping whatever follows it (skipped verbatim,
    even inside a quote a real shell/JS would not let you escape in -- close
    enough for the shapes these suites actually use).
    """
    c = text[i]
    if c == '\\':
        return i + 2
    if c == top:
        stack.pop()
    return i + 1


def _advance_balanced(source: str, i: int, open_ch: str, close_ch: str,
                       quote_chars: str, stack: list[str]) -> int:
    """One character's worth of `_scan_balanced`'s bookkeeping outside any
    open quote; returns the next index."""
    c = source[i]
    top = stack[-1]
    if top in quote_chars:
        return _advance_in_quote(source, i, top, stack)
    if c == '\\':
        return i + 2
    if c in quote_chars:
        stack.append(c)
    elif c == open_ch:
        stack.append(c)
    elif c == close_ch:
        stack.pop()
    return i + 1


def _scan_balanced(source: str, start: int, open_ch: str, close_ch: str,
                    quote_chars: str) -> int:
    """Index just past the `close_ch` matching the `open_ch` at `start`.

    Generic bracket/quote scanner shared by the bash and JS call readers:
    tracks a stack of open quotes and brackets via `_advance_balanced`.
    """
    assert source[start] == open_ch
    stack = [open_ch]
    i = start + 1
    n = len(source)
    while i < n and stack:
        i = _advance_balanced(source, i, open_ch, close_ch, quote_chars, stack)
    return i


def _is_matching_closer(c: str, closers: set[str], stack: list[str]) -> bool:
    return c in closers and bool(stack) and stack[-1] == c


def _top_quote(stack: list[str], quote_chars: str) -> str | None:
    """The innermost open quote, or None if the stack is empty or its top is a bracket."""
    if not stack:
        return None
    return stack[-1] if stack[-1] in quote_chars else None


def _advance_split(text: str, i: int, quote_chars: str, bracket_pairs: dict[str, str],
                    closers: set[str], stack: list[str]) -> int:
    """One character's worth of `_split_top_level`'s bookkeeping outside any
    open quote; returns the next index."""
    top = _top_quote(stack, quote_chars)
    if top is not None:
        return _advance_in_quote(text, i, top, stack)
    c = text[i]
    if c == '\\':
        return i + 2
    if c in quote_chars:
        stack.append(c)
    elif c in bracket_pairs:
        stack.append(bracket_pairs[c])
    elif _is_matching_closer(c, closers, stack):
        stack.pop()
    return i + 1


def _split_top_level(text: str, sep: str, quote_chars: str, bracket_pairs: dict[str, str]) -> list[str]:
    """Split `text` on a single-character `sep` that sits outside every quote and bracket.

    `sep` itself never collides with a quote or bracket character in any
    caller here, so checking it ahead of `_advance_split` (which only ever
    runs while the stack is empty, same condition) cannot skip a real
    quote-open or bracket-open on the same character.
    """
    parts = []
    stack: list[str] = []
    start = 0
    i = 0
    n = len(text)
    closers = set(bracket_pairs.values())
    while i < n:
        if not stack and text[i] == sep:
            parts.append(text[start:i])
            start = i + 1
            i += 1
            continue
        i = _advance_split(text, i, quote_chars, bracket_pairs, closers, stack)
    parts.append(text[start:])
    return parts


# ---------------------------------------------------------------------------
# Bash `check "label" "$got" "$want"` calls, outside any JS heredoc.
# ---------------------------------------------------------------------------

_BASH_CHECK_RE = re.compile(r'(?<![\w.])check[ \t]+', re.MULTILINE)
_BASH_QUOTES = "'\""


def _scan_single_quote(source: str, i: int) -> int:
    """`i` points at the opening `'`; the index just past its match.

    No escapes are recognized inside a single-quoted shell string, so this
    is a plain search for the next `'`, unlike every other quote handled
    here.
    """
    return source.index("'", i + 1) + 1


def _at_dollar_paren(source: str, i: int) -> bool:
    return source[i] == '$' and source[i + 1:i + 2] == '('


def _scan_double_quote(source: str, i: int) -> int:
    """`i` points at the opening `"`; the index just past its match.

    A `$(...)` inside is its own nested, quote-resetting region: bash lets
    an unescaped `"` reappear inside a command substitution even while the
    outer double quote is still open (`test-static.sh`'s own
    `"$(grep -c "required: ..." "$SCRIPT")"` relies on exactly this).
    """
    n = len(source)
    i += 1
    while i < n:
        c = source[i]
        if c == '\\':
            i += 2
        elif c == '"':
            return i + 1
        elif _at_dollar_paren(source, i):
            i = _scan_balanced(source, i + 1, '(', ')', _BASH_QUOTES)
        else:
            i += 1
    return i


def _skip_bash_whitespace(source: str, i: int) -> int:
    """Advances past top-level spaces/tabs and backslash-newline continuations.

    A backslash-newline is a line continuation bash removes outright, so at
    top level it is whitespace like any other, never part of a word.
    """
    n = len(source)
    while i < n:
        if source[i] in ' \t':
            i += 1
        elif source[i] == '\\' and source[i + 1:i + 2] == '\n':
            i += 2
        else:
            break
    return i


def _skip_one_bash_token(source: str, i: int) -> int:
    c = source[i]
    if c == '\\':
        return i + 2
    if c == "'":
        return _scan_single_quote(source, i)
    if c == '"':
        return _scan_double_quote(source, i)
    if _at_dollar_paren(source, i):
        return _scan_balanced(source, i + 1, '(', ')', _BASH_QUOTES)
    return i + 1


def _skip_bash_word(source: str, i: int) -> int:
    """Advances past one top-level shell word: a run of non-whitespace,
    honoring `'...'`, `"...with $(...) inside..."`, and a bare `$(...)`."""
    n = len(source)
    while i < n and source[i] not in ' \t\n':
        i = _skip_one_bash_token(source, i)
    return i


def _skip_to_newline(source: str, i: int) -> int:
    n = len(source)
    while i < n and source[i] != '\n':
        i += 1
    return i


def _read_bash_call(source: str, args_start: int) -> tuple[list[str], int]:
    """Reads up to 3 whitespace-separated shell words starting at `args_start`.

    The call itself ends at the first top-level, unescaped newline once 3
    words have been read (bash `check` never takes a 4th argument here);
    `_skip_to_newline` covers the case where the 3rd word is followed by
    nothing but that newline, so `text`/`end_line` still span the whole call.
    """
    words: list[str] = []
    i = args_start
    n = len(source)
    while len(words) < 3 and i < n:
        i = _skip_bash_whitespace(source, i)
        if i >= n or source[i] == '\n':
            break
        start = i
        i = _skip_bash_word(source, i)
        words.append(source[start:i])
    return words, _skip_to_newline(source, i)


def _is_quoted_with(word: str, q: str) -> bool:
    return len(word) >= 2 and word[0] == q and word[-1] == q


def _strip_shell_word(word: str) -> str:
    """The literal value of a single- or double-quoted shell word with no
    expansion inside (a plain label); returns the word unchanged otherwise."""
    if _is_quoted_with(word, "'"):
        return word[1:-1]
    if _is_quoted_with(word, '"') and '$' not in word:
        return re.sub(r'\\(.)', r'\1', word[1:-1])
    return word


def _bash_section(source: str, before: int) -> str | None:
    """The text of the nearest `echo "== ..."` line before `before`, if any."""
    header = None
    for m in re.finditer(r'^[ \t]*echo\s+"(==[^"]*)"', source[:before], re.MULTILINE):
        header = m.group(1)
    return header


def _parse_bash_calls(file: str, source: str) -> list[Call]:
    calls = []
    for m in _BASH_CHECK_RE.finditer(source):
        args_start = m.end()
        words, end = _read_bash_call(source, args_start)
        if len(words) != 3:
            continue
        label_src, got_src, want_src = words
        text = source[m.start():end]
        calls.append(Call(
            kind='bash', file=file,
            start_line=_line_of(source, m.start()), end_line=_line_of(source, end),
            scenario=_bash_section(source, m.start()),
            label_src=label_src, label=_strip_shell_word(label_src),
            got_src=got_src, want_src=want_src,
            text=_collapse_ws(text),
            dependent='$SCRIPT' in got_src or '$SCRIPT' in want_src,
        ))
    return calls


# ---------------------------------------------------------------------------
# JS `check(label, got, want)` calls inside a `run_js_scenarios <<'EOF'` heredoc.
# ---------------------------------------------------------------------------

_HEREDOC_START_RE = re.compile(r'run_js_scenarios[ \t]*<<[ \t]*[\'"]?(\w+)[\'"]?[ \t]*\n')
_JS_CHECK_RE = re.compile(r'(?<![\w.])check\(')
_JS_SCENARIO_RE = re.compile(r'^async function (scenario\w+)\s*\(', re.MULTILINE)
_JS_QUOTES = "'\"`"
_JS_BRACKETS = {'(': ')', '[': ']', '{': '}'}


def _heredoc_spans(source: str) -> list[tuple[int, int, int]]:
    """(body_start, body_end, first_line_of_body) for each run_js_scenarios heredoc."""
    spans = []
    for m in _HEREDOC_START_RE.finditer(source):
        delim = m.group(1)
        body_start = m.end()
        close_re = re.compile(r'^' + re.escape(delim) + r'\s*$', re.MULTILINE)
        close_m = close_re.search(source, body_start)
        body_end = close_m.start() if close_m else len(source)
        spans.append((body_start, body_end, _line_of(source, body_start)))
    return spans


def _js_scenario_at(body: str, before: int) -> str | None:
    name = None
    for m in _JS_SCENARIO_RE.finditer(body[:before]):
        name = m.group(1)
    return name


def _scenario_calls_run(body: str, scenario: str | None) -> bool:
    """Whether `scenario`'s own function body calls harness.sh's run() at all.

    A scenario that never does exercises nothing about deliver-pipeline.js,
    so none of its checks are candidates: swapping deliver-pipeline.js out
    for any counterfactual can only ever be a no-op for them.
    """
    if scenario is None:
        return False
    m = re.search(r'^async function ' + re.escape(scenario) + r'\s*\([^)]*\)\s*\{', body, re.MULTILINE)
    if not m:
        return False
    end = _scan_balanced(body, m.end() - 1, '{', '}', _JS_QUOTES)
    return 'await run(' in body[m.start():end]


_JS_ESCAPES = {'n': '\n', 't': '\t', "'": "'", '"': '"', '`': '`', '\\': '\\'}


def _is_bare_js_literal(lit: str) -> bool:
    return len(lit) >= 2 and lit[0] in _JS_QUOTES and lit[-1] == lit[0]


def _unescape_js_string(inner: str) -> str:
    out = []
    i = 0
    n = len(inner)
    while i < n:
        c = inner[i]
        if c == '\\' and i + 1 < n:
            out.append(_JS_ESCAPES.get(inner[i + 1], inner[i + 1]))
            i += 2
        else:
            out.append(c)
            i += 1
    return ''.join(out)


def _eval_js_string_literal(lit: str) -> str | None:
    lit = lit.strip()
    if not _is_bare_js_literal(lit):
        return None
    inner = lit[1:-1]
    if '${' in inner:
        return None  # template interpolation: not a literal we can evaluate
    return _unescape_js_string(inner)


def _eval_js_label(expr: str) -> str | None:
    """A label built from string literals and top-level `+` concatenation."""
    parts = _split_top_level(expr, '+', _JS_QUOTES, _JS_BRACKETS)
    values = [_eval_js_string_literal(p) for p in parts]
    if any(v is None for v in values):
        return None
    return ''.join(values)


def _parse_js_calls(file: str, source: str) -> list[Call]:
    calls = []
    for body_start, body_end, first_line in _heredoc_spans(source):
        body = source[body_start:body_end]
        for m in _JS_CHECK_RE.finditer(body):
            open_paren = m.end() - 1
            close = _scan_balanced(body, open_paren, '(', ')', _JS_QUOTES)
            args_src = body[open_paren + 1:close - 1]
            args = _split_top_level(args_src, ',', _JS_QUOTES, _JS_BRACKETS)
            if len(args) != 3:
                continue
            label_src, got_src, want_src = (a.strip() for a in args)
            scenario = _js_scenario_at(body, m.start())
            text = body[m.start():close]
            calls.append(Call(
                kind='js', file=file,
                start_line=first_line - 1 + _line_of(body, m.start()),
                end_line=first_line - 1 + _line_of(body, close),
                scenario=scenario,
                label_src=label_src, label=_eval_js_label(label_src),
                got_src=got_src, want_src=want_src,
                text=_collapse_ws(text),
                dependent=_scenario_calls_run(body, scenario),
            ))
    return calls


def select_candidates(head_calls: list[Call], base_texts: set[str]) -> list[Call]:
    """New-or-changed, deliver-pipeline.js-dependent calls: this ticket's scope.

    "New or changed" is decided by whether `call.text` (already
    whitespace-collapsed) appears anywhere in `base_texts`, gathered from
    every suite file at the base revision regardless of which file it came
    from -- so a call moved verbatim to a new file (gh-118 split its 4651-line
    suite into workflows/tests/*.sh) still matches and is excluded, rather
    than being reported as new because the file it now lives in did not
    exist at base.
    """
    return [c for c in head_calls if c.dependent and c.text not in base_texts]


# ---------------------------------------------------------------------------
# Reading a suite run's own stdout back into a verdict per call.
# ---------------------------------------------------------------------------

_STATUS_LINE_RE = re.compile(r'^\s*(ok|FAIL):\s+(.*)$')


def extract_statuses(stdout: str) -> list[tuple[str, str]]:
    """Every `ok:`/`FAIL:` line in `stdout`, in the order printed."""
    out = []
    for line in stdout.splitlines():
        m = _STATUS_LINE_RE.match(line)
        if m:
            out.append((m.group(1), m.group(2)))
    return out


def match_call_status(calls: list[Call], stdout: str) -> dict[Call, str | None]:
    """`calls` (one scenario's or one bash section's, in source order) mapped
    to the status ('ok'/'FAIL') its line printed in `stdout`, or None if
    execution never reached it.

    Matching is positional: the n-th status line is assumed to be the n-th
    call in source order, since every scenario examined here is a
    straight-line function with no branch around a `check` call itself --
    what a run actually executes is always a prefix of the full list, cut
    short only by an early throw or return. Once a label does not match at a
    position, matching stops rather than guessing a realignment.
    """
    statuses = extract_statuses(stdout)
    result: dict[Call, str | None] = {}
    for call, (status, rest) in zip(calls, statuses):
        if call.label is not None and not rest.startswith(call.label + ' ('):
            break
        result[call] = status
    for call in calls[len(result):]:
        result[call] = None
    return result


# ---------------------------------------------------------------------------
# Bounding a mutant search to what base..head actually added to a file.
# ---------------------------------------------------------------------------

_HUNK_RE = re.compile(r'^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@')


def _is_diff_header_noise(line: str) -> bool:
    return line.startswith('+++') or line.startswith('---')


def _added_line_delta(line: str) -> tuple[bool, int]:
    """(is `line` itself an addition, how many head lines it accounts for:
    0 for a removal, 1 otherwise)."""
    if line.startswith('-'):
        return False, 0
    return line.startswith('+'), 1


def added_lines(diff_text: str) -> list[int]:
    """Head line numbers of every pure-addition line in a `git diff -U0` hunk."""
    lines = []
    cur = None
    for line in diff_text.splitlines():
        m = _HUNK_RE.match(line)
        if m:
            cur = int(m.group(1))
            continue
        if cur is None or _is_diff_header_noise(line):
            continue
        is_add, delta = _added_line_delta(line)
        if is_add:
            lines.append(cur)
        cur += delta
    return lines


def line_delete_mutant(content: str, line_no: int) -> str:
    """`content` with its 1-based `line_no` removed outright (a statement-deletion mutant)."""
    lines = content.splitlines(keepends=True)
    idx = line_no - 1
    return ''.join(lines[:idx] + lines[idx + 1:])


_STRING_LIT_RE = re.compile(r"""('([^'\\]|\\.)*'|"([^"\\]|\\.)*")""")


def line_blank_string_mutants(content: str, line_no: int) -> list[str]:
    """One mutant per non-empty string literal on `line_no`, that literal blanked.

    Targets a presence/absence check directly: deleting the whole line (see
    `line_delete_mutant`) can change unrelated control flow, where blanking
    just the literal a `.includes(...)` check is looking for isolates the one
    thing such a check claims to test.
    """
    lines = content.splitlines(keepends=True)
    idx = line_no - 1
    line = lines[idx]
    mutants = []
    for m in _STRING_LIT_RE.finditer(line):
        q = m.group(0)[0]
        if m.group(0) == q + q:
            continue
        new_line = line[:m.start()] + q + q + line[m.end():]
        mutants.append(''.join(lines[:idx] + [new_line] + lines[idx + 1:]))
    return mutants


# ---------------------------------------------------------------------------
# Git and process plumbing. Every tree this check runs against is a
# `git archive` extraction, never the repo's own worktree or .git: the
# fence this feeds requires a read-only, deterministic check.
# ---------------------------------------------------------------------------

def git_show(repo: str, rev: str, path: str) -> str | None:
    """`path`'s content at `rev`, or None if it does not exist there."""
    proc = subprocess.run(['git', '-C', repo, 'show', f'{rev}:{path}'],
                           capture_output=True, text=True)
    return proc.stdout if proc.returncode == 0 else None


def list_suite_files(repo: str, rev: str, patterns: tuple[str, ...] = SUITE_GLOBS) -> list[str]:
    """Suite-relative paths at `rev` matching any of `patterns`."""
    proc = subprocess.run(['git', '-C', repo, 'ls-tree', '-r', '--name-only', rev],
                           capture_output=True, text=True, check=True)
    return [p for p in proc.stdout.splitlines() if any(fnmatch.fnmatch(p, pat) for pat in patterns)]


def archive_tree(repo: str, rev: str, dest: str) -> None:
    """Extracts the full tree at `rev` into `dest`, which must not yet exist."""
    os.makedirs(dest)
    git_proc = subprocess.Popen(['git', '-C', repo, 'archive', rev], stdout=subprocess.PIPE)
    tar_proc = subprocess.run(['tar', '-x', '-C', dest], stdin=git_proc.stdout,
                               capture_output=True, text=True)
    git_proc.stdout.close()
    git_rc = git_proc.wait()
    if git_rc != 0 or tar_proc.returncode != 0:
        raise RuntimeError(f'archiving {rev} from {repo} failed (git={git_rc}, tar={tar_proc.returncode}): {tar_proc.stderr}')


def run_suite(suite_path: str, scenario: str | None) -> tuple[str, int]:
    """Runs one suite file as its own process, optionally scoped to one JS scenario."""
    env = dict(os.environ)
    if scenario is not None:
        env['TOUCHSTONE_SCENARIOS'] = scenario
    proc = subprocess.run(['bash', suite_path], capture_output=True, text=True, env=env)
    return proc.stdout + proc.stderr, proc.returncode


def diff_added_lines(repo: str, base: str, head: str, path: str) -> list[int]:
    proc = subprocess.run(['git', '-C', repo, 'diff', '-U0', base, head, '--', path],
                           capture_output=True, text=True)
    return added_lines(proc.stdout)


# ---------------------------------------------------------------------------
# Orchestration: which of `select_candidates`' calls does no counterfactual
# make fail.
# ---------------------------------------------------------------------------

def _group_by_scenario_per_file(calls: list[Call]) -> dict[str, dict[str | None, list[Call]]]:
    by_file: dict[str, dict[str | None, list[Call]]] = {}
    for c in calls:
        by_file.setdefault(c.file, {}).setdefault(c.scenario, []).append(c)
    return by_file


def _run_groups(tree: str, head_calls_by_file: dict[str, list[Call]],
                 calls: list[Call]) -> list[tuple[str, list[Call], dict[Call, str | None], bool]]:
    """Runs `calls`, one process per (file, scenario) group, sharing that
    plumbing between `_passing_at_head` and `_survivors_of_counterfactual`:
    both need the same groups run and matched against `tree`, only the
    verdict they read off the result differs."""
    results = []
    for f, groups in _group_by_scenario_per_file(calls).items():
        for scenario, group in groups.items():
            all_in_group = [c for c in head_calls_by_file[f] if c.scenario == scenario]
            stdout, _ = run_suite(os.path.join(tree, f), scenario)
            statuses = match_call_status(all_in_group, stdout)
            results.append((f, group, statuses, bool(extract_statuses(stdout))))
    return results


def _require_records(saw_record: dict[str, bool]) -> None:
    for f, had_records in saw_record.items():
        if not had_records:
            raise NoRecordsError(f)


def _passing_at_head(tree: str, head_calls_by_file: dict[str, list[Call]],
                      candidates: list[Call]) -> list[Call]:
    """Of `candidates`, the ones that actually pass when `tree` is run as-is.

    A candidate already failing (or unreached) at head is a different,
    pre-existing problem; this check only judges whether a passing assertion
    could ever have failed. Raises `NoRecordsError` for any file with a
    candidate whose run printed no record at all: a setup problem in that
    file, not a verdict on the candidate.
    """
    passing = []
    saw_record: dict[str, bool] = {}
    for f, group, statuses, this_run_had_records in _run_groups(tree, head_calls_by_file, candidates):
        saw_record[f] = saw_record.get(f, False) or this_run_had_records
        passing.extend(c for c in group if statuses.get(c) == 'ok')
    _require_records(saw_record)
    return passing


def _survivors_of_counterfactual(tree: str, head_calls_by_file: dict[str, list[Call]],
                                  pending: list[Call]) -> list[Call]:
    """Of `pending`, the calls this one counterfactual tree did NOT fail."""
    return [c for _, group, statuses, _ in _run_groups(tree, head_calls_by_file, pending)
            for c in group if statuses.get(c) != 'FAIL']


def _mutant_contents(head_script: str, repo: str, base: str, head: str) -> list[str]:
    """Every mutant of `head_script`, one per string literal or whole line
    that base..head added to it -- the only lines a new assertion's own
    production support could plausibly sit on."""
    contents = []
    for line_no in diff_added_lines(repo, base, head, PIPELINE_SCRIPT):
        contents.append(line_delete_mutant(head_script, line_no))
        contents.extend(line_blank_string_mutants(head_script, line_no))
    return contents


def _parse_calls_at(repo: str, rev: str, file: str) -> list[Call]:
    return parse_suite_source(file, git_show(repo, rev, file) or '')


def _collect_candidates(repo: str, base: str, head: str) -> tuple[dict[str, list[Call]], list[Call]]:
    base_texts = {c.text for f in list_suite_files(repo, base) for c in _parse_calls_at(repo, base, f)}
    head_calls_by_file = {f: _parse_calls_at(repo, head, f) for f in list_suite_files(repo, head)}
    candidates = [c for calls in head_calls_by_file.values() for c in select_candidates(calls, base_texts)]
    return head_calls_by_file, candidates


def _try_counterfactual(tmp: str, name: str, head_tree: str, script_content: str,
                         head_calls_by_file: dict[str, list[Call]], pending: list[Call]) -> list[Call]:
    """Copies `head_tree`, swaps in `script_content`, and returns whichever of
    `pending` survive a run against it (see `_survivors_of_counterfactual`)."""
    tree = os.path.join(tmp, name)
    shutil.copytree(head_tree, tree)
    with open(os.path.join(tree, PIPELINE_SCRIPT), 'w') as fh:
        fh.write(script_content)
    survivors = _survivors_of_counterfactual(tree, head_calls_by_file, pending)
    shutil.rmtree(tree)
    return survivors


def _run_mutant_sweep(repo: str, base: str, head: str, tmp: str, head_tree: str,
                       head_calls_by_file: dict[str, list[Call]], pending: list[Call]) -> list[Call]:
    head_script = git_show(repo, head, PIPELINE_SCRIPT) or ''
    for i, mutated in enumerate(_mutant_contents(head_script, repo, base, head)):
        if not pending:
            break
        pending = _try_counterfactual(tmp, f'mutant-{i}', head_tree, mutated, head_calls_by_file, pending)
    return pending


def _run_counterfactuals(repo: str, base: str, head: str, tmp: str, head_tree: str,
                          head_calls_by_file: dict[str, list[Call]], pending: list[Call]) -> list[Call]:
    base_script = git_show(repo, base, PIPELINE_SCRIPT)
    if pending and base_script is not None:
        pending = _try_counterfactual(tmp, 'revert', head_tree, base_script, head_calls_by_file, pending)
    if pending:
        pending = _run_mutant_sweep(repo, base, head, tmp, head_tree, head_calls_by_file, pending)
    return pending


def find_reports(repo: str, base: str, head: str) -> list[Report]:
    head_calls_by_file, candidates = _collect_candidates(repo, base, head)
    if not candidates:
        return []

    with tempfile.TemporaryDirectory(prefix='touchstone-assertion-discrimination-') as tmp:
        head_tree = os.path.join(tmp, 'head')
        archive_tree(repo, head, head_tree)
        pending = _passing_at_head(head_tree, head_calls_by_file, candidates)
        pending = _run_counterfactuals(repo, base, head, tmp, head_tree, head_calls_by_file, pending)

    return sorted(
        (Report(file=c.file, line=c.start_line, scenario=c.scenario,
                label=c.label if c.label is not None else c.label_src,
                reason='no counterfactual production script makes this assertion fail')
         for c in pending),
        key=lambda r: (r.file, r.line),
    )


def parse_suite_source(file: str, source: str) -> list[Call]:
    """Every `check` call in one suite file's source, bash and JS alike."""
    heredocs = _heredoc_spans(source)
    bash_source = source
    for body_start, body_end, _ in heredocs:
        # Blank out heredoc bodies (preserving line count) so the bash-call
        # regex never fires on a `check(` inside one.
        bash_source = bash_source[:body_start] + \
            re.sub(r'[^\n]', ' ', bash_source[body_start:body_end]) + \
            bash_source[body_end:]
    calls = _parse_bash_calls(file, bash_source) + _parse_js_calls(file, source)
    calls.sort(key=lambda c: c.start_line)
    return calls


def _print_report(r: Report) -> None:
    scenario = f'[{r.scenario}] ' if r.scenario else ''
    print(f'{r.file}:{r.line}: {scenario}"{r.label}": {r.reason}')


def _parse_args(argv: list[str]) -> tuple[str, str, str] | str:
    """`(repo, base, head)`, or an error message to print to stderr."""
    if len(argv) != 3:
        return 'usage: assertion_discrimination.py <repo> <base-sha> <head-sha>'
    repo = argv[0]
    if not os.path.isdir(repo):
        return f'assertion-discrimination: no such directory: {repo}'
    return repo, argv[1], argv[2]


def _gather_reports(repo: str, base: str, head: str) -> tuple[list[Report] | None, int]:
    """`(reports, 0)`, or `(None, exit-code)` after printing why."""
    try:
        return find_reports(repo, base, head), 0
    except NoRecordsError as e:
        print(f'assertion-discrimination: {e}', file=sys.stderr)
        return None, 4
    except RuntimeError as e:
        print(f'assertion-discrimination: {e}', file=sys.stderr)
        return None, 2


def main(argv: list[str] | None = None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    parsed = _parse_args(argv)
    if isinstance(parsed, str):
        print(parsed, file=sys.stderr)
        return 2
    reports, error_code = _gather_reports(*parsed)
    if reports is None:
        return error_code
    for r in reports:
        _print_report(r)
    if reports:
        return 1
    print('assertion-discrimination: no non-discriminating new assertion found')
    return 0


if __name__ == '__main__':
    sys.exit(main())
