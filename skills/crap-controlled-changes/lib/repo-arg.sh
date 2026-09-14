#!/usr/bin/env bash
# repo-arg.sh: shared optional-leading-repo-path resolution for crap-check.sh,
# mutation-check.sh and deadcode-check.sh. Mirrors crap-commit.sh's existing
# `<absolute-repo-path>` argument, so a worktree run can name its own tree
# explicitly instead of relying on the process cwd -- which a treeAgent
# session may have moved away from without the gate ever knowing.
#
# resolve_repo_root <gate-name> [<maybe-path>] prints the resolved repo root
# to stdout. On any failure it `exit`s 2 rather than returning: every caller
# invokes it as `REPO_ROOT="$(resolve_repo_root ...)" || exit 2`, so the
# function always runs inside the subshell that command substitution creates,
# where a bare `return` would only end that subshell -- indistinguishable
# from success once its output is captured. `exit` there ends the subshell
# with the right status, which `|| exit 2` then propagates to the caller.

resolve_repo_root() {
  local gate="$1" arg="${2:-}"
  case "$arg" in
    ''|-*)
      git rev-parse --show-toplevel 2>/dev/null || {
        echo "$gate: not inside a git repo" >&2
        exit 2
      }
      ;;
    /*)
      [ -d "$arg" ] || { echo "$gate: no such directory: $arg" >&2; exit 2; }
      # GIT_DIR/GIT_WORK_TREE in the environment outrank `-C` in git itself,
      # so a caller's exported vars would otherwise win silently over an
      # explicit path here -- the same env vars the ticket-43 agent resorted
      # to before this argument existed. Unset them so the argument, once
      # given, is the only thing that decides.
      unset GIT_DIR GIT_WORK_TREE
      git -C "$arg" rev-parse --show-toplevel 2>/dev/null || {
        echo "$gate: not a git repository: $arg" >&2
        exit 2
      }
      ;;
    *)
      echo "$gate: repo path must be absolute, got '$arg'" >&2
      exit 2
      ;;
  esac
}
