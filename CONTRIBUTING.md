# Contributing

Thanks for looking. This guide is for humans and for coding agents alike; where
the two differ, it says so.

## Before you write anything

**Open an issue first.** This project is ticket-driven: every branch name carries
its ticket (`feat/gh-216-retry-path`), and the delivery pipeline refuses to run
without one. An issue also gives a change somewhere to be argued with before it
costs anyone time.

The bug and feature forms under [`.github/ISSUE_TEMPLATE/`](.github/ISSUE_TEMPLATE)
ask for the three things that make a ticket actionable: the evidence, the
expected outcome, and how anyone can tell it is done. A ticket missing its
expected outcome gets one inferred, and an inferred outcome is how half a ticket
ships.

## Getting set up

Prerequisites are listed under **Requirements** in the [README](README.md). The
short version: `gh` authenticated, `python3`, and **bash 4.0 or newer**, which
macOS does not ship as `/bin/bash`. Language toolchains are only needed for the
gates you actually exercise.

## Proposing a change

**Outside collaborators:** fork, branch, and open a pull request against `main`.

**If you have push access:** branch directly in this repository. Do not commit to
`main`; a hook refuses it, and CI's version check is written around comparing a
branch to `main`.

Name the branch `<type>/<marker>-<slug>`, where `<type>` is one of `feat`, `fix`,
`chore`, `refactor`, `docs`, `test`, `perf`, `build` or `ci`, and `<marker>` is
`gh-<issue>` or `jira-<KEY>`. The marker is the only record of which ticket the
work came from, so an invented one is not recoverable later.

You can also hand the whole thing to the pipeline with
`/touchstone:deliver --ticket <ref>`, which cuts the branch, implements under
TDD, reviews, runs the gates and opens the PR. See
[`commands/deliver.md`](commands/deliver.md).

## Writing the code

- [`AGENTS.md`](AGENTS.md) is the entry point: the commands, and the rules that
  are easy to break by habit. `CLAUDE.md` symlinks to it.
- [`docs/architecture.md`](docs/architecture.md) explains how the gates, hooks
  and workflow fit together. Read it before changing any of the three.
- [`docs/testing.md`](docs/testing.md) covers running the suites, including a
  single one.

Two conventions worth stating outright, because both are easy to get wrong:

**Comments carry the WHY, at unusual density.** Most comments here record a
specific failure that already happened. Read one before changing the line it sits
on, and do not add comments that restate what the code plainly does.

**python3 does the real work; bash orchestrates.** Prefer extending a `lib/*.py`
parser over growing a shell script.

## Tests

Every suite is a bash script that exits 0 green. There is no framework to
configure. The runners are listed in [`docs/testing.md`](docs/testing.md); run
the ones your change touches before opening the PR, and CI will run all of them.

New behaviour needs a test. The gates measure whether your tests would actually
fail if the code were wrong, so a test that only executes a line will not satisfy
them.

## Committing

**Commit through `crap-commit.sh`, not `git commit`.** This repository gates
itself: `.crap-gated` and `.mutation-gated` are both committed, so a hook refuses
the raw form. The wrapper runs the dead-code and CRAP gates first and refuses
while either is red.

Signing follows whatever your own git configuration resolves; this project does
not decide it for you. The one refusal is an `*_sk` hardware-token key, which an
unattended run would hang on rather than fail.

**Bump `version` in `.claude-plugin/plugin.json`** in the same pull request as any
change under `workflows/`, `hooks/`, `skills/`, `agents/` or `commands/`.
`claude plugin update` keys its cache on that string, so an unbumped change is
invisible to every existing install. CI fails the PR if you forget.

## Opening the pull request

Push, then open the PR against `main`. The mutation gate intercepts a non-draft
`gh pr create` and `gh pr ready`, verifying the ledger first, so open a draft
while work is in flight and mark it ready once the gates are green.

Say what the change does and why it matters. Keep local machinery out of the
description: a reviewer cannot act on it, and naming a check this repository does
not run is simply wrong.

## What a reviewer will look for

- The change does what its ticket said, and nothing else. Adjacent work belongs
  in its own ticket.
- Tests that would fail if the code were wrong, not tests that merely run it.
- A green CI, including the gates. Exit 2 and exit 4 are setup failures and
  could-not-measure, not passes.
- No new comment that a better name would have removed.

If a gate refuses and you believe the code is right, say so in the PR and stop.
That is a decision for the maintainer, not a file to edit around.

## A note for agents

Two habits, both of which have already caused real damage here.

**Do branch work in a `git worktree`, never by checking out a branch in the main
checkout.** Sessions share this clone and `HEAD` is global to it, so a second
session cutting a branch switches `HEAD` out from under the first, and untracked
files from one session sit where the other's `git add -A` will sweep them up.

```bash
git worktree add .claude/worktrees/<marker>-<slug> -b <type>/<marker>-<slug> origin/main
```

**Use `git -C <path>`, never `cd <path> &&`.** The shell's working directory
persists between commands, so one `cd` silently moves every command after it. Non-git
commands take an absolute path instead, either as the script path or as the argument
they already expect (`crap-commit.sh <worktree-path> -m "..."`).

Remove the worktree and delete the branch once its pull request merges.
