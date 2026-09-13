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
- This repo does not gate itself. There is no `.crap-gated` marker, because the Python
  gate cannot measure `lib/*.py` while it is tested only by shell suites. Do not create
  the marker to "fix" this.
