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
# Exit 0 clean, 1 a gated file changed without a bump (or the bump reuses a
# version already published on main), 2 usage (missing manifest, no version
# key, no origin/main or main to compare against, or a shallow clone).

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

MANIFEST=".claude-plugin/plugin.json"
# Trailing slash so a prefix match never catches a sibling like .github/workflows/
# or a hypothetical hooks-extra/. .claude-plugin/ is included because the
# manifest itself ships to every install (mcpServers, hooks, description),
# not just the five directories it points at.
GATED_PREFIXES=("workflows/" "hooks/" "skills/" "agents/" "commands/" ".claude-plugin/")

version_at() {
  git show "$1:$MANIFEST" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])' 2>/dev/null
}

file_exists_at() {
  git cat-file -e "$1:$MANIFEST" 2>/dev/null
}

is_gated() {
  local f="$1" prefix
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

# A shallow clone can silently truncate the "which versions has main already
# published" scan below rather than fail it outright, so refuse it up front
# instead of trusting a partial answer.
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
CHANGED=()
while IFS= read -r f; do
  is_gated "$f" && CHANGED+=("$f")
done < <(git diff --no-renames --name-only "$BASE" HEAD)

if [ "${#CHANGED[@]}" -eq 0 ]; then
  echo "check-version-bump: ok (nothing gated changed since $BASE_REF at $(git rev-parse --short "$BASE"))"
  exit 0
fi

BASE_VERSION="$(version_at "$BASE" 2>/dev/null || true)"

if [ "$CURRENT_VERSION" = "$BASE_VERSION" ]; then
  {
    echo "check-version-bump: $MANIFEST is still at $CURRENT_VERSION while these files changed since $BASE_REF at $(git rev-parse --short "$BASE"):"
    printf '  %s\n' "${CHANGED[@]}"
    echo "\`claude plugin update\` compares that version string, not the commit, so every install keeps serving the cached $CURRENT_VERSION copy."
    echo "Bump the version (patch for a fix, minor for behaviour) in this PR."
  } >&2
  exit 1
fi

# The bump itself has to be new: reusing a version main has already shipped,
# under different content, serves that old cached copy, same as not bumping.
while IFS= read -r c; do
  v="$(version_at "$c")" || continue
  if [ "$v" = "$CURRENT_VERSION" ]; then
    {
      echo "check-version-bump: $MANIFEST bumped to $CURRENT_VERSION, but that version was already published at $(git rev-parse --short "$c") for different content:"
      printf '  %s\n' "${CHANGED[@]}"
      echo "installs cached under $CURRENT_VERSION keep serving that old copy, not this change. Pick a version nobody has shipped yet."
    } >&2
    exit 1
  fi
done < <(git rev-list "$BASE_REF" -- "$MANIFEST")

echo "check-version-bump: ok ($MANIFEST bumped to $CURRENT_VERSION, covers everything changed since $BASE_REF at $(git rev-parse --short "$BASE"))"
exit 0
