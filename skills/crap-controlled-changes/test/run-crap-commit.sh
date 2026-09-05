#!/usr/bin/env bash
# Tests crap-commit.sh: the single sanctioned commit path. Covers the refusals
# that keep the gate meaningful, that a red gate's exit code is propagated and
# nothing is committed, and that a green gate produces a signed commit.

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WRAP="$SKILL_DIR/crap-commit.sh"

command -v git >/dev/null || { echo "SKIP: git not on PATH"; exit 0; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
failures=0

check() {
  if [ "$2" = "$3" ]; then
    echo "  ok:   $1"
  else
    echo "  FAIL: $1 (got '$2', want '$3')"
    failures=$((failures + 1))
  fi
}

# A repo under the tmpdir matches none of ~/.gitconfig's includeIf blocks, so it
# falls through to the openpgp smartcard identity, which crap-commit.sh refuses
# rather than signing as someone else. Point it at the passphrase-less ssh key so
# the signing path is exercised instead of skipped.
export CRAP_SIGNING_KEY="${CRAP_SIGNING_KEY:-$HOME/.ssh/id_ed25519}"
[ -f "$CRAP_SIGNING_KEY" ] || { echo "SKIP: no ssh signing key at $CRAP_SIGNING_KEY"; exit 0; }

new_repo() {
  local d="$WORK/$1"
  mkdir -p "$d"
  git init -q "$d"
  git -C "$d" config user.email t@t
  git -C "$d" config user.name t
  git -C "$d" config commit.gpgsign false
  echo "# readme" > "$d/README.md"
  git -C "$d" add README.md
  git -C "$d" -c gpg.format=openpgp commit -q -m baseline
  printf '%s' "$d"
}

rc_of() {
  local rc=0
  "$@" >/dev/null 2>&1 || rc=$?
  printf '%s' "$rc"
}

echo "usage and setup refusals"
check "no arguments"          "$(rc_of "$WRAP")" "2"
check "repo but no flags"     "$(rc_of "$WRAP" /tmp)" "2"
check "relative repo path"    "$(rc_of "$WRAP" some/where -m x)" "2"
check "nonexistent directory" "$(rc_of "$WRAP" /nonexistent/xyz -m x)" "2"
check "not a git repository"  "$(rc_of "$WRAP" /tmp -m x)" "2"

R="$(new_repo plain)"
echo "staging discipline"
check "nothing staged"        "$(rc_of "$WRAP" "$R" -m x)" "2"
echo "change" >> "$R/README.md"
git -C "$R" add README.md
check "-a is refused"         "$(rc_of "$WRAP" "$R" -a -m x)" "2"
check "--all is refused"      "$(rc_of "$WRAP" "$R" --all -m x)" "2"
check "-am is refused too"    "$(rc_of "$WRAP" "$R" -am x)" "2"

echo "green gate commits, and signs"
before="$(git -C "$R" rev-parse HEAD)"
out="$("$WRAP" "$R" -m "docs: a change" 2>&1)"; rc=$?
check "exit 0"                "$rc" "0"
check "HEAD moved"            "$([ "$(git -C "$R" rev-parse HEAD)" != "$before" ] && echo yes)" "yes"
check "commit is signed"      "$(git -C "$R" log -1 --format='%G?' | grep -cE '^[GU]')" "1"
if [ "$rc" -ne 0 ]; then printf '%s\n' "$out" | sed 's/^/    | /'; fi

echo "red gate propagates and does not commit"
if command -v go >/dev/null; then
  G="$(new_repo golang)"
  printf 'module example.com/g\n\ngo 1.26\n' > "$G/go.mod"
  cat > "$G/calc.go" <<'EOF'
package calc

func Grade(x int) string {
	if x > 90 {
		return "a"
	}
	if x > 80 {
		return "b"
	}
	if x > 70 {
		return "c"
	}
	return "f"
}
EOF
  git -C "$G" add go.mod calc.go
  before="$(git -C "$G" rev-parse HEAD)"
  rc=0
  out="$("$WRAP" "$G" -m "feat: ungated" 2>&1)" || rc=$?
  check "exit is the gate's, not 0"  "$([ "$rc" -ne 0 ] && echo yes)" "yes"
  check "HEAD did not move"          "$(git -C "$G" rev-parse HEAD)" "$before"
  check "says it is not committing"  "$(printf '%s' "$out" | grep -c 'not committing')" "1"
  check "staged diff is still staged" \
        "$(git -C "$G" diff --cached --name-only | grep -c 'calc.go')" "1"
else
  echo "  skip: go not on PATH, red-gate case not exercised"
fi

echo ""
if [ "$failures" -eq 0 ]; then
  echo "CRAP COMMIT OK"
else
  echo "FAILED: $failures assertion(s)"
  exit 1
fi
