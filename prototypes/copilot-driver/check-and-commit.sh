#!/usr/bin/env bash
# The wrapper the commit-gate hook redirects to: run the repo's local check,
# and only touch the marker (and thereby unblock `git commit`) if it passes.
# Mirrors skills/crap-controlled-changes/crap-commit.sh's shape: the gate is
# not a test runner you run separately and hope to remember to honour, it *is*
# the thing that runs the check and then commits, atomically.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/repo"

marker=".copilot-check-passed"
rm -f "$marker"

echo "== running local check (python3 -m unittest) =="
if python3 -m unittest discover -s . -p 'test_*.py' -v; then
  echo "== check passed =="
  touch "$marker"
else
  echo "== check FAILED: commit stays refused ==" >&2
  exit 1
fi

git -c commit.gpgsign=false add -A
git -c commit.gpgsign=false -c user.email=t@t -c user.name=t commit -q -m "$*"
rm -f "$marker"
echo "== committed =="
