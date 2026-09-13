# Contributing

## Work in a worktree, never in this checkout

Do all branch work in a `git worktree`, not by checking out a branch here.
Every session that opens this repo shares this one clone, and `HEAD` is global
to it: a second session cutting its own branch switches `HEAD` away from
whatever the first session was mid-way through, and untracked files from one
session's work sit in the tree where the other session's `git add -A` can
sweep them into the wrong commit. A worktree gives each branch its own
directory and its own `HEAD`, so two sessions never contend for either.

```bash
git fetch origin
git worktree add <repo-root>/.claude/worktrees/<ticket-marker>-<slug> -b <branch> origin/main
```

Run every command, git included, with `-C <worktree-path>`. Never `cd` into
the worktree, not even for a single command: the shell's working directory
persists between commands in an agent session, so one `cd` moves every command
after it, including the ones that record where the work happened.

## Ticket-driven delivery

`/touchstone:deliver --ticket <ref>` runs the full pipeline: worktree, triage,
plan, TDD implementation, gates, review, mutation, PR. See
[commands/deliver.md](commands/deliver.md) for its flags and behaviour. Hand
work follows the same worktree rule above; it just skips the rest of the
pipeline's automation.

## Gates, signing, and pushing

This repo gates itself: `.crap-gated` and `.mutation-gated` are both
committed, so `crap-commit.sh` and the mutation ledger enforce on every commit
and PR here, not only in repos this plugin is installed into. Commit through
`crap-commit.sh` rather than a raw `git commit`; a hook refuses the raw form.

Commits are signed by whatever `git config` resolves for this clone unless you
set `CRAP_SIGNING_KEY` to a key file, which `crap-commit.sh` uses instead and
turns signing on even if `commit.gpgsign` is off. The one thing refused, with
or without that variable, is signing with an `*_sk` hardware-token key, since
an unattended run would hang waiting for the token rather than fail; set
`CRAP_SIGNING_KEY` to a non-hardware key to get past that.

Push and open the PR the normal way. The mutation gate intercepts a non-draft
`gh pr create`, a `gh pr ready`, a merge onto a base branch, and a push at one,
running `mutation-check.sh --verify` first and blocking while the ledger is
unverified. `gh pr create --draft` is exempt, so open a draft PR and mark it
ready only once the ledger is verified.

Bump `version` in `.claude-plugin/plugin.json` in the same PR as any change
under `workflows/`, `hooks/`, `skills/`, `agents/`, `commands/` or
`.claude-plugin/plugin.json` itself. `claude plugin update` keys its cache on
that string, so an unbumped change is invisible to every existing install.
Nothing at commit time catches a missed bump; `scripts/check-version-bump.sh`
runs in CI and fails the PR.
