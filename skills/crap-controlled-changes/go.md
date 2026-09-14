# Signal B: Go Procedure

Run this from the repo root after staging your changes (`git add ...`).

## Setup

None. The helper invokes `go run github.com/padiazg/go-crap@v0.5.0 scan` directly, so it uses the project's active Go toolchain (mise / asdf / system). The version is pinned; override with `CRAP_GO_GOCRAP_VERSION`. The first run in a given Go version downloads and compiles it; subsequent runs are served from Go's build cache.

## Recommended: Use the Helper

```bash
crap-check.sh
# or, to target a repo other than the process cwd (e.g. a worktree):
crap-check.sh <absolute-repo-path>
```

Every run prints the repo root and branch it resolved as its first line of output,
on every code path (`--accept`, `--mark-scored`, `--anchor-committed`, and a plain
run alike). With no leading path it resolves from the cwd, exactly as before; a
leading path that is not a git repository refuses with exit 2 rather than
falling back to the cwd.

The helper:

1. Verifies you are inside a git repo (or that the given path is one) and that `go` is on PATH.
2. Identifies changed `.go` files (excluding `_test.go`) from the staged diff.
3. Checks HEAD out into a throwaway detached worktree and measures there (baseline), then measures your working tree (current). Your index and the stash are never touched, so concurrent runs in different worktrees cannot interfere.
4. Joins the two outputs by `<pkg>.<func>` and prints one row per changed function:

   ```
   <pkg>.<Func>  complexity=<c>  coverage=<cov>%  CRAP=<score>  [OK|SOFT|HARD|NEEDS_TESTS|OK_MAIN|HARD_MAIN]  (new|unchanged|worsened)
   ```

Coverage profiles are written to temp files and removed after each measurement; nothing is left in the working tree.

After the CRAP table, the helper also runs `gocognit -over 15` on the same files and prints a "Cognitive complexity" section if any function exceeds the threshold. This is advisory (see SKILL.md).

Apply the Decision Policy in `SKILL.md` to the output.

### If `go test ./...` can't pass locally

Coverage comes from `go test ./...` by default, run by the helper rather than by go-crap. In a monorepo where the default package set includes integration suites that need a live service (Postgres, RabbitMQ, and the like), that command fails everywhere, every time, regardless of your change, and there is no trustworthy coverage to score.

`crap-check-go.sh` treats this as a hard failure, not a silent pass: it exits non-zero and prints the run's stdout/stderr so you can see why. It fails on the coverage command's exit status, not just on an empty profile, because a partly failing suite still writes a profile for the packages that passed and scoring against that would be a false pass. This is also why go-crap is never allowed to run the tests itself: its own run reports every function at 0% coverage when it collects none, prints nothing, and exits 0. Override the test command with `CRAP_GO_TEST_COMMAND` to scope it to packages that can actually run:

```bash
CRAP_GO_TEST_COMMAND='go test ./internal/...' \
  crap-check.sh
```

Pick a package set that covers the function you changed and excludes anything requiring infrastructure you don't have locally.

### If the baseline fails to build but HEAD is fine

`git stash push --include-untracked` stashes untracked files but **not ignored** ones (that needs `--all`). During the baseline phase the working tree therefore holds HEAD's sources alongside the current tree's *ignored* files. If an over-broad `.gitignore` rule is hiding generated code, that mixture may not compile, and the failure looks like it is HEAD's fault when it isn't.

The classic case: an unanchored rule meant for a build binary, say `myapp`, also matches the directory `internal/myapp/`, so every generated mock in it is ignored. The baseline then builds HEAD's interfaces against the current tree's regenerated mocks.

When ignored source files are present, the diagnostic names them and labels the phase `baseline (HEAD) + N ignored files from working tree`. The fix is in the repo, not the gate:

- Track the generated files if they are needed to build (mocks, sqlc, protobuf), or
- Anchor the ignore rule (`/myapp` rather than `myapp`).

The gate deliberately does **not** use `git stash push --all`. That would hide the underlying problem, and stashing build caches, vendored trees, and `.env` files is slow and risks losing them. Reporting is safer than hiding.

Note that the selection excludes in `crap-check.sh` (`*_test.go`, `*mock_*.go`, `*.sql.go`) control only which files get *scored*. They have no effect on the stash: an excluded file still sits in the working tree during the baseline and still has to compile.

### Exit codes

| Code | Meaning |
|------|---------|
| 0 | Measured successfully (may be zero functions, e.g. a comment-only change) |
| 2 | Setup problem (not a git repo, `go` missing, missing module) |
| 3 | Stash restore failed — resolve the working tree manually |
| 4 | Could not measure: the coverage run failed or no CRAP report was produced. Not a pass — see the printed diagnostic and consider `CRAP_GO_TEST_COMMAND` |
| 5 | Nothing staged, but HEAD already touched supported-language source — you likely committed before running this. Re-stage or diff `HEAD~1..HEAD` manually |

## Manual Equivalent (if the helper is unavailable)

1. Identify changed Go files:
   ```bash
   git diff --name-only --cached | grep '\.go$' | grep -v _test.go
   ```
2. Capture the current report, restricted to changed files:
   ```bash
   go test ./... -coverprofile=/tmp/cover.out -covermode=set
   go run github.com/padiazg/go-crap@v0.5.0 scan ./path/to/pkg --coverage-profile /tmp/cover.out
   ```
3. For a baseline at HEAD, stash first (`git stash push --include-untracked`), repeat step 2, then `git stash pop`.
4. Compare the two reports per `<pkg>.<func>`. Apply thresholds: ≤6 OK, (6, 8] SOFT, >8 HARD. For `package main`, use complexity only with threshold ≤5.
5. If coverage <80% and the function is new or worsened, the status is `NEEDS_TESTS` regardless of CRAP — add tests first, do not refactor.

The helper exists to keep you from getting the stash dance and the join wrong.

## Signal C: What the mutation gate will do to your Go code

Catalog for the pinned mutago (v2.8.1, `docs/mutators.md` in the module). Read the
right-hand column as an obligation you take on the moment you write the construct:
if no test distinguishes the mutant, the gate will find it, and it is cheaper to
write the assertion now than to come back for it.

| Mutator | What it does | What kills it |
| :--- | :--- | :--- |
| `expression/error-guard` | `if err != nil` becomes `if false` | a test that actually enters the error branch |
| `expression/errorf-wrap` | `%w` becomes `%v`, same message, no longer wraps | `errors.Is`/`errors.As` on the cause, not just `err != nil` |
| `statement/return` | every return value becomes its zero value | asserting the returned value, not just that an error is non-nil |
| `expression/comparison` | flips `<` `<=` `>` `>=` `==` `!=` | a case on each side of the boundary, including the boundary itself |
| `expression/string-literal` | `s == "expected"` becomes `s == ""` | asserting the actual string, not just that a branch was taken |
| `conditional/negated`, `conditional/not` | inverts conditions, drops `!` | both truth values reaching different observable outcomes |
| `branch/if`, `branch/else`, `branch/case` | removes a branch body | one assertion per arm, distinguishable from the others |
| `statement/remove` | drops an assignment or call statement | asserting the effect of the statement, not that the function returned |
| `statement/defer-remove` | `defer f()` becomes `f()` | a test that fails if cleanup runs too early (unlock, close) |
| `expression/context-nil` | passes `nil` where a `ctx` was passed | asserting cancellation or deadline propagation |
| `expression/recover-clear` | `recover()` becomes `any(nil)`, so a panic propagates | a test that panics and asserts the recovery |
| `composite/field-clear` | drops a field from a struct literal | asserting each field that matters downstream |
| `arithmetic/*`, `numbers/*` | swaps operators, off-by-one on integer constants | asserting exact numeric values |
| `concurrency/goroutine-remove`, `select/*` | `go f()` runs inline, drops select arms | asserting the concurrent effect, not just absence of error |

Mutants inside `func main()` are exempted and listed on stderr, so entry-point
wiring does not block, wherever that function lives. A command's whole entry
file, `cmd/<x>/main.go`, is excluded from scoring outright, so nothing in it
is listed on stderr either; a sibling in the same directory (flag parsing,
config merging, subcommand wiring) is not the entry file and blocks normally.

**The two obligations that account for most survivors in this codebase:**

1. **Every error path you add needs a test that enters it and asserts the message
   prefix and the wrapped cause.** One `if err != nil { return fmt.Errorf("x: %w",
   err) }` with no test yields three or four survivors on its own
   (`error-guard`, `errorf-wrap`, `statement/return`), which is why a single
   untested error branch looks like a crop of failures rather than one gap.
2. **A branch you cannot construct an input for is dead code, not safety.** Decide
   at write time: if every caller is known and it is unreachable, delete it and
   record why in a comment; otherwise write the test. Do not wait for the gate,
   and never delete a branch *because* a survivor appeared, which is
   indistinguishable from weakening the code to dodge the mutant.

## Running the gate in a repo with build tags or a test database

The mutation gate runs the repo's real suite once per mutant, so it needs the same
environment the suite needs. Supply it on the command line:

```
GOWORK=off GOFLAGS=-tags=<your build tags> CGO_ENABLED=0 \
  <YOUR_TEST_DB_DSN_VAR>="postgres://user:pass@localhost:5432/db?sslmode=disable" \
  mutation-check.sh <absolute-repo-path>
```

Each part earns its place:

- **Build tags.** A module whose real files sit behind a tag compiles tagless
  without one, and the gate then measures a different program than the one you
  ship. Pass whatever tag the suite normally builds with.
- **`GOWORK=off`** keeps a local `go.work` out of it, so the measurement matches
  what CI would build.
- **A pre-provisioned test database.** Without a DSN pointing at a running
  instance, every database-backed package starts its own container *per mutant*.
  That is the difference between minutes and hours, and it is the single largest
  factor in how long a run takes.

A missing DSN shows up as exit 4, FAILED TO MEASURE, never as a pass.
