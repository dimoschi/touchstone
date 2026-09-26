#!/usr/bin/env bash
# Real mutmut (3.8.0 as of writing) refuses outright when every given pattern
# matches zero registered mutants (`AssertionError: ... nothing matches`,
# already caught elsewhere as FAILED TO MEASURE), so a genuinely empty
# `mutmut results --all` for a changed function can only be produced with a
# stub, not with the real tool: needs no live mutmut, only python3 and git.
#
# What it proves: plain `mutmut results` (no --all) omits killed mutants
# entirely, so a naive count of it cannot tell "every mutant was killed" from
# "no mutant was ever generated" -- both look like zero rows. The fix reads
# `--all` and counts every matched row regardless of state.

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODULE="$SKILL_DIR/lib/mutation-check-python.sh"

command -v git >/dev/null || { echo "SKIP: git not on PATH"; exit 0; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

git init -qb main
mkdir -p mypkg
touch mypkg/__init__.py
cat > mypkg/calc.py <<'EOF'
def classify(x):
    return "ok"
EOF
printf '[tool.mutmut]\nsource_paths = ["mypkg"]\n' > pyproject.toml
GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=commit.gpgsign GIT_CONFIG_VALUE_0=false \
  bash -c 'git add . && git commit -qm baseline'

git checkout -qb feature
cat >> mypkg/calc.py <<'EOF'


def double(x):
    return x * 2
EOF
GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=commit.gpgsign GIT_CONFIG_VALUE_0=false \
  bash -c 'git add . && git commit -qm "add double"'

mkdir -p bin
cat > bin/mutmut <<'STUB'
#!/usr/bin/env bash
case "$1" in
  --help) exit 0 ;;
  run) exit 0 ;;
  results)
    case "${STUB_SCENARIO:-}" in
      killed)
        echo "    mypkg.calc.x_double__mutmut_1: killed"
        echo "    mypkg.calc.x_double__mutmut_2: killed"
        ;;
      empty) ;;
    esac
    ;;
  *) exit 0 ;;
esac
STUB
chmod +x bin/mutmut

run() { # run <scenario>
  RC=0
  OUT="$(PATH="$WORK/bin:$PATH" STUB_SCENARIO="$1" MUTATION_PY_RUN="" \
         MUTATION_BASE=main MUTATION_FILES=mypkg/calc.py "$MODULE" 2>&1)" || RC=$?
}

echo "--- scenario: mutants generated and all killed ---"
run killed
echo "$OUT"
[ "$RC" -eq 0 ] || { echo "FAIL: expected exit 0, got $RC"; exit 1; }
echo "$OUT" | grep -qE "generated 2 mutant\(s\) for the changed functions, all killed" || { echo "FAIL: expected the all-killed message with the count"; exit 1; }

echo "--- scenario: mutmut results is empty because nothing was generated ---"
run empty
echo "$OUT"
[ "$RC" -eq 0 ] || { echo "FAIL: expected exit 0, got $RC"; exit 1; }
echo "$OUT" | grep -q "generated no mutants for the changed functions" || { echo "FAIL: expected the zero-mutants message"; exit 1; }
echo "$OUT" | grep -q "killed" && { echo "FAIL: a zero-mutant run must not read as a kill"; exit 1; }

echo "MUTATION PYTHON STUB OK"
