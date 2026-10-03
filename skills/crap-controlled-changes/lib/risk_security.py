"""The security_pattern signal: a security tool's finding on a line the range added.

gosec (Go), bandit (Python) and opengrep with this plugin's own PHP rules run
over the head revision. A finding counts only when its line span overlaps a line
the range added: a finding on code the range did not touch says nothing about
this change. A language with no tool, a missing tool, or a tool that fails is
unmeasured rather than false.
"""

import json
import os

import go_modules
from risk_core import combine_any, measured, unmeasured
from risk_scan import scan_head
from risk_tools import missing, run, tail

PHP_RULES = os.path.normpath(os.path.join(
    os.path.dirname(os.path.abspath(__file__)), '..', 'rules', 'php-security.yml'))


def span_of(line):
    """(start, end) of gosec's `line`, which is '9' or '10-12'."""
    start, _, end = str(line).partition('-')
    return int(start), int(end or start)


def gosec_findings(text, root):
    real_root = os.path.realpath(root)
    return [(os.path.relpath(os.path.realpath(i['file']), real_root), *span_of(i['line']),
             f"{i['rule_id']} {i['details']}")
            for i in json.loads(text).get('Issues') or []]


def bandit_span(result):
    lines = result.get('line_range') or [result['line_number']]
    return min(lines), max(lines)


def bandit_findings(text):
    return [(os.path.normpath(r['filename']), *bandit_span(r), f"{r['test_id']} {r['issue_text']}")
            for r in json.loads(text)['results']]


def opengrep_findings(text):
    return [(os.path.normpath(r['path']), r['start']['line'], r['end']['line'], r['check_id'])
            for r in json.loads(text)['results']]


def overlapping(findings, added):
    return [f for f in findings if added.get(f[0], set()) & set(range(f[1], f[2] + 1))]


def describe(hits):
    return '; '.join(f'{label} at {path}:{start}' for path, start, _, label in hits)


def scan_verdict(tool, done, parse, added):
    try:
        findings = parse(done.stdout)
    except (ValueError, KeyError, TypeError):
        return unmeasured(f'{tool} exited {done.returncode} without a readable report: '
                          f'{tail(done.stderr or done.stdout)}')
    if done.returncode not in (0, 1):
        return unmeasured(f'{tool} exited {done.returncode}: {tail(done.stderr)}')
    hits = overlapping(findings, added)
    if hits:
        return measured(True, f'{tool}: {describe(hits)}')
    return measured(False, f'{tool}: {len(findings)} finding(s), none on a line this range added')


def gosec_module(head_root, moddir, added):
    done = run(['gosec', '-fmt=json', '-quiet', './...'], cwd=os.path.join(head_root, moddir))
    return scan_verdict('gosec', done, lambda text: gosec_findings(text, head_root), added)


def go_part(head_root, paths, added):
    gap = missing('gosec')
    if gap:
        return unmeasured(gap)
    moddirs = sorted({go_modules.owning_module(p, set(), head_root) for p in paths})
    return combine_any([gosec_module(head_root, m, added) for m in moddirs],
                       'no Go module changed')


def scan_changed(tool, argv, parse, head_root, paths, added, noun):
    gap = missing(tool)
    if gap:
        return unmeasured(gap)
    present = [p for p in paths if os.path.isfile(os.path.join(head_root, p))]
    if not present:
        return measured(False, f'{tool}: no changed {noun} file exists at the head revision')
    return scan_verdict(tool, run([*argv, *present], cwd=head_root), parse, added)


def python_part(head_root, paths, added):
    return scan_changed('bandit', ['bandit', '-q', '-f', 'json', '--'], bandit_findings,
                        head_root, paths, added, 'Python')


def php_part(head_root, paths, added):
    argv = ['opengrep', 'scan', '--json', '--quiet', '--config', PHP_RULES]
    return scan_changed('opengrep', argv, opengrep_findings, head_root, paths, added, 'PHP')


HANDLERS = {'go': go_part, 'python': python_part, 'php': php_part}


def security_signal(repo, head, groups, added):
    return scan_head(HANDLERS, 'security tool', repo, head, groups, added)
