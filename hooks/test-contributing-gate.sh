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
RECORDER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/copilot_session_evidence.py"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
STATE="$TMP/state"
export TOUCHSTONE_HOOK_STATE_DIR="$STATE"

GUIDED="$TMP/guided"    # gated, ships a CONTRIBUTING.md
BARE="$TMP/bare"        # gated, no guide to read
UNGATED="$TMP/ungated"  # ships a guide but never opted in
MULTI="$TMP/multi"      # gated, ships multiple guides
for r in "$GUIDED" "$BARE" "$UNGATED" "$MULTI"; do
  mkdir -p "$r/internal"
  git -C "$r" init -q
done
touch "$GUIDED/.crap-gated" "$BARE/.crap-gated" "$MULTI/.crap-gated"
printf 'Run the tests before opening a PR.\n' > "$GUIDED/CONTRIBUTING.md"
printf '# guided\n' > "$GUIDED/README.md"
printf 'Run the tests before opening a PR.\n' > "$UNGATED/CONTRIBUTING.md"
mkdir -p "$MULTI/docs"
printf 'Read the main guide first.\n' > "$MULTI/CONTRIBUTING.md"
printf 'Read the deeper development guide too.\n' > "$MULTI/docs/DEVELOPMENT.md"

printf '%s\n' '{"message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"'"$GUIDED"'/CONTRIBUTING.md"}}]}}' > "$TMP/read.jsonl"
printf '%s\n' '{"message":{"content":[{"type":"tool_use","name":"Grep","input":{"file_path":"'"$GUIDED"'/CONTRIBUTING.md"}}]}}' > "$TMP/grep.jsonl"
printf '%s\n' '{"message":{"content":[{"type":"tool_result","content":"contributing-gate: read '"$GUIDED"'/CONTRIBUTING.md first"}]}}' > "$TMP/echo.jsonl"
printf '%s\n%s\n' \
  '{"message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"'"$MULTI"'/CONTRIBUTING.md"}}]}}' \
  '{"message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"'"$MULTI"'/docs/DEVELOPMENT.md"}}]}}' \
  > "$TMP/multi-read.jsonl"

failures=0

# want: BLOCK (guide named on stderr) | ALLOW
expect_payload() {
  local label="$1" want="$2" payload="$3" rc=0 out got
  out="$(printf '%s' "$payload" | python3 "$GATE" 2>&1)" || rc=$?
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

expect_detail() {
  local label="$1" needle="$2" payload="$3" rc=0 out
  out="$(printf '%s' "$payload" | python3 "$GATE" 2>&1)" || rc=$?
  if [ "$rc" -ne 2 ] || ! printf '%s' "$out" | grep -Fq "$needle"; then
    printf '  FAIL: %-48s missing %s\n' "$label" "$needle"
    printf '        rc=%s %s\n' "$rc" "$out"
    failures=$((failures + 1))
    return
  fi
  printf '  ok:   %-48s BLOCK\n' "$label"
}

expect_detail_without_state_dir() {
  local label="$1" needle="$2" payload="$3" rc=0 out
  out="$(printf '%s' "$payload" | env -u TOUCHSTONE_HOOK_STATE_DIR python3 "$GATE" 2>&1)" || rc=$?
  if [ "$rc" -ne 2 ] || ! printf '%s' "$out" | grep -Fq "$needle"; then
    printf '  FAIL: %-48s missing %s\n' "$label" "$needle"
    printf '        rc=%s %s\n' "$rc" "$out"
    failures=$((failures + 1))
    return
  fi
  printf '  ok:   %-48s BLOCK\n' "$label"
}

legacy_payload() {
  python3 - "$1" "$2" <<'PY'
import json
import sys

transcript, file_path = sys.argv[1:3]
payload = {
    "transcript_path": transcript,
    "tool_input": {"file_path": file_path},
}
json.dump(payload, sys.stdout)
PY
}

copilot_pre_payload() {
  python3 - "$1" "$2" "$3" "$4" <<'PY'
import json
import sys

session_id, cwd, tool_name, file_path = sys.argv[1:5]
payload = {
    "hook_event_name": "PreToolUse",
    "session_id": session_id,
    "cwd": cwd,
    "tool_name": tool_name,
    "tool_input": {},
}
if file_path != "__MISSING__":
    payload["tool_input"]["file_path"] = file_path
json.dump(payload, sys.stdout)
PY
}

copilot_post_payload() {
  python3 - "$1" "$2" "$3" "$4" "$5" <<'PY'
import json
import sys

session_id, cwd, tool_name, file_path, result_type = sys.argv[1:6]
payload = {
    "hook_event_name": "PostToolUse",
    "session_id": session_id,
    "cwd": cwd,
    "tool_name": tool_name,
    "tool_input": {},
    "tool_result": {"result_type": result_type},
}
if file_path != "__MISSING__":
    payload["tool_input"]["file_path"] = file_path
json.dump(payload, sys.stdout)
PY
}

record_post() {
  local payload="$1"
  printf '%s' "$payload" | python3 "$RECORDER"
}

echo "a repo with a guide gates its files until the guide is read"
expect_payload "edit, guide unread"                BLOCK "$(legacy_payload "$TMP/missing.jsonl" "$GUIDED/internal/app.go")"
expect_payload "write into a directory that does not exist yet" \
                                           BLOCK "$(legacy_payload "$TMP/missing.jsonl" "$GUIDED/internal/new/pkg/app.go")"
expect_payload "edit, guide read this session"     ALLOW "$(legacy_payload "$TMP/read.jsonl" "$GUIDED/internal/app.go")"
expect_payload "the guide itself is not gated"     ALLOW "$(legacy_payload "$TMP/missing.jsonl" "$GUIDED/CONTRIBUTING.md")"

echo "only a Read clears it"
expect_payload "a Grep naming the path does not"   BLOCK "$(legacy_payload "$TMP/grep.jsonl" "$GUIDED/internal/app.go")"
expect_payload "the block message quoting the path does not" \
                                           BLOCK "$(legacy_payload "$TMP/echo.jsonl" "$GUIDED/internal/app.go")"
expect_payload "an unreadable transcript does not" BLOCK "$(legacy_payload "$TMP/nope.jsonl" "$GUIDED/internal/app.go")"

echo "multiple guides must all be read"
expect_payload "legacy transcript missing one guide" \
                                           BLOCK "$(legacy_payload "$TMP/read.jsonl" "$MULTI/internal/app.go")"
expect_payload "legacy transcript reading both guides" \
                                           ALLOW "$(legacy_payload "$TMP/multi-read.jsonl" "$MULTI/internal/app.go")"

echo "a repo reached through a symlink is the same repo"
# find_guides works from git's toplevel, which is already resolved, while a Read
# records the spelling the agent used. Comparing them raw made the gate
# unclearable behind a symlink: reading the guide never counted.
ln -s "$GUIDED" "$TMP/link"
printf '%s\n' '{"message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"'"$TMP"'/link/CONTRIBUTING.md"}}]}}' > "$TMP/read-link.jsonl"
expect_payload "unread, edit via the symlinked path"  BLOCK "$(legacy_payload "$TMP/missing.jsonl" "$TMP/link/internal/app.go")"
expect_payload "guide read via the symlinked path"    ALLOW "$(legacy_payload "$TMP/read-link.jsonl" "$GUIDED/internal/app.go")"
expect_payload "guide read via the real path"         ALLOW "$(legacy_payload "$TMP/read.jsonl" "$TMP/link/internal/app.go")"

echo "copilot guide evidence is session-specific and path-specific"
record_post "$(copilot_post_payload copilot-same "$GUIDED" Read CONTRIBUTING.md success)"
expect_payload "same session after post Read allows" \
                                           ALLOW "$(copilot_pre_payload copilot-same "$GUIDED" Edit internal/app.go)"
expect_payload "same session allows multiple edits" \
                                           ALLOW "$(copilot_pre_payload copilot-same "$GUIDED" Write internal/second.go)"
expect_payload "different session still blocks" \
                                           BLOCK "$(copilot_pre_payload copilot-other "$GUIDED" Edit internal/app.go)"
record_post "$(copilot_post_payload copilot-grep "$GUIDED" Grep CONTRIBUTING.md success)"
expect_payload "copilot Grep does not count" \
                                           BLOCK "$(copilot_pre_payload copilot-grep "$GUIDED" Edit internal/app.go)"
record_post "$(copilot_post_payload copilot-failed "$GUIDED" Read CONTRIBUTING.md error)"
expect_payload "copilot failed Read does not count" \
                                           BLOCK "$(copilot_pre_payload copilot-failed "$GUIDED" Edit internal/app.go)"
record_post "$(copilot_post_payload copilot-wrong "$GUIDED" Read README.md success)"
expect_payload "copilot wrong path does not count" \
                                           BLOCK "$(copilot_pre_payload copilot-wrong "$GUIDED" Edit internal/app.go)"
expect_detail "copilot missing path denies" "tool_input.file_path" \
                                           "$(copilot_pre_payload copilot-missing "$GUIDED" Edit __MISSING__)"

echo "copilot resolves relative paths and preserves symlink equivalence"
record_post "$(copilot_post_payload copilot-relative "$GUIDED" Read CONTRIBUTING.md success)"
expect_payload "copilot relative cwd read allows relative edit" \
                                           ALLOW "$(copilot_pre_payload copilot-relative "$GUIDED" MultiEdit internal/app.go)"
record_post "$(copilot_post_payload copilot-link "$TMP/link" Read CONTRIBUTING.md success)"
expect_payload "copilot symlink guide read counts for real path edit" \
                                           ALLOW "$(copilot_pre_payload copilot-link "$GUIDED" Edit internal/app.go)"
expect_payload "copilot real-path guide read counts for symlink edit" \
                                           ALLOW "$(copilot_pre_payload copilot-same "$TMP/link" Edit internal/app.go)"

echo "copilot evidence honors multiple guides and invalid state is observable"
record_post "$(copilot_post_payload copilot-multi "$MULTI" Read CONTRIBUTING.md success)"
expect_payload "copilot blocks until every guide is read" \
                                           BLOCK "$(copilot_pre_payload copilot-multi "$MULTI" Edit internal/app.go)"
record_post "$(copilot_post_payload copilot-multi "$MULTI" Read docs/DEVELOPMENT.md success)"
expect_payload "copilot allows once every guide is read" \
                                           ALLOW "$(copilot_pre_payload copilot-multi "$MULTI" Edit internal/app.go)"
expect_detail_without_state_dir "copilot missing state dir denies" "TOUCHSTONE_HOOK_STATE_DIR" \
                                           "$(copilot_pre_payload copilot-same "$GUIDED" Edit internal/app.go)"
CORRUPT_STATE="$TMP/corrupt-state"
export TOUCHSTONE_HOOK_STATE_DIR="$CORRUPT_STATE"
record_post "$(copilot_post_payload copilot-bad-state "$GUIDED" Read CONTRIBUTING.md success)"
for corrupt_file in "$CORRUPT_STATE"/*.json; do
  printf 'not json\n' > "$corrupt_file"
done
expect_detail "copilot corrupt session state denies" "invalid session evidence" \
                                           "$(copilot_pre_payload copilot-bad-state "$GUIDED" Edit internal/app.go)"
export TOUCHSTONE_HOOK_STATE_DIR="$STATE"

echo "nothing to read, or no opt-in, means nothing to gate"
expect_payload "gated repo with no guide"          ALLOW "$(legacy_payload "$TMP/missing.jsonl" "$BARE/internal/app.go")"
expect_payload "guide present but repo not gated"  ALLOW "$(legacy_payload "$TMP/missing.jsonl" "$UNGATED/internal/app.go")"
expect_payload "path in no repository at all"      ALLOW "$(legacy_payload "$TMP/missing.jsonl" "$TMP/loose/scratch.go")"
expect_payload "no file_path in the tool input"    ALLOW "$(legacy_payload "$TMP/missing.jsonl" "")"

echo ""
if [ "$failures" -eq 0 ]; then
  echo "CONTRIBUTING GATE OK"
else
  echo "FAILED: $failures assertion(s)"
  exit 1
fi
