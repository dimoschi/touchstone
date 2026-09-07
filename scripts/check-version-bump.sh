#!/usr/bin/env bash
# Refuse a change that touches a plugin-served directory without moving
# `version` in .claude-plugin/plugin.json, scoped to what this PR (or push)
# actually introduces.
#
#   scripts/check-version-bump.sh
#
# `claude plugin update` compares that version string against the cache, not
# the commit history: a gated file can change on main and every existing
# install keeps serving the old cached copy until the string moves. This does
# not cover `claude plugin tag`, which already checks plugin.json against the
# marketplace entry.
#
# The comparison is against origin/main (falling back to a local `main`
# branch when there is no origin), not "the last commit anywhere in history
# that touched version": anchoring on history let an unrelated sibling
# branch's bump, or a later commit on the same PR, decide whether *this*
# change needs one. Comparing against the fork point instead answers "did
# this change bump the version", nothing upstream of it. A push straight to
# main compares main against itself and is a deliberate no-op: it exists to
# gate PRs, not to catch a bypass of the PR process.
#
# Exit 0 clean, 1 a gated file changed without the version advancing past the
# base's, 2 usage (missing manifest, no version key, a version that is not
# dotted integers, no origin/main or main to compare against, or a shallow
# clone).

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

MANIFEST=".claude-plugin/plugin.json"
# Trailing slash so a prefix match never catches a sibling like .github/workflows/
# or a hypothetical hooks-extra/.
GATED_PREFIXES=("workflows/" "hooks/" "skills/" "agents/" "commands/")

version_at() {
  git show "$1:$MANIFEST" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])' 2>/dev/null
}

file_exists_at() {
  git cat-file -e "$1:$MANIFEST" 2>/dev/null
}

is_gated() {
  local f="$1" prefix
  # The manifest itself, not the whole .claude-plugin/ directory: it ships to
  # every install (mcpServers, hooks, description) same as the five gated
  # dirs, but .claude-plugin/marketplace.json is the marketplace index, not
  # part of what an install fetches, so gating the directory would demand a
  # bump for a file the plugin never serves.
  [ "$f" = "$MANIFEST" ] && return 0
  for prefix in "${GATED_PREFIXES[@]}"; do
    case "$f" in
      "$prefix"*) return 0 ;;
    esac
  done
  return 1
}

if ! file_exists_at HEAD; then
  echo "check-version-bump: no $MANIFEST at HEAD" >&2
  exit 2
fi

CURRENT_VERSION="$(version_at HEAD)" || {
  echo "check-version-bump: $MANIFEST at HEAD has no readable \"version\"" >&2
  exit 2
}

# A shallow clone can put the merge base below the graft point, so `git
# merge-base` silently returns a later commit and the diff range narrows to
# fewer files than the PR really changed. Refuse up front rather than pass on a
# partial answer.
if [ "$(git rev-parse --is-shallow-repository)" = "true" ]; then
  echo "check-version-bump: shallow clone, cannot compare against origin/main reliably (run with full history: fetch-depth: 0)" >&2
  exit 2
fi

BASE_REF=""
for ref in origin/main main; do
  if git rev-parse -q --verify "$ref" >/dev/null 2>&1; then
    BASE_REF="$ref"
    break
  fi
done

if [ -z "$BASE_REF" ]; then
  echo "check-version-bump: no origin/main or main to compare against" >&2
  exit 2
fi

BASE="$(git merge-base "$BASE_REF" HEAD)" || {
  echo "check-version-bump: HEAD and $BASE_REF share no common history" >&2
  exit 2
}

# --no-renames: a detected rename prints only the destination path, so
# moving a gated file out of a gated directory (skills/x/SKILL.md ->
# docs/x.md) would otherwise report no gated change at all.
# -z, read -d '': default --name-only quotes a path with a non-ASCII byte,
# quote or backslash, which would defeat every match below. NUL-delimited
# output is never quoted.
CHANGED=()
while IFS= read -r -d '' f; do
  is_gated "$f" && CHANGED+=("$f")
done < <(git diff --no-renames --name-only -z "$BASE" HEAD)

if [ "${#CHANGED[@]}" -eq 0 ]; then
  echo "check-version-bump: ok (nothing gated changed since $BASE_REF at $(git rev-parse --short "$BASE"))"
  exit 0
fi

BASE_VERSION="$(version_at "$BASE" 2>/dev/null || true)"

# Forward, not merely different: an increase cannot reuse a string an install
# already cached, so no walk over what main has published is needed, and no
# question of which walk is the right one. Dotted integers only, because a
# string compare would call 0.10.0 older than 0.9.0.
version_advances() {
  python3 - "$1" "$2" <<'PY'
import re, sys

def parse(v):
    if not re.fullmatch(r'\d+(\.\d+)*', v):
        sys.exit(3)
    return [int(p) for p in v.split('.')]

base, current = sys.argv[1], sys.argv[2]
cur = parse(current)
sys.exit(0 if not base else (0 if cur > parse(base) else 1))
PY
}

RC=0
version_advances "$BASE_VERSION" "$CURRENT_VERSION" || RC=$?

if [ "$RC" -eq 3 ]; then
  echo "check-version-bump: version '$CURRENT_VERSION' (or base '$BASE_VERSION') is not dotted integers, so the two cannot be ordered" >&2
  exit 2
fi

if [ "$RC" -ne 0 ]; then
  if [ "$CURRENT_VERSION" = "$BASE_VERSION" ]; then
    HEADLINE="$MANIFEST is still at $CURRENT_VERSION while these files changed since $BASE_REF at $(git rev-parse --short "$BASE"):"
    HINT="Bump the version (patch for a fix, minor for behaviour) in this PR."
  else
    HEADLINE="$MANIFEST goes backwards, $BASE_VERSION at $BASE_REF down to $CURRENT_VERSION here, while these files changed:"
    HINT="Raise the version above $BASE_VERSION (patch for a fix, minor for behaviour) in this PR."
  fi
  {
    echo "check-version-bump: $HEADLINE"
    printf '  %s\n' "${CHANGED[@]}"
    echo "\`claude plugin update\` compares that version string, not the commit, so an install that cached $CURRENT_VERSION keeps serving that copy rather than this change."
    echo "$HINT"
  } >&2
  exit 1
fi

echo "check-version-bump: ok ($MANIFEST advances ${BASE_VERSION:-none} -> $CURRENT_VERSION, covers everything changed since $BASE_REF at $(git rev-parse --short "$BASE"))"
exit 0
