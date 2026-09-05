#!/usr/bin/env bash
# ignored-files.sh: shared diagnostic for gitignored files that contaminate a
# measurement phase. Sourced by the per-language modules; not executable alone.
#
# An over-broad ignore rule (an unanchored `foo` in .gitignore also matches the
# directory foo/) can hide generated code that the sources need to build. Either
# baseline mechanism then breaks, in opposite ways, so the note is parameterised:
#
#   stash (php, python): `--include-untracked` does not stash ignored files (that
#     needs --all), so the baseline builds HEAD's sources against the CURRENT
#     tree's generated code, and that mixture may not compile.
#   worktree (go): a detached HEAD worktree has no ignored files at all, so
#     generated code the tracked sources need is simply missing.
#
# php and python cannot use a worktree: they run their suites in-tree and need
# vendor/ and .venv/, both gitignored, so a fresh checkout cannot measure.
#
# We deliberately neither stash --all nor copy ignored files in: that would hide
# the underlying problem (generated code that ought to be tracked), and moving
# build caches, vendored trees and .env files is slow and risks losing them.

IGNORED_FILES_CAP=20
IGNORED_FILES=()

# Shared phase labels. Only the baseline phase is contaminated by ignored
# files, so only that phase collects them.
PHASE_BASELINE="baseline (HEAD)"
PHASE_CURRENT="current (working tree, staged changes applied)"

# Call once per phase with that phase's label; anything but the baseline clears
# the list, so a later phase cannot inherit the baseline's findings.
# Callers pass their language's dependency directory as an exclude pathspec:
# vendor/ and .venv/ are ignored by design and would bury the signal.
collect_ignored_files() {
  local phase="$1"
  shift
  IGNORED_FILES=()
  [ "$phase" = "$PHASE_BASELINE" ] || return 0
  mapfile -t IGNORED_FILES < <(
    git ls-files --others --ignored --exclude-standard -- "$@" 2>/dev/null || true
  )
}

ignored_files_phase_suffix() {
  local n="${#IGNORED_FILES[@]}"
  [ "$n" -gt 0 ] || return 0
  if [ "$n" -eq 1 ]; then
    printf ' + 1 ignored file from working tree'
  else
    printf ' + %d ignored files from working tree' "$n"
  fi
}

# $1 optionally replaces the mechanism sentence, for modules that take their
# baseline in a worktree rather than by stashing.
ignored_files_note() {
  local n="${#IGNORED_FILES[@]}"
  [ "$n" -gt 0 ] || return 0
  if [ -n "${1:-}" ]; then
    echo "  NOTE: $n file(s) in the working tree are gitignored. $1"
  else
    echo "  NOTE: $n file(s) in the working tree are gitignored, so"
    echo "  \`git stash push --include-untracked\` did NOT stash them (that needs"
    echo "  --all). They are still present from the CURRENT tree and may be why"
    echo "  this phase does not build:"
  fi
  printf '    %s\n' "${IGNORED_FILES[@]:0:$IGNORED_FILES_CAP}"
  if [ "$n" -gt "$IGNORED_FILES_CAP" ]; then
    echo "    ... and $((n - IGNORED_FILES_CAP)) more"
  fi
  echo "  If they are generated (mocks, sqlc, protobuf), they probably should be"
  echo "  tracked. Check for an unanchored .gitignore rule: a bare \`foo\` intended"
  echo "  for a build binary also matches every file under a directory named foo/."
  echo ""
}
