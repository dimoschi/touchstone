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
git worktree add ../touchstone-<branch-slug> -b <branch> origin/main
```

Run every command, git included, with `-C <worktree-path>` or from inside that
directory, and never `cd` back into the main checkout mid-session.

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

Commits are signed by whatever `git config` resolves for this clone; nothing
here overrides `commit.gpgsign` or the signing key. The one thing refused is
signing with an `*_sk` hardware-token key, since an unattended run would hang
waiting for the token rather than fail.

Push and open the PR the normal way; nothing here intercepts either except the
mutation gate, which blocks a `gh pr create`, a merge onto a base branch, or a
push at one while the mutation ledger is unverified.
