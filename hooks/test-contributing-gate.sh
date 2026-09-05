#!/usr/bin/env bash
# Tests contributing-gate.py against real repos: an edit in a gated repo that
# ships a contribution guide is refused until the session transcript shows a Read
# of it. A gated repo with no guide, and an ungated repo, are never gated.
#
# The repos are built here rather than pointed at: scope is a marker file at the
# repo root, so the hook stats the filesystem and a fabricated path proves
# nothing.

set -uo pipefail

GATE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/contributing-gate.py"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

GUIDED="$TMP/guided"    # gated, ships a CONTRIBUTING.md
BARE="$TMP/bare"        # gated, no guide to read
UNGATED="$TMP/ungated"  # ships a guide but never opted in
for r in "$GUIDED" "$BARE" "$UNGATED"; do
  mkdir -p "$r/internal"
  git -C "$r" init -q
done
touch "$GUIDED/.crap-gated" "$BARE/.crap-gated"
printf 'Run the tests before opening a PR.\n' > "$GUIDED/CONTRIBUTING.md"
printf 'Run the tests before opening a PR.\n' > "$UNGATED/CONTRIBUTING.md"

printf '%s\n' '{"message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"'"$GUIDED"'/CONTRIBUTING.md"}}]}}' > "$TMP/read.jsonl"
printf '%s\n' '{"message":{"content":[{"type":"tool_use","name":"Grep","input":{"file_path":"'"$GUIDED"'/CONTRIBUTING.md"}}]}}' > "$TMP/grep.jsonl"
printf '%s\n' '{"message":{"content":[{"type":"tool_result","content":"contributing-gate: read '"$GUIDED"'/CONTRIBUTING.md first"}]}}' > "$TMP/echo.jsonl"

failures=0

# want: BLOCK (guide named on stderr) | ALLOW
expect() {
  local label="$1" want="$2" file="$3" transcript="${4:-$TMP/missing.jsonl}" rc=0 out got
  out="$(printf '{"transcript_path":"%s","tool_input":{"file_path":"%s"}}' \
          "$transcript" "$file" | python3 "$GATE" 2>&1)" || rc=$?
  if [ "$rc" -eq 0 ]; then
    got=ALLOW
  elif printf '%s' "$out" | grep -q 'contributing-gate:'; then
    got=BLOCK
  else
    got="OTHER($rc)"
  fi
  if [ "$got" = "$want" ]; then
    printf '  ok:   %-48s %s\n' "$label" "$got"
  else
    printf '  FAIL: %-48s got %s want %s\n' "$label" "$got" "$want"
    printf '        %s\n' "$out"
    failures=$((failures + 1))
  fi
}

echo "a repo with a guide gates its files until the guide is read"
expect "edit, guide unread"                BLOCK "$GUIDED/internal/app.go"
expect "write into a directory that does not exist yet" \
                                           BLOCK "$GUIDED/internal/new/pkg/app.go"
expect "edit, guide read this session"     ALLOW "$GUIDED/internal/app.go" "$TMP/read.jsonl"
expect "the guide itself is not gated"     ALLOW "$GUIDED/CONTRIBUTING.md"

echo "only a Read clears it"
expect "a Grep naming the path does not"   BLOCK "$GUIDED/internal/app.go" "$TMP/grep.jsonl"
expect "the block message quoting the path does not" \
                                           BLOCK "$GUIDED/internal/app.go" "$TMP/echo.jsonl"
expect "an unreadable transcript does not" BLOCK "$GUIDED/internal/app.go" "$TMP/nope.jsonl"

echo "a repo reached through a symlink is the same repo"
# find_guides works from git's toplevel, which is already resolved, while a Read
# records the spelling the agent used. Comparing them raw made the gate
# unclearable behind a symlink: reading the guide never counted.
ln -s "$GUIDED" "$TMP/link"
printf '%s\n' '{"message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"'"$TMP"'/link/CONTRIBUTING.md"}}]}}' > "$TMP/read-link.jsonl"
expect "unread, edit via the symlinked path"  BLOCK "$TMP/link/internal/app.go"
expect "guide read via the symlinked path"    ALLOW "$GUIDED/internal/app.go" "$TMP/read-link.jsonl"
expect "guide read via the real path"         ALLOW "$TMP/link/internal/app.go" "$TMP/read.jsonl"

echo "nothing to read, or no opt-in, means nothing to gate"
expect "gated repo with no guide"          ALLOW "$BARE/internal/app.go"
expect "guide present but repo not gated"  ALLOW "$UNGATED/internal/app.go"
expect "path in no repository at all"      ALLOW "$TMP/loose/scratch.go"
expect "no file_path in the tool input"    ALLOW ""

echo ""
if [ "$failures" -eq 0 ]; then
  echo "CONTRIBUTING GATE OK"
else
  echo "FAILED: $failures assertion(s)"
  exit 1
fi
