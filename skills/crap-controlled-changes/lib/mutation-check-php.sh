#!/usr/bin/env bash
# mutation-check-php.sh: surviving-mutant report for PHP changes vs
# MUTATION_BASE. Runs infection (>=0.32, needs PHP ^8.3) with line-level git
# diff scoping and normalizes the JSON report's escaped[] into SURVIVED rows.
#
# The per-mutant report is a config key, not a flag: infection 0.34 exposes only
# --logger-html/-text/-summary-json/-github/-gitlab, so the run needs a config
# carrying `logs.json`. The repo must supply its own infection config, the same
# way a Python repo declares [tool.mutmut] source_paths, because source
# directories and excludes are project decisions the gate must not invent. The
# gate copies it with the report logger injected (see lib/infection_config.py),
# beside the original because relative paths resolve against dirname(config).
#
# Verified end to end against infection 0.34.2 in test/run-mutation-php-live.sh
# (php comes from mise, which needs no global version set; pcov is already in those
# builds, phpunit is a phar), and against a stub in test/run-mutation-php-config.sh
# so the contract still gets checked on a machine with no PHP at all.
#
# Invoked by ../mutation-check.sh. Env:
#   MUTATION_BASE       diff base ref (required)
#   MUTATION_FILES      newline-separated changed .php files
#   MUTATION_PHP_INFECTION  infection invocation (default: vendor/bin/infection)
#   MUTATION_PHP_CONFIG     config path (default: infection.json5, then
#                           infection.json5.dist, infection.json.dist,
#                           infection.json, matching infection's own order)
#   MUTATION_PHP_THREADS    parallel mutants (default: cores/4, min 1)
#
# Exit codes: 0 measured, 2 setup problem, 4 could not measure.

set -euo pipefail

EXIT_UNMEASURABLE=4
DIAG_LINES=30

SKILL_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SKILL_LIB/read-lines.sh"

[ -n "${MUTATION_BASE:-}" ] || { echo "mutation-check[php]: MUTATION_BASE not set" >&2; exit 2; }

read_lines CHANGED <<< "${MUTATION_FILES:-}"
if [ "${#CHANGED[@]}" -eq 0 ] || [ -z "${CHANGED[0]}" ]; then
  exit 0
fi

INFECTION="${MUTATION_PHP_INFECTION:-vendor/bin/infection}"
if ! command -v "${INFECTION%% *}" >/dev/null && [ ! -x "${INFECTION%% *}" ]; then
  echo "mutation-check[php]: infection not found at '$INFECTION'." >&2
  echo "  Install with: composer require --dev infection/infection" >&2
  echo "  or set MUTATION_PHP_INFECTION." >&2
  exit 2
fi

CONFIG="${MUTATION_PHP_CONFIG:-}"
if [ -z "$CONFIG" ]; then
  for cand in infection.json5 infection.json5.dist infection.json.dist infection.json; do
    [ -f "$cand" ] && { CONFIG="$cand"; break; }
  done
fi
if [ -z "$CONFIG" ] || [ ! -f "$CONFIG" ]; then
  {
    echo "mutation-check[php]: no infection config found."
    echo "  The per-mutant JSON report this gate parses is only reachable through"
    echo "  the 'logs.json' config key, and source directories are a project"
    echo "  decision the gate will not invent. Create infection.json, e.g.:"
    echo '    { "source": { "directories": ["src"] } }'
    echo "  or run 'infection --init', or set MUTATION_PHP_CONFIG."
  } >&2
  exit 2
fi

REPORT="$(mktemp -t mutation-php.XXXXXX.json)"
RAW_OUT="$(mktemp)"
RAW_ERR="$(mktemp)"
# Beside the repo's own config, so every relative path in it still resolves.
GATE_CONFIG="$(dirname "$CONFIG")/.infection-gate-$$.json"
trap 'rm -f "$REPORT" "$RAW_OUT" "$RAW_ERR" "$GATE_CONFIG"' EXIT

python3 "$SKILL_LIB/infection_config.py" "$CONFIG" "$GATE_CONFIG" "$REPORT" || exit 2

NCPU="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"
THREADS="${MUTATION_PHP_THREADS:-$((NCPU / 4))}"
[ "$THREADS" -lt 1 ] && THREADS=1

status=0
$INFECTION -c "$GATE_CONFIG" --git-diff-lines --git-diff-base="$MUTATION_BASE" \
  --ignore-msi-with-no-mutations --no-progress --threads="$THREADS" \
  >"$RAW_OUT" 2>"$RAW_ERR" || status=$?

if [ "$status" -ne 0 ] || [ ! -s "$REPORT" ]; then
  {
    echo "mutation-check[php]: FAILED TO MEASURE - infection produced no JSON report."
    echo "  infection exit: $status"
    if [ -s "$RAW_ERR" ]; then
      echo "  stderr:"
      tail -n "$DIAG_LINES" "$RAW_ERR" | sed 's/^/    /'
    fi
    if [ -s "$RAW_OUT" ]; then
      echo "  stdout (last $DIAG_LINES lines):"
      tail -n "$DIAG_LINES" "$RAW_OUT" | sed 's/^/    /'
    fi
    echo ""
    echo "  This is NOT a pass: zero mutants were scored."
  } >&2
  exit "$EXIT_UNMEASURABLE"
fi

rows="$(python3 "$SKILL_LIB/parse_infection.py" "$REPORT" "$PWD")"
if [ -n "$rows" ]; then
  printf '%s\n' "$rows"
else
  total="$(python3 "$SKILL_LIB/parse_infection.py" --total "$REPORT")"
  if [ "$total" -gt 0 ]; then
    echo "mutation-check[php]: generated $total mutant(s) on changed lines, all killed."
  else
    echo "mutation-check[php]: generated no mutants on changed lines; nothing was measured, so this is not a pass."
  fi
fi
