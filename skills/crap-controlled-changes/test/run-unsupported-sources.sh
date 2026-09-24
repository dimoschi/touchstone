#!/usr/bin/env bash
# Tests the unsupported-language refusal.
#
# The gate scores Go, PHP and Python. Everything else used to fall through to
# "no staged source files in supported languages" and exit 0, so a TypeScript
# function with complexity 5 and no tests committed cleanly in a repo whose
# marker said it was gated, while the docs promised three gates. A gate that
# silently passes what it cannot measure reports a guarantee it never checked.
#
# Needs only git and bash: no language toolchain, because the refusal happens
# before any module runs.

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CRAP="$SKILL_DIR/crap-check.sh"
source "$SKILL_DIR/lib/unsupported-sources.sh"
failures=0

check() {
  local label="$1" want="$2" got="$3"
  if [ "$got" = "$want" ]; then
    printf '  ok:   %-52s %s\n' "$label" "$got"
  else
    printf '  FAIL: %-52s got %s want %s\n' "$label" "$got" "$want"
    failures=$((failures + 1))
  fi
}

# Exit 2 is the refusal; 0 is a clean no-op. Anything else is a real failure.
verdict() {
  "$CRAP" >/dev/null 2>&1
  case $? in
    0) echo ALLOW ;;
    2) echo REFUSE ;;
    *) echo "OTHER" ;;
  esac
}

new_repo() {
  REPO="$(mktemp -d)"
  cd "$REPO" || exit 1
  git init -q -b main .
  git config user.email t@t
  git config user.name t
  git config commit.gpgsign false
  printf 'module example.com/t\n\ngo 1.26\n' > go.mod
  echo 'package main' > main.go
  git add -A
  git -c commit.gpgsign=false commit -q -m base
}

cleanup() { cd /; [ -n "${REPO:-}" ] && rm -rf "$REPO"; }
trap cleanup EXIT

ts_file() {
  mkdir -p "$(dirname "$1")"
  cat > "$1" <<'EOF'
export function riskyParse(input: string): number {
  if (!input) { return 0 }
  if (input.length > 10) { throw new Error('too long') }
  return parseInt(input, 10)
}
EOF
}

echo "a gated repo refuses source it cannot measure"
new_repo; touch .crap-gated; ts_file src/app.ts; git add -A
check "typescript only"          REFUSE "$(verdict)"

echo "the refusal covers a diff it can only partly measure"
cat > helper.go <<'EOF'
package main

func Helper() int { return 1 }
EOF
git add -A
check "go plus typescript"       REFUSE "$(verdict)"
git rm -q --cached helper.go >/dev/null 2>&1; rm -f helper.go; git add -A

echo "other unsupported languages are caught too"
for ext in rs rb java kt swift cs ex scala dart cpp; do
  rm -f src/*.ts src/*."$ext"; git add -A >/dev/null 2>&1
  printf 'fn main() {}\n' > "src/app.$ext"; git add -A
  got="$(verdict)"
  [ "$got" = REFUSE ] || { printf '  FAIL: .%s not refused (got %s)\n' "$ext" "$got"; failures=$((failures + 1)); }
done
printf '  ok:   %-52s %s\n' "rs rb java kt swift cs ex scala dart cpp" "REFUSE"
rm -f src/*; git add -A

echo "files that are not program source never trigger it"
printf '# notes\n' > README.md
printf 'a: 1\n' > config.yaml
printf 'SELECT 1;\n' > q.sql
printf 'echo hi\n' > run.sh
git add -A
check "markdown, yaml, sql, shell"  ALLOW "$(verdict)"
rm -f README.md config.yaml q.sql run.sh; git add -A

echo "the marker can exempt paths, one gitignore-style pattern per line"
ts_file web/app.ts; git add -A
check "unexempted web/ refuses"     REFUSE "$(verdict)"
printf 'web/**\n' >> .crap-gated; git add -A
check "web/** exempted"             ALLOW  "$(verdict)"
printf '\n# a comment, and a blank line above\n' >> .crap-gated; git add -A
check "comments and blanks ignored" ALLOW  "$(verdict)"
ts_file src/other.ts; git add -A
check "exemption is not repo-wide"  REFUSE "$(verdict)"

echo "a repo that never opted in is never refused"
rm -f .crap-gated; git add -A
check "no marker, typescript staged" ALLOW "$(verdict)"

echo "an exempted path is also skipped for a language the gate measures, not only an unsupported one"
rm -f web/app.ts src/other.ts; git add -A
touch .crap-gated
mkdir -p tools
cat > tools/scratch.go <<'EOF'
package main

func Scratch() int { return 1 }
EOF
git add -A
printf 'tools/scratch.go\n' >> .crap-gated
git add -A
check "an exempted Go file is never handed to a language module" ALLOW "$(verdict)"

echo "a leading-slash exempt pattern (gitignore anchoring) is a valid pathspec, not a crash"
git rm -q --cached tools/scratch.go >/dev/null 2>&1; rm -rf tools; git add -A
mkdir -p unrelated
: > unrelated/x.go
cat > measured.go <<'EOF'
package main

func Measured() int { return 1 }
EOF
printf '/unrelated/**\n' > .crap-gated
git add -A
EXEMPT_SPEC=()
while IFS= read -r ex; do
  [ -n "$ex" ] && EXEMPT_SPEC+=("$ex")
done < <(crap_exempt_pathspecs "$PWD")
GO_OUT="$(git diff --cached --name-only -- '*.go' "${EXEMPT_SPEC[@]}" 2>&1)"; GO_RC=$?
check "the pathspec built from a leading-slash line is valid" "0" "$GO_RC"
check "the unrelated exempted path is filtered out" \
      "0" "$(printf '%s\n' "$GO_OUT" | grep -c '^unrelated/x.go$')"
check "a non-exempted Go file is still selected for measurement" \
      "1" "$(printf '%s\n' "$GO_OUT" | grep -c '^measured.go$')"

echo "threshold settings share the marker and are configuration, not path patterns"
printf 'crap-soft = 8\ncrap-hard = 10\nmain-complexity = 7\ncognitive-complexity = 20\nunrelated/**\n' > .crap-gated
git add -A
SETTING_SPEC=()
while IFS= read -r ex; do
  [ -n "$ex" ] && SETTING_SPEC+=("$ex")
done < <(crap_exempt_pathspecs "$PWD")
check "only the pattern line becomes a pathspec" "1" "${#SETTING_SPEC[@]}"
check "the pattern line is the one that survived" \
      "1" "$(printf '%s\n' "${SETTING_SPEC[@]+"${SETTING_SPEC[@]}"}" | grep -c 'unrelated/\*\*$')"

echo ""
if [ "$failures" -eq 0 ]; then
  echo "UNSUPPORTED SOURCES OK"
else
  echo "FAILED: $failures assertion(s)"
  exit 1
fi
