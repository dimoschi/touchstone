#!/usr/bin/env python3
"""PreToolUse hook (Bash matcher): route commits in first-party repos through
crap-commit.sh.

Scope: opt-in. A repo is gated when <repo-root>/.crap-gated exists, and not
otherwise (mirrors the crap-controlled-changes skill scope).

This hook no longer decides whether a commit is signed, whether it is gated, or
which repo it lands in. It only refuses a raw `git commit` and names the one
command that does all three. That deliberately removes the inference it used to
carry: it had to parse `cd`, `git -C` and `--git-dir` out of an arbitrary shell
command to guess the target repo, and every form it failed to parse -- notably
`git -C <repo> commit`, which its own regex did not match -- was a silent bypass
of both the signing and CRAP gates. Refusing is decidable; guessing was not.

Exit 2 blocks, with guidance on stderr. Tests: test-crap-commit-gate.sh.
"""

import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from base_branch import is_gated, target_repo

# Not CLAUDE_PLUGIN_ROOT: that is substituted into hooks.json command lines,
# which says nothing about it reaching this process's environment.
WRAPPER = Path(__file__).resolve().parent.parent / \
    'skills/crap-controlled-changes/crap-commit.sh'

# -[cC] takes a following value: without that alternative `git -C <path> commit`
# does not match at all.
GIT_COMMIT = re.compile(
    r'(?:^|[;&|(]\s*)(?:\w+=\S*\s+)*git(?:\s+(?:-[cC]\s+\S+|--?\S+))*\s+commit\b')

# Quoted spans are data, not commands: a commit message can contain anything,
# including the words this hook matches on.
QUOTED = re.compile(r'"(?:\\.|[^"\\])*"|\'[^\']*\'')

HELP = f'''crap-commit-gate: commit in a first-party repo via the wrapper, which \
runs the CRAP gate and signs, in one step:

  {WRAPPER} <absolute-repo-path> -m "message"

Stage your files first with `git add`; the gate scores the staged diff, so
-a is refused. The wrapper takes the repo as an explicit absolute path, so no
`cd` or `git -C` is needed or parsed.'''


def main():
    data = json.load(sys.stdin)
    cmd = (data.get('tool_input') or {}).get('command') or ''

    # A commit message may quote the words `git commit`, and a wrapper call
    # carrying such a message is not a raw commit to intercept. Blanking quoted
    # spans settles that without a second rule: what remains is the command, and
    # a wrapper call has no `git commit` in it. The rule this replaces skipped
    # any command whose text merely contained "crap-commit.sh", so naming the
    # wrapper in a message was enough to walk a raw commit past every gate.
    if not GIT_COMMIT.search(QUOTED.sub(' ', cmd)):
        return 0

    # The repo the commit lands in, not the one the session sits in: a command
    # is free to `cd` or `git -C` somewhere else, and gating the session cwd
    # would both miss those and gate a repo the command never touches.
    session_cwd = Path(data.get('cwd') or '.').resolve()
    if not is_gated(target_repo(cmd, session_cwd), '.crap-gated'):
        return 0

    print(HELP, file=sys.stderr)
    return 2


if __name__ == '__main__':
    sys.exit(main())
