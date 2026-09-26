#!/usr/bin/env bash
# Tests worktree-edit-gate.py against a real repo and a real linked worktree:
# an edit in the main checkout is refused while a ticket worktree is active
# for the acting agent (agent_id plus its own transcript's own
# [touchstone: ...] header naming it); the same edit inside the worktree, an
# agent whose transcript never named one, and the invoking session itself
# (no agent_id) are all allowed.

set -uo pipefail

GATE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/worktree-edit-gate.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
failures=0

REPO="$TMP/repo"
mkdir -p "$REPO"
git init -q "$REPO"
WT="$TMP/wt"
git -C "$REPO" worktree add -q -b fix/gh-125-stub "$WT"

PARENT="$TMP/s1.jsonl"
SUB_DIR="$TMP/s1/subagents"
mkdir -p "$SUB_DIR"

header_content() {
  printf '[touchstone: implementer]\nWork in the git worktree at %s. Every command, git included, acts on that tree.\n\nTicket 1: stub\nRepo worktree: %s\nBranch: fix/gh-125-stub (base main)\n\nImplement this task.\n' "$1" "$1"
}
jq -nc --arg content "$(header_content "$WT")" '{type:"user", message:{content:$content}}' > "$SUB_DIR/agent-a1.jsonl"
jq -nc '{type:"user", message:{content:"just do the task"}}' > "$SUB_DIR/agent-a2.jsonl"

payload() {
  local path="$1" cwd="$2" agent_id="${3:-}"
  if [ -n "$agent_id" ]; then
    jq -nc --arg path "$path" --arg cwd "$cwd" --arg t "$PARENT" --arg a "$agent_id" \
      '{hook_event_name:"PreToolUse", session_id:"s1", cwd:$cwd, tool_name:"Edit",
        tool_input:{file_path:$path}, transcript_path:$t, agent_id:$a}'
  else
    jq -nc --arg path "$path" --arg cwd "$cwd" \
      '{hook_event_name:"PreToolUse", session_id:"s1", cwd:$cwd, tool_name:"Edit",
        tool_input:{file_path:$path}}'
  fi
}

# want: BLOCK (worktree-edit-gate: on stderr) | ALLOW
expect() {
  local label="$1" want="$2" payload="$3" rc=0 out got
  out="$(printf '%s' "$payload" | python3 "$GATE" 2>&1)" || rc=$?
  if [ "$rc" -eq 0 ]; then
    got=ALLOW
  elif printf '%s' "$out" | grep -q 'worktree-edit-gate:'; then
    got=BLOCK
  else
    got="OTHER($rc)"
  fi
  if [ "$got" = "$want" ]; then
    printf '  ok:   %-56s %s\n' "$label" "$got"
  else
    printf '  FAIL: %-56s got %s want %s\n' "$label" "$got" "$want"
    printf '        %s\n' "$out"
    failures=$((failures + 1))
  fi
}

echo "a ticket worktree is active for this agent"
expect "an edit in the main checkout is refused" \
                                    BLOCK "$(payload "$REPO/app.py" "$WT" a1)"
out="$(printf '%s' "$(payload "$REPO/app.py" "$WT" a1)" | python3 "$GATE" 2>&1)"
if printf '%s' "$out" | grep -qF "$WT"; then
  echo "  ok:   the refusal names the worktree path"
else
  echo "  FAIL: the refusal does not name the worktree path"
  printf '        %s\n' "$out"
  failures=$((failures + 1))
fi
expect "the same edit inside the worktree is allowed" \
                                    ALLOW "$(payload "$WT/app.py" "$WT" a1)"

echo "no active worktree"
expect "a subagent whose transcript never named one" \
                                    ALLOW "$(payload "$REPO/app.py" "$REPO" a2)"
expect "the invoking session itself (no agent_id)" \
                                    ALLOW "$(payload "$REPO/app.py" "$REPO")"

echo ""
if [ "$failures" -eq 0 ]; then
  echo "WORKTREE EDIT GATE OK"
else
  echo "FAILED: $failures assertion(s)"
  exit 1
fi
