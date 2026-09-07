#!/usr/bin/env bash
# Regression test for scripts/check-version-bump.sh.
#
# Builds a throwaway fixture repo per case rather than reusing the real
# repo's history, so each case controls exactly which commit last changed
# `version` and which files moved after it.
#
# Exit 0 all green, 1 any assertion failed.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT/scripts/check-version-bump.sh"

failures=0

check() {
  local label="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then
    echo "  ok:   $label ($got)"
  else
    echo "  FAIL: $label (got $got, want $want)"
    failures=$((failures + 1))
  fi
}

# Builds a fresh fixture repo at $1 with a root commit carrying
# .claude-plugin/plugin.json at $2, and returns (via REPO) a path ready for
# more commits.
new_fixture() {
  local dir="$1" version="$2"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" config user.email test@example.com
  git -C "$dir" config user.name test
  git -C "$dir" config commit.gpgsign false
  mkdir -p "$dir/.claude-plugin"
  printf '{\n  "name": "fixture",\n  "version": "%s"\n}\n' "$version" > "$dir/.claude-plugin/plugin.json"
  git -C "$dir" add .claude-plugin/plugin.json
  git -C "$dir" commit -qm "root: version $version"
}

bump_version() {
  local dir="$1" version="$2" msg="$3"
  printf '{\n  "name": "fixture",\n  "version": "%s"\n}\n' "$version" > "$dir/.claude-plugin/plugin.json"
  git -C "$dir" add .claude-plugin/plugin.json
  git -C "$dir" commit -qm "$msg"
}

write_file() {
  local dir="$1" path="$2" content="$3" msg="$4"
  mkdir -p "$dir/$(dirname "$path")"
  printf '%s\n' "$content" > "$dir/$path"
  git -C "$dir" add "$path"
  git -C "$dir" commit -qm "$msg"
}

run_check() {
  local dir="$1"
  (cd "$dir" && bash "$CHECK")
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "case A: no gated change since the last bump -> ok"
REPO="$WORK/a"
new_fixture "$REPO" 0.1.0
write_file "$REPO" "README.md" "docs" "docs: readme"
write_file "$REPO" "scripts/thing.sh" "echo hi" "scripts: add thing"
write_file "$REPO" ".github/workflows/ci.yml" "name: ci" "ci: add workflow"
run_check "$REPO" >/tmp/out.a 2>&1
check "exit code" "$?" 0
check ".github/workflows/ is not matched by the workflows/ prefix" \
  "$(grep -c 'ok' /tmp/out.a)" "1"

echo "case B: a gated file changed after the last bump, version unchanged -> fail"
REPO="$WORK/b"
new_fixture "$REPO" 0.1.0
write_file "$REPO" "workflows/deliver.js" "export const meta = {}" "workflows: add deliver"
run_check "$REPO" >/tmp/out.b 2>&1
check "exit code" "$?" 1
check "names the offending file" "$(grep -c 'workflows/deliver.js' /tmp/out.b)" "1"
check "names the current version" "$(grep -c '0.1.0' /tmp/out.b)" "2"

echo "case C: plugin.json touched without changing version does not count as a bump"
REPO="$WORK/c"
new_fixture "$REPO" 0.1.0
# Touches plugin.json (adds a field) but keeps version identical: must not
# reset the search for V, a plain 'git log -- plugin.json' would get this wrong.
{
  printf '{\n  "name": "fixture",\n  "version": "0.1.0",\n  "description": "x"\n}\n' > "$REPO/.claude-plugin/plugin.json"
  git -C "$REPO" add .claude-plugin/plugin.json
  git -C "$REPO" commit -qm "manifest: add description"
}
write_file "$REPO" "hooks/foo.py" "print(1)" "hooks: add foo"
run_check "$REPO" >/tmp/out.c 2>&1
check "exit code" "$?" 1
check "names the offending file" "$(grep -c 'hooks/foo.py' /tmp/out.c)" "1"

echo "case D: gated change bundled with the version bump -> ok"
REPO="$WORK/d"
new_fixture "$REPO" 0.1.0
write_file "$REPO" "agents/one.md" "one" "agents: add one, pre-bump"
{
  printf '{\n  "name": "fixture",\n  "version": "0.2.0"\n}\n' > "$REPO/.claude-plugin/plugin.json"
  printf 'two\n' > "$REPO/agents/two.md"
  git -C "$REPO" add .claude-plugin/plugin.json agents/two.md
  git -C "$REPO" commit -qm "agents: add two, bump version"
}
run_check "$REPO" >/tmp/out.d 2>&1
check "exit code" "$?" 0

echo "case E: gated change committed before the last bump -> ok"
REPO="$WORK/e"
new_fixture "$REPO" 0.1.0
write_file "$REPO" "commands/one.md" "one" "commands: add one"
bump_version "$REPO" 0.2.0 "release: bump to 0.2.0"
run_check "$REPO" >/tmp/out.e 2>&1
check "exit code" "$?" 0

echo "case F: a gated file deleted since the last bump -> fail"
REPO="$WORK/f"
new_fixture "$REPO" 0.1.0
write_file "$REPO" "skills/one/SKILL.md" "one" "skills: add one"
bump_version "$REPO" 0.2.0 "release: bump to 0.2.0"
git -C "$REPO" rm -q skills/one/SKILL.md
git -C "$REPO" commit -qm "skills: drop one"
run_check "$REPO" >/tmp/out.f 2>&1
check "exit code" "$?" 1
check "names the deleted path" "$(grep -c 'skills/one/SKILL.md' /tmp/out.f)" "1"

echo "case G: a gated file renamed since the last bump -> fail"
REPO="$WORK/g"
new_fixture "$REPO" 0.1.0
write_file "$REPO" "skills/one/SKILL.md" "one" "skills: add one"
bump_version "$REPO" 0.2.0 "release: bump to 0.2.0"
git -C "$REPO" mv skills/one/SKILL.md skills/one/SKILLS.md
git -C "$REPO" commit -qm "skills: rename one"
run_check "$REPO" >/tmp/out.g 2>&1
check "exit code" "$?" 1

echo "case H: no .claude-plugin/plugin.json at HEAD -> usage error"
REPO="$WORK/h"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name test
git -C "$REPO" config commit.gpgsign false
write_file "$REPO" "README.md" "docs" "docs: readme"
run_check "$REPO" >/tmp/out.h 2>&1
check "exit code" "$?" 2

echo "case I: plugin.json with no version key -> usage error"
REPO="$WORK/i"
mkdir -p "$REPO/.claude-plugin"
git -C "$REPO" init -q
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name test
git -C "$REPO" config commit.gpgsign false
printf '{\n  "name": "fixture"\n}\n' > "$REPO/.claude-plugin/plugin.json"
git -C "$REPO" add .claude-plugin/plugin.json
git -C "$REPO" commit -qm "root: no version key"
run_check "$REPO" >/tmp/out.i 2>&1
check "exit code" "$?" 2

echo "case J: no version-changing commit reachable from HEAD -> usage error"
REPO="$WORK/j"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name test
git -C "$REPO" config commit.gpgsign false
write_file "$REPO" "README.md" "docs" "docs: readme, no manifest at all"
run_check "$REPO" >/tmp/out.j 2>&1
check "exit code" "$?" 2

echo "case K: a shallow clone additionally says full history is required"
REPO="$WORK/k"
new_fixture "$REPO" 0.1.0
write_file "$REPO" "README.md" "docs" "docs: readme"
CLONE="$WORK/k-shallow"
git clone -q --depth 1 "file://$REPO" "$CLONE"
run_check "$CLONE" >/tmp/out.k 2>&1
check "exit code" "$?" 2
check "mentions fetch-depth" "$(grep -c 'fetch-depth' /tmp/out.k)" "1"

echo ""
if [ "$failures" -eq 0 ]; then
  echo "OK (11 cases)"
else
  echo "FAILED: $failures assertion(s)"
  exit 1
fi
