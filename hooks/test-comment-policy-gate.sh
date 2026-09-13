#!/usr/bin/env bash
# Tests comment-policy-gate.py: an opt-in .comment-gated marker at the repo
# root carries the policy itself (one regex per line); absent, empty or
# comment-only, the gate flags nothing.

set -uo pipefail

GATE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/comment-policy-gate.py"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
failures=0

GATED="$WORK/gated"
PLAIN="$WORK/plain"
mkdir -p "$GATED" "$PLAIN"
git -C "$GATED" init -q
git -C "$PLAIN" init -q
printf 'hush\n' > "$GATED/.comment-gated"

# want: BLOCK | ALLOW
expect() {
  local label="$1" want="$2" payload="$3" rc=0 out got
  out="$(printf '%s' "$payload" | python3 "$GATE" 2>&1)" || rc=$?
  if [ "$rc" -eq 0 ]; then
    got=ALLOW
  elif printf '%s' "$out" | grep -q 'comment-policy:'; then
    got=BLOCK
  else
    got="OTHER($rc)"
  fi
  if [ "$got" = "$want" ]; then
    printf '  ok:   %-56s %s\n' "$label" "$got"
  else
    printf '  FAIL: %-56s got %s want %s\n' "$label" "$got" "$want"
    failures=$((failures + 1))
  fi
}

write() {
  jq -nc --arg p "$1" --arg c "$2" --arg cwd "$(dirname "$1")" \
    '{tool_name:"Write", tool_input:{file_path:$p, content:$c}, cwd:$cwd}'
}
edit() {
  jq -nc --arg p "$1" --arg o "$2" --arg n "$3" --arg cwd "$(dirname "$1")" \
    '{tool_name:"Edit", tool_input:{file_path:$p, old_string:$o, new_string:$n}, cwd:$cwd}'
}
multi_edit() {
  jq -nc --arg p "$1" --arg o1 "$2" --arg n1 "$3" --arg o2 "$4" --arg n2 "$5" --arg cwd "$(dirname "$1")" \
    '{tool_name:"MultiEdit", tool_input:{file_path:$p, edits:[{old_string:$o1, new_string:$n1}, {old_string:$o2, new_string:$n2}]}, cwd:$cwd}'
}
copilot_write() {
  python3 - "$1" "$2" "$3" <<'PY'
import json
import sys

cwd, file_path, content = sys.argv[1:4]
json.dump(
    {
        "hook_event_name": "PostToolUse",
        "session_id": "copilot-comment",
        "cwd": cwd,
        "tool_name": "Write",
        "tool_input": {"path": file_path, "content": content},
    },
    sys.stdout,
)
PY
}

echo "no marker: every payload is a no-op"
expect "no .comment-gated at all" ALLOW "$(write "$PLAIN/task.py" '# hush, do not tell
print(1)')"

echo "empty or comment-only marker is also a no-op"
mkdir -p "$WORK/empty" "$WORK/commented"
git -C "$WORK/empty" init -q
git -C "$WORK/commented" init -q
: > "$WORK/empty/.comment-gated"
printf '# no rules yet\n\n' > "$WORK/commented/.comment-gated"
expect "empty marker"        ALLOW "$(write "$WORK/empty/task.py" '# hush, do not tell')"
expect "comment-only marker" ALLOW "$(write "$WORK/commented/task.py" '# hush, do not tell')"

echo "a policy regex blocks a matching new comment, and only in a comment"
expect "Write adds a matching comment" \
                             BLOCK "$(write "$GATED/task.py" '# hush, do not tell
print(1)')"
expect "same text in code, not a comment" \
                             ALLOW "$(write "$GATED/task.py" 'print("hush, do not tell")')"

echo "Edit only flags a line that is new"
printf '# hush, already here\nprint(1)\n' > "$GATED/existing.py"
expect "unchanged old comment is not reflagged" \
                             ALLOW "$(edit "$GATED/existing.py" 'print(1)' 'print(2)')"
expect "a genuinely new comment in the edit" \
                             BLOCK "$(edit "$GATED/existing.py" 'print(1)' '# hush, new
print(1)')"

echo "MultiEdit unions the new lines of every edit"
printf 'a\nb\n' > "$GATED/multi.py"
expect "match arrives via the second edit" \
                             BLOCK "$(multi_edit "$GATED/multi.py" 'a' 'a' 'b' '# hush, two')"

echo "an extension with no known comment prefix is never flagged"
expect "unmapped extension" ALLOW "$(write "$GATED/task.rkt" '; hush, do not tell')"

echo "a tool other than Edit/Write/MultiEdit is a no-op"
expect "Bash payload" ALLOW '{"tool_name":"Bash","tool_input":{"command":"echo hush"}}'

echo "no path in the payload is a no-op"
expect "missing file_path" ALLOW '{"tool_name":"Write","tool_input":{"content":"# hush"}}'

echo "a bad regex in the policy is a setup error, not a silent skip"
mkdir -p "$WORK/badregex"
git -C "$WORK/badregex" init -q
printf '(unclosed\n' > "$WORK/badregex/.comment-gated"
out="$(printf '%s' "$(write "$WORK/badregex/task.py" '# anything')" | python3 "$GATE" 2>&1)"
rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q "$WORK/badregex/.comment-gated"; then
  printf '  ok:   %-56s %s\n' "bad regex names the marker file" "OTHER(2)"
else
  printf '  FAIL: %-56s got rc=%s out=%s\n' "bad regex names the marker file" "$rc" "$out"
  failures=$((failures + 1))
fi

echo "copilot payloads resolve a relative path against cwd"
expect "copilot write, relative path" \
                             BLOCK "$(copilot_write "$GATED" "copilot.py" '# hush, do not tell')"

echo ""
if [ "$failures" -eq 0 ]; then
  echo "COMMENT POLICY GATE OK"
else
  echo "FAILED: $failures assertion(s)"
  exit 1
fi
