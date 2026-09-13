# Testing

Most suites are bash scripts that exit 0 green, non-zero red, with no framework to
configure. The pytest unit suites under `hooks/` and `skills/crap-controlled-changes/test/unit/`
are the exception, driven by `pytest.ini` and `conftest.py`; see `run-python-tests.sh` below.

## Runners

```bash
bash scripts/run-hook-tests.sh          # every hooks/test-*.sh; needs only python3 and git
bash scripts/run-go-tests.sh            # the skill's suites; needs Go, python3, an ssh signing key
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

## How `run-go-tests.sh` selects suites

By **exclusion**, not by grepping for a `command -v go` guard. A new suite in
`skills/crap-controlled-changes/test/` runs there by default and opts out by name in
`NEEDS_OTHER_TOOLCHAIN`.

The rejected alternative matters: a guard-based rule could never match
`run-go-modules.sh`, which tests Go module resolution in pure Python and so never
carried the guard.

**A `SKIP:` line is a failure in this runner.** Every prerequisite the selected suites
need is installed, so a skip means an assumption the suite makes did not hold, not a
legitimate absence. Suites still skip normally when run by hand without a toolchain.

## Fixtures

Suites build their fixture repositories on first run, each with a guarded `git init` and
an explicit test identity with signing off. `fixture*/.git/` is gitignored on purpose:
committing it would produce gitlinks that clone as empty directories and break every
test.

A suite refuses to run rather than resetting a fixture that has uncommitted changes.
Discard them yourself if that is what you want; the refusal message names the commands.

## What CI installs

`.github/workflows/ci.yml` runs seven jobs. Three details are load-bearing:

- The `hooks` job runs on **ubuntu and macOS**, because hooks resolve paths and symlinks
  differently and macOS reaches `/tmp` through `/private`. It installs a modern bash,
  since GitHub's macOS image resolves `env bash` to the 3.2 Apple ships and the gates
  correctly refuse below 4.0.
- The `go` job installs python3 alongside Go. Most selected suites shell out to
  `python3`, and so do the three gates themselves, so it is a declared prerequisite
  rather than a runner-image accident.
- The `python` job also runs on **ubuntu and macOS**, for the same reason as `hooks`:
  `copilot_session_evidence.py`'s permission checks and `contributing-gate.py`'s symlink
  comparison are exactly the platform-sensitive code that matrix exists to catch.

No job installs a live PHP toolchain or `uv`, so the PHP-live and Python mutation suites
are verified by hand only.
