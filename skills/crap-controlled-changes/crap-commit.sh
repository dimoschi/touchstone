#!/usr/bin/env bash
# crap-commit.sh: the one sanctioned way for an agent to commit in a first-party
# repo. Gate, then sign, then commit, in one deterministic step.
#
#   crap-commit.sh <absolute-repo-path> -m "message" [git commit flags...]
#
# The repo is an explicit absolute argument on purpose. The old PreToolUse hook
# had to infer which repo a `git commit` would land in by parsing `cd`, `git -C`
# and `--git-dir` out of a shell command; every form it failed to parse was a
# silent bypass of the gate. Naming the repo removes the question instead of
# answering it better.
#
# Signing follows the repo's own configuration. This script does not decide
# whether a commit is signed, which key signs it, or whether signing is wanted
# at all: git already resolves that from the repo, global and system config,
# including any conditional includes. Set CRAP_SIGNING_KEY to an ssh key file
# to override.
#
# Exit codes: 0 committed, 2 usage/setup problem, anything else is crap-check's
# own exit code (1 gate red, 4 could not measure, 5 unscored source) or git's.

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CRAP_CHECK="$SKILL_DIR/crap-check.sh"
DEADCODE_CHECK="$SKILL_DIR/deadcode-check.sh"
. "$SKILL_DIR/lib/require-bash.sh"
# Injected git config outranks the repo's own .git/config, so imposing a key
# here silently overrides a repo that signs with a different one. Only ever set
# from CRAP_SIGNING_KEY, where someone has asked for exactly that.
SIGNING_KEY="${CRAP_SIGNING_KEY:-}"

usage() {
  {
    echo "usage: crap-commit.sh <absolute-repo-path> -m \"message\" [git commit flags...]"
    echo ""
    echo "  Runs the dead-code and CRAP gates in that repo and commits the staged"
    echo "  diff only if both are green. Signing follows the repo's git config."
    echo "  Stage your files first; -a is refused."
  } >&2
  exit 2
}

[ "$#" -ge 2 ] || usage
REPO="$1"
shift

case "$REPO" in
  /*) ;;
  *) echo "crap-commit: repo path must be absolute, got '$REPO'" >&2; usage ;;
esac
[ -d "$REPO" ] || { echo "crap-commit: no such directory: $REPO" >&2; exit 2; }

cd "$REPO"
git rev-parse --show-toplevel >/dev/null 2>&1 || {
  echo "crap-commit: not a git repository: $REPO" >&2
  exit 2
}

refuse_all_flag() {
  echo "crap-commit: -a/--all stages at commit time, which would bypass the" >&2
  echo "  gate: it scores the staged diff. git add the files, then retry." >&2
  exit 2
}

# -a stages at commit time, after the gate has already scored the index. Short
# flags cluster, so -am and -sa hide an -a; checked by scanning the cluster
# rather than by one glob, because case globs do not backtrack.
for arg in "$@"; do
  case "$arg" in
    --) break ;;
    --all) refuse_all_flag ;;
    --*) ;;
    -*) case "$arg" in *a*) refuse_all_flag ;; esac ;;
  esac
done

if git diff --cached --quiet; then
  echo "crap-commit: nothing staged in $REPO; git add the files you mean to commit." >&2
  exit 2
fi

# What git itself would do, read from the fully resolved config so a conditional
# include is already applied. Nothing here decides to sign: if the config does
# not ask for signing, the commit is not signed, and that is the repo's call.
SIGN_ENABLED="$(git -C "$REPO" config --get --type=bool commit.gpgsign 2>/dev/null || echo false)"
SIGN_FORMAT="$(git -C "$REPO" config --get gpg.format 2>/dev/null || echo openpgp)"
SIGN_KEY_CONFIGURED="$(git -C "$REPO" config --get user.signingkey 2>/dev/null || true)"

if [ -n "$SIGNING_KEY" ]; then
  # An explicit override is a request to sign with this key, whatever the config
  # says, so it also turns signing on.
  case "$SIGNING_KEY" in
    *_sk|*_sk.pub)
      echo "crap-commit: refusing CRAP_SIGNING_KEY=$SIGNING_KEY: an *_sk key needs" >&2
      echo "  a hardware security token to be touched, which no unattended process" >&2
      echo "  can do. It would hang waiting rather than fail." >&2
      exit 2 ;;
  esac
  if [ ! -f "$SIGNING_KEY" ]; then
    echo "crap-commit: CRAP_SIGNING_KEY does not name a readable file: $SIGNING_KEY" >&2
    exit 2
  fi
  SIGN_MODE=override
elif [ "$SIGN_ENABLED" = "true" ]; then
  # The config wants signing. Refuse only what is *demonstrably* untouchable by
  # an unattended process: an ssh key whose filename marks it as a FIDO/PIV
  # token. An openpgp key is left alone, because whether it lives in a keyring
  # or on a smartcard is not knowable from config, and assuming a smartcard
  # would refuse every passphrase-less GPG setup that works fine.
  if [ "$SIGN_FORMAT" = "ssh" ]; then
    case "$SIGN_KEY_CONFIGURED" in
      *_sk|*_sk.pub)
        echo "crap-commit: this repo signs with '$SIGN_KEY_CONFIGURED', an *_sk key" >&2
        echo "  that needs a hardware token nobody is here to touch. Commit this" >&2
        echo "  one yourself, or set CRAP_SIGNING_KEY to a key file." >&2
        echo "  Not falling back to another key: signing as a different identity" >&2
        echo "  is worse than not committing." >&2
        exit 2 ;;
    esac
  fi
  SIGN_MODE=config
else
  SIGN_MODE=none
fi

run_gate() {
  local name="$1" script="$2" status=0
  "$script" "$REPO" || status=$?
  if [ "$status" -ne 0 ]; then
    echo "" >&2
    echo "crap-commit: not committing; $name exited $status." >&2
    echo "  Follow its NEXT_ACTION directive, then retry." >&2
    exit "$status"
  fi
}

# Dead-code first: it is static analysis, while the CRAP gate runs the test suite
# twice. Failing on the cheap gate first saves the expensive one when the diff
# adds code nothing can reach anyway.
run_gate "the dead-code gate" "$DEADCODE_CHECK"
run_gate "the CRAP gate" "$CRAP_CHECK"

COMMIT_STATUS=0
case "$SIGN_MODE" in
  override)
    GIT_CONFIG_COUNT=2 \
    GIT_CONFIG_KEY_0=gpg.format      GIT_CONFIG_VALUE_0=ssh \
    GIT_CONFIG_KEY_1=user.signingkey GIT_CONFIG_VALUE_1="$SIGNING_KEY" \
      git commit -S "$@" || COMMIT_STATUS=$?
    ;;
  *)
    # No -S and no injected config: git applies commit.gpgsign and the key from
    # its own resolved configuration. Passing -S here would sign commits in
    # repos that never asked to be signed.
    git commit "$@" || COMMIT_STATUS=$?
    ;;
esac

# The gate scored the index, so only now does a commit carry the blobs it
# measured; anchoring them here is what lets a later branch reuse the scoring.
# Never fatal: the commit has already happened.
if [ "$COMMIT_STATUS" -eq 0 ]; then
  "$CRAP_CHECK" "$REPO" --anchor-committed || true
fi
exit "$COMMIT_STATUS"
