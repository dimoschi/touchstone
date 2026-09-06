# Touchstone

A Claude Code plugin. You hand it a ticket; it hands back a pull request that has
been measured.

*A touchstone is the stone used to assay gold, and in plain English, the standard
by which something is judged.*

```
/touchstone:deliver --ticket PROJ-4821
```

That cuts a branch and a worktree from a freshly pulled base, reads the ticket,
argues with its premise, plans, implements under TDD, reviews itself
adversarially, and opens a PR. At no point can it skip a gate to get there.

## What makes it different

Most autonomous coding agents open a pull request when the model believes the work
is done. Touchstone does not have that option. Three gates stand between the code
and the PR, and each one is a mechanical check with an exit code, not a prompt
asking the model to be careful:

| Gate | What it measures | When |
|---|---|---|
| **Dead code** | Static reachability. Code nothing can reach is not a feature. | Every commit |
| **CRAP** | `complexity² × (1 − coverage)³ + complexity` per *changed function*, ≤6 soft, ≤8 hard | Every commit |
| **Mutation** | Whether your tests actually fail when the code is wrong | Before the PR opens |

The mutation gate is the sharp one. Coverage asks whether a line ran; mutation
asks whether an assertion would notice if that line were wrong. A `PreToolUse`
hook runs it on `gh pr create`, so a red ledger blocks the PR at the tool call.
There is no flag to skip it, and the workflow's own instructions tell every agent
never to weaken production code to kill a mutant.

Touchstone is also **bounded**. Each stage carries an output-token ceiling and the
run halts rather than looping: a disproved premise stops before any code exists, a
dirty tree stops before it branches, and a plan that overruns stops before
implementing. Unbounded agent runs are where the money goes on trajectories that
merge nothing.

It is not a standalone agent. It runs on Claude Code's own subagents and needs no
sandbox, no server, and no API key beyond the one you already have.

## Install

```
/plugin marketplace add dimoschi/touchstone
/plugin install touchstone
```

Then opt a repository in. **Nothing is gated until you say so:**

```bash
cd your-repo
touch .crap-gated        # dead-code + CRAP gate on every commit, and the guide gate
touch .mutation-gated    # mutation gate before a PR can open
git add .crap-gated .mutation-gated
```

Both markers are committable, so opting in is one decision a team shares rather
than something each person configures. They are separate on purpose: the CRAP
ledger can always be made green by writing tests, but some codebases carry mutants
no test can ever kill (a string-heavy module where the mutator only flips the case
of case-insensitive keys). One shared marker made those repos unmergeable.

## Every run needs a ticket. This is deliberate

`--ticket` is required and the pipeline refuses without it. It will not infer
one from your task text.

```
/touchstone:deliver --ticket 216            # GitHub issue 216 in this repo
/touchstone:deliver --ticket PROJ-4821      # Jira key, via the Atlassian MCP
/touchstone:deliver refactor the retry path # refused: no --ticket
```

A bare number is read as a GitHub issue in the repo you are in, so **any repo
with Issues enabled already satisfies this** — you do not need Jira, or a
project, or any tracker beyond GitHub. `gh issue create` is the whole setup.

The reason it refuses rather than guessing: the ticket goes into the branch
name (`feat/gh-216-retry-path`), and every metric downstream reads it from
there. A guessed ticket bakes a fabricated link into that name permanently, and
nothing later can tell it was invented. Refusing is cheap; an unfabricated link
is not recoverable after the fact.

If a ticket cannot be *fetched* — Jira is down, the issue is private — the run
continues without its prose. Only the reference is mandatory, not the text.

## Requirements

Needed for the pipeline itself:

- **Claude Code** with dynamic workflows enabled (`/config`).
- **`gh`**, authenticated. Reads GitHub issues and opens the PR.
- **python3**, which the gates already use for all of their real logic.
- **bash 4.0 or newer.** macOS still ships bash 3.2 as `/bin/bash`; the gates
  refuse to run on it with a message naming the fix (`brew install bash`).
  Linux distributions already ship bash 5.

Needed per language you gate, and only then:

The gates score **Go, PHP and Python**. In a gated repo, staged source in any
other language that carries functions (TypeScript, Rust, Java, Ruby, Swift, C#,
Elixir and the like) is **refused**, not waved through: a gate that silently
passes what it cannot measure reports a guarantee it never checked. A repo that
genuinely mixes languages exempts paths by listing gitignore-style patterns in
its `.crap-gated` marker, one per line, so a Go service with a TypeScript
frontend can gate the Go and exempt `web/**`. Files that are not program source
— docs, config, SQL, shell — never trigger it.

| Language | Gate tooling |
|---|---|
| Go | [`go-crap`](https://github.com/padiazg/go-crap), [`mutago`](https://github.com/quality-gates/mutago), `golang.org/x/tools/cmd/deadcode` |
| PHP | Composer-managed PHPUnit, [Infection](https://github.com/infection/infection) with an `infection.json` declaring `source.directories` |
| Python | `pytest`, `coverage`, `radon`, [`mutmut`](https://github.com/boxed/mutmut) with `[tool.mutmut] source_paths` set |

The gate scripts tell you the exact install command when a tool is missing, and
exit 2 (setup problem) rather than reporting a pass.

Optional:

- **Jira** via the Atlassian MCP server, for `PROJ-1234`-style keys. A bare number
  is read as a GitHub issue instead. A ticket that cannot be fetched is not fatal:
  the pipeline proceeds without its prose.
- **[agent-eval](https://github.com/dimoschi/agent-eval)** records phase and
  outcome metrics so the gates have ground truth to be judged against. If it is
  not installed, every phase skips recording and carries on. Pass
  `{record: false}` to silence the instruction entirely.

## What it installs

```
commands/deliver.md              /touchstone:deliver — parses flags, refuses without a ticket
workflows/deliver-pipeline.js    the eight-phase orchestration
agents/planner.md                plan-only subagent, has no Edit or Write tool
skills/crap-controlled-changes/  the gates, their language modules, and their docs
hooks/                           seven PreToolUse gates
```

### The phases

1. **Worktree** — canonical branch and worktree off a freshly pulled base, then one ticket fetch shared by every later phase.
2. **Triage** — one cheap agent checks the ticket's premise and sizes the job. A disproved premise halts. Work under ten lines skips straight to Implement.
3. **Plan** — a planner with no write tools produces a plan, acceptance criteria and risk areas.
4. **Implement** — TDD via the skill, committing through `crap-commit.sh`, which runs both commit-time gates and refuses while either is red.
5. **Review** — adversarial reviewers on distinct lenses, chosen by diff size. Re-runs on commits any later phase adds.
6. **Fix** — confirmed findings only, bounded rounds. A verifier and an adversary then read the fix's own commits in parallel: independent questions, one turn.
7. **Mutation** — kill every survivor with a test. Its own commits get reviewed too.
8. **PR** — pushes and opens against the repo's template, only once every gate is green.

### The hooks

Five apply only to repos you opted in:

- `crap-commit-gate.py` — refuses raw `git commit`, names `crap-commit.sh` instead. It does not guess which repo a command targets; it resolves `git -C` and `cd` chains and refuses decidably.
- `mutation-pr-gate.py` — verifies the mutation ledger before `gh pr create`, a `git merge` onto a base branch, or a `git push` at one.
- `contributing-gate.py` — refuses the first edit until the repo's `CONTRIBUTING.md` has actually been Read this session. A repo shipping no guide is never gated.

Two apply everywhere, because each fires only on its own evidence:

- `base-branch-commit-gate.py` — refuses a commit on `main`/`master`/etc. Exempts a repo with no remote, since that work cannot reach anyone yet.
- `gate-pipe-gate.py` — refuses piping a gate anywhere. `$?` after a pipeline is the *last* command's status, so `mutation-check.sh | tail` reports tail's exit 0 however the gate ended, turning a red gate into a reported pass.
- `generated-file-gate.py` — refuses hand-editing a file whose own header says `@generated` or `DO NOT EDIT`. The marker is the file's consent, so this needs no repo opt-in.

## Signing

Touchstone does not decide whether your commits are signed. `crap-commit.sh` runs
plain `git commit` and lets git resolve `commit.gpgsign` and the key from your
own configuration, including conditional includes. It refuses only one thing: an
`*_sk` SSH key, which needs a hardware token that an unattended run cannot touch
and would hang waiting for rather than fail. Set `CRAP_SIGNING_KEY` to a key file
to override.

## Development

```bash
bash scripts/run-hook-tests.sh          # hook suites; needs only python3 and git
bash scripts/run-go-tests.sh            # the skill's Go suites; needs a Go toolchain, python3, and an ssh signing key
bash scripts/check-no-private-refs.sh   # no machine- or org-specific references
```

`run-go-tests.sh` runs every suite in `skills/crap-controlled-changes/test/`
except the ones needing a live PHP toolchain or `uv`, which this job does not
install. That includes dead-code, CRAP and mutation, the two `crap-commit.sh`
suites (which additionally need an ssh key for `CRAP_SIGNING_KEY`, defaulting
to `~/.ssh/id_ed25519`, and a matching entry in `gpg.ssh.allowedSignersFile`),
and `lib/go_modules.py`'s own test, which is pure Python and runs here for lack
of anywhere else. Several of the selected suites shell out to `python3`, so the
job installs it alongside Go rather than relying on the runner image to carry
it. Prerequisites installed but a suite still prints a `SKIP:` line is treated
as a failure, not a pass: it means an assumption the suite makes did not hold.

Two rules the CI enforces, both easy to break by habit:

- **Module resolution lives in one place.** `lib/go_modules.py` answers "which
  module owns this file" for all three Go gates. It used to be copy-pasted into
  each of them, which meant the gates could disagree about what to measure while
  all reporting green.

The skill's own suites live in `skills/crap-controlled-changes/test/` and need the
relevant language toolchain. Each builds its fixture repository on first run.

`check-no-private-refs.sh` looks for classes of leak (absolute home paths,
personal config paths, stray tracker keys) rather than a list of specific names,
since a committed list would publish exactly what it exists to exclude. Point
`TOUCHSTONE_PRIVATE_TERMS` at a local file of extra patterns for anything that
should not be written down in the repo.

## Prior art

[OpenHands](https://github.com/All-Hands-AI/OpenHands) and
[SWE-agent](https://github.com/SWE-agent/SWE-agent) are autonomous agents that own
the model loop and the sandbox, and they are judged on SWE-Bench resolve rate.
Touchstone is a much smaller thing pointed at a different problem: it assumes the
agent is competent and asks whether the change it produced can be shown to be
tested. If you want an autonomous software engineer, use those. If you want a
pipeline that will not let one open a PR on unmeasured code, use this.

## Licence

MIT. See [LICENSE](LICENSE).
