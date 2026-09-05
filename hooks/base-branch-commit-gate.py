#!/usr/bin/env python3
"""PreToolUse hook (Bash matcher): refuse agent commits on a base branch.

Scope: any repo that has a configured remote. A repo with no remote is local
scratch and committing to its main harms nobody, so it is exempt. That
exemption expires the moment a remote is added, which is the point: the rule
starts applying as soon as the work can reach anyone else.
"""

import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from base_branch import base_branch_names, git, target_repo

GIT_COMMIT = re.compile(r'\bgit\b[^|;&]*\bcommit\b')

# Quoted spans are data, not commands, so a message or an echo that contains
# these words is not a commit. Mirrors crap-commit-gate.py.
QUOTED = re.compile(r'"(?:\\.|[^"\\])*"|\'[^\']*\'')

HELP = '''Refused: that commit would land on a base branch.

Cut a working branch first. If this belongs to a ticket, name it so the session
can be traced back to one:

    git checkout -b feat/jira-PROJ-4821-short-slug
    git checkout -b fix/gh-216-short-slug

Then commit. Do not commit to the base branch by another route, and do not
change this hook: the rule is that agents never commit to a branch other people
build on.'''


def main():
    try:
        data = json.load(sys.stdin)
    except (ValueError, TypeError):
        return 0
    cmd = (data.get('tool_input') or {}).get('command') or ''
    if not GIT_COMMIT.search(QUOTED.sub(' ', cmd)):
        return 0

    repo = target_repo(cmd, Path(data.get('cwd') or '.'))
    if git(repo, 'rev-parse', '--git-dir') is None:
        return 0

    # No remote means the work cannot reach anyone else yet.
    if not git(repo, 'remote'):
        return 0

    branch = git(repo, 'rev-parse', '--abbrev-ref', 'HEAD')
    if not branch or branch == 'HEAD':
        return 0
    if branch.lower() not in base_branch_names(repo):
        return 0

    print(f'{HELP}\n\nCurrent branch: {branch}\nRepo: {repo}', file=sys.stderr)
    return 2


if __name__ == '__main__':
    raise SystemExit(main())
