#!/usr/bin/env python3
"""Shared git helpers for PreToolUse hooks: base-branch detection, the
`-C <path>` target-repo resolution, and the opt-in marker lookup.

Extracted because mutation-pr-gate.py needs the same base-branch detection
base-branch-commit-gate.py already had (merge/push land on the same set of
branches a raw commit would); duplicating it risked the two hooks disagreeing
about what counts as a base branch.
"""

import shlex
import subprocess
from pathlib import Path

BASE_BRANCHES = frozenset({
    'main', 'master', 'production', 'staging', 'develop', 'dev', 'release',
    'trunk',
})

OPERATOR_CHARS = frozenset('();<>|&')


def git(repo, *args):
    try:
        p = subprocess.run(['git', '-C', str(repo), *args],
                           capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError, UnicodeDecodeError):
        # `text=True` decodes stdout strictly (locale encoding, usually
        # UTF-8); a caller reading a tracked file's content (rather than a
        # ref name or path) can hit legacy-encoded source, and that must
        # report "unknown" like any other failure, not crash the process.
        return None
    return p.stdout.strip() if p.returncode == 0 else None


def shell_tokens(cmd):
    """Lex `cmd` into shell words, quoting and escapes resolved like bash would.

    `posix=True` collapses a quoted argument into exactly one token (a `--body
    "..."` value becomes one word, not the words inside it) and honours a
    backslash-escaped quote inside it rather than letting it reopen the word;
    without this a message like `"he said \\"git -C /x\\""` split back into
    `git`, `-C`, `/x` as separate tokens, which is the redirect bug again.
    `punctuation_chars=True` keeps `&&`, `;`, `|` etc. as their own tokens even
    with no surrounding whitespace (`cd a&&cd b`). An unterminated quote raises
    after yielding the words seen before it; that is a command bash itself
    would refuse to run, so returning the partial lex rather than raising keeps
    a hook from crashing on it.

    Shell constructs beyond quoting are deliberately not modelled: comments,
    line continuations and heredocs. Each of them ends the lex early, which
    leaves no redirect to find, and the caller then resolves the session's own
    repository, which is the answer that still gates something. Modelling them
    means reimplementing bash's word splitting, and the attempt reached for
    shlex's private attributes to do it.
    """
    lexer = shlex.shlex(cmd, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    tokens = []
    try:
        for tok in lexer:
            tokens.append(tok)
    except ValueError:
        pass
    return tokens


def _is_operator(tok):
    return tok != '' and set(tok) <= OPERATOR_CHARS


def _dash_c_target(tokens):
    """Path named by the first `git -C <path>` among `tokens`, or None."""
    for i in range(len(tokens) - 2):
        if tokens[i].split('/')[-1] == 'git' and tokens[i + 1] == '-C':
            return Path(tokens[i + 2]).expanduser()
    return None


def _is_cd_at(tokens, i):
    """Whether `tokens[i]` is a `cd` in command position: first token, or
    right after an operator, mirroring where a shell would actually run it
    rather than treat it as an argument to something else."""
    return tokens[i] == 'cd' and (i == 0 or _is_operator(tokens[i - 1]))


def _is_skippable_cd_path(path):
    """`cd -` (previous directory) and a bare operator in the path slot
    (`cd && ls`, which the old `[^\\s;&|)]+` class could not match either)
    are not paths to walk into."""
    return path == '-' or _is_operator(path)


def _cd_walk(tokens, session_cwd):
    """`session_cwd` after applying every `cd` among `tokens` in order."""
    repo = Path(session_cwd)
    for i in range(len(tokens) - 1):
        if not _is_cd_at(tokens, i):
            continue
        path = tokens[i + 1]
        if _is_skippable_cd_path(path):
            continue
        repo = repo / Path(path).expanduser()
    return repo


def target_repo(cmd, session_cwd):
    """Repo a command acts on: `git -C`, else any `cd` it performs, else cwd.

    Scans lexed tokens, not the raw string, so a `git -C` or `cd` that only
    appears inside a quoted argument (message text, `--body`) is data, not a
    redirect. The `cd` walk matters because a harness can pin the session cwd
    somewhere that is not the repo (or not a repo at all), leaving
    `cd <repo> && git ...` as the only thing naming the real target. Without it
    the gates resolve to the pinned cwd and verify a repo the command never
    touches.
    """
    tokens = shell_tokens(cmd)
    return _dash_c_target(tokens) or _cd_walk(tokens, session_cwd)


def base_branch_names(repo):
    names = set(BASE_BRANCHES)
    head = git(repo, 'symbolic-ref', '--short', 'refs/remotes/origin/HEAD')
    if head:
        names.add(head.rsplit('/', 1)[-1].lower())
    return names


def repo_common_root(repo):
    """Repo root shared by all worktrees, resolved via --git-common-dir.

    --show-toplevel returns the *worktree* path from inside a linked
    worktree, not the repo. A marker resolved through this function is a
    per-repo opt-in (a repo either wants gating or it doesn't), not a
    per-worktree one, so every worktree must resolve to the same root.
    `.comment-gated` is the exception: see `worktree_root` for why it needs
    its own resolver instead of this one.
    """
    gcd = git(repo, 'rev-parse', '--path-format=absolute', '--git-common-dir')
    return Path(gcd).parent if gcd else None


def worktree_root(path):
    """Root of the specific worktree containing `path`, via --show-toplevel.

    Deliberately not `repo_common_root`: that resolves every linked worktree
    to the same directory, which is right for a boolean opt-in marker but
    wrong for one that carries content a branch can edit (a Write in worktree
    A must see worktree A's own copy, not whatever worktree B's working tree
    happens to hold).
    """
    probe = _nearest_existing_ancestor(path)
    if probe is None:
        return None
    top = git(probe, 'rev-parse', '--show-toplevel')
    return Path(top) if top else None


def _nearest_existing_ancestor(path):
    """`path` itself if it is a directory, else its nearest existing parent.

    `path` may be a file that does not exist yet (a Write creating a new
    directory), so the walk has to climb past every not-yet-created level.
    """
    if path.is_dir():
        return path
    for parent in path.parents:
        if parent.is_dir():
            return parent
    return None


def marker_path(path, marker):
    """Path to `marker` at the repo root containing `path`, or None outside one."""
    probe = _nearest_existing_ancestor(path)
    if probe is None:
        return None
    root = repo_common_root(probe)
    return root / marker if root is not None else None


def is_gated(path, marker):
    """Whether `path` sits in a repo that opted into `marker`.

    Gating is opt-in per repo: the marker file must exist at the repo root.
    Nothing is inferred from where the repo lives on disk. That is the whole
    scope rule, and it is deliberately not configurable -- a path-prefix rule
    ("everything under my work directory") silently gates a third-party
    checkout the moment you clone it somewhere convenient, and gives the repo
    itself no say. The marker is committable, so a team shares one decision.
    """
    found = marker_path(path, marker)
    return found is not None and found.exists()
