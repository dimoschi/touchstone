#!/usr/bin/env bash
# E2E test for mutation-check.sh with the Python module (mutmut via uv).
# Mirrors run-mutation-go.sh: feature branch adds a weakly tested method,
# expects survivors + exit 1, then killing tests + exit 0.

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SKILL_DIR/mutation-check.sh"

command -v uv  >/dev/null || { echo "SKIP: uv not on PATH"; exit 0; }
command -v git >/dev/null || { echo "SKIP: git not on PATH"; exit 0; }

export MUTATION_PY_RUN="uv run --no-project --with mutmut --with pytest --"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

git init -qb main
mkdir -p mypkg tests
touch mypkg/__init__.py
cat > mypkg/calc.py <<'EOF'
def classify(x):
    if x > 10:
        return "big"
    return "ok"
EOF
cat > tests/test_calc.py <<'EOF'
from mypkg.calc import classify

def test_classify():
    assert classify(50) == "big"
    assert classify(5) == "ok"
    assert classify(10) == "ok"
    assert classify(11) == "big"
EOF
printf '[tool.mutmut]\nsource_paths = ["mypkg"]\n' > pyproject.toml
printf 'mutants/\n' > .gitignore
GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=commit.gpgsign GIT_CONFIG_VALUE_0=false \
  bash -c 'git add . && git commit -qm baseline'

git checkout -qb feature
cat >> mypkg/calc.py <<'EOF'


class Ops:
    def sign(self, x):
        if x < 0:
            return -1
        return 1
EOF
cat >> tests/test_calc.py <<'EOF'

from mypkg.calc import Ops

def test_sign_weak():
    assert Ops().sign(5) == 1
EOF
GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=commit.gpgsign GIT_CONFIG_VALUE_0=false \
  bash -c 'git add . && git commit -qm "add Ops.sign weakly tested"'

echo "--- phase 1: weakly tested method, expect survivors ---"
RC=0
OUT="$("$SCRIPT" 2>&1)" || RC=$?
echo "$OUT"
[ "$RC" -eq 1 ] || { echo "FAIL: expected exit 1, got $RC"; exit 1; }
echo "$OUT" | grep -q 'SURVIVED'          || { echo "FAIL: no SURVIVED rows"; exit 1; }
echo "$OUT" | grep -q 'mypkg/calc.py:'    || { echo "FAIL: no file:line in rows"; exit 1; }
echo "$OUT" | grep -q 'Ops.sign'          || { echo "FAIL: qualname missing"; exit 1; }
echo "$OUT" | grep -q 'KILL_SURVIVORS'    || { echo "FAIL: no KILL_SURVIVORS directive"; exit 1; }
echo "$OUT" | grep -q 'classify'          && { echo "FAIL: unchanged function was mutated"; exit 1; }

echo "--- phase 2: killing tests added, expect clean ---"
cat >> tests/test_calc.py <<'EOF'

def test_sign_strong():
    assert Ops().sign(-5) == -1
    assert Ops().sign(-1) == -1
    assert Ops().sign(0) == 1
EOF
GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=commit.gpgsign GIT_CONFIG_VALUE_0=false \
  bash -c 'git add tests && git commit -qm "kill mutants"'

RC=0
OUT="$("$SCRIPT" 2>&1)" || RC=$?
echo "$OUT"
[ "$RC" -eq 0 ] || { echo "FAIL: expected exit 0, got $RC"; exit 1; }
echo "$OUT" | grep -q 'MUTATION_OK' || { echo "FAIL: no MUTATION_OK"; exit 1; }

echo "--- unit: module path derivation ---"
python3 -c "
import sys
sys.path.insert(0, '$SKILL_DIR/lib')
from mutmut_patterns import module_path
assert module_path('src/mypkg/calc.py') == 'mypkg.calc', module_path('src/mypkg/calc.py')
assert module_path('mypkg/__init__.py') == 'mypkg', module_path('mypkg/__init__.py')
assert module_path('calc.py') == 'calc', module_path('calc.py')
print('module_path OK')
" || exit 1

echo "MUTATION PYTHON OK"
