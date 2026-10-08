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
        path.unlink(missing_ok=True)
        path.write_text(STUB.format(python=sys.executable, log=str(self.log), name=name, body=body))
        path.chmod(0o755)
        return path

    def wrap(self, name, failing, err="boom"):
        """Replace the real `name` with one that fails, with `err` on stderr, whenever
        every word of `failing` is among its arguments, and otherwise runs the real tool."""
        real = os.path.realpath(self.directory / name)
        return self.add(name, f"if {set(failing)!r} <= set(sys.argv[1:]):\n"
                              f"    sys.stderr.write({err!r}); sys.exit(1)\n"
                              f"os.execv({real!r}, [{real!r}, *sys.argv[1:]])")

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


@pytest.fixture
def argv_log(monkeypatch):
    """Every subprocess.run made while the test runs, as {"argv", "cwd", "kwargs"}.

    A tool name written in another case still runs on a case-insensitive filesystem,
    so the argv is the only place a test can see that the name was spelled exactly.
    """
    real = subprocess.run
    calls = []

    def recording(argv, *args, **kwargs):
        calls.append({"argv": list(argv), "cwd": kwargs.get("cwd"), "kwargs": kwargs})
        return real(argv, *args, **kwargs)

    monkeypatch.setattr(subprocess, "run", recording)
    return calls


@pytest.fixture
def exact_case_fs(monkeypatch):
    """os.path.isfile that is true only when every component of the path exists spelled as
    given, so a file named in the wrong case is not found as it would be on macOS."""
    real = os.path.isfile

    def exact(path):
        path = os.path.abspath(path)
        if not real(path):
            return False
        while path != os.path.dirname(path):
            parent, name = os.path.split(path)
            if name not in os.listdir(parent):
                return False
            path = parent
        return True

    monkeypatch.setattr(os.path, "isfile", exact)
