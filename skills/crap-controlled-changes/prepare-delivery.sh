#!/usr/bin/env bash
# prepare-delivery.sh: find or cut the ticket's branch and worktree before the
# delivery workflow starts, and print what the workflow takes as args.prepared.
#
#   prepare-delivery.sh <absolute-repo-path> --ticket <ref> --type <type> --slug <slug>
#                       [--existing] [--base <ref>] [--prior-head <sha>]
#
# Prints one JSON object on stdout. Exit 0 prepared; 2 bad arguments or a setup
# problem, 3 a refusal (a taken branch name, an occupied path, a merged or dirty
# branch, nothing found); both print {"error", "reason"}. The work is in
# lib/prepare_delivery.py; this script resolves the repo and names the plugin
# manifest it ships beside.

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SKILL_DIR/lib"
. "$LIB_DIR/require-bash.sh"
source "$LIB_DIR/repo-arg.sh"

refuse_args() {
  python3 -c 'import json, sys; print(json.dumps({"error": "bad-args", "reason": sys.argv[1]}))' "$1"
  exit 2
}

[ "$#" -ge 1 ] || refuse_args "usage: prepare-delivery.sh <absolute-repo-path> --ticket <ref> --type <type> --slug <slug> [--existing] [--base <ref>] [--prior-head <sha>]"
case "$1" in
  /*) ;;
  *) refuse_args "repo path must be absolute, got '$1'" ;;
esac

ERR="$(mktemp)"
trap 'rm -f "$ERR"' EXIT
REPO_ROOT="$(resolve_repo_root prepare-delivery "$1" 2>"$ERR")" || refuse_args "$(cat "$ERR")"
unset GIT_DIR GIT_WORK_TREE
shift

python3 "$LIB_DIR/prepare_delivery.py" "$REPO_ROOT" "$@" \
  --plugin-json "$SKILL_DIR/../../.claude-plugin/plugin.json"
