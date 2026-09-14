# Signal B: Python Procedure

Run this from the repo root after staging your changes (`git add ...`).

## Setup

The Python module needs:

1. **`uv` / `uvx` on PATH.** Complexity (`radon`) and cognitive complexity
   (`complexipy`) run ephemerally via `uvx`, so no project changes are required
   (the Python analogue of Go's `go run ...@latest`). The first run downloads
   each tool; subsequent runs are cached.
2. **coverage.py (>=7.13.1) and pytest in the project environment.** Coverage must
   instrument the real test run, so it runs inside the project's own env, not in
   isolation. The floor is 7.13.1, not merely "7": that release is what puts a
   `start_line` on each entry in `coverage json`'s per-function `functions` map,
   which is the key `lib/parse_python.py` joins radon's complexity against. An
   older coverage produces a JSON the joiner silently reads as 0% coverage for
   every function. The default test command is `coverage run -m pytest`. If your
   env needs a launcher, set `CRAP_PY_RUN` (e.g. `poetry run`, `uv run`).
3. **Python 3** on PATH (used by the joiner in `lib/parse_python.py`).

If `coverage` is not runnable the helper prints a remediation hint.

## Recommended: Use the Helper

```bash
crap-check.sh
# or, to target a repo other than the process cwd (e.g. a worktree):
crap-check.sh <absolute-repo-path>
```

Every run prints the repo root and branch it resolved as its first line of
output. With no leading path it resolves from the cwd, exactly as before; a
leading path that is not a git repository refuses with exit 2 rather than
falling back to the cwd.

The dispatcher detects staged `.py` files (excluding `test_*.py`, `*_test.py`,
`tests/**`, and `conftest.py`) and invokes `lib/crap-check-python.sh`. That
module:

1. Stashes any other working-tree changes.
2. Runs the test suite under coverage and `radon cc -j` against HEAD (baseline).
3. Restores your working tree.
4. Re-runs both against the staged changes (current).
5. Joins per function by `(file, start_line)` (`lib/parse_python.py`), classifies
   with the same thresholds Go and PHP use, and prints one row per changed
   function/method:

   ```
   <relpath>::<name>  complexity=<c>  coverage=<cov>%  CRAP=<score>  [OK|SOFT|HARD|NEEDS_TESTS]  (new|unchanged|worsened)
   ```

   `<name>` is `Class.method` for methods, the bare name for functions.

After the CRAP table, the helper runs `complexipy -mx 15 -f` on the changed
files and prints a "Cognitive complexity (advisory, >15)" section if anything
exceeds the threshold. This is advisory (see SKILL.md). There is no
`OK_MAIN`/`HARD_MAIN`: Python has no `package main` analogue in v1.

Apply the Decision Policy in `SKILL.md` to the output.

## Subdirectory projects

The suite and coverage run from the repo root by default, which only works if
the project's config (`pyproject.toml`'s `[tool.coverage.run]` /
`[tool.pytest.ini_options]`, or `.coveragerc`) also resolves from there. A
project one level down in a monorepo needs its own directory:

```bash
CRAP_PY_PROJECT_DIR=services/api crap-check.sh
```

Resolution order:

1. `CRAP_PY_PROJECT_DIR`, if set (absolute, or relative to the repo root).
2. The repo root, unless a changed file sits under a subdirectory whose own
   `pyproject.toml` declares `[tool.coverage.run]` or `[tool.pytest.ini_options]`,
   in which case the module refuses (exit 2) and names that subdirectory
   rather than silently measuring with the wrong config.

A repo whose Python project sits at the git root never trips the refusal:
only a `pyproject.toml` strictly below the root, with one of those two
section headers, does.

## Performance

The configured pytest suite runs **twice** (baseline + current). Scope it via:

```bash
CRAP_PY_PYTEST_ARGS="tests/unit -k somepattern" crap-check.sh
```

## Env overrides

| Var | Default | Purpose |
|-----|---------|---------|
| `CRAP_PY_RUN` | *(empty)* | Prefix for in-env commands (`poetry run`, `uv run`) |
| `CRAP_PY_PYTEST_ARGS` | *(empty)* | Extra pytest args to scope/speed the suite |
| `CRAP_PY_RADON` | `uvx radon` | Override to a project-local `radon` |
| `CRAP_PY_COMPLEXIPY` | `uvx complexipy` | Override to a project-local `complexipy` |
| `CRAP_PY_PROJECT_DIR` | *(repo root)* | Directory to run the suite and coverage from; see Subdirectory projects |

## Manual Equivalent (if the helper is unavailable)

1. Identify changed Python files:
   ```bash
   git diff --name-only --cached -- '*.py' ':(exclude)**/test_*.py' ':(exclude)tests/**'
   ```
2. Capture a current report:
   ```bash
   coverage run -m pytest && coverage json -o cur-cov.json
   uvx radon cc -j path/to/changed1.py path/to/changed2.py > cur-radon.json
   CRAP_REPO_ROOT="$PWD" CRAP_CHANGED_FILES="$(git diff --name-only --cached -- '*.py')" \
     python3 lib/parse_python.py cur-radon.json cur-cov.json
   ```
3. For a baseline at HEAD, stash first (`git stash push --include-untracked`),
   repeat step 2, then `git stash pop`.
4. Compare per `<relpath>::<name>`. Apply thresholds: <=6 OK, (6, 8] SOFT, >8
   HARD. If coverage <80% and the function is new or worsened, the status is
   `NEEDS_TESTS` regardless of CRAP, add tests first, do not refactor.

The helper exists to keep the stash dance, the join, and the artifact cleanup
(`.complexipy_cache/`, `.coverage`) out of your hands.

## Mutation setup (Signal C)

`mutation-check-python.sh` drives mutmut 3, which needs `source_paths` in
`pyproject.toml` under `[tool.mutmut]` or in `setup.cfg` under `[mutmut]`. Four
things about it are easy to get wrong, and each fails quietly rather than loudly.

- **`source_paths` is not only "what to mutate".** mutmut copies every entry into
  `mutants/` and runs the suite there with that as the working directory. A test
  file or a `conftest.py` outside those paths does not exist in that tree, so
  collection fails or the mutants run against nothing. List the test directories
  too. An entry may be a single file, which is how a repo-root `conftest.py`
  gets there.
- **In `setup.cfg`, one path per line.** That reader splits a list value on
  newlines only, so a comma-separated value is read as one path of that literal
  name. It matches nothing and the run reports `0 files mutated` while exiting 0
  from generation. `pyproject.toml` takes a normal TOML array and is not affected.
- **`do_not_mutate` patterns are matched with `fnmatch` against the path as
  written.** `**/conftest.py` needs a literal `/` and so misses a `conftest.py`
  at a source-path root; list both spellings (`conftest.py` and `*/conftest.py`,
  `test_*.py` and `*/test_*.py`). A mutated `conftest.py` takes down mutmut's
  forced-fail self-check before it reports anything about your code.
- **A conftest that caches modules by name must key on the file too.** pytest's
  rootdir search reaches the original `conftest.py` as well as the copy inside
  `mutants/`, so the unmutated modules can claim the names first. Handing those
  back runs the suite against unmutated code, and every mutant then comes back
  `no tests`.

`mutants/` is mutmut's own cache: gitignore it.

Note that `no tests` is not a pass. The module reports such a mutant as a
survivor, exactly like `survived`, because a mutant no test exercises is a
change your suite cannot detect.

## Caveats and known gaps (prototype)

- A changed file that is **never imported by any test** produces no coverage
  data at all. In the current phase that is could-not-measure: the run exits 4
  and names the file rather than reporting a false `coverage=0.0%`. Import it
  from at least the unit suite. (Same blind spot Go's `_test.go`-only coverage
  and PHP's class-named tests have; here it refuses instead of scoring it.)
- **Closures and module-level code are not scored.** radon only surfaces
  top-level functions and methods, so nested functions and `if __name__ ==
  "__main__":` blocks don't get a CRAP row. Extract logic into named functions to
  bring it under the gate.
- coverage configuration (`.coveragerc` / `[tool.coverage]`) is respected.
  Aggressive `source`/`omit` filters that exclude a changed file will make its
  functions read as untested.
- **Async / greenlet stacks need `concurrency` set, or post-`await` lines
  under-report.** coverage's tracer is per thread/greenlet. If the project runs
  code via greenlets (SQLAlchemy async) or a threadpool (Starlette/FastAPI sync
  deps), `[tool.coverage.run]` must set `concurrency = ["greenlet", "thread"]`.
  Without it, lines that resume after an `await` crossing that boundary, e.g. a
  FastAPI handler's `return SomeResponse(...)`, read as missed even though the
  test exercised them, and new/renamed functions trip a false `NEEDS_TESTS`.
- **`coverage json` itself failing (import error, collection error) is a
  warning in either phase, not a hard failure.** There is then nothing
  per-file to tell "absent" from "zero", so the run falls back to scoring
  every function it can still join at `coverage=0.0%` instead. When gitignored
  `.py` files are present the warning names them: `git stash
  --include-untracked` does not stash ignored files, so they survive from the
  current tree into the baseline. See the same section in `go.md` for the full
  explanation. crap-check honors the project config, so fix it in
  `[tool.coverage.run]`, not in the tool. (Symptom: every async handler reads
  ~50% while directly-awaited service/repo functions read 100%.)
- **A single changed file missing from an otherwise-successful measurement is
  different.** The baseline (HEAD) phase treats it as a warning, since the
  file may simply be new since HEAD; the current phase treats it as
  could-not-measure and exits 4, per the caveat above.
