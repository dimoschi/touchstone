#!/usr/bin/env bash
# A package's coverage measured on a tree is reused by any later run that needs
# it on the same tree, so a series of commits does not re-measure its baseline.
# Every reuse is checked against a run with the cache off: same rows, same tags.

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SKILL_DIR/crap-check.sh"

command -v go  >/dev/null || { echo "SKIP: go not on PATH"; exit 0; }
command -v git >/dev/null || { echo "SKIP: git not on PATH"; exit 0; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"
CALLS="$WORK/go-test.log"
VERSION_CALLS="$WORK/go-version.log"
mkdir -p "$REPO" "$WORK/bin"
cd "$REPO" || exit 1

# Logs each `go test` with its arguments, then runs the real go.
REAL_GO="$(command -v go)"
# A test run in the repo itself (the current one, not the baseline worktree)
# first runs and removes $WORK/during when that exists.
cat > "$WORK/bin/go" <<EOF
#!/usr/bin/env bash
[ "\${1:-}" = test ] && printf '%s\n' "\$*" >> "$CALLS"
[ "\${1:-}" = version ] && echo >> "$VERSION_CALLS"
if [ "\${1:-}" = test ] && [ -f "$WORK/during" ] && [ "\$(pwd -P)" = "\$(cd "$REPO" && pwd -P)" ]; then
  bash "$WORK/during" && rm -f "$WORK/during"
fi
exec "$REAL_GO" "\$@"
EOF
chmod +x "$WORK/bin/go"
export PATH="$WORK/bin:$PATH"

commit() {
  GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
    git -c commit.gpgsign=false commit -q -m "$1"
}

failures=0
check() { # check <description> <condition-exit-status>
  if [ "$2" -eq 0 ]; then echo "  ok: $1"; else echo "  FAIL: $1"; failures=$((failures + 1)); fi
}

# gate: one gate run; sets OUT, STATUS, RUNS (the go test calls it made) and
# VERSIONS (its go version calls, one per build configuration it read).
gate() {
  : > "$CALLS"
  : > "$VERSION_CALLS"
  STATUS=0
  OUT="$(env -u CRAP_GO_TEST_COMMAND bash "$SCRIPT" 2>&1)" || STATUS=$?
  RUNS="$(wc -l < "$CALLS" | tr -d ' ')"
  VERSIONS="$(wc -l < "$VERSION_CALLS" | tr -d ' ')"
  check "clean exit (exit $STATUS)" "$STATUS"
  [ "$STATUS" -eq 0 ] || printf '%s\n' "$OUT" | head -25 | sed 's/^/    | /'
}

expect_runs() { # expect_runs <n> <description>
  local r=0
  [ "$RUNS" -eq "$1" ] || r=1
  check "$2 ($RUNS go test runs, want $1)" "$r"
}

# fresh: the same staged change measured with the cache off gives the same output.
fresh() {
  local out status=0 r=0
  out="$(env -u CRAP_GO_TEST_COMMAND CRAP_BASELINE_CACHE=0 bash "$SCRIPT" 2>&1)" || status=$?
  { [ "$status" -eq "$STATUS" ] && [ "$out" = "$OUT" ]; } || r=1
  check "same rows as with the cache off" "$r"
}

# write_pkg <dir> <func> <n>: an unchanged, half-tested <func> (so its row's
# "unchanged" tag depends on the baseline's coverage being right) and n small
# tested functions. Every case uses its own n, so no two cases stage one tree.
write_pkg() {
  local dir="$1" fn="$2" n="$3" i
  mkdir -p "$dir"
  {
    printf 'package %s\n\nfunc %s(x int) string {\n\tif x < 0 {\n\t\treturn "neg"\n\t}\n\treturn "pos"\n}\n' "$dir" "$fn"
    for i in $(seq 1 "$n"); do printf '\nfunc %s%d() int {\n\treturn %d\n}\n' "$fn" "$i" "$i"; done
  } > "$dir/$dir.go"
  {
    printf 'package %s\n\nimport "testing"\n\nfunc Test%s(t *testing.T) {\n' "$dir" "$fn"
    printf '\tif %s(5) != "pos" {\n\t\tt.Fatal("pos")\n\t}\n' "$fn"
    for i in $(seq 1 "$n"); do printf '\tif %s%d() != %d {\n\t\tt.Fatal("%d")\n\t}\n' "$fn" "$i" "$i" "$i"; done
    printf '}\n'
  } > "$dir/${dir}_test.go"
}

git init -qb main
printf 'module example.com/br\n\ngo 1.26\n' > go.mod
write_pkg alpha Sign 0
write_pkg beta Step 0
git add . && commit base

echo "case 1: the first commit measures its baseline"
write_pkg alpha Sign 1 && git add alpha
gate
expect_runs 2 "baseline and change measured"
commit c1

echo "case 2: the next commit reuses what the last run measured"
write_pkg alpha Sign 2 && git add alpha
gate
expect_runs 1 "only the change measured"
r=0; printf '%s\n' "$OUT" | grep -qE '^alpha\.Sign .*\(unchanged\)' || r=1
check "the half-tested function reads unchanged against the reused baseline" "$r"
fresh
commit c2

echo "case 3: only the package not yet measured on this tree is tested"
write_pkg alpha Sign 3 && write_pkg beta Step 1 && git add alpha beta
gate
expect_runs 2 "baseline for beta and change measured"
first="$(sed -n 1p "$CALLS")"
r=1
case "$first" in *alpha*) ;; *beta*) r=0 ;; esac
check "baseline run tests beta alone: $first" "$r"
r=0; [ "$VERSIONS" -eq 2 ] || r=1
check "build configuration read once per module and phase ($VERSIONS reads, want 2)" "$r"
fresh
git reset -q --hard HEAD

echo "case 4: a run with unstaged changes is not reused"
write_pkg alpha Sign 4 && git add alpha
write_pkg beta Step 2
gate
git checkout -q -- beta && commit c3
write_pkg alpha Sign 5 && git add alpha
gate
expect_runs 2 "baseline measured again"
fresh
git reset -q --hard HEAD

echo "case 5: a run with an untracked file is not reused"
write_pkg alpha Sign 6 && git add alpha
printf 'package alpha\n\nconst Extra = 1\n' > alpha/extra.go
gate
rm alpha/extra.go && commit c4
write_pkg alpha Sign 7 && git add alpha
gate
expect_runs 2 "baseline measured again"
fresh
git reset -q --hard HEAD

echo "case 6: a run with an ignored file in a Go package is not reused"
printf 'ignored.txt\n' > .gitignore && git add .gitignore && commit ignore
write_pkg alpha Sign 8 && git add alpha
mkdir -p alpha/testdata && echo x > alpha/testdata/ignored.txt
gate
rm -r alpha/testdata && commit c5
write_pkg alpha Sign 9 && git add alpha
gate
expect_runs 2 "baseline measured again"
fresh
git reset -q --hard HEAD

# The tracked files after alpha's push `git ls-files -v` past a pipe buffer
# beyond the matching line, so a check that stops reading early is caught.
echo "case 7: a run with an assume-unchanged file is not reused"
mkdir zz && for i in $(seq 1 5000); do echo "$i" > "zz/f$i.txt"; done
git add zz && commit padding
write_pkg alpha Sign 10 && git add alpha && commit c6
git update-index --assume-unchanged alpha/alpha_test.go
write_pkg alpha Sign 11 && git add alpha/alpha.go
printf '\nfunc TestNeg(t *testing.T) {\n\tif Sign(-1) != "neg" {\n\t\tt.Fatal("neg")\n\t}\n}\n' >> alpha/alpha_test.go
gate
git update-index --no-assume-unchanged alpha/alpha_test.go
git checkout -q -- alpha/alpha_test.go && commit c7
write_pkg alpha Sign 12 && git add alpha
gate
expect_runs 2 "baseline measured again"
fresh
git reset -q --hard HEAD

echo "case 8: a checkout changed while the tests run is not reused"
write_pkg alpha Sign 13 && git add alpha
cp alpha/alpha_test.go "$WORK/staged_test.go"
cat > "$WORK/during" <<EOF
cd "$REPO" && printf '\nfunc TestNeg(t *testing.T) {\n\tif Sign(-1) != "neg" {\n\t\tt.Fatal("neg")\n\t}\n}\n' >> alpha/alpha_test.go && git add alpha/alpha_test.go
EOF
gate
r=0; [ ! -f "$WORK/during" ] || r=1
check "the edit ran during the current tests" "$r"
cp "$WORK/staged_test.go" alpha/alpha_test.go && git add alpha && commit c8
write_pkg alpha Sign 14 && git add alpha
gate
expect_runs 2 "baseline measured again"
fresh
git reset -q --hard HEAD

# beta's tests cover alpha.Sign's negative branch, so a run of both stores more
# coverage for alpha than alpha's own tests give.
echo "case 9: coverage from other packages' tests (-coverpkg) is not reused"
export GOFLAGS=-coverpkg=./...
write_pkg alpha Sign 15 && write_pkg beta Step 3
printf 'package beta\n\nimport (\n\t"testing"\n\n\t"example.com/br/alpha"\n)\n\nfunc TestNeg(t *testing.T) {\n\tif alpha.Sign(-1) != "neg" {\n\t\tt.Fatal("neg")\n\t}\n}\n' > beta/cross_test.go
git add alpha beta
gate
commit c9
write_pkg alpha Sign 16 && git add alpha
gate
expect_runs 2 "baseline measured again"
fresh
unset GOFLAGS
git reset -q --hard HEAD

echo "case 10: a go.work in the repo does not stop reuse"
go work init . && git add go.work && commit work
write_pkg alpha Sign 17 && git add alpha
gate
commit c10
write_pkg alpha Sign 18 && git add alpha
gate
expect_runs 1 "only the change measured"
fresh
git reset -q --hard HEAD

echo "case 11: an ignored file outside the Go packages does not stop reuse"
printf 'node_modules/\n' >> .gitignore && git add .gitignore && commit ignore-nm
mkdir -p node_modules/x && echo x > node_modules/x/index.js
write_pkg alpha Sign 19 && git add alpha
gate
commit c11
write_pkg alpha Sign 20 && git add alpha
gate
expect_runs 1 "only the change measured"
fresh
git reset -q --hard HEAD

echo ""
if [ "$failures" -eq 0 ]; then echo "GO BASELINE REUSE OK"; else echo "FAILED: $failures assertion(s)"; exit 1; fi
