"""Fixtures shared by the unit suites in this directory."""

import json
import os
import shutil
import subprocess
import sys

import pytest

import crap_rows


class Repo:
    """A throwaway git repository the suites commit into."""

    def __init__(self, root):
        self.root = root

    def git(self, *args):
        done = subprocess.run(
            ["git", "-C", str(self.root), "-c", "commit.gpgsign=false",
             "-c", "user.name=t", "-c", "user.email=t@t", *args],
            check=True, capture_output=True, text=True)
        return done.stdout.strip()

    def write(self, rel, content):
        path = self.root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        if isinstance(content, bytes):
            path.write_bytes(content)
        else:
            path.write_text(content)
        return path

    def commit(self, message="c"):
        self.git("add", "-A")
        self.git("commit", "-q", "--allow-empty", "-m", message)
        return self.git("rev-parse", "HEAD")

    def worktree(self, path, branch):
        self.git("worktree", "add", "-q", "-b", branch, str(path))
        return Repo(path)

    @property
    def rows_path(self):
        common = self.git("rev-parse", "--path-format=absolute", "--git-common-dir")
        return os.path.join(common, "crap-check-rows.json")

    def land(self, rows, branch="feat"):
        """One crap-commit.sh round: record the gate's rows against a staged change, then commit it."""
        self.landings = getattr(self, "landings", 0) + 1
        self.write(f"landed-{self.landings}.txt", "x\n")
        self.git("add", "-A")
        crap_rows.record(self.rows_path, branch, rows, str(self.root))
        return self.commit(f"landing {self.landings}")


@pytest.fixture
def repo(tmp_path):
    root = tmp_path / "repo"
    root.mkdir()
    subprocess.run(["git", "init", "-q", str(root)], check=True)
    subprocess.run(["git", "-C", str(root), "symbolic-ref", "HEAD", "refs/heads/feat"], check=True)
    return Repo(root)


STUB = """#!{python}
import json, os, sys
with open({log!r}, 'a') as _log:
    _log.write(json.dumps({{'tool': {name!r}, 'args': sys.argv[1:], 'cwd': os.getcwd()}}) + '\\n')
{body}
"""


class Stubs:
    """Command-line tools that are not the real ones, on a PATH holding nothing else.

    Every call is logged, so a test can say what a tool was asked and from where.
    """

    def __init__(self, directory):
        self.directory = directory
        self.log = directory / "calls.jsonl"

    def add(self, name, body="", *, out="", err="", code=0, into=None):
        body = body or (f"sys.stdout.write({out!r}); sys.stderr.write({err!r}); sys.exit({code})")
        path = (into or self.directory) / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(STUB.format(python=sys.executable, log=str(self.log), name=name, body=body))
        path.chmod(0o755)
        return path

    def calls(self, name=None):
        if not self.log.exists():
            return []
        rows = [json.loads(line) for line in self.log.read_text().splitlines()]
        return [r for r in rows if name is None or r["tool"] == name]


@pytest.fixture
def stubs(tmp_path, monkeypatch):
    directory = tmp_path / "stub-bin"
    directory.mkdir()
    for real in ("git", "tar"):
        (directory / real).symlink_to(shutil.which(real))
    monkeypatch.setenv("PATH", str(directory))
    return Stubs(directory)
