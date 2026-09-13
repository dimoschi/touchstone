# AGENTS.md

Guidance for coding agents working in this repository. `CLAUDE.md` is a symlink to this
file, so Claude Code reads it too.

## What this repo is

A plugin, not an application. What ships is installed into *other* repositories and
executed there: the gate scripts under `skills/crap-controlled-changes/`, the policy
gates in `hooks/`, and the delivery orchestration in `workflows/deliver-pipeline.js`.

The gates run on Claude Code and Copilot, from two manifests over one set of scripts.
Adding or changing a gate means touching both manifests.

Read [docs/architecture.md](docs/architecture.md) before changing any of the three.

## Commands

```bash
bash scripts/run-hook-tests.sh          # needs only python3 and git
bash scripts/run-go-tests.sh            # needs Go, python3, an ssh signing key
bash scripts/run-python-tests.sh        # needs pytest + coverage>=7.13.1 (or CRAP_PY_RUN)
bash workflows/test-fix-loop-join.sh
bash workflows/test-mutation-optin.sh
bash scripts/check-version-bump.sh
bash scripts/check-no-private-refs.sh
```

Running one suite, fixture handling, and what CI installs: [docs/testing.md](docs/testing.md).

## Rules that are easy to break by habit

- **Never pipe a gate**, not even into `tail`. `$?` after a pipeline is the last
  command's status, so a red gate reads as a pass. Redirect and read the file:
  `<gate> > /tmp/gate.log 2>&1; echo "EXIT=$?"`. A hook refuses the piped form.
- **Never hand-edit a ledger** under the git dir to clear a failure. A gate that can be
  satisfied by editing its own record measures nothing.
- **Bump `version` in `.claude-plugin/plugin.json`** in the same PR as any change under
  `workflows/`, `hooks/`, `skills/`, `agents/` or `commands/`. `claude plugin update`
  keys its cache on that string, so an unbumped change is invisible to every existing
  install. `check-version-bump.sh` enforces it; the reasoning is in the README's
  Versioning section.
- **bash 4.0 is the floor.** macOS ships 3.2 as `/bin/bash`. Guard `"${arr[@]}"` on
  possibly-empty arrays under `set -u`, since bash before 4.4 treats that as unbound.
- **Exit 2 and exit 4 are not passes.** They mean setup problem and could-not-measure.
  Full table in [docs/architecture.md](docs/architecture.md).

## Conventions

- python3 does the real work; bash orchestrates. Prefer extending a `lib/*.py` parser
  over growing a shell script.
- Scripts resolve their own location from `${BASH_SOURCE[0]}`, never the cwd, because
  they run from a version-keyed plugin cache rather than from this checkout.
- Comments here carry the WHY at unusual density, and most record a specific failure
  that already happened. Read them before changing the line they sit on.
- This repo gates itself: `.crap-gated` is committed at the root. `hooks/*.py` and
  `skills/crap-controlled-changes/lib/*.py` are measured by the pytest unit suites under
  `scripts/run-python-tests.sh`, which is what makes them real coverage instead of the
  0%/no-data the Python gate reported before those suites existed. The marker also
  exempts three things it cannot measure at all: `workflows/*.js` (no gate module scores
  JavaScript), the throwaway git fixtures under `skills/crap-controlled-changes/test/`
  that the skill's own suites copy into disposable repos to exercise the gate itself,
  and `lib/mainrange.go` (a `go:build ignore` helper with no enclosing `go.mod`). An
  exempted path is dropped from measurement entirely, for every language, not only from
  the unsupported-language refusal. Do not remove the marker or widen its exemptions
  without the repo owner's say-so.
- `.mutation-gated` is committed too, so `gh pr create`, `gh pr ready`, a merge onto a
  base branch and a push at one all run `mutation-check.sh --verify` first and block
  while the ledger is unverified. `--verify` reads the ledger and needs nothing
  installed; a real run needs mutmut and pytest, which are not importable from the
  system python3 here, so pass
  `MUTATION_PY_RUN='uv run --no-project --with mutmut --with pytest --'`. Exempt paths
  live in `.crap-gated`, never in this marker: `mutation-check.sh` reads that marker's
  patterns for its own selection so there is one list rather than two. `conftest.py` and
  `test_*.py` are outside mutation selection already, so a branch that only touches
  tests records a green run without mutating anything.
