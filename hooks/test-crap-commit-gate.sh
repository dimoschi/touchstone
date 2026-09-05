#!/usr/bin/env bash
# Tests crap-commit-gate.py: a raw `git commit` aimed at a gated repo is refused
# and redirected to crap-commit.sh; everything else is left alone.
#
# Scope is now a marker file at the repo root, so these cases need real
# repositories rather than the string-matched paths this suite used when scope
# was a path prefix. GATED carries .crap-gated, PLAIN does not, and NOREPO is a
# directory that is not a repository at all.

set -uo pipefail

GATE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/crap-commit-gate.py"
WRAP="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/skills/crap-controlled-changes/crap-commit.sh"
K='commit'
failures=0

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
GATED="$TMP/gated"
PLAIN="$TMP/plain"
NOREPO="$TMP/norepo"
mkdir -p "$GATED" "$PLAIN" "$NOREPO"
git -C "$GATED" init -q
git -C "$PLAIN" init -q
touch "$GATED/.crap-gated"
# A linked worktree must resolve to the same repo root as its parent, so the
# marker applies there too. That is what repo_common_root exists for.
git -C "$GATED" -c commit.gpgsign=false -c user.email=t@t -c user.name=t \
  commit -q --allow-empty -m baseline
git -C "$GATED" worktree add -q "$TMP/gated-wt" -b wt 2>/dev/null
WT="$TMP/gated-wt"

# want: BLOCK (redirected to the wrapper) | ALLOW
expect() {
  local label="$1" want="$2" cwd="$3" cmd="$4" rc=0 out got
  out="$(printf '{"cwd":"%s","tool_input":{"command":"%s"}}' "$cwd" "$cmd" \
        | python3 "$GATE" 2>&1)" || rc=$?
  if [ "$rc" -eq 0 ]; then
    got=ALLOW
  elif printf '%s' "$out" | grep -q 'crap-commit.sh <absolute-repo-path>'; then
    got=BLOCK
  else
    got="OTHER($rc)"
  fi
  if [ "$got" = "$want" ]; then
    printf '  ok:   %-46s %s\n' "$label" "$got"
  else
    printf '  FAIL: %-46s got %s want %s\n' "$label" "$got" "$want"
    failures=$((failures + 1))
  fi
}

echo "raw commits aimed at a gated repo are refused"
expect "plain commit, session in the repo"   BLOCK "$GATED"  "git $K -m wip"
expect "cd into the repo from outside"       BLOCK "$TMP"    "cd $GATED && git $K -m wip"
expect "git -C <repo> from outside"          BLOCK "$TMP"    "git -C $GATED $K -m wip"
expect "subdirectory of a gated repo"        BLOCK "$TMP"    "cd $GATED/x && git $K -m wip"
expect "amend, session in the repo"          BLOCK "$GATED"  "git $K --amend --no-edit"
expect "linked worktree of a gated repo"     BLOCK "$WT"     "git $K -m wip"

echo "a raw commit cannot excuse itself by quoting the wrapper's name"
expect "message naming the wrapper"          BLOCK "$GATED"  "git $K -S -m \\\"do it like $WRAP would\\\""
expect "message naming the bare script"      BLOCK "$GATED"  "git $K -m \\\"see crap-commit.sh\\\""
expect "signing config injected inline"      BLOCK "$GATED"  "GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=user.signingkey git $K -m wip"
expect "comment mentioning the wrapper"      BLOCK "$GATED"  "git $K -m wip # $WRAP refused"

echo "the sanctioned path and ungated work are untouched"
expect "the wrapper itself"                  ALLOW "$TMP"    "$WRAP $GATED -m wip"
expect "wrapper, message quoting the words"  ALLOW "$TMP"    "$WRAP $GATED -m \\\"fix git $K parsing\\\""
expect "repo without the marker"             ALLOW "$PLAIN"  "git $K -m wip"
expect "cd into a repo without the marker"   ALLOW "$TMP"    "cd $PLAIN && git $K -m wip"
expect "directory that is not a repo"        ALLOW "$NOREPO" "git $K -m wip"
expect "not a commit at all"                 ALLOW "$GATED"  "git status"

echo ""
if [ "$failures" -eq 0 ]; then
  echo "CRAP COMMIT GATE OK"
else
  echo "FAILED: $failures assertion(s)"
  exit 1
fi
