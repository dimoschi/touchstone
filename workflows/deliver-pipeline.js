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
// Decided here, never by the branch agent. The two forms are mechanically
// distinct -- 216 against PROJ-4821 -- but asked to classify one, a model put
// GitHub issue 278 on a feat/jira-278-... branch. The marker is the run's only
// ticket link, so that files it under a tracker the ticket is not in.
const markerFor = (ref) => {
  const t = String(ref).trim().replace(/^#/, '')
  if (/^\d+$/.test(t)) return `gh-${t}`
  if (/^[A-Za-z][A-Za-z0-9]*-\d+$/.test(t)) return `jira-${t.toUpperCase()}`
  return null
}
const ticketMarker = markerFor(ticket)
if (!ticketMarker) {
  throw new Error(
    `deliver-pipeline: ticket "${ticket}" is neither a GitHub issue number ` +
    `(216, #216) nor a Jira key (PROJ-4821). Refusing rather than guessing: ` +
    `the branch marker is the only record of which tracker the work came from.`)
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
  // Two separate windows share this ceiling: discovery+baseline before
  // Implement, and the post-Implement run plus its one pre-review fix
  // round. stage_spend.checks sums both; each is bounded on its own.
  checks: 20_000,
  review: 80_000,
  // Carries the tail review of each fix round as well as the fixing itself.
  fix: 170_000,
  mutation: 150_000,
  pr: 30_000,
  ...(args?.stageBudgets ?? {}),
}
const stageSpend = {}
// Names the caller set by hand. Those keep their literal value: an explicit
// budget is a decision, and scaling it would silently overrule it.
const EXPLICIT_BUDGETS = new Set(Object.keys(args?.stageBudgets ?? {}))
// Applied to every ceiling of a stage created after Triage, so the sizing that
// already picks effort and lens count also picks how much the stage may spend.
// 1 until Triage has judged; the stages before it are cheap and fixed.
let ceilingScale = 1
const stage = (name) => {
  const start = budget.spent()
  const raw = CEILINGS[name]
  const cap = raw == null || EXPLICIT_BUDGETS.has(name)
    ? raw
    : Math.round(raw * ceilingScale)
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

// Opening the draft is allowed to fail without ending the run, so a note that
// states either outcome flatly is wrong half the time. Every halt note that
// mentions the PR reads this instead of asserting one.
const prNote = () => draftPr
  ? `The PR was left as a draft`
  : `No PR was opened, because the draft could not be opened earlier in this run`

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

// A halt is a result, not an absence of one, and the run record is where it
// survives the session. It used to be posted as a comment on the draft PR too.
// That put the run's internal state -- which phase stopped, which findings a
// lens raised -- on the repository's public record, where a reviewer cannot act
// on it and someone has to delete it by hand. Opening the PR is this workflow's
// only write to GitHub. Async because recordRun is, and every call site is
// `return await`.
const halted = async (at, extra) => {
  const payload = {
    task, halted_at: at, stage_spend: stageSpend, needs_user: true, ...extra,
  }
  if (draftPr?.number) {
    log(`halt at ${at}: draft PR ${draftPr.url} left as it is; the reason is in ` +
        `this run's result and record`)
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
  required: ['created', 'branch', 'base', 'path', 'detail', 'dirty'],
  properties: {
    created: { type: 'boolean' },
    branch: { type: 'string' },
    base: { type: 'string' },
    path: { type: 'string' },
    ticket: { type: 'string' },
    detail: { type: 'string' },
    dirty: { type: 'boolean' },
  },
}

// halt_reason lives here, not on BRANCH, so the default branch agent never
// sees a field its own prompt says nothing about. Required, because an
// omitted one reads as the plain not-found note, which is the note these
// halts exist to replace; 'none' keeps an absent key from being the signal.
const EXISTING_BRANCH = {
  ...BRANCH,
  required: [...BRANCH.required, 'halt_reason'],
  properties: {
    ...BRANCH.properties,
    halt_reason: { type: 'string', enum: ['none', 'ambiguous', 'wrong-ticket', 'merged', 'occupied'] },
  },
}

// Answers both the CRAP and mutation opt-in questions in one call: both
// markers live at the same repo root, and no phase of this run writes there,
// so timing cannot change either answer.
const MARKERS = {
  type: 'object', additionalProperties: false,
  required: ['crap_gated', 'mutation_gated', 'detail'],
  properties: {
    crap_gated: { type: 'boolean' },
    mutation_gated: { type: 'boolean' },
    detail: { type: 'string' },
  },
}

// Discovery source: AGENTS.md/CLAUDE.md's "## Commands" fence, not
// CONTRIBUTING.md's "## Tests" prose or .github/workflows/ci.yml -- the one
// list already written for an agent to run verbatim, with no CI-provider
// interpretation needed and no dependency on any CI existing at all.
const CHECKS = {
  type: 'object', additionalProperties: false, required: ['checks', 'detail'],
  properties: {
    checks: {
      type: 'array',
      items: {
        type: 'object', additionalProperties: false, required: ['name', 'command'],
        properties: { name: { type: 'string' }, command: { type: 'string' } },
      },
    },
    detail: { type: 'string' },
  },
}
// One row per command, run exactly as discovered. exit_code and output are
// what the fix phase is handed verbatim -- never a model's account of them.
// Redness is keyed on exit_code alone, never on a model-judged boolean: exit
// 2 and exit 4 are not passes either, and asking for a "passed" field let a
// haiku call one of those green.
const CHECK_RUN = {
  type: 'object', additionalProperties: false, required: ['results', 'dirty'],
  properties: {
    results: {
      type: 'array',
      items: {
        type: 'object', additionalProperties: false,
        required: ['name', 'command', 'exit_code', 'output'],
        properties: {
          name: { type: 'string' }, command: { type: 'string' },
          exit_code: { type: 'integer' }, output: { type: 'string' },
        },
      },
    },
    dirty: { type: 'boolean' },
    porcelain: { type: 'string' },
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
  required: ['summary', 'files_changed', 'commit_range', 'insertions', 'scored'],
  properties: {
    summary: { type: 'string' },
    files_changed: { type: 'array', items: { type: 'string' } },
    commit_range: { type: 'string' },
    insertions: { type: 'integer' },
    scored: { type: 'boolean' },
    gate_note: { type: 'string' },
    // Set when the one halt this phase can hit -- a NEXT_ACTION of
    // UNSUPPORTED_LANGUAGE -- fires. Without a schema field for it, the phase
    // has no way to represent a halt at all: it would return a normal result
    // and the run would sail on through Draft PR, Review, Fix and Mutation
    // with the refused work never committed.
    unsupported_language: { type: 'boolean' },
  },
}
// head_sha is required, not optional: it is how the script learns what this
// phase committed, and an absent one is indistinguishable from "committed
// nothing" -- which is exactly the case that must not silently skip review.
const GATE = {
  type: 'object', additionalProperties: false,
  required: ['green', 'head_sha', 'detail', 'scored'],
  properties: {
    green: { type: 'boolean' }, head_sha: { type: 'string' },
    detail: { type: 'string' },
    needs_user_run: { type: 'boolean' },
    scored: { type: 'boolean' }, gate_note: { type: 'string' },
    // Same halt escape IMPL carries: set when a NEXT_ACTION of
    // UNSUPPORTED_LANGUAGE fires mid-mutation, so the phase has a field to
    // report it on rather than burning every remaining attempt on a gate that
    // cannot run.
    unsupported_language: { type: 'boolean' },
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
          // Optional: a deletion or a repo-wide pattern has no single span,
          // and schema validation must not fail a lens over that.
          line_start: { type: 'integer' }, line_end: { type: 'integer' },
          // An id copied from reviewOf's `known` list, never invented. Each
          // call site states what a reference there means.
          duplicate_of: { type: 'string' },
        },
      },
    },
  },
}
// One group per real defect, each listing the ids that describe it. Ids only:
// the grouping is a model judgement, but the join back is the script's.
const DUPES = {
  type: 'object', additionalProperties: false, required: ['groups'],
  properties: {
    groups: {
      type: 'array',
      items: {
        type: 'object', additionalProperties: false,
        required: ['ids', 'why'],
        properties: {
          ids: { type: 'array', items: { type: 'string' } },
          why: { type: 'string' },
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
        required: ['id', 'fixed', 'widened', 'note'],
        properties: {
          id: { type: 'string' },
          // Ignored for matching. Present only so a verifier that still echoes
          // a finding's title cannot fail schema validation over it.
          title: { type: 'string' },
          fixed: { type: 'boolean' },
          // Prose says why; this says whether, and only this survives the
          // boundary below. Visibility, not enforcement: a verifier that
          // widens and reports false is no more detectable than before.
          widened: { type: 'boolean' },
          note: { type: 'string' },
        },
      },
    },
  },
}
// A fix round is a code change like any other, so the script has to know where
// it landed to hand the next reviewer a range.
const FIXED = {
  type: 'object', additionalProperties: false, required: ['head_sha', 'note', 'scored'],
  properties: {
    head_sha: { type: 'string' }, note: { type: 'string' },
    scored: { type: 'boolean' }, gate_note: { type: 'string' },
    // Same halt escape IMPL carries: without it a fixer that hits
    // UNSUPPORTED_LANGUAGE has no field to report the halt on, so the run
    // reads a normal result and sails on into Mutation with the refused work
    // uncommitted.
    unsupported_language: { type: 'boolean' },
  },
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
      `Find the worktree that already holds this ticket's branch, then STOP. Do ` +
      `not create a branch, do not fetch, do not pull, do not plan or ` +
      `implement. The one exception is step 5: re-attaching a worktree to a ` +
      `branch that already exists is not creating one.\n` +
      `This task continues work on an existing branch for ticket ${ticket}.\n` +
      `Two fields matter on every response below, halts included: dirty is ` +
      `true only for step 7's dirty-checkout halt, false in every other ` +
      `response; halt_reason is "ambiguous" for the two-or-more-matches halts ` +
      `in steps 4 and 5, "merged" for step 4 or 5's already-merged-PR halt, ` +
      `"occupied" for step 5's occupied-directory halt, "wrong-ticket" for ` +
      `the different-ticket halt in step 6, and "none" in every other ` +
      `response, including every success. Never omit it.\n` +
      `1. Run git worktree prune. It only removes registrations for worktree ` +
      `directories that no longer exist on disk; it never touches a directory ` +
      `that does exist. Run it before listing worktrees so a stale record left ` +
      `behind by a hand-deleted directory cannot be matched below.\n` +
      `2. Find the repo root: dirname "$(git rev-parse --path-format=absolute ` +
      `--git-common-dir)". Do not use git rev-parse --show-toplevel for this: ` +
      `the invoking session usually runs inside another worktree, and ` +
      `--show-toplevel would return that one, not the repo.\n` +
      `3. Run git worktree list --porcelain. It prints one record per worktree: ` +
      `a "worktree <path>" line followed by a "branch refs/heads/<name>" line ` +
      `(or "detached"/"bare").\n` +
      `4. Ticket lookup, tried first regardless of what the invoking checkout is ` +
      `on: the base branch, another feature branch, or detached HEAD are all ` +
      `fine here, because the branch this task needs lives in its own worktree, ` +
      `not necessarily in whichever tree happens to be checked out right now. ` +
      `Find every record whose branch, after its first "/", begins with ` +
      `"${ticketMarker}-" -- that is <type>/${ticketMarker}-<slug>, the exact ` +
      `shape a fresh run of this workflow cuts. Match on that marker segment, ` +
      `never on this task's own branch-type prefix: a branch cut as ` +
      `feat/${ticketMarker}-x must still be found here even if this run asks ` +
      `for a different type. Its canonical directory is ` +
      `<repo-root>/.claude/worktrees/${ticketMarker}-<slug>, the expected ` +
      `location, but the record's own path wins if it differs: the branch lives ` +
      `where git says it lives, not where convention says it should.\n` +
      `   - Exactly one match: before reusing it, run gh pr view <branch> ` +
      `--json state -q .state, using the matched branch's own name. This ` +
      `workflow never removes a worktree once it creates one, so a leftover ` +
      `worktree here is no signal by itself that the branch is still live. If ` +
      `that reports MERGED, the ticket's work already shipped on that ` +
      `branch; return created=false, halt_reason=merged, naming the branch ` +
      `and that its PR merged. Do not commit into that tree: a merged branch ` +
      `is done, not a tree to keep implementing into. If gh reports any ` +
      `other state (OPEN, CLOSED), no PR at all, or the call itself fails ` +
      `(no network, no auth), treat the branch as still live and go to step ` +
      `7.\n` +
      `   - Two or more matches: return created=false, halt_reason=ambiguous, ` +
      `listing every matching branch and its path in detail. Do not guess ` +
      `which one this task means.\n` +
      `5. Only if step 4 matched nothing: a branch can carry the ` +
      `${ticketMarker} marker with no worktree of its own. git worktree ` +
      `prune (step 1) drops a worktree's registration once its directory is ` +
      `gone, but never the branch itself. The most common way that happens ` +
      `is the opposite of abandonment: the PR merged and the worktree was ` +
      `cleaned up because the work was done, not because it was cut loose ` +
      `mid-flight. Run git branch --list "*/${ticketMarker}-*" to check for ` +
      `one.\n` +
      `   - Exactly one match: before touching it, run gh pr view <branch> ` +
      `--json state -q .state, using the matched branch's own name, not ` +
      `whatever is checked out here. If that reports MERGED, the ticket's ` +
      `work already shipped on that branch; return created=false, ` +
      `halt_reason=merged, naming the branch and that its PR merged. Do not ` +
      `re-attach a worktree to it and do not run any further step on it: a ` +
      `merged branch is done, not a tree to keep implementing into. If gh ` +
      `reports any other state (OPEN, CLOSED), no PR at all, or the call ` +
      `itself fails (no network, no auth), treat the branch as still live ` +
      `and re-attach a worktree to it rather than losing it. Its canonical ` +
      `directory is <repo-root>/.claude/worktrees/${ticketMarker}-<slug>; if ` +
      `that path is already occupied by something else, return ` +
      `created=false, halt_reason=occupied, naming the path and what is ` +
      `there. Otherwise run git worktree add <path> <branch> -- no -b, the ` +
      `branch already exists; a branch cannot be created twice, and this ` +
      `step never creates one. Do not fetch or pull. Go to step 7.\n` +
      `   - Two or more matches: return created=false, halt_reason=ambiguous, ` +
      `listing every matching branch, same as step 4.\n` +
      `   - No match: go to step 6.\n` +
      `6. Only if steps 4 and 5 matched nothing: fall back to whatever is ` +
      `actually checked out here (git branch --show-current). If HEAD is ` +
      `detached, or the current branch is the repo's base branch (main, ` +
      `master, or whatever origin/HEAD names), return created=false saying no ` +
      `worktree or branch for ${ticketMarker} was found and the current ` +
      `checkout is not on a feature branch either. If that branch carries a ` +
      `jira- or gh- marker other than ${ticketMarker}, refuse it too: return ` +
      `created=false, halt_reason=wrong-ticket, and say in detail which other ` +
      `ticket it belongs to. The invoking session usually runs inside another ` +
      `worktree, so this is reachable, and committing this task's work onto ` +
      `another ticket's branch is worse than halting. Otherwise take the git ` +
      `worktree list --porcelain record for that branch (every checked-out ` +
      `branch has one) and use its path. An unmarked pre-existing branch is ` +
      `allowed here and is not a failure: it predates the convention.\n` +
      `7. This mode commits into the tree holding the branch, and a later phase ` +
      `runs git add -A there, so unrelated dirty files sitting in that tree ` +
      `would be swept into a commit. Check git -C <path> status --porcelain, ` +
      `using the matched or re-attached path from step 4, 5, or 6, whether ` +
      `that is the main checkout or a linked worktree; the risk is the same ` +
      `either way. If it is non-empty, return created=false, dirty=true, and ` +
      `say what is dirty. Never stash, reset, or discard the user's work.\n` +
      `8. Otherwise return created=true, branch set to the matched record's own ` +
      `branch name (never git branch --show-current, which names the invoking ` +
      `checkout and not necessarily this ticket's branch), base set to the ` +
      `repo's base branch, and path set to the absolute path from the matching ` +
      `record. Note in detail whether the match came from the ticket lookup ` +
      `(step 4), the worktree-less branch (step 5), or the fallback (step 6), ` +
      `whether that path is the main checkout or a linked worktree, and ` +
      `whether the branch name carries a jira- or gh- marker.` +
      RECORD('branch:existing'),
      { label: 'branch:existing', schema: EXISTING_BRANCH, model: 'haiku', effort: 'low' })
  // A worktree is a separate checkout, so the main tree's state is irrelevant
  // to it; cutting from origin/<base> is what removes the need to touch the
  // main checkout at all.
  : await agent(
  `[touchstone: branch]\n` +
  `Create the working branch and a git worktree for it, then STOP. Do not ` +
  `plan, implement, or commit any code.\n` +
  `Task: ${brief(task)}\n` +
  `Ticket: ${ticket}\n` +
  `Branch type prefix: ${args?.branchType ?? 'feat'}\n` +
  `One field matters on every response below, halts included: dirty is true ` +
  `only for step 6's dirty-checkout halt, false in every other response.\n` +
  `1. Run git worktree prune. It only removes registrations for worktree ` +
  `directories that no longer exist on disk, never a directory that does ` +
  `exist, so it is safe to run unconditionally; it clears the way for ` +
  `re-adding a worktree whose directory was deleted by hand.\n` +
  `2. Find the repo root: dirname "$(git rev-parse --path-format=absolute ` +
  `--git-common-dir)". Do not use git rev-parse --show-toplevel for this.\n` +
  (baseOverride
    ? `3. The base for this branch is given: ${baseOverride}. Do not read the ` +
      `remote HEAD and do not substitute main or master; this work is stacked ` +
      `on that branch deliberately. Verify the ref resolves ` +
      `(git rev-parse --verify ${baseOverride}) and return created=false naming ` +
      `it if it does not.\n`
    : `3. Find this repo's base branch: read the remote HEAD ` +
      `(git symbolic-ref --short refs/remotes/origin/HEAD), which prints an ` +
      `origin/-prefixed name; strip that prefix so the base is the bare ` +
      `branch name (main, not origin/main), falling back to whichever of ` +
      `main or master exists when there is no remote-tracking HEAD. Do not ` +
      `assume main.\n`) +
  `4. Name the branch exactly ` +
  `${args?.branchType ?? 'feat'}/${ticketMarker}-<slug>. The prefix is given ` +
  `in full, already resolved against the ticket: use it character for ` +
  `character and do not re-derive it, abbreviate it, or swap jira- for gh- or ` +
  `back. Supply only <slug>, from the task: lowercase, hyphen-separated, at ` +
  `most 6 words, no trailing hyphen.\n` +
  `5. The worktree path is ` +
  `<repo-root>/.claude/worktrees/${ticketMarker}-<slug>, the branch name with ` +
  `its ${args?.branchType ?? 'feat'}/ prefix stripped.\n` +
  `6. Run git worktree list --porcelain and look for a record whose "branch ` +
  `refs/heads/<name>" line matches the branch name from step 4. If one ` +
  `exists, the branch is already checked out somewhere; git refuses to check ` +
  `it out twice, so that record's own path (even if it differs from the ` +
  `path in step 5) is what this task must reuse. This mode commits into ` +
  `that tree, and a later phase runs git add -A there, so check git -C ` +
  `<that path> status --porcelain: if it is non-empty, return created=false, ` +
  `dirty=true, and say what is dirty. Never stash, reset, or discard the ` +
  `user's work. Otherwise return created=true using that path, note in ` +
  `detail that the branch was reused rather than created, and stop: do not ` +
  `fetch, pull, or run any worktree add.\n` +
  `7. Otherwise check whether the branch exists at all (git show-ref --verify ` +
  `--quiet refs/heads/<name>). If it does, the fetch and cut in step 10 are ` +
  `not needed; go straight to step 8.\n` +
  `8. Check whether the path from step 5 already exists on disk. If it does, ` +
  `return created=false naming the exact path and explaining what is there. ` +
  `Do not delete it, do not rename around it, and do not pick a different ` +
  `slug: a surprising second worktree is worse than a clear halt.\n` +
  `9. If the branch exists (step 7) and the path is clear (step 8), run ` +
  `git worktree add <path> <branch>, without -b since the branch already ` +
  `exists; a branch cannot be created twice. Note in detail that the branch ` +
  `was reused rather than created, and set base to ` +
  (baseOverride ? `${baseOverride}.\n` : `the repo's base branch.\n`) +
  (baseOverride
    ? `10. If the branch does not exist, run ` +
      `git worktree add <path> -b <branch> ${baseOverride} directly. Do not ` +
      `fetch, do not check out the base, and do not pull or rebase it: it is a ` +
      `branch under review whose head the user chose, and it may itself be ` +
      `checked out in another worktree, where checking it out again would fail.\n`
    : `10. If the branch does not exist, run git fetch origin, then resolve ` +
      `the cut point with git rev-parse --verify origin/<base>. If the fetch ` +
      `fails or that ref does not resolve, return created=false naming the ` +
      `base and the reason, rather than falling back to the local branch. ` +
      `Otherwise run git worktree add <path> -b <branch> origin/<base>. Do ` +
      `not check out the base branch, do not run git pull, and do not modify ` +
      `the main checkout's working tree in any way: the worktree is a ` +
      `separate checkout, cut straight from the fetched remote ref.\n`) +
  `Do not check out the new branch in this working tree; the worktree is a ` +
  `separate checkout.\n` +
  `Return the branch you created or reused, the base you cut it from (or ` +
  (baseOverride ? `${baseOverride}` : `the repo's base branch`) +
  ` if the branch already existed), and the absolute worktree path.` +
  RECORD('branch'),
  { label: 'branch', schema: BRANCH, model: 'haiku', effort: 'low' })
sBranch.close()

// A failed worktree step halts rather than falling through: implementing onto
// whatever tree happened to be checked out is how unrelated work lands in a PR.
if (!wt?.created) {
  return await halted('Worktree', {
    branch: wt?.branch,
    base: wt?.base,
    detail: wt?.detail,
    // wt.dirty names the actual cause regardless of mode: both the default
    // reuse path (step 6) and the existingBranch guard (step 7) halt here for
    // the same reason, an uncommitted checkout, and re-running with
    // existingBranch: true would only hit that same existingBranch guard.
    // wt.halt_reason distinguishes the existingBranch prompt's other halts,
    // which need their own notes rather than falling into the plain
    // not-found one below: an ambiguous marker match, a fallback branch
    // marked for a different ticket, a matched branch whose PR already
    // merged, or a matched branch's canonical directory already occupied.
    // None of the four is safe to answer with "cut a new branch" -- an
    // ambiguous match already has too many candidates, a wrong-ticket match
    // means this ticket's own branch or worktree is still missing rather
    // than nothing existing to reuse, a merged match means the ticket's
    // branch already exists and shipped, and an occupied match means the
    // ticket's branch already exists and only its directory is blocked.
    note: wt?.dirty
      ? 'The checkout that holds this branch has uncommitted changes, so ' +
        'nothing was planned or implemented. Commit or stash them, then ' +
        're-run.'
      : wt?.halt_reason === 'ambiguous'
      ? `Found more than one branch carrying the ${ticketMarker} marker, so ` +
        `nothing was planned or implemented: ${wt?.detail}. This lookup ` +
        `cannot tell which one the task means; delete or rename the branch ` +
        `this ticket does not need, then re-run with existingBranch: true.`
      : wt?.halt_reason === 'wrong-ticket'
      ? `The only checked-out branch belongs to a different ticket, so ` +
        `nothing was planned or implemented: ${wt?.detail}. No branch or ` +
        `worktree for ${ticketMarker} exists yet. Re-run without ` +
        `existingBranch to cut one.`
      : wt?.halt_reason === 'merged'
      ? `The only branch carrying the ${ticketMarker} marker already has a ` +
        `merged pull request, so nothing was planned or implemented: ` +
        `${wt?.detail}. That work already shipped. Re-running without ` +
        `existingBranch is not a reliable escape: that path names the branch ` +
        `<type>/${ticketMarker}-<slug> from this run's own type and a slug ` +
        `it re-derives from the task, and only the name decides what ` +
        `happens. Land on this same name and it reuses the merged branch, ` +
        `so the new commits push onto its closed pull request; land on a ` +
        `different one and it either cuts a fresh branch or halts on the ` +
        `worktree directory this branch already holds. Do not rely on ` +
        `which. Remove that worktree and delete the branch first, or track ` +
        `the new work under a ticket of its own.`
      : wt?.halt_reason === 'occupied'
      ? `A branch carrying the ${ticketMarker} marker was found with no ` +
        `worktree of its own, but its canonical worktree directory is ` +
        `occupied, so nothing was planned or implemented: ${wt?.detail}. ` +
        `Clear or rename what is occupying that path, then re-run with ` +
        `existingBranch: true; re-running without existingBranch either ` +
        `halts on this same occupied path or, if it re-derives a different ` +
        `slug, cuts a duplicate branch for a ticket that already has one.`
      : args?.existingBranch
      ? `No worktree or branch carrying the ${ticketMarker}-<slug> marker ` +
        `was found (any branch type, e.g. under ` +
        `.claude/worktrees/${ticketMarker}-<slug>), and the current ` +
        `checkout is not on a branch for this ticket either. Re-run without ` +
        `existingBranch to cut one, or pass existingBranch: true again once ` +
        `a branch or worktree for this ticket exists.`
      : 'No worktree was created, so nothing was planned or implemented. ' +
        'Resolve the base branch problem in detail, then re-run. If fetch ' +
        'cannot run here (a remote needing a hardware key, for example), ' +
        'fetch the base branch manually first, or pass existingBranch: true ' +
        'if this work belongs on a branch that already exists.',
  })
}
// Bare unconditionally: neither gh pr create --base nor the merge-base rule
// below can take an origin/-qualified name.
wt.base = (baseOverride || wt.base).replace(/^origin\//, '')
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
    `repo's. crap-commit.sh, crap-check.sh, mutation-check.sh and ` +
    `deadcode-check.sh all take this worktree path as an optional leading ` +
    `argument (crap-commit.sh already required it; the other three now accept ` +
    `it too) and print the repo and branch they resolved as their first line ` +
    `of output -- read that line and pass ${wt.path} there, every time, rather ` +
    `than relying on cwd. GIT_DIR/GIT_WORK_TREE env vars and cd are not the way ` +
    `to target it. Any reproduction or experiment -- a scratch clone, a throwaway ` +
    `git repo to test a git behaviour, anything you would otherwise drop in /tmp ` +
    `-- goes under ${wt.path}/.claude/scratch/ instead, never /tmp. Before creating ` +
    `anything under it, confirm that path is excluded from git: run ` +
    `git -C ${wt.path} check-ignore -q ${wt.path}/.claude/scratch, and if that ` +
    `fails, append that path to the file printed by ` +
    `git -C ${wt.path} rev-parse --git-path info/exclude. Never add the entry to ` +
    `.gitignore itself: that file is tracked, so editing it leaves the worktree ` +
    `dirty for every phase that runs before Implement's baseline dirty-tree check, ` +
    `which would then blame a discovered check for dirt this instruction caused. ` +
    `info/exclude is never committed, so excluding the path there can never dirty ` +
    `the tree that check reads. Git resolves identity and signing config by ` +
    `directory, so a repo created outside the workspace inherits whatever the ` +
    `global config says, which can mean signing with the wrong identity or ` +
    `blocking on a hardware key no agent can satisfy. A scratch git repo is ` +
    `therefore always created with signing off and an explicit test identity: ` +
    `git init -q, then commit with ` +
    `GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=test ` +
    `GIT_COMMITTER_EMAIL=t@t git -c commit.gpgsign=false -c gpg.format=openpgp ` +
    `commit.\n\n` +
    envelope() + `\n` + prompt + RECORD(opts.label),
    opts)

const headOf = (range) => range.includes('..') ? range.split('..')[1].trim() : range.trim()

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
// Ceilings scale with the same judgement as effort. A trivial change used to
// get a trivial effort setting and the full 80k review ceiling, which is not a
// budget so much as permission to keep going.
const CEILING_SCALE = { trivial: 0.4, routine: 1, involved: 1.5 }
const complexity = EFFORT[triage.complexity] ? triage.complexity : 'involved'
const effortFor = EFFORT[complexity]
ceilingScale = CEILING_SCALE[complexity]
if (triage.complexity && complexity !== triage.complexity) {
  log(`triage returned an unrecognised complexity (${triage.complexity}); ` +
      `treating it as involved, which spends the most rather than the least`)
}
log(`triage judged this ${complexity}` +
    (triage.complexity_note ? `: ${triage.complexity_note}` : '') +
    ` -- plan/implement/review/verify effort ` +
    `${effortFor.plan}/${effortFor.implement}/${effortFor.review}/${effortFor.verify}` +
    `, ceilings x${ceilingScale}` +
    (EXPLICIT_BUDGETS.size
      ? ` (${[...EXPLICIT_BUDGETS].join(', ')} left at the value you passed)`
      : ''))
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

// The Fix, Mutation and final-result payloads below all report a `gates`
// field, and the Mutation phase further down needs the mutation opt-in
// marker. One probe answers both here, before either marker is needed.
//
// crap-commit-gate.py's PreToolUse hook only blocks a raw `git commit` when
// .crap-gated exists at the repo root; crap-commit.sh itself runs the CRAP
// and dead-code gates on every commit it makes regardless of that marker. So
// the marker answers one question only -- could a raw commit have bypassed
// the wrapper -- not whether the gates ran, and `gates` below reports both
// separately rather than folding them into one "enforced" claim.
//
// The two markers take opposite fail-safe defaults on an unconfirmed answer.
// Mutation: unknown counts as gated, which only costs an extra mutation run.
// CRAP: unknown must NOT count as gated, because that would assert a raw
// commit could not have bypassed the wrapper when nobody confirmed the
// marker is there -- the false assertion this ticket exists to remove. So
// crap_gated counts only a confirmed `true`; everything else, including a
// probe that returned nothing, is reported as unconfirmed.
const sGate = stage('gate')
const gateProbe = await treeAgent(
  `[touchstone: gate opt-in]\n` +
  `Report whether this repo opts into CRAP-gated commits and into mutation ` +
  `gating, then STOP. Run no tests, no gate tooling, and change nothing.\n` +
  `1. Find the repo root: dirname "$(git rev-parse --path-format=absolute ` +
  `--git-common-dir)".\n` +
  `2. Test for a file named exactly .crap-gated at that root, and separately ` +
  `for one named exactly .mutation-gated.\n` +
  `3. Return crap_gated=true only if .crap-gated is there; crap_gated=false ` +
  `otherwise, whether it is confirmed absent or you could not tell -- an ` +
  `unconfirmed CRAP marker must never be reported as gated. Return ` +
  `mutation_gated=true if .mutation-gated is there or you could not ` +
  `determine either way, mutation_gated=false only if you confirmed it is ` +
  `absent -- an unconfirmed mutation marker should still run the gate, which ` +
  `only costs a run rather than dropping a real one.\n` +
  `Report the paths you checked in detail.`,
  { label: 'gate:opt-in', schema: MARKERS, model: 'haiku', effort: 'low' })
sGate.close()

const crapGated = gateProbe?.crap_gated === true
const mutationGated = gateProbe?.mutation_gated !== false
if (!gateProbe) {
  log(`gate opt-in probe returned nothing; treating CRAP gating as ` +
      `unconfirmed (reported as not hook-enforced) and mutation gating as ` +
      `opted-in (safe default: costs an extra run rather than dropping a real gate)`)
}

const sChecksPre = stage('checks')
phase('Implement')
const discovery = await treeAgent(
  `[touchstone: checks:discover]\n` +
  `Find the deterministic checks this repo advertises for its own ` +
  `contributors, then STOP. Read only; run nothing and change nothing.\n` +
  `1. Find the repo root: dirname "$(git rev-parse --path-format=absolute ` +
  `--git-common-dir)".\n` +
  `2. Read AGENTS.md at that root; if it does not exist, read CLAUDE.md ` +
  `instead (it is conventionally a symlink to AGENTS.md).\n` +
  `3. Find a "## Commands" heading (case-insensitive) followed by a fenced ` +
  `code block. If neither file exists, or no such section is found, return ` +
  `checks=[] and say why in detail.\n` +
  `4. Otherwise return one entry per non-blank line inside that fence, in ` +
  `the file's own order: name is the line's own script (its basename, e.g. ` +
  `run-tests.sh), command is the full line with any trailing "#" comment ` +
  `stripped. Do not add a check that is not literally a line there, and do ` +
  `not drop one for looking slow or environment-specific -- that judgement ` +
  `is the repo's, made by what it chose to list.`,
  { label: 'checks:discover', schema: CHECKS, model: 'haiku', effort: 'low' })
let discoveredChecks = discovery?.checks ?? []
log(discoveredChecks.length
  ? `checks discovered: ${discoveredChecks.map(c => c.name).join(', ')}`
  : `no repo-advertised checks found (${discovery?.detail ?? 'discovery returned nothing'}); nothing to run alongside review`)

// existingBranch resumes a branch that may already carry commits of its own,
// so there is no clean base tree here to tell an environmental failure from
// a real one. Checks still run and are still reported below, but never
// block: after #87 resuming is the normal path, not an edge case.
const checksBlocking = !args?.existingBranch
let checkAttempt = 0
const executeChecks = async () => {
  checkAttempt++
  return await treeAgent(
    `[touchstone: checks:run]\n` +
    `Run each command below, then STOP. Do not fix, edit, or investigate a ` +
    `failure; a later phase does that.\n` +
    `This one call is the exception to the rule above about never running ` +
    `cd, and only in the bash -c form: run each command as ` +
    `bash -c 'cd ${wt.path} && <command>'. Never a bare ` +
    `cd ${wt.path} && <command>, which does move this session. A ` +
    `subshell does not move this session's own working directory, and cd ` +
    `inside it is what makes a command written relative to the repo root ` +
    `(as every discovered command is) mean this worktree rather than ` +
    `wherever the session's own cwd happens to be.\n` +
    `Report each command's exit code and its combined stdout and stderr ` +
    `verbatim -- do not summarise, truncate, or interpret what it printed.\n` +
    `Then run git -C ${wt.path} status --porcelain and report whether it ` +
    `printed anything (dirty) and, if so, its output (porcelain): a check ` +
    `that writes to the tree (a ledger, a generated file) must be visible, ` +
    `not silently carried into whatever commits next.\n` +
    discoveredChecks.map(c => `${c.name}: ${c.command}`).join('\n'),
    { label: `checks:run:${checkAttempt}`, schema: CHECK_RUN, model: 'haiku', effort: 'low' })
}
const CHECK_HEAD_BYTES = 1024
const CHECK_TAIL_BYTES = 8192
// A cap stated only in a prompt is a request; a slice is a bound. Head and
// tail both, since a gate prints the repo and branch it resolved first and
// its verdict last.
const truncateOutput = (s) => {
  const t = String(s ?? '')
  if (t.length <= CHECK_HEAD_BYTES + CHECK_TAIL_BYTES) return t
  const omitted = t.length - CHECK_HEAD_BYTES - CHECK_TAIL_BYTES
  return t.slice(0, CHECK_HEAD_BYTES) +
    `\n[touchstone: truncated, ${omitted} bytes omitted]\n` +
    t.slice(t.length - CHECK_TAIL_BYTES)
}
const toRedList = (results) => (Array.isArray(results) ? results : [])
  .filter(r => r?.exit_code !== 0)
  .map(r => ({ id: `check:${r.name}`, name: r.name, command: r.command,
               exit_code: r.exit_code, output: truncateOutput(r.output) }))
// A check nobody reported on is unknown, and unknown is red. Reading a
// missing row as a pass would put the verdict back in the shape of the
// model's answer, which is the thing this phase exists to take it out of.
// The baseline does not come through here: an unreported row there is left
// in place rather than dropped, since a missing answer is no evidence that a
// check is environmental.
const runChecks = async () => {
  if (!discoveredChecks.length) return []
  const outcome = await executeChecks()
  const reported = new Set((Array.isArray(outcome?.results) ? outcome.results : [])
    .map(r => r?.name))
  const unreported = discoveredChecks.filter(c => !reported.has(c.name))
    .map(c => ({ id: `check:${c.name}`, name: c.name, command: c.command,
                 exit_code: null, output: 'no result was reported for this check' }))
  return [...toRedList(outcome?.results), ...unreported]
}

const renderCheck = (c) => `Check ${c.name} (${c.command}) exited ${c.exit_code}:\n${c.output}`

// A check red before any work started is the repo's own environment, not
// this run's doing, and there is no way to tell the two apart other than
// measuring the base commit itself. Dropped, not merely downgraded, so it
// can never re-enter a fixer prompt later.
let droppedAtBaseline = []
if (discoveredChecks.length && checksBlocking) {
  const baseline = await executeChecks()
  if (baseline?.dirty) {
    sChecksPre.close()
    return await halted('Implement', {
      checks: { discovered: discoveredChecks.length, blocking: checksBlocking, red: [],
        detail: 'halted before any check ran against real implementation work' },
      note: `A discovered check wrote to the working tree while establishing ` +
        `the environmental baseline, before any implementation ran: ` +
        `${baseline.porcelain || '(no detail returned)'}. Nothing was planned ` +
        `or implemented. Find which check writes, then re-run.`,
    })
  }
  const baseRed = toRedList(baseline?.results)
  if (baseRed.length) {
    const redNames = new Set(baseRed.map(c => c.name))
    droppedAtBaseline = baseRed
    discoveredChecks = discoveredChecks.filter(c => !redNames.has(c.name))
    log(`checks: dropped ${droppedAtBaseline.length} as environmental (red ` +
        `before any work started): ${droppedAtBaseline.map(c => c.name).join(', ')}`)
  }
} else if (discoveredChecks.length) {
  log(`checks: existingBranch has no clean base tree to classify against; ` +
      `the ${discoveredChecks.length} discovered check(s) are reported but ` +
      `never block this run`)
}
sChecksPre.close()
const checksPreSpend = stageSpend.checks ?? 0

function checksPayload() {
  return {
    discovered: discoveredChecks.length,
    blocking: checksBlocking,
    red: redChecks,
    detail: (checksBlocking
      ? (droppedAtBaseline.length
          ? `dropped ${droppedAtBaseline.length} as environmental at the base ` +
            `commit: ${droppedAtBaseline.map(c => c.name).join(', ')}. `
          : '')
      : `advisory only: existingBranch has no clean base tree to classify ` +
        `checks against, so a red one here is reported but never blocks. `
    ) + (discovery?.detail ?? ''),
  }
}
// Red but not blocking (existingBranch) reaches the fixer as nothing at
// all: it is visibility for a human, not work to hand to an agent.
let preReviewFixCommitted = false
const blockingChecksOpen = () => checksBlocking && redChecks.length > 0

const sImpl = stage('implement')
const impl = await treeAgent(
  `Implement this task in the current repo.\n` +
  `Task: ${brief(task)}\nPlan: ${brief(plan.plan)}\n` +
  (plan.acceptance_criteria.length
    ? `Acceptance criteria:\n- ${plan.acceptance_criteria.join('\n- ')}\n`
    : `Acceptance criteria: none were supplied with this plan. Derive them from ` +
      `it before you write anything, and state them in your summary.\n`) +
  `Follow the crap-controlled-changes skill: TDD first, iterating with the ` +
  `repo's own test command. Commit with crap-commit.sh ${wt.path} -m "...", ` +
  `which runs the gate itself and refuses if it is red; do not run ` +
  `crap-check.sh first, since that doubles a check that already runs the ` +
  `suite twice, and do not use either as your test loop. Run it in the ` +
  `foreground with a Bash timeout of 600000; never background it and wait ` +
  `with sleep. Follow its NEXT_ACTION until green. Commit signed, in as many ` +
  `commits as the work naturally takes. Never run ` +
  `--accept or --mark-scored yourself; both need explicit user approval. ` +
  `Never create, edit or delete .crap-gated, .mutation-gated or ` +
  `.comment-gated on your own initiative: whether a repo is gated (and by ` +
  `which policy) is the repo owner's decision, not yours, and a repo ` +
  `without any of them is simply not gated -- say so and continue. The ` +
  `one exception is a NEXT_ACTION of UNSUPPORTED_LANGUAGE: halt ` +
  `and report its three options to the user rather than picking one and ` +
  `editing the marker yourself. Set unsupported_language=true when you do, ` +
  `and put the three options in summary; leave commit_range as the unchanged ` +
  `base if you made no commits before hitting it. ` +
  `Do not push and do not open a PR: those are the user's to authorise.\n` +
  `Return scored=true if crap-commit.sh printed that it scored the change ` +
  `(ran the CRAP and dead-code checks on your commits), scored=false if you ` +
  `made no commits or it printed nothing to score. Base this on what it ` +
  `printed, never on whether .crap-gated exists and never on your own ` +
  `judgement of the change. If it printed its own gate message, copy it ` +
  `verbatim into gate_note.\n` +
  `Return commit_range as '<base-sha>..<head-sha>', both as full 40-character ` +
  `SHAs, using your final HEAD and a base you work out yourself: find the ` +
  `merge base of HEAD with ${wt.base} and with origin/${wt.base}. If only ` +
  `one of those refs resolves, use its merge base. If both resolve, use ` +
  `whichever of the two merge-base commits is a descendant of the other ` +
  `(git merge-base --is-ancestor); if neither is, use the one from ` +
  `origin/${wt.base} -- the gates resolve their own diff base as origin/HEAD ` +
  `first, and this keeps the reviewed range aligned with the measured one. ` +
  `Later phases compare their own HEAD against the head of this range to ` +
  `work out what is still unreviewed, and an abbreviated SHA never matches. ` +
  `Downstream phases are given that range and read the diff themselves, so ` +
  `it is how your work is handed on: a summary of it is not, and will not ` +
  `be forwarded.`,
  { label: 'implementer', schema: IMPL, model: 'sonnet', effort: effortFor.implement })
if (!impl) throw new Error('implementer failed')
sImpl.close()

// Whether anything actually went through the gate, across every committing
// phase from here through the mutation loop -- an implementer that scored
// nothing (nothing changed the gate checks) can still be followed by a fix
// round or the mutation loop that does. Folded with OR, never overwritten, so
// one scored=true anywhere makes the whole run's `measured` claim 'scored'.
//
// Declared above the halts below, not after them: these are `let` bindings,
// and the gate payload helper reads all three, so a halt that called it from
// above this point died with "Cannot access 'scored' before initialization"
// rather than reporting the gate.
let scored = impl.scored === true
// Kept apart by whether the reporting phase itself scored: pairing a final
// measured='scored' with an unscored phase's "nothing to score" note would
// misattribute evidence, and the reverse throws away the only observation
// there is for a run that never scores at all -- scored=false covers "no
// commits", "it printed nothing to score" and more, and the note is what
// says which.
let scoredNote = scored ? (impl.gate_note ?? '') : ''
let unscoredNote = scored ? '' : (impl.gate_note ?? '')

// The only other outcome this phase can report, and the only one that must
// not fall through to Draft PR: the schema has no other way to say "I
// stopped", so an unhandled unsupported_language would read as a normal,
// reviewable result and the refused work would never reach a commit.
if (impl.unsupported_language) {
  return await halted('Implement', {
    plan: plan.plan, implemented: impl.summary, gates: gatesPayload(),
    note: impl.summary,
  })
}
if (sImpl.over()) {
  return await halted('Implement', {
    plan: plan.plan, implemented: impl.summary, gates: gatesPayload(),
    // The note says nothing about the gates: an implementer that committed
    // before overrunning did gate those commits, and what was measured is in
    // the gates field now.
    note: 'implementer exceeded its token ceiling; any work is on the branch and review did not run',
  })
}

// Run before Review spends any budget on something a script already
// answers with an exit code.
const sChecksPost = stage('checks')
let lastCheckedHead = headOf(impl.commit_range)
let redChecks = await runChecks()
if (redChecks.length) {
  log(`checks: ${redChecks.length} discovered check(s) red after Implement: ` +
      redChecks.map(c => c.name).join(', '))
}

// One checks-only fix round before Review, so a purely mechanical defect
// (a missing version bump, the incident this exists for) is applied as
// part of the same diff Review reads, rather than reaching a reviewer as
// something to notice.
if (blockingChecksOpen() && !sChecksPost.over()) {
  const preReviewFixed = await treeAgent(
    `Fix the repo's own failing checks below in the current repo, iterating ` +
    `with the repo's own test command if a fix needs one. Commit with ` +
    `crap-commit.sh ${wt.path} -m "...", which gates and commits in one ` +
    `call: run it in the foreground with a Bash timeout of 600000, never ` +
    `background it and wait with sleep, and do not pre-run crap-check.sh. ` +
    `Never create, edit or delete .crap-gated, .mutation-gated or ` +
    `.comment-gated on your own initiative: that is the repo owner's ` +
    `decision, not yours. The one exception is a NEXT_ACTION of ` +
    `UNSUPPORTED_LANGUAGE: halt and report its three options rather than ` +
    `editing the marker yourself. Set unsupported_language=true when you ` +
    `do, and put the three options in note; leave head_sha as the ` +
    `unchanged HEAD if you made no commits before hitting it. Do not push ` +
    `or open a PR.\n` +
    `Task: ${brief(task)}\n` +
    redChecks.map(renderCheck).join('\n\n') + `\n` +
    `Return head_sha: the full 40-character SHA of HEAD after your last ` +
    `commit, or of the unchanged HEAD if you committed nothing. Return ` +
    `scored=true if crap-commit.sh printed that it scored this round's ` +
    `commits, scored=false otherwise; if it printed its own gate message, ` +
    `copy it verbatim into gate_note.`,
    { label: 'checks:fix', schema: FIXED, model: 'sonnet', effort: effortFor.implement })
  if (preReviewFixed?.scored === true) {
    scored = true
    if (preReviewFixed?.gate_note) scoredNote = preReviewFixed.gate_note
  } else if (preReviewFixed?.gate_note) {
    unscoredNote = preReviewFixed.gate_note
  }
  if (preReviewFixed?.unsupported_language) {
    sChecksPost.close()
    stageSpend.checks = checksPreSpend + (stageSpend.checks ?? 0)
    return await halted('Implement', {
      plan: plan.plan, implemented: impl.summary, gates: gatesPayload(),
      checks: checksPayload(),
      note: preReviewFixed.note,
    })
  }
  // impl.commit_range is what Review reads below; folding the pre-review
  // fix's head into it is what keeps the version bump inside the diff a
  // reviewer sees, instead of arriving as a fix round after the fact.
  const preReviewHead = preReviewFixed?.head_sha?.trim()
  if (preReviewHead && preReviewHead !== lastCheckedHead) {
    const implBase = impl.commit_range.includes('..')
      ? impl.commit_range.split('..')[0].trim() : impl.commit_range.trim()
    impl.commit_range = `${implBase}..${preReviewHead}`
    preReviewFixCommitted = true
    lastCheckedHead = preReviewHead
    redChecks = await runChecks()
    log(redChecks.length
      ? `checks: ${redChecks.length} still red after the pre-review fix round`
      : `checks: all clear after the pre-review fix round`)
  }
}
sChecksPost.close()
stageSpend.checks = checksPreSpend + (stageSpend.checks ?? 0)

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
  (baseOverride ? ` --base ${wt.base}` : '') + `. Push the branch either ` +
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
// number, not opened: the PR phase addresses the draft by number to update and
// ready it, and a url with no number is not enough for that.
if (draft?.number) {
  draftPr = { url: draft.url, number: draft.number }
  log(`PR #${draft.number} carries this run: ${draft.url ?? '(no url)'}`)
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
// files_changed and insertions describe the implementer's own commits, and
// the checks-only fix commits after them without updating either. Since this
// latch can skip review outright, a run that took that fix is never trivial.
const trivial = !preReviewFixCommitted &&
  impl.files_changed.length <= 1 && (impl.insertions ?? 999) < INLINE_LOC
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
// Falls back to the bare file when a lens reported no span, so a schema-legal
// finding never breaks the fix brief that renders it.
const locusOf = (f) =>
  typeof f.line_start !== 'number' ? f.file
  : (typeof f.line_end === 'number' && f.line_end !== f.line_start)
    ? `${f.file}:${f.line_start}-${f.line_end}` : `${f.file}:${f.line_start}`
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
      `Read wide, report narrow. A finding must be a defect these commits ` +
      `introduce, or one they were meant to fix and did not. A defect that was ` +
      `already there in code this range does not touch is out of scope however ` +
      `real it is: someone else's bug, filed here, costs a fix round and can ` +
      `stop the run. Do not report it.\n` +
      `Report only findings you can defend with file:line evidence. Do NOT ` +
      `report coverage, complexity, test quality, or style: deterministic ` +
      `gates own those. Set line_start (and line_end, if the span covers more ` +
      `than one line) to where the defect sits, so the fix does not have to ` +
      `re-read this range to find it; leave them out only when nothing that ` +
      `narrow applies.` +
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
  const raised = out.filter(Boolean).flatMap(r => r.findings)
    .map(f => ({ ...f, id: `f${++findingSeq}`, recorded_at: headOf(range) }))
  // A finding with no span reaches the fixer as a bare filename, and the
  // brief no longer points at the range either, so it arrives with less than
  // it used to. Counted so that drift shows up instead of being argued about.
  const spanless = raised.filter(f => typeof f.line_start !== 'number')
  if (spanless.length) {
    log(`${tag}: ${spanless.length} of ${raised.length} finding(s) carry no line span: ` +
        spanless.map(f => `${f.id} (${f.file})`).join(', '))
  }
  return raised
}

// Everything from here to the PR is measured against reviewedThrough: the SHA
// an adversary has actually read up to. It only ever advances by way of a
// review, so a phase that commits without one leaves it behind and the PR
// guard below refuses.
let reviewedThrough = headOf(impl.commit_range)

// Lenses cannot see each other, and contentKeyOf cannot merge them: two
// reviewers describe one bug in different words. A failure keeps everything,
// which costs a duplicate rather than losing a defect.
const collapseDuplicates = async (findings) => {
  if (findings.length < 2 || reviewerCount < 2) return findings
  const grouped = await agent(
    `Several reviewers looked at the same diff without seeing each other's ` +
    `work, so the list below may describe the same defect more than once.\n` +
    `Group the ids that are the same defect. Same underlying bug at the same ` +
    `place counts as one even when the wording, the severity or the suggested ` +
    `fix differ. Two defects that merely sit in one function are NOT one ` +
    `group. Return only groups of two or more ids; if nothing duplicates, ` +
    `return an empty list. Do not judge whether any finding is correct.\n` +
    findings.map(f => `[${f.id}] ${f.title} (${f.file}): ${f.claim}`).join('\n'),
    { label: 'review:dedup', phase: 'Review', schema: DUPES,
      model: 'haiku', effort: 'low' })
  const dropped = new Set()
  for (const g of grouped?.groups ?? []) {
    const ids = (Array.isArray(g?.ids) ? g.ids : [])
      .map(stripBrackets)
      .filter(id => findings.some(f => f.id === id))
    for (const id of ids.slice(1)) dropped.add(id)
    if (ids.length > 1) {
      log(`review: ${ids.slice(1).join(', ')} fold into ${ids[0]}` +
          (g.why ? ` (${g.why})` : ''))
    }
  }
  if (!dropped.size) return findings
  log(`review: ${findings.length} finding(s) from ${reviewerCount} reviewers ` +
      `collapse to ${findings.length - dropped.size}`)
  return findings.filter(f => !dropped.has(f.id))
}

let open = reviewerCount
  ? await collapseDuplicates(await reviewOf(impl.commit_range, 'review', lenses))
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
// it was handed, or reporting the fix did not hold. Not reopened mid-loop,
// which would send the fixer to undo its own work; recorded, then verified
// once the loop ends so a real one is not filed away as noise.
let regressionSuspects = []
let suspectsUnverified = false
let round = 0
// Per round, just the fix agent's own output tokens (the cost this ticket
// targets), separate from stageSpend.fix which also carries verify and the
// tail review.
const fixRoundSpend = []
// The diff the most recent fix round actually produced. Verify is judged
// against this instead of the whole commit range; a call after the loop ends
// (the late pass, the suspect recheck) has no round of its own, so it reuses
// the last one rather than falling back to an unbounded range.
let lastFixRange = null
// Which of the loop's four exits fired. Checked in the same order the loop
// tests them, so the answer matches the condition that actually stopped it.
// Every id a verifier has been asked about. A finding first reported by the
// last round's tail review would otherwise reach the halt having never been
// checked, listed as one that survived every round.
const everVerified = new Set()
// One verifier for every finding, not one each. Six findings meant six agents
// that each re-read the same diff to answer six questions about it; the reading
// is the expensive part and it is identical across them. Returns [id, fixed]
// pairs, keyed on the id the script assigned in reviewOf, never the title: a
// model asked to echo a title verbatim reworded it anyway, which stalled every
// finding until the round limit and halted the run for good.
const verifyOpen = async (findings, label, range, afterFix = true) => {
  if (!findings.length) return []
  for (const f of findings) everVerified.add(f.id)
  const out = await treeAgent(
    `Verify, finding by finding, whether each is now actually fixed.\n` +
    (afterFix
      ? `The fix's own commit range is ${range}. `
      : `No fix round ran, so there is no fix diff; the change under review ` +
        `is ${range}. `) +
    `Read git diff ${range} and judge ` +
    `each claim against that diff first, rather than re-reading the file cold ` +
    `or trusting a claim it was fixed. Widen beyond this range only when the ` +
    `diff itself cannot answer the question. When you do, set widened=true ` +
    `on that finding's verdict and say in its note what you had to read and ` +
    `why the diff could not answer it. Set widened=false otherwise.\n` +
    `Each finding below is listed with its id in brackets. Return one ` +
    `verdict per finding with that id copied exactly into id; order does ` +
    `not matter. A verdict whose id is not in this list is discarded, and a ` +
    `finding with no verdict stays open. Nothing is matched on the title, ` +
    `so rewording it costs nothing.\n` +
    findings.map(f =>
      `[${f.id}] ${f.title} (${locusOf(f)}): ${f.claim}. Evidence was: ${f.evidence}`
    ).join('\n'),
    // phase is explicit: inside parallel() the global phase() cursor races
    // with the Review group the tail lens opens beside it.
    { label, phase: 'Fix', schema: VERDICTS, model: 'opus',
      effort: effortFor.verify })
  // Pairs, not a Map: this crosses parallel() at the loop-join call site,
  // which serializes each thunk's result and strips a Map down to a plain
  // object with no .get. The Map is rebuilt at each call site instead.
  const kept = (out?.verdicts ?? []).filter(v => typeof v.id === 'string')
  const widened = kept.filter(v => v.widened === true)
  if (widened.length) {
    log(`${label}: ${widened.length} verdict(s) read past ${range}: ` +
        widened.map(v => `${stripBrackets(v.id)} (${v.note ?? 'no reason given'})`).join('; '))
  }
  return kept.map(v => [stripBrackets(v.id), v.fixed === true])
}

// Advisory only: a finding's evidence may have moved since it was recorded. One
// cheap agent checks each against its evidence, not just its file. Skipped only
// when the loop ran zero rounds, since nothing could have changed then; a loop
// that stopped on budget after a round already committed is exactly the case
// this exists for, so it runs regardless of budget. Any rejection degrades to
// nothing marked, never to losing the halt.
// Declared before the loop because the refusal halt inside it calls this too,
// and a const declared below the loop is in its temporal dead zone.
const markStale = async (findings) => {
  let staleness = null
  if (round > 0 && findings.length) {
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
        findings.map(f =>
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
  return findings.map(f =>
    staleIds.has(f.id) ? { ...f, code_changed_since_recorded: true } : f)
}

const fixStopReason = () =>
  !open.length && !blockingChecksOpen() ? 'every finding and check was resolved'
  : round >= MAX_REVIEW_ROUNDS
    ? `the ${MAX_REVIEW_ROUNDS}-round limit was reached; each of these was ` +
      `checked against the code and is still open`
  : sFix.over()
    ? `the fix stage passed its ${Math.round(CEILINGS.fix / 1000)}k output-token ` +
      `ceiling, so the loop stopped early -- these have not had every round`
  : outOfBudget()
    ? 'the run passed its overall token budget, so the loop stopped early'
  : 'the loop ended without reaching any of its limits, which should not happen'

while ((open.length || blockingChecksOpen()) && round < MAX_REVIEW_ROUNDS && !outOfBudget() && !sFix.over()) {
  round++
  phase('Fix')
  const fixSpendStart = budget.spent()
  const fixed = await treeAgent(
    `Fix ` + (open.length && blockingChecksOpen()
      ? `these confirmed review findings and the repo's own failing checks below`
      : open.length ? `these confirmed review findings`
      : `the repo's own failing checks below`) +
    ` in the current repo, TDD first, ` +
    `iterating with the repo's own test command. Commit with ` +
    `crap-commit.sh ${wt.path} -m "...", which gates and commits in one ` +
    `call: run it in the foreground with a Bash timeout of 600000, never ` +
    `background it and wait with sleep, and do not pre-run crap-check.sh. ` +
    `Never create, edit or delete .crap-gated, ` +
    `.mutation-gated or .comment-gated on your own initiative: that is the ` +
    `repo owner's decision, not yours, and a repo without any of them is ` +
    `simply not gated -- say so and continue. The one exception is a ` +
    `NEXT_ACTION of UNSUPPORTED_LANGUAGE: halt and report its three options ` +
    `to the user rather than picking one and editing the marker yourself. Set ` +
    `unsupported_language=true when you do, and put the three options in note. ` +
    `Do not push or open a PR.\n` +
    `Task: ${brief(task)}\n` +
    `Each finding names the place it was raised against. Work from there. ` +
    `Read git diff ${impl.commit_range} only when that place cannot tell you ` +
    `what the change was meant to do -- a finding about scope, an unmet ` +
    `criterion, or a caller outside the diff.\n` +
    `Fix what the findings name and no more. If fixing one requires reverting ` +
    `or weakening a deliberate part of the change that no finding objected to, ` +
    `say so in note and leave it: an unasked-for revert is how this workflow ` +
    `has shipped regressions before.\n` +
    `Return head_sha: the full 40-character SHA of HEAD after your last commit, ` +
    `or of the unchanged HEAD if you committed nothing. Your commits are ` +
    `reviewed as <previous head>..<your head_sha>, so a wrong or abbreviated ` +
    `SHA there is how unreviewed code reaches the PR.\n` +
    `Return scored=true if crap-commit.sh printed that it scored this round's ` +
    `commits, scored=false if you committed nothing or it printed nothing to ` +
    `score. Base this on what it printed, never on whether .crap-gated exists ` +
    `and never on your own judgement of the change. If it printed its own ` +
    `gate message, copy it verbatim into gate_note.\n` +
    (open.length
      ? `Findings, each at the location its reviewer already read; open that ` +
        `location directly rather than re-reading the whole commit range for ` +
        `context:\n` +
        open.map(f => `- ${f.title} (${locusOf(f)}): ${f.claim}`).join('\n') + `\n`
      : '') +
    (blockingChecksOpen()
      ? `The repo's own checks below are failing. Each is a script the repo ` +
        `already runs and decides the same way every time, not a reviewer's ` +
        `opinion; make every one pass rather than silencing its output.\n` +
        redChecks.map(renderCheck).join('\n\n')
      : ''),
    { label: `fix:${round}`, schema: FIXED, model: 'sonnet', effort: effortFor.implement })
  fixRoundSpend.push({ round, output: budget.spent() - fixSpendStart })
  // Folded before the halt check below, not after: a fixer that committed part
  // of the work and only then hit the refusal still has a gate result, and the
  // halt is the only place left to report it.
  if (fixed?.scored === true) {
    scored = true
    if (fixed?.gate_note) scoredNote = fixed.gate_note
  } else if (fixed?.gate_note) {
    unscoredNote = fixed.gate_note
  }
  // Same reasoning as Implement's check above: without this, a fixer that
  // reports the halt reads as a normal round and the loop keeps going with
  // the refused work still uncommitted.
  if (fixed?.unsupported_language) {
    // The stage is closed before the return because closing is what records
    // its spend. stopped_because is written here rather than taken from the
    // shared reason helper, whose arms all describe a limit being reached and
    // so would call this refusal "should not happen".
    sFix.close()
    return await halted('Fix', {
      plan: plan.plan, implemented: impl.summary, gates: gatesPayload(),
      unresolved_findings: await markStale(open), fix_rounds: round,
      fix_round_output: fixRoundSpend,
      stopped_because:
        `the fixer hit a NEXT_ACTION of UNSUPPORTED_LANGUAGE and halted rather ` +
        `than editing a gate marker, so these findings have not had every round`,
      regression_suspects: regressionSuspects,
      checks: checksPayload(),
      note: fixed.note,
    })
  }
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
  const roundRange = head && head !== reviewedThrough
    ? `${reviewedThrough}..${head}` : reviewedThrough
  lastFixRange = roundRange

  const [verdicts, freshRaw] = await parallel([
    () => verifyOpen(open, `verify:${round}`, roundRange),
    // The point of the loop: a fix is a change, so it faces the same adversary.
    // One lens, not all of them -- correctness is where a fix round goes wrong,
    // and the range is small.
    // async, so the skip path still hands parallel() a promise rather than a
    // bare array.
    async () => tailReviewable
      ? reviewOf(roundRange, `review:fix:${round}`, [LENS.correctness],
          [...settled, ...open])
      : [],
  ])

  const byId = new Map(verdicts ?? [])
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

  if (checksBlocking && discoveredChecks.length && head && head !== lastCheckedHead && !outOfBudget()) {
    redChecks = await runChecks()
    lastCheckedHead = head
  }
  log(`round ${round}: ${open.length} finding(s) still open` +
      (discoveredChecks.length ? `, ${redChecks.length} check(s) still red` : ''))
}

// The last round's tail review appends findings and the loop then exits, so
// without this they reach the halt unchecked while the fix that closed their
// twins sits in settled. One run halted on 11 findings of which 8 were already
// confirmed fixed. Not gated on the fix ceiling: a false halt costs the whole
// run, and this is one agent.
if (open.length && !outOfBudget()) {
  const unchecked = open.filter(f => !everVerified.has(f.id))
  if (unchecked.length) {
    log(`${unchecked.length} finding(s) were reported too late to be checked ` +
        `by a round; verifying them before deciding to halt`)
    const late = new Map(await verifyOpen(unchecked, 'verify:final',
      lastFixRange ?? reviewedThrough, lastFixRange !== null))
    const closed = unchecked.filter(f => late.get(f.id) === true)
    settled.push(...closed)
    const closedIds = new Set(closed.map(f => f.id))
    open = open.filter(f => !closedIds.has(f.id))
    log(closed.length
      ? `${closed.length} of them were already fixed; ${open.length} still open`
      : `none of them were fixed; ${open.length} still open`)
  }
}

// duplicate_of cannot separate a lens re-reporting a fixed finding from one
// describing a defect that finding's fix introduced: both reference the same
// id. Assuming the first readied a PR whose mutation gate any bogus `git -C`
// switched off, under unresolved_findings: []. No verdict means unknown,
// which stays blocking, as it already does for the open list.
if (regressionSuspects.length && !outOfBudget()) {
  log(`verifying ${regressionSuspects.length} regression suspect(s) before ` +
      `treating them as noise`)
  const verdicts = new Map(await verifyOpen(regressionSuspects, 'verify:suspects', lastFixRange))
  const live = regressionSuspects.filter(f => verdicts.get(f.id) !== true)
  const liveIds = new Set(live.map(f => f.id))
  regressionSuspects = regressionSuspects.filter(f => !liveIds.has(f.id))
  open = open.concat(live)
  log(live.length
    ? `${live.length} suspect(s) still reproduce and are now open; ` +
      `${regressionSuspects.length} confirmed fixed`
    : `none reproduce; all ${regressionSuspects.length} stay advisory`)
} else if (regressionSuspects.length) {
  suspectsUnverified = true
  log(`${regressionSuspects.length} regression suspect(s) could not be verified ` +
      `(out of budget); reported unverified rather than as noise`)
}
sFix.close()

// A function, not a value computed once here: `scored` and the two notes keep
// folding in later phases' own reports (the mutation loop below can still add
// to them), so each halt and the final result call this after whatever has
// scored by that point rather than freezing it at the end of the fix loop.
// bypass_blocked is the earlier probe's crapGated answer, unrelated to
// whether anything scored.
function gatesPayload() {
  // scored=false does not mean any one thing -- no commits, a gate that
  // printed nothing to score, or (unconfirmed) that it never ran -- so the
  // clause here stays generic and leaves the actual cause to gateNote below,
  // rather than asserting one. scored=true only means a phase reported that
  // crap-commit.sh printed a scored pass on its own commits -- an adoption or
  // a declaration-only pass counts too, and neither measured a function -- so
  // the true arm claims a pass on a commit, never a count of what it scored.
  const scoredClause = scored
    ? 'and passed on a commit in this range'
    : 'but nothing in this range scored'
  const bypassClause = crapGated
    ? 'a raw git commit could not have bypassed it (.crap-gated present at the repo root)'
    : 'nothing hook-enforced stopped a raw git commit from bypassing it ' +
      '(.crap-gated absent at the repo root, or its presence could not be confirmed)'
  const gateNote = scored ? scoredNote : unscoredNote
  return {
    measured: scored ? 'scored' : 'nothing scorable',
    bypass_blocked: crapGated,
    detail: (`${scored ? 'gates measured' : 'gates ran, nothing scorable'}: ` +
      `crap-commit.sh runs the dead-code and CRAP gates on every commit ` +
      `${scoredClause}; separately, ${bypassClause}. ${gateProbe?.detail ?? ''}`
    ).trim() + (gateNote ? ` ${gateNote}` : ''),
  }
}

if (open.length || blockingChecksOpen()) {
  const reported = await markStale(open)
  const staleCount = reported.filter(f => f.code_changed_since_recorded).length

  return await halted('Fix', {
    plan: plan.plan, implemented: impl.summary, gates: gatesPayload(),
    unresolved_findings: reported, fix_rounds: round, stopped_because: fixStopReason(),
    fix_round_output: fixRoundSpend,
    regression_suspects: regressionSuspects,
    checks: checksPayload(),
    // Report the round count that actually ran and why the loop ended. This
    // said "survived MAX_REVIEW_ROUNDS rounds" unconditionally, so a loop that
    // stopped early on its token ceiling was reported as findings surviving
    // three rounds it never got. The two need opposite remedies -- raise the
    // ceiling, or judge the findings -- and the note pointed at the wrong one.
    note: `${open.length} review finding(s)` +
          (blockingChecksOpen() ? ` and ${redChecks.length} discovered check(s)` : '') +
          ` still open after ${round} fix round(s); ${fixStopReason()}. Stopping ` +
          `before the mutation stage rather than spending it on work that cannot ` +
          `be marked ready. Judge each finding: fix it, or reject it as wrong.` +
          (blockingChecksOpen()
            ? ` A red check is the repo's own verdict, not a judgement call: ` +
              `${redChecks.map(c => c.name).join(', ')}.`
            : '') +
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
// `gh pr ready` while it is red, so a red gate here means the PR phase below
// cannot get past a draft anyway. It deliberately does not block
// `gh pr create --draft`, which is how this pipeline opens the draft above.
phase('Mutation')
const sMut = stage('mutation')
let mutation = { green: false, detail: 'not run' }

// Mutation gating is opt-in, on the same marker mutation-pr-gate.py reads.
// mutationGated came out of the merged gate-opt-in probe before Implement;
// nothing between there and here writes to the repo root, so the answer is
// still current. A repo with no marker has nothing enforcing the gate and may
// have none of the tooling installed, so a red result there is unclearable by
// any amount of work.
if (!mutationGated) {
  mutation = {
    green: true,
    detail: `skipped: repo has not opted into mutation gating ` +
      `(.mutation-gated absent at the repo root). ${gateProbe?.detail ?? ''}`.trim(),
  }
  log(`mutation gate skipped: no .mutation-gated marker, so nothing enforces it ` +
      (crapGated
        ? `(the CRAP and dead-code gates still ran on every commit)`
        : `(the CRAP and dead-code gates are not hook-enforced here either, ` +
          `per the earlier probe)`))
}
// needs_user_run breaks the loop instead of retrying: a run that cannot fit the
// Bash ceiling returns the same answer every attempt, and each one costs the
// ceiling in wall clock before saying so.
for (let attempt = 1; attempt <= MAX_GATE_ATTEMPTS && !mutation.green
     && !mutation.needs_user_run && !mutation.unsupported_language
     && !outOfBudget() && !sMut.over(); attempt++) {
  mutation = await treeAgent(
    `Run mutation-check.sh ${wt.path} from the crap-controlled-changes skill in ` +
    `this repo. It mutates files in place and needs a clean working tree, so ` +
    `commit anything outstanding first. Never create, edit or delete .crap-gated, ` +
    `.mutation-gated or .comment-gated on your own initiative: that is the ` +
    `repo owner's decision, not yours, and a repo without any of them is ` +
    `simply not gated -- say so and continue. The one exception is a ` +
    `NEXT_ACTION of UNSUPPORTED_LANGUAGE: halt and report its three options ` +
    `to the user rather than picking one and editing the marker yourself. Set ` +
    `unsupported_language=true when you do, and put the three options in ` +
    `detail.\n` +
    `HOW TO RUN IT, in this order. The skill's Signal C settles all of this ` +
    `from measurements; do not re-derive a policy of your own, which is why ` +
    `this phase has been inconsistent run to run.\n` +
    `1. mutation-check.sh ${wt.path} --verify first. It reads the ledger and ` +
    `costs milliseconds. If it reports the branch already green, you owe no ` +
    `run at all: return green=true saying so. A branch stayed green for two ` +
    `hours once while four full runs re-measured it.\n` +
    `2. If the repo has scripts/gate-env.sh, run ` +
    `eval "$(scripts/gate-env.sh mutation)" in the same shell invocation as the ` +
    `check. It exports the build tags, test runner and database DSN the gate ` +
    `needs. Without it the suite falls back to one throwaway container per test, ` +
    `turning a one-minute run into ten, and on a split build it measures the ` +
    `wrong build entirely. Read the comments it prints: they name any second ` +
    `pass the repo needs.\n` +
    `3. Run it in the FOREGROUND with a Bash timeout of 600000, no flags (just ` +
    `mutation-check.sh ${wt.path}), so the run is incremental. Do not use ` +
    `run_in_background: past runs here were killed by a SIGTERM nobody has ` +
    `explained, so it is not a route to rely on. Do not poll with sleep either.\n` +
    `4. If one pass will not fit inside that ceiling, SPLIT IT. Do not hand it ` +
    `back. The ledger records per path, so scoped passes accumulate into one ` +
    `green: run MUTATION_ONLY='<glob>' over one module or package at a time, ` +
    `each pass inside the ceiling (mutation-check.sh ${wt.path}), until ` +
    `mutation-check.sh ${wt.path} --verify reports the branch green. Name ` +
    `every glob you ran in detail. Asking the user to run the gate in their ` +
    `own terminal is not an acceptable outcome, and neither is reporting it ` +
    `unrunnable because of a timeout.\n` +
    `5. Only if one indivisible path exceeds the ceiling on its own, so there ` +
    `is nothing left to split, return green=false with needs_user_run=true and ` +
    `the exact command in detail, including the gate-env eval from step 2 and ` +
    `${wt.path} as the leading argument to mutation-check.sh. That is a last ` +
    `resort and it means the split failed, so say which glob was too big and ` +
    `how long it ran.\n` +
    `6. --full (mutation-check.sh ${wt.path} --full) re-measures every changed ` +
    `source, which you need when something outside the ledger's key changed: ` +
    `a fixture, a compose file, a toolchain pin. A narrowed pass records only ` +
    `what it measured, so say what is still unmeasured.\n` +
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
    `keyed off this SHA.\n` +
    `Return scored=true if crap-commit.sh printed that it scored a commit you ` +
    `made this attempt, scored=false if you committed nothing or it printed ` +
    `nothing to score. Base this on what it printed, never on whether ` +
    `.crap-gated exists and never on your own judgement of the change. If it ` +
    `printed its own gate message, copy it verbatim into gate_note.`,
    { label: `mutation:${attempt}`, schema: GATE, model: 'sonnet', effort: 'high' }) ?? mutation
  if (mutation?.scored === true) {
    scored = true
    if (mutation?.gate_note) scoredNote = mutation.gate_note
  } else if (mutation?.gate_note) {
    unscoredNote = mutation.gate_note
  }
}
sMut.close()

if (!mutation.green) {
  return await halted('Mutation', {
    plan: plan.plan, implemented: impl.summary, gates: gatesPayload(),
    mutation, unresolved_findings: open, regression_suspects: regressionSuspects,
    // unsupported_language checked first: neither of the other two notes
    // describes it (the tree is not necessarily uncommittable, and it is not
    // a Bash-ceiling timeout), and blaming surviving mutants for a gate that
    // never ran sends a human chasing the wrong fix.
    // No arm states the PR's fate itself: this note is posted as a comment on
    // the draft when there is one, and prNote() is what knows whether there is.
    note: mutation.unsupported_language
      ? `The mutation agent hit a NEXT_ACTION of UNSUPPORTED_LANGUAGE and ` +
        `halted rather than editing .crap-gated or .mutation-gated itself. ` +
        `${mutation.detail} ${prNote()}; a human has to pick ` +
        `one of the reported options before this can proceed.`
      : mutation.needs_user_run
      ? `The mutation run does not fit the 600000 ms Bash ceiling, which for ` +
        `this repo is expected rather than a fault. Run the command in detail ` +
        `in your own terminal, then re-run this workflow: --verify will find ` +
        `the ledger green and the gate will cost milliseconds. ${prNote()}, ` +
        `and mutation-pr-gate.py would block marking it ready anyway.`
      : `Mutation gate still red after ${MAX_GATE_ATTEMPTS} attempt(s). Surviving ` +
        `mutants are behaviour the tests cannot detect. ${prNote()}, and ` +
        `mutation-pr-gate.py would block marking it ready. Kill them ` +
        `with tests, or approve a provably equivalent mutant with ` +
        `mutation-check.sh ${wt.path} --accept.`,
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
    `does it. Doing so ends the run without the PR being marked ready, on the grounds that a ` +
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
      gates: gatesPayload(),
      unresolved_findings: fresh, fix_rounds: round, fix_round_output: fixRoundSpend,
      regression_suspects: regressionSuspects,
      note: `The mutation gate's own commits (${reviewedThrough}..${mutHead}) ` +
            `introduced ${fresh.length} finding(s). The fix rounds are spent. ` +
            `${prNote()}. Judge each: fix it, or reject it as wrong.`,
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
      ? `This branch is stacked: open the PR with --base ${wt.base}, not ` +
        `against the repo's default branch, and say in the body that it targets ` +
        `that branch and why. gh defaults to the default branch, which would ` +
        `show the parent's commits as this PR's own.\n`
      : '') +
    `gh has no -C flag, so the mutation gate that intercepts gh pr ready and ` +
    `gh pr create can only resolve this worktree from a git -C ${wt.path} ` +
    `invocation in the same Bash command, never a separate one before it. ` +
    `Chain the push into the same command line as the gh call, e.g. ` +
    `git -C ${wt.path} push ... && gh pr ...; do not run them as two calls.\n` +
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
  // Suspects stay in the result and the run record. They used to be posted as
  // a PR comment, which put a note about the run on the repository's permanent
  // record for a reader who cannot act on it.
  if (pr?.opened && regressionSuspects.length) {
    log(`${regressionSuspects.length} regression suspect(s) in this run's ` +
        `result and record; not posted`)
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
  gates: gatesPayload(),
  checks: checksPayload(),
  mutation,
  reviewers: reviewerCount,
  regression_suspects: regressionSuspects,
  // An unverified suspect is an open question, not a clean bill: saying so
  // here is what keeps "nothing outstanding" from being claimed on its behalf.
  suspects_unverified: suspectsUnverified,
  reviewed_through: reviewedThrough,
  fix_rounds: round,
  fix_round_output: fixRoundSpend,
  unresolved_findings: open,
  pr,
  needs_user: suspectsUnverified || (args?.openPr !== false && !pr?.opened),
}
result.record_path = await recordRun(result)
return result
