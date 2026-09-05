#!/usr/bin/env python3
"""PreToolUse hook (Bash matcher): verify the mutation ledger before a base
branch changes.

Scope: opt-in. A repo is gated when <repo-root>/.mutation-gated exists, and
not otherwise.

The marker is deliberately NOT the same file as crap-commit-gate.py's
.crap-gated. The two gates are satisfiable on different terms: the CRAP ledger
can always be made green by scoring the code, but a repo can carry mutants that
no test can ever kill -- a string-heavy codebase where mutmut only flips the
case of SQL keywords or sqlite3.Row keys, both case-insensitive. One shared
marker made those repos unmergeable, since this hook blocks `git merge` and
MUTATION_OK was unreachable. Separate markers let a repo opt into commit-time
scoring while treating mutation as informational.

Narrower than the name: this used to fire only on `gh pr create`/`gh pr
ready`, which is one *route* to a base branch, not the condition that
matters. It now fires on three routes -- kept as one file, not renamed,
because hooks.json references it by this exact path:

  - `gh pr create` / `gh pr ready`
  - `git merge <branch>` while HEAD is a base branch
  - `git push` whose destination refspec names a base branch, or whose HEAD is one

Each trigger calls `mutation-check.sh --verify [branch]`, which only checks
the mutation ledger (content-addressed, from a prior full run) and runs no
mutants; it returns in milliseconds. The full run stays a manual, deliberate
step (see mutation-check.sh's own docstring) -- this hook never runs it.

The repo is whatever `git -C` names, else whatever the command `cd`s into, else
the session cwd. The `cd` step is not cosmetic: a harness that pins cwd outside
the repo (or somewhere that is not a repo) otherwise leaves the gate verifying a
repo the command never touches. An explicit push refspec must additionally name
a ref that resolves in that repo, the same tie-break `git merge` makes, since
the branch is read from the command text and the repo from the cwd.

A --verify that exits 2 (setup problem) or 4 (could not measure) never read the
ledger, so it is reported as the gate failing rather than as a red ledger. It
still blocks: unevaluated is not clean, but "record a green run" is the wrong
remedy and sending you after it wastes a full mutation run.

Known gap: a `git push` whose refspec does not name the destination branch
literally (a glob refspec, a remote with a non-identity push default, a bare
`git push` relying on `push.default` config) can slip through undetected.
Decidable beats clever; the gap is written down rather than silently guessed at.
"""

import json
import os
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from base_branch import base_branch_names, git, is_gated, target_repo

MUTATION_CHECK = Path(__file__).resolve().parent.parent / \
    'skills/crap-controlled-changes/mutation-check.sh'
GH_PR = re.compile(r'(?:^|[;&|(]\s*)gh\s+pr\s+(?:create|ready)\b')
GIT_MERGE = re.compile(
    r'(?:^|[;&|(]\s*)git\s+merge\s+(?:-\S+\s+)*(?P<branch>[A-Za-z0-9][\w./-]*)')
GIT_PUSH = re.compile(r'(?:^|[;&|(]\s*)git\s+push\b(?P<rest>[^;&|]*)')
DIAG_LINES = 60


def push_target(rest, repo, base_names):
    """Branch to verify for a `git push`, or None if it isn't headed at one.

    tokens[0] is the remote (if given); tokens[1], if present, is the
    refspec. `git push <refspec>` with no remote is rare enough to skip.
    """
    tokens = [t for t in rest.split() if t and not t.startswith('-')]
    refspec = tokens[1] if len(tokens) > 1 else None
    if refspec:
        source, _, dest = refspec.partition(':')
        dest = dest or source
        if dest.lstrip('+').rsplit('/', 1)[-1].lower() in base_names:
            return source
        return None
    head = git(repo, 'rev-parse', '--abbrev-ref', 'HEAD')
    if head and head.lower() in base_names:
        return head
    return None


def trigger(cmd, cwd):
    """Return (repo, branch_arg) if cmd should be gated, else None.

    branch_arg is None for "verify current HEAD" (mutation-check.sh's own
    default); otherwise it names the branch to verify explicitly.
    """
    if GH_PR.search(cmd):
        return cwd, None

    repo = target_repo(cmd, cwd).resolve()

    m = GIT_MERGE.search(cmd)
    if m:
        head = git(repo, 'rev-parse', '--abbrev-ref', 'HEAD')
        if head and head.lower() in base_branch_names(repo):
            # The branch comes from the command text and the repo from the cwd,
            # which are unrelated: any command merely mentioning a merge would
            # otherwise be gated against whatever repo the shell happened to be
            # in. Verifying the branch exists there is what ties the two
            # together; without it mutation-check got a ref from another repo
            # and its "bad revision" exit was reported as a red ledger.
            if git(repo, 'rev-parse', '--verify', '--quiet',
                   f"{m.group('branch')}^{{commit}}"):
                return repo, m.group('branch')
        return None

    m = GIT_PUSH.search(cmd)
    if m:
        target = push_target(m.group('rest'), repo, base_branch_names(repo))
        # Same tie-break the merge path makes above: an explicit refspec is read
        # from the command text while the repo comes from the cwd, so the ref has
        # to exist in that repo before the two can be treated as one change.
        if target and git(repo, 'rev-parse', '--verify', '--quiet',
                          f'{target}^{{commit}}'):
            return repo, (None if target == 'HEAD' else target)
        return None

    return None


def main():
    try:
        data = json.load(sys.stdin)
    except (ValueError, TypeError):
        return 0
    cmd = (data.get('tool_input') or {}).get('command') or ''
    cwd = Path(data.get('cwd') or os.getcwd()).resolve()

    hit = trigger(cmd, cwd)
    if hit is None:
        return 0
    repo, branch = hit
    repo = repo.resolve()
    if not is_gated(repo, '.mutation-gated'):
        return 0

    args = [str(MUTATION_CHECK), '--verify']
    if branch:
        args.append(branch)
    res = subprocess.run(args, cwd=repo, capture_output=True, text=True)
    if res.returncode == 0:
        return 0
    tail = '\n'.join((res.stdout + '\n' + res.stderr).strip().splitlines()[-DIAG_LINES:])
    # Exit 2 (setup problem) and 4 (could not measure) mean the ledger was never
    # read, so reporting them as a red ledger sends you off to record a green run
    # that cannot help. Still blocks: unevaluated is not the same as clean.
    if res.returncode in (2, 4):
        detail = (f'mutation-check could not evaluate this change in {repo} '
                  f'(exit {res.returncode}), so the ledger was never read. This is '
                  f'the gate failing, not a red ledger')
    else:
        detail = (f'mutation ledger is not green for this change '
                  f'(mutation-check --verify exit {res.returncode}). Run '
                  f'mutation-check.sh (no flags) to record a green run, then retry')
    print(f'mutation-pr-gate: blocked, {detail}.\n\n{tail}', file=sys.stderr)
    return 2


if __name__ == '__main__':
    sys.exit(main())
