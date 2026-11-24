#!/usr/bin/env bash
# Test that mutago's macOS test-binary wrapper is turned off, keeping user test flags.
#
# On darwin mutago v2.10.19+ runs each mutant's test binary through a wrapper that
# overwrites one reused file in place. macOS then sometimes SIGKILLs the binary,
# and mutago counts that as a killed mutant: an untested line scored as tested.
# A -exec test flag of the caller's own disables the wrapper.

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODULE="$SKILL_DIR/lib/mutation-check-go.sh"

command -v go  >/dev/null || { echo "SKIP: go not on PATH"; exit 0; }
command -v git >/dev/null || { echo "SKIP: git not on PATH"; exit 0; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
CALLS="$WORK/calls.log"
mkdir -p "$WORK/repo"
cd "$WORK/repo" || exit 1

cat > "$WORK/runner.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$CALLS"
exit 1
EOF
chmod +x "$WORK/runner.sh"

GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=commit.gpgsign GIT_CONFIG_VALUE_0=false \
  bash -c 'git init -qb main && printf "module example.com/ex\n\ngo 1.26\n" > go.mod &&
    printf "package ex\n\nfunc One() int {\n\treturn 1\n}\n" > ex.go &&
    git add . && git commit -qm base'

run() { # run [test-flags]
  : > "$CALLS"
  MUTATION_BASE=main MUTATION_FILES=ex.go MUTATION_GO_RUNNER="$WORK/runner.sh" \
    MUTATION_GO_TEST_FLAGS="${1:-}" "$MODULE" >/dev/null 2>&1
}

echo "--- phase 1: no user flags, the wrapper is still disabled ---"
run ""
grep -q -- '--test-flags=-exec=env$\|--test-flags=-exec=env ' "$CALLS" \
  || { echo "FAIL: expected --test-flags=-exec=env"; cat "$CALLS"; exit 1; }
echo "  ok"

echo "--- phase 2: user flags are kept beside it ---"
run "-short -count=1"
grep -q -- '--test-flags=-exec=env -short -count=1' "$CALLS" \
  || { echo "FAIL: expected the user's flags after -exec=env"; cat "$CALLS"; exit 1; }
echo "  ok"

echo "--- phase 3: the config sits in the module dir, where a container runner can read it ---"
cat > "$WORK/config-runner.sh" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in --config=*) cfg="\${a#--config=}" ;; esac
done
case "\$cfg" in /*|'') echo "absolute-or-missing \$cfg" >> "$CALLS"; exit 1 ;; esac
[ -f "\$cfg" ] && grep -q 'skip_without_test: false' "\$cfg" \
  && echo "readable \$cfg" >> "$CALLS"
exit 1
EOF
chmod +x "$WORK/config-runner.sh"
: > "$CALLS"
MUTATION_BASE=main MUTATION_FILES=ex.go MUTATION_GO_RUNNER="$WORK/config-runner.sh" \
  "$MODULE" >/dev/null 2>&1
grep -q '^readable ' "$CALLS" \
  || { echo "FAIL: expected a relative, readable config in the module dir"; cat "$CALLS"; exit 1; }
left="$(git status --porcelain --ignored)"
[ -z "$left" ] || { echo "FAIL: the config copy was left behind"; echo "$left"; exit 1; }
echo "  ok"

echo "MUTATION GO EXEC OK"
