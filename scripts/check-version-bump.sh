#!/usr/bin/env bash
# Refuse a change that touches a plugin-served directory without moving
# `version` in .claude-plugin/plugin.json.
#
#   scripts/check-version-bump.sh
#
# `claude plugin update` compares that version string against the cache, not
# the commit history: a gated file can change on main and every existing
# install keeps serving the old cached copy until the string moves. This does
# not cover `claude plugin tag`, which already checks plugin.json against the
# marketplace entry.
#
# Exit 0 clean, 1 a gated file changed since the last bump, 2 usage (missing
# manifest, no version key, no version-changing commit reachable, or a
# shallow clone that cannot see one).

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

# A shallow graft and a real root both fail `rev-parse "$c^"`; only the
# shallow file tells them apart, since a graft's parent existed but is unseen.
SHALLOW_BOUNDARIES=""
if [ "$(git rev-parse --is-shallow-repository)" = "true" ]; then
  shallow_file="$(git rev-parse --git-path shallow)"
  [ -f "$shallow_file" ] && SHALLOW_BOUNDARIES="$(cat "$shallow_file")"
fi

is_shallow_boundary() {
  [ -n "$SHALLOW_BOUNDARIES" ] && printf '%s\n' "$SHALLOW_BOUNDARIES" | grep -qxF "$1"
}

V=""
while IFS= read -r c; do
  if git rev-parse -q --verify "$c^" >/dev/null 2>&1; then
    parent="$(git rev-parse "$c^")"
    if ! file_exists_at "$parent"; then
      V="$c"
      break
    fi
    if v_c="$(version_at "$c")" && v_p="$(version_at "$parent")" && [ "$v_c" != "$v_p" ]; then
      V="$c"
      break
    fi
  elif is_shallow_boundary "$c"; then
    # History truncated right here: cannot tell whether an earlier commit
    # changed the version, so this cannot count as one.
    break
  else
    # Root commit: the file has no prior version to differ from, so its
    # own version counts as the last change.
    V="$c"
    break
  fi
done < <(git rev-list HEAD -- "$MANIFEST")

if [ -z "$V" ]; then
  msg="check-version-bump: no version-changing commit for $MANIFEST reachable from HEAD"
  if [ "$(git rev-parse --is-shallow-repository)" = "true" ]; then
    msg="$msg (run with full history: fetch-depth: 0)"
  fi
  echo "$msg" >&2
  exit 2
fi

CHANGED=()
while IFS= read -r f; do
  is_gated "$f" && CHANGED+=("$f")
done < <(git diff --name-only "$V" HEAD)

if [ "${#CHANGED[@]}" -eq 0 ]; then
  echo "check-version-bump: ok ($MANIFEST at $CURRENT_VERSION covers everything changed since $(git rev-parse --short "$V"))"
  exit 0
fi

{
  echo "check-version-bump: $MANIFEST is still at $CURRENT_VERSION while these files changed since $(git rev-parse --short "$V"):"
  printf '  %s\n' "${CHANGED[@]}"
  echo "\`claude plugin update\` compares that version string, not the commit, so every install keeps serving the cached $CURRENT_VERSION copy."
  echo "Bump the version (patch for a fix, minor for behaviour) in the same commit."
} >&2
exit 1
