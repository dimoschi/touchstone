"""Report a new `check()` assertion in the workflow test suites that no
counterfactual production script makes fail.

Works from what the suites print, never from their source. Every suite prints
a `== ...` header before each scenario or section and one `ok:`/`FAIL:` line
per assertion, carrying its label; that is the record, for today's suites and
for historical revisions alike. An assertion is identified by its header, its
label and its occurrence under that header, not by file, so a scenario moved
between suite files is not new.

An assertion is a candidate when it passes at head and has no record in the
base revision's run of the same suites. It discriminates when some
counterfactual run fails it: the base revision's deliver-pipeline.js swapped
into head, or a mutant blanking one string literal on a line the range added
to it. A candidate missing from a counterfactual run (its scenario threw
first) is not evidence either way. Two known limits: an assertion whose got
or want changed while its header and label did not is not a candidate, and a
range that leaves deliver-pipeline.js untouched has no counterfactual, so
nothing in it is judged.

scripts/check-assertions-discriminate.sh resolves the range and calls main().
"""

from __future__ import annotations

import fnmatch
import os
import re
import shutil
import subprocess
import sys
import tempfile
from collections import Counter
from dataclasses import dataclass

SUITE_GLOBS = ('workflows/tests/test-*.sh', 'workflows/test-fix-loop-join.sh')

PIPELINE_SCRIPT = 'workflows/deliver-pipeline.js'


@dataclass(frozen=True)
class Record:
    file: str
    header: str | None
    label: str
    n: int
    passed: bool

    @property
    def key(self) -> tuple[str | None, str, int]:
        return (self.header, self.label, self.n)


@dataclass(frozen=True)
class Report:
    file: str
    header: str | None
    label: str
    reason: str


class NoRecordsError(Exception):
    """A suite the range changed printed no ok/FAIL line at all when run at
    head: a setup problem in that suite, not a verdict on any assertion."""

    def __init__(self, file: str):
        super().__init__(f'{file} printed no check records when run at head')
        self.file = file


_STATUS_LINE_RE = re.compile(r'^\s*(ok|FAIL):\s+(.*)$')

_HEADER_RE = re.compile(r'^\s*(==\s.*?)\s*$')


def _label_of(rest: str) -> str:
    """The label part of an ok/FAIL line: everything before its first ` (`.

    An `ok:` line appends ` (<value>)` and a `FAIL:` line ` (got ..., want ...)`,
    and a label can itself carry parentheses, so cutting at the first one is
    the only cut both lines of the same assertion agree on.
    """
    return rest.partition(' (')[0].strip()


def records_of(file: str, stdout: str) -> list[Record]:
    """Every assertion `stdout` records, in the order printed."""
    records = []
    header = None
    seen: Counter = Counter()
    for line in stdout.splitlines():
        h = _HEADER_RE.match(line)
        if h:
            header = h.group(1)
            continue
        m = _STATUS_LINE_RE.match(line)
        if not m:
            continue
        label = _label_of(m.group(2))
        seen[(header, label)] += 1
        records.append(Record(file, header, label, seen[(header, label)], m.group(1) == 'ok'))
    return records


def candidates_of(base: list[Record], head: list[Record]) -> list[Record]:
    """Head records that pass and whose identity the base run never printed."""
    base_keys = {r.key for r in base}
    return [r for r in head if r.passed and r.key not in base_keys]


def surviving(pending: list[Record], run: list[Record]) -> list[Record]:
    """`pending` minus every candidate `run` recorded as failing."""
    failed = {r.key for r in run if not r.passed}
    return [c for c in pending if c.key not in failed]


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


_STRING_LIT_RE = re.compile(r"""('([^'\\]|\\.)*'|"([^"\\]|\\.)*")""")


_COMPARISON_OPERAND_RE = re.compile(r'[=!]==?\s*$')


def _is_comparison_operand(line: str, match_start: int) -> bool:
    """Whether the string literal at `match_start` is immediately preceded by
    `==`/`===`/`!=`/`!==`: a condition to route on, not text to check."""
    return bool(_COMPARISON_OPERAND_RE.search(line[:match_start]))


def line_blank_string_mutants(content: str, line_no: int) -> list[str]:
    """One mutant per non-empty string literal on `line_no` that is not an
    equality operand, that literal blanked.

    Targets a presence/absence check directly, without the risk a whole-line
    deletion mutant would carry: this codebase's notes are commonly one arm
    of a long conditional chain, so deleting a line can reroute a different
    arm's text into the one under test, rather than just removing what that
    line contributed. Blanking a literal's contents changes no operator or
    branch -- unless the literal itself is an `===`/`!==` operand, in which
    case blanking it changes what the comparison matches and so, just like
    deletion, can reroute a chain of these into an unrelated arm; skipping
    those specifically is what tells the two apart. Otherwise a blanked
    literal can only remove text a `.includes(...)` or grep check might
    depend on, which is what these assertions actually check.
    """
    lines = content.splitlines(keepends=True)
    idx = line_no - 1
    line = lines[idx]
    mutants = []
    for m in _STRING_LIT_RE.finditer(line):
        q = m.group()[0]
        if m.group() == q + q:
            continue
        if _is_comparison_operand(line, m.start()):
            continue
        new_line = line[:m.start()] + q + q + line[m.end():]
        mutants.append(''.join(lines[:idx] + [new_line] + lines[idx + 1:]))
    return mutants


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


def run_suite(suite_path: str) -> tuple[str, int]:
    """Runs one suite file as its own process: its combined output and exit code."""
    proc = subprocess.run(['bash', suite_path], capture_output=True, text=True)
    return proc.stdout + proc.stderr, proc.returncode


def diff_added_lines(repo: str, base: str, head: str, path: str) -> list[int]:
    proc = subprocess.run(['git', '-C', repo, 'diff', '-U0', base, head, '--', path],
                           capture_output=True, text=True)
    return added_lines(proc.stdout)


def changed_suite_files(repo: str, base: str, head: str) -> list[str]:
    """Suite files the range adds, changes, moves or deletes: the only ones a
    new assertion, or the base record of a moved one, can sit in."""
    # --no-renames: a moved file must list its old path too, or its base
    # records are never run and everything in it reads as new.
    proc = subprocess.run(['git', '-C', repo, 'diff', '--name-only', '--no-renames', base, head],
                          capture_output=True, text=True, check=True)
    return [p for p in proc.stdout.splitlines()
            if any(fnmatch.fnmatch(p, pat) for pat in SUITE_GLOBS)]


def run_suites(tree: str, files: list[str]) -> dict[str, list[Record]]:
    """Each of `files` that exists under `tree`, run, mapped to its records."""
    out = {}
    for f in files:
        path = os.path.join(tree, f)
        if os.path.exists(path):
            stdout, _ = run_suite(path)
            out[f] = records_of(f, stdout)
    return out


def _mutant_contents(head_script: str, repo: str, base: str, head: str) -> list[str]:
    """Every mutant of `head_script`, one per string literal on a line
    base..head added -- the only lines a new assertion's own production
    support could plausibly sit on.

    Deliberately not whole-line deletion: this codebase's notes are commonly
    one arm of a long `cond ? a : cond2 ? b : ...` chain spanning many
    `+`-joined template-literal lines, so deleting a line can reroute an
    unrelated arm's text into the one under test instead of just removing
    what that line contributes -- a false "this discriminates" from control
    flow collateral damage, not from anything the deleted line's own content
    said. Blanking only a literal's contents changes no operator or branch,
    so it cannot reroute anything; it can only remove text an `.includes`
    or grep check might depend on, which is what these assertions actually
    check.
    """
    contents = []
    for line_no in diff_added_lines(repo, base, head, PIPELINE_SCRIPT):
        contents.extend(line_blank_string_mutants(head_script, line_no))
    return contents


def _counterfactual_scripts(repo: str, base: str, head: str):
    """Base's deliver-pipeline.js (when it exists and differs), then every mutant."""
    base_script = git_show(repo, base, PIPELINE_SCRIPT)
    head_script = git_show(repo, head, PIPELINE_SCRIPT)
    if head_script is None or base_script == head_script:
        return
    if base_script is not None:
        yield base_script
    yield from _mutant_contents(head_script, repo, base, head)


def _judge(repo: str, base: str, head: str, tmp: str, head_tree: str,
           pending: list[Record]) -> list[Record]:
    for i, script in enumerate(_counterfactual_scripts(repo, base, head)):
        if not pending:
            break
        tree = os.path.join(tmp, f'counterfactual-{i}')
        shutil.copytree(head_tree, tree)
        with open(os.path.join(tree, PIPELINE_SCRIPT), 'w') as fh:
            fh.write(script)
        files = sorted({c.file for c in pending})
        runs = run_suites(tree, files)
        pending = surviving(pending, [r for f in files for r in runs.get(f, [])])
        shutil.rmtree(tree)
    return pending


def _require_records(head_runs: dict[str, list[Record]]) -> None:
    for f, records in head_runs.items():
        if not records:
            raise NoRecordsError(f)


def _flatten(runs: dict[str, list[Record]]) -> list[Record]:
    return [r for records in runs.values() for r in records]


def _candidates_in(repo: str, base: str, head: str, files: list[str],
                   tmp: str) -> tuple[list[Record], str]:
    """The range's candidates and the head tree they were found in."""
    base_tree, head_tree = os.path.join(tmp, 'base'), os.path.join(tmp, 'head')
    archive_tree(repo, base, base_tree)
    archive_tree(repo, head, head_tree)
    base_runs = run_suites(base_tree, files)
    head_runs = run_suites(head_tree, files)
    _require_records(head_runs)
    return candidates_of(_flatten(base_runs), _flatten(head_runs)), head_tree


def _reports(pending: list[Record]) -> list[Report]:
    return sorted(
        (Report(c.file, c.header, c.label,
                'no counterfactual production script makes this assertion fail') for c in pending),
        key=lambda r: (r.file, r.header or '', r.label),
    )


def find_reports(repo: str, base: str, head: str) -> list[Report]:
    files = changed_suite_files(repo, base, head)
    if not files or git_show(repo, head, PIPELINE_SCRIPT) == git_show(repo, base, PIPELINE_SCRIPT):
        return []
    with tempfile.TemporaryDirectory(prefix='touchstone-assertion-discrimination-') as tmp:
        pending, head_tree = _candidates_in(repo, base, head, files, tmp)
        pending = _judge(repo, base, head, tmp, head_tree, pending)
    return _reports(pending)


def _print_report(r: Report) -> None:
    header = f'[{r.header}] ' if r.header else ''
    print(f'{r.file}: {header}"{r.label}": {r.reason}')


def _parse_args(argv: list[str]) -> tuple[str, str, str] | str:
    """`(repo, base, head)`, or an error message to print to stderr."""
    if len(argv) != 3:
        return 'usage: assertion_discrimination.py <repo> <base-sha> <head-sha>'
    repo = argv[0]
    if not os.path.isdir(repo):
        return f'assertion-discrimination: no such directory: {repo}'
    return repo, argv[1], argv[2]


def _gather_reports(repo: str, base: str, head: str) -> tuple[list[Report] | None, int | None]:
    """`(reports, None)`, or `(None, exit-code)` after printing why."""
    try:
        return find_reports(repo, base, head), None
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
