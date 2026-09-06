#!/usr/bin/env bash
# Refuse machine-specific and organisation-specific references in tracked files.
#
#   scripts/check-no-private-refs.sh [path...]     (default: every tracked file)
#
# This plugin was extracted from a personal Claude Code configuration, where
# every script lived at a fixed path under one home directory and the prose cited
# private repositories by name. Both classes are easy to reintroduce by copying a
# snippet back from that machine, and neither breaks any test: an absolute
# /Users/<someone> path simply fails for everybody else, and a private repo name
# is only wrong to the person who recognises it.
#
# The patterns here are deliberately generic. A list of the specific private
# names would have to contain them to grep for them, which would publish in this
# file exactly what it exists to keep out. Point TOUCHSTONE_PRIVATE_TERMS at a
# file of extra regexes (one per line, '#' comments allowed) to check names that
# should not be written down here.
#
# Exit 0 clean, 1 findings, 2 usage.

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

FILES=()
if [ "$#" -gt 0 ]; then
  FILES=("$@")
else
  while IFS= read -r f; do FILES+=("$f"); done < <(git ls-files)
fi
[ "${#FILES[@]}" -gt 0 ] || { echo "check-no-private-refs: no files to check" >&2; exit 2; }

STATUS=0

report() {
  local label="$1" advice="$2" hits="$3"
  [ -n "$hits" ] || return 0
  printf '\n== %s ==\n%s\n\n%s\n' "$label" "$advice" "$hits"
  STATUS=1
}

# This script names the patterns it looks for, so it would match itself on every
# rule. Excluded by path rather than by an inline marker, which would be one more
# thing to keep in sync.
scan() {
  grep -nEI "$1" "${FILES[@]}" 2>/dev/null \
    | grep -v '^scripts/check-no-private-refs\.sh:' || true
}

report "absolute home directory paths" \
  "Use a path relative to the repo, \${CLAUDE_PLUGIN_ROOT} in skill/agent/hook config, or resolve it from the script's own location." \
  "$(scan '/(Users|home)/[a-z][a-z0-9._-]*/')"

report "paths into a personal Claude Code config" \
  "A plugin must not read or write the installing user's config. Reference bundled files through \${CLAUDE_PLUGIN_ROOT} or relative to the script." \
  "$(scan '~/\.claude|\\\$HOME/\.claude')"

# The placeholders the docs and prompts are allowed to use. Anything else
# shaped like a tracker key is probably a real ticket copied from a private
# tracker: harmless alone, recognisable in aggregate.
report "ticket keys that are not the documented placeholders" \
  "Use PROJ-<n> or ABC-<n> in examples, or drop the key and keep the lesson." \
  "$(scan '\b[A-Z]{2,5}-[0-9]{1,6}\b' | grep -vE '\b(PROJ|ABC|MIT|RFC|UTF|SHA|API|JSON|HTTP|SQL|TODO|CI|PR)-' || true)"

# A cheap proxy for "an anecdote about a specific run on a specific system".
# Dates in prose were how the extracted skill cited private incidents.
report "dated incident references in prose" \
  "Keep the rule, drop the date and the system it happened on." \
  "$(scan '\(20[0-9]{2}-[0-9]{2}-[0-9]{2}\)')"

if [ -n "${TOUCHSTONE_PRIVATE_TERMS:-}" ]; then
  if [ ! -f "$TOUCHSTONE_PRIVATE_TERMS" ]; then
    echo "check-no-private-refs: TOUCHSTONE_PRIVATE_TERMS is not a readable file: $TOUCHSTONE_PRIVATE_TERMS" >&2
    exit 2
  fi
  # -f keeps the terms out of this process's argv, so they stay out of any CI
  # log that echoes commands.
  extra="$(grep -vE '^\s*(#|$)' "$TOUCHSTONE_PRIVATE_TERMS" \
    | grep -nEIif /dev/stdin "${FILES[@]}" 2>/dev/null \
    | grep -v '^scripts/check-no-private-refs\.sh:' || true)"
  report "terms from TOUCHSTONE_PRIVATE_TERMS" \
    "These came from your local term list." "$extra"
fi

if [ "$STATUS" -eq 0 ]; then
  echo "check-no-private-refs: clean (${#FILES[@]} files)"
fi
exit "$STATUS"
