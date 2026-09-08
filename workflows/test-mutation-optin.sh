#!/usr/bin/env bash
# Regression test for deliver-pipeline.js's mutation opt-in probe.
#
# Two things can silently drop or wrongly impose the mutation gate:
#
#   1. The repo-root command. The probe runs inside a linked worktree, where
#      `git rev-parse --show-toplevel` names the worktree and not the repo the
#      marker lives in. The prompt specifies --git-common-dir for that reason,
#      so the difference is asserted here rather than trusted.
#   2. The skip decision. `gateProbe?.mutation_gated !== false` must treat every
#      answer except a confirmed false as gated, so a probe that fails or omits
#      the field costs a mutation run instead of dropping the gate.
#
# Needs git and node. Exit 0 all green, 1 any assertion failed.

set -uo pipefail

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

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

MAIN="$WORK/main"
mkdir -p "$MAIN"
git -C "$MAIN" init -q
git -C "$MAIN" config user.email test@example.com
git -C "$MAIN" config user.name test
git -C "$MAIN" config commit.gpgsign false
echo seed > "$MAIN/seed.txt"
git -C "$MAIN" add seed.txt
git -C "$MAIN" commit -qm baseline
WT="$MAIN/.claude/worktrees/probe"
git -C "$MAIN" worktree add -q "$WT" -b feat/probe

# The probe's own instruction, verbatim: resolve the repo root, then test for the
# marker there.
probe() (
  cd "$1" || exit 1
  root="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")"
  if [ -f "$root/.mutation-gated" ]; then echo true; else echo false; fi
)

echo "case A: no marker anywhere"
check "main checkout reports ungated" "$(probe "$MAIN")" false
check "worktree reports ungated"      "$(probe "$WT")"   false

echo "case B: marker at the repo root"
touch "$MAIN/.mutation-gated"
check "main checkout reports gated" "$(probe "$MAIN")" true
check "worktree reports gated"      "$(probe "$WT")"   true

echo "case C: --show-toplevel would have missed it from the worktree"
# Guards the prompt's choice of flag: if this ever agrees with --git-common-dir,
# the distinction the probe depends on has gone and case B proves nothing.
toplevel="$(cd "$WT" && git rev-parse --show-toplevel)"
common="$(cd "$WT" && dirname "$(git rev-parse --path-format=absolute --git-common-dir)")"
check "the two paths differ" "$([ "$toplevel" != "$common" ] && echo yes || echo no)" yes
check "a marker lookup under toplevel finds nothing" \
  "$([ -f "$toplevel/.mutation-gated" ] && echo true || echo false)" false

echo "case D: a marker only in the worktree does not opt the repo in"
# The worktree is disposable and per-run; a marker dropped there would gate one
# run and vanish, which reads as a flaky gate.
rm -f "$MAIN/.mutation-gated"
touch "$WT/.mutation-gated"
check "worktree-only marker reports ungated" "$(probe "$WT")" false
rm -f "$WT/.mutation-gated"

echo "case E: the skip decision over every probe outcome"
# Mirrors the script's `gateProbe?.mutation_gated !== false`. Exits 1 on any
# mismatch, so the assertion is the status rather than parsed output.
node --input-type=module -e '
const decide = p => (p?.mutation_gated !== false)
const cases = [
  [{mutation_gated: true,  detail: "x"}, true],
  [{mutation_gated: false, detail: "x"}, false],
  [{},                                   true],
  [null,                                 true],
  [undefined,                            true],
]
process.exit(cases.every(([probe, want]) => decide(probe) === want) ? 0 : 1)
'
check "every non-false outcome runs the gate" "$?" 0

echo ""
if [ "$failures" -eq 0 ]; then
  echo "OK (5 cases)"
else
  echo "FAILED: $failures assertion(s)"
  exit 1
fi
