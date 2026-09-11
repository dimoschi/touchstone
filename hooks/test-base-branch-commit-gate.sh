#!/usr/bin/env bash
# Tests base-branch-commit-gate.py: commits on a shared base branch are refused
# once a remote exists; feature-branch and local-only repos are untouched.

set -uo pipefail

GATE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/base-branch-commit-gate.py"
failures=0

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
REMOTE="$TMP/remote.git"
MAIN="$TMP/main"
LOCAL="$TMP/local"

git init -q --bare "$REMOTE"
mkdir -p "$MAIN" "$LOCAL"
git -C "$MAIN" init -q
git -C "$LOCAL" init -q
printf 'tracked\n' > "$MAIN/readme.txt"
git -C "$MAIN" add readme.txt
git -C "$MAIN" -c commit.gpgsign=false -c user.email=t@t -c user.name=t commit -q -m baseline
git -C "$MAIN" remote add origin "$REMOTE"
git -C "$MAIN" push -q -u origin HEAD
git -C "$MAIN" checkout -q -b feature
printf 'feature\n' >> "$MAIN/readme.txt"
git -C "$MAIN" add readme.txt
git -C "$MAIN" -c commit.gpgsign=false -c user.email=t@t -c user.name=t commit -q -m feature
git -C "$MAIN" checkout -q main
git -C "$LOCAL" -c commit.gpgsign=false -c user.email=t@t -c user.name=t \
  commit -q --allow-empty -m baseline

expect_payload() {
  local label="$1" want="$2" payload="$3" rc=0 out got
  out="$(printf '%s' "$payload" | python3 "$GATE" 2>&1)" || rc=$?
  if [ "$rc" -eq 0 ]; then
    got=ALLOW
  elif printf '%s' "$out" | grep -q 'Refused: that commit would land on a base branch.'; then
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

legacy_payload() {
  python3 - "$1" "$2" <<'PY'
import json
import sys

cwd, command = sys.argv[1:3]
json.dump({"cwd": cwd, "tool_input": {"command": command}}, sys.stdout)
PY
}

copilot_payload() {
  python3 - "$1" "$2" <<'PY'
import json
import sys

cwd, command = sys.argv[1:3]
json.dump(
    {
        "hook_event_name": "PreToolUse",
        "session_id": "copilot-base-branch",
        "cwd": cwd,
        "tool_name": "Bash",
        "tool_input": {"command": command},
    },
    sys.stdout,
)
PY
}

echo "legacy payloads keep the existing base-branch guard"
expect_payload "remote-backed main branch commit" BLOCK "$(legacy_payload "$MAIN" "git commit -m wip")"
expect_payload "local-only repo with no remote"   ALLOW "$(legacy_payload "$LOCAL" "git commit -m wip")"
expect_payload "non-commit command"               ALLOW "$(legacy_payload "$MAIN" "git status")"
git -C "$MAIN" checkout -q feature
expect_payload "feature branch commit"            ALLOW "$(legacy_payload "$MAIN" "git commit -m wip")"
git -C "$MAIN" checkout -q main

echo "copilot bash payloads block the same base-branch commit"
expect_payload "copilot main branch commit"       BLOCK "$(copilot_payload "$MAIN" "git commit -m wip")"
expect_payload "copilot local-only repo"          ALLOW "$(copilot_payload "$LOCAL" "git commit -m wip")"
git -C "$MAIN" checkout -q feature
expect_payload "copilot feature branch commit"    ALLOW "$(copilot_payload "$MAIN" "git commit -m wip")"

echo ""
if [ "$failures" -eq 0 ]; then
  echo "BASE BRANCH COMMIT GATE OK"
else
  echo "FAILED: $failures assertion(s)"
  exit 1
fi
