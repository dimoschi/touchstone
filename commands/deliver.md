---
description: Run the touchstone delivery pipeline (triage, worktree, plan, TDD, gates, review, mutation, PR)
argument-hint: --ticket <PROJ-4821|216> [--type feat|fix|...] [--existing] [optional narrowing]
---

Invoke the `deliver-pipeline` workflow via the **Workflow** tool. Do not use the Skill
tool, and do not read the workflow script and run its phases by hand: hand-running
skips the token ceilings, the halt latches, and the gates, which are the reason the
workflow exists.

```
Workflow({ name: 'touchstone:deliver-pipeline', args: { task: "...", ticket: "...", branchType: "..." } })
```

## Arguments

Parse `$ARGUMENTS` by **explicit flags only**. Never infer which token is a ticket:
a wrong guess is baked into the branch name, and every downstream metric inherits
the fabricated link.

- `--ticket <ref>` — **required**. A Jira key (`PROJ-4821`, `ABC-127`) or a GitHub
  issue number (`216`, `#216`). Pass it through verbatim as `ticket`.
- `--type <word>` — optional. `feat`, `fix`, `chore`, `refactor`, `docs`, `test`,
  `perf`, `build`, or `ci`. Pass as `branchType`. Defaults to `feat`.
- `--existing` — optional. Pass `existingBranch: true`. Use it when the work
  continues a branch this ticket already has: review feedback, or scope added
  to a ticket whose PR is already open. The workflow looks up that branch by
  ticket marker, whatever the invoking checkout happens to be on and skipping
  fetch and pull entirely: first among every worktree
  (`git worktree list --porcelain`), then, only if none matches, a branch with
  no worktree of its own (its directory was removed by hand -- sometimes
  because its PR merged and the tree was cleaned up, sometimes because it was
  cut loose mid-flight). Either match is checked for a merged PR before it is
  touched: a merged one halts instead of being reused, since that work is
  done, not a tree to keep implementing into; otherwise the workflow
  re-attaches a worktree to it rather than cutting a new branch.
  **`--ticket` is still required.** Without this flag the workflow cuts a
  fresh branch and worktree off the base, which would strand follow-up work
  away from the PR it belongs to.
- Everything remaining, with the flags removed, is `task`. **Optional.** The
  workflow fetches the ticket's title, description and comments and gives them to
  every phase, so the ticket is the specification. Pass task text only to *narrow*
  or *reframe* it -- "only the retry path", "just the migration, not the backfill"
  -- and pass nothing when the whole ticket is the job. Do not restate the ticket:
  a second, staler copy of it is what triage and the devil's advocate then argue
  with.

**If `--ticket` is absent, stop and tell the user. Do not invoke the workflow.**

## Re-running with a plan you already have

When a previous run produced a plan and stopped before implementing it, pass that
plan as `plan`, not as `task`:

```
Workflow({ name: 'touchstone:deliver-pipeline', args: { ticket: "...", plan: "<the plan text>" } })
```

The run then skips Plan and Challenge and starts at Implement. Optionally pass
`acceptanceCriteria` and `riskyAreas` as arrays if the earlier run produced them.

Never put a plan in `task` with an instruction to carry it out. `task` is handed to
the planner, whose one rule is that it must not implement, so a task saying "the
plan is written, now implement it" asks that phase to break its own contract. One
run did exactly that: the plan agent made 51 edits and 6 commits, blew the Plan
ceiling, and the review, mutation and PR phases that would have checked the code
never ran. The planner now refuses such a task and halts, pointing here.

Say that `/touchstone:deliver` requires a ticket, and show the correct form. Do not scan the
task text for something ticket-shaped, do not offer to proceed without one, and do
not invent one. If the user genuinely wants agent work with no ticket, they can
invoke the workflow directly; refusing here is the point, so do not route around it.

Examples:

```
/touchstone:deliver --ticket PROJ-4821
/touchstone:deliver --ticket PROJ-4821 only the retry path, leave the session store alone
/touchstone:deliver --ticket 216 --type fix
/touchstone:deliver --ticket PROJ-119 --existing address the review comments on PR 58
```

These are refused:

```
/touchstone:deliver refactor the retry decision ordering    -> no --ticket, refuse
/touchstone:deliver 2 factor auth for the admin panel       -> "2" is task text, not a ticket
```

The second is why the flag is required rather than positional: inferring `2` as issue
number 2 would bake a fabricated ticket link into the branch name, and every
downstream metric would inherit it.

## If the workflow refuses

It halts on purpose: a detached HEAD, a base ref that will not resolve, a dirty
checkout in the worktree `--existing` resolves to, `--existing` finding no
worktree or branch for the ticket and the current checkout not on a feature
branch either, `--existing` matching more than one worktree or branch for the
ticket, `--existing` matching a worktree or a branch whose pull request
already merged, `--existing` matching only a branch whose canonical worktree
directory is already occupied by something else, `--existing` falling back
to a checkout that carries a different ticket's marker, a missing ticket.
**Report the halt and stop.** Do not copy
`deliver-pipeline.js` elsewhere and edit out the phase that blocked you, and do not
edit the original. A gate that gets neutered whenever it is inconvenient is not a
gate.

If the workflow genuinely cannot express the job, say exactly what it cannot express
and let the user decide. That is a gap worth fixing in the script, not routing
around once.

## Before invoking

Nothing to confirm. Invoke the workflow.

**A missing marker is not a reason to stop.** The markers control enforcement, not
measurement, so the run is worth making either way:

- `crap-check.sh` and `crap-commit.sh` never read a marker. They run on every
  invocation and score any staged Go, PHP or Python. Those numbers carry full
  weight in an unmarked repo.
- `.crap-gated` arms `crap-commit-gate.py` (intercepts a raw `git commit`),
  `contributing-gate.py`, and the unsupported-language refusal.
- `.mutation-gated` arms `mutation-pr-gate.py` (intercepts `gh pr ready`) and is
  what makes the mutation phase run at all; unmarked, that phase skips itself.

So report which gates were inert when the run returns, and never stop to ask for a
marker first: stopping delivers nothing, which is worse than delivering a change
whose mutation gate did not run.

**Never create a marker.** That is the repo owner's decision and it is repo-wide and
permanent. It can also break the repo it is added to: a language in
`lib/unsupported-sources.sh`'s list refuses every commit touching it once
`.crap-gated` exists, and a language whose tests the gate cannot measure refuses too.

## After it returns

Report the branch it cut, the base it came from, the gate results, and the PR URL if
one was opened. If it halted, report the phase and the halt note verbatim: the halts
are diagnostic, and paraphrasing them loses the reason.

Report `pipeline_version.executed`, the version of `deliver-pipeline.js` this run
actually ran. If `pipeline_version.mismatch` is `true`, say so and name both
`pipeline_version.executed` and `pipeline_version.base_branch`: the latter came from
the repository's base branch, not from the caller's own checkout, so word it that way
rather than implying it was read from anything the caller has locally. `mismatch`
only means the two differ, never which one is ahead. Compare the two version strings
yourself before describing a direction; do not assume the executed snapshot is
the older one. A `mismatch` of `false` or `null` needs no mention.

### Add the run id to the run record

The workflow writes its own record to `.claude/touchstone-runs/<ticket>.json` in the
main checkout, and returns the path as `record_path`. It cannot include the run id:
the id reaches you only after the run has started, so nothing inside can be told it.

Add it yourself, along with the date, by editing that file's JSON:

```
{ "run_id": "<the wf_ id the Workflow tool returned>", "recorded_on": "<today>" }
```

Without the id the record cannot be resumed from, which is most of its value: resume
needs `resumeFromRunId` and the `scriptPath`, and both live under the launching
session's own directory, invisible to any later session and to a second
`CLAUDE_CONFIG_DIR`. The record is the only copy that stays with the repo.

Do not commit it. `.claude/` is ignored, and the record is local state, not
something the repo's team asked for.

### Record what happened, before you report it

**Only if [agent-eval](https://github.com/dimoschi/agent-eval) is installed.** It is
an optional companion that stores session outcomes so quality metrics have ground
truth. If `agent-eval` is not on PATH, skip this whole section: report the run and
stop. Nothing here affects the work, and the workflow does not depend on it.

If the run returned a `halted_at`, record the halt:

```
agent-eval record-phase --session "$CLAUDE_CODE_SESSION_ID" --phase '<halted_at>' \
  --status halted --reason '<the halt note, verbatim>' \
  --workflow-run <the wf_ id the Workflow tool returned> --branch '<branch>'
```

If it errored, was killed, or returned nothing usable, record that instead with
`--status failed` and whatever phase it reached. Then, whenever the outcome is known:

```
agent-eval record --session "$CLAUDE_CODE_SESSION_ID" --outcome merged --pr <n> \
  --workflow-run <the wf_ id>
```

Only you can do either. The run id reaches you after the run has started, so no agent
inside the workflow can be told it, and a session that ran /touchstone:deliver twice otherwise
records two outcomes for two PRs with nothing saying which run produced which.

The halt record matters more than the outcome one. Each phase reports on itself, and a
phase that raises a fundamental objection has completed its own job perfectly well, so
it records `completed` and is right to. Whether the *run* stops is your decision to
report, not the phase's: without this, two runs that halted and produced no code showed
four phases, all `completed`, and querying for halted runs returned nothing.
