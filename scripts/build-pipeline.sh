#!/usr/bin/env bash
# Builds workflows/deliver-pipeline.js from workflows/parts/*.js.part.
#
# The Workflow host requires the script to be one self-contained file (no
# imports, see docs/architecture.md), so the built file has to stay
# committed even though it is generated: what a source part gains in staying
# under about 800 lines, the built file has to give up, and there is no way
# to have both without a build step in between.
#
#   scripts/build-pipeline.sh          builds workflows/deliver-pipeline.js
#   scripts/build-pipeline.sh --check  exits 1 if the committed file is stale
#
# Parts are concatenated in LC_ALL=C sorted order, which is why they are
# named NN-<area>.js.part: the numeric prefix is the only thing that decides
# where a part lands in the built file.
#
# Exit 0 built (or, under --check, already up to date). Exit 1 under --check
# when the committed file or a part disagrees with a fresh build. Exit 2 when
# no parts are found.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PARTS_DIR="$REPO_ROOT/workflows/parts"
OUT="$REPO_ROOT/workflows/deliver-pipeline.js"

shopt -s nullglob
parts=($(cd "$PARTS_DIR" 2>/dev/null && LC_ALL=C printf '%s\n' *.js.part | LC_ALL=C sort))
shopt -u nullglob

if [ "${#parts[@]}" -eq 0 ]; then
  echo "build-pipeline: no workflows/parts/*.js.part found" >&2
  exit 2
fi

build_to() {
  local dest="$1" p
  : > "$dest"
  for p in "${parts[@]}"; do
    cat "$PARTS_DIR/$p" >> "$dest"
  done
}

if [ "${1:-}" = "--check" ]; then
  TMP="$(mktemp)"
  trap 'rm -f "$TMP"' EXIT
  build_to "$TMP"
  if ! cmp -s "$TMP" "$OUT"; then
    echo "build-pipeline: $OUT is stale; run scripts/build-pipeline.sh" >&2
    exit 1
  fi
  echo "build-pipeline: ok ($OUT matches ${#parts[@]} part(s))"
  exit 0
fi

build_to "$OUT"
echo "build-pipeline: wrote $OUT from ${#parts[@]} part(s)"
