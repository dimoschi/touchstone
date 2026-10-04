"""Fixtures shared by the unit suites in this directory."""

import subprocess

import pytest


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


@pytest.fixture
def repo(tmp_path):
    root = tmp_path / "repo"
    root.mkdir()
    subprocess.run(["git", "init", "-q", str(root)], check=True)
    subprocess.run(["git", "-C", str(root), "symbolic-ref", "HEAD", "refs/heads/feat"], check=True)
    return Repo(root)
