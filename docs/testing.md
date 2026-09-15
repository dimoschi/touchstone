# Testing

Most suites are bash scripts that exit 0 green, non-zero red, with no framework to
configure. The pytest unit suites under `hooks/` and `skills/crap-controlled-changes/test/unit/`
are the exception, driven by `pytest.ini` and `conftest.py`; see `run-python-tests.sh` below.

## Runners

```bash
bash scripts/run-hook-tests.sh          # every hooks/test-*.sh; needs only python3 and git
bash scripts/run-go-tests.sh            # the skill's Go-toolchain suites; needs Go, python3, an ssh signing key
bash scripts/run-php-python-tests.sh    # the skill's PHP/uv suites; needs a live PHP ^8.3 + infection + phpunit, and uv
bash scripts/run-python-tests.sh        # pytest unit suites for hooks/ and lib/; needs pytest + coverage>=7.13.1
bash workflows/test-fix-loop-join.sh    # the workflow's fix/verify/review loop
bash workflows/test-mutation-optin.sh   # marker opt-in behaviour
bash scripts/test-version-bump.sh       # check-version-bump.sh's own suite
```

The two `crap-commit.sh` suites need an ssh key for `CRAP_SIGNING_KEY` (defaulting to
`~/.ssh/id_ed25519`) and a matching entry in `gpg.ssh.allowedSignersFile`.
`lib/go_modules.py` now carries two independent suites: `run-go-modules.sh`, pure Python
but still run by the Go runner for lack of moving it, and `test/unit/test_go_modules.py`,
which runs under `run-python-tests.sh` instead.

`run-python-tests.sh` runs `coverage run -m pytest` over `hooks/test_*.py` and
`skills/crap-controlled-changes/test/unit/`, then enforces a 90% combined floor. These
suites drive every module in-process (calling `main()` directly, never `subprocess`),
which is what lets `coverage run -m pytest` see them: the CRAP gate's own Python module
runs the configured suite twice per commit, so a suite that only worked via a subprocess
round-trip would need parallel coverage collection this repo does not configure. Neither
coverage nor pytest need to be importable in the active environment; set `CRAP_PY_RUN`
to a launcher (e.g. `uv run --no-project --with coverage>=7.13.1 --with pytest --`, no
inner quotes: the value is expanded unquoted, so a quoted spec reaches the launcher as a
literal string containing quote characters) when they are not. These suites do not
replace `run-hook-tests.sh` or `run-go-tests.sh`,
which still drive the CLIs end to end and assert on their output.

## Running one suite

Call it directly. Nothing needs a runner.

```bash
bash hooks/test-crap-commit-gate.sh
bash skills/crap-controlled-changes/test/run-mutation-go.sh
```

Neither workflow suite takes a scenario filter; both run every scenario they define.

`skills/crap-controlled-changes/test/run-repo-arg.sh` covers the optional leading
`<absolute-repo-path>` argument that `crap-check.sh`, `mutation-check.sh` and
`deadcode-check.sh` accept (matching `crap-commit.sh`'s existing one): given a
path, a gate measures that repository and never the process cwd, and every gate
prints the repo root and branch it resolved as the first line of its output on
every code path. Needs only git, bash and python3, since nothing in it mutates
code.

`skills/crap-controlled-changes/test/run-python-subproject.sh` covers a Python
project living in a repo subdirectory: no `CRAP_PY_PROJECT_DIR` refuses and
names it, the variable measures it for real, and a changed file no test
imports still exits 4 rather than a false 0%. It needs `uv`, so it runs under
`run-php-python-tests.sh` alongside `run-python-e2e.sh`, not under
`run-go-tests.sh`.

## How the two runners select suites

`scripts/lib/skill-suites.sh` holds one list, `NEEDS_OTHER_TOOLCHAIN`, naming every
suite in `skills/crap-controlled-changes/test/` that needs a live PHP toolchain or
`uv`. `run-go-tests.sh` runs discovered `run*.sh` suites **minus** that list;
`run-php-python-tests.sh` runs the **intersection** with it. The two sets are
complements of one discovery, so a new suite runs under `run-go-tests.sh` by default
and opts out (into `run-php-python-tests.sh`) only by being added to the list.

Selection is by exclusion, not by grepping each suite for a `command -v go`/`uv`
guard: that rule could never match `run-go-modules.sh`, which tests Go module
resolution in pure Python and so never carried one.

**A `SKIP:` line is a failure in both runners.** Every prerequisite the selected
suites need is installed in their own job, so a skip means an assumption the suite
makes did not hold, not a legitimate absence. Suites still skip normally when run by
hand without a toolchain. `run-php-python-tests.sh` also fails if discovery finds
fewer suites than `NEEDS_OTHER_TOOLCHAIN` names: a name in the list that no longer
exists on disk is stale and would otherwise silently shrink the job.

## Fixtures

Suites build their fixture repositories on first run, each with a guarded `git init` and
an explicit test identity with signing off. `fixture*/.git/` is gitignored on purpose:
committing it would produce gitlinks that clone as empty directories and break every
test.

A suite refuses to run rather than resetting a fixture that has uncommitted changes.
Discard them yourself if that is what you want; the refusal message names the commands.

## What CI installs

`.github/workflows/ci.yml` runs eight jobs. Four details are load-bearing:

- The `hooks` job runs on **ubuntu and macOS**, because hooks resolve paths and symlinks
  differently and macOS reaches `/tmp` through `/private`. It installs a modern bash,
  since GitHub's macOS image resolves `env bash` to the 3.2 Apple ships and the gates
  correctly refuse below 4.0.
- The `go` job installs python3 alongside Go. Most selected suites shell out to
  `python3`, and so do the three gates themselves, so it is a declared prerequisite
  rather than a runner-image accident.
- The `php-python` job installs a live PHP ^8.3 toolchain (with a pcov coverage driver,
  phpunit and infection) and `uv`, and runs `scripts/run-php-python-tests.sh`: the
  suites the `go` job excludes because it installs neither.
- The `python` job also runs on **ubuntu and macOS**, for the same reason as `hooks`:
  `copilot_session_evidence.py`'s permission checks and `contributing-gate.py`'s symlink
  comparison are exactly the platform-sensitive code that matrix exists to catch.
