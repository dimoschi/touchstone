#!/usr/bin/env python3
r"""PostToolUse hook (Edit|Write|MultiEdit matcher): flag newly added comments
against a repo's own policy.

Scope: opt-in. A repo is gated when <worktree-root>/.comment-gated exists in the
worktree being edited, and not otherwise: the plugin ships no default rule, so
an ungated repo's comments are never inspected and a repo that opts in but
writes an empty (or comment-only) marker flags nothing until it lists a rule.
Unlike `.crap-gated`/`.mutation-gated`, which resolve to the same file for
every worktree off a repo, `.comment-gated` carries policy content a branch
can edit, so it is read per-worktree: it must be committed, not just staged,
to be visible from a linked worktree.

The marker carries the policy itself, one Python regex per line (blank lines
and `#`-prefixed lines ignored), same shape as `.crap-gated`'s exemption list:
a second file just for the rules would be a list nobody keeps in sync with the
marker that turns the gate on. Each pattern is matched with `re.search(...,
re.I)` against the text of a newly added whole-line comment (its prefix and
surrounding whitespace stripped). A rule that itself needs to start with a
literal `#` (`#\d+`, for "no ticket references in comments") has to escape it
(`\#\d+`), or the line reads as a marker comment and is silently ignored.

Comment detection is prefix-based per file extension, not a parser. That cuts
both ways: it never sees a trailing (same-line) comment or a block comment
(false negatives), and it cannot tell a real comment from a string literal,
heredoc, or docstring line whose first non-space character happens to be the
prefix (false positives). That is deliberate scope, not an oversight; see
README.md for the full list of what this does and does not do.

Verdict: exit 2 with findings on stderr, exit 0 otherwise. A `.comment-gated`
line that does not compile as a regex, or that cannot be decoded as UTF-8, is
a setup error (exit 2 naming the marker file), not a silent skip or an
uncaught crash.

Tests: test-comment-policy-gate.sh, test_comment_policy_gate.py.
"""

import json
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from base_branch import worktree_root
from copilot_session_evidence import canonical_path
from hook_invocation import normalize_invocation, tool_input_path

MARKER = '.comment-gated'
EDIT_TOOLS = frozenset({'Edit', 'Write', 'MultiEdit'})

# Extension -> the syntax for a whole-line comment in that language. Prefix
# form only: a file whose extension is not listed here produces no findings,
# by design (README.md names this as a limitation, not a bug to work around).
COMMENT_PREFIXES = {
    '.py': '#', '.sh': '#', '.bash': '#', '.zsh': '#', '.rb': '#', '.pl': '#',
    '.yaml': '#', '.yml': '#', '.toml': '#',
    '.go': '//', '.js': '//', '.jsx': '//', '.ts': '//', '.tsx': '//',
    '.java': '//', '.c': '//', '.h': '//', '.cc': '//', '.cpp': '//',
    '.hpp': '//', '.cs': '//', '.php': '//', '.rs': '//', '.swift': '//',
    '.kt': '//', '.kts': '//', '.scala': '//', '.groovy': '//',
    '.sql': '--', '.lua': '--',
}

HELP = '''comment-policy: a newly added comment matches this repo's .comment-gated policy: {reason}

Address what the policy rule is warning about. .comment-gated is the repo owner's
policy, not yours to edit: if the rule itself looks wrong, say so and let a human decide.'''


def comment_text(line, prefix):
    """Text of `line` with `prefix` removed, or None if it is not a whole-line comment."""
    stripped = line.strip()
    if not stripped.startswith(prefix):
        return None
    return stripped[len(prefix):].strip()


def _new_lines_from_edit(edit):
    """New_string lines whose stripped text was not already present in old_string."""
    new_string = edit.get('new_string')
    if not isinstance(new_string, str):
        return []
    old_string = edit.get('old_string')
    old_lines = {line.strip() for line in old_string.split('\n')} if isinstance(old_string, str) else set()
    return [line for line in new_string.split('\n') if line.strip() not in old_lines]


def _new_lines_from_write(tool_input, path):
    """Content lines whose stripped text was not already in `path`'s last commit.

    A Write overwrites the file before this PostToolUse hook ever runs, so
    unlike Edit there is no `old_string` to diff against: the file's own
    working-tree content before the call is already gone. The last commit is
    the closest available "before" snapshot; `path` untracked or unresolvable
    falls back to treating every line as new, same as a brand new file.
    """
    content = tool_input.get('content')
    if not isinstance(content, str):
        return []
    old_lines = _committed_lines(path)
    return [line for line in content.split('\n') if line.strip() not in old_lines]


def _committed_lines(path):
    """Stripped lines of `path` as of HEAD, or empty if untracked/unknown.

    Decodes the raw `git show` bytes itself with `errors='replace'` rather
    than going through `base_branch.git` (which decodes strictly and returns
    None on failure): a committed blob that is not valid UTF-8 still needs a
    baseline to diff the new content against, or every untouched line in the
    file, comments included, is reported as newly added -- the same fallback
    a genuinely untracked file gets, wrongly applied to a tracked one.
    """
    if path is None:
        return set()
    try:
        p = subprocess.run(['git', '-C', str(path.parent), 'show', f'HEAD:./{path.name}'],
                            capture_output=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return set()
    if p.returncode != 0:
        return set()
    text = p.stdout.decode('utf-8', errors='replace')
    return {line.strip() for line in text.split('\n')}


def _new_lines_from_multi_edit(tool_input):
    edits = tool_input.get('edits')
    if not isinstance(edits, list):
        return []
    lines = []
    for edit in edits:
        if isinstance(edit, dict):
            lines.extend(_new_lines_from_edit(edit))
    return lines


def new_comment_lines(tool_name, tool_input, path):
    """Raw text of the lines `tool_name` newly adds, per its own payload shape.

    `path` is only used by the Write branch, which has no `old_string` of its
    own to diff against.
    """
    if tool_name == 'Write':
        return _new_lines_from_write(tool_input, path)
    if tool_name == 'Edit':
        return _new_lines_from_edit(tool_input)
    if tool_name == 'MultiEdit':
        return _new_lines_from_multi_edit(tool_input)
    return []


def _policy_text(path):
    """UTF-8 text of `path`, or None if it does not exist.

    Pinned to UTF-8 rather than the locale's default encoding, so a non-ASCII
    rule (an em-dash ban is the obvious first one for this project) does not
    crash the process open under a `LC_ALL=C` locale. Bytes that still fail to
    decode are the same kind of setup error as a bad regex (exit 2 naming the
    file), not an uncaught exit 1.
    """
    try:
        return path.read_text(encoding='utf-8')
    except OSError:
        return None
    except UnicodeDecodeError as exc:
        print(f'comment-policy: {path}: not valid UTF-8: {exc}', file=sys.stderr)
        sys.exit(2)


def _compile_rule(path, lineno, line):
    """`line` compiled as a case-insensitive regex, or exit 2 naming file and line."""
    try:
        return re.compile(line, re.I)
    except re.error as exc:
        print(f'comment-policy: {path} line {lineno}: not a valid regex: {exc}', file=sys.stderr)
        sys.exit(2)


def load_policy(path):
    """Compiled regexes from `path`; [] if it is absent or carries no rule.

    A line that does not compile is a setup error: it exits the process with
    2 rather than being skipped or raising past the caller, so a typo in the
    policy is reported at the point it was written, not discovered later as a
    gate that silently never fires.
    """
    text = _policy_text(path)
    if text is None:
        return []
    patterns = []
    for lineno, raw in enumerate(text.split('\n'), start=1):
        line = raw.strip()
        if not line or line.startswith('#'):
            continue
        patterns.append(_compile_rule(path, lineno, line))
    return patterns


def _target_path(invocation):
    """Canonical path an Edit/Write/MultiEdit lands on, or None if out of scope."""
    if invocation.tool_name not in EDIT_TOOLS:
        return None
    path = tool_input_path(invocation.tool_input)
    if not path:
        return None
    return Path(canonical_path(path, invocation.cwd))


def _comment_marker_path(path):
    """Path to `.comment-gated` for the worktree that actually contains `path`.

    Unlike the boolean opt-in markers, `.comment-gated` carries policy content
    that a branch can add to or edit, so it has to be read from the worktree
    being edited, not the root every worktree shares (`base_branch.marker_path`,
    used for `.crap-gated`/`.mutation-gated`, resolves there deliberately since
    those are a whole-repo yes/no). A linked worktree otherwise reads whatever
    the main checkout's working tree happens to hold.
    """
    root = worktree_root(path)
    return root / MARKER if root is not None else None


def _resolved_policy(invocation):
    """(tool_name, path, comment prefix, compiled rules), or None once any precondition misses."""
    path = _target_path(invocation)
    if path is None:
        return None
    prefix = COMMENT_PREFIXES.get(path.suffix)
    if prefix is None:
        return None
    found = _comment_marker_path(path)
    if found is None or not found.exists():
        return None
    patterns = load_policy(found)
    if not patterns:
        return None
    return invocation.tool_name, path, prefix, patterns


def _first_match(tool_name, tool_input, path, prefix, patterns):
    """Text of the first newly added comment line any rule matches, or None."""
    for line in new_comment_lines(tool_name, tool_input, path):
        text = comment_text(line, prefix)
        if text is None:
            continue
        for pattern in patterns:
            if pattern.search(text):
                return text
    return None


def main():
    data = json.load(sys.stdin)
    invocation = normalize_invocation(data)
    if invocation is None:
        return 0

    resolved = _resolved_policy(invocation)
    if resolved is None:
        return 0
    tool_name, path, prefix, patterns = resolved

    match = _first_match(tool_name, invocation.tool_input, path, prefix, patterns)
    if match is None:
        return 0

    print(HELP.format(reason=match), file=sys.stderr)
    return 2


if __name__ == '__main__':
    sys.exit(main())
