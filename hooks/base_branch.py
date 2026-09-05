#!/usr/bin/env python3
"""Shared git helpers for PreToolUse hooks: base-branch detection, the
`-C <path>` target-repo resolution, and the opt-in marker lookup.

Extracted because mutation-pr-gate.py needs the same base-branch detection
base-branch-commit-gate.py already had (merge/push land on the same set of
branches a raw commit would); duplicating it risked the two hooks disagreeing
about what counts as a base branch.
"""

import re
import subprocess
from pathlib import Path

BASE_BRANCHES = frozenset({
    'main', 'master', 'production', 'staging', 'develop', 'dev', 'release',
    'trunk',
})

DASH_C = re.compile(r'\bgit\s+-C\s+(?P<path>"[^"]+"|\'[^\']+\'|\S+)')
CD = re.compile(r'(?:^|[;&|(]\s*)cd\s+(?P<path>"[^"]+"|\'[^\']+\'|[^\s;&|)]+)')


def git(repo, *args):
    try:
        p = subprocess.run(['git', '-C', str(repo), *args],
                           capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return None
    return p.stdout.strip() if p.returncode == 0 else None


def target_repo(cmd, session_cwd):
    """Repo a command acts on: `git -C`, else any `cd` it performs, else cwd.

    The `cd` walk matters because a harness can pin the session cwd somewhere
    that is not the repo (or not a repo at all), leaving `cd <repo> && git ...`
    as the only thing naming the real target. Without it the gates resolve to
    the pinned cwd and verify a repo the command never touches.
    """
    m = DASH_C.search(cmd)
    if m:
        return Path(m.group('path').strip('"\'')).expanduser()
    repo = Path(session_cwd)
    for m in CD.finditer(cmd):
        path = m.group('path').strip('"\'')
        if path == '-':
            continue
        repo = repo / Path(path).expanduser()
    return repo


def base_branch_names(repo):
    names = set(BASE_BRANCHES)
    head = git(repo, 'symbolic-ref', '--short', 'refs/remotes/origin/HEAD')
    if head:
        names.add(head.rsplit('/', 1)[-1].lower())
    return names


def repo_common_root(repo):
    """Repo root shared by all worktrees, resolved via --git-common-dir.

    --show-toplevel returns the *worktree* path from inside a linked
    worktree, not the repo. A gating marker is a per-repo opt-in
    (a repo either wants gating or it doesn't), not a per-worktree one, so
    every worktree must resolve to the same root.
    """
    gcd = git(repo, 'rev-parse', '--path-format=absolute', '--git-common-dir')
    return Path(gcd).parent if gcd else None


def is_gated(path, marker):
    """Whether `path` sits in a repo that opted into `marker`.

    Gating is opt-in per repo: the marker file must exist at the repo root.
    Nothing is inferred from where the repo lives on disk. That is the whole
    scope rule, and it is deliberately not configurable -- a path-prefix rule
    ("everything under my work directory") silently gates a third-party
    checkout the moment you clone it somewhere convenient, and gives the repo
    itself no say. The marker is committable, so a team shares one decision.

    `path` may be a file that does not exist yet (a Write creating a new
    directory), so the walk starts at its nearest existing ancestor.
    """
    probe = path if path.is_dir() else None
    if probe is None:
        for parent in path.parents:
            if parent.is_dir():
                probe = parent
                break
    if probe is None:
        return False
    root = repo_common_root(probe)
    return root is not None and (root / marker).exists()
