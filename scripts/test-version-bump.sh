#!/usr/bin/env bash
# Regression test for scripts/check-version-bump.sh.
#
# Builds a throwaway fixture repo per case rather than reusing the real
# repo's history. Each case that means to look like a PR commits to `main`
# once (the fork point) and then branches to `pr` for the change under test,
# since the script compares HEAD against origin/main (or, absent an origin,
# a local main branch) rather than walking history for the last bump.
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
# .claude-plugin/plugin.json at $2, on a branch named `main`.
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
  git -C "$dir" branch -M main
}

# Branches `pr` off the current `main` tip, so main stays at the fork point
# while further commits (added by the caller) land on `pr`.
fork_pr() {
  local dir="$1"
  git -C "$dir" checkout -q -b pr main
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

echo "case A: PR with no gated change -> ok"
REPO="$WORK/a"
new_fixture "$REPO" 0.1.0
fork_pr "$REPO"
write_file "$REPO" "README.md" "docs" "docs: readme"
write_file "$REPO" "scripts/thing.sh" "echo hi" "scripts: add thing"
write_file "$REPO" ".github/workflows/ci.yml" "name: ci" "ci: add workflow"
run_check "$REPO" >/tmp/out.a 2>&1
check "exit code" "$?" 0
check ".github/workflows/ is not matched by the workflows/ prefix" \
  "$(grep -c 'ok' /tmp/out.a)" "1"

echo "case B: PR adds a gated file, version unchanged -> fail"
REPO="$WORK/b"
new_fixture "$REPO" 0.1.0
fork_pr "$REPO"
write_file "$REPO" "workflows/deliver.js" "export const meta = {}" "workflows: add deliver"
run_check "$REPO" >/tmp/out.b 2>&1
check "exit code" "$?" 1
check "names the offending file" "$(grep -c 'workflows/deliver.js' /tmp/out.b)" "1"
check "names the current version" "$(grep -c '0.1.0' /tmp/out.b)" "2"

echo "case C: manifest-only edit (no version change) -> fail, plugin.json itself is gated"
REPO="$WORK/c"
new_fixture "$REPO" 0.1.0
fork_pr "$REPO"
{
  printf '{\n  "name": "fixture",\n  "version": "0.1.0",\n  "description": "x"\n}\n' > "$REPO/.claude-plugin/plugin.json"
  git -C "$REPO" add .claude-plugin/plugin.json
  git -C "$REPO" commit -qm "manifest: add description"
}
run_check "$REPO" >/tmp/out.c 2>&1
check "exit code" "$?" 1
check "names the manifest itself" "$(grep -c '.claude-plugin/plugin.json' /tmp/out.c)" "2"

echo "case D1: PR bumps version, then adds the gated file -> ok (order independent)"
REPO="$WORK/d1"
new_fixture "$REPO" 0.1.0
fork_pr "$REPO"
bump_version "$REPO" 0.2.0 "release: bump to 0.2.0"
write_file "$REPO" "agents/one.md" "one" "agents: add one"
run_check "$REPO" >/tmp/out.d1 2>&1
check "exit code" "$?" 0

echo "case D2: PR adds the gated file, then bumps version -> ok (order independent)"
REPO="$WORK/d2"
new_fixture "$REPO" 0.1.0
fork_pr "$REPO"
write_file "$REPO" "agents/one.md" "one" "agents: add one"
bump_version "$REPO" 0.2.0 "release: bump to 0.2.0"
run_check "$REPO" >/tmp/out.d2 2>&1
check "exit code" "$?" 0

echo "case E: a gated file pushed straight to main -> ok (push-to-main is a deliberate no-op)"
REPO="$WORK/e"
new_fixture "$REPO" 0.1.0
write_file "$REPO" "commands/one.md" "one" "commands: add one, no PR"
run_check "$REPO" >/tmp/out.e 2>&1
check "exit code" "$?" 0

echo "case F: PR deletes a gated file, no bump -> fail"
REPO="$WORK/f"
new_fixture "$REPO" 0.1.0
write_file "$REPO" "skills/one/SKILL.md" "one" "skills: add one"
fork_pr "$REPO"
git -C "$REPO" rm -q skills/one/SKILL.md
git -C "$REPO" commit -qm "skills: drop one"
run_check "$REPO" >/tmp/out.f 2>&1
check "exit code" "$?" 1
check "names the deleted path" "$(grep -c 'skills/one/SKILL.md' /tmp/out.f)" "1"

echo "case G: PR renames a gated file within a gated dir, no bump -> fail"
REPO="$WORK/g"
new_fixture "$REPO" 0.1.0
write_file "$REPO" "skills/one/SKILL.md" "one" "skills: add one"
fork_pr "$REPO"
git -C "$REPO" mv skills/one/SKILL.md skills/one/SKILLS.md
git -C "$REPO" commit -qm "skills: rename one"
run_check "$REPO" >/tmp/out.g 2>&1
check "exit code" "$?" 1

echo "case G2: PR moves a gated file out of a gated dir, no bump -> fail (rename must not hide the source)"
REPO="$WORK/g2"
new_fixture "$REPO" 0.1.0
write_file "$REPO" "skills/one/SKILL.md" "one" "skills: add one"
fork_pr "$REPO"
mkdir -p "$REPO/docs"
git -C "$REPO" mv skills/one/SKILL.md docs/one.md
git -C "$REPO" commit -qm "docs: move one out of skills/"
run_check "$REPO" >/tmp/out.g2 2>&1
check "exit code" "$?" 1
check "names the vacated gated path" "$(grep -c 'skills/one/SKILL.md' /tmp/out.g2)" "1"

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

echo "case J: no origin/main and no local main branch -> usage error"
REPO="$WORK/j"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name test
git -C "$REPO" config commit.gpgsign false
git -C "$REPO" checkout -q -b trunk
write_file "$REPO" ".claude-plugin/plugin.json" '{"name": "fixture", "version": "0.1.0"}' "root: version 0.1.0, no main branch"
run_check "$REPO" >/tmp/out.j 2>&1
check "exit code" "$?" 2

echo "case K: a shallow clone -> usage error mentioning fetch-depth"
REPO="$WORK/k"
new_fixture "$REPO" 0.1.0
write_file "$REPO" "README.md" "docs" "docs: readme"
CLONE="$WORK/k-shallow"
git clone -q --depth 1 "file://$REPO" "$CLONE"
run_check "$CLONE" >/tmp/out.k 2>&1
check "exit code" "$?" 2
check "mentions fetch-depth" "$(grep -c 'fetch-depth' /tmp/out.k)" "1"

echo "case L: PR bumps version back to one main already published -> fail (reuse, not just 'unchanged')"
REPO="$WORK/l"
new_fixture "$REPO" 0.1.0
write_file "$REPO" "agents/published.md" "one" "agents: add published, pre-bump"
bump_version "$REPO" 0.2.0 "release: bump to 0.2.0"
fork_pr "$REPO"
write_file "$REPO" "agents/two.md" "two" "agents: add two"
bump_version "$REPO" 0.1.0 "release: revert version to 0.1.0"
run_check "$REPO" >/tmp/out.l 2>&1
check "exit code" "$?" 1
check "says it goes backwards, not merely unbumped" \
  "$(grep -c 'goes backwards' /tmp/out.l)" "1"

echo "case N: PR edits .claude-plugin/marketplace.json only, plugin.json untouched -> ok (marketplace.json isn't served)"
REPO="$WORK/n"
new_fixture "$REPO" 0.1.0
write_file "$REPO" ".claude-plugin/marketplace.json" '{"plugins": []}' "root: add marketplace.json"
fork_pr "$REPO"
{
  printf '{"plugins": [], "note": "renamed"}' > "$REPO/.claude-plugin/marketplace.json"
  git -C "$REPO" add .claude-plugin/marketplace.json
  git -C "$REPO" commit -qm "marketplace: edit listing"
}
run_check "$REPO" >/tmp/out.n 2>&1
check "exit code" "$?" 0

echo "case O: PR sets a version main once carried behind a merge-simplified commit, below main's tip -> fail (ordering against the base settles it, no history walk)"
REPO="$WORK/o"
new_fixture "$REPO" 0.1.0
bump_version "$REPO" 0.5.0 "release: bump to 0.5.0"
git -C "$REPO" checkout -q -b hotfix main~1
bump_version "$REPO" 0.9.0 "hotfix: bump to 0.9.0"
git -C "$REPO" checkout -q main
git -C "$REPO" merge --no-ff hotfix -m "merge hotfix, resolve to hotfix's 0.9.0" >/dev/null 2>&1 || true
printf '{\n  "name": "fixture",\n  "version": "0.9.0"\n}\n' > "$REPO/.claude-plugin/plugin.json"
git -C "$REPO" add .claude-plugin/plugin.json
git -C "$REPO" commit -q --no-edit
fork_pr "$REPO"
bump_version "$REPO" 0.5.0 "release: reuse 0.5.0 that main once carried"
run_check "$REPO" >/tmp/out.o 2>&1
check "exit code" "$?" 1
check "says it goes backwards" "$(grep -c 'goes backwards' /tmp/out.o)" "1"

echo "case M: two PRs off the same main tip each bump correctly, merged in turn -> resulting main is clean"
REPO="$WORK/m"
new_fixture "$REPO" 0.1.0
git -C "$REPO" checkout -q -b pr1 main
write_file "$REPO" "hooks/one.py" "print(1)" "hooks: add one"
bump_version "$REPO" 0.2.0 "release: bump to 0.2.0"
git -C "$REPO" checkout -q -b pr2 main
write_file "$REPO" "commands/two.md" "two" "commands: add two"
bump_version "$REPO" 0.3.0 "release: bump to 0.3.0"
git -C "$REPO" checkout -q main
git -C "$REPO" merge -q --no-ff pr1 -m "merge pr1"
# pr2 bumped from the same 0.1.0 fork point as pr1, so its plugin.json
# conflicts with pr1's on merge; a human resolves it by hand, so this
# fixture does too, keeping the higher version.
git -C "$REPO" merge --no-ff pr2 -m "merge pr2" >/dev/null 2>&1
printf '{\n  "name": "fixture",\n  "version": "0.3.0"\n}\n' > "$REPO/.claude-plugin/plugin.json"
git -C "$REPO" add .claude-plugin/plugin.json
git -C "$REPO" commit -q --no-edit
run_check "$REPO" >/tmp/out.m 2>&1
check "exit code" "$?" 0

echo "case P: PR adds a gated file whose path git C-quotes (embedded double quote), no bump -> fail"
REPO="$WORK/p"
new_fixture "$REPO" 0.1.0
fork_pr "$REPO"
write_file "$REPO" 'skills/one"two.md' "one" "skills: add a quoted path"
run_check "$REPO" >/tmp/out.p 2>&1
check "exit code" "$?" 1

echo "case Q: PR sets a version above main's tip that a discarded merge side once carried -> ok, merge topology does not matter to an ordering check"
REPO="$WORK/q"
new_fixture "$REPO" 0.1.0
bump_version "$REPO" 0.5.0 "release: bump to 0.5.0"
git -C "$REPO" checkout -q -b side main~1
bump_version "$REPO" 0.7.0 "side: bump to 0.7.0, never lands on main"
git -C "$REPO" checkout -q main
git -C "$REPO" merge --no-ff side -m "merge side, resolve to main's own 0.5.0" >/dev/null 2>&1 || true
printf '{\n  "name": "fixture",\n  "version": "0.5.0"\n}\n' > "$REPO/.claude-plugin/plugin.json"
git -C "$REPO" add .claude-plugin/plugin.json
git -C "$REPO" commit -q --no-edit
fork_pr "$REPO"
bump_version "$REPO" 0.7.0 "release: reuse 0.7.0, which main's tip never carried"
run_check "$REPO" >/tmp/out.q 2>&1
check "exit code" "$?" 0

echo "case R: PR sets a version main's tip published before main was fast-forwarded onto a branch that had merged it in -> fail (invisible to a first-parent walk, but still below the base)"
REPO="$WORK/r"
new_fixture "$REPO" 0.1.0
git -C "$REPO" checkout -q -b feature main
write_file "$REPO" "skills/f.md" "f" "skills: add f"
bump_version "$REPO" 0.4.0 "release: bump to 0.4.0"
git -C "$REPO" checkout -q main
write_file "$REPO" "skills/m.md" "m" "skills: add m"
bump_version "$REPO" 0.3.0 "release: bump to 0.3.0"
# main's tip sits at 0.3.0 here, so 0.3.0 is served to every install that
# updates now. The fast-forward below moves main off this commit without
# leaving it on the first-parent chain, which is what makes it invisible to
# any walk narrower than --full-history.
git -C "$REPO" checkout -q feature
git -C "$REPO" merge --no-ff main -m "update branch: merge main into feature" >/dev/null 2>&1 || true
printf '{\n  "name": "fixture",\n  "version": "0.4.0"\n}\n' > "$REPO/.claude-plugin/plugin.json"
git -C "$REPO" add .claude-plugin/plugin.json
git -C "$REPO" commit -q --no-edit
git -C "$REPO" checkout -q main
git -C "$REPO" merge -q --ff-only feature
fork_pr "$REPO"
write_file "$REPO" "skills/new.md" "new" "skills: add new"
bump_version "$REPO" 0.3.0 "release: reuse 0.3.0, which main's tip once served"
run_check "$REPO" >/tmp/out.r 2>&1
check "exit code" "$?" 1
check "says it goes backwards" "$(grep -c 'goes backwards' /tmp/out.r)" "1"

echo "case S: 0.9.0 -> 0.10.0 is an advance (a string compare would call it a regression)"
REPO="$WORK/s"
new_fixture "$REPO" 0.9.0
fork_pr "$REPO"
write_file "$REPO" "hooks/s.py" "s" "hooks: add s"
bump_version "$REPO" 0.10.0 "release: bump to 0.10.0"
run_check "$REPO" >/tmp/out.s 2>&1
check "exit code" "$?" 0

echo "case T: a version that is not dotted integers -> usage error, not a pass"
REPO="$WORK/t"
new_fixture "$REPO" 0.1.0
fork_pr "$REPO"
write_file "$REPO" "hooks/t.py" "t" "hooks: add t"
{
  printf '{\n  "name": "fixture",\n  "version": "1.0.0-rc1"\n}\n' > "$REPO/.claude-plugin/plugin.json"
  git -C "$REPO" add .claude-plugin/plugin.json
  git -C "$REPO" commit -qm "release: bump to a prerelease string"
}
run_check "$REPO" >/tmp/out.t 2>&1
check "exit code" "$?" 2
check "names the ordering problem" "$(grep -c 'dotted integers' /tmp/out.t)" "1"

echo ""
if [ "$failures" -eq 0 ]; then
  echo "OK (22 cases)"
else
  echo "FAILED: $failures assertion(s)"
  exit 1
fi
