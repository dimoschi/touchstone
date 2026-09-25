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
| **CRAP** | `complexity² × (1 − coverage)³ + complexity` per *changed function*, ≤6 soft, ≤8 hard by default, set per repo in `.crap-gated` | Every commit |
| **Mutation** | Whether your tests actually fail when the code is wrong | Before the PR opens |

The mutation gate is the sharp one. Coverage asks whether a line ran; mutation
asks whether an assertion would notice if that line were wrong. A `PreToolUse`
hook runs it on `gh pr create`, so a red ledger blocks the PR at the tool call.
There is no flag to skip it, and the workflow's own instructions tell every agent
never to weaken production code to kill a mutant.

Touchstone is also **bounded**. Each stage carries an output-token ceiling and the
run halts rather than looping: a disproved premise stops before any code exists, an
unresolvable base ref stops before it branches, and a plan that overruns stops before
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
printf '\\bTODO\\b\n' > .comment-gated   # flags a newly added comment matching any rule below, one regex per line
git add .crap-gated .mutation-gated .comment-gated
git commit -m "Opt in to touchstone's gates"
```

Run this from a plain terminal, not inside a Claude Code session: the two `touch` lines
just gated the repo, and `crap-commit-gate.py` refuses a raw `git commit` from that point
on, naming `crap-commit.sh` instead (see [Signing](#signing)).

All three markers are committable, so opting in is one decision a team shares
rather than something each person configures. `.crap-gated` and `.mutation-gated`
are plain booleans (present or absent); `.comment-gated` instead carries the
policy itself, so `touch .comment-gated` alone flags nothing until you add a
rule line. `.crap-gated`/`.mutation-gated` resolve to the same file at the repo
root for every worktree even while only staged; `.comment-gated` instead has to
already sit on disk in the worktree actually being edited, a plain filesystem
check. It does not need to be tracked or committed at all, but a copy that
only exists in the main checkout (staged, committed, or otherwise) is invisible
to a linked worktree (where this pipeline's own runs happen) unless that
worktree's own checkout already has it. `.crap-gated` and `.mutation-gated` are separate from each other on
purpose: the CRAP ledger can always be made green by writing tests, but some
codebases carry mutants no test can ever kill (a string-heavy module where the
mutator only flips the case
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
frontend can gate the Go and exempt `web/**`. The same patterns also stop all
three gates, coverage, dead code and mutation, from measuring Go, PHP or Python
under an exempted path, not only from refusing another language there. Files that are not program source — docs,
config, SQL, shell — never trigger it.

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
workflows/deliver-pipeline.js    the nine-phase orchestration
agents/planner.md                plan-only subagent, has no Edit or Write tool
skills/crap-controlled-changes/  the gates, their language modules, and their docs
hooks/                           seven policy gates, with a manifest per host
```

### The phases

1. **Worktree** — canonical branch and worktree off a freshly pulled base, then one ticket fetch shared by every later phase.
2. **Triage** — one cheap agent checks the ticket's premise, sizes the job, and judges how hard it is to get right. A disproved premise halts. Work under ten lines skips straight to Implement. The difficulty judgement sets the reasoning effort every later phase runs at, so an easy change does not get paid for like a hard one.
3. **Plan** — a planner with no write tools produces a plan, acceptance criteria and risk areas.
4. **Implement** — TDD via the skill, committing through `crap-commit.sh`, which runs both commit-time gates and refuses while either is red. Alongside it, every line under the target repo's own `## Checks` heading (in `AGENTS.md` or `CLAUDE.md`) is executed before this phase and again after every step that commits: it must list only read-only, deterministic checks, since it runs repeatedly against the same tree.
5. **Draft PR** — pushes the branch and opens a draft, so the work is visible and any later halt has somewhere durable to be reported.
6. **Review** — adversarial reviewers on distinct lenses, chosen by diff size. A finding only holds the run if its category is one of a closed blocking set (wrong result, crash, gate bypass, unmet criterion) and it carries a reproducer that actually fails; everything else reaches the PR as a non-blocking note. Re-runs on commits any later phase adds, and from that point on a finding also has to fall inside what the new commits actually changed.
7. **Fix** — confirmed findings only, bounded rounds. A finding counts as fixed when its own reproducer exits 0 against the new commits, never by a model's judgement of the diff.
8. **Mutation** — kill every survivor with a test. Its own commits get reviewed too.
9. **PR** — fills in the PR against the repo's template and marks the draft ready, only once every gate is green.

### The hooks

Four apply only to repos you opted in:

- `crap-commit-gate.py` — refuses raw `git commit`, names `crap-commit.sh` instead. It does not guess which repo a command targets; it resolves `git -C` and `cd` chains and refuses decidably.
- `mutation-pr-gate.py` — verifies the mutation ledger before `gh pr create`, a `git merge` onto a base branch, or a `git push` at one.
- `contributing-gate.py` — refuses the first edit until the repo's `CONTRIBUTING.md` has actually been Read this session. A repo shipping no guide is never gated.
- `comment-policy-gate.py` — flags a newly added comment that matches a rule in the repo's own `.comment-gated` (one regex per line, blank and `#` lines ignored; a rule that itself must start with a literal `#`, such as `#\d+`, needs `\#\d+` instead, or the line reads as a marker comment and is dropped). The plugin ships no default rule, so an absent, empty, or comment-only marker flags nothing. Comment detection is prefix-based per file extension, not a parser: it never sees a block comment or a trailing (same-line) comment, and does not report a line number. It also flags a string literal, heredoc, or docstring line whose first non-space character happens to be the comment prefix, since it cannot tell that apart from a real comment: not a blind spot, the opposite of one.

Three apply everywhere, because each fires only on its own evidence:

- `base-branch-commit-gate.py` — refuses a commit on `main`/`master`/etc. Exempts a repo with no remote, since that work cannot reach anyone yet.
- `gate-pipe-gate.py` — refuses piping a gate anywhere. `$?` after a pipeline is the *last* command's status, so `mutation-check.sh | tail` reports tail's exit 0 however the gate ended, turning a red gate into a reported pass.
- `generated-file-gate.py` — refuses hand-editing a file whose own header says `@generated` or `DO NOT EDIT`. The marker is the file's consent, so this needs no repo opt-in.

The same seven run on Claude Code and on Copilot. Each host gets its own manifest
(`hooks/hooks.json`, `hooks/copilot-hooks.json`) over one set of scripts, because the
hosts disagree about how a hook is invoked and how it reports a refusal. Copilot
additionally carries a `PostToolUse` hook on `Read`, which is how `contributing-gate.py`
learns the guide was read on a host with no session transcript to inspect. Details in
[docs/architecture.md](docs/architecture.md).

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
bash scripts/run-go-tests.sh            # the skill's Go-toolchain suites; needs a Go toolchain, python3, and an ssh signing key
bash scripts/run-php-python-tests.sh    # the skill's PHP/uv suites; needs a live PHP ^8.3 + infection + phpunit, and uv
bash scripts/check-no-private-refs.sh   # no machine- or org-specific references
bash scripts/check-version-bump.sh      # gated directories moved version in the same range
```

`run-go-tests.sh` and `run-php-python-tests.sh` run complementary halves of every
suite in `skills/crap-controlled-changes/test/`, split by the one list in
`scripts/lib/skill-suites.sh`. Running a single suite, how that selection works,
fixture handling and the toolchain each CI job provides are in
[docs/testing.md](docs/testing.md). How the gates, hooks and workflow fit
together is in [docs/architecture.md](docs/architecture.md).

### Versioning

`claude plugin update` serves a marketplace plugin by the `version` string in
`.claude-plugin/plugin.json`, from a cache keyed on that string, not by commit.
A change under `workflows/`, `hooks/`, `skills/`, `agents/`, `commands/` or to
`.claude-plugin/plugin.json` itself that lands without moving `version` is
invisible to every existing install until someone bumps it later
(`.claude-plugin/marketplace.json` is the marketplace index, not part of what
an install fetches, so it is not gated). `check-version-bump.sh`
diffs HEAD against `origin/main` (a local `main` branch if there is no
origin) and fails if any gated path changed without `version` rising above
the one on that base, so the bump has to travel in the same PR as the change
it covers, in either commit order. Versions are ordered as dotted integers,
which puts `0.10.0` above `0.9.0` where a string compare would not; a version
that cannot be read that way is a setup error, not a pass. Requiring the
version to rise, rather than only to differ, is what stops a bump from
reusing a string some install has already cached, and it settles that without
the check having to decide which versions `main` ever really served. A push
straight to `main` compares main against itself and is a no-op: the check
gates PRs, not a bypass of the PR process.

`workflows/deliver-pipeline.js` carries its own name and version as literals, since
it cannot read the manifest at runtime; how that reports a version mismatch during
a run is in [docs/architecture.md](docs/architecture.md#pipeline-version-transparency).

`check-no-private-refs.sh` looks for classes of leak (absolute home paths,
personal config paths, stray tracker keys) rather than a list of specific names,
since a committed list would publish exactly what it exists to exclude. Point
`TOUCHSTONE_PRIVATE_TERMS` at a local file of extra patterns for anything that
should not be written down in the repo.

## What a run costs

Touchstone is not cheap, and you should know that before you point it at a ticket
rather than after.

One measured run (ticket 7, a routine CI-configuration change) took **44 minutes
across 17 agents** and moved **33M tokens**: 198k of output against 31.2M of cache
reads and 1.9M of cache writes. Output is 0.6% of the tokens and roughly 15% of the
cost. The rest is each agent re-sending its own growing conversation on every turn,
which is why the handoff between phases is nearly free and the phases themselves are
not.

A heavier ticket costs more, and not linearly. The expensive axis is fix rounds: that
run needed one, while earlier runs on code tickets needed three and came to 252k and
291k of output over 57 and 75 minutes.

Triage scales reasoning effort to the difficulty it judges, which bounds the output
share. It does not bound the context re-reads, which are the larger half.

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
