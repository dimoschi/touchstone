#!/usr/bin/env bash
# crap-check.sh hands the Go module only the staged files that are authored in the
# repo: tests, generated code and both spellings of a mock are left out. Needs only
# git, bash and python3: the Go module is a stub that records the files it is given.

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir "$WORK/skill"
cp -R "$SKILL_DIR/lib" "$SKILL_DIR/crap-check.sh" "$WORK/skill/"
cat > "$WORK/skill/lib/crap-check-go.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$CRAP_FILES" > "$STUB_SEEN"
STUB
chmod +x "$WORK/skill/lib/crap-check-go.sh"

REPO="$WORK/repo"
git init -qb main "$REPO"
printf 'x\n' > "$REPO/README"
git -C "$REPO" add README
GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
  git -C "$REPO" -c commit.gpgsign=false commit -q -m base
git -C "$REPO" checkout -qb feature

for name in a.go a_test.go mock_store.go store_mock.go q.sql.go m.pb.go; do
  printf 'package p\n' > "$REPO/$name"
done
git -C "$REPO" add -A

STUB_SEEN="$WORK/seen" "$WORK/skill/crap-check.sh" "$REPO" > "$WORK/out.log" 2>&1

SEEN="$(cat "$WORK/seen" 2>/dev/null || echo "<the Go module never ran>")"
if [ "$SEEN" = "a.go" ]; then
  echo "GO SELECTION OK"
else
  printf 'FAILED: the Go module was given:\n%s\nwant: a.go\n' "$SEEN"
  exit 1
fi
