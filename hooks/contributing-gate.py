#!/usr/bin/env python3
"""PreToolUse hook (Edit|Write|MultiEdit matcher): read a repo's contribution
guide before changing its files.

Scope: opt-in. A repo is gated when <repo-root>/.crap-gated exists, and not
otherwise (mirrors crap-commit-gate.py).

A repo that ships no guide is never gated: the lookup that finds nothing returns
before anything else runs. The gate exists only where there is something to read.

What satisfies it is a Read of the file in this session's transcript, not a
marker file. A marker is state that can be written once and then stops
measuring; the transcript is the same evidence a reader would look for, and the
one action that clears the gate -- reading -- is always available, so there is
no way to be stuck behind it.

Exit 2 blocks, with the paths on stderr. Tests: test-contributing-gate.sh.
"""

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from base_branch import git, is_gated
from copilot_session_evidence import (
    SessionEvidenceError,
    canonical_path,
    read_session_paths,
)
from hook_invocation import normalize_invocation

# Extensionless CONTRIBUTORS is deliberately absent: it is commonly a generated
# list of names rather than a guide, so gating on it costs a read and teaches
# nothing.
GUIDES = (
    'CONTRIBUTING.md', 'CONTRIBUTING.rst', 'CONTRIBUTING.txt', 'CONTRIBUTING',
    'CONTRIBUTORS.md',
    'DEVELOPMENT.md', 'DEVELOPING.md',
)
GUIDE_DIRS = ('', '.github', 'docs')
EDIT_TOOLS = frozenset({'Edit', 'Write', 'MultiEdit'})

HELP = '''contributing-gate: this repo documents how it wants to be changed.
Read it before editing:

{paths}

Then make the edit again. A Read of each file is the only thing that clears
this, and it is asked once per file per session.'''

UNSUPPORTED = '''contributing-gate: unsupported Copilot {tool} payload for a repo that ships contribution guides.
This hook needs tool_input.file_path to decide what {tool} would change:

{paths}'''


def nearest_dir(path):
    """First ancestor that exists, so a Write creating new directories still
    resolves to its repo instead of failing open."""
    for parent in path.parents:
        if parent.is_dir():
            return parent
    return None


def find_guides(worktree):
    found = []
    for subdir in GUIDE_DIRS:
        for name in GUIDES:
            guide = worktree / subdir / name
            if guide.is_file() and guide not in found:
                found.append(guide)
    return found


def resolved(path):
    """Absolute path with symlinks collapsed, for a file that need not exist.

    Both sides of the transcript comparison must go through this. The guides are
    found under `git rev-parse --show-toplevel`, which git returns already
    resolved, while a Read records whatever path the agent was working with. On
    any repo reached through a symlink -- /tmp and /var on macOS, or a symlinked
    code directory -- the two spellings differ, and comparing them raw left the
    gate permanently unclearable: the one action that satisfies it could never
    be recognised.
    """
    try:
        return str(Path(path).expanduser().resolve())
    except (OSError, RuntimeError):
        return str(Path(path).expanduser())


def read_in_session(transcript, guides):
    """Subset of `guides` this session's transcript records a Read of."""
    wanted = {resolved(guide): guide for guide in guides}
    # Prefilter on basenames, not full paths: the line holds the agent's
    # spelling of the path, which is exactly what may not match.
    names = {Path(guide).name for guide in guides}
    seen = set()
    try:
        handle = open(transcript, errors='replace')
    except OSError:
        return seen
    with handle:
        for line in handle:
            if 'tool_use' not in line or not any(n in line for n in names):
                continue
            try:
                entry = json.loads(line)
            except ValueError:
                continue
            content = (entry.get('message') or {}).get('content') or ()
            for block in content:
                if not isinstance(block, dict) or block.get('name') != 'Read':
                    continue
                target = (block.get('input') or {}).get('file_path')
                if target and resolved(target) in wanted:
                    seen.add(resolved(target))
    return seen


def main():
    try:
        data = json.load(sys.stdin)
    except ValueError:
        return 0

    invocation = normalize_invocation(data)
    if invocation is not None and invocation.host == 'copilot' \
            and invocation.event == 'pre_tool_use':
        return gate_copilot(invocation)

    return gate_legacy(data)


def gate_copilot(invocation):
    if invocation.tool_name not in EDIT_TOOLS:
        return 0

    target = copilot_target(invocation)
    if target is None:
        top = repo_toplevel(invocation.cwd)
        if not top:
            return 0
        guides = find_guides(Path(top))
        if not is_gated(Path(top), '.crap-gated') or not guides:
            return 0
        print(UNSUPPORTED.format(
            tool=invocation.tool_name,
            paths='\n'.join(f'  {guide}' for guide in guides),
        ), file=sys.stderr)
        return 2

    target_path = Path(target)
    top = repo_toplevel(target_path)
    if not top or not is_gated(target_path, '.crap-gated'):
        return 0

    guides = [g for g in find_guides(Path(top)) if canonical_path(g) != target]
    if not guides:
        return 0

    try:
        read = read_session_paths(invocation.session_id)
    except SessionEvidenceError as exc:
        print(f'contributing-gate: {exc}', file=sys.stderr)
        return 2

    unread = [g for g in guides if canonical_path(g) not in read]
    if not unread:
        return 0

    print(HELP.format(paths='\n'.join(f'  {g}' for g in unread)), file=sys.stderr)
    return 2


def gate_legacy(data):
    target = (data.get('tool_input') or {}).get('file_path')
    if not target:
        return 0

    target = Path(target).expanduser()
    if not is_gated(target, '.crap-gated'):
        return 0

    start = nearest_dir(target)
    top = git(start, 'rev-parse', '--show-toplevel') if start else None
    if not top:
        return 0

    guides = [g for g in find_guides(Path(top)) if resolved(g) != resolved(target)]
    if not guides:
        return 0

    read = read_in_session(data.get('transcript_path') or '', guides)
    unread = [g for g in guides if resolved(g) not in read]
    if not unread:
        return 0

    print(HELP.format(paths='\n'.join(f'  {g}' for g in unread)), file=sys.stderr)
    return 2


def repo_toplevel(path):
    start = path if path.is_dir() else nearest_dir(path)
    top = git(start, 'rev-parse', '--show-toplevel') if start else None
    return Path(top) if top else None


def copilot_target(invocation):
    value = invocation.tool_input.get('file_path')
    if not isinstance(value, str) or not value:
        return None
    return canonical_path(value, invocation.cwd)


if __name__ == '__main__':
    sys.exit(main())
