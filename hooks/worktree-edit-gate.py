#!/usr/bin/env python3
"""PreToolUse hook (Edit|Write|MultiEdit matcher): refuse an edit that lands
in the repo's main checkout while a ticket worktree is active for the acting
agent.

Scope: no opt-in marker. "Active" is read straight off the acting agent's own
evidence, the same way contributing-gate.py reads whether a guide was Read:
the payload must carry `agent_id`, and that subagent's own transcript
(`hook_invocation.subagent_transcript`) must open with a `[touchstone:
<label>]` line followed by a `Repo worktree: <path>` line in its first
`type == "user"` entry -- the exact header `treeAgent()` and `envelope()`
(workflows/parts/20-setup-worktree.js.part) stamp on every dispatch once a
worktree exists. A marker would need the dispatched agent itself to write it,
which is state under measurement, not evidence of it; a missing subagent
transcript therefore fails open (this hook stays silent) rather than closed,
since failing closed here would refuse every subagent's first edit in every
repo, gated or not, until its transcript happened to exist on disk.

Known gap: a Bash command that writes a file (a redirect, `sed -i`, a script,
a test fixture) is not covered. `base_branch.shell_tokens`'s own docstring
gives the reason: modelling an arbitrary shell command's write target reaches
past what shlex can answer, and the treeAgent prompt already forces `git -C
<worktree>` for every git command plus `base-branch-commit-gate.py`'s own
refusal of a commit on main; this hook only closes the Edit/Write/MultiEdit
path the ticket this file is named for was filed about.

Exit 2 blocks, naming the worktree on stderr. Tests: test-worktree-edit-gate.sh.
"""

import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from base_branch import git_common_dir, repo_common_root
from hook_invocation import subagent_transcript, tool_input_path

EDIT_TOOLS = frozenset({'Edit', 'Write', 'MultiEdit'})

HEADER_RE = re.compile(r'^\s*\[touchstone: [^\]\n]+\]\s*$', re.M)
WORKTREE_RE = re.compile(r'^\s*Repo worktree: (.+?)\s*$', re.M)

HELP = '''worktree-edit-gate: a ticket worktree is active for this agent at
{worktree}, and {path} is in the main checkout instead.

Edit inside the worktree: every Read, Grep and Edit path starts with
{worktree}/.'''


def _text_block(block):
    """A `text`-type content block's own text, else ''."""
    if not isinstance(block, dict) or block.get('type') != 'text':
        return ''
    return block.get('text') or ''


def _entry_text(entry):
    """A transcript entry's own message text, or None if its shape is not one
    this gate recognises (a list of content blocks, or a bare string)."""
    message = entry.get('message')
    content = message.get('content') if isinstance(message, dict) else None
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return '\n'.join(_text_block(block) for block in content)
    return None


def _first_user_entry(transcript):
    """The first `type == "user"` JSON entry in `transcript`, or None if the
    file cannot be opened at all or no such entry is in it.

    Stops at that first entry on purpose: a later one naming the dispatch
    header is the agent quoting its own instructions back mid-conversation,
    not the header a treeAgent dispatch actually opened with.
    """
    try:
        handle = open(transcript, errors='replace')
    except OSError:
        return None
    with handle:
        for line in handle:
            try:
                entry = json.loads(line)
            except ValueError:
                continue
            if entry.get('type') == 'user':
                return entry
    return None


def _worktree_from_entry(entry):
    """The worktree path `entry`'s own text names, or None if it names none
    or the entry's shape is not one this gate recognises."""
    text = _entry_text(entry)
    if text is None:
        return None
    header = HEADER_RE.search(text)
    if not header:
        return None
    match = WORKTREE_RE.search(text[header.end():])
    return match.group(1) if match else None


def active_worktree(transcript):
    """Absolute worktree path the transcript's first `type == "user"` entry
    names, or None otherwise."""
    entry = _first_user_entry(transcript)
    return _worktree_from_entry(entry) if entry is not None else None


def _contains(root, target):
    """Whether `target` is `root` itself or somewhere under it."""
    return target == root or root in target.parents


def _edit_target(data):
    """(tool_input's path, cwd to resolve it against), or None if this
    payload is not an Edit/Write/MultiEdit naming a usable path."""
    if data.get('tool_name') not in EDIT_TOOLS:
        return None
    tool_input = data.get('tool_input')
    if not isinstance(tool_input, dict):
        return None
    path = tool_input_path(tool_input)
    if not path:
        return None
    cwd = data.get('cwd')
    return path, (cwd if isinstance(cwd, str) and cwd else '.')


def _active_worktree_for(data):
    """The worktree path this agent's own transcript names as active, or
    None if the payload or that transcript carries no such evidence."""
    agent_id = data.get('agent_id')
    if not agent_id:
        return None
    transcript_path = data.get('transcript_path')
    if not isinstance(transcript_path, str) or not transcript_path:
        return None
    own = subagent_transcript(transcript_path, agent_id)
    return active_worktree(own) if own is not None else None


def _exempt(target, wt, root):
    """Whether `target` sits somewhere this gate never refuses: inside the
    active worktree itself, inside any worktree under <root>/.claude/worktrees/,
    or inside the repo's shared git directory."""
    if _contains(wt, target):
        return True
    if _contains((root / '.claude' / 'worktrees').resolve(), target):
        return True
    gcd = git_common_dir(wt)
    return bool(gcd) and _contains(Path(gcd).resolve(), target)


def _payload():
    """The hook's stdin as a dict, or None for anything else at all."""
    try:
        data = json.load(sys.stdin)
    except ValueError:
        return None
    return data if isinstance(data, dict) else None


def _resolved_edit(data):
    """(target path, active worktree, repo root), each already resolved, or
    None if any piece of evidence this gate needs -- a usable edit target, an
    active worktree, a repo root to check it against -- is missing."""
    edit = _edit_target(data)
    if edit is None:
        return None
    path, cwd = edit
    worktree = _active_worktree_for(data)
    if not worktree:
        return None
    # Resolved on both sides: /tmp and /var are themselves symlinks on macOS,
    # so a bare string compare between a worktree path and a target built from
    # the payload's own cwd can disagree about the same directory.
    wt = Path(worktree).expanduser().resolve()
    root = repo_common_root(wt)
    if root is None:
        return None
    target = (Path(cwd) / path).expanduser().resolve()
    return target, wt, root.resolve()


def main():
    data = _payload()
    if data is None:
        return 0
    resolved = _resolved_edit(data)
    if resolved is None:
        return 0
    target, wt, root = resolved
    if not _contains(root, target) or _exempt(target, wt, root):
        return 0

    print(HELP.format(worktree=wt, path=target), file=sys.stderr)
    return 2


if __name__ == '__main__':
    sys.exit(main())
