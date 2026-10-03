"""Fixtures shared by the unit suites that need a real git repository."""

import os
import subprocess

import pytest


def _clean_env():
    env = {k: v for k, v in os.environ.items() if not k.startswith('GIT_')}
    env.update(GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1')
    return env


class Repo:
    """A throwaway repository: signing off, an explicit identity, no inherited config."""

    def __init__(self, path):
        self.path = path
        self.git('init', '-q')

    def git(self, *args):
        done = subprocess.run(
            ['git', '-C', str(self.path), '-c', 'user.name=test', '-c', 'user.email=t@t',
             '-c', 'commit.gpgsign=false', *args],
            capture_output=True, text=True, check=True, env=_clean_env())
        return done.stdout

    def commit(self, files, message='c'):
        """Write `files` (a value of None deletes the path) and commit; returns the sha."""
        for name, content in files.items():
            target = self.path / name
            if content is None:
                target.unlink()
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            if isinstance(content, bytes):
                target.write_bytes(content)
            else:
                target.write_text(content)
        self.git('add', '-A')
        self.git('commit', '-q', '-m', message)
        return self.git('rev-parse', 'HEAD').strip()


@pytest.fixture
def repo(tmp_path):
    return Repo(tmp_path)
