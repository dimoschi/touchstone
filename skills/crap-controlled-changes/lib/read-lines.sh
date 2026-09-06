#!/usr/bin/env bash
# read_lines: fill an array variable from stdin, one element per non-empty line.
#
# Sourced rather than repeated: nine call sites all wanted the same
# read-and-filter, and nine copies drift.
#
#   read_lines ARR < <(git ls-files)
#   read_lines ARR <<< "$SOME_STRING"
#
# Empty lines are dropped, so an empty input yields an empty array rather than
# mapfile's one-empty-string array. Callers testing "${#ARR[@]}" -eq 0 therefore
# need no second check for a single blank element.

read_lines() {
  local __name="$1" __line
  eval "$__name=()"
  # `|| [ -n "$__line" ]` keeps a final line with no trailing newline, which
  # plain `read` reports as failure after assigning it. mapfile -t keeps it too,
  # and dropping it would silently shorten a file list.
  while IFS= read -r __line || [ -n "$__line" ]; do
    [ -n "$__line" ] || continue
    eval "$__name+=(\"\$__line\")"
  done
}
