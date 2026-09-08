export const meta = {
  name: 'deliver-pipeline',
  description: 'Triage -> plan -> implement (TDD) -> gates -> adversarial review -> mutation -> PR, bounded',
  whenToUse: 'Ticket-driven delivery in a repo that has opted into gating. Prefer the /deliver command, which parses flags and refuses without a ticket. Pass args: {ticket: "..."}; task is optional and narrows the ticket. Pass {plan: "..."} to reuse a plan an earlier run produced, which skips the Plan phase and starts at Implement.',
  phases: [
    { title: 'Worktree', detail: 'canonically named branch and worktree from a freshly pulled base, then fetch the ticket once for every later phase' },
    { title: 'Triage', detail: 'one cheap agent checks the premise, sizes the job and judges its difficulty; a disproved premise halts, small work skips Plan, and the difficulty sets every later phase\'s reasoning effort' },
    { title: 'Plan', detail: 'planner produces plan + acceptance criteria + risk areas' },
    { title: 'Implement', detail: 'one implementer, TDD via crap-controlled-changes, many small signed commits' },
    { title: 'Draft PR', detail: 'push the branch and open a draft PR, so the work is visible and any later halt has somewhere durable to be reported' },
    { title: 'Review', detail: 'adversarial reviewers on distinct lenses, chosen by diff size: correctness and devil\'s advocate normally, plus requirements coverage on a big diff, none on a one-liner. Runs again on any commits a later phase adds' },
    { title: 'Fix', detail: 'fix confirmed findings, then a verifier and an adversary read the result in parallel; bounded rounds' },
    { title: 'Mutation', detail: 'pre-PR mutation gate; kill survivors with tests, never weaken code. Its own commits are reviewed before the PR' },
    { title: 'PR', detail: 'push, fill in the PR against the repo template, and mark the draft ready for review, only when every gate is green' },
  ],
}

// Boundaries. Wall-clock deadlines are not expressible here (no Date.now, by
// design); the bounds are rounds, counts, and token budget instead.
// The ticket is the specification: its description and comments are fetched
// below and given to Triage, which checks its claims, and to Plan, which works
// from it. No other phase sees the text. A task string is therefore optional,
// and when given it narrows or reframes rather than restates -- "just the retry
// path of this ticket".
let task = typeof args === 'string' ? args : args?.task

// Every task traces to a ticket, by rule. Failing here rather than cutting an
// unmarked branch keeps the link unfabricated: a branch with no jira-/gh- marker
// is reported untracked forever, and nothing downstream can recover the ticket.
const ticket = args?.ticket
if (!ticket) {
  throw new Error(
    'deliver-pipeline: pass args {ticket: "PROJ-4821"} or {ticket: "216"}. ' +
    'Every task must trace to a Jira ticket or GH issue. Do not infer one from ' +
    'the task text; supply it explicitly or do the work outside this workflow.')
}
// Phase recording goes to agent-eval, a separate optional tool. Default on so a
// machine that has it keeps its ground truth without opting in every run; the
// prompt tells each phase to skip a missing command rather than halt, so this
// flag exists to silence the instruction entirely, not to make it safe.
const recordPhases = args?.record !== false

// Stacking on a PR still in flight. The review range is the merge base with the
// base and the PR opens against it, so defaulting here puts the parent's commits
// in this PR's diff.
const baseOverride = typeof args?.base === 'string' && args.base.trim()
  ? args.base.trim() : null

const MAX_GATE_ATTEMPTS = args?.maxGateAttempts ?? 3
// Three, not two: a fix round that introduces a new finding now spends a round
// discovering that, so two left no round to actually resolve it.
const MAX_REVIEW_ROUNDS = args?.maxReviewRounds ?? 3
const BUDGET_FLOOR = 30_000
const outOfBudget = () => budget.total && budget.remaining() < BUDGET_FLOOR

// A change this small is cheaper to plan than to orchestrate around: Triage
// sends it straight to Implement, and Review skips its lenses for a diff under
// the same bar.
const INLINE_LOC = args?.inlineLoc ?? 10

// Long briefs make agents thorough about the wrong things, and the task text is
// re-sent to every agent in the pipeline. Clamp what gets forwarded.
const BRIEF_CHARS = args?.briefChars ?? 4000
const brief = (s) => {
  const t = String(s ?? '')
  return t.length <= BRIEF_CHARS ? t : `${t.slice(0, BRIEF_CHARS)}\n[brief truncated]`
}

// Per-stage token ceilings (output tokens). Tripwires, not aborts: a running
// agent can't be stopped from here, so over() is read only after the agent has
// returned. On a single-shot stage that makes the ceiling retrospective -- it
// cannot prevent the spend, it can only discard the finished work, which is why
// plan and implement carry none. A ceiling is a real bound only where over()
// gates a further iteration (the fix rounds, the mutation attempts, the
// re-review latches), and those keep theirs. triage and branch keep theirs too:
// both halt before any code exists, so tripping them forfeits nothing.
// null means uncapped; args.stageBudgets can set a number to opt one back in.
const CEILINGS = {
  triage: 15_000,
  branch: 10_000,
  plan: null,
  implement: null,
  gate: 120_000,
  review: 80_000,
  // Carries the tail review of each fix round as well as the fixing itself.
  fix: 170_000,
  mutation: 150_000,
  pr: 30_000,
  ...(args?.stageBudgets ?? {}),
}
const stageSpend = {}
const stage = (name) => {
  const start = budget.spent()
  const cap = CEILINGS[name]
  return {
    over: () => cap != null && budget.spent() - start > cap,
    close: () => {
      stageSpend[name] = budget.spent() - start
      log(`${name}: ${Math.round(stageSpend[name] / 1000)}k output tokens ` +
          (cap == null ? '(no ceiling)' : `(ceiling ${Math.round(cap / 1000)}k)`))
    },
  }
}
// Set once the draft PR exists; read by halted() so a stop has somewhere
// durable to be reported. Declared here because halted() is defined before the
// phase that opens it.
let draftPr = null

// Keyed by ticket, not run id: a script is never told its own run id, and the
// ticket is what a human looks the run up by.
const recordRun = async (record) => {
  const key = String(ticket).replace(/[^A-Za-z0-9_-]/g, '-')
  const written = await agent(
    `Write one file, then STOP. Do not stage it, commit it or push, and do ` +
    `not touch anything else.\n` +
    `1. Resolve the main checkout: git rev-parse --path-format=absolute ` +
    `--git-common-dir, then take that directory's parent. Write there, not in ` +
    `this worktree, which is removed once the work lands.\n` +
    `2. mkdir -p <main>/.claude/touchstone-runs\n` +
    `3. Write the JSON below to <main>/.claude/touchstone-runs/${key}.json ` +
    `byte for byte, with a quoted heredoc (cat > path <<'TOUCHSTONE_EOF'). Do ` +
    `not reformat it, re-indent it, summarise it or add fields. It is a record, ` +
    `not a draft.\n` +
    `Return the absolute path you wrote.\n\n` +
    JSON.stringify(record, null, 2),
    { label: 'run-record', model: 'haiku', effort: 'low' })
  log(written
    ? `run record written to .claude/touchstone-runs/${key}.json`
    : `run record could not be written; this run survives only in the transcript`)
  return typeof written === 'string' ? written : null
}

const renderSuspects = (suspects) => suspects
  .map((s, i) => `${i + 1}. ${s.title} (${s.file}): ${s.claim}. Evidence: ` +
    `${s.evidence}. Reported again in fix round ${s.round}, after an earlier ` +
    `finding of the same issue had been fixed and verified.`)
  .join('\n')

// A halt is a result, not an absence of one. When a draft PR is open it gets
// the halt note as a comment, so the run's ending survives the session that
// produced it. Async for that reason alone -- every call site is `return await`.
const halted = async (at, extra) => {
  const payload = {
    task, halted_at: at, stage_spend: stageSpend, needs_user: true, ...extra,
  }
  if (draftPr?.number) {
    const posted = await agent(
      `Post a comment on PR #${draftPr.number} in the current repo, then STOP.\n` +
      `Use: gh pr comment ${draftPr.number} --body-file - with the body on stdin, ` +
      `or --body. Do not edit the PR title or body, do not mark it ready, do ` +
      `not close it, and do not push anything.\n` +
      `The comment reports that an automated run stopped at the ${at} phase ` +
      `and what a human has to decide. Write it for whoever opens this PR next ` +
      `week with no memory of the run. Lead with the decision they owe, then ` +
      `the reason. Keep it short.\n` +
      `Do not name this workflow, its phases, its gates, or the fact that an ` +
      `agent produced the change: none of that is actionable to a reviewer. ` +
      `Say what is unfinished and what has to be judged.\n` +
      `Stopped at: ${at}\n` +
      `Reason: ${extra?.note ?? 'no note given'}\n` +
      (extra?.unresolved_findings?.length
        ? `Open findings a human must judge, fix or reject:\n` +
          extra.unresolved_findings
            .map((f, i) => `${i + 1}. ${f.title} (${f.file}): ${f.claim}` +
              (f.code_changed_since_recorded
                ? ` [code changed since recorded; re-check against HEAD]`
                : ''))
            .join('\n')
        : '') +
      (extra?.regression_suspects?.length
        ? `\nAlso report these, as a separate list headed so a reader sees they ` +
          `are a different kind of item from the open findings above: a fix ` +
          `landed for each and was verified, then a later review reported the ` +
          `same issue again. They were deliberately not reopened, so nobody has ` +
          `judged whether the fix held. Say that plainly and say it needs ` +
          `checking:\n` +
          renderSuspects(extra.regression_suspects)
        : ''),
      { label: `halt-notice:${at}`, model: 'haiku', effort: 'low' })
    payload.halt_reported_to = posted ? draftPr.url : null
    log(posted
      ? `halt at ${at} reported on ${draftPr.url}`
      : `halt at ${at}: could not comment on the draft PR; it is in this session only`)
  }
  payload.record_path = await recordRun(payload)
  return payload
}

// task_demands_implementation is asked of the planner rather than pattern-matched
// here because the contradiction arrives as prose. A real run was handed a task
// reading "the plan below is already written... then implement", obeyed the task
// over the phase rule, and committed 51 edits from the Plan stage; the review that
// would have compared its reasoning to its code never ran.
const PLAN = {
  type: 'object', additionalProperties: false,
  required: ['plan', 'acceptance_criteria', 'risky_areas',
             'task_demands_implementation'],
  properties: {
    plan: { type: 'string' },
    acceptance_criteria: { type: 'array', items: { type: 'string' } },
    risky_areas: { type: 'array', items: { type: 'string' } },
    task_demands_implementation: { type: 'boolean' },
    conflict_note: { type: 'string' },
  },
}
// Scalars first, prose last. A required integer serialized after a long
// free-text field is where the value drifts into the prose and validation
// fails; premise_note is explicitly asked to be discursive. estimated_loc is
// optional because the branch that needs it least is the one that fires most:
// when premise_ok is false the latch trips regardless, and demanding a line
// count for a change nobody has scoped yet forces a number out of thin air.
const BRANCH = {
  type: 'object', additionalProperties: false,
  required: ['created', 'branch', 'base', 'path', 'detail'],
  properties: {
    created: { type: 'boolean' },
    branch: { type: 'string' },
    base: { type: 'string' },
    path: { type: 'string' },
    ticket: { type: 'string' },
    detail: { type: 'string' },
  },
}

const GATED = {
  type: 'object', additionalProperties: false,
  required: ['gated', 'detail'],
  properties: {
    gated: { type: 'boolean' },
    detail: { type: 'string' },
  },
}

const TRIAGE = {
  type: 'object', additionalProperties: false,
  required: ['scope', 'complexity', 'complexity_note', 'premise_ok', 'evidence',
             'premise_note'],
  properties: {
    scope: { type: 'string', enum: ['inline', 'team'] },
    // Judgement, not arithmetic. A line count is a proxy for risk and a poor
    // one: five lines in a signing path are harder than two hundred in a test
    // file. Triage has already read the ticket and the code by the time it
    // answers, so it is the right place to say how hard this is, and the only
    // place that knows before anything expensive runs.
    complexity: { type: 'string', enum: ['trivial', 'routine', 'involved'] },
    complexity_note: { type: 'string' },
    premise_ok: { type: 'boolean' },
    estimated_loc: { type: 'integer' },
    evidence: { type: 'array', items: { type: 'string' } },
    premise_note: { type: 'string' },
  },
}
// commit_range is what downstream phases are handed. summary exists for the
// halt returns a human reads, and is deliberately NOT forwarded to the
// reviewer: an adversarial reviewer told what the implementer believes it did
// is anchored before it opens a file. files_changed is forwarded, because scope
// is a fact rather than the implementer's account of itself.
const IMPL = {
  type: 'object', additionalProperties: false,
  required: ['summary', 'files_changed', 'commit_range', 'insertions'],
  properties: {
    summary: { type: 'string' },
    files_changed: { type: 'array', items: { type: 'string' } },
    commit_range: { type: 'string' },
    insertions: { type: 'integer' },
  },
}
// head_sha is required, not optional: it is how the script learns what this
// phase committed, and an absent one is indistinguishable from "committed
// nothing" -- which is exactly the case that must not silently skip review.
const GATE = {
  type: 'object', additionalProperties: false,
  required: ['green', 'head_sha', 'detail'],
  properties: {
    green: { type: 'boolean' }, head_sha: { type: 'string' },
    detail: { type: 'string' },
    needs_user_run: { type: 'boolean' },
  },
}
const FINDINGS = {
  type: 'object', additionalProperties: false, required: ['findings'],
  properties: {
    findings: {
      type: 'array',
      items: {
        type: 'object', additionalProperties: false,
        required: ['title', 'file', 'claim', 'evidence'],
        properties: {
          title: { type: 'string' }, file: { type: 'string' },
          claim: { type: 'string' }, evidence: { type: 'string' },
          // An id copied from reviewOf's `known` list, never invented. Each
          // call site states what a reference there means.
          duplicate_of: { type: 'string' },
        },
      },
    },
  },
}
const VERDICTS = {
  type: 'object', additionalProperties: false, required: ['verdicts'],
  properties: {
    verdicts: {
      type: 'array',
      items: {
        type: 'object', additionalProperties: false,
        required: ['id', 'fixed', 'note'],
        properties: {
          id: { type: 'string' },
          // Ignored for matching. Present only so a verifier that still echoes
          // a finding's title cannot fail schema validation over it.
          title: { type: 'string' },
          fixed: { type: 'boolean' },
          note: { type: 'string' },
        },
      },
    },
  },
}
// A fix round is a code change like any other, so the script has to know where
// it landed to hand the next reviewer a range.
const FIXED = {
  type: 'object', additionalProperties: false, required: ['head_sha', 'note'],
  properties: { head_sha: { type: 'string' }, note: { type: 'string' } },
}
const STALENESS = {
  type: 'object', additionalProperties: false, required: ['results'],
  properties: {
    results: {
      type: 'array',
      items: {
        type: 'object', additionalProperties: false,
        required: ['id', 'changed'],
        properties: {
          id: { type: 'string' }, changed: { type: 'boolean' },
          detail: { type: 'string' },
        },
      },
    },
  },
}
const PR = {
  type: 'object', additionalProperties: false, required: ['opened', 'url', 'note'],
  properties: {
    opened: { type: 'boolean' }, url: { type: 'string' }, note: { type: 'string' },
  },
}
const TICKET = {
  type: 'object', additionalProperties: false,
  required: ['found', 'summary', 'description', 'comments'],
  properties: {
    found: { type: 'boolean' },
    summary: { type: 'string' },
    description: { type: 'string' },
    comments: { type: 'string' },
  },
}

// Worktree before triage, not just before planning. Triage often routes small
// work back to be done inline, and that work still needs to land somewhere
// named: without the jira-/gh- marker the session is reported untracked
// forever. Creating the worktree first means inline work happens in the right
// place too. The cost is one unused worktree when triage rejects the premise.
// Recording is the sanctioned way to finish, not an extra step. A phase that
// halts never reaches the moment a human would report it, so halted runs used
// to leave no trace at all and the evaluation data described only work that
// completed -- it could not show this workflow failing, because failure never
// arrived. The script cannot record on a phase's behalf: it has no shell, and a
// phase that dies mid-flight returns nothing for it to write.
// Set once the worktree exists. RECORD is called while building the worktree
// agents' own prompts, before `wt` is initialised, so reading wt there is a
// temporal dead zone crash on every run.
let recordedBranch = ''

const RECORD = (label) => !recordPhases ? '' :
  `\n\nBefore you return, record this phase. It is the only reason a stopped ` +
  `run leaves any evidence:\n` +
  `  agent-eval record-phase --session "$CLAUDE_CODE_SESSION_ID" ` +
  `--phase '${label}' --status <completed|halted|failed> [--reason '<why>'] `+
  `--branch '${recordedBranch}'\n` +
  `Use completed when you did the job; halted when you deliberately stopped ` +
  `because the work should not continue; failed when you stopped without ` +
  `deciding anything, such as running out of budget or hitting an error. ` +
  `halted and failed look identical from outside and mean opposite things, so ` +
  `do not use one for the other.\n` +
  `agent-eval is an optional companion tool. If the command is not installed ` +
  `(command not found), skip this step silently and carry on: it records ` +
  `metrics and has no bearing on the work. Report any other error verbatim, ` +
  `and never set CLAUDE_CONFIG_DIR to make it work.`

// One fetch, before anything reads the envelope. A failed fetch is not a halt:
// the ticket is required to exist as a reference, but its prose is enrichment,
// and a Jira outage is not a reason to refuse to do the work.
const fetched = await agent(
  `[touchstone: ticket]\n` +
  `Fetch the details of ticket ${ticket} and STOP. Do not plan, implement, ` +
  `branch, or comment on anything.\n` +
  `A key like PROJ-4821 or ABC-36 is a Jira issue: read it with the Atlassian ` +
  `tools, which you can find via ToolSearch. A bare number like 216 is a ` +
  `GitHub issue in the repo you are currently in: read it with ` +
  `gh issue view <number> --json title,body,comments.\n` +
  `Return found=true with summary (the title), description, and comments ` +
  `(concatenated, newest last, each prefixed with its author; empty string if ` +
  `none). Return found=false with empty strings if the ticket cannot be read ` +
  `at all: say why in summary. Do not invent or infer any field.` +
  RECORD('ticket'),
  { label: 'ticket', schema: TICKET, model: 'haiku', effort: 'low' })

const ticketDetail = fetched?.found
  ? fetched
  : { found: false, summary: fetched?.summary ?? 'not fetched', description: '', comments: '' }
if (!ticketDetail.found) {
  log(`ticket ${ticket} details unavailable (${ticketDetail.summary}); ` +
      `continuing without it`)
}

// With no task given, the ticket's own title is the task. If neither exists
// there is nothing to name a branch after and nothing to plan against, which is
// a real dead end rather than something to invent a slug for.
if (!task) {
  if (!ticketDetail.found) {
    throw new Error(
      `touchstone: no task given and ticket ${ticket} could not be read ` +
      `(${ticketDetail.summary}). Pass args {task: "..."} or make the ticket ` +
      `readable; naming a branch after neither is how a fabricated link gets in.`)
  }
  task = ticketDetail.summary
  log(`no task given; using ticket summary: ${task}`)
}

phase('Worktree')
const sBranch = stage('branch')

// --show-toplevel returns the worktree's own path when run from inside one,
// not the repository; every session now runs inside a worktree, so a new
// worktree path built from it nests inside the current one instead of sitting
// beside it. The repo root must come from --git-common-dir instead.
//
// Re-running the same ticket is normal, not an error, and git will not let a
// branch be checked out twice: both prompts below must find an existing
// branch or worktree and reuse it rather than treat a collision as a halt.

// existingBranch is for follow-up work on an open PR: review feedback, or scope
// added to a ticket already in flight. Cutting a fresh branch there strands the
// delta away from the PR it belongs to. The ticket stays mandatory either way.
const wt = args?.existingBranch
  ? await agent(
      `[touchstone: branch:existing]\n` +
      `Find the worktree that already holds the current branch, then STOP. Do ` +
      `not create a branch, do not create a worktree, do not fetch, do not ` +
      `pull, do not plan or implement.\n` +
      `This task continues work on an existing branch for ticket ${ticket}.\n` +
      `1. Return created=false if the working tree has uncommitted changes. Say ` +
      `what is dirty. Never stash, reset, or discard the user's work.\n` +
      `2. Run git worktree prune. It only removes registrations for worktree ` +
      `directories that no longer exist on disk; it never touches a directory ` +
      `that does exist. Run it before listing worktrees so a stale record left ` +
      `behind by a hand-deleted directory cannot be matched below.\n` +
      `3. Return created=false if HEAD is detached, or if the current branch is ` +
      `the repo's base branch (main, master, or whatever origin/HEAD names). ` +
      `Committing follow-up work straight onto the base is not what this mode is ` +
      `for.\n` +
      `4. Note the current branch name (git branch --show-current), then run ` +
      `git worktree list --porcelain. It prints one record per worktree: a ` +
      `"worktree <path>" line followed by a "branch refs/heads/<name>" line (or ` +
      `"detached"/"bare"). A branch already checked out somewhere cannot also ` +
      `have a worktree created for it here, git refuses that outright, so the ` +
      `existing record is what this task must use, not a new one.\n` +
      `5. Find the record whose branch matches the current branch name and take ` +
      `its path. That path is correct whether it is the main checkout or a ` +
      `linked worktree: the branch lives there and nowhere else.\n` +
      `6. If no record matches (the branch is checked out in no worktree at ` +
      `all), return created=false and say so. Do not create one for it; that is ` +
      `what the default (non-existingBranch) mode is for.\n` +
      `7. Otherwise return created=true, branch set to the current branch name, ` +
      `base set to the repo's base branch, and path set to the absolute path ` +
      `from the matching record. Note in detail whether that path is the main ` +
      `checkout or a linked worktree, and whether the branch name carries a ` +
      `jira- or gh- marker. An unmarked pre-existing branch is allowed here and ` +
      `is not a failure: it predates the convention. Say so plainly so the ` +
      `session is known to be untrackable by branch name.` + RECORD('branch:existing'),
      { label: 'branch:existing', schema: BRANCH, model: 'haiku', effort: 'low' })
  : await agent(
  `[touchstone: branch]\n` +
  `Create the working branch and a git worktree for it, then STOP. Do not ` +
  `plan, implement, or commit any code.\n` +
  `Task: ${brief(task)}\n` +
  `Ticket: ${ticket}\n` +
  `Branch type prefix: ${args?.branchType ?? 'feat'}\n` +
  `1. Refuse and return created=false if the working tree has uncommitted ` +
  `changes. Say what is dirty. Never stash, reset, or discard the user's work.\n` +
  `2. Run git worktree prune. It only removes registrations for worktree ` +
  `directories that no longer exist on disk, never a directory that does ` +
  `exist, so it is safe to run unconditionally; it clears the way for ` +
  `re-adding a worktree whose directory was deleted by hand.\n` +
  `3. Find the repo root: dirname "$(git rev-parse --path-format=absolute ` +
  `--git-common-dir)". Do not use git rev-parse --show-toplevel for this.\n` +
  (baseOverride
    ? `4. The base for this branch is given: ${baseOverride}. Do not read the ` +
      `remote HEAD and do not substitute main or master; this work is stacked ` +
      `on that branch deliberately. Verify the ref resolves ` +
      `(git rev-parse --verify ${baseOverride}) and return created=false naming ` +
      `it if it does not.\n`
    : `4. Find this repo's base branch: read the remote HEAD ` +
      `(git symbolic-ref --short refs/remotes/origin/HEAD), falling back to ` +
      `whichever of main or master exists. Do not assume main.\n`) +
  `5. Name the branch exactly: <type>/jira-<KEY>-<slug> when the ticket is a ` +
  `Jira key such as PROJ-4821, or <type>/gh-<NUMBER>-<slug> when it is a ` +
  `GitHub issue number such as 216 or #216. The literal jira- or gh- marker ` +
  `is required. Derive <slug> from the task: lowercase, hyphen-separated, at ` +
  `most 6 words, no trailing hyphen. If the ticket is malformed and you cannot ` +
  `classify it as either, return created=false and say so. Never cut an ` +
  `unmarked branch: it would be reported untracked with no way to recover the ` +
  `link.\n` +
  `6. The worktree path is <repo-root>/.claude/worktrees/<slug>, where <slug> ` +
  `is the branch name with its <type>/ prefix stripped (for example ` +
  `feat/jira-PROJ-4821-session-reset gives jira-PROJ-4821-session-reset).\n` +
  `7. Run git worktree list --porcelain and look for a record whose "branch ` +
  `refs/heads/<name>" line matches the branch name from step 5. If one ` +
  `exists, the branch is already checked out somewhere; git refuses to check ` +
  `it out twice, so return created=true using that record's own path (even ` +
  `if it differs from the path in step 6), note in detail that the branch ` +
  `was reused rather than created, and stop: do not fetch, pull, or run any ` +
  `worktree add.\n` +
  `8. Otherwise check whether the branch exists at all (git show-ref --verify ` +
  `--quiet refs/heads/<name>). If it does, the fetch and fast-forward in step ` +
  `10 are not needed; go straight to step 9.\n` +
  `9. Check whether the path from step 6 already exists on disk. If it does, ` +
  `return created=false naming the exact path and explaining what is there. ` +
  `Do not delete it, do not rename around it, and do not pick a different ` +
  `slug: a surprising second worktree is worse than a clear halt.\n` +
  `10. If the branch exists (step 8) and the path is clear (step 9), run ` +
  `git worktree add <path> <branch>, without -b since the branch already ` +
  `exists; a branch cannot be created twice. Note in detail that the branch ` +
  `was reused rather than created, and set base to ` +
  (baseOverride ? `${baseOverride}.\n` : `the repo's base branch.\n`) +
  (baseOverride
    ? `11. If the branch does not exist, run ` +
      `git worktree add <path> -b <branch> ${baseOverride} directly. Do not ` +
      `fetch, do not check out the base, and do not pull or rebase it: it is a ` +
      `branch under review whose head the user chose, and it may itself be ` +
      `checked out in another worktree, where checking it out again would fail.\n`
    : `11. If the branch does not exist, git fetch origin, check out the base ` +
      `branch, and fast-forward it (git pull --ff-only). If the pull is not a ` +
      `fast-forward, return created=false and say so rather than merging or ` +
      `rebasing. Then run git worktree add <path> -b <branch> <base>.\n`) +
  `Do not check out the new branch in this working tree; the worktree is a ` +
  `separate checkout.\n` +
  `Return the branch you created or reused, the base you cut it from (or ` +
  (baseOverride ? `${baseOverride}` : `the repo's base branch`) +
  ` if the branch already existed), and the absolute ` +
  `worktree path.` + RECORD('branch'),
  { label: 'branch', schema: BRANCH, model: 'haiku', effort: 'low' })
sBranch.close()

// A failed worktree step halts rather than falling through: implementing onto
// whatever tree happened to be checked out is how unrelated work lands in a PR.
if (!wt?.created) {
  return await halted('Worktree', {
    branch: wt?.branch,
    base: wt?.base,
    detail: wt?.detail,
    note: args?.existingBranch
      ? 'No usable worktree, so nothing was planned or implemented. Check out ' +
        'the branch this work belongs on, commit or stash any changes, then ' +
        're-run.'
      : 'No worktree was created, so nothing was planned or implemented. ' +
        'Commit or stash your changes, or resolve the base branch problem in ' +
        'detail, then re-run. If fetch or pull cannot run here (a remote ' +
        'needing a hardware key, for example), pull the base branch manually ' +
        'first, or pass existingBranch: true if this work belongs on a branch ' +
        'that already exists.',
  })
}
// The review range and the PR target both read wt.base, and a reused branch or
// the existingBranch path reports the repo default regardless of what it was
// actually cut from.
if (baseOverride) wt.base = baseOverride
recordedBranch = wt.branch
log(args?.existingBranch
  ? `worktree ${wt.path} reused for branch ${wt.branch} (base ${wt.base})`
  : `worktree ${wt.path} created for branch ${wt.branch} (base ${wt.base})`)


// Every agent dispatch below inherits the session's working directory, which
// is the main checkout, not the worktree; each prompt must say so explicitly
// or the agent will silently plan, implement, or push from the wrong tree.
// Nothing passed to agent() reaches disk as an identity: opts.label is display
// only, and the workflow journal records just an agent id and a prompt hash. The
// tag below is the only durable name a workflow agent gets, so it is read back
// out of the transcript's first user message rather than restated at each call.
// The envelope: facts every phase needs, and nothing else. Deliberately not a
// shared conversation. Withholding each phase's reasoning from the others is
// what keeps the devil's advocate and the reviewers unbiased, so the envelope
// carries only what is true regardless of who is reading -- where the code is,
// what the ticket asks for -- and never what another phase concluded about it.
//
// Fetched once. Every phase used to rediscover the ticket, or more often work
// without it, from a task string clamped short enough to lose the requirement.
// The ticket is the specification, so it is never clamped: clamping it here cut
// one ticket mid-acceptance-criterion and three phases planned against a spec
// whose second half they could not see.
// The envelope carries the ticket's identity, never its prose. Only Triage is
// given the text to scrutinise, and Plan to work from as the specification.
// Handing it to every phase made the devil's advocate a critic of the ticket's
// own reasoning and burned a whole plan-and-challenge cycle without changing a
// line of code.
const envelope = () =>
  `Ticket ${ticket}${ticketDetail.found ? `: ${ticketDetail.summary}` : ' (details unavailable)'}\n` +
  `Repo worktree: ${wt.path}\nBranch: ${wt.branch} (base ${wt.base})\n`

// Never clamped: brief() once cut a ticket mid-acceptance-criterion and three
// phases planned against a spec whose second half they could not see.
const ticketSpec = () => ticketDetail.found
  ? `Ticket description:\n${ticketDetail.description}\n` +
    (ticketDetail.comments.trim()
      ? `Ticket comments:\n${ticketDetail.comments}\n` : '')
  : `Ticket ${ticket} could not be read; work from the task text alone.\n`

const treeAgent = (prompt, opts) =>
  agent(
    `[touchstone: ${opts.label}]\n` +
    `Work in the git worktree at ${wt.path}. Every command, git included, acts ` +
    `on that tree and not on the main checkout: pass it explicitly, with ` +
    `git -C ${wt.path} and absolute paths. Never cd there, not even as ` +
    `cd ${wt.path} && <cmd>. The Bash working directory persists between ` +
    `calls, so one such command moves the whole session, and the run state ` +
    `written afterwards is filed under the worktree's path instead of the ` +
    `repo's.\n\n` +
    envelope() + `\n` + prompt + RECORD(opts.label),
    opts)

// Latch 1. The premise checks that matter most are usually one grep, and a task
// whose stated facts are wrong must not be planned around. Buying that check
// for one cheap agent is the difference between a 2-agent run and an 11-agent
// one, so it runs before anything expensive.
phase('Triage')
const sTriage = stage('triage')
let triage = null
try {
  triage = await treeAgent(
  `You are triage. Do the cheapest investigation that settles two questions, ` +
  `then STOP. Do not implement, do not commit, do not write a plan.\n` +
  `Task: ${brief(task)}\n` +
  `You are the ONLY phase that scrutinises the ticket itself. No later phase ` +
  `sees this text, so a claim in it that you do not check goes unchecked for ` +
  `the whole run:\n` +
  ticketSpec() +
  `1. Is every factual claim the task makes actually true of the code? Check ` +
  `them with grep/read. A false premise is your single most valuable output: ` +
  `report it in premise_note with the command that disproves it.\n` +
  `   Absence of evidence in the repo is not evidence of absence, and calling ` +
  `a premise false on a negative grep is the most expensive mistake this ` +
  `phase makes. Deployment config, infrastructure and runtime state often ` +
  `live outside the repo, and something wanted but not yet built is still a ` +
  `real requirement. Set premise_ok=false only for a claim you positively ` +
  `contradicted by reading code that says otherwise, never for one you merely ` +
  `could not find.\n` +
  `2. How large is the real change, in lines?\n` +
  `scope is about SIZE only, never about whether the task is a good idea: a ` +
  `wrong premise goes in premise_ok and premise_note, and setting scope from it ` +
  `would route a task that needs rethinking into being built immediately. ` +
  `Return scope='inline' if a competent engineer would finish this in roughly ` +
  `ten tool calls or fewer (a comment, a rename, a one-line fix, a config ` +
  `value). Return scope='team' only when the work genuinely needs a plan, new ` +
  `tests, and independent review.\n` +
  `3. How hard is it to get right? This is a separate question from size, and ` +
  `it sets how much reasoning every later phase is given, so answer it on its ` +
  `own terms rather than reading it off the line count.\n` +
  `  trivial  - mechanical and locally verifiable. Config, docs, a rename, a ` +
  `version bump, a value change with an obvious correct answer.\n` +
  `  routine  - ordinary feature or fix work in a well-understood area, where ` +
  `the shape of the answer is clear once you have read the code.\n` +
  `  involved - concurrency, migrations, auth or crypto, protocol or data ` +
  `formats, anything whose failure is silent, anything touching a boundary ` +
  `other systems depend on, or anywhere you are genuinely unsure what correct ` +
  `looks like.\n` +
  `Size and difficulty are independent. A two-hundred-line test file is ` +
  `trivial; a five-line change to a signing path is involved. When torn ` +
  `between two levels, choose the higher one: under-reasoning a hard change ` +
  `costs far more than over-reasoning an easy one. Put the deciding factor in ` +
  `complexity_note, in one sentence.`,
  { label: 'triage', schema: TRIAGE, model: 'sonnet', effort: 'medium' })
} catch (e) {
  log(`triage returned no verdict: ${e?.message ?? e}`)
}

// An absent verdict halts rather than fails open: planning on an unverified
// premise is the one failure this latch exists to prevent.
if (!triage) {
  sTriage.close()
  return await halted('Triage', {
    note: 'Triage produced no verdict, so the task premise is unverified and ' +
          'nothing was planned or implemented. Re-run; if it repeats, the task ' +
          'text or the TRIAGE schema is at fault, not the model.',
  })
}

// A disproved premise halts: that is a fact about the task, and planning around
// it is the one thing this latch exists to stop.
if (!triage.premise_ok) {
  sTriage.close()
  return await halted('Triage', {
    scope: triage.scope,
    premise_ok: false,
    premise_note: triage.premise_note,
    estimated_loc: triage.estimated_loc,
    evidence: triage.evidence,
    note: 'The task\'s premise does not hold. Fix the brief before planning ' +
      'around it; see premise_note.',
  })
}

// Size does not. The old latch halted here and told the user to do the work
// themselves, which delivers nothing: triage's finding was that the change is
// SMALL, not that it is unwanted, and handing back a ten-line edit costs more
// of the user's attention than making it. Small work now runs, with the
// planning and multi-lens review phases skipped instead of the work.
const inlineMode = triage.scope === 'inline'
  || (triage.estimated_loc ?? Infinity) < INLINE_LOC
if (inlineMode) {
  log(`triage sized this as ` +
      (triage.estimated_loc != null
        ? `~${triage.estimated_loc} LOC (< ${INLINE_LOC})`
        : 'inline') +
      `; implementing it directly, skipping the Plan phase`)
}

// Reasoning effort, scaled by the difficulty triage just judged.
//
// This is the lever that actually bounds spend, and the only one available
// before an agent starts. The stage ceilings below cannot do it: they are read
// after an agent returns, so on a single-shot stage a ceiling spends the tokens
// and then discards the work, which is why plan and implement deliberately
// carry none. effort is set on the call.
//
// It is also the lever that matters most, for a reason that is not obvious from
// the token counts. On a measured run of this pipeline, output was 15% of cost
// and re-read context was 85%: every turn an agent takes re-reads everything it
// has accumulated. Lower effort earns its saving mainly by taking fewer turns,
// so the context is re-read fewer times -- not by writing shorter replies.
//
// Levels follow Anthropic's published effort/cost measurements: on long-horizon
// coding `medium` gave up about two points of pass rate for half the cost,
// while research-shaped work was near flat between `medium` and the default. So
// the phases that reason about code drop a level on routine work, and the
// phases that mostly read and report drop further.
//
// `involved` keeps every default. The point of asking triage is to spend less
// on easy work, never less on hard work.
const EFFORT = {
  trivial:  { plan: 'low',    implement: 'medium', review: 'medium', verify: 'low' },
  routine:  { plan: 'medium', implement: 'high',   review: 'high',   verify: 'low' },
  involved: { plan: 'high',   implement: 'xhigh',  review: 'xhigh',  verify: 'medium' },
}
const complexity = EFFORT[triage.complexity] ? triage.complexity : 'involved'
const effortFor = EFFORT[complexity]
if (triage.complexity && complexity !== triage.complexity) {
  log(`triage returned an unrecognised complexity (${triage.complexity}); ` +
      `treating it as involved, which spends the most rather than the least`)
}
log(`triage judged this ${complexity}` +
    (triage.complexity_note ? `: ${triage.complexity_note}` : '') +
    ` -- plan/implement/review/verify effort ` +
    `${effortFor.plan}/${effortFor.implement}/${effortFor.review}/${effortFor.verify}`)
sTriage.close()

// A plan an earlier run already produced arrives as args.plan and starts this
// run at Implement. Without it the only way to reuse a plan was to paste it into
// the task, which routed it back through the planner and asked that phase to
// carry out work it is forbidden to do.
const givenPlan = typeof args?.plan === 'string' && args.plan.trim()
  ? args.plan.trim() : null
let plan = givenPlan
  ? {
      plan: givenPlan,
      acceptance_criteria: args?.acceptanceCriteria ?? [],
      risky_areas: args?.riskyAreas ?? [],
      task_demands_implementation: false,
    }
  : null

if (givenPlan) log('Plan supplied in args; Plan phase skipped.')

if (!plan && inlineMode) {
  plan = {
    plan: `Triage sized this as a small, self-contained change and no planning ` +
      `phase ran. What triage found: ${triage.premise_note}\n` +
      `Make the change the task asks for and nothing more.`,
    acceptance_criteria: [],
    risky_areas: [],
    task_demands_implementation: false,
  }
}

if (!givenPlan && !inlineMode) {
phase('Plan')
const sPlan = stage('plan')
plan = await treeAgent(
  `You are the planner for this task; do NOT implement anything. You have no ` +
  `Edit or Write tool, and must not reach for another route to the same thing.\n` +
  `Task: ${brief(task)}\n` +
  `Triage found: ${triage?.premise_note ?? 'n/a'}\n` +
  `The ticket is the specification. Triage has already checked its factual ` +
  `claims, so take its requirement and do not re-litigate its reasoning; no ` +
  `later phase sees this text, so every requirement it states must survive ` +
  `into your plan and acceptance criteria:\n` +
  ticketSpec() +
  `Read the relevant code first. Return a concrete implementation plan, ` +
  `testable acceptance criteria, and the risky areas a reviewer should probe.\n` +
  `If the task itself tells you to implement, or says a plan already exists and ` +
  `only needs carrying out, set task_demands_implementation and explain in ` +
  `conflict_note. Do not resolve the contradiction by obeying the task: pass a ` +
  `plan already in hand as args.plan instead, which starts the run at Implement.`,
  { label: 'planner', schema: PLAN, model: 'opus', effort: effortFor.plan,
    agentType: 'touchstone:planner' })
if (!plan) throw new Error('planner failed')

// This used to halt and ask the user to re-run with args.plan. The script is
// already holding that plan, so the halt bought nothing but a round trip: the
// planner cannot implement anyway, having no Edit or Write tool.
if (plan.task_demands_implementation) {
  log(`planner reports the task itself demands implementation ` +
      `(${plan.conflict_note ?? 'no note given'}); using its plan as-is and ` +
      `going straight to Implement`)
}

sPlan.close()
if (sPlan.over()) {
  return await halted('Plan', {
    plan: plan.plan,
    note: 'plan stage exceeded its token ceiling; the run stopped before Implement. ' +
      'Check the branch before re-running: a planner that overruns has sometimes ' +
      'written code despite being forbidden to.',
  })
}
}

phase('Implement')
const sImpl = stage('implement')
const impl = await treeAgent(
  `Implement this task in the current repo.\n` +
  `Task: ${brief(task)}\nPlan: ${brief(plan.plan)}\n` +
  (plan.acceptance_criteria.length
    ? `Acceptance criteria:\n- ${plan.acceptance_criteria.join('\n- ')}\n`
    : `Acceptance criteria: none were supplied with this plan. Derive them from ` +
      `it before you write anything, and state them in your summary.\n`) +
  `Follow the crap-controlled-changes skill: TDD first, iterating with the ` +
  `repo's own test command. Commit with crap-commit.sh, which runs the gate ` +
  `itself and refuses if it is red; do not run crap-check.sh first, since that ` +
  `doubles a check that already runs the suite twice, and do not use either as ` +
  `your test loop. Run it in the foreground with a Bash timeout of 600000; ` +
  `never background it and wait with sleep. Follow its NEXT_ACTION until ` +
  `green. Commit signed, in as many commits as the work naturally takes. Never run ` +
  `--accept or --mark-scored yourself; both need explicit user approval. ` +
  `Do not push and do not open a PR: those are the user's to authorise.\n` +
  `Return commit_range as '<base-sha>..<head-sha>' using the merge base with ` +
  `${wt.base} and your final HEAD, both as full 40-character SHAs: later ` +
  `phases compare their own HEAD against the head of this range to work out ` +
  `what is still unreviewed, and an abbreviated SHA never matches. ` +
  `Downstream phases are given that range and ` +
  `read the diff themselves, so it is how your work is handed on: a summary of ` +
  `it is not, and will not be forwarded.`,
  { label: 'implementer', schema: IMPL, model: 'sonnet', effort: effortFor.implement })
if (!impl) throw new Error('implementer failed')
sImpl.close()
if (sImpl.over()) {
  return await halted('Implement', {
    plan: plan.plan, implemented: impl.summary,
    note: 'implementer exceeded its token ceiling; any work is on the branch, gates and review did not run',
  })
}

// A draft PR, opened as soon as there is a commit to hang it on.
//
// The alternative, and what this used to do, was to produce a PR only on the
// happy path. Every other ending left the work in a worktree nobody opens and a
// halt note in a session that scrolls away, so a run that spent an hour and
// stopped one step short was indistinguishable from one that never happened.
// That is the worst outcome this pipeline can produce, and it produced it
// silently.
//
// So the artefact comes first and the *readiness* is what the run earns. From
// here on every halt has somewhere durable to be written, GitHub notifies, and
// the branch is pushed rather than stranded on one machine. Nothing about the
// gates changes: a draft is not a review request, and the PR phase still
// refuses to mark it ready until they are green.
//
// Deliberately not earlier: `gh pr create` needs a commit, and the halts before
// this point (a disproved premise, a dirty tree, a planner that overran) are
// cheap, immediate, and have no code to show. The expensive halts are all
// downstream of here.
const DRAFT = {
  type: 'object', additionalProperties: false,
  required: ['opened', 'detail'],
  properties: {
    opened: { type: 'boolean' },
    url: { type: 'string' },
    number: { type: 'integer' },
    detail: { type: 'string' },
  },
}
phase('Draft PR')
const draft = await treeAgent(
  `Make sure this branch has a pull request to hang the run's progress on, ` +
  `then STOP.\n` +
  `Task: ${brief(task)}\nWhat has been implemented so far: ${impl.summary}\n` +
  `FIRST check whether one already exists: gh pr view ${wt.branch} ` +
  `--json number,url,isDraft,state. A branch resumed with --existing normally ` +
  `has one, and opening a second is not possible anyway. If an open PR is ` +
  `already there, adopt it: return its number and url with opened=true, say so ` +
  `in detail, and change nothing about it. In particular do not re-draft a PR ` +
  `that is already marked ready for review -- someone did that deliberately.\n` +
  `Only if there is none: git push -u origin ${wt.branch}, then gh pr create --draft` +
  (baseOverride ? ` --base ${baseOverride}` : '') + `. Push the branch either ` +
  `way, so the commits are on the remote rather than on one machine.\n` +
  `The body is a short statement of intent, not a report: two or three ` +
  `sentences on what this branch sets out to do and why, from the ticket. Do ` +
  `not describe the diff, do not claim it is finished, and do not list what ` +
  `you verified -- review has not run yet and the gates are not the subject. ` +
  `Open it as a draft and leave it a draft: something later in this run marks ` +
  `it ready, and only once every gate is green.\n` +
  `This exists so the work is visible even if the run stops early, so a ` +
  `failure to open it is worth reporting but is never fatal: if push or ` +
  `gh fails, return opened=false with the error in detail and stop. Do not ` +
  `retry in a loop, do not open a non-draft PR instead, and do not merge.\n` +
  `Return the PR url and number for the PR this branch now has, whether you ` +
  `opened it or adopted one that was already there.`,
  { label: 'draft-pr', phase: 'Draft PR', schema: DRAFT, model: 'haiku',
    effort: 'low' })
// number, not opened: the halt reporter needs something to comment on, and a
// url with no number is not addressable by `gh pr comment`.
if (draft?.number) {
  draftPr = { url: draft.url, number: draft.number }
  log(`PR #${draft.number} carries this run: ${draft.url ?? '(no url)'} -- ` +
      `every later halt is reported there rather than only in this session`)
} else {
  log(`draft PR not opened (${draft?.detail ?? 'no detail'}); continuing. ` +
      `A halt from here on is only visible in this session`)
}

phase('Review')
const sReview = stage('review')
// risky_areas is deliberately not part of this: it is a required schema field
// and a planner asked for risky areas always returns some, so including it
// pinned `big` to true and made the diffstat agent's answer decorative.
const big = impl.files_changed.length > 5 || (impl.insertions ?? 999) > 200
const trivial = impl.files_changed.length <= 1 && (impl.insertions ?? 999) < INLINE_LOC
// Named, not positional. The count used to slice a list from the front, so the
// third lens ran only when someone passed reviewers: 3 by hand, and the size
// latches silently decided WHICH lenses existed rather than how many. The
// dropped one was design fit; the devil's advocate covers that ground now and
// has to demonstrate the claim, which design fit never did.
const LENS = {
  correctness: {
    label: 'correctness',
    charge: `You are an adversarial reviewer. REFUTE the claim that this ` +
      `implementation is correct, through one lens: hunt for inputs or states ` +
      `where the new code returns wrong results or breaks existing callers.`,
  },
  requirements: {
    label: 'requirements',
    charge: `You are an adversarial reviewer. REFUTE the claim that this ` +
      `implementation is complete, through one lens: hunt for acceptance ` +
      `criteria that are unmet, half-met, or untested.`,
  },
  advocate: {
    label: 'advocate',
    charge: `You are the devil's advocate: a reviewer whose lens is whether ` +
      `this should exist at all, or exist in this shape. The others assume the ` +
      `change is wanted and ask whether it is right; you are the one who does ` +
      `not assume it. Run the repo's own tests, then hunt for a simpler route ` +
      `that is only visible now the code exists (a config value, an existing ` +
      `utility, deleting code instead), scope the change took on that nothing ` +
      `asked for, and cost it imposes that the diff hides.\n` +
      `Report a finding only where you DEMONSTRATED the gap against the ` +
      `working code, and put that demonstration in evidence: a test that fails ` +
      `and the assertion in it that fails, or the exact command with its ` +
      `actual output beside what you expected. This is why you run against ` +
      `built code instead of a plan. Something you could not reproduce is not ` +
      `a finding however strongly you hold it, and a preference between two ` +
      `working designs is never one.\n` +
      `You are deliberately not shown the ticket text; triage owns its claims. ` +
      `Absence of evidence in the repo is not evidence of absence, so never ` +
      `rest a finding on a negative grep.`,
  },
}

// The advocate is a reviewer, counted and gated with the rest: a one-line diff
// used to get zero reviewers and an advocate anyway, which is the ratio the
// trivial latch exists to prevent.
const lensKeys = trivial ? [] : (big
  ? ['correctness', 'advocate', 'requirements']
  : ['correctness', 'advocate'])
const lenses = (args?.reviewers != null
    ? lensKeys.slice(0, Math.max(0, Math.min(args.reviewers, lensKeys.length)))
    : lensKeys)
  .filter(k => !(k === 'advocate' && args?.devilsAdvocate === false))
  .map(k => LENS[k])
const reviewerCount = lenses.length
if (!reviewerCount) {
  log(`review skipped: ${impl.files_changed.length} file(s) / ${impl.insertions} insertion(s) ` +
      `is under the ${INLINE_LOC}-line bar; adversarial lenses on a one-liner is the ratio this workflow is trying to avoid`)
} else {
  log(`review: ${lenses.map(l => l.label).join(', ')}`)
}
// Every finding gets an id and a recorded_at the moment it enters the script,
// here and nowhere else: the initial review, every fix round's tail review,
// and the post-mutation review all return through reviewOf. Neither is asked
// of the model -- a model-supplied id is exactly as unreliable as the
// model-supplied title this replaces, so the script stamps its own.
let findingSeq = 0
const headOf = (range) => range.includes('..') ? range.split('..')[1].trim() : range.trim()
// A verifier told to copy an id "in brackets" sometimes copies the brackets
// too. Strip a matching pair before joining, so [f1] lines up with f1.
const stripBrackets = (s) => {
  const t = s.trim()
  const m = /^\[(.+)\]$/.exec(t)
  return (m ? m[1] : t).trim()
}
// The settled/fresh-finding dedup below cannot key on id alone: every
// reviewOf call mints a brand-new one, even for a finding that is, in
// substance, the same one reported again. contentKeyOf catches a
// byte-identical re-report without needing the model's cooperation.
// duplicate_of is the other half: a reworded re-report can't match by
// content either, so the reviewer is handed the known findings by id (the
// `known` param below) and asked to reference one back instead of restating
// it, the same way the verdict join below matches an id rather than text.
const contentKeyOf = (f) => JSON.stringify([f.title, f.file, f.claim, f.evidence])
const dupOf = (f) => (typeof f.duplicate_of === 'string' && f.duplicate_of.trim())
  ? stripBrackets(f.duplicate_of) : null
// Reports how the duplicate matched, not just that it did: referencing a
// settled finding and restating one byte for byte mean different things, and
// only the caller knows which it can afford to discard.
// Order matters: all four fields matching byte for byte means the text was
// copied from the known list the lens was handed, so it is a restatement even
// if duplicate_of is set too.
const duplicateTargetOf = (f, known) => {
  const key = contentKeyOf(f)
  const restated = known.find(k => contentKeyOf(k) === key)
  if (restated) return { hit: restated, byReference: false }
  const dup = dupOf(f)
  const referenced = dup ? known.find(k => k.id === dup) : undefined
  return referenced ? { hit: referenced, byReference: true } : null
}

// Review is a function of a range, not a one-shot on the implementer's commits.
// Reviewing only impl.commit_range meant every later phase that commits -- the
// fix rounds and the mutation gate -- shipped unread. On one run that was 314
// insertions across 6 files, two of which no reviewer had ever opened, and it
// silently reverted an earlier context-cancellation fix on every mutating
// handler. The PR was green on every gate and carried a new bug.
const reviewOf = async (range, tag, picked, known = [], knownCharge = '') => {
  const out = await parallel(picked.map((lens) => () =>
    treeAgent(
      `${lens.charge}\n` +
      `Task: ${brief(task)}\n` +
      `Commit range: ${range}\n` +
      `You are given the range, not an account of what was done, on purpose: ` +
      `read git diff ${range} yourself and form your own view. Read the ` +
      `surrounding code as well: a change is wrong in its context, not in ` +
      `isolation, and a line this range only deletes may be load-bearing ` +
      `somewhere the range does not show you.\n` +
      `Report only findings you can defend with file:line evidence. Do NOT ` +
      `report coverage, complexity, test quality, or style: deterministic ` +
      `gates own those.` +
      (known.length
        ? `\nThe findings below were already reported earlier this run, each ` +
          `with its id in brackets, whether already fixed and verified or ` +
          `still tracked as open. If what you would report is the same ` +
          `underlying issue as one of these, even worded quite differently, ` +
          `set duplicate_of to that id instead of inventing a new one; report ` +
          `a finding with no duplicate_of only for a genuinely different bug.\n` +
          known.map(k => `[${k.id}] ${k.title} (${k.file}): ${k.claim}`).join('\n') +
          knownCharge
        : ''),
      { label: `${tag}:${lens.label}`, phase: 'Review', schema: FINDINGS,
        model: 'opus', effort: effortFor.review })))
  return out.filter(Boolean).flatMap(r => r.findings)
    .map(f => ({ ...f, id: `f${++findingSeq}`, recorded_at: headOf(range) }))
}

// Everything from here to the PR is measured against reviewedThrough: the SHA
// an adversary has actually read up to. It only ever advances by way of a
// review, so a phase that commits without one leaves it behind and the PR
// guard below refuses.
let reviewedThrough = headOf(impl.commit_range)

let open = reviewerCount
  ? await reviewOf(impl.commit_range, 'review', lenses)
  : []
sReview.close()

const sFix = stage('fix')
// A finding a verifier confirmed fixed must not come back through the tail
// review as a fresh one: the loop would never converge, and the fixer would be
// sent to undo its own work. Holds the finding objects themselves, not an id
// or a content hash, so a later reviewOf call can be handed their title/file/
// claim as the known-findings list a duplicate_of reference joins against.
const settled = []
// A lens pointing a fresh finding at a settled one may be restating the claim
// it was handed, or reporting the fix did not hold. Not reopened, which would
// send the fixer to undo its own work; recorded so it is not dropped in silence.
const regressionSuspects = []
let round = 0
// Which of the loop's four exits fired. Checked in the same order the loop
// tests them, so the answer matches the condition that actually stopped it.
const fixStopReason = () =>
  !open.length ? 'every finding was resolved'
  : round >= MAX_REVIEW_ROUNDS
    ? `the ${MAX_REVIEW_ROUNDS}-round limit was reached, so these survived every round`
  : sFix.over()
    ? `the fix stage passed its ${Math.round(CEILINGS.fix / 1000)}k output-token ` +
      `ceiling, so the loop stopped early -- these have not had every round`
  : outOfBudget()
    ? 'the run passed its overall token budget, so the loop stopped early'
  : 'the loop ended without reaching any of its limits, which should not happen'

while (open.length && round < MAX_REVIEW_ROUNDS && !outOfBudget() && !sFix.over()) {
  round++
  phase('Fix')
  const fixed = await treeAgent(
    `Fix these confirmed review findings in the current repo, TDD first, ` +
    `iterating with the repo's own test command. Commit with crap-commit.sh, ` +
    `which gates and commits in one call: run it in the foreground with a Bash ` +
    `timeout of 600000, never background it and wait with sleep, and do not ` +
    `pre-run crap-check.sh. Do not push or open a PR.\n` +
    `Task: ${brief(task)}\n` +
    `The work under review is ${impl.commit_range}; read that diff for context ` +
    `rather than guessing what the change was meant to do.\n` +
    `Fix what the findings name and no more. If fixing one requires reverting ` +
    `or weakening a deliberate part of the change that no finding objected to, ` +
    `say so in note and leave it: an unasked-for revert is how this workflow ` +
    `has shipped regressions before.\n` +
    `Return head_sha: the full 40-character SHA of HEAD after your last commit, ` +
    `or of the unchanged HEAD if you committed nothing. Your commits are ` +
    `reviewed as <previous head>..<your head_sha>, so a wrong or abbreviated ` +
    `SHA there is how unreviewed code reaches the PR.\n` +
    `Findings:\n` +
    open.map(f => `- ${f.title} (${f.file}): ${f.claim}`).join('\n'),
    { label: `fix:${round}`, schema: FIXED, model: 'sonnet', effort: effortFor.implement })
  // Verification and the tail review both read the fix's finished commits and
  // answer independent questions of them -- "are the named findings closed?"
  // and "did the fix break something new?" -- so they run together. Sequenced,
  // they made every round three model turns deep, and rounds are the whole
  // wall-clock cost of this phase: the review lenses above are parallel, so
  // trimming those buys tokens and almost no time, while a round does not.
  //
  // They stay two separate agents on purpose. Merging them would hand the
  // "did anything break?" question to the agent that has just finished
  // deciding the fixes are good, and a reviewer grading work it has already
  // blessed is not a reviewer. Independence is the point; the sequencing was
  // never part of it.
  const head = fixed?.head_sha?.trim()
  const tailReviewable =
    reviewerCount && head && head !== reviewedThrough && !outOfBudget()

  const [verdicts, freshRaw] = await parallel([
    // One verifier for every finding, not one each. Six findings meant six
    // agents that each re-read the same diff to answer six questions about it;
    // the reading is the expensive part and it is identical across them.
    () => treeAgent(
      `Verify, finding by finding, whether each is now actually fixed in the ` +
      `repo. Read the code for each one; do not trust any claim that it was ` +
      `fixed, including your own reasoning about a neighbouring finding.\n` +
      `Each finding below is listed with its id in brackets. Return one ` +
      `verdict per finding with that id copied exactly into id; order does ` +
      `not matter. A verdict whose id is not in this list is discarded, and a ` +
      `finding with no verdict stays open. Nothing is matched on the title, ` +
      `so rewording it costs nothing.\n` +
      open.map(f =>
        `[${f.id}] ${f.title} (${f.file}): ${f.claim}. Evidence was: ${f.evidence}`
      ).join('\n'),
      // phase is explicit: inside parallel() the global phase() cursor races
      // with the Review group the tail lens opens beside it.
      { label: `verify:${round}`, phase: 'Fix', schema: VERDICTS, model: 'opus',
        effort: effortFor.verify }),
    // The point of the loop: a fix is a change, so it faces the same adversary.
    // One lens, not all of them -- correctness is where a fix round goes wrong,
    // and the range is small.
    // async, so the skip path still hands parallel() a promise rather than a
    // bare array.
    async () => tailReviewable
      ? reviewOf(`${reviewedThrough}..${head}`, `review:fix:${round}`, [LENS.correctness],
          [...settled, ...open])
      : [],
  ])

  // Keyed on the id the script assigned in reviewOf, never the title: a model
  // asked to echo a title verbatim reworded it anyway, which stalled every
  // finding until the round limit and halted the run for good.
  const byId = new Map(
    (verdicts?.verdicts ?? [])
      .filter(v => typeof v.id === 'string')
      .map(v => [stripBrackets(v.id), v.fixed === true]))
  // Unmatched means unverified, which stays open: a finding silently dropped
  // because its id came back missing or mistyped is the one failure this must
  // not have.
  for (const f of open) if (byId.get(f.id) === true) settled.push(f)
  open = open.filter(f => byId.get(f.id) !== true)

  // Filtered after the verdicts land, not before, so a finding the fix closed
  // cannot come back as a fresh one. That ordering is what the sequencing used
  // to give for free, and it is the only thing that had to be preserved here.
  if (tailReviewable) {
    const known = [...settled, ...open]
    const settledIds = new Set(settled.map(k => k.id))
    const fresh = []
    for (const f of freshRaw ?? []) {
      const dupe = duplicateTargetOf(f, known)
      if (!dupe) { fresh.push(f); continue }
      if (dupe.byReference && settledIds.has(dupe.hit.id)) {
        regressionSuspects.push({ ...f, duplicate_of: dupe.hit.id, round })
        log(`round ${round}: a lens reports [${dupe.hit.id}] again after it was ` +
            `verified fixed; not reopened, carried to the report`)
      } else {
        log(`round ${round}: dropped a re-report of [${dupe.hit.id}]`)
      }
    }
    if (fresh.length) log(`round ${round}: the fix itself introduced ${fresh.length} new finding(s)`)
    open = open.concat(fresh)
    reviewedThrough = head
  } else if (head) {
    reviewedThrough = head
  }
  log(`round ${round}: ${open.length} finding(s) still open`)
}
sFix.close()

if (open.length) {
  // Advisory only: a finding's evidence may have moved since it was
  // recorded. One cheap agent checks each against its evidence, not just its
  // file. Skipped only when the loop ran zero rounds, since nothing could
  // have changed then; a loop that stopped on budget after a round already
  // committed is exactly the case this exists for, so it runs regardless of
  // budget. Any rejection degrades to nothing marked, never to losing the
  // halt.
  let staleness = null
  if (round > 0) {
    try {
      staleness = await treeAgent(
        `For each finding below, report whether the code its evidence ` +
        `describes has changed since it was recorded, not merely whether its ` +
        `file has any commit at all. For each one, run: git log -p ` +
        `<recorded_at>..HEAD -- <file>, substituting that finding's own ` +
        `recorded_at and file, and read the diff. Return changed=true only if ` +
        `a commit in that range touches the location or behaviour the ` +
        `evidence describes; changed=false if the file has no commits in ` +
        `range, or its commits do not touch what the evidence describes. This ` +
        `does not judge whether the finding is still valid, only whether the ` +
        `code it points at moved.\n` +
        open.map(f =>
          `[${f.id}] ${f.file} recorded at ${f.recorded_at}. Evidence: ${f.evidence}`
        ).join('\n'),
        { label: 'staleness', schema: STALENESS, model: 'haiku', effort: 'low' })
    } catch (e) {
      log(`staleness probe failed, reporting findings unmarked: ${e?.message ?? e}`)
    }
  }
  const staleIds = new Set(
    (Array.isArray(staleness?.results) ? staleness.results : [])
      .filter(r => r?.changed === true && typeof r?.id === 'string')
      .map(r => stripBrackets(r.id)))
  const reported = open.map(f =>
    staleIds.has(f.id) ? { ...f, code_changed_since_recorded: true } : f)
  const staleCount = reported.filter(f => f.code_changed_since_recorded).length

  return await halted('Fix', {
    plan: plan.plan, implemented: impl.summary, gates: { green: true, detail: 'enforced by crap-commit-gate on every commit' },
    unresolved_findings: reported, fix_rounds: round, stopped_because: fixStopReason(),
    regression_suspects: regressionSuspects,
    // Report the round count that actually ran and why the loop ended. This
    // said "survived MAX_REVIEW_ROUNDS rounds" unconditionally, so a loop that
    // stopped early on its token ceiling was reported as findings surviving
    // three rounds it never got. The two need opposite remedies -- raise the
    // ceiling, or judge the findings -- and the note pointed at the wrong one.
    note: `${open.length} review finding(s) still open after ${round} fix ` +
          `round(s); ${fixStopReason()}. Stopping before the mutation stage ` +
          `rather than spending it on work that cannot open a PR. Judge each ` +
          `finding: fix it, or reject it as wrong.` +
          (regressionSuspects.length
            ? ` Separately, ${regressionSuspects.length} finding(s) were ` +
              `reported again after being verified fixed, and were not ` +
              `reopened: check by hand that those fixes held.`
            : '') +
          (staleCount
            ? ` ${staleCount} of them have code that changed since they were ` +
              `recorded; re-check those against HEAD before acting on them.`
            : ''),
  })
}

// Mutation is a pre-PR gate, not a per-commit one: it costs a full test-suite
// run per mutant, so it runs once here, on a clean tree, rather than inside the
// implement/fix loops. In an opted-in repo mutation-pr-gate.py blocks
// `gh pr create` while it is red, so a red gate here means the PR phase below
// cannot succeed anyway.
phase('Mutation')
const sMut = stage('mutation')
let mutation = { green: false, detail: 'not run' }

// Mutation gating is opt-in, on the same marker mutation-pr-gate.py reads. A
// repo with no marker has nothing enforcing the gate and may have none of the
// tooling installed, so a red result there is unclearable by any amount of work.
//
// Fail safe: only a confirmed absence skips it. An unknown answer counts as
// gated, costing a mutation run rather than dropping a gate the repo relies on.
const gateProbe = await treeAgent(
  `[touchstone: mutation opt-in]\n` +
  `Report whether this repo opts into mutation gating, then STOP. Run no ` +
  `tests, no mutation tooling, and change nothing.\n` +
  `1. Find the repo root: dirname "$(git rev-parse --path-format=absolute ` +
  `--git-common-dir)".\n` +
  `2. Test for a file named exactly .mutation-gated at that root.\n` +
  `3. Return gated=true if it is there, gated=false only if you confirmed it ` +
  `is absent. If you could not determine either way, return gated=true and ` +
  `explain why in detail: treating an unknown as ungated would drop a real ` +
  `gate.\n` +
  `Report the path you checked in detail.`,
  { label: 'mutation:opt-in', schema: GATED, model: 'haiku', effort: 'low' })

const mutationGated = gateProbe?.gated !== false
if (!mutationGated) {
  mutation = {
    green: true,
    detail: `skipped: repo has not opted into mutation gating ` +
      `(.mutation-gated absent at the repo root). ${gateProbe?.detail ?? ''}`.trim(),
  }
  log(`mutation gate skipped: no .mutation-gated marker, so nothing enforces it ` +
      `(the CRAP and dead-code gates still ran on every commit)`)
} else if (!gateProbe) {
  log('mutation opt-in probe returned nothing; treating the repo as gated')
}
// needs_user_run breaks the loop instead of retrying: a run that cannot fit the
// Bash ceiling returns the same answer every attempt, and each one costs the
// ceiling in wall clock before saying so.
for (let attempt = 1; attempt <= MAX_GATE_ATTEMPTS && !mutation.green
     && !mutation.needs_user_run && !outOfBudget() && !sMut.over(); attempt++) {
  mutation = await treeAgent(
    `Run mutation-check.sh from the crap-controlled-changes skill in this repo. ` +
    `It mutates files in place and needs a clean working tree, so commit anything ` +
    `outstanding first.\n` +
    `HOW TO RUN IT, in this order. The skill's Signal C settles all of this ` +
    `from measurements; do not re-derive a policy of your own, which is why ` +
    `this phase has been inconsistent run to run.\n` +
    `1. mutation-check.sh --verify first. It reads the ledger and costs ` +
    `milliseconds. If it reports the branch already green, you owe no run at ` +
    `all: return green=true saying so. A branch stayed green for two hours ` +
    `once while four full runs re-measured it.\n` +
    `2. If the repo has scripts/gate-env.sh, run ` +
    `eval "$(scripts/gate-env.sh mutation)" in the same shell invocation as the ` +
    `check. It exports the build tags, test runner and database DSN the gate ` +
    `needs. Without it the suite falls back to one throwaway container per test, ` +
    `turning a one-minute run into ten, and on a split build it measures the ` +
    `wrong build entirely. Read the comments it prints: they name any second ` +
    `pass the repo needs.\n` +
    `3. Run it in the FOREGROUND with a Bash timeout of 600000, no flags, so ` +
    `the run is incremental. Do not use run_in_background: past runs here were ` +
    `killed by a SIGTERM nobody has explained, so it is not a route to rely ` +
    `on. Do not poll with sleep either.\n` +
    `4. If one pass will not fit inside that ceiling, SPLIT IT. Do not hand it ` +
    `back. The ledger records per path, so scoped passes accumulate into one ` +
    `green: run MUTATION_ONLY='<glob>' over one module or package at a time, ` +
    `each pass inside the ceiling, until mutation-check.sh --verify reports the ` +
    `branch green. Name every glob you ran in detail. Asking the user to run ` +
    `the gate in their own terminal is not an acceptable outcome, and neither ` +
    `is reporting it unrunnable because of a timeout.\n` +
    `5. Only if one indivisible path exceeds the ceiling on its own, so there ` +
    `is nothing left to split, return green=false with needs_user_run=true and ` +
    `the exact command in detail, including the gate-env eval from step 2. ` +
    `That is a last resort and it means the split failed, so say which glob ` +
    `was too big and how long it ran.\n` +
    `6. --full re-measures every changed source, which you need when something ` +
    `outside the ledger's key changed: a fixture, a compose file, a toolchain ` +
    `pin. A narrowed pass records only what it measured, so say what is still ` +
    `unmeasured.\n` +
    `On KILL_SURVIVORS, write a test that fails on the mutated ` +
    `code and passes on the original, TDD-style, and commit it. Never weaken or ` +
    `restructure production code to dodge a mutant. If a survivor instead reveals ` +
    `a genuine defect (dead branch, wrong condition), fix that properly, TDD ` +
    `first, and commit; that is a real bug the suite was blind to. Never run ` +
    `--accept yourself: if a mutant is provably equivalent, report it and stop. ` +
    `Report the final state, and return head_sha: the full 40-character SHA of ` +
    `HEAD after your last commit, or of the unchanged HEAD if you committed ` +
    `nothing. ` +
    `Anything you commit is reviewed before the PR opens, and that review is ` +
    `keyed off this SHA.`,
    { label: `mutation:${attempt}`, schema: GATE, model: 'sonnet', effort: 'high' }) ?? mutation
}
sMut.close()

if (!mutation.green) {
  return await halted('Mutation', {
    plan: plan.plan, implemented: impl.summary, gates: { green: true, detail: 'enforced by crap-commit-gate on every commit' },
    mutation, unresolved_findings: open, regression_suspects: regressionSuspects,
    note: mutation.needs_user_run
      ? `The mutation run does not fit the 600000 ms Bash ceiling, which for ` +
        `this repo is expected rather than a fault. Run the command in detail ` +
        `in your own terminal, then re-run this workflow: --verify will find ` +
        `the ledger green and the gate will cost milliseconds. No PR was ` +
        `opened, and mutation-pr-gate.py would block one anyway.`
      : `Mutation gate still red after ${MAX_GATE_ATTEMPTS} attempt(s). Surviving ` +
        `mutants are behaviour the tests cannot detect. The PR was left as a ` +
        `draft, and mutation-pr-gate.py would block marking it ready. Kill them ` +
        `with tests, or approve a provably equivalent mutant with ` +
        `mutation-check.sh --accept.`,
  })
}

// The mutation gate commits: new tests, and real fixes when a survivor exposes
// a genuine defect. Those are production changes nobody has read yet.
const mutHead = mutation.head_sha?.trim()
if (reviewerCount && mutHead && mutHead !== reviewedThrough && !outOfBudget()) {
  phase('Review')
  // A reference here means the gate undid a verified fix, and there is no loop
  // left to reopen it into, so it halts. The charge narrows it to that: the
  // general instruction would have a lens reference any bug it still perceives.
  const fresh = (await reviewOf(
    `${reviewedThrough}..${mutHead}`, 'review:mutation', [LENS.correctness], settled,
    `\nEach of those was fixed and the fix was verified, all of it before the ` +
    `commits you are reviewing. So set duplicate_of ONLY to report that these ` +
    `commits undid one of those fixes, and say in the evidence which line here ` +
    `does it. Doing so ends the run with no pull request, on the grounds that a ` +
    `verified fix was reverted. A defect you still perceive in code these ` +
    `commits do not touch is not a finding against this range: leave it out.`))
    .filter(f => {
      const dupe = duplicateTargetOf(f, settled)
      if (!dupe || dupe.byReference) return true
      log(`post-mutation review: dropped a re-report of [${dupe.hit.id}]`)
      return false
    })
  if (fresh.length) {
    return await halted('Review', {
      plan: plan.plan, implemented: impl.summary, mutation,
      unresolved_findings: fresh, fix_rounds: round,
      regression_suspects: regressionSuspects,
      note: `The mutation gate's own commits (${reviewedThrough}..${mutHead}) ` +
            `introduced ${fresh.length} finding(s). The fix rounds are spent, so ` +
            `no PR was opened. Judge each: fix it, or reject it as wrong.`,
    })
  }
  reviewedThrough = mutHead
} else if (mutHead) {
  reviewedThrough = mutHead
}

// Reaching here means every gate is green: the Gate, Fix and Mutation halts
// above are terminal, so there is no red state left to guard against.
let pr = null
if (args?.openPr !== false && !outOfBudget()) {
  phase('PR')
  const sPr = stage('pr')
  pr = await treeAgent(
    `Open a pull request for the work on this branch.\n` +
    (reviewerCount
      ? `FIRST, run git rev-list --count ${reviewedThrough}..HEAD. Every commit ` +
        `through ${reviewedThrough} has been adversarially reviewed. Compare as ` +
        `revisions like this, never by string-matching SHAs, which differ in ` +
        `abbreviation and would fail on an honest branch. If the count is not ` +
        `0, commits exist that no reviewer has read: return opened=false, name ` +
        `them with git log --oneline ${reviewedThrough}..HEAD, and do not push. ` +
        `Do not review them yourself and do not judge them harmless; you are ` +
        `the phase that opens PRs, not the one that vouches for them.\n`
      : '') +
    `Task: ${brief(task)}\nWhat was implemented: ${impl.summary}\n` +
    `Commit range: ${impl.commit_range}. Read that diff rather than relying on ` +
    `the summary above; a PR body that describes the diff is worth more than ` +
    `one that repeats a claim.\n` +
    `First look for a PR template: .github/pull_request_template.md, ` +
    `docs/pull_request_template.md, or any file under .github/PULL_REQUEST_TEMPLATE/. ` +
    `If one exists, fill in its sections and keep its structure; do not ` +
    `substitute your own. If none exists, write a short body: what changed, why, ` +
    `and how it was verified. Keep it tight; a few bullets, not an essay.\n` +
    `Verification means the repo's own tests and checks. The CRAP gate, mutation ` +
    `gate, this workflow, its reviewers and the fact that an agent wrote the ` +
    `change are local process: never mention them in the title, body or commits. ` +
    `A control the repo itself declares (its CI config, a documented pre-commit ` +
    `hook, CONTRIBUTING.md) is fair to reference once you have seen it in the ` +
    `repo.\n` +
    (baseOverride
      ? `This branch is stacked: open the PR with --base ${baseOverride}, not ` +
        `against the repo's default branch, and say in the body that it targets ` +
        `that branch and why. gh defaults to the default branch, which would ` +
        `show the parent's commits as this PR's own.\n`
      : '') +
    (draftPr?.number
      ? `A draft PR already exists for this branch: #${draftPr.number}. Do NOT ` +
        `open a second one. Push the branch, update that PR's title and body to ` +
        `describe the finished change, then mark it ready for review with ` +
        `gh pr ready ${draftPr.number}. Marking it ready is the last thing you ` +
        `do and the only thing that signals the work is finished; a PR left in ` +
        `draft reads as abandoned. Return its url with opened=true.\n`
      : `No draft PR exists for this branch, so push it and open the PR with ` +
        `gh. Return the PR url.\n`) +
    `Do not merge it.`,
    { label: 'pr', schema: PR, model: 'sonnet', effort: 'medium' })
  sPr.close()
  // Not in the PR body: the body describes the change, this is a note to its
  // reviewer. Unposted it lives only in a return value that dies with the run.
  if (pr?.opened && regressionSuspects.length) {
    const posted = await agent(
      `Post a comment on PR ${draftPr?.number ?? pr.url} in the current repo, ` +
      `then STOP. Use gh pr comment with --body-file - and the body on stdin, ` +
      `or --body. Do not edit the PR title or body, do not close it, do not ` +
      `push anything, and do not un-ready it.\n` +
      `The comment flags work a reviewer should check by hand. For each item ` +
      `below: a fix for it landed on this branch and was confirmed, then a ` +
      `later review of the same branch reported the same problem again. Nobody ` +
      `judged which reading is right, so ask the reviewer to confirm the fix ` +
      `holds. Be brief and concrete, quote the file, and do not speculate ` +
      `about the cause.\n` +
      `Do not name this workflow, its phases, its gates, its reviewers, or the ` +
      `fact that an agent wrote the change: none of it is actionable.\n` +
      renderSuspects(regressionSuspects),
      { label: 'regression-notice', model: 'haiku', effort: 'low' })
    log(posted
      ? `${regressionSuspects.length} regression suspect(s) reported on the PR`
      : `could not comment the ${regressionSuspects.length} regression ` +
        `suspect(s) on the PR; they are in this run's result only`)
  }
} else if (args?.openPr === false) {
  log('PR skipped: openPr=false; the branch is green and committed, PR is yours to open')
} else {
  log('PR skipped: out of token budget with every gate green; open the PR manually')
}

const result = {
  task,
  branch: wt.branch,
  base: wt.base,
  ticket: wt.ticket,
  worktree: wt.path,
  plan: plan.plan,
  stage_spend: stageSpend,
  implemented: impl.summary,
  gates: { green: true, detail: 'enforced by crap-commit-gate on every commit' },
  mutation,
  reviewers: reviewerCount,
  regression_suspects: regressionSuspects,
  reviewed_through: reviewedThrough,
  fix_rounds: round,
  unresolved_findings: open,
  pr,
  needs_user: args?.openPr !== false && !pr?.opened,
}
result.record_path = await recordRun(result)
return result
