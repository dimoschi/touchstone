#!/usr/bin/env bash
# unsupported_sources: staged source files in a language no module can measure.
#
# The gates score Go, PHP and Python. Anything else used to fall through to
# "no staged source files in supported languages" and exit 0, so a TypeScript
# function with complexity 5 and no tests committed cleanly in a repo whose
# marker says it is gated. A gate that silently passes what it cannot measure
# is worse than no gate: it reports a guarantee it never checked.
#
# Only languages that carry functions and have real per-function coverage and
# mutation tooling are listed. Markdown, YAML, SQL, shell and the like are
# absent on purpose: they are not measurable in the terms this gate is
# expressed in, so refusing them would be noise rather than signal.
#
# A repo can exempt paths by listing gitignore-style patterns in its
# .crap-gated marker, one per line, '#' for comments. That covers the ordinary
# mixed repo -- a Go service with a TypeScript frontend gates the Go and
# exempts web/ -- without forcing a choice between gating everything and
# gating nothing. An empty marker, which is the common case, exempts nothing.

UNSUPPORTED_SPEC=(
  '*.ts' '*.tsx' '*.js' '*.jsx' '*.mjs' '*.cjs'
  '*.rs' '*.java' '*.kt' '*.kts' '*.scala' '*.groovy' '*.cs' '*.swift'
  '*.rb' '*.ex' '*.exs' '*.erl' '*.clj' '*.cljs' '*.dart' '*.lua'
  '*.c' '*.cc' '*.cpp' '*.cxx' '*.m' '*.mm' '*.hs' '*.ml' '*.jl'
)

# Patterns the repo's marker exempts, as git pathspecs. Prints nothing when the
# marker is absent or holds no patterns.
crap_exempt_pathspecs() {
  local root="$1" marker line
  marker="$root/.crap-gated"
  [ -f "$marker" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    # Trim surrounding whitespace without a subshell.
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -n "$line" ] || continue
    printf '%s\n' ":(glob,exclude)$line"
  done < "$marker"
}

# Staged files in an unsupported language, minus anything the marker exempts.
unsupported_sources() {
  local root="$1"
  local specs=("${UNSUPPORTED_SPEC[@]}")
  local ex
  while IFS= read -r ex; do
    [ -n "$ex" ] && specs+=("$ex")
  done < <(crap_exempt_pathspecs "$root")
  git diff --name-only --cached --diff-filter=d -- "${specs[@]}" 2>/dev/null || true
}

# Print the refusal and return 1 when anything is unmeasurable, else return 0.
#
# Only in a repo that opted in. The gate is runnable by hand anywhere, and
# refusing in a repo that never asked to be gated would both be wrong and make
# the message ("this repo carries .crap-gated") a lie.
report_unsupported_sources() {
  local root="$1" files count
  [ -f "$root/.crap-gated" ] || return 0
  files="$(unsupported_sources "$root")"
  [ -n "$files" ] || return 0
  count="$(printf '%s\n' "$files" | grep -c .)"
  {
    echo "crap-check: FAILED TO MEASURE - $count staged file(s) in a language this"
    echo "  gate cannot score:"
    echo ""
    printf '%s\n' "$files" | sed 's/^/    /'
    echo ""
    echo "  This repo carries .crap-gated, so a change the gate cannot measure is"
    echo "  not a pass. Supported languages: go, php, python."
    echo ""
    echo "  == NEXT_ACTION =="
    echo "  UNSUPPORTED_LANGUAGE. Pick one, in preference order:"
    echo "    1. Exempt these paths, if they are genuinely out of scope for this"
    echo "       gate. Add gitignore-style patterns to .crap-gated, one per line:"
    echo "         echo 'web/**' >> $root/.crap-gated"
    echo "       The marker is committed, so the whole team gets the same rule."
    echo "    2. Add a module for the language: lib/crap-check-<lang>.sh, following"
    echo "       the contract the go, php and python modules already implement."
    echo "    3. Remove .crap-gated if this repo should not be gated at all."
    echo ""
    echo "  Do not work around this by committing outside crap-commit.sh."
  } >&2
  return 1
}
