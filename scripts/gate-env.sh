#!/usr/bin/env bash
# Prints the exports a gate needs in this repo, for eval "$(scripts/gate-env.sh <gate>)". The pins match AGENTS.md.
set -euo pipefail

case "${1:-}" in
  mutation) printf '%s\n' "export MUTATION_PY_RUN='uv run --no-project --with mutmut==3.8.0 --with pytest==9.1.1 --'" ;;
esac
