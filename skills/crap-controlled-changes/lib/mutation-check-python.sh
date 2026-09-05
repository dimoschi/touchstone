#!/usr/bin/env bash
# mutation-check-python.sh: surviving-mutant report for Python changes vs
# MUTATION_BASE, via mutmut 3. mutmut has no git-diff scoping and its JSON
# export is counts-only, so this module scopes by generating mutant-name
# patterns for changed functions (mutmut_patterns.py) and scrapes
# `mutmut results` for survivor identities.
#
# The repo should configure [tool.mutmut] source_paths in pyproject.toml
# (or [mutmut] in setup.cfg). mutmut keeps its incremental cache in
# ./mutants/ - add that to .gitignore.
#
# Invoked by ../mutation-check.sh. Env:
#   MUTATION_BASE    diff base ref (required)
#   MUTATION_FILES   newline-separated changed .py files
#   MUTATION_PY_RUN  prefix for in-env commands (e.g. "poetry run", "uv run --")
#
# Exit codes: 0 measured, 2 setup problem, 4 could not measure.

set -uo pipefail

EXIT_UNMEASURABLE=4
DIAG_LINES=20

SKILL_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[ -n "${MUTATION_BASE:-}" ] || { echo "mutation-check[python]: MUTATION_BASE not set" >&2; exit 2; }

mapfile -t CHANGED <<< "${MUTATION_FILES:-}"
if [ "${#CHANGED[@]}" -eq 0 ] || [ -z "${CHANGED[0]}" ]; then
  exit 0
fi

MUTATION_PY_RUN="${MUTATION_PY_RUN:-}"
if ! $MUTATION_PY_RUN mutmut --help >/dev/null 2>&1; then
  echo "mutation-check[python]: 'mutmut' not runnable via '${MUTATION_PY_RUN:-<active env>}'." >&2
  echo "  Install mutmut+pytest in the project env, or set MUTATION_PY_RUN" >&2
  echo "  (e.g. MUTATION_PY_RUN='uv run --with mutmut --with pytest --')." >&2
  exit 2
fi

EXISTING=()
for f in "${CHANGED[@]}"; do
  [ -f "$f" ] && EXISTING+=("$f")
done
if [ "${#EXISTING[@]}" -eq 0 ]; then
  echo "mutation-check[python]: all changed Python files are deleted; nothing to mutate."
  exit 0
fi

TSV="$(printf '%s\n' "${EXISTING[@]}" | python3 "$SKILL_LIB/mutmut_patterns.py" "$MUTATION_BASE")"
if [ -z "$TSV" ]; then
  echo "mutation-check[python]: no function bodies changed vs $MUTATION_BASE; nothing to mutate."
  exit 0
fi

PATTERNS=()
while IFS=$'\t' read -r pat _file _line _qual; do
  PATTERNS+=("$pat")
done <<< "$TSV"

RAW="$(mktemp)"
trap 'rm -f "$RAW"' EXIT

status=0
$MUTATION_PY_RUN mutmut run "${PATTERNS[@]}" >"$RAW" 2>&1 || status=$?
# mutmut exits 0 even when the pattern set matches no mutants; that means the
# module-path derivation failed and must not read as a pass.
if [ "$status" -ne 0 ] || grep -q 'nothing matches' "$RAW"; then
  {
    echo "mutation-check[python]: FAILED TO MEASURE - mutmut run did not score the changed functions."
    echo "  mutmut exit: $status"
    echo "  patterns:"
    printf '    %s\n' "${PATTERNS[@]}"
    echo "  output (last $DIAG_LINES lines):"
    tail -n "$DIAG_LINES" "$RAW" | sed 's/^/    /'
    echo ""
    echo "  This is NOT a pass. Check [tool.mutmut] source_paths and that the"
    echo "  changed files live inside it (src/ layouts are handled; exotic"
    echo "  layouts may need adjustment)."
  } >&2
  exit "$EXIT_UNMEASURABLE"
fi

survivors=0
while IFS=: read -r name state; do
  name="$(tr -d ' ' <<< "$name")"
  state="$(sed 's/^ *//' <<< "$state")"
  case "$state" in survived|'no tests') ;; *) continue ;; esac
  while IFS=$'\t' read -r pat file line qual; do
    # shellcheck disable=SC2254
    case "$name" in
      $pat)
        printf '%-42s %-26s SURVIVED  id=%s\n' "$file:$line" "$qual" "$name"
        $MUTATION_PY_RUN mutmut show "$name" 2>/dev/null \
          | grep -E '^[+-]' | grep -vE '^(\+\+\+|---)' | sed 's/^/    /' || true
        survivors=$((survivors + 1))
        break
        ;;
    esac
  done <<< "$TSV"
done < <($MUTATION_PY_RUN mutmut results 2>/dev/null)

if [ "$survivors" -eq 0 ]; then
  echo "mutation-check[python]: all mutants on changed functions were killed."
fi
