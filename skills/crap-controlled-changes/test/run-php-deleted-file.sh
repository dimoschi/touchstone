#!/usr/bin/env bash
# A staged deletion must not be reported as a file the gate could not measure.
#
# `git diff --cached` lists deletions, so the old path of a removed or renamed
# file reaches the module. It cannot appear in a Clover report, because it is no
# longer in the working tree the suite runs against, so the could-not-measure
# check turned it into exit 4 and refused the commit. Both remedies that refusal
# prints ask for coverage of a file that no longer exists.
#
# The Python module already filters per phase (crap-check-python.sh's measure()
# keeps only paths that are still files), and per phase is the right scope: the
# baseline tree is at HEAD, where the deleted file does still exist.
#
# phpunit is stubbed, so this needs neither php nor a vendor tree.

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$SKILL_DIR/lib"

STUBS="$(mktemp -d)"
WORK="$(mktemp -d)"
trap 'rm -rf "$STUBS" "$WORK"' EXIT

printf '#!/bin/sh\nexit 0\n' > "$STUBS/phpunit"
chmod +x "$STUBS/phpunit"

failures=0
check() {
  if [ "$2" = "$3" ]; then
    echo "  ok:   $1"
  else
    echo "  FAIL: $1 (got '$2', want '$3')"
    failures=$((failures + 1))
  fi
}

commit() {
  GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
    git -c commit.gpgsign=false -c gpg.format=openpgp commit -q "$@"
}

REPO="$WORK/repo"
mkdir -p "$REPO/src"
git init -q "$REPO"
(
  cd "$REPO"
  cat > src/Gone.php <<'PHP'
<?php
class Gone { public function run(): int { return 1; } }
PHP
  git add src/Gone.php
  commit -m baseline
  git rm -q src/Gone.php
)

RC=0
OUT="$(cd "$REPO" && PATH="$STUBS:$PATH" PHPUNIT_BIN="$STUBS/phpunit" \
  bash "$LIB/crap-check-php.sh" 2>&1)" || RC=$?

printf '%s\n' "$OUT" | sed 's/^/    | /'

check "a staged deletion does not exit 4" "$RC" "0"
check "the deleted path is not reported as unmeasurable" \
  "$(printf '%s' "$OUT" | grep -c 'FAILED TO MEASURE' || true)" "0"
# The filter is per phase, not global: the baseline tree is stashed back to
# HEAD, where the file still exists, so its baseline note must survive. Losing
# it would mean the filter had been applied once for both phases.
check "the baseline phase still accounts for it" \
  "$(printf '%s' "$OUT" | grep -c 'baseline (HEAD) Clover report has no data' || true)" "1"

echo ""
if [ "$failures" -eq 0 ]; then
  echo "PHP DELETED FILE OK"
  exit 0
fi
echo "FAILED: $failures assertion(s)"
exit 1
