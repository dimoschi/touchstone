"""Running git and external analysers for the change-risk signals."""

import shutil
import subprocess
import tempfile


def which(tool):
    return shutil.which(tool)


def missing(tool):
    """The reason a tool cannot run, or None when it is on PATH."""
    return None if which(tool) else f'{tool} is not on PATH'


def run(cmd, cwd=None):
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, check=False)


def tail(text, limit=300):
    """The last `limit` characters of `text`, on one line."""
    return ' '.join(text.split())[-limit:]


def git(repo, *args):
    return subprocess.run(['git', '-C', repo, *args], capture_output=True, check=False)


def cat_file(repo, rev, path):
    """The bytes of `path` at `rev`, or None when it is not there."""
    done = git(repo, 'cat-file', '-p', f'{rev}:{path}')
    return done.stdout if done.returncode == 0 else None


def unpack(repo, rev, parent, paths=()):
    """`rev` exported into a new directory under `parent`, which is returned.

    The directory exists even when the export failed, so a path the revision
    does not have simply is not in it.
    """
    dest = tempfile.mkdtemp(dir=parent)
    export_tree(repo, rev, dest, paths)
    return dest


def export_tree(repo, rev, dest, paths=()):
    """Unpack `rev` (limited to `paths`, when given) into `dest`; False on failure."""
    args = ['archive', '--format=tar', rev] + (['--', *paths] if paths else [])
    packed = git(repo, *args)
    if packed.returncode != 0:
        return False
    unpacked = subprocess.run(['tar', '-x', '-C', dest], input=packed.stdout,
                              capture_output=True, check=False)
    return unpacked.returncode == 0
