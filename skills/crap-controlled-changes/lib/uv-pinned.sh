#!/usr/bin/env bash
# uv-pinned.sh: run a python3 script inside an environment holding one of
# github.com/unclebob's tools (crapper, dryer) at an exact commit.
#
# --isolated gives uv a throwaway environment instead of the target project's
# .venv, and --no-project stops it reading that project's pyproject.toml at all,
# so nothing is installed into, or written under, the repo being measured. A
# pinned commit rather than a branch for the reason tool-versions.sh gives: a
# gate whose verdict moves when upstream does is not a measurement.
#
# An override replaces the whole launcher, `python3` included, and is split into
# words the way CRAP_PY_RUN is. It exists so the suites here can stand in for the
# tool without a network; set to a real value it is also what the baseline cache
# and the ledger fingerprint record, so a different tool never reads as the same.

# pinned_ready <gate> <tool> <override-variable> <override>: 0 when pinned_run can
# run, otherwise says why on stderr and returns 2.
pinned_ready() {
  local gate="$1" tool="$2" variable="$3" override="$4"
  [ -n "$override" ] && return 0
  command -v uv >/dev/null && return 0
  {
    echo "$gate: uv is not on PATH, and $tool runs through it."
    echo "  Install uv (https://docs.astral.sh/uv/), or set $variable to a command"
    echo "  that runs python3 with $tool importable."
  } >&2
  return 2
}

# pinned_run <tool> <sha> <override> <script> [args...]
pinned_run() {
  local tool="$1" sha="$2" override="$3"
  shift 3
  if [ -n "$override" ]; then
    # shellcheck disable=SC2086  # split into words on purpose, as CRAP_PY_RUN is
    $override "$@"
    return
  fi
  uv run --isolated --no-project --quiet --python '>=3.11' \
    --with "$tool @ git+https://github.com/unclebob/$tool@$sha" python3 "$@"
}
