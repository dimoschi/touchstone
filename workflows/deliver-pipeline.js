export const meta = {
  name: 'deliver-pipeline',
  description: 'Triage -> plan -> implement (TDD) -> gates -> adversarial review -> mutation -> PR, bounded',
  whenToUse: 'Ticket-driven delivery in a repo that has opted into gating. Prefer the /deliver command, which parses flags and refuses without a ticket. Pass args: {ticket: "..."}; task is optional and narrows the ticket. Pass {plan: "..."} to reuse a plan an earlier run produced, which skips the Plan phase and starts at Implement.',
  phases: [
    { title: 'Worktree', detail: 'canonically named branch and worktree from a freshly pulled base, then fetch the ticket once for every later phase' },
    { title: 'Triage', detail: 'one cheap agent checks the premise, sizes the job and judges its difficulty; a disproved premise halts, small work skips Plan, and the difficulty sets every later phase\'s reasoning effort' },
    { title: 'Plan', detail: 'planner produces a concise plan + acceptance criteria + risk areas; the whole plan is written to an untracked file in the worktree, which the implementer must read to its last line' },
    { title: 'Implement', detail: 'one implementer, TDD via crap-controlled-changes, many small signed commits' },
    { title: 'Draft PR', detail: 'push the branch and open a draft PR, or adopt the branch\'s open PR only when its head is an ancestor of the branch, converting a ready one back to a draft, so the work is visible and any later halt has somewhere durable to be reported' },
    { title: 'Review', detail: 'a measured diffstat (code churn, with comments, tests and docs counted apart) decides the reviewer lenses: correctness and devil\'s advocate normally, plus requirements coverage on a large or wide change, none on a one-liner; support code (tests, docs, comments) far outweighing the actual change halts here before any lens runs. Only a wrong-result, crash, gate-bypass or unmet-criterion finding with a demonstrated reproducer can hold the run; everything else reaches the PR as a note. Runs again on any commits a later phase adds, and from the first re-review on a finding also has to fall inside what that range actually changed' },
    { title: 'Fix', detail: 'fix confirmed findings, bounded rounds; a finding is fixed when its own reproducer exits 0, never by a model\'s judgement of the diff' },
    { title: 'Mutation', detail: 'pre-PR mutation gate; kill survivors with tests, never weaken code. Its own commits are reviewed before the PR' },
    { title: 'PR', detail: 'push, fill in the PR against the repo template, and mark the draft ready for review, only when every gate is green' },
  ],
}

// Built by scripts/build-pipeline.sh from workflows/parts/*.js.part;
// edit the parts and rebuild, never this file directly.

// A snapshot of this script can keep running after main moves past it: the
// host that persists a copy under its own session directory, the plugin
// cache, and this checkout can all disagree on which version actually
// executed. The script has no fs and no imports (see docs/architecture.md),
// so it cannot read .claude-plugin/plugin.json to find out -- any runtime
// read would report whatever the *current* file holds, which is exactly
// wrong when the point is to say what this *running* snapshot is. A literal
// is the only value that travels with the executed bytes; a regex checks it
// against the manifest in scripts/check-version-bump.sh, so drift is a
// gate's job rather than something this script verifies about itself.
const PLUGIN_NAME = 'touchstone'
const PIPELINE_VERSION = '0.36.0'

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
// Keyed by ticket, not run id: a script is never told its own run id, and the
// ticket is what a human looks the run up by. The script no longer writes this
// file itself (that agent dispatch cost a full round trip for a mkdir and a
// heredoc); it names the path and hands the payload back, and the invoking
// session writes it, the same session that already appends run_id and models
// afterwards.
const runRecordFile = `.claude/touchstone-runs/${String(ticket).replace(/[^A-Za-z0-9_-]/g, '-')}.json`

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
// The rest of the lens-count and ratio thresholds Review measures against,
// once the diffstat probe has sized the actual diff (see lensKeysFor and
// sizeOf in part 40): below ONE_LENS_LOC a single correctness lens is
// enough; above BIG_LOC, or past BIG_FILES code files touched, the
// requirements lens joins too. RATIO_MIN_CODE is the floor below which the
// support-ratio halt does not apply at all -- a change that is mostly tests
// by design must not halt on that alone -- and MAX_SUPPORT_RATIO is the
// limit past it; args.supportRatio raises the limit for a run that knows
// its own ratio is intentional. This repo's own last 20 merged commits ran
// 1.0-14.4:1, and every one still at or above the code floor ran 1.2-7.6:1:
// a real TDD change with tests routinely clears 3:1, so the limit sits at
// 10 instead, above that observed range with headroom.
const ONE_LENS_LOC = 150
const BIG_LOC = 400
const BIG_FILES = 5
const RATIO_MIN_CODE = 20
const MAX_SUPPORT_RATIO = 10

// Long briefs make agents thorough about the wrong things, and the task text is
// re-sent to every agent in the pipeline. Clamp what gets forwarded.
const BRIEF_CHARS = args?.briefChars ?? 4000
const brief = (s) => {
  const t = String(s ?? '')
  return t.length <= BRIEF_CHARS ? t : `${t.slice(0, BRIEF_CHARS)}\n[brief truncated]`
}
// The plan is never passed through brief(): the implementer reads it whole from
// a file, so the planner is held to a length instead.
const PLAN_MAX_CHARS = args?.planMaxChars ?? 6000

// Shared by every prompt that reads or edits code (implement, checks:fix,
// fix, reviewOf): a phase reaching for grep/sed/cat to read a file, or Bash
// generally to search one, is the one habit worth naming once rather than
// repeating per prompt. Takes the worktree path as a parameter (every call
// site already has wt.path in scope) rather than leaving it implicit, so the
// same sentence that names the native tools also says where every one of
// those paths has to start.
const NATIVE_TOOLS = (worktreePath) =>
  `Use your native Read, Grep and Edit tools to read, search and edit files; ` +
  `Bash is for running things (tests, gates, git), never for reading code ` +
  `with grep, sed, or cat. Every Read, Grep and Edit path starts with ` +
  `${worktreePath}/, apart from the scratch path under the git directory ` +
  `given above.`

// Shared by every prompt that commits code (implement, checks:fix, fix):
// worded generically, since these prompts ship to other repos, not just
// this one -- whose own workflows/deliver-pipeline.js is itself exactly
// this kind of file.
const GENERATED_FILES =
  `A file the repo's AGENTS.md or its own header marks as built from parts ` +
  `(this plugin's workflows/deliver-pipeline.js is one) is never edited ` +
  `directly; edit its parts and run the build the repo names.`

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
  // No ceiling: it runs once, before any code exists, so tripping one here
  // would forfeit nothing but also bound nothing real.
  setup: null,
  triage: 15_000,
  branch: 10_000,
  plan: null,
  implement: null,
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
// Stages left open when a throw unwinds past their own close(): stage()
// records a start tick here, and close() deletes it again, so whatever
// remains when the run-budget catch (below) fires is the stage that was
// actually running at the halt, and its spend so far still belongs in
// stageSpend rather than being silently dropped from it.
const openStages = {}
// 'checks' is the one name stage() opens twice (the pre-Implement baseline,
// then the post-Implement run); by the time the second open reaches this
// function, stageSpend.checks already holds the first window's spend, and
// adding rather than overwriting is what keeps it instead of losing it to
// the second window's own delta -- the same fix-up every normal close site
// for 'checks' already does by hand with checksPreSpend.
const closeOpenStages = () => {
  const names = Object.keys(openStages)
  for (const name of names) {
    stageSpend[name] = (stageSpend[name] ?? 0) + (budget.spent() - openStages[name])
    delete openStages[name]
  }
  return names
}
const stage = (name) => {
  const start = budget.spent()
  openStages[name] = start
  const raw = CEILINGS[name]
  const cap = raw == null || EXPLICIT_BUDGETS.has(name)
    ? raw
    : Math.round(raw * ceilingScale)
  return {
    over: () => cap != null && budget.spent() - start > cap,
    close: () => {
      stageSpend[name] = budget.spent() - start
      delete openStages[name]
      log(`${name}: ${Math.round(stageSpend[name] / 1000)}k output tokens ` +
          (cap == null ? '(no ceiling)' : `(ceiling ${Math.round(cap / 1000)}k)`))
    },
  }
}

// Tracks which phase is actually running, so the run-budget catch (below)
// can name it in a halt without every call site passing its own phase name
// in. A thin wrapper over the runtime's own phase() rather than a replacement
// for it.
let currentPhase = null
const enterPhase = (name) => { currentPhase = name; phase(name) }

// The one choke point every agent dispatch passes through -- a static check
// in test-static.sh asserts `agent(` appears nowhere else -- so a run-wide
// token budget can refuse a call before it starts rather than merely notice
// after. runBudget stays null until Triage has sized the work (set in the
// Triage phase, below), so every dispatch before that -- setup, branch,
// branch:existing -- is unbounded by it: there is no code yet for a budget to
// bound.
let runBudget = null
let runBudgetNote = null
// Set only by a refused dispatch, read only by the top-level catch: its
// presence, not the thrown error's identity, is what tells that catch this
// throw was the budget's doing rather than a genuine failure to rethrow, since
// parallel() and other call sites can wrap or swallow the error itself.
let runBudgetSpent = null
// budget.spent() is not zero when a run starts (the host counts spend from
// before it: 4,634k on the first live run of this code, whose own stages had
// spent 14k), so the run budget, like every stage ceiling, is measured from
// this run's own start.
const runSpendStart = budget.spent()
const runSpent = () => budget.spent() - runSpendStart
const dispatch = async (prompt, opts) => {
  if (runBudget != null && runSpent() >= runBudget) {
    runBudgetSpent = { refused: opts.label, spent: runSpent() }
    throw new Error(
      `touchstone: run budget (${Math.round(runBudget / 1000)}k output ` +
      `tokens) spent before '${opts.label}' could dispatch`)
  }
  return await agent(prompt, opts)
}

// Set once the run has a PR, opened or adopted (Draft PR phase, part 40):
// { url, number, draft, readyWhy }. draft is the state the run last read, and
// readyWhy says why a ready PR could not be made a draft. Read by prNote() and
// halted(), which are defined before the phase that sets it.
let draftPr = null

// Set once the diffstat line (Review phase, part 40) has measured the
// real diff; null on every halt before that, and read unconditionally by
// halted() below so every halt from Review onward carries it without each
// call site having to pass it through `extra` by hand.
let size = null

// The change-risk signals measured over the implementer's range (part 40), null
// on every halt before the implementer has returned one and whenever the probe
// failed. Recorded only: nothing in the run reads it to decide anything.
let signals = null

// reportedHead() is reported as reviewed_through by every halt and the result: the
// last head a review finished at. Not reviewedThrough (part 50), which also
// moves past commits no review read, so the next run would skip them.
// reviewedHead is the last head a review in this run read up to; until one
// finishes, a resumed run reports the head of the record it was given.
//
// An --existing run starts holding that record (args.priorRun; the script has no
// fs), unverified: the invoking session writes every payload over the record
// file, so a halt before the ancestry check in part 20 (a dirty checkout, an
// oversized plan) would otherwise overwrite it with nothing. That check drops
// it when the head is not confirmed.
const asSha = (v) => typeof v === 'string' && /^[0-9a-f]{40}$/.test(v.trim()) ? v.trim() : null
const SCOPES = ['ticket', 'addition', 'unattributed']
const carry = (list) => (Array.isArray(list) ? list : [])
  .filter(f => typeof f?.id === 'string' && /^f\d+$/.test(f.id))
  .map(f => ({ ...f, scope: SCOPES.includes(f.scope) ? f.scope : 'unattributed' }))
const recordHead = args?.existingBranch ? asSha(args.priorRun?.reviewed_through) : null
let recordedHead = recordHead
let reviewedHead = null
const reportedHead = () => reviewedHead ?? recordedHead
// Where the first review range may start: the record's head, but only while
// nothing was merged after it (part 20). A merge leaves that head an ancestor,
// so the record still holds, but a range from it would carry the merged base's
// own changes.
let resumeFrom = null
let carriedOpen = recordHead ? carry(args.priorRun.unresolved_findings) : []
let carriedNotes = recordHead ? carry(args.priorRun.notes) : []

// executed never changes; base_branch and mismatch stay null until the
// merged setup call (before Worktree) has something to report, which is why
// a halt at Worktree carries the executed value with the other two still
// null. mismatch is null rather than false when the probe found no comparable
// manifest (found:false, or a different plugin's name) -- the ordinary case
// for every repo this runs against except touchstone's own, but it is logged
// too, distinct from a real mismatch. A probe that returns nothing at all
// leaves the same null/null pair, but is logged separately again, since that
// case means the comparison did not run, not that there was nothing to
// compare.
let pipelineVersion = { executed: PIPELINE_VERSION, base_branch: null, mismatch: null }

// Opening the draft is allowed to fail without ending the run, and an adopted
// PR that was already ready may not convert back, so a note that states one
// outcome flatly is wrong some of the time. Every halt note that mentions the
// PR reads this instead of asserting one.
const prNote = () => !draftPr
  ? `No PR was opened, because the draft could not be opened earlier in this run`
  : draftPr.draft
  ? `The PR was left as a draft`
  : `PR #${draftPr.number} read as ready for review, with commits the gates have not ` +
    `passed: it was ready when this run adopted it, and ${draftPr.readyWhy}`

// A halt is a result, not an absence of one, and the run record is where it
// survives the session. It used to be posted as a comment on the draft PR too.
// That put the run's internal state -- which phase stopped, which findings a
// lens raised -- on the repository's public record, where a reviewer cannot act
// on it and someone has to delete it by hand. Opening the PR is this workflow's
// only write to GitHub. record_file only names where the invoking session
// should write this payload (commands/deliver.md does that); the script has
// no fs and cannot write it itself. Not async: nothing here dispatches an
// agent, but every call site still says `return await` from when it did.
// Set once the plan is known, and once findings can exist. Both are read by
// halted(), which is defined long before either.
let planAdditions = null
let scopeSplit = () => null
const halted = async (at, extra) => {
  const split = scopeSplit()
  const payload = {
    task, halted_at: at, pipeline_version: pipelineVersion, stage_spend: stageSpend,
    needs_user: true, record_file: runRecordFile, size, signals,
    reviewed_through: reportedHead(),
    ...(carriedOpen.length ? { unresolved_findings: carriedOpen } : {}),
    ...(carriedNotes.length ? { notes: carriedNotes } : {}),
    ...(planAdditions ? { plan_additions: planAdditions } : {}),
    ...(split ? { scope_split: split } : {}),
    ...extra,
  }
  // A ready PR holding ungated commits is the one PR state a reviewer cannot
  // see from GitHub, so every halt says so, not only the notes that mention the PR.
  if (draftPr && !draftPr.draft && typeof payload.note === 'string' && !payload.note.includes(prNote())) {
    payload.note = `${payload.note} ${prNote()}.`
  }
  if (draftPr?.number) {
    log(`halt at ${at}: PR #${draftPr.number} left as it is ` +
        `(${draftPr.draft ? 'a draft' : 'ready for review'}); the reason is in ` +
        `this run's result and record`)
  }
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
             'task_demands_implementation', 'additions'],
  properties: {
    plan: { type: 'string' },
    // Work the plan believes the ticket needs but does not ask for, kept out
    // of `plan` so it reaches the implementer and reviewers as a decision
    // rather than an unmarked line. Two runs grew this way, and every finding
    // left at their halts was in the part nobody asked for.
    additions: {
      type: 'array',
      items: {
        type: 'object', additionalProperties: false, required: ['item', 'consequence'],
        properties: { item: { type: 'string' }, consequence: { type: 'string' } },
      },
    },
    acceptance_criteria: { type: 'array', items: { type: 'string' } },
    risky_areas: { type: 'array', items: { type: 'string' } },
    task_demands_implementation: { type: 'boolean' },
    conflict_note: { type: 'string' },
  },
}
// Discovery source: AGENTS.md/CLAUDE.md read from the worktree, not the
// --git-common-dir root the merged setup call resolves the gate markers
// from -- a check list is branch content the ticket can change, while the
// gate markers are repo-wide policy no phase of this run writes. The agent
// transcribes every "##" heading and the first fenced block under it
// verbatim, marker lines included, choosing and interpreting nothing.
// Selecting the check heading, dropping the fence's own marker lines,
// splitting the rest and assigning ids is script code (checksFrom below): a
// check list runs again after every step that commits, so what runs must
// come from parsing, never a model's account of it. Declared before BRANCH,
// which embeds it as checks_source, since a const cannot be read before its
// own declaration.
const CHECKS = {
  type: 'object', additionalProperties: false, required: ['file', 'sections', 'detail'],
  properties: {
    file: { type: 'string' },
    sections: {
      type: 'array',
      items: {
        type: 'object', additionalProperties: false, required: ['heading', 'fence'],
        properties: { heading: { type: 'string' }, fence: { type: 'string' } },
      },
    },
    detail: { type: 'string' },
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
    // Optional: only meaningful when created=true, the one case where a
    // worktree exists to read AGENTS.md/CLAUDE.md out of. checksFrom() reads
    // this instead of a separate checks:discover call, since the branch
    // agent already has the worktree open by the time it can answer.
    checks_source: CHECKS,
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
    // Optional: asked for only when a prior reviewed head was passed in.
    prior_head_check: { type: 'string' },
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

// What a checks:run agent returns: the lines the runner printed, copied back
// whole. A check's own output never passes through it. The shell writes each
// check's output to a log file under the worktree's git dir and prints one line
// per check plus an end line (runnerLinesFor); parseCheckRun below reads those
// lines strictly or not at all, so what a model relays can be wrong only in
// ways the parser sees.
const CHECK_RUN = {
  type: 'object', additionalProperties: false, required: ['output'],
  properties: { output: { type: 'string' } },
}
const CHECK_END_PREFIX = 'TOUCHSTONE_CHECKS_END'
const CHECK_END_LINE = /^TOUCHSTONE_CHECKS_END (\S+) (clean|dirty) (\d+)[ \t]+(\d+)$/
// The script has no Buffer or TextEncoder, so text reaches cksum and base64
// as UTF-8 bytes through this.
const utf8Bytes = (s) => {
  const out = []
  for (const ch of String(s)) {
    let cp = ch.codePointAt(0)
    // A lone surrogate is not text; encode it as U+FFFD, as every UTF-8 encoder does.
    if (cp >= 0xd800 && cp <= 0xdfff) cp = 0xfffd
    if (cp < 0x80) out.push(cp)
    else if (cp < 0x800) out.push(0xc0 | cp >> 6, 0x80 | cp & 0x3f)
    else if (cp < 0x10000) out.push(0xe0 | cp >> 12, 0x80 | cp >> 6 & 0x3f, 0x80 | cp & 0x3f)
    else out.push(0xf0 | cp >> 18, 0x80 | cp >> 12 & 0x3f, 0x80 | cp >> 6 & 0x3f, 0x80 | cp & 0x3f)
  }
  return out
}
// POSIX cksum: a 32-bit CRC, polynomial 0x04C11DB7, MSB first, over the bytes
// and then the byte count (least significant byte first, as few bytes as it
// needs), complemented. Printed as `cksum` prints it: "<crc> <bytes>".
const CKSUM_TABLE = Array.from({ length: 256 }, (_, i) => {
  let c = i << 24
  for (let k = 0; k < 8; k++) c = c & 0x80000000 ? (c << 1) ^ 0x04c11db7 : c << 1
  return c >>> 0
})
const cksum = (s) => {
  const bytes = utf8Bytes(s)
  let crc = 0
  const add = (b) => { crc = ((crc << 8) ^ CKSUM_TABLE[((crc >>> 24) ^ b) & 0xff]) >>> 0 }
  bytes.forEach(add)
  for (let n = bytes.length; n > 0; n = Math.floor(n / 256)) add(n & 0xff)
  return `${(~crc) >>> 0} ${bytes.length}`
}
const BASE64_ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
const base64Of = (s) => {
  const b = utf8Bytes(s)
  let out = ''
  for (let i = 0; i < b.length; i += 3) {
    const n = (b[i] << 16) | ((b[i + 1] ?? 0) << 8) | (b[i + 2] ?? 0)
    out += BASE64_ALPHABET[n >> 18 & 63] + BASE64_ALPHABET[n >> 12 & 63] +
      (i + 1 < b.length ? BASE64_ALPHABET[n >> 6 & 63] : '=') +
      (i + 2 < b.length ? BASE64_ALPHABET[n & 63] : '=')
  }
  return out
}
// Every row line also appends the row it printed to <run dir>/rows, and the
// end line prints that file's cksum. A row copied with a slip was never written
// there, so the sums differ. It detects slips, not a model set on forging: one
// with a Bash tool can compute a matching sum itself. The rows are the
// lines the parser accepted, joined as the shell wrote them.
const ROWS_SUM_REASON = 'rows checksum does not match what the runner wrote'
const rowsSumMatches = (rows, sum) =>
  cksum(rows.length ? `${rows.map(r => r.line).join('\n')}\n` : '') === sum
const CHECK_ROW_LINE = /^TOUCHSTONE_CHECK (\S+) (\S+) (.+)$/
// The end line closes the batch: it names this run and says whether the tree
// was dirty once every check had run. It must be the last line and the only one.
const parseCheckEnd = (lines, run, prefix = CHECK_END_PREFIX, pattern = CHECK_END_LINE) => {
  const ends = lines.filter(l => l.startsWith(prefix))
  if (!ends.length) return { reason: 'no end line' }
  if (ends.length > 1) return { reason: 'end line repeated' }
  if (lines[lines.length - 1] !== ends[0]) return { reason: 'end line is not last' }
  const m = pattern.exec(ends[0])
  if (!m) return { reason: 'malformed end line' }
  if (m[1] !== run) return { reason: `end line names run ${m[1]}, not ${run}` }
  return { dirty: m[2] === 'dirty', sum: `${Number(m[3])} ${Number(m[4])}`, path: m[5] }
}
// One check line, read against the rows already accepted: the next row has to
// be the next discovered check, and its log has to be where this run puts it.
const parseCheckRow = (line, checks, rows, run) => {
  if (!line.startsWith('TOUCHSTONE_CHECK ')) {
    return { reason: `unexpected line ${JSON.stringify(line.slice(0, 80))}` }
  }
  const m = CHECK_ROW_LINE.exec(line)
  if (!m) return { reason: 'malformed check line' }
  const [, id, exit, log] = m
  if (rows.some(r => r.id === id)) return { reason: `${id} reported twice` }
  if (!checks.some(c => c.id === id)) return { reason: `unexpected id ${id}` }
  const want = checks[rows.length].id
  if (id !== want) return { reason: `${id} reported where ${want} was expected` }
  if (!/^\d+$/.test(exit)) return { reason: `exit of ${id} is not an integer` }
  if (!log.startsWith('/') || !log.endsWith(`/touchstone-checks/${run}/${id}.log`)) {
    return { reason: `log path of ${id} is not under this run` }
  }
  return { row: { id, exit: Number(exit), log, line } }
}
// Pure, like parseDiffstat: reads only the shape of what the runner printed,
// never a model's account of it. Every discovered id has to appear exactly
// once, in order, with an integer exit and its own log path, and the end line
// has to come last. Anything else is not a partial result: the whole batch is
// unmeasured, with the first reason found, because a reply that is wrong
// anywhere cannot be trusted anywhere. checks is never empty here.
const runnerLinesOf = (output) =>
  String(output ?? '').split(/\r?\n/).map(l => l.trimEnd()).filter(l => l !== '')
const dirOf = (p) => p.slice(0, p.lastIndexOf('/'))
const parseCheckRun = (output, checks, run) => {
  const lines = runnerLinesOf(output)
  if (!lines.length) return { reason: 'no output' }
  const end = parseCheckEnd(lines, run)
  if (end.reason) return end
  const rows = []
  for (const line of lines.slice(0, -1)) {
    const parsed = parseCheckRow(line, checks, rows, run)
    if (parsed.reason) return parsed
    rows.push(parsed.row)
  }
  if (rows.length < checks.length) return { reason: `no line for ${checks[rows.length].id}` }
  // One runner writes every log of a run into one directory; a row elsewhere
  // was not printed by that runner.
  const dir = dirOf(rows[0].log)
  const stray = rows.find(r => dirOf(r.log) !== dir)
  if (stray) return { reason: `log path of ${stray.id} is not in the run directory` }
  if (!rowsSumMatches(rows, end.sum)) return { reason: ROWS_SUM_REASON }
  return { rows, dirty: end.dirty, statusLog: `${dir}/status.log` }
}

// What a reproduce:* agent returns, read the same way as CHECK_RUN: the lines
// the runner printed (reproLinesFor in 50-classify-fix.js.part), copied back
// whole. No reproducer's output, exit code or porcelain passes through a model.
const REPRO_RUN = {
  type: 'object', additionalProperties: false, required: ['output'],
  properties: { output: { type: 'string' } },
}
const REPRO_BEFORE_PREFIX = 'TOUCHSTONE_REPRO_BEFORE'
const REPRO_BEFORE_LINE = /^TOUCHSTONE_REPRO_BEFORE (\S+) (clean|dirty)$/
const REPRO_ROW_PREFIX = 'TOUCHSTONE_REPRO '
const REPRO_ROW_LINE = /^TOUCHSTONE_REPRO (\S+) (\S+) (\S+) (.+)$/
// The end line carries the status log's path, unlike the checks end line,
// because a call that runs no reproducer (the mutation-hunk fetch) has no row
// to read the run directory from, and a dirty tree's halt has to name it.
const REPRO_END_PREFIX = 'TOUCHSTONE_REPRO_END'
const REPRO_END_LINE = /^TOUCHSTONE_REPRO_END (\S+) (clean|dirty) (\d+)[ \t]+(\d+) (.+)$/
const HUNKS_PREFIX = 'TOUCHSTONE_HUNKS_'
const HUNKS_BEGIN_PREFIX = 'TOUCHSTONE_HUNKS_BEGIN'
const HUNKS_FAILED_PREFIX = 'TOUCHSTONE_HUNKS_FAILED'
const HUNKS_FAILED_LINE = /^TOUCHSTONE_HUNKS_FAILED (\S+) (\d+)$/
const HUNKS_BEGIN_LINE = /^TOUCHSTONE_HUNKS_BEGIN (\S+)$/
const HUNKS_END_PREFIX = 'TOUCHSTONE_HUNKS_END'
const HUNKS_END_LINE = /^TOUCHSTONE_HUNKS_END (\S+) (\S+)$/
const underRun = (p, run, name) => p.startsWith('/') && p.endsWith(`/touchstone-repro/${run}/${name}`)
const parseReproRow = (line, ids, rows, run) => {
  if (!line.startsWith(REPRO_ROW_PREFIX)) {
    return { reason: `unexpected line ${JSON.stringify(line.slice(0, 80))}` }
  }
  const m = REPRO_ROW_LINE.exec(line)
  if (!m) return { reason: 'malformed reproducer line' }
  const [, id, exit, marker, log] = m
  if (rows.some(r => r.id === id)) return { reason: `${id} reported twice` }
  if (!ids.includes(id)) return { reason: `unexpected id ${id}` }
  const want = ids[rows.length]
  if (id !== want) return { reason: `${id} reported where ${want} was expected` }
  if (!/^\d+$/.test(exit)) return { reason: `exit of ${id} is not an integer` }
  if (marker !== '0' && marker !== '1') return { reason: `marker of ${id} is not 0 or 1` }
  if (!underRun(log, run, `${id}.log`)) return { reason: `log path of ${id} is not under this run` }
  return { row: { id, exit: Number(exit), reproduced: marker === '1', log, line } }
}
// The block between the begin and end lines is the kept diff header lines,
// and the end line's count, computed by the shell, has to match them. A failed
// line in its place says git diff itself exited nonzero: the hunks are
// unknown, and nothing else about the run is in doubt.
const parseHunksBlock = (body, i, run) => {
  if (i < body.length && body[i].startsWith(HUNKS_FAILED_PREFIX)) {
    const failed = HUNKS_FAILED_LINE.exec(body[i])
    if (!failed) return { reason: 'malformed hunks failed line' }
    if (failed[1] !== run) return { reason: `hunks failed line names run ${failed[1]}, not ${run}` }
    return { hunkLines: null, diffExit: Number(failed[2]), next: i + 1 }
  }
  if (i >= body.length || !body[i].startsWith(HUNKS_BEGIN_PREFIX)) return { reason: 'no hunks block' }
  const begin = HUNKS_BEGIN_LINE.exec(body[i])
  if (!begin) return { reason: 'malformed hunks begin line' }
  if (begin[1] !== run) return { reason: `hunks block names run ${begin[1]}, not ${run}` }
  const j = body.findIndex((l, k) => k > i && l.startsWith(HUNKS_END_PREFIX))
  if (j < 0) return { reason: 'no hunks end line' }
  const kept = body.slice(i + 1, j)
  const stray = kept.find(l => !l.startsWith('+++ ') && !l.startsWith('@@ '))
  if (stray !== undefined) return { reason: `unexpected hunk line ${JSON.stringify(stray.slice(0, 80))}` }
  const end = HUNKS_END_LINE.exec(body[j])
  if (!end || !/^\d+$/.test(end[2])) return { reason: 'malformed hunks end line' }
  if (end[1] !== run) return { reason: `hunks end line names run ${end[1]}, not ${run}` }
  if (Number(end[2]) !== kept.length) {
    return { reason: `hunks count ${end[2]} does not match ${kept.length} line(s)` }
  }
  return { hunkLines: kept, next: j + 1 }
}
// Pure, like parseCheckRun: the before line first, one row per runnable id in
// order, the hunks block when a range was asked for, the end line last, and
// every log in this run's one directory. Anything else is not a partial
// result: the whole run is unmeasured, with the first reason found.
const parseReproRun = (output, ids, run, withHunks) => {
  const lines = runnerLinesOf(output)
  if (!lines.length) return { reason: 'no output' }
  if (!lines[0].startsWith(REPRO_BEFORE_PREFIX)) return { reason: 'no before line' }
  const before = REPRO_BEFORE_LINE.exec(lines[0])
  if (!before) return { reason: 'malformed before line' }
  if (before[1] !== run) return { reason: `before line names run ${before[1]}, not ${run}` }
  const end = parseCheckEnd(lines, run, REPRO_END_PREFIX, REPRO_END_LINE)
  if (end.reason) return end
  const body = lines.slice(1, -1)
  const rows = []
  let i = 0
  for (; i < body.length && !body[i].startsWith(HUNKS_PREFIX); i++) {
    const parsed = parseReproRow(body[i], ids, rows, run)
    if (parsed.reason) return parsed
    rows.push(parsed.row)
  }
  if (rows.length < ids.length) return { reason: `no line for ${ids[rows.length]}` }
  let hunkLines = null
  let diffExit
  if (withHunks) {
    const block = parseHunksBlock(body, i, run)
    if (block.reason) return block
    ;({ hunkLines, diffExit, next: i } = block)
  }
  if (i < body.length) return { reason: `unexpected line ${JSON.stringify(body[i].slice(0, 80))}` }
  const dir = dirOf(end.path)
  if (!underRun(end.path, run, 'status.log')) return { reason: 'status log is not in the run directory' }
  const stray = rows.find(r => dirOf(r.log) !== dir)
  if (stray) return { reason: `log path of ${stray.id} is not in the run directory` }
  if (!rowsSumMatches(rows, end.sum)) return { reason: ROWS_SUM_REASON }
  return { rows, before: before[2] === 'dirty', dirty: end.dirty, statusLog: end.path, hunkLines, diffExit }
}

// What a one-line relay returns (mutation-verify, pr-unreviewed in
// 60-mutation-pr.js.part; pr:state, pr:undo, pr:push and diffstat in
// 40-implement-draft-review.js.part): what its script-built command printed.
const VERDICT_RUN = {
  type: 'object', additionalProperties: false, required: ['output'],
  properties: { output: { type: 'string' } },
}
const COMMIT_TOKEN = /^[0-9a-f]{40}$/
const oneLineOf = (output) => {
  const lines = runnerLinesOf(output)
  if (!lines.length) return { reason: 'no output' }
  if (lines.length > 1) return { reason: `${lines.length} lines where one was expected` }
  return { line: lines[0] }
}
const MUTATION_VERIFY_LINE = /^TOUCHSTONE_MUTATION_VERIFY (\S+) (\S+) (\S+) (\S+) (.+)$/
// The real mutation-check.sh ends every run past its own setup with
// `mutation-check: EXIT=<n> ...`, so a 0 or a 5 without that trailer, or with
// a different number, came from something else: a substituted `true`, another
// script. A setup exit (127 not found, 2 before the trailer trap is set) may
// carry none and is still a verdict about the gate.
const trailerProblem = (exit, trailer) => {
  if (trailer === '-') return exit === 0 || exit === 5 ? `exit ${exit} with no gate trailer in the log` : null
  if (!/^\d+$/.test(trailer)) return 'trailer is not an integer'
  return Number(trailer) === exit ? null : `gate trailer says EXIT=${trailer}, the shell says ${exit}`
}
const parseMutationVerify = (output, run) => {
  const { line, reason } = oneLineOf(output)
  if (reason) return { reason }
  const m = MUTATION_VERIFY_LINE.exec(line)
  if (!m) return { reason: 'malformed verdict line' }
  const [, r, exit, trailer, head, log] = m
  if (r !== run) return { reason: `verdict line names run ${r}, not ${run}` }
  if (!/^\d+$/.test(exit)) return { reason: 'exit is not an integer' }
  const mismatch = trailerProblem(Number(exit), trailer)
  if (mismatch) return { reason: mismatch }
  if (!COMMIT_TOKEN.test(head)) return { reason: 'head is not a commit id' }
  if (!log.startsWith('/') || !log.endsWith(`/touchstone-gates/${run}/mutation-verify.log`)) {
    return { reason: 'log path is not under this run' }
  }
  return { exit: Number(exit), head, log }
}
const UNREVIEWED_LINE = /^TOUCHSTONE_UNREVIEWED (\S+) (\S+) (\S+)$/
const parseUnreviewed = (output, from) => {
  const { line, reason } = oneLineOf(output)
  if (reason) return { reason }
  const m = UNREVIEWED_LINE.exec(line)
  if (!m) return { reason: 'malformed count line' }
  const [, f, count, head] = m
  if (f !== from) return { reason: `count line starts at ${f}, not ${from}` }
  if (!/^\d+$/.test(count)) return { reason: 'count is not an integer' }
  if (!COMMIT_TOKEN.test(head)) return { reason: 'head is not a commit id' }
  return { count: Number(count), head }
}
// The branch's PR as gh reported it, and whether its head is an ancestor of
// the branch head, which the shell decides (prStateLine in part 40). No PR,
// or gh failing, prints none in every field.
const PR_STATE_LINE = /^TOUCHSTONE_PR (\S+) (\S+) (\S+) (\S+) (\S+) (\S+)$/
const PR_STATES = ['OPEN', 'CLOSED', 'MERGED']
const parsePrState = (output, branch) => {
  const { line, reason } = oneLineOf(output)
  if (reason) return { reason }
  const m = PR_STATE_LINE.exec(line)
  if (!m) return { reason: 'malformed PR line' }
  const [, b, number, state, isDraft, head, ancestor] = m
  if (b !== branch) return { reason: `PR line names branch ${b}, not ${branch}` }
  if (number === 'none') {
    return [state, isDraft, head, ancestor].join(' ') === 'none none none 0'
      ? { number: null } : { reason: 'PR line says none but carries PR fields' }
  }
  if (!/^[1-9]\d*$/.test(number)) return { reason: 'PR number is not an integer' }
  if (!PR_STATES.includes(state)) return { reason: `unknown PR state ${state}` }
  if (isDraft !== 'true' && isDraft !== 'false') return { reason: 'isDraft is not true or false' }
  if (!COMMIT_TOKEN.test(head)) return { reason: 'PR head is not a commit id' }
  if (ancestor !== '0' && ancestor !== '1') return { reason: 'ancestor is not 0 or 1' }
  return { number: Number(number), state, draft: isDraft === 'true', head, ancestor: ancestor === '1' }
}
const underPrRun = (p, run, name) => p.startsWith('/') && p.endsWith(`/touchstone-pr/${run}/${name}`)
// isDraft is what gh reported after the undo, none when it reported nothing.
const PR_UNDO_LINE = /^TOUCHSTONE_PR_UNDO (\S+) (\S+) (\S+) (.+)$/
const parsePrUndo = (output, number, run) => {
  const { line, reason } = oneLineOf(output)
  if (reason) return { reason }
  const m = PR_UNDO_LINE.exec(line)
  if (!m) return { reason: 'malformed undo line' }
  const [, n, exit, isDraft, log] = m
  if (n !== String(number)) return { reason: `undo line names PR ${n}, not ${number}` }
  if (!/^\d+$/.test(exit)) return { reason: 'exit is not an integer' }
  if (!['true', 'false', 'none'].includes(isDraft)) return { reason: 'isDraft is not true, false or none' }
  if (!underPrRun(log, run, 'pr-undo.log')) return { reason: 'log path is not under this run' }
  return { exit: Number(exit), draft: isDraft === 'true', log }
}
const PUSH_LINE = /^TOUCHSTONE_PUSH (\S+) (\S+) (.+)$/
const parsePush = (output, branch, run) => {
  const { line, reason } = oneLineOf(output)
  if (reason) return { reason }
  const m = PUSH_LINE.exec(line)
  if (!m) return { reason: 'malformed push line' }
  const [, b, exit, log] = m
  if (b !== branch) return { reason: `push line names branch ${b}, not ${branch}` }
  if (!/^\d+$/.test(exit)) return { reason: 'exit is not an integer' }
  if (!underPrRun(log, run, 'push.log')) return { reason: 'log path is not under this run' }
  return { exit: Number(exit), log }
}
// The only heading that is a check list. Only trailing whitespace is
// ignored: '## checks', '### Checks', '##Checks', '## Checks ##' and
// '## Commands' all name something else and must never match, because a
// check here runs as a baseline before Implement and again after every step
// that commits, so listing it must be a deliberate, exact choice, not a
// heading that merely resembles it.
const CHECKS_HEADING = '## Checks'
// Run once before the PR and reported there as notes, never blocking: a
// check that can be wrong about good code must not send a fixer after it.
const ADVISORY_CHECKS_HEADING = '## Advisory checks'

// Strips an unquoted '#' at the start of a line or after whitespace, and
// everything after it. Tracks single and double quotes only, with no
// backslash handling: the fence holds one shell command per line, not a
// string this needs to fully parse, and a quoted '#' is the one case where
// stripping would silently corrupt a command's own argument.
function stripComment(line) {
  let quote = null
  for (let i = 0; i < line.length; i++) {
    const ch = line[i]
    if (quote) {
      if (ch === quote) quote = null
      continue
    }
    if (ch === '"' || ch === "'") { quote = ch; continue }
    if (ch === '#' && (i === 0 || /\s/.test(line[i - 1]))) return line.slice(0, i)
  }
  return line
}

// Turns a transcribed CHECKS response into the ordered, id-keyed list every
// later phase runs against, plus a note for when there is nothing to run.
// Duplicate commands stay separate entries -- checksFrom assigns by
// position, never dedupes -- because two identical lines is the repo saying
// to run the command twice, not a transcription accident to collapse.
function checksFrom(source, heading = CHECKS_HEADING, idPrefix = 'check') {
  if (!source) {
    return { checks: [], note: 'discovery returned nothing' }
  }
  const file = source.file ?? ''
  if (!file) {
    return { checks: [], note: 'neither AGENTS.md nor CLAUDE.md exists at the worktree root' }
  }
  const sections = Array.isArray(source?.sections) ? source.sections : []
  const section = sections.find(s => s?.heading?.trimEnd() === heading)
  if (!section) {
    const hasCommands = sections.some(s => /^##\s+commands\s*$/i.test(s?.heading?.trimEnd() ?? ''))
    return {
      checks: [],
      note: `${file} has no '${heading}' heading` +
        (hasCommands
          ? `; ${file} has a ## Commands heading, which is no longer read as ` +
            `checks. Only an exact ${CHECKS_HEADING} heading is, because every ` +
            `line there is executed before this run's own work and again after ` +
            `it, so it must list only read-only, deterministic checks.`
          : '.'),
    }
  }
  // The agent transcribes the fence with its own opening and closing marker
  // lines (``` or ~~~, info string included), because "the contents between
  // the markers" is ambiguous about whether an info string like `bash` on
  // the opening line counts -- a literal reading would surface it as a
  // spurious first command. Drop it here, where the marker regex is one
  // rule applied once, rather than in the prompt. A fence transcribed
  // without markers (or with only one) is unaffected: dropping is
  // conditional on the line actually being a marker.
  const fenceLines = (section.fence ?? '').split(/\r?\n/)
  // A newline outside the fence, before the opening marker or after the
  // closing one, fills the exact slot the marker check below looks at.
  while (fenceLines.length && fenceLines[0].trim() === '') fenceLines.shift()
  while (fenceLines.length && fenceLines[fenceLines.length - 1].trim() === '') fenceLines.pop()
  const isFenceMarker = (l) => /^\s*(`{3,}|~{3,})/.test(l)
  if (fenceLines.length && isFenceMarker(fenceLines[0])) fenceLines.shift()
  if (fenceLines.length && isFenceMarker(fenceLines[fenceLines.length - 1])) fenceLines.pop()
  const commands = fenceLines
    .map(stripComment).map(l => l.trim()).filter(l => l.length > 0)
  if (!commands.length) {
    return { checks: [], note: `${file}'s '${heading}' section has no fence, or no command lines in it` }
  }
  return { checks: commands.map((command, i) => ({ id: `${idPrefix}:${i + 1}`, command })), note: '' }
}

const TRIAGE = {
  type: 'object', additionalProperties: false,
  required: ['scope', 'complexity', 'expected_files', 'complexity_note', 'premise_ok',
             'evidence', 'premise_note'],
  properties: {
    scope: { type: 'string', enum: ['inline', 'team'] },
    // Judgement, not arithmetic. A line count is a proxy for risk and a poor
    // one: five lines in a signing path are harder than two hundred in a test
    // file. Triage has already read the ticket and the code by the time it
    // answers, so it is the right place to say how hard this is, and the only
    // place that knows before anything expensive runs.
    complexity: { type: 'string', enum: ['trivial', 'routine', 'involved'] },
    // Required, unlike expected_call_sites and involved_reason below: every
    // verdict names what it expects the change to touch, but only an
    // involved one has to explain why that is hard rather than routine.
    expected_files: { type: 'array', items: { type: 'string' } },
    complexity_note: { type: 'string' },
    // Optional: only an involved verdict needs either. A missing one demotes
    // involved to routine in the script (see the complexity block below),
    // never the other way, so leaving them out on a trivial or routine
    // verdict costs nothing.
    expected_call_sites: { type: 'array', items: { type: 'string' } },
    involved_reason: { type: 'string' },
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
// is a fact rather than the implementer's account of itself. insertions is
// gone: it described the implementer's own commits and went stale the
// moment a pre-review checks fix landed after them; the diffstat probe
// (part 40, `size` in the result) replaces it with a real, measured count.
const IMPL = {
  type: 'object', additionalProperties: false,
  required: ['summary', 'files_changed', 'commit_range', 'scored', 'plan_id'],
  properties: {
    summary: { type: 'string' },
    files_changed: { type: 'array', items: { type: 'string' } },
    commit_range: { type: 'string' },
    scored: { type: 'boolean' },
    gate_note: { type: 'string' },
    // The id on the plan file's last line: returning it proves the whole file
    // was read.
    plan_id: { type: 'string' },
    // Set when the one halt this phase can hit -- a NEXT_ACTION of
    // UNSUPPORTED_LANGUAGE -- fires. Without a schema field for it, the phase
    // has no way to represent a halt at all: it would return a normal result
    // and the run would sail on through Draft PR, Review, Fix and Mutation
    // with the refused work never committed.
    unsupported_language: { type: 'boolean' },
  },
}
const PLAN_WRITE = {
  type: 'object', additionalProperties: false,
  required: ['digest', 'last_line', 'ignored_exit'],
  properties: {
    digest: { type: 'string' },
    last_line: { type: 'string' },
    ignored_exit: { type: 'integer' },
  },
}
const PLAN_LEAK_PROBE = {
  type: 'object', additionalProperties: false, required: ['output'],
  properties: { output: { type: 'string' } },
}
const HEAD_CHECK_PROBE = {
  type: 'object', additionalProperties: false, required: ['output'],
  properties: { output: { type: 'string' } },
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
// Closed set a finding's category must come from. Only the four in
// BLOCKING_CATEGORIES can hold a run; the rest still reach the PR, as a note.
const CATEGORIES = ['wrong-result', 'crash', 'gate-bypass', 'unmet-criterion',
                     'docs', 'wording', 'design', 'scope', 'other']
// Read only by the script -- classify() below -- never by a prompt: a
// reviewer's own severity judgement is exactly what this ticket stops
// trusting.
const BLOCKING_CATEGORIES = new Set(['wrong-result', 'crash', 'gate-bypass', 'unmet-criterion'])
// A lens returning unbounded findings can null its whole result on a
// maxItems failure; reviewOf slices to this many itself instead, most
// serious first, and logs what it dropped.
const MAX_FINDINGS_PER_LENS = 5
// One command, run from the worktree root: exits 0 when the code is correct.
// A nonzero exit only counts as a demonstration when the reproducer's own
// output also carries REPRODUCED_MARKER on a line of its own; nonzero without
// it means the command itself failed to run, not that it showed the defect.
// expected/actual hold what it prints. The script decides on the exit code
// and marker flag the shell printed, never on a model's account of them --
// the same principle as CHECK_RUN above.
const REPRODUCER = {
  type: 'object', additionalProperties: false,
  required: ['kind', 'command', 'expected', 'actual'],
  properties: {
    kind: { type: 'string', enum: ['test', 'command'] },
    command: { type: 'string' }, expected: { type: 'string' }, actual: { type: 'string' },
  },
}
// Printed by a reproducer on a line of its own when, and only when, it has
// observed the defect. The runner's grep matches it whole-line (surrounding
// whitespace, a CR included, allowed), never as a substring: a `set -x` echo
// of this same text, or a stack-trace source line that happens to mention it,
// must not pass as a demonstration.
const REPRODUCED_MARKER = 'TOUCHSTONE_DEFECT_REPRODUCED'
// The one place that turns a runner row into what it actually showed. The
// marker flag was decided by the shell against the whole log, so a long
// output can never cut the marker off.
const outcomeOf = (row) => {
  if (!row) return 'not-executed'
  if (row.exit_code === 0) return 'passed'
  if (row.exit_code === 126 || row.exit_code === 127) return 'could-not-run'
  return row.reproduced ? 'reproduced' : 'errored'
}
const FINDINGS = {
  type: 'object', additionalProperties: false, required: ['findings'],
  properties: {
    findings: {
      type: 'array',
      items: {
        type: 'object', additionalProperties: false,
        required: ['category', 'title', 'file', 'claim', 'evidence'],
        properties: {
          category: { type: 'string', enum: CATEGORIES },
          title: { type: 'string' }, file: { type: 'string' },
          claim: { type: 'string' }, evidence: { type: 'string' },
          // Optional: a deletion or a repo-wide pattern has no single span,
          // and schema validation must not fail a lens over that.
          line_start: { type: 'integer' }, line_end: { type: 'integer' },
          // An id copied from reviewOf's `known` list, never invented. Each
          // call site states what a reference there means.
          duplicate_of: { type: 'string' },
          // Only a blocking-category finding needs one; classify() below
          // treats an incomplete one the same as none at all.
          reproducer: REPRODUCER,
          // unmet-criterion only: copied verbatim from the ticket text, so
          // the script can check it is actually there rather than trusting
          // the claim.
          criterion_quote: { type: 'string' },
          // Asked for only when the plan has additions; reviewOf overwrites it
          // with what the script can stand behind.
          scope: { type: 'string', enum: ['ticket', 'addition'] },
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

const MANIFEST_PROBE = {
  type: 'object', additionalProperties: false,
  required: ['found', 'refreshed', 'name', 'version', 'detail'],
  properties: {
    found: { type: 'boolean' },
    refreshed: { type: 'boolean' },
    name: { type: 'string' },
    version: { type: 'string' },
    detail: { type: 'string' },
  },
}

// One dispatch answering three unrelated questions before a worktree exists:
// the ticket's own text, the repo's base-branch manifest, and its two gate
// markers. Each sub-object keeps its own found/false fallback, so a model
// that could not resolve one of the three still returns valid JSON for the
// other two, rather than the whole call failing schema together.
const SETUP = {
  type: 'object', additionalProperties: false,
  required: ['ticket', 'version', 'markers'],
  properties: {
    ticket: TICKET,
    version: MANIFEST_PROBE,
    markers: MARKERS,
  },
}

// Worktree before triage, not just before planning. Triage often routes small
// work back to be done inline, and that work still needs to land somewhere
// named: without the jira-/gh- marker the session is reported untracked
// forever. Creating the worktree first means inline work happens in the right
// place too. The cost is one unused worktree when triage rejects the premise.

// A supplied plan is held to the same limit as a planner's, but there is no
// planner to send it back to, so it halts rather than being tightened. Checked
// before anything is dispatched: the verdict needs nothing from setup, branch
// or triage, and a run that is going to halt should not pay for them first.
const givenPlan = typeof args?.plan === 'string' && args.plan.trim()
  ? args.plan.trim() : null
if (givenPlan && givenPlan.length > PLAN_MAX_CHARS) {
  enterPhase('Plan')
  return await halted('Plan', {
    plan: givenPlan,
    note: `args.plan is ${givenPlan.length} chars, over the ${PLAN_MAX_CHARS} limit. ` +
      `It was not retried: nothing tightens a supplied plan. The ticket may need ` +
      `splitting. The run stopped before any agent ran: no worktree, branch, ` +
      `triage or plan file.`,
  })
}

// One dispatch, before anything reads the envelope, answering three questions
// that share nothing but their timing: none needs a worktree, and each used
// to cost its own haiku round trip (ticket, plugin:version, gate:opt-in). Not
// a treeAgent -- there is no worktree yet, so every git command below
// resolves the repo root itself (dirname of --git-common-dir) rather than
// being pointed at one, and the prompt never names wt.base or baseOverride,
// both unset at this point regardless. Its only write is the one
// `git fetch origin <base>` the version check needs.
const sSetup = stage('setup')
const setupResult = await dispatch(
  `[touchstone: setup]\n` +
  `Gather three unrelated facts, then STOP. Do not plan, implement, branch, ` +
  `commit, or comment on anything.\n\n` +
  `1. TICKET. A key like PROJ-4821 or ABC-36 is a Jira issue: read it with ` +
  `the Atlassian tools, which you can find via ToolSearch. A bare number ` +
  `like 216 is a GitHub issue in the repo you are currently in: read it ` +
  `with gh issue view <number> --json title,body,comments. Fetch ticket ` +
  `${ticket}. Return ticket.found=true with ticket.summary (the title), ` +
  `ticket.description, and ticket.comments (concatenated, newest last, ` +
  `each prefixed with its author; empty string if none). Return ` +
  `ticket.found=false with empty strings if the ticket cannot be read at ` +
  `all: say why in ticket.summary. Do not invent or infer any field.\n\n` +
  `2. VERSION. Find the repo root: dirname "$(git rev-parse ` +
  `--path-format=absolute --git-common-dir)". Resolve the repo's actual ` +
  `base branch: git -C <repo root> symbolic-ref --short refs/remotes/` +
  `origin/HEAD, which prints an origin/-prefixed name; strip that prefix, ` +
  `falling back to whichever of main or master exists when there is no ` +
  `remote-tracking HEAD. Then run git -C <repo root> fetch origin <that ` +
  `base> to refresh the remote-tracking ref before reading it -- this ` +
  `checkout can be sessions old. If that fetch fails (no network, no auth, ` +
  `a remote needing a hardware key), that is not by itself a missing ` +
  `manifest: origin/<that base> can already hold it from an earlier fetch ` +
  `or the initial clone, so read it anyway. Then read git -C <repo root> ` +
  `show origin/<that base>:.claude-plugin/plugin.json. This fetch is the ` +
  `only change to make anywhere in this task; do not touch a working tree, ` +
  `commit, or push. Return version.found=true with version.name and ` +
  `version.version set from that file's "name" and "version" fields, or ` +
  `version.found=false with empty strings if the base cannot be resolved, ` +
  `the ref still cannot be resolved even after attempting the read, or the ` +
  `file is missing, unreadable, or has no such fields. A failed fetch does ` +
  `not force version.found=false on its own. Do not invent either value. ` +
  `Set version.refreshed=true only if that fetch actually succeeded, and ` +
  `false if it failed, was refused, or you did not run it. Set ` +
  `version.detail to one line saying which case applied.\n\n` +
  `3. MARKERS. At the same repo root, test for a file named exactly ` +
  `.crap-gated, and separately for one named exactly .mutation-gated. ` +
  `Return markers.crap_gated=true only if .crap-gated is there; ` +
  `markers.crap_gated=false otherwise, whether it is confirmed absent or ` +
  `you could not tell -- an unconfirmed CRAP marker must never be reported ` +
  `as gated. Return markers.mutation_gated=true if .mutation-gated is ` +
  `there or you could not determine either way, markers.mutation_gated=` +
  `false only if you confirmed it is absent -- an unconfirmed mutation ` +
  `marker should still run the gate, which only costs a run rather than ` +
  `dropping a real one. Report the paths you checked in markers.detail.`,
  { label: 'setup', schema: SETUP, model: 'haiku', effort: 'low' })
sSetup.close()

const fetched = setupResult?.ticket
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

// executed never changes; base_branch and mismatch stay null until this
// probe has something to report, which is why a halt at Worktree carries the
// executed value with the other two still null. mismatch is null rather than
// false when the probe found no comparable manifest (found:false, or a
// different plugin's name) -- the ordinary case for every repo this runs
// against except touchstone's own, but it is logged too, distinct from a real
// mismatch. A probe that returns nothing at all leaves the same null/null
// pair, but is logged separately again, since that case means the comparison
// did not run, not that there was nothing to compare.
const versionProbe = setupResult?.version
if (versionProbe == null) {
  log(`the plugin:version probe returned nothing, so pipeline_version could ` +
      `not be compared against the repository's base branch`)
} else if (versionProbe.found && versionProbe.name === PLUGIN_NAME) {
  const drift = versionProbe.version !== PIPELINE_VERSION
  pipelineVersion = {
    executed: PIPELINE_VERSION, base_branch: versionProbe.version, mismatch: drift,
    base_refreshed: versionProbe.refreshed !== false,
  }
  if (drift) {
    // Names both and orders neither: the executed snapshot is the newer one
    // whenever the base was reverted or the plugin was built locally.
    log(`this run is executing pipeline ${PIPELINE_VERSION}; the repository's ` +
        `base branch's plugin.json names ${versionProbe.version}`)
  }
  if (versionProbe.refreshed === false) {
    // Without this the fetch failing produces mismatch:false and silence,
    // which is the stale agreement the fetch was added to rule out.
    log(`the base branch's manifest was read from a remote-tracking ref this ` +
        `run could not refresh, so its version may predate the base branch's ` +
        `real state (${versionProbe.detail})`)
  }
} else {
  // The probe answered but did not confirm a comparable manifest -- the
  // ordinary case for every repo this pipeline delivers into other than
  // touchstone's own, but logged regardless: an answer that came back
  // uncomparable must not collapse into the same silence as a comparison
  // that never ran at all (the branch above).
  log(`the plugin:version probe found no comparable manifest on the ` +
      `repository's base branch (${versionProbe.detail}), so pipeline_version ` +
      `stays uncompared`)
}

// The two markers take opposite fail-safe defaults on an unconfirmed answer.
// Mutation: unknown counts as gated, which only costs an extra mutation run.
// CRAP: unknown must NOT count as gated, because that would assert a raw
// commit could not have bypassed the wrapper when nobody confirmed the
// marker is there -- the false assertion this ticket exists to remove. So
// crap_gated counts only a confirmed `true`; everything else, including a
// probe that returned nothing, is reported as unconfirmed.
const gateProbe = setupResult?.markers
const crapGated = gateProbe?.crap_gated === true
const mutationGated = gateProbe?.mutation_gated !== false
if (!gateProbe) {
  log(`gate opt-in probe returned nothing; treating CRAP gating as ` +
      `unconfirmed (reported as not hook-enforced) and mutation gating as ` +
      `opted-in (safe default: costs an extra run rather than dropping a real gate)`)
}

enterPhase('Worktree')
const sBranch = stage('branch')

// --show-toplevel returns the worktree's own path when run from inside one,
// not the repository; every session now runs inside a worktree, so a new
// worktree path built from it nests inside the current one instead of sitting
// beside it. The repo root must come from --git-common-dir instead.
//
// Re-running the same ticket is normal, not an error, and git will not let a
// branch be checked out twice: both prompts below must find an existing
// branch or worktree and reuse it rather than treat a collision as a halt.

// Shared by both worktree-creation prompts below: transcribing the same repo
// file the same way, whichever path found the worktree. Read only; chooses,
// filters and interprets nothing, since checksFrom() (used once wt exists)
// is what decides what any of it means. Folded into the worktree prompt
// itself rather than a separate checks:discover call after it, since that
// agent already has the worktree path open by the time it can answer this.
const checksDiscoveryStep = (n, whichPath) =>
  `${n}. Before you return from the step above: read ${whichPath}/AGENTS.md; ` +
  `if it does not exist, read ${whichPath}/CLAUDE.md instead (conventionally ` +
  `a symlink to it). Set checks_source.file to the absolute path you read, ` +
  `or '' if neither exists. If a file was read, find every line starting ` +
  `with "##" that sits outside a fenced code block. For each, set ` +
  `checks_source.sections[].heading to that full line verbatim, "#" ` +
  `characters included, and .fence to the first fenced code block that ` +
  `follows it and precedes the next such heading line, verbatim and whole ` +
  `-- its opening marker line (\`\`\` or ~~~, with any info string after ` +
  `it) and its closing marker line included -- or '' if there is none ` +
  `before the next heading or the file's end. List sections in the file's ` +
  `own order. Do not choose, filter, reorder, trim, or interpret any of ` +
  `it; a later step decides what it means. Set checks_source.detail to one ` +
  `line saying what you found.`

// The head an earlier run's review finished at, from the run record the invoking
// session passes in as args.priorRun (the script has no fs). An explicit
// args.reviewedThrough wins over the record's. Only a full SHA is a candidate,
// and only the branch:existing step below can say whether it is still on the
// branch, so nothing is carried until then.
const PRIOR_HEAD_MARKER = 'TOUCHSTONE_PRIOR_HEAD_LINEAR'
const PRIOR_HEAD_LINEAR = `${PRIOR_HEAD_MARKER} 0`
const PRIOR_HEAD_MERGED = `${PRIOR_HEAD_MARKER} 2`
const priorHeadGiven = !args?.existingBranch ? null
  : typeof args.reviewedThrough === 'string' ? args.reviewedThrough
  : args.priorRun?.reviewed_through
const priorHead = asSha(priorHeadGiven)
if (priorHeadGiven != null && !priorHead) {
  log(`ignoring reviewed head ${JSON.stringify(priorHeadGiven)}: not a 40-character SHA; ` +
      `reviewing the whole branch`)
}
// Prints 0 for an ancestor with no merge after it, 2 for an ancestor with one,
// and 1 for anything else. Two facts, not one: an ancestor keeps its findings'
// recorded_at and reproducers valid, but git diff A..B is a tree diff, so a range
// from a head that predates merging the base in holds all the base gained too, and
// the lenses would review that as this branch's work. A merge costs the narrowed
// range, never the carried record.
const priorHeadCommand = (path, head) =>
  `git -C ${path} merge-base --is-ancestor ${priorHead} ${head}; a=$?; ` +
  `m=$(git -C ${path} rev-list --merges --count ${priorHead}..${head}); ` +
  `echo ${PRIOR_HEAD_MARKER} $((a ? 1 : (m ? 2 : 0)))`
const priorHeadStep = (n) =>
  `${n}. Also before you return, only if step 8 returned created=true: run ` +
  `exactly the command below, with <path> the absolute path from step 8, and ` +
  `put the one line it prints in prior_head_check, verbatim and alone. Do not ` +
  `interpret it; the script reads it.\n` +
  priorHeadCommand('<path>', 'HEAD')

// existingBranch is for follow-up work on an open PR: review feedback, or scope
// added to a ticket already in flight. Cutting a fresh branch there strands the
// delta away from the PR it belongs to. The ticket stays mandatory either way.
const wt = args?.existingBranch
  ? await dispatch(
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
      `whether the branch name carries a jira- or gh- marker.\n` +
      checksDiscoveryStep(9, 'that path') +
      (priorHead ? `\n${priorHeadStep(10)}` : ''),
      { label: 'branch:existing', schema: EXISTING_BRANCH, model: 'haiku', effort: 'low' })
  // A worktree is a separate checkout, so the main tree's state is irrelevant
  // to it; cutting from origin/<base> is what removes the need to touch the
  // main checkout at all.
  : await dispatch(
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
  `detail that the branch was reused rather than created, then go straight ` +
  `to step 11: do not fetch, pull, or run any worktree add.\n` +
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
  checksDiscoveryStep(11, 'the worktree path from step 5 (or the reused path from step 6)') + `\n` +
  `Return the branch you created or reused, the base you cut it from (or ` +
  (baseOverride ? `${baseOverride}` : `the repo's base branch`) +
  ` if the branch already existed), and the absolute worktree path.`,
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
log(args?.existingBranch
  ? `worktree ${wt.path} reused for branch ${wt.branch} (base ${wt.base})`
  : `worktree ${wt.path} created for branch ${wt.branch} (base ${wt.base})`)

const priorHeadAnswer = wt.prior_head_check
if (!priorHead || (priorHeadAnswer !== PRIOR_HEAD_LINEAR && priorHeadAnswer !== PRIOR_HEAD_MERGED)) {
  recordedHead = null
  carriedOpen = []
  carriedNotes = []
  if (priorHead) {
    log(`reviewed head ${priorHead} is not confirmed as an ancestor of branch ` +
        `${wt.branch} (check printed ${JSON.stringify(wt.prior_head_check ?? null)}); ` +
        `reviewing the whole branch, carrying nothing`)
  }
} else {
  recordedHead = priorHead
  carriedOpen = carry(args.priorRun?.unresolved_findings)
  carriedNotes = carry(args.priorRun?.notes)
  const carried = `${carriedOpen.length} open, ${carriedNotes.length} notes carried`
  if (priorHeadAnswer === PRIOR_HEAD_LINEAR) {
    resumeFrom = priorHead
    log(`resuming from reviewed head ${priorHead}: ${carried}`)
  } else {
    log(`reviewed head ${priorHead} is still an ancestor of branch ${wt.branch}, but a ` +
        `merge commit came after it; reviewing the whole branch, ${carried}`)
  }
}


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
// line of code. Every review lens gets one slice of that prose besides, via
// decisionsSpec() below: the ticket's own "Constraints, or decisions already
// taken" section, verbatim. That does not reopen the reason the rest stays
// withheld, because a settled decision is not something to reason about, only
// something to not flag; it hands a lens a fact to respect, never the ticket's
// argument to critique.
// withBase is off for the version probe alone. On a stacked run wt.base is the
// branch under review, and naming it here handed the probe the exact ref its
// prompt spends a paragraph telling it to ignore.
const envelope = (withBase = true) =>
  `Ticket ${ticket}${ticketDetail.found ? `: ${ticketDetail.summary}` : ' (details unavailable)'}\n` +
  `Repo worktree: ${wt.path}\nBranch: ${wt.branch}${withBase ? ` (base ${wt.base})` : ''}\n`

// Never clamped: brief() once cut a ticket mid-acceptance-criterion and three
// phases planned against a spec whose second half they could not see.
const ticketSpec = () => ticketDetail.found
  ? `Ticket description:\n${ticketDetail.description}\n` +
    (ticketDetail.comments.trim()
      ? `Ticket comments:\n${ticketDetail.comments}\n` : '')
  : `Ticket ${ticket} could not be read; work from the task text alone.\n`

// GitHub's feature form renders this field's label as a heading, one of the
// two "### <label>" lines .github/ISSUE_TEMPLATE/feature.yml produces, so a
// heading of any level whose text matches exactly is the field, and the next
// heading of the same or shallower level (fewer #s) closes it -- a deeper one
// is a subsection of the field's own body, not the end of it. Anchored to
// line starts so the phrase said in passing, inside a paragraph, never
// matches. Returns '' for a missing section, an empty body, or GitHub's
// '_No response_' placeholder for an optional field left blank.
const settledDecisionsOf = (description) => {
  const heading = /^(#{1,6})[ \t]*Constraints, or decisions already taken[ \t]*$/m
  const m = heading.exec(description ?? '')
  if (!m) return ''
  const level = m[1].length
  const rest = description.slice(m.index + m[0].length)
  // Line-scanned rather than one multiline regex: a fenced code block can
  // contain a '#'-led line (a shell comment shown in an example), which a
  // bare heading match cannot tell apart from a real heading, so anything
  // between an odd and even fence marker is skipped.
  const headingRe = new RegExp(`^#{1,${level}}[ \t]+\\S`)
  const fenceRe = /^[ \t]{0,3}(`{3,}|~{3,})/
  let inFence = false
  let next = -1
  let pos = 0
  for (const line of rest.split('\n')) {
    if (fenceRe.test(line)) {
      inFence = !inFence
    } else if (!inFence && headingRe.test(line)) {
      next = pos
      break
    }
    pos += line.length + 1
  }
  const body = (next >= 0 ? rest.slice(0, next) : rest).trim()
  return (body && body !== '_No response_') ? body : ''
}
const settledDecisions = ticketDetail.found ? settledDecisionsOf(ticketDetail.description) : ''

// Handed to every review lens (reviewOf), never to Triage or Plan, which get
// the whole ticket via ticketSpec() instead. Framed as settled rather than as
// more ticket text to weigh, so a lens does not file the specified behaviour
// as the defect it was told to hunt for.
const decisionsSpec = () => settledDecisions
  ? `Settled decisions (the ticket's "Constraints, or decisions already ` +
    `taken" section, verbatim; decided, not under review):\n${settledDecisions}\n` +
    `Behaviour a settled decision specifies is not a defect: do not report it ` +
    `as wrong-result, crash, gate-bypass or unmet-criterion. Disagreeing with ` +
    `a decision is at most a design or scope note, which never blocks. Do not ` +
    `critique the rest of the ticket's reasoning.\n`
  : ''

const treeAgent = (prompt, { omitBase = false, ...opts }) =>
  dispatch(
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
    `-- goes under the path printed by ` +
    `git -C ${wt.path} rev-parse --git-path touchstone-scratch instead, never ` +
    `/tmp. That path lives under the worktree's own git dir, not its working ` +
    `tree, so it needs no gitignore entry and is gone once the worktree is ` +
    `removed. Git resolves identity and signing config by directory, so a repo ` +
    `created there inherits whatever the global config says, which can mean ` +
    `signing with the wrong identity or blocking on a hardware key no agent can ` +
    `satisfy. A scratch git repo is therefore always created with signing off ` +
    `and an explicit test identity, and every git command against it names ` +
    `that path literally, for the same reason ${wt.path} is named literally ` +
    `above. ` +
    `git init -q <scratch path> creates the directory, which the path above ` +
    `only names; git -C <scratch path> init cannot, because -C needs it to ` +
    `exist already. Then ` +
    `git -C <scratch path> add -A, then ` +
    `GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=test ` +
    `GIT_COMMITTER_EMAIL=t@t git -C <scratch path> -c commit.gpgsign=false ` +
    `-c gpg.format=openpgp commit -q -m scratch.\n\n` +
    envelope(!omitBase) + `\n` + prompt,
    opts)

const headOf = (range) => range.includes('..') ? range.split('..')[1].trim() : range.trim()

// Latch 1. The premise checks that matter most are usually one grep, and a task
// whose stated facts are wrong must not be planned around. Buying that check
// for one cheap agent is the difference between a 2-agent run and an 11-agent
// one, so it runs before anything expensive.
enterPhase('Triage')
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
  `2. How large is the real change, in lines? Set estimated_loc to your ` +
  `estimate of lines added plus removed, tests and docs included: it sets ` +
  `this run's token budget.\n` +
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
  `complexity_note, in one sentence.\n` +
  `Always return expected_files: every file you expect the real change to ` +
  `touch, from having read the code, not the ticket's own wording. A ticket ` +
  `naming one file and one behaviour is routine unless you can say why it is ` +
  `not. involved stands only when you also return involved_reason (why this ` +
  `is hard rather than routine) and expected_call_sites (the function or ` +
  `method names, not just files, you expect the change to touch); returning ` +
  `involved without all three gets read as routine instead, since "this ` +
  `feels hard" is not evidence and naming what you expect to touch is.`,
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
// This is the lever that shapes what one call spends, and the only one
// available before that agent starts. The stage ceilings below cannot do it:
// they are read after an agent returns, so on a single-shot stage a ceiling
// spends the tokens and then discards the work, which is why plan and
// implement deliberately carry none. effort is set on the call. runBudget,
// derived just below, is the other lever available this early, but it works
// differently: it refuses a whole call outright once the run has spent past
// it, rather than shaping how any one call spends.
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
let complexity = EFFORT[triage.complexity] ? triage.complexity : 'involved'
if (triage.complexity && complexity !== triage.complexity) {
  log(`triage returned an unrecognised complexity (${triage.complexity}); ` +
      `treating it as involved, which spends the most rather than the least`)
}
// involved triples effort and ceilings against routine, so it stands only
// when triage backs it with a reason and the files and call sites that
// reason names -- never on the strength of the word alone. This demotes a
// *recognised* involved verdict that arrived unjustified; it never touches
// the unrecognised-value fallback above, which stays involved regardless
// (that case is not a judgement about difficulty, so there is nothing to
// demote it against).
const involvedJustified = !!triage.involved_reason &&
  (triage.expected_files ?? []).length > 0 && (triage.expected_call_sites ?? []).length > 0
if (triage.complexity === 'involved' && !involvedJustified) {
  log(`triage judged this involved without a reason and the files and call ` +
      `sites it expects the diff to touch; treating it as routine instead`)
  complexity = 'routine'
} else if (triage.complexity === 'involved') {
  log(`triage justified involved: ${triage.involved_reason} (expected files: ` +
      `${triage.expected_files.join(', ')}; expected call sites: ` +
      `${triage.expected_call_sites.join(', ')})`)
}
const effortFor = EFFORT[complexity]
ceilingScale = CEILING_SCALE[complexity]
log(`triage judged this ${complexity}` +
    (triage.complexity_note ? `: ${triage.complexity_note}` : '') +
    ` -- plan/implement/review/verify effort ` +
    `${effortFor.plan}/${effortFor.implement}/${effortFor.review}/${effortFor.verify}` +
    `, ceilings x${ceilingScale}` +
    (EXPLICIT_BUDGETS.size
      ? ` (${[...EXPLICIT_BUDGETS].join(', ')} left at the value you passed)`
      : ''))
sTriage.close()

// Derived from the size triage just judged, in output tokens: a run-wide
// ceiling dispatch() (part 00) refuses a call past, catching what the
// per-stage ceilings above cannot -- those bound one stage each, and a run
// that overruns several of them in turn still has nothing stopping it
// overall. estimated_loc is optional on TRIAGE (a disproved premise trips
// regardless of it), so a numeric args.runBudget aside, a missing one falls
// back to a flat default by scope rather than the LOC formula: there is no
// number to derive from and a change already latched to inline is smaller by
// definition than a team-scoped one. The figures are set so healthy runs
// finish with room to spare (about 270k-300k output tokens for 240-450
// changed lines, and an inline-sized gate fix that spent 141k in Implement
// alone): a budget halt strands work mid-run, so it is for a run that has
// gone wrong, not a tight fit.
const budgetForLoc = (loc) => Math.min(1_000_000, Math.max(300_000, 100_000 + 1_500 * loc))
if (typeof args?.runBudget === 'number') {
  runBudget = args.runBudget
  runBudgetNote = `set explicitly via args.runBudget`
} else if (triage.estimated_loc != null) {
  runBudget = budgetForLoc(triage.estimated_loc)
  runBudgetNote = `derived from triage's ~${triage.estimated_loc} estimated LOC`
} else {
  runBudget = inlineMode ? 300_000 : 600_000
  runBudgetNote = `triage gave no estimated_loc; using the ${inlineMode ? 'inline' : 'team'} default`
}
log(`run budget: ${Math.round(runBudget / 1000)}k output tokens (${runBudgetNote})`)

// Everything from here on runs inside one try, so a dispatch the budget
// above refuses -- wherever in the run it happens to fall -- unwinds to one
// place rather than needing its own halt at every call site. The catch is at
// the very end of the script (part 60): it checks runBudgetSpent, not the
// thrown error's identity, since a genuine failure (the planner or
// implementer returning nothing, for instance) must still propagate rather
// than being read as a budget halt.
//
// That catch also has to report the state the run had reached, but it cannot
// read the `let` bindings this try declares. So each phase widens this
// closure once the state it adds exists; reading a binding any earlier is the
// TDZ failure recorded above `scored`.
let budgetHaltState = () => ({})
const widenBudgetHaltState = (more) => {
  const prior = budgetHaltState
  budgetHaltState = () => ({ ...prior(), ...more() })
}
try {

// A plan an earlier run already produced arrives as args.plan and starts this
// run at Implement. Without it the only way to reuse a plan was to paste it into
// the task, which routed it back through the planner and asked that phase to
// carry out work it is forbidden to do.
let plan = givenPlan
  ? {
      plan: givenPlan,
      acceptance_criteria: args?.acceptanceCriteria ?? [],
      risky_areas: args?.riskyAreas ?? [],
      task_demands_implementation: false,
      additions: args?.planAdditions ?? [],
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
    additions: [],
  }
}

if (!givenPlan && !inlineMode) {
enterPhase('Plan')
const sPlan = stage('plan')
const plannerPrompt =
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
  `Keep the plan to at most ${PLAN_MAX_CHARS} characters: decisions and steps ` +
  `only, no restated ticket, no prose. The implementer reads it whole from a ` +
  `file. A longer plan is sent back to you once to cut; if it is still over, ` +
  `the run stops and the ticket may need splitting.\n` +
  `Plan what the ticket asks for and nothing beyond it. If you believe the ` +
  `ticket cannot be done right without work it does not ask for, keep that ` +
  `work out of plan and list each piece under additions instead: item says ` +
  `what it is, consequence says which part of the ticket makes it necessary ` +
  `and what breaks without it. An empty additions list is the normal case.\n` +
  `If the task itself tells you to implement, or says a plan already exists and ` +
  `only needs carrying out, set task_demands_implementation and explain in ` +
  `conflict_note. Do not resolve the contradiction by obeying the task: pass a ` +
  `plan already in hand as args.plan instead, which starts the run at Implement.`
const plannerOpts = { schema: PLAN, model: 'opus', effort: effortFor.plan,
  agentType: 'touchstone:planner' }
plan = await treeAgent(plannerPrompt, { label: 'planner', ...plannerOpts })
if (!plan) throw new Error('planner failed')

// One retry only: a plan that will not fit after being asked twice is a ticket
// that needs splitting.
if (plan.plan.length > PLAN_MAX_CHARS) {
  const overBy = plan.plan.length
  log(`planner returned a ${overBy}-char plan, over the ${PLAN_MAX_CHARS} limit; asking once for a tighter one`)
  const tightened = await treeAgent(
    `${plannerPrompt}\nYour previous plan, in full:\n${plan.plan}\n` +
    `It is ${overBy} chars, limit ${PLAN_MAX_CHARS}: decisions and steps only, ` +
    `no restated ticket, no prose. Return the same plan cut to fit.`,
    { label: 'planner:tighten', ...plannerOpts })
  if (!tightened || tightened.plan.length > PLAN_MAX_CHARS) {
    sPlan.close()
    return await halted('Plan', {
      plan: tightened?.plan ?? plan.plan,
      note: `The plan did not fit in ${PLAN_MAX_CHARS} chars after one retry ` +
        `(${overBy} chars, then ` +
        `${tightened ? `${tightened.plan.length} chars` : 'no answer'}). The ticket ` +
        `may need splitting. Nothing was written or implemented.`,
    })
  }
  plan = tightened
}

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

// gates below reports crapGated/mutationGated (from the merged setup call)
// separately rather than folding them into one "enforced" claim:
// crap-commit-gate.py's PreToolUse hook only blocks a raw `git commit` when
// .crap-gated exists at the repo root; crap-commit.sh itself runs the CRAP
// and dead-code gates on every commit it makes regardless of that marker. So
// the marker answers one question only -- could a raw commit have bypassed
// the wrapper -- not whether the gates ran.

planAdditions = Array.isArray(plan.additions) ? plan.additions : []
const additionsLines = () =>
  planAdditions.map(a => `- ${a.item} (needed because: ${a.consequence})`).join('\n')

// A path made only of characters no shell ever treats specially is left bare:
// the check lines the runner executes carry the worktree path twice, and a
// nested `'\''` is the one thing a model relaying a line has miscopied before
// (on the pipeline 0.21.0 run that #116 is about, on every row). Quoting still
// closes the quote, splices in a backslash-escaped literal quote, and reopens
// it, for the one case that still needs it: a declared check's own command
// (`pytest -k 'not slow'`) or a worktree path carrying a character a bare word
// cannot hold as-is.
const shQuote = (s) => {
  const str = String(s)
  return /^[A-Za-z0-9/._+:@%=,-]+$/.test(str) ? str : `'${str.replace(/'/g, `'\\''`)}'`
}

enterPhase('Implement')
// The plan reaches the implementer as an untracked file it reads whole, never
// as prompt text, which brief() would clamp. The script has no fs, so an agent
// writes it and the script checks the measurements it reports.
const fnv1a = (s) => {
  let h = 0x811c9dc5
  for (let i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 0x01000193) }
  return (h >>> 0).toString(16).padStart(8, '0')
}
// FNV-1a over the UTF-8 bytes of the text with every run of spaces, tabs and
// newlines collapsed to one space and the ends trimmed. A model copying
// thousands of characters slips on whitespace now and then (a line indented
// by two spaces halted a run), so the copy is held to its words, not its bytes.
const contentDigest = (s) => {
  let h = 0x811c9dc5
  const add = (b) => { h ^= b; h = Math.imul(h, 0x01000193) }
  utf8Bytes(s.replace(/[ \t\n\r]+/g, ' ').replace(/^ | $/g, '')).forEach(add)
  return (h >>> 0).toString(16).padStart(8, '0')
}
const planId = fnv1a(`${ticket}${plan.plan}`)
const planFile = `${wt.path}/.touchstone/plan.md`
const planEndLine = `END OF PLAN ${planId}`
const planBody = `${plan.plan}\n`
const planEndCommand = `printf '\\nEND OF PLAN %s\\n' ${planId} >> ${shQuote(planFile)}`
const planContent = `${planBody}\n${planEndLine}\n`
// The plan reaches the file through a quoted heredoc the script builds, run
// as one command: a model asked to copy it with the Write tool reformatted it
// (bullets added, a line indented) and the run halted on a correct plan.
const planWriteCommand = `cat > ${shQuote(planFile)} <<'PLAN FILE END ${planId}'\n` +
  `${planBody}PLAN FILE END ${planId}\n${planEndCommand}`
// The same digest, computed over the written file in the worktree.
const planDigestCommand = `python3 -c 'import functools,re,sys;` +
  `t=re.sub(r"[ \\t\\n\\r]+"," ",open(sys.argv[1],encoding="utf-8").read()).strip(" ");` +
  `print("%08x"%functools.reduce(lambda h,c:((h^c)*16777619)&4294967295,t.encode("utf-8"),2166136261))' ` +
  `${shQuote(planFile)}`
widenBudgetHaltState(() => ({ plan: plan.plan }))
const planWritePrompt =
  `Write the plan file, then STOP. Do not implement anything and do not commit.\n` +
  `1. mkdir -p ${wt.path}/.touchstone && rm -f ${planFile}\n` +
  `2. Keep it out of git without touching any tracked file, before writing it. Run: ` +
  `x="$(git -C ${wt.path} rev-parse --path-format=absolute --git-common-dir)/info/exclude"; ` +
  `mkdir -p "$(dirname "$x")"; ` +
  `grep -qxF '.touchstone/' "$x" || printf '\\n.touchstone/\\n' >> "$x"\n` +
  `3. Run the command between the two fence lines below as one Bash call, ` +
  `passing every line exactly as written. It writes the plan and appends its ` +
  `end line; do not write or edit the file any other way.\n` +
  `\`\`\`bash\n${planWriteCommand}\n\`\`\`\n` +
  `4. Only after steps 1 to 3, run these and report what they print, never ` +
  `what you expect them to print.\n` +
  `digest: what ${planDigestCommand} prints.\n` +
  `last_line: what tail -n 1 ${planFile} prints, exactly, without its newline.\n` +
  `ignored_exit: the exit status of ` +
  `git -C ${wt.path} check-ignore -q .touchstone/plan.md (0 means ignored).`
const planWriteOpts = { schema: PLAN_WRITE, model: 'sonnet', effort: 'low' }
const planWriteProblemOf = (written) => !written
  ? 'the plan:write agent returned nothing'
  : written.digest !== contentDigest(planContent)
  ? `its content digest is ${JSON.stringify(written.digest)}, not the plan's ${contentDigest(planContent)}`
  : written.last_line !== planEndLine
  ? `its last line is ${JSON.stringify(written.last_line)}, not ${planEndLine}`
  : written.ignored_exit !== 0
  ? `git check-ignore exited ${written.ignored_exit}, so it is not ignored and a commit could pick it up`
  : null
let planWriteProblem = planWriteProblemOf(
  await treeAgent(planWritePrompt, { label: 'plan:write', ...planWriteOpts }))
if (planWriteProblem) {
  log(`plan file not verified (${planWriteProblem}); asking once more`)
  planWriteProblem = planWriteProblemOf(
    await treeAgent(planWritePrompt, { label: 'plan:write:retry', ...planWriteOpts }))
}
if (planWriteProblem) {
  return await halted('Implement', {
    plan: plan.plan,
    note: `The plan file ${planFile} could not be verified, even after a retry: ` +
      `${planWriteProblem}. Nothing was implemented.`,
  })
}

const sChecksPre = stage('checks')
// wt.checks_source came back from the branch/branch:existing call itself
// (its last step, done only when created=true), replacing a separate
// checks:discover dispatch now that the worktree it needs to read is
// already open by the time that call answers.
const { checks: sourceChecks, note: discoveryNote } = checksFrom(wt.checks_source)
let discoveredChecks = sourceChecks
log(discoveredChecks.length
  ? `checks discovered: ${discoveredChecks.map(c => c.id).join(', ')}`
  : `no repo-advertised checks found (${discoveryNote}); nothing to run alongside review`)

// existingBranch resumes a branch that may already carry commits of its own,
// so there is no clean base tree here to tell an environmental failure from
// a real one. Checks still run and are still reported below, but never
// block: after #87 resuming is the normal path, not an edge case.
const checksBlocking = !args?.existingBranch
let checkAttempt = 0
// The runner is a list of shell lines the script builds and an agent runs as
// given, so no check command and no check output is ever copied by a model:
// a fixer or a baseline that trusted a model-reported command or exit code
// could be handed a result for something that only resembles what was asked.
// Each check's line runs it from the worktree and writes its combined output
// to <git dir>/touchstone-checks/<run>/<id>.log, where `git rev-parse
// --git-path` puts it under the worktree's own git dir: never in the tree, so
// a log cannot dirty it, and gone with the worktree. Only then does it print
// the one line the script parses, with the exit code read from $? straight
// after the check, `;` rather than `&&` so a check that fails still gets its
// line. The printed line is why a long suite's output no longer has to fit
// the Bash tool's inline preview. c.command is spliced in unquoted -- it is
// the -c script's source, not one argument -- so only the cd target and the
// outer -c argument need quoting. There is no `exit` in any line: the agent's
// shell persists, and one would end it. A line whose git or mkdir fails
// prints nothing, which parseCheckRun reads as unmeasured. Every git call's
// stderr stays out of what the agent relays: a warning git prints on a healthy
// tree (an unreadable excludes or attributes file) would otherwise read as an
// unexpected line, or as a dirty tree.
const bashCommandFor = (c) => `bash -c ${shQuote(`cd ${shQuote(wt.path)} && ${c.command}`)}`
const logDirFor = (run, area = 'touchstone-checks') =>
  `d="$(git -C ${shQuote(wt.path)} rev-parse --path-format=absolute --git-path ${area}/${run} 2>/dev/null)"`
// The printed row is also written to the run's rows file (rowsSumMatches): the
// first line of a batch starts the file, so a re-run in the same directory
// never sums the previous run's rows.
const rowTo = (first) =>
  `printf '%s\\n' "$r" ${first ? '>|' : '>>'}"$d/rows"; printf '%s\\n' "$r"`
const checkLineFor = (c, run, first) =>
  `${logDirFor(run)} && mkdir -p "$d" && { ${bashCommandFor(c)} >|"$d/${c.id}.log" 2>&1; e=$?; ` +
  `r="$(printf 'TOUCHSTONE_CHECK %s %s %s' ${c.id} "$e" "$d/${c.id}.log")"; ${rowTo(first)}; }`
// The tree is looked at once, after the last check: a check that writes to it
// (a ledger, a generated file) must be visible, not silently carried into
// whatever commits next. The porcelain goes to a log beside the others and its
// stderr to status.err; a human reads both, so neither is ever relayed. Only
// stdout decides dirty. reproduce:* reuses these pieces for its before and end
// lines. The end line also prints the rows file's cksum.
const porcelainTo = (name) =>
  `git -C ${shQuote(wt.path)} status --porcelain >|"$d/${name}.log" 2>|"$d/${name}.err"`
const stateOf = (name) => `if [ -s "$d/${name}.log" ]; then s=dirty; else s=clean; fi`
const rowsSumTo = `k="$(cksum < "$d/rows")"`
const endLineFor = (run) =>
  `${logDirFor(run)} && mkdir -p "$d" && ${porcelainTo('status')} && ${rowsSumTo} && ` +
  `{ ${stateOf('status')}; printf 'TOUCHSTONE_CHECKS_END %s %s %s\\n' ${run} "$s" "$k"; }`
// The instructions every runner call gets around its fenced lines: checks:run
// and reproduce:* alike.
const runnerPrompt = (label, lines, note = '') =>
  `[touchstone: ${label}]\n` +
  `Run each line between the fence lines below as its own Bash call, exactly ` +
  `as written, then STOP. Do not fix, edit, or investigate a failure; a later ` +
  `phase does that.\n` +
  `Every line is complete and self-contained: it runs one step, writes that ` +
  `step's output to a log file itself, and prints only what the script reads ` +
  `back. Never edit, merge, split, reorder or re-quote a line, and never add ` +
  `to one.\n` +
  `This one call is the exception to the rule above about never running ` +
  `cd, and only in the form each line already takes: its cd runs inside a ` +
  `child shell (bash -c, or a subshell in parentheses), which does not move ` +
  `this session's own working directory. Never split one into a bare ` +
  `cd ${wt.path} && <command>, which does.\n` +
  `Run the lines one at a time, in the order given, each in the ` +
  `foreground with a Bash timeout of 600000 ms: never with ` +
  `run_in_background, never several at once, and wait for each to return ` +
  `before starting the next. A call that does not return within the ` +
  `timeout printed nothing and is simply not reported.\n` +
  `Return output: every line the calls printed, copied verbatim and in ` +
  `order, one per line, with no fence, comment or summary of your own. Never ` +
  `write, change or reorder a line yourself; a line you did not see printed ` +
  `is not reported.\n` + note +
  '```bash\n' + lines.join('\n') + '\n```'
const executeChecks = async (checks = discoveredChecks) => {
  checkAttempt++
  const run = `${planId}-${checkAttempt}`
  const out = await treeAgent(
    runnerPrompt('checks:run', [...checks.map((c, i) => checkLineFor(c, run, i === 0)), endLineFor(run)]),
    { label: `checks:run:${checkAttempt}`, schema: CHECK_RUN, model: 'haiku', effort: 'low' })
  return parseCheckRun(out?.output, checks, run)
}
// The one record kept of what a reproducer actually did at a given round: the
// log path, never its output, which a fixer reads from the log itself.
const reproducerRunOf = (row, round) =>
  ({ outcome: outcomeOf(row), exit_code: row?.exit_code ?? null, log: row?.log ?? null, round })
// Splits a parsed run into a real red list (a check whose own line reads a
// nonzero exit) and an unmeasured one. Unmeasured is never a pass, but it is
// also never red: a reply this phase cannot trust is not evidence either way,
// so it stays apart from red and is handed to runChecks below to retry, not to
// a fixer that cannot change what a runner printed. A reason fails the whole
// batch, since parseCheckRun accepts a reply only when every line of it is
// right. parseCheckRun returns the rows in the order of checks, so they pair
// up by position. reason is plain text for unmeasuredLines below.
const classifyResults = (checks, parsed) => {
  if (parsed.reason) {
    return { red: [], unmeasured: checks.map(c =>
      ({ id: c.id, command: c.command, exit_code: null, reason: parsed.reason })) }
  }
  return { unmeasured: [], red: checks.flatMap((c, i) => parsed.rows[i].exit !== 0
    ? [{ id: c.id, command: c.command, exit_code: parsed.rows[i].exit, log: parsed.rows[i].log }]
    : []) }
}
// Runs every check once and, only if the batch came back unmeasured, once
// more: a runner that miscopies once can copy correctly on a second try, and a
// run never re-measures what it already measured at this head. One that
// miscopies twice is not fixed by a code change, so nothing past this point
// retries again -- it halts instead (unmeasuredChecksHalt, or the baseline's
// own halt). The retry is the whole batch under a new run, so the first
// attempt's logs are kept as they were. dirty and statusLog describe the
// attempt that was measured.
const runChecks = async (checks = discoveredChecks) => {
  if (!checks.length) return { red: [], unmeasured: [], dirty: false, statusLog: null }
  const first = await executeChecks(checks)
  if (!first.reason) return { ...classifyResults(checks, first), dirty: first.dirty, statusLog: first.statusLog }
  log(`checks: the batch was unmeasured (${first.reason}), retrying once`)
  const second = await executeChecks(checks)
  if (!second.reason) return { ...classifyResults(checks, second), dirty: second.dirty, statusLog: second.statusLog }
  return {
    red: [], dirty: false, statusLog: null,
    unmeasured: classifyResults(checks, second).unmeasured
      .map(u => ({ ...u, reason: first.reason, reason_again: second.reason })),
  }
}

// A red check reaches a fixer as where its output is, never as the output: the
// log is the whole of it, and a fixer reads what it needs from the end.
const renderCheck = (c) => `Check ${c.id} (${c.command}) exited ${c.exit_code}. Full output: ${c.log}`
const renderChecks = (checks) =>
  `Each log below sits under the worktree's git directory, outside the ` +
  `worktree: it is the one path you may Read that does not start with ` +
  `${wt.path}/. Read it from the end, where a check prints its verdict; its ` +
  `start only names the repo and branch it resolved.\n` +
  checks.map(renderCheck).join('\n')
const unmeasuredLines = (checks) => checks.map(c =>
  `- ${c.id}: first run ${c.reason}; second run ${c.reason_again}.`).join('\n')

// Reports a check the runner never measured, after runChecks already
// retried it once. Never sent to a fixer: a fixer cannot change what a
// runner printed, and three fix rounds were burned on exactly that
// before #116. plan, impl, gatesPayload and checksPayload are read here only
// by closure -- this halts solely from a call site after impl exists (the
// three sites below), never from above it, so none of open/notes/round/
// fixRoundSpend can be read here: those are `let` bindings this file
// declares only inside the fix loop, and reading them from a call site
// before that loop starts would be the same TDZ failure the comment above
// `scored` records. The fix-loop call site passes them through extra.
const unmeasuredChecksHalt = (at, extra) => {
  const note = `${unmeasuredChecks.length} discovered check(s) could not be ` +
    `measured after a retry. This halt is about measurement, not the code: ` +
    `the runner did not print what the script asked for, or they did not ` +
    `finish within the 600000 ms Bash timeout, so no verdict exists either ` +
    `way, and no fix round has been spent on them.\n` +
    unmeasuredLines(unmeasuredChecks)
  return halted(at, {
    plan: plan.plan, implemented: impl.summary, gates: gatesPayload(), checks: checksPayload(),
    ...extra, note,
  })
}

// A check red before any work started is the repo's own environment, not
// this run's doing, and there is no way to tell the two apart other than
// measuring the base commit itself. Dropped, not merely downgraded, so it
// can never re-enter a fixer prompt later. A baseline that could not be
// measured, even after runChecks' retry, is not part of this and does not go
// on: with nothing known about the base, every check red after Implement would
// read as the run's own doing and reach a fixer (#143), so the run halts here,
// before anything is implemented.
let droppedAtBaseline = []
if (discoveredChecks.length && checksBlocking) {
  const baseline = await runChecks()
  if (baseline.unmeasured.length) {
    sChecksPre.close()
    return await halted('Implement', {
      plan: plan.plan,
      checks: { discovered: discoveredChecks.length, blocking: checksBlocking, red: [],
        unmeasured: baseline.unmeasured,
        detail: 'halted before any check ran against real implementation work' },
      note: `The environmental baseline could not be established: ` +
        `${baseline.unmeasured.length} discovered check(s) could not be ` +
        `measured at the base commit, even after a retry, before any ` +
        `implementation ran. This is about measurement, not the code, and no ` +
        `verdict exists either way. Nothing was implemented.\n` +
        unmeasuredLines(baseline.unmeasured),
    })
  }
  if (baseline.dirty) {
    sChecksPre.close()
    return await halted('Implement', {
      plan: plan.plan,
      checks: { discovered: discoveredChecks.length, blocking: checksBlocking, red: [],
        detail: 'halted before any check ran against real implementation work' },
      note: `A discovered check wrote to the working tree while establishing ` +
        `the environmental baseline, before any implementation ran. What git ` +
        `status reported afterwards is in ${baseline.statusLog}. Nothing was ` +
        `planned or implemented. Find which check writes, then re-run.`,
    })
  }
  const baseRed = baseline.red
  if (baseRed.length) {
    const redIds = new Set(baseRed.map(c => c.id))
    droppedAtBaseline = baseRed
    discoveredChecks = discoveredChecks.filter(c => !redIds.has(c.id))
    log(`checks: dropped ${droppedAtBaseline.length} as environmental (red ` +
        `before any work started): ${droppedAtBaseline.map(c => c.id).join(', ')}`)
  }
} else if (discoveredChecks.length) {
  log(`checks: existingBranch has no clean base tree to classify against; ` +
      `the ${discoveredChecks.length} discovered check(s) are reported but ` +
      `never block this run`)
}
sChecksPre.close()
const checksPreSpend = stageSpend.checks ?? 0

let redChecks = []
let unmeasuredChecks = []
function checksPayload() {
  return {
    discovered: discoveredChecks.length,
    blocking: checksBlocking,
    red: redChecks,
    unmeasured: unmeasuredChecks,
    detail: (checksBlocking
      ? (droppedAtBaseline.length
          ? `dropped ${droppedAtBaseline.length} as environmental at the base ` +
            `commit: ${droppedAtBaseline.map(c => c.id).join(', ')}. `
          : '')
      : `advisory only: existingBranch has no clean base tree to classify ` +
        `checks against, so a red one here is reported but never blocks. `
    ) + (discoveryNote || wt.checks_source?.detail || ''),
  }
}
// Red but not blocking (existingBranch) reaches the fixer as nothing at
// all: it is visibility for a human, not work to hand to an agent.
const blockingChecksOpen = () => checksBlocking && redChecks.length > 0
widenBudgetHaltState(() => ({ plan: plan.plan, checks: checksPayload() }))

// Every name change-signals.sh prints. Recorded and read by nothing here: not
// the lens count, the ratio halt, the round limit or a ceiling.
const SIGNAL_NAMES = [
  'la', 'ld', 'lt', 'la_lt', 'files', 'directories', 'dependency_surface',
  'api_broken', 'security_pattern', 'semantic_noop', 'crap_max', 'coverage_min',
  'reachable', 'defect_files']
const SIGNALS_PROBE = {
  type: 'object', additionalProperties: false, required: ['output'],
  properties: { output: { type: 'string' } },
}
const signalsCommandFor = (range) => `change-signals.sh ${wt.path} ${range}`

// As strict as parseDiffstat: the begin line names this exact range, one JSON
// line follows, then the end line, and every name carries a well-formed value.
// Anything else is null.
const validSignal = (e) => !!e && typeof e === 'object' && (
  e.value === true || e.value === false ||
  (typeof e.value === 'number' && Number.isFinite(e.value)) ||
  (e.value === 'unmeasured' && typeof e.reason === 'string' && e.reason.trim() !== ''))
const parseSignals = (output, range) => {
  const lines = String(output ?? '').split(/\r?\n/).map(l => l.trimEnd())
  while (lines.length && lines[0].trim() === '') lines.shift()
  while (lines.length && lines[lines.length - 1].trim() === '') lines.pop()
  if (lines.length !== 3) return null
  if (lines[0] !== `TOUCHSTONE_SIGNALS ${range}`) return null
  if (lines[2] !== 'TOUCHSTONE_SIGNALS_END') return null
  let parsed
  try { parsed = JSON.parse(lines[1]) } catch { return null }
  if (!parsed || parsed.range !== range || !parsed.values || typeof parsed.values !== 'object') return null
  if (!SIGNAL_NAMES.every(name => validSignal(parsed.values[name]))) return null
  return { range, values: Object.fromEntries(SIGNAL_NAMES.map(name => [name, parsed.values[name]])) }
}

// One try, no retry: a missing record is not worth a second dispatch, and a
// failure here must not stop the run. Not dispatched once the run budget is
// spent: the refusal would end the run as a budget halt before the halt it was
// about to make for its own reason, an unsupported language or an overrun
// implementer, could say so.
const measureSignals = async (range) => {
  if (runBudget != null && runSpent() >= runBudget) {
    log(`signals: run budget spent; not measured for ${range}`)
    return null
  }
  try {
    const probe = await treeAgent(
      `Run exactly this and put all of its output verbatim in output, ` +
      `unsummarised, then STOP. change-signals.sh sits in the ` +
      `crap-controlled-changes skill's directory, beside crap-check.sh: invoke ` +
      `that skill to learn where that is. Run it in the foreground with a Bash ` +
      `timeout of 600000, never in the background, never twice, and change ` +
      `nothing.\n${signalsCommandFor(range)}`,
      { label: 'signals', phase: 'Implement', schema: SIGNALS_PROBE, model: 'haiku', effort: 'low' })
    const parsed = parseSignals(probe?.output, range)
    if (!parsed) {
      log(`signals: no usable output for ${range}; continuing without them`)
      return null
    }
    const unmeasured = SIGNAL_NAMES.filter(n => parsed.values[n].value === 'unmeasured')
    log(`signals: ${SIGNAL_NAMES.length - unmeasured.length} of ${SIGNAL_NAMES.length} measured` +
      (unmeasured.length ? `; unmeasured: ${unmeasured.join(', ')}` : ''))
    return parsed
  } catch (e) {
    log(`signals: probe failed (${e?.message ?? e}); continuing without them`)
    return null
  }
}

const sImpl = stage('implement')
const impl = await treeAgent(
  `Implement this task in the current repo.\n` +
  `${NATIVE_TOOLS(wt.path)} ${GENERATED_FILES}\n` +
  `Task: ${brief(task)}\n` +
  `The plan is the file ${planFile}. Read all of it before any edit: use ` +
  `Read, with offset and limit if it is long, until you have read its last ` +
  `line, which reads END OF PLAN followed by an id. Return that id as ` +
  `plan_id. If you cannot read the whole file, do not start: make no edit ` +
  `and no commit, return plan_id as an empty string, and say why in ` +
  `summary. The file is untracked on purpose, so never commit .touchstone/.\n` +
  (plan.acceptance_criteria.length
    ? `Acceptance criteria:\n- ${plan.acceptance_criteria.join('\n- ')}\n`
    : `Acceptance criteria: none were supplied with this plan. Derive them from ` +
      `it before you write anything, and state them in your summary.\n`) +
  (planAdditions.length
    ? `Beyond the ticket, the plan adds the work below, each because it judged ` +
      `the ticket cannot be done right without it. None is a decision the ` +
      `ticket made: build each only as far as its stated reason needs, and ` +
      `name each in your summary.\n${additionsLines()}\n`
    : '') +
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
widenBudgetHaltState(() => ({ implemented: impl.summary, gates: gatesPayload() }))

// Measured here, the first moment a range exists, so that every halt from this
// point on carries the signals, a refused plan_id and a budget refusal during
// checks included. The probe's own spend counts against the stage's window, so
// whether the implementer overran is read before it.
const implementerOver = sImpl.over()
signals = await measureSignals(impl.commit_range)

// Before anything else is read from impl: an implementer that never reached
// the end of the plan cannot be trusted to have followed it.
const returnedPlanId = String(impl.plan_id ?? '').trim()
if (returnedPlanId !== planId) {
  return await halted('Implement', {
    plan: plan.plan, implemented: impl.summary, gates: gatesPayload(),
    note: `The implementer returned plan_id ${JSON.stringify(returnedPlanId)}, ` +
      `not ${planId}, so it did not read the whole plan file ${planFile}. Its ` +
      `work is refused and nothing was pushed; any commits it made are still ` +
      `on the branch.`,
  })
}

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
if (implementerOver) {
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
const implBase = impl.commit_range.includes('..')
  ? impl.commit_range.split('..')[0].trim() : impl.commit_range.trim()
;({ red: redChecks, unmeasured: unmeasuredChecks } = await runChecks())
if (redChecks.length) {
  log(`checks: ${redChecks.length} discovered check(s) red after Implement: ` +
      redChecks.map(c => c.id).join(', '))
}
if (checksBlocking && unmeasuredChecks.length) {
  sChecksPost.close()
  stageSpend.checks = checksPreSpend + (stageSpend.checks ?? 0)
  return await unmeasuredChecksHalt('Implement')
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
    `${NATIVE_TOOLS(wt.path)} ${GENERATED_FILES}\n` +
    `Task: ${brief(task)}\n` +
    renderChecks(redChecks) + `\n` +
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
    impl.commit_range = `${implBase}..${preReviewHead}`
    lastCheckedHead = preReviewHead
    signals = (await measureSignals(impl.commit_range)) ?? signals
    ;({ red: redChecks, unmeasured: unmeasuredChecks } = await runChecks())
    log(redChecks.length
      ? `checks: ${redChecks.length} still red after the pre-review fix round`
      : `checks: all clear after the pre-review fix round`)
    if (unmeasuredChecks.length) {
      sChecksPost.close()
      stageSpend.checks = checksPreSpend + (stageSpend.checks ?? 0)
      return await unmeasuredChecksHalt('Implement')
    }
  }
}
sChecksPost.close()
stageSpend.checks = checksPreSpend + (stageSpend.checks ?? 0)

// Taken here, after the pre-review fix may have moved impl.commit_range's head.
// The branch step's merge check ran before the implementer, who is often told to
// bring the branch up to date first, so it is asked again at the head Implement
// left: a merge after resumeFrom would put the base's own changes in the range.
// A probe that cannot say the range is clean gives the whole branch, which costs
// tokens, never coverage.
let firstReviewRange = impl.commit_range
if (resumeFrom) {
  const rangeHead = headOf(impl.commit_range)
  const checked = await treeAgent(
    `Run exactly this and put all of its output verbatim in output, ` +
    `unsummarised, then STOP.\n${priorHeadCommand(wt.path, rangeHead)}`,
    { label: 'resume:range-check', schema: HEAD_CHECK_PROBE, model: 'haiku', effort: 'low' })
  const printed = String(checked?.output ?? '').trim()
  if (printed === PRIOR_HEAD_LINEAR) {
    firstReviewRange = `${resumeFrom}..${rangeHead}`
  } else {
    log(`reviewed head ${resumeFrom} is not a clean start for a range ending at ${rangeHead} ` +
        `(check printed ${JSON.stringify(printed)}): a merge came after it, or it could not ` +
        `be checked; reviewing the whole branch`)
    resumeFrom = null
  }
}

// Nothing under .touchstone/ may reach a commit. The range runs from the
// implementer's own base, not from the previous head, so a commit that adds the
// plan file and a later one that deletes it is still seen. Run before every
// push, and again after each phase that commits.
const PLAN_LEAK_MARKER = 'TOUCHSTONE_PLAN_LEAK'
const planLeakCommandFor = (range) =>
  `echo ${PLAN_LEAK_MARKER} ${range}; ` +
  `git -C ${wt.path} log --format= --name-only ${range} -- .touchstone; ` +
  `echo ${PLAN_LEAK_MARKER}_END`
// null for output that is not the probe's: a missing marker, the wrong range,
// or a line that is not a path under .touchstone. [] is the only clean answer.
const parsePlanLeak = (output, range) => {
  const lines = String(output ?? '').split(/\r?\n/)
  while (lines.length && lines[0].trim() === '') lines.shift()
  while (lines.length && lines[lines.length - 1].trim() === '') lines.pop()
  if (lines.length < 2) return null
  if (lines[0] !== `${PLAN_LEAK_MARKER} ${range}`) return null
  if (lines[lines.length - 1] !== `${PLAN_LEAK_MARKER}_END`) return null
  const paths = lines.slice(1, -1).filter(l => l.trim() !== '')
  return paths.every(l => l === '.touchstone' || l.startsWith('.touchstone/')) ? paths : null
}
const planLeakHalt = async (head, at, extra = {}) => {
  const range = `${implBase}..${head}`
  const prompt =
    `Run exactly this and put all of its output verbatim in output, ` +
    `unsummarised, then STOP.\n${planLeakCommandFor(range)}`
  const probe = async (label) => parsePlanLeak((await treeAgent(prompt,
    { label, schema: PLAN_LEAK_PROBE, model: 'haiku', effort: 'low' }))?.output, range)
  let leaked = await probe(`plan:leak:${at}`)
  if (leaked === null) leaked = await probe(`plan:leak:${at}:retry`)
  if (leaked?.length === 0) return null
  return await halted(at, {
    plan: plan.plan, implemented: impl.summary, gates: gatesPayload(),
    checks: checksPayload(), ...extra,
    note: leaked
      ? `Commits in ${range} carry ${leaked.length} path(s) under .touchstone/, ` +
        `which holds the untracked plan file: ${leaked.join(', ')}. The run ` +
        `stopped before pushing them.`
      : `Whether ${range} carries anything under .touchstone/ could not be ` +
        `verified, even after a retry: the probe's output was missing or malformed. The run stopped ` +
        `before pushing it.`,
  })
}
const implLeak = await planLeakHalt(headOf(impl.commit_range), 'Implement')
if (implLeak) return implLeak

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
// The diffstat line: a numstat pass for added/removed per file, then an awk
// pass counting, per file, added lines whose trimmed text opens a comment:
// "//" or "/*" anywhere, a bare "*" only when it opens a block-comment
// continuation or close ("* foo", "*/", not "*p = v", a Go/C pointer
// write), and "#" unless it is "#!" (a shebang) or "#[" (a PHP 8 attribute,
// e.g. #[ORM\Column]) -- sizeOf needs that count per file, not one grand
// total, since only a code file's own comment lines subtract from its own
// added count. Both passes write to a log under the worktree's git dir, and
// only then does the line print it between a begin line naming this exact
// range and an end line carrying the log's line count and numstat's exit,
// both from the shell: a relay that drops or adds a row, or a git diff that
// failed and printed nothing, which would otherwise read as an empty diff
// and skip review, no longer parses.
const diffstatLineFor = (range, run) =>
  `${logDirFor(run, 'touchstone-diffstat')} && mkdir -p "$d" && ` +
  `{ git -C ${shQuote(wt.path)} diff --numstat --no-renames ${range} >|"$d/diffstat.log" 2>|"$d/diffstat.err"; g=$?; ` +
  `echo TOUCHSTONE_COMMENT_LINES >>"$d/diffstat.log"; ` +
  `git -C ${shQuote(wt.path)} diff --unified=0 --no-color --no-renames ${range} 2>>"$d/diffstat.err" | awk '` +
  `/^\\+\\+\\+ /{ f=$0; sub(/^\\+\\+\\+ (b\\/)?/, "", f); cur=f; next } ` +
  `/^\\+/{ if (cur=="") next; line=$0; sub(/^\\+/, "", line); t=line; ` +
  `sub(/^[ \\t]+/, "", t); if ((t ~ /^(\\/\\/|\\/\\*)/) || ` +
  `(t ~ /^\\*($|[ \\t\\/])/) || (t ~ /^#/ && t !~ /^#!/ && ` +
  `t !~ /^#\\[/)) cnt[cur]++ } ` +
  `END{ for (k in cnt) print cnt[k] "\\t" k }' >>"$d/diffstat.log"; ` +
  `printf 'TOUCHSTONE_DIFFSTAT %s\\n' ${range}; cat "$d/diffstat.log"; ` +
  `printf 'TOUCHSTONE_DIFFSTAT_END %s %s\\n' "$(grep -c '' "$d/diffstat.log")" "$g"; }`

// Pure: reads only the shape of the line's own output, never a model's
// account of it. The begin line, naming this exact range, must be the first
// line -- a diffstat whose begin line names a different range was run against
// the wrong commits and must not be trusted -- and the end line the last,
// with a count equal to the lines between them and a numstat exit of 0. A
// numstat row failing NUMSTAT_ROW, a missing TOUCHSTONE_COMMENT_LINES marker,
// or a malformed comment-count row all count as unmeasured, the same as either
// marker missing: anything this strict about the shape either parses cleanly
// or is not trusted at all.
const NUMSTAT_ROW = /^(\d+|-)\t(\d+|-)\t(.+)$/
const DIFFSTAT_END_LINE = /^TOUCHSTONE_DIFFSTAT_END (\d+) (\d+)$/
const parseDiffstat = (output, range) => {
  const lines = runnerLinesOf(output)
  if (lines.length < 2) return null
  if (lines[0] !== `TOUCHSTONE_DIFFSTAT ${range}`) return null
  const end = DIFFSTAT_END_LINE.exec(lines[lines.length - 1])
  if (!end) return null
  const body = lines.slice(1, -1)
  if (Number(end[1]) !== body.length || end[2] !== '0') return null
  const markerIdx = body.indexOf('TOUCHSTONE_COMMENT_LINES')
  if (markerIdx === -1) return null
  const files = []
  for (const line of body.slice(0, markerIdx)) {
    const m = NUMSTAT_ROW.exec(line)
    if (!m) return null
    files.push({ added: m[1] === '-' ? 0 : Number(m[1]), removed: m[2] === '-' ? 0 : Number(m[2]), path: m[3] })
  }
  const comments = new Map()
  for (const line of body.slice(markerIdx + 1)) {
    const m = /^(\d+)\t(.+)$/.exec(line)
    if (!m) return null
    comments.set(m[2], Number(m[1]))
  }
  return { files, comments }
}

// test: test/, tests/, __tests__/ or spec/ dirs; test-* or test_* basenames;
// *_test.*, *.test.*, *.spec.*, *Test.php. doc: *.md, *.rst, *.adoc, *.txt,
// or anything under docs/. Everything else is code.
const classifyPath = (path) => {
  const base = path.split('/').pop() ?? path
  if (/(^|\/)(test|tests|__tests__|spec)\//.test(path) ||
      /^test[-_]/.test(base) || /_test\.[^.]+$/.test(base) ||
      /\.test\.[^.]+$/.test(base) || /\.spec\.[^.]+$/.test(base) ||
      /Test\.php$/.test(base)) return 'test'
  if (/\.(md|rst|adoc|txt)$/.test(base) || /(^|\/)docs\//.test(path)) return 'doc'
  return 'code'
}

// code = a code file's added lines minus its own comment lines; comment =
// those subtracted lines; test/doc = their files' added lines as-is (a
// comment inside a test file is still test code, not support layered on top
// of it); codeChurn = code-file added + removed, which lensKeysFor and the
// ratio halt both key on; totalChurn is every file's added + removed,
// regardless of kind, for the single-file trivial case below, where kind
// does not matter.
const sizeOf = (parsed) => {
  let code = 0, comment = 0, test = 0, doc = 0, codeChurn = 0, codeFiles = 0, totalChurn = 0
  for (const f of parsed.files) {
    totalChurn += f.added + f.removed
    const kind = classifyPath(f.path)
    if (kind === 'test') { test += f.added; continue }
    if (kind === 'doc') { doc += f.added; continue }
    codeFiles++
    const c = parsed.comments.get(f.path) ?? 0
    code += Math.max(0, f.added - c)
    comment += c
    codeChurn += f.added + f.removed
  }
  return { files: parsed.files.length, codeFiles, code, comment, test, doc, codeChurn, totalChurn }
}

// Replaces big/trivial: a real, measured diff decides the lens count, never
// the implementer's own report of what it touched, which goes stale the
// moment a pre-review checks fix lands after it without updating either
// field.
const lensKeysFor = (size) =>
  size.files <= 1 && size.totalChurn < INLINE_LOC ? []
  : size.codeChurn < ONE_LENS_LOC ? ['correctness']
  : size.codeChurn > BIG_LOC || size.codeFiles > BIG_FILES ? ['correctness', 'advocate', 'requirements']
  : ['correctness', 'advocate']

enterPhase('Draft PR')
// Whether the branch already has a PR is read from a line the shell prints,
// never from a model's account: a run once adopted an unrelated PR because its
// branch had the same name. gh has no -C, so it runs in a subshell cd'd into
// the worktree; the ancestry is git's, against the PR head gh reported, and a
// head this clone does not have is not an ancestor either.
const prStateLine =
  `p="$(cd ${shQuote(wt.path)} && gh pr view ${shQuote(wt.branch)} --json number,state,isDraft,headRefOid ` +
  `--jq '"\\(.number) \\(.state) \\(.isDraft) \\(.headRefOid)"' 2>/dev/null)" || p=''; ` +
  `read -r n s r h <<<"$p"; ` +
  `if [ -n "$h" ] && git -C ${shQuote(wt.path)} merge-base --is-ancestor "$h" HEAD 2>/dev/null; then a=1; else a=0; fi; ` +
  `printf 'TOUCHSTONE_PR %s %s %s %s %s %s\\n' ${shQuote(wt.branch)} "\${n:-none}" "\${s:-none}" "\${r:-none}" "\${h:-none}" "$a"`
let prLineAttempt = 0
const prRunFor = (what) => `${planId}-${what}-${++prLineAttempt}`
const relayLine = async (label, line) =>
  (await treeAgent(runnerPrompt(label, [line]),
    { label, phase: 'Draft PR', schema: VERDICT_RUN, model: 'haiku', effort: 'low' }))?.output
// One retry on a reply that does not parse, the same as every other line.
const readTwice = async (label, measure) => {
  const first = await measure(label)
  if (!first.reason) return first
  log(`${label}: unmeasured (${first.reason}), retrying once`)
  const second = await measure(`${label}:retry`)
  if (!second.reason) return second
  return { reasons: [first.reason, second.reason] }
}
// Converting back to a draft is verified by re-reading isDraft, not by the
// undo's exit: the run reports the state gh shows afterwards.
const prUndoLineFor = (n, run) =>
  `${logDirFor(run, 'touchstone-pr')} && mkdir -p "$d" && ` +
  `{ (cd ${shQuote(wt.path)} && gh pr ready ${n} --undo) >|"$d/pr-undo.log" 2>&1; e=$?; ` +
  `r="$(cd ${shQuote(wt.path)} && gh pr view ${n} --json isDraft --jq .isDraft 2>/dev/null)"; ` +
  `printf 'TOUCHSTONE_PR_UNDO %s %s %s %s\\n' ${n} "$e" "\${r:-none}" "$d/pr-undo.log"; }`
const prPushLineFor = (run) =>
  `${logDirFor(run, 'touchstone-pr')} && mkdir -p "$d" && ` +
  `{ git -C ${shQuote(wt.path)} push -u origin ${shQuote(wt.branch)} >|"$d/push.log" 2>&1; e=$?; ` +
  `printf 'TOUCHSTONE_PUSH %s %s %s\\n' ${shQuote(wt.branch)} "$e" "$d/push.log"; }`
const draftPayload = () => ({ plan: plan.plan, implemented: impl.summary, gates: gatesPayload(), checks: checksPayload() })

const prState = await readTwice('pr:state', async (label) => parsePrState(await relayLine(label, prStateLine), wt.branch))
if (prState.reasons) {
  // Not knowing is not a reason to open one: a PR may exist that this run
  // must not touch. The draft is never fatal, so the run goes on without it.
  log(`pr:state: unmeasured (first: ${prState.reasons[0]}; second: ${prState.reasons[1]}); ` +
      `nothing was opened or adopted, so a halt from here on is only visible in this session`)
} else if (prState.number === null) {
  const draft = await treeAgent(
    `Open a draft pull request for this branch to hang the run's progress on, ` +
    `then STOP. No PR exists for it yet.\n` +
    `Task: ${brief(task)}\nWhat has been implemented so far: ${impl.summary}\n` +
    `git push -u origin ${wt.branch}, then gh pr create --draft` +
    (baseOverride ? ` --base ${wt.base}` : '') + `.\n` +
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
    `Return the url and number of the PR you opened.`,
    { label: 'draft-pr', phase: 'Draft PR', schema: DRAFT, model: 'haiku',
      effort: 'low' })
  // number, not opened: the PR phase addresses the draft by number to update and
  // ready it, and a url with no number is not enough for that.
  if (draft?.number) {
    draftPr = { url: draft.url, number: draft.number, draft: true }
    log(`PR #${draft.number} carries this run: ${draft.url ?? '(no url)'}`)
  } else {
    log(`draft PR not opened (${draft?.detail ?? 'no detail'}); continuing. ` +
        `A halt from here on is only visible in this session`)
  }
} else if (!prState.ancestor) {
  return await halted('Draft PR', { ...draftPayload(),
    note: `PR #${prState.number} for branch ${wt.branch} has head ${prState.head}, which is ` +
      `not an ancestor of this branch's head, so it is not this branch's history: an ` +
      `unrelated PR under the same branch name, or one pushed to since this branch was ` +
      `cut. The run did not adopt it and pushed nothing. Pick another branch name or ` +
      `bring the branch up to that head, then re-run.`,
  })
} else if (prState.state !== 'OPEN') {
  return await halted('Draft PR', { ...draftPayload(),
    note: `PR #${prState.number} for branch ${wt.branch} is ${prState.state.toLowerCase()}, so ` +
      `this run cannot carry its work on it. The run pushed nothing. Pick another branch ` +
      `name, or reopen the PR, then re-run.`,
  })
} else {
  draftPr = { url: null, number: prState.number, draft: prState.draft }
  log(`PR #${prState.number} carries this run, adopted ${prState.draft ? 'as a draft' : 'ready for review'}`)
  // A ready PR would otherwise hold commits no gate has passed while it reads
  // as finished. Converted before the push, so it never does.
  if (!prState.draft) {
    const undo = await readTwice('pr:undo', async (label) => {
      const run = prRunFor('pr-undo')
      return parsePrUndo(await relayLine(label, prUndoLineFor(prState.number, run)), prState.number, run)
    })
    draftPr.draft = !undo.reasons && undo.draft
    draftPr.readyWhy = undo.reasons
      ? `converting it to a draft could not be verified: ${undo.reasons.join('; ')}`
      : undo.draft ? null
      : `gh pr ready ${prState.number} --undo exited ${undo.exit} and the PR still reads as ready (${undo.log})`
    log(draftPr.draft ? `PR #${prState.number} converted to a draft` : `PR #${prState.number}: ${draftPr.readyWhy}`)
  }
  const pushRun = prRunFor('pr-push')
  const pushed = parsePush(await relayLine('pr:push', prPushLineFor(pushRun)), wt.branch, pushRun)
  if (pushed.reason || pushed.exit !== 0) {
    log(`pr:push: ${pushed.reason ?? `git push exited ${pushed.exit} (${pushed.log})`}; ` +
        `continuing, the PR phase pushes again`)
  }
}

enterPhase('Review')
const sReview = stage('review')

// Unmeasured gets one retry, at the same range. Still unmeasured after that
// halts here: this is a measurement problem, not a code problem, the same
// principle unmeasuredChecksHalt and notExecutedHalt apply elsewhere in this
// file.
let diffstatAttempt = 0
const measureDiffstat = async (label) => {
  const run = `${planId}-diffstat-${++diffstatAttempt}`
  const out = await treeAgent(runnerPrompt(label, [diffstatLineFor(firstReviewRange, run)]),
    { label, schema: VERDICT_RUN, model: 'haiku', effort: 'low' })
  return parseDiffstat(out?.output, firstReviewRange)
}
let sizeParsed = await measureDiffstat('diffstat')
if (!sizeParsed) sizeParsed = await measureDiffstat('diffstat:retry')
if (!sizeParsed) {
  sReview.close()
  return await halted('Review', {
    plan: plan.plan, implemented: impl.summary, gates: gatesPayload(), checks: checksPayload(),
    note: `The diff could not be measured, even after a retry: the diffstat ` +
      `line's output did not have the shape parseDiffstat requires (the ` +
      `begin/end markers naming ${firstReviewRange}, a line count matching ` +
      `the rows between them, a numstat exit of 0, or a well-formed ` +
      `numstat/comment-count row). This is a measurement problem, not a ` +
      `code problem; re-run.`,
  })
}
size = sizeOf(sizeParsed)

// The budget was set from Triage's estimate, or a flat default when it gave none,
// but a resumed run's first review range is whatever the last run left unreviewed,
// or the whole branch when a merge came after the record's head, and either can be
// bigger than that budget allows for. Raised, never lowered, and never over an
// explicit args.runBudget.
if (recordedHead && typeof args?.runBudget !== 'number') {
  const needed = budgetForLoc(size.totalChurn)
  if (needed > runBudget) {
    const wasBudget = runBudget
    const wasNote = runBudgetNote
    runBudget = needed
    runBudgetNote = `raised to fit the ${size.totalChurn} changed lines of the first review ` +
      `range ${firstReviewRange}, from ${Math.round(wasBudget / 1000)}k (${wasNote})`
    log(`run budget raised to ${Math.round(runBudget / 1000)}k (first review range ` +
        `${firstReviewRange}, ${size.totalChurn} changed lines)`)
  }
}

// Below RATIO_MIN_CODE the ratio does not apply at all: an ordinary TDD
// change reads well over 1:1 test-to-code and must not halt on that alone.
// Above it, support code (tests, docs, and a code file's own comments)
// outweighing the actual code by more than MAX_SUPPORT_RATIO halts before
// any lens spends a token on a diff that is mostly something other than the
// change itself.
if (size.code >= RATIO_MIN_CODE) {
  const supportRatio = typeof args?.supportRatio === 'number' ? args.supportRatio : MAX_SUPPORT_RATIO
  const ratio = (size.test + size.doc + size.comment) / size.code
  if (ratio > supportRatio) {
    sReview.close()
    return await halted('Review', {
      plan: plan.plan, implemented: impl.summary, gates: gatesPayload(), checks: checksPayload(),
      note: `Support code outweighs the actual change: ${size.code} code ` +
        `line(s) against ${size.test} test, ${size.doc} doc and ` +
        `${size.comment} comment line(s) (${ratio.toFixed(1)}:1), over the ` +
        `${supportRatio}:1 limit. If this ratio is intentional for this ` +
        `change, pass args.supportRatio to raise it, then re-run.`,
    })
  }
}
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
    // The only lens shown the whole ticket: it cannot quote an acceptance
    // criterion it is never given, and it is the one charged with judging
    // against them.
    needsTicket: true,
    charge: `You are an adversarial reviewer. REFUTE the claim that this ` +
      `implementation is complete, through one lens: hunt for acceptance ` +
      `criteria that are unmet, half-met, or untested. For an unmet criterion, ` +
      `set category to unmet-criterion and copy the criterion into ` +
      `criterion_quote verbatim from the ticket text below, whitespace and ` +
      `all: the script checks it is actually there, so a paraphrase does not ` +
      `hold the run.`,
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
      `working designs is never one. Put that same demonstration in reproducer ` +
      `too: the command from evidence, run from the worktree root, with its ` +
      `expected and actual output.\n` +
      `You are deliberately shown only the ticket's settled decisions, if it ` +
      `has any, never the rest of its text; triage owns the rest of its ` +
      `claims. Absence of evidence in the repo is not evidence of absence, so ` +
      `never rest a finding on a negative grep.`,
  },
}

// The advocate is a reviewer, counted and gated with the rest: a one-line diff
// used to get zero reviewers and an advocate anyway, which is the ratio the
// files<=1/totalChurn latch in lensKeysFor exists to prevent.
const lensKeys = lensKeysFor(size)
const lenses = (args?.reviewers != null
    ? lensKeys.slice(0, Math.max(0, Math.min(args.reviewers, lensKeys.length)))
    : lensKeys)
  .filter(k => !(k === 'advocate' && args?.devilsAdvocate === false))
  .map(k => LENS[k])
// A resumed run's first range can be under the bar while its carried findings
// still get fixed; reviewerCount 0 would ship those fixes unreviewed, since it
// also switches off the tail reviews, the mutation review and the PR guard.
const reviewerCount = lenses.length ||
  (carriedOpen.length && args?.reviewers == null ? 1 : 0)
if (!lenses.length) {
  log(`review skipped: ${size.files} file(s), ${size.codeChurn} code churn ` +
      `line(s) is under the ${INLINE_LOC}-line bar; adversarial lenses on a ` +
      `one-liner is the ratio this workflow is trying to avoid` +
      (reviewerCount
        ? `; the ${carriedOpen.length} carried finding(s) are still tracked, and ` +
          `their fix rounds are still reviewed`
        : ''))
} else {
  log(`review: ${lenses.map(l => l.label).join(', ')}`)
  if (!settledDecisions) {
    log(`review: ticket ${ticket} has no "Constraints, or decisions already ` +
        `taken" section (or could not be read), so lenses get no settled ` +
        `decisions`)
  }
}
// Every finding gets an id and a recorded_at the moment it enters the script,
// here and nowhere else: the initial review, every fix round's tail review,
// and the post-mutation review all return through reviewOf. Neither is asked
// of the model -- a model-supplied id is exactly as unreliable as the
// model-supplied title this replaces, so the script stamps its own.
let findingSeq = Math.max(0, ...[...carriedOpen, ...carriedNotes].map(f => Number(f.id.slice(1))))
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
// Stated to every lens: what a reproducer is and who decides on it. Repeated
// rather than assumed, since a lens that never reads CHECK_RUN's contract has
// no other way to learn the script judges exit_code plus the marker line.
const REPRODUCER_CONTRACT =
  `A reproducer is one command, run from the worktree root (${wt.path}). It ` +
  `exits 0 when the code is correct. Print ${REPRODUCED_MARKER} on a line of ` +
  `its own when, and only when, you have observed the defect, and exit ` +
  `nonzero; never print it unconditionally, from a ||-style fallback, or ` +
  `from a trap. A nonzero exit without that line counts as the reproducer ` +
  `failing to run, never as a demonstration. expected and actual hold what ` +
  `it prints. The command must be self-contained: set any environment ` +
  `variable it reads yourself, never rely on your own shell's exports, and ` +
  `keep its output short. Any helper file it needs goes under the scratch ` +
  `path already given above, never in the tracked tree. The script decides ` +
  `on exit_code plus that marker line, never on your account of it.`

const reviewOf = async (range, tag, picked, known = [], knownCharge = '') => {
  const out = await parallel(picked.map((lens) => () =>
    treeAgent(
      `${lens.charge}\n` +
      `${NATIVE_TOOLS(wt.path)}\n` +
      (lens.needsTicket ? ticketSpec() : '') +
      decisionsSpec() +
      (planAdditions.length
        ? `Beyond the ticket, the plan added the work below, each with the ` +
          `reason it gave:\n${additionsLines()}\nSet scope on every finding: ` +
          `addition when the defect sits in that added work, ticket when it ` +
          `sits in what the ticket asked for.\n`
        : '') +
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
      `narrow applies.\n` +
      `Return at most ${MAX_FINDINGS_PER_LENS} findings, most serious first. An ` +
      `empty list is the expected result for a correct change. Every finding ` +
      `carries a category: wrong-result, crash, gate-bypass, unmet-criterion, ` +
      `docs, wording, design, scope, or other. Only wrong-result, crash, ` +
      `gate-bypass and unmet-criterion can hold this run, and only when they ` +
      `also carry a reproducer (unmet-criterion additionally needs criterion_quote). ` +
      `Everything else is still worth raising and reaches the pull request as a ` +
      `note for a human to judge, but it never blocks. ${REPRODUCER_CONTRACT}` +
      (known.length
        ? `\nThe findings below were already reported earlier this run, each ` +
          `with its id in brackets, whether still open, already settled, or ` +
          `recorded as a note. If what you would report is the same ` +
          `underlying issue as one of these, even worded quite differently, or a ` +
          `variant of one already fixed (the same defect resurfacing elsewhere, ` +
          `or an edge case its fix missed), set duplicate_of to that id instead ` +
          `of inventing a new one; report a finding with no duplicate_of only ` +
          `for a genuinely different bug.\n` +
          known.map(k => `[${k.id}] ${k.title} (${k.file}): ${k.claim}`).join('\n') +
          knownCharge
        : ''),
      { label: `${tag}:${lens.label}`, phase: 'Review', schema: FINDINGS,
        model: 'opus', effort: effortFor.review })))
  // parallel() (the runtime global) catches each thunk's own error and hands
  // back null for the ones that threw, so a budget refusal inside one lens
  // reads, past this point, exactly like a lens that died for any other
  // reason. Re-checking the flag here is what tells the two apart, and
  // re-throwing is what lets the top-level catch turn it into a budget halt
  // instead of a dead-lens one.
  if (runBudgetSpent) throw new Error(`touchstone: run budget spent during review (${tag})`)
  // A lens with no result did not review the range, so a round holding one
  // must not read as clean. Only `findings: []` is a clean lens.
  const dead = picked.filter((_, i) => !Array.isArray(out[i]?.findings))
    .map(l => `${tag}:${l.label}`)
  if (dead.length) {
    log(`${tag}: no result from ${dead.join(', ')}; the review did not run`)
    return { raised: [], dead }
  }
  const raised = out.flatMap((r, i) => {
    const findings = r.findings
    // The script slices, not the schema: a maxItems failure would null the
    // whole lens's result rather than trim it.
    if (findings.length > MAX_FINDINGS_PER_LENS) {
      log(`${tag}:${picked[i].label}: returned ${findings.length} findings; ` +
          `keeping the first ${MAX_FINDINGS_PER_LENS}, dropping ` +
          `${findings.length - MAX_FINDINGS_PER_LENS}`)
    }
    return findings.slice(0, MAX_FINDINGS_PER_LENS)
  }).map(f => ({ ...f, id: `f${++findingSeq}`, recorded_at: headOf(range),
    // With no additions there is nothing else a finding could sit in. With
    // some, a missing or invalid scope is counted apart, never guessed.
    scope: !planAdditions.length ? 'ticket'
      : (f.scope === 'ticket' || f.scope === 'addition') ? f.scope : 'unattributed' }))
  // A finding with no span reaches the fixer as a bare filename, and the
  // brief no longer points at the range either, so it arrives with less than
  // it used to. Counted so that drift shows up instead of being argued about.
  const spanless = raised.filter(f => typeof f.line_start !== 'number')
  if (spanless.length) {
    log(`${tag}: ${spanless.length} of ${raised.length} finding(s) carry no line span: ` +
        spanless.map(f => `${f.id} (${f.file})`).join(', '))
  }
  return { raised, dead: [] }
}

// Everything from here to the PR is measured against reviewedThrough: the SHA
// an adversary has actually read up to. It only ever advances by way of a
// review, so a phase that commits without one leaves it behind and the PR
// guard below refuses.
let reviewedThrough = headOf(impl.commit_range)
// Where the next review starts. Until one has read something, that is the start
// of the first range: a resumed run's first range can get no lens (under the bar,
// kept only for the carried findings' fixes), and a review starting at
// reviewedThrough would skip those commits yet still move reviewedHead past them.
const startOf = (range) => (range.includes('..') ? range.split('..')[0] : range).trim()
const reviewStart = () => reviewedHead ?? startOf(firstReviewRange)

// Lenses cannot see each other, and contentKeyOf cannot merge them: two
// reviewers describe one bug in different words. A failure keeps everything,
// which costs a duplicate rather than losing a defect.
const collapseDuplicates = async (findings) => {
  if (findings.length < 2 || reviewerCount < 2) return findings
  const grouped = await dispatch(
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
  const byId = new Map(findings.map(f => [f.id, f]))
  const dropped = new Set()
  for (const g of grouped?.groups ?? []) {
    const ids = (Array.isArray(g?.ids) ? g.ids : [])
      .map(stripBrackets)
      .filter(id => findings.some(f => f.id === id))
    if (ids.length < 2) continue
    // The survivor is whichever id in the group would actually hold the
    // run, not just the first one a dedup agent happened to list: keeping
    // ids[0] unconditionally meant a demonstrated, blocking defect from one
    // lens could be discarded in favor of a non-blocking one from another.
    const survivor = ids.find(id => looksBlocking(byId.get(id))) ?? ids[0]
    for (const id of ids) if (id !== survivor) dropped.add(id)
    log(`review: ${ids.filter(id => id !== survivor).join(', ')} fold into ${survivor}` +
        (g.why ? ` (${g.why})` : ''))
  }
  if (!dropped.size) return findings
  log(`review: ${findings.length} finding(s) from ${reviewerCount} reviewers ` +
      `collapse to ${findings.length - dropped.size}`)
  return findings.filter(f => !dropped.has(f.id))
}

// classify() turns a lens's structured fields into a script decision -- a
// candidate whose reproducer gets executed next, or a note -- never a
// reviewer's own self-reported severity. ctx.hunks, given from the first
// tail review on (never the initial review), is a per-file list of
// new-side [start, end] ranges the preceding fix (or mutation) range
// actually touched.
const collapseWs = (s) => String(s ?? '').replace(/\s+/g, ' ').trim()
// Shared between classify() and collapseDuplicates(): whether a finding
// carries every field a reproducer needs, never just that the key is present.
const hasCompleteReproducer = (f) => {
  const r = f.reproducer
  return !!(r && typeof r === 'object' &&
    ['kind', 'command', 'expected', 'actual'].every(k => typeof r[k] === 'string' && r[k].length > 0))
}
// unmet-criterion's evidence is the quote, not a reproducer: verbatim and
// long enough that a paraphrase cannot pass as a match.
const criterionQuoteFound = (f) => {
  const quote = collapseWs(f.criterion_quote)
  const haystack = collapseWs(`${ticketDetail.description}\n${ticketDetail.comments}`)
  return quote.length >= 20 && haystack.includes(quote)
}
// Mirrors classify()'s own gate, ahead of classify() ever seeing the
// finding: used only to rank collapseDuplicates()'s survivor, never to
// decide anything classify() itself decides.
const looksBlocking = (f) =>
  BLOCKING_CATEGORIES.has(f?.category) &&
  (f.category === 'unmet-criterion' ? criterionQuoteFound(f) : hasCompleteReproducer(f))
// A lens is told to use absolute paths (treeAgent's own rule) but hands
// classify() its own file field, which hunks (keyed on the repo-relative
// "+++ b/<path>" git prints) never matches unless normalized the same way: an
// absolute path under the worktree, a ./-relative one, and a trailing
// ":line" or ":start-end" a lens sometimes appends to the path itself.
const normalizeFilePath = (p) => {
  let s = String(p ?? '').replace(/:\d+(?:-\d+)?$/, '')
  if (s === wt.path) s = ''
  else if (s.startsWith(`${wt.path}/`)) s = s.slice(wt.path.length + 1)
  return s.replace(/^\.\//, '').replace(/^[ab]\//, '')
}
const overlapsHunk = (f, hunks) => {
  const ranges = hunks?.[normalizeFilePath(f.file)]
  if (!ranges?.length) return false
  const start = typeof f.line_start === 'number' ? f.line_start : null
  if (start === null) return false // a finding with no span never overlaps
  const end = typeof f.line_end === 'number' ? f.line_end : start
  return ranges.some(r => start <= r.end && r.start <= end)
}
// Parses `git diff --unified=0` header lines, given back verbatim by an
// agent because the script itself cannot run git. "+++ b/path" names the
// file that follows; each "@@ -o,p +n,q @@" contributes one new-side range.
// A pure deletion hunk (q=0) adds no new line, but the deleted content used
// to sit right at that point in the new file, so it still anchors a
// one-line range there (n and n+1, the surviving lines either side of the
// gap) rather than contributing nothing: a fix or mutation commit that only
// removes code (a dropped guard, a reverted fix) must still be in range.
const parseHunks = (lines) => {
  const hunks = {}
  let file = null
  for (const line of Array.isArray(lines) ? lines : []) {
    const plus = /^\+\+\+ (?:b\/)?(.+)$/.exec(line)
    if (plus) { file = plus[1] === '/dev/null' ? null : plus[1]; continue }
    const at = /^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@/.exec(line)
    if (at && file) {
      const start = Number(at[1])
      const count = at[2] !== undefined ? Number(at[2]) : 1
      const range = count > 0 ? { start, end: start + count - 1 } : { start, end: start + 1 }
      ;(hunks[file] ??= []).push(range)
    }
  }
  return hunks
}
const classify = (f, ctx) => {
  const dupe = duplicateTargetOf(f, ctx.known ?? [])
  if (dupe && !dupe.byReference) return { drop: true }
  if (dupe && dupe.byReference) {
    if (ctx.settledIds?.has(dupe.hit.id)) {
      return { note: { ...f, reason: 'residual', residual_of: dupe.hit.id, round: ctx.round } }
    }
    if (ctx.openIds?.has(dupe.hit.id)) {
      // Already tracked as open; no need to re-add it.
      return { drop: true }
    }
    // References a note: nothing tracks that id in a way that can block, so
    // fall through and classify this finding on its own merits instead of
    // dropping it in silence. The reference the first report was folded
    // under (a bad reproducer, an earlier out-of-range round, the wrong
    // category) does not mean the defect itself is gone.
  }
  if (!BLOCKING_CATEGORIES.has(f.category)) {
    return { note: { ...f, reason: 'category', round: ctx.round } }
  }
  if (!hasCompleteReproducer(f)) {
    return { note: { ...f, reason: 'no-reproducer', round: ctx.round } }
  }
  // The quote proves the criterion exists; the reproducer is what shows the
  // change misses it. Without the second, the only way to decide "unmet" is a
  // model reading the code, which is exactly what blocking must not rest on.
  if (f.category === 'unmet-criterion' && !criterionQuoteFound(f)) {
    return { note: { ...f, reason: 'quote-not-found', round: ctx.round } }
  }
  if (ctx.hunks && !overlapsHunk(f, ctx.hunks)) {
    return { note: { ...f, reason: 'out-of-range', round: ctx.round } }
  }
  return { candidate: f }
}

// Replaces verifyOpen: whether a finding is fixed is decided by executing its
// reproducer, never by a model's judgement of a diff. One haiku dispatch runs
// script-built lines against the worktree's current HEAD, the same way
// checks:run does (runnerPrompt): a before line, one line per reproducer, the
// range's new-side hunk headers when diffRange is given (for classify()'s
// out-of-range rule), and an end line. Each reproducer's output goes to a log
// under the worktree's git dir; the shell prints its exit code and whether
// the log holds REPRODUCED_MARKER on a line of its own, so neither the exit
// nor the marker is ever a model's copy. Porcelain before and after goes to
// before.log and status.log beside it: dirt already there before anything
// runs must never be blamed on a reproducer, and dirt a reproducer leaves
// must not be carried into whatever commits next.
let reproAttempt = 0
const REPRO_AREA = 'touchstone-repro'
// A reproducer command can span several lines (a python3 -c script, a
// heredoc), and a newline spliced into the fence would split one line into
// fragments the runner executes on their own, outside the worktree and the
// log. So it travels base64-encoded and is decoded inside the line; an empty
// decode prints nothing, which reads as unmeasured rather than as a pass.
const reproLineFor = (it, run) =>
  `${logDirFor(run, REPRO_AREA)} && mkdir -p "$d" && ` +
  `c="$(python3 -c 'import base64,sys;sys.stdout.write(base64.b64decode(sys.argv[1]).decode())' ${base64Of(it.reproducer.command)})" && [ -n "$c" ] && ` +
  `{ (cd ${shQuote(wt.path)} && bash -c "$c") >|"$d/${it.id}.log" 2>&1; e=$?; ` +
  `if grep -aqxE '[[:space:]]*${REPRODUCED_MARKER}[[:space:]]*' "$d/${it.id}.log"; then m=1; else m=0; fi; ` +
  `r="$(printf 'TOUCHSTONE_REPRO %s %s %s %s' ${it.id} "$e" "$m" "$d/${it.id}.log")"; ${rowTo(false)}; }`
// The diff goes to a file rather than a pipe, so its own exit decides which
// block is printed: a git failure (a bad range) prints a failed line, which
// leaves the hunks unknown without voiding the reproducer rows.
const hunksLineFor = (run, range) =>
  `${logDirFor(run, REPRO_AREA)} && mkdir -p "$d" && ` +
  `{ git -C ${shQuote(wt.path)} diff --unified=0 --no-color ${shQuote(range)} >|"$d/diff.log" 2>|"$d/diff.err"; g=$?; ` +
  `if [ "$g" -ne 0 ]; then printf 'TOUCHSTONE_HUNKS_FAILED %s %s\\n' ${run} "$g"; ` +
  `else grep -aE '^(\\+\\+\\+ |@@ )' "$d/diff.log" >|"$d/hunks.log"; ` +
  `printf 'TOUCHSTONE_HUNKS_BEGIN %s\\n' ${run}; cat "$d/hunks.log"; ` +
  `printf 'TOUCHSTONE_HUNKS_END %s %s\\n' ${run} "$(grep -c '' "$d/hunks.log")"; fi; }`
// The before line starts the rows file, so every reproducer line appends.
const reproLinesFor = (runnable, run, diffRange) => [
  `${logDirFor(run, REPRO_AREA)} && mkdir -p "$d" && : >|"$d/rows" && ${porcelainTo('before')} && ` +
    `{ ${stateOf('before')}; printf 'TOUCHSTONE_REPRO_BEFORE %s %s\\n' ${run} "$s"; }`,
  ...runnable.map(it => reproLineFor(it, run)),
  ...(diffRange ? [hunksLineFor(run, diffRange)] : []),
  `${logDirFor(run, REPRO_AREA)} && mkdir -p "$d" && ${porcelainTo('status')} && ${rowsSumTo} && ` +
    `{ ${stateOf('status')}; printf 'TOUCHSTONE_REPRO_END %s %s %s %s\\n' ${run} "$s" "$k" "$d/status.log"; }`,
]
const executeAtHead = async (items, label, diffRange) => {
  const runnable = items.filter(it => it.reproducer?.command)
  reproAttempt++
  const run = `${planId}-${label.replace(/[^A-Za-z0-9._-]+/g, '-')}-${reproAttempt}`
  const out = await treeAgent(runnerPrompt(label, reproLinesFor(runnable, run, diffRange)),
    { label, schema: REPRO_RUN, model: 'haiku', effort: 'low' })
  const parsed = parseReproRun(out?.output, runnable.map(it => it.id), run, Boolean(diffRange))
  // An unmeasured run is read exactly as a call that returned nothing: no
  // rows (so callers' not-executed handling applies), hunks unknown rather
  // than empty, and nothing seen dirty.
  if (parsed.reason) {
    log(`${label}: unmeasured (${parsed.reason})`)
    return { runs: new Map(), hunks: null, dirty: false, porcelain: '', preexisting: !runnable.length,
      unmeasured: parsed.reason }
  }
  if (parsed.diffExit !== undefined) {
    log(`${label}: git diff exited ${parsed.diffExit}, so this range's hunks are unknown`)
  }
  return {
    runs: new Map(parsed.rows.map(r => [r.id, { exit_code: r.exit, reproduced: r.reproduced, log: r.log }])),
    hunks: parsed.hunkLines ? parseHunks(parsed.hunkLines) : null,
    dirty: parsed.dirty,
    porcelain: parsed.statusLog,
    // True when nothing this call could have dirtied: either it ran no
    // reproducer at all (the mutation-hunk fetch calls with an empty items
    // list), or the tree was already dirty before anything below ran. Without
    // this, a fixer whose crap-commit.sh was refused -- the wrapper leaves the
    // staged changes in place, with no reset/stash/restore -- gets a halt
    // blaming "a reproducer execution" for dirt that predates it.
    preexisting: !runnable.length || parsed.before,
    unmeasured: null,
  }
}

// A settled finding's re-check gets the retry a candidate gets: an unmeasured
// call has no rows at all, and regressedOf reads a missing row as regressed,
// so one copy slip would otherwise reopen every settled finding and, at the
// mutation head, blame the gate's commits for undoing them. Still unmeasured
// after the retry, the result carries both reasons for unmeasuredSettledHalt.
// A missing row inside a measured call keeps its meaning there.
const executeSettled = async (items, label) => {
  const first = await executeAtHead(items, label)
  if (first.dirty || !first.unmeasured) return first
  const second = await executeAtHead(items, `${label}:retry`)
  if (second.dirty || !second.unmeasured) return second
  return { ...second, reasons: [first.unmeasured, second.unmeasured] }
}

// A reproducer run that leaves the tree dirty halts outright: a check that
// writes to the tree (a ledger, a generated file, a mutated fixture) must not
// be silently carried into whatever commits next, the same principle
// runChecks already applies to the repo's own discovered checks. extraOpen is
// for a caller (the post-mutation site) whose first-call verdicts live in a
// local variable rather than the closed-over `open`, so they still reach the
// halt instead of being silently dropped alongside it.
const dirtyReproducerHalt = async (phaseName, exec, extraOpen = []) => halted(phaseName, {
  plan: plan.plan, implemented: impl.summary, gates: gatesPayload(),
  unresolved_findings: [...open, ...extraOpen], notes, fix_rounds: round,
  note: exec.preexisting
    ? `The working tree was already dirty before this check ran, so nothing ` +
      `it did caused it. What git status reported afterwards is in ` +
      `${exec.porcelain}. Find what left it dirty earlier in this round, then re-run.`
    : `A reproducer execution left the working tree dirty. What git status ` +
      `reported afterwards is in ${exec.porcelain}. Nothing further ran; find ` +
      `which reproducer writes to the tree, then re-run.`,
})

// Every note is a finding the run does not block on: raised, but not
// demonstrated, not blocking-category, not in range, or a residual of a fix
// already verified. Separate from unresolved_findings, which stays reserved
// for what actually holds the run.
let notes = [...carriedNotes]
const knownForRound = () => [...settled, ...open, ...notes]
// Splits a batch of freshly raised findings into candidates (subject to an
// executeAtHead call next) and notes, via classify() alone.
const classifyBatch = (raised, hunks, round) => {
  const settledIds = new Set(settled.map(f => f.id))
  const openIds = new Set(open.map(f => f.id))
  const known = knownForRound()
  const candidates = [], freshNotes = []
  for (const f of raised) {
    const r = classify(f, { known, settledIds, openIds, hunks, round })
    if (r.candidate) candidates.push(r.candidate)
    else if (r.note) freshNotes.push(r.note)
  }
  return { candidates, freshNotes }
}
// The initial-classification rule, shared by the initial review, each
// round's fresh tail-review candidates, and the post-mutation review. Keyed
// on outcomeOf, not the bare exit code: only 'reproduced' -- nonzero exit and
// the marker, both actually observed -- opens the candidate. A missing row
// (not-executed, the executor dropped it or the whole call failed schema) is
// even less evidence than an errored run and must not open one either, or a
// finding can hold the run on a reproducer nobody ever ran (gh-113). Unlike
// passed/could-not-run/errored, not-executed is no verdict at all, so it is
// returned apart from asNotes for executeAndDispose below to retry.
const disposeCandidates = (candidates, runs, round) => {
  const opened = [], asNotes = [], notExecuted = []
  for (const f of candidates) {
    const row = runs?.get(f.id)
    const reproducer_run = reproducerRunOf(row, round)
    if (reproducer_run.outcome === 'passed') asNotes.push({ ...f, reason: 'did-not-reproduce', round, reproducer_run })
    else if (reproducer_run.outcome === 'could-not-run') asNotes.push({ ...f, reason: 'reproducer-could-not-run', round, reproducer_run })
    else if (reproducer_run.outcome === 'errored') asNotes.push({ ...f, reason: 'reproducer-errored', round, reproducer_run })
    else if (reproducer_run.outcome === 'not-executed') notExecuted.push({ ...f, reproducer_run })
    else opened.push({ ...f, reproducer_run })
  }
  return { opened, asNotes, notExecuted }
}

// Runs `candidates` through executeAtHead under `label`; whatever comes back
// with no row is retried exactly once, at the same head, as its own
// executeAtHead call restricted to just those candidates and labelled
// `${label}:retry` -- the retry-once rule runChecks already applies to a
// discovered check (#116), extended here to a reproducer nobody measured
// (gh-113). The retry runs only after the first call fully resolves, so it
// can never overlap another agent in the worktree, same as every
// executeAtHead call. Its rows are merged into the first call's before
// reclassifying the whole batch, so a candidate the retry did measure counts
// on that verdict and one still missing surfaces in notExecuted for the
// caller to halt on. A dirty result from the first call has no verdicts to
// carry (disposeCandidates never ran). A dirty retry is narrower -- the retry
// only ever covers the notExecuted subset -- so the first call's opened and
// asNotes, already measured clean at this same head, ride along on the dirty
// result instead of being dropped; the caller folds them in before turning
// the result into a dirtyReproducerHalt at its own phase.
const executeAndDispose = async (candidates, label, round) => {
  const exec = await executeAtHead(candidates, label)
  if (exec.dirty) return { dirty: true, exec, opened: [], asNotes: [], notExecuted: [] }
  const first = disposeCandidates(candidates, exec.runs, round)
  if (!first.notExecuted.length) return { dirty: false, ...first }
  const retryIds = new Set(first.notExecuted.map(f => f.id))
  const retryCandidates = candidates.filter(f => retryIds.has(f.id))
  const retryExec = await executeAtHead(retryCandidates, `${label}:retry`)
  if (retryExec.dirty) return { dirty: true, exec: retryExec, ...first }
  const merged = new Map(exec.runs)
  for (const [id, row] of retryExec.runs) merged.set(id, row)
  return { dirty: false, ...disposeCandidates(candidates, merged, round) }
}

// Reports whatever executeAndDispose still could not measure after its
// retry. Never handed to a fixer: like unmeasuredChecksHalt above, this is
// about measurement, not the code, so no fix round should be spent guessing
// at a reproducer nobody ran. Defined here, before open/notes/round/
// fixRoundSpend, for the same reason unmeasuredChecksHalt is: it reads only
// plan, impl, gatesPayload and checksPayload by closure, and every call site passes
// unresolved_findings, notes, fix_rounds and (once it exists) fix_round_output
// through extra instead, so calling this from the initial review -- before
// fixRoundSpend is declared -- is not the TDZ failure the comment above
// unmeasuredChecksHalt describes.
const notExecutedHalt = (at, notExecuted, extra) => {
  const note = `${notExecuted.length} finding(s) could not be measured after ` +
    `a retry. This halt is about measurement, not the code: the executor did ` +
    `not run ${notExecuted.length === 1 ? 'this reproducer' : 'these reproducers'}, ` +
    `so no verdict exists either way.\n` +
    notExecuted.map(f => `- ${f.id}: ${f.title}`).join('\n')
  return halted(at, {
    plan: plan.plan, implemented: impl.summary, gates: gatesPayload(),
    checks: checksPayload(), ...extra, note,
  })
}

// Reports a review round in which a lens returned no result. Same shape and
// the same TDZ reasoning as notExecutedHalt: it reads only plan, impl,
// gatesPayload and checksPayload by closure, and every call site passes
// unresolved_findings, notes, fix_rounds and (once it exists) fix_round_output
// through extra. Never handed to a fixer: nothing was found, so nothing is open
// because of it.
const deadLensHalt = (at, dead, extra) => {
  const note = `${dead.length} review ${dead.length === 1 ? 'lens' : 'lenses'} ` +
    `returned no result (stalled, errored, or failed schema after retries), so ` +
    `the review did not run over its range. reviewed_through was not moved past ` +
    `that range, and a re-run reviews it again.\n` +
    dead.map(label => `- ${label}`).join('\n')
  return halted(at, {
    plan: plan.plan, implemented: impl.summary, gates: gatesPayload(),
    checks: checksPayload(), ...extra, note,
  })
}

// Same shape and TDZ reasoning as notExecutedHalt. The settled findings are
// carried in unresolved_findings with their last measured run, so the record
// keeps them and a re-run checks them again; nothing was reopened.
// Marks a settled finding whose re-check could not be measured, so a resumed
// run re-checks it instead of briefing a fixer on a fix already shown to hold.
const awaitingRecheck = (f) => ({ ...f, awaiting_recheck: true })
const unmeasuredSettledHalt = (at, items, exec, extra) => halted(at, {
  plan: plan.plan, implemented: impl.summary, gates: gatesPayload(),
  checks: checksPayload(), ...extra,
  note: `The re-check of ${items.length} settled finding(s) could not be ` +
    `measured, even after a retry (first run ${exec.reasons[0]}; second run ` +
    `${exec.reasons[1]}). This is a measurement failure, not a regression: ` +
    `no fix was shown undone, and each is carried below with its last measured ` +
    `run so a re-run checks it again.\n` +
    items.map(f => `- ${f.id}: ${f.title}`).join('\n'),
})

let settled = []
// A carried finding whose reproducer nobody ran (notExecutedHalt recorded it)
// is a candidate, not a verdict: held in open it would stay open through every
// fix round on a reproducer that may not even run.
const unmeasured = (f) => f.reproducer_run?.outcome === 'not-executed'
// What keeps `unmeasured` true only of a candidate no row ever came back for: a
// finding that was demonstrated and whose later row the executor dropped keeps
// the last run that happened. Recorded as not-executed it would be measured again
// on resume as a candidate, and a reproducer that then errors or passes would turn
// a finding that was demonstrated into a note.
const latestRun = (f, run) =>
  run.outcome === 'not-executed' && f.reproducer_run ? f.reproducer_run : run
const carriedPassed = (f) => f.awaiting_recheck === true
settled = carriedOpen.filter(carriedPassed).map(({ awaiting_recheck, ...f }) => f)
let awaiting = carriedOpen.filter(unmeasured)
let open = carriedOpen.filter(f => !unmeasured(f) && !carriedPassed(f))
let round = 0
widenBudgetHaltState(() => ({
  unresolved_findings: [...open, ...awaiting], notes, fix_rounds: round }))
scopeSplit = () => {
  const split = { ticket: 0, addition: 0, unattributed: 0 }
  for (const f of [...settled, ...open, ...awaiting]) split[f.scope]++
  return split
}
if (awaiting.length) {
  const disposed = await executeAndDispose(awaiting, 'reproduce:carried', 0)
  open.push(...disposed.opened)
  notes.push(...disposed.asNotes)
  const placed = new Set([...disposed.opened, ...disposed.asNotes].map(f => f.id))
  const unplaced = awaiting.filter(f => !placed.has(f.id))
  awaiting = unplaced
  if (disposed.dirty) { sReview.close(); return await dirtyReproducerHalt('Review', disposed.exec, unplaced) }
  if (disposed.notExecuted.length) {
    sReview.close()
    return await notExecutedHalt('Review', disposed.notExecuted, {
      unresolved_findings: [...open, ...disposed.notExecuted], notes, fix_rounds: round,
    })
  }
}
if (lenses.length) {
  const carriedCharge = carriedOpen.length || carriedNotes.length
    ? `\nThose came from an earlier run on this branch and are still tracked. ` +
      `Reference one by its id in duplicate_of; never raise it again.`
    : ''
  const { raised: raisedRaw, dead } =
    await reviewOf(firstReviewRange, 'review', lenses, knownForRound(), carriedCharge)
  if (dead.length) {
    sReview.close()
    return await deadLensHalt('Review', dead, { unresolved_findings: open, notes, fix_rounds: round })
  }
  const raised = await collapseDuplicates(raisedRaw)
  const { candidates, freshNotes } = classifyBatch(raised, null, 0)
  notes.push(...freshNotes)
  if (candidates.length) {
    const disposed = await executeAndDispose(candidates, 'reproduce:review', 0)
    open.push(...disposed.opened)
    notes.push(...disposed.asNotes)
    if (disposed.dirty) { sReview.close(); return await dirtyReproducerHalt('Review', disposed.exec, disposed.notExecuted) }
    if (disposed.notExecuted.length) {
      sReview.close()
      return await notExecutedHalt('Review', disposed.notExecuted, {
        unresolved_findings: [...open, ...disposed.notExecuted], notes, fix_rounds: round,
      })
    }
  }
  reviewedHead = headOf(firstReviewRange)
}
sReview.close()

const sFix = stage('fix')
// Per round, just the fix agent's own output tokens (the cost this ticket
// targets), separate from stageSpend.fix which also carries the executor and
// tail review.
const fixRoundSpend = []
widenBudgetHaltState(() => ({ fix_round_output: fixRoundSpend }))

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

// Advisory only: a finding's evidence may have moved since it was recorded. One
// cheap agent checks each against its evidence, not just its file. Skipped only
// when the loop ran zero rounds, since nothing could have changed then; a loop
// that stopped on budget after a round already committed is exactly the case
// this exists for, so it runs regardless of budget. Any rejection degrades to
// nothing marked, never to losing the halt.
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
      // A budget refusal must reach the top-level catch, not be swallowed
      // into "reporting findings unmarked": that would let a halted run
      // return a normal-looking result instead of stopping.
      if (runBudgetSpent) throw e
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

// A settled finding stays settled only while its reproducer keeps passing.
// Every head the code moves to after a finding settled re-runs that
// reproducer, whatever any lens reported: a later round's fix, or the mutation
// gate's own commits, can undo an earlier fix, and a lens happening to set
// duplicate_of is not something that check can depend on. A residual note is
// therefore only ever a note. A missing row counts as regressed, the same
// "could not measure is not a pass" rule the open list gets. Not gated on
// budget: trusting a fix nobody re-checked is worse than one cheap dispatch.
// errored is split out from regressed: a fix nobody could re-measure (the
// reproducer itself crashed) is not the same claim as one whose reproducer
// ran clean and still shows the defect, and the two are reported separately.
const regressedOf = (items, exec, round) => {
  const regressed = [], errored = []
  for (const f of items) {
    const row = exec?.runs?.get(f.id)
    const reproducer_run = reproducerRunOf(row, round)
    if (reproducer_run.outcome === 'passed') continue
    ;(reproducer_run.outcome === 'errored' ? errored : regressed)
      .push({ ...f, reproducer_run: latestRun(f, reproducer_run) })
  }
  return { regressed, errored }
}

while ((open.length || blockingChecksOpen()) && round < MAX_REVIEW_ROUNDS && !outOfBudget() && !sFix.over()) {
  round++
  enterPhase('Fix')
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
    `${NATIVE_TOOLS(wt.path)} ${GENERATED_FILES}\n` +
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
        `context. Where a reproduce command is shown, check it exits 0 before ` +
        `you consider that one fixed; an unmet-criterion finding with none is ` +
        `judged by the criterion it names instead.\n` +
        open.map(f => `- ${f.title} (${locusOf(f)}): ${f.claim}` +
          (f.reproducer?.command ? ` [reproduce: ${f.reproducer.command}]` : '') +
          (f.reproducer_run?.outcome === 'errored'
            ? `\n  Its reproducer itself failed to run last round: exit ` +
              `${f.reproducer_run.exit_code}, no marker line. This is not a ` +
              `demonstration of the defect; find out why the command failed. ` +
              (f.reproducer_run.log
                ? `Its full output is in ${f.reproducer_run.log}, under the ` +
                  `worktree's git directory, outside the worktree: you may Read ` +
                  `it although it does not start with ${wt.path}/. Read it from ` +
                  `the end.`
                : '')
            : '')).join('\n') + `\n`
      : '') +
    (blockingChecksOpen()
      ? `The repo's own checks below are failing. Each is a script the repo ` +
        `already runs and decides the same way every time, not a reviewer's ` +
        `opinion; make every one pass rather than silencing its output.\n` +
        renderChecks(redChecks)
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
    sFix.close()
    return await halted('Fix', {
      plan: plan.plan, implemented: impl.summary, gates: gatesPayload(),
      unresolved_findings: await markStale(open), fix_rounds: round,
      fix_round_output: fixRoundSpend,
      stopped_because:
        `the fixer hit a NEXT_ACTION of UNSUPPORTED_LANGUAGE and halted rather ` +
        `than editing a gate marker, so these findings have not had every round`,
      notes,
      checks: checksPayload(),
      note: fixed.note,
    })
  }
  const head = fixed?.head_sha?.trim()
  if (head && head !== reviewedThrough) {
    const leak = await planLeakHalt(head, 'Fix', {
      unresolved_findings: open, fix_rounds: round, fix_round_output: fixRoundSpend, notes,
    })
    if (leak) { sFix.close(); return leak }
  }
  const tailReviewable =
    reviewerCount && head && head !== reviewedThrough && !outOfBudget()
  const roundRange = head && head !== reviewedThrough
    ? `${reviewStart()}..${head}` : reviewedThrough

  // One at a time, never beside another agent in this worktree. executeAtHead
  // judges a reproducer by the tree's porcelain before and after its own
  // commands, so a file anything else writes meanwhile is blamed on a
  // reproducer: a tail review's own test log once halted a clean run this way.
  // The open list's call also fetches this round's diff hunks, which the tail
  // review's fresh findings are classified against below.
  const settledBefore = [...settled]
  const execOld = await executeAtHead(open, `reproduce:fix:${round}`, roundRange)
  if (execOld?.dirty) { sFix.close(); return await dirtyReproducerHalt('Fix', execOld) }
  const execSettled = settledBefore.length
    ? await executeSettled(settledBefore, `reproduce:settled:${round}`)
    : null
  if (execSettled?.dirty) { sFix.close(); return await dirtyReproducerHalt('Fix', execSettled) }
  if (execSettled?.reasons) {
    sFix.close()
    return await unmeasuredSettledHalt('Fix', settledBefore, execSettled, {
      unresolved_findings: [...open, ...settledBefore.map(awaitingRecheck)], notes, fix_rounds: round,
      fix_round_output: fixRoundSpend,
    })
  }
  const tail = tailReviewable
    ? await reviewOf(roundRange, `review:fix:${round}`, [LENS.correctness], knownForRound())
    : { raised: [], dead: [] }

  // For an open finding, fixed means its reproducer exits 0 at this round's
  // head; anything else stays open, carrying the latest reproducer_run
  // (never accumulated) so the next fix brief can render it. A missing row
  // (the agent dropped it) still leaves it open rather than guessing it was
  // resolved, and keeps the last run that did happen (latestRun).
  const stillOpen = []
  let erroredOpen = 0
  for (const f of open) {
    const row = execOld?.runs?.get(f.id)
    const outcome = outcomeOf(row)
    if (outcome === 'passed') { settled.push({ ...f, reproducer_run: reproducerRunOf(row, round) }); continue }
    if (outcome === 'errored') erroredOpen++
    stillOpen.push({ ...f, reproducer_run: latestRun(f, reproducerRunOf(row, round)) })
  }
  open = stillOpen
  if (erroredOpen) {
    log(`round ${round}: ${erroredOpen} open finding(s) whose reproducer errored (nonzero, no marker)`)
  }

  const { regressed, errored: erroredSettled } =
    execSettled ? regressedOf(settledBefore, execSettled, round) : { regressed: [], errored: [] }
  if (regressed.length) {
    const ids = new Set(regressed.map(f => f.id))
    settled = settled.filter(f => !ids.has(f.id))
    open = open.concat(regressed)
    log(`round ${round}: ${regressed.length} earlier fix(es) no longer hold at this head; reopened`)
  }
  if (erroredSettled.length) {
    const ids = new Set(erroredSettled.map(f => f.id))
    settled = settled.filter(f => !ids.has(f.id))
    open = open.concat(erroredSettled)
    log(`round ${round}: ${erroredSettled.length} earlier fix(es) could not be re-measured this ` +
        `round (reproducer errored, nonzero, no marker); reopened`)
  }

  if (tailReviewable) {
    if (tail.dead.length) {
      sFix.close()
      return await deadLensHalt('Fix', tail.dead, {
        unresolved_findings: open, notes, fix_rounds: round, fix_round_output: fixRoundSpend,
      })
    }
    const { candidates, freshNotes } = classifyBatch(tail.raised, execOld?.hunks ?? null, round)
    notes.push(...freshNotes)
    if (candidates.length) {
      const disposed = await executeAndDispose(candidates, `reproduce:fix:${round}:fresh`, round)
      if (disposed.opened.length) log(`round ${round}: the fix itself introduced ${disposed.opened.length} new finding(s)`)
      open = open.concat(disposed.opened)
      notes.push(...disposed.asNotes)
      if (disposed.dirty) { sFix.close(); return await dirtyReproducerHalt('Fix', disposed.exec, disposed.notExecuted) }
      if (disposed.notExecuted.length) {
        sFix.close()
        return await notExecutedHalt('Fix', disposed.notExecuted, {
          unresolved_findings: [...open, ...disposed.notExecuted], notes,
          fix_rounds: round, fix_round_output: fixRoundSpend,
        })
      }
    }
    reviewedThrough = head
    reviewedHead = head
  } else if (head) {
    reviewedThrough = head
  }

  if (checksBlocking && discoveredChecks.length && head && head !== lastCheckedHead && !outOfBudget()) {
    ;({ red: redChecks, unmeasured: unmeasuredChecks } = await runChecks())
    lastCheckedHead = head
    if (unmeasuredChecks.length) {
      sFix.close()
      return await unmeasuredChecksHalt('Fix', {
        unresolved_findings: open, notes, fix_rounds: round, fix_round_output: fixRoundSpend,
      })
    }
  }

  log(`round ${round}: ${open.length} finding(s) still open` +
      (discoveredChecks.length ? `, ${redChecks.length} check(s) still red` : ''))
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
    notes,
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
              `${redChecks.map(c => c.id).join(', ')}.`
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
enterPhase('Mutation')
const sMut = stage('mutation')
let mutation = { green: false, detail: 'not run' }
widenBudgetHaltState(() => ({ mutation }))

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
// Whether the gate is green, and the head it left, are read from a line the
// script builds and the shell prints, never from the mutation agent's own
// account: green is mutation-check.sh --verify exiting 0, and the head is git's.
// The line names mutation-check.sh without its directory, so the agent
// running the line supplies the path, as the signals probe does.
let verdictAttempt = 0
// What --verify exits when the ledger is missing or stale for this head.
const VERIFY_UNRECORDED = 5
const mutationVerifyLineFor = (run) =>
  `${logDirFor(run, 'touchstone-gates')} && mkdir -p "$d" && ` +
  `h="$(git -C ${shQuote(wt.path)} rev-parse HEAD 2>/dev/null)" && ` +
  `{ mutation-check.sh ${shQuote(wt.path)} --verify >|"$d/mutation-verify.log" 2>&1; e=$?; ` +
  `t="$(sed -n '$s/^mutation-check: EXIT=\\([0-9][0-9]*\\) .*$/\\1/p' "$d/mutation-verify.log")"; ` +
  `printf 'TOUCHSTONE_MUTATION_VERIFY %s %s %s %s %s\\n' ${run} "$e" "\${t:--}" "$h" "$d/mutation-verify.log"; }`
const MUTATION_CHECK_PATH_NOTE =
  `mutation-check.sh is named without its directory. It sits in the ` +
  `crap-controlled-changes skill's directory, beside crap-check.sh: invoke ` +
  `that skill to learn where that is, and replace that one word with its ` +
  `absolute path. That is the only change you may make to the line.\n`
const measureVerdict = async (label) => {
  verdictAttempt++
  const run = `${planId}-mutation-verify-${verdictAttempt}`
  const out = await treeAgent(runnerPrompt(label, [mutationVerifyLineFor(run)], MUTATION_CHECK_PATH_NOTE),
    { label, schema: VERDICT_RUN, model: 'haiku', effort: 'low' })
  return parseMutationVerify(out?.output, run)
}
// 127 most often means the relay left the bare script name in place, which a
// second relay can get right; any other setup exit is the gate's own answer.
const SCRIPT_NOT_FOUND = 127
const verifyMutation = async (label) => {
  const first = await measureVerdict(label)
  if (!first.reason && first.exit === SCRIPT_NOT_FOUND) {
    log(`${label}: mutation-check.sh was not found (exit 127), retrying once`)
    return await measureVerdict(`${label}:retry`)
  }
  if (!first.reason) return first
  log(`${label}: unmeasured (${first.reason}), retrying once`)
  const second = await measureVerdict(`${label}:retry`)
  if (!second.reason) return second
  return { reasons: [first.reason, second.reason] }
}
// needs_user_run breaks the loop instead of retrying: a run that cannot fit the
// Bash ceiling returns the same answer every attempt, and each one costs the
// ceiling in wall clock before saying so. An unmeasured verdict breaks it too:
// another mutation run cannot fix a relay that did not print its line, and so
// does a --verify that could not run at all (127, 2): another attempt meets
// the same missing script or setup failure.
for (let attempt = 1; attempt <= MAX_GATE_ATTEMPTS && !mutation.green
     && !mutation.needs_user_run && !mutation.unsupported_language
     && !mutation.verdict_unmeasured && !mutation.verify_setup
     && !outOfBudget() && !sMut.over(); attempt++) {
  const reported = await treeAgent(
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
    `Anything you commit is reviewed before the PR opens.\n` +
    `Return scored=true if crap-commit.sh printed that it scored a commit you ` +
    `made this attempt, scored=false if you committed nothing or it printed ` +
    `nothing to score. Base this on what it printed, never on whether ` +
    `.crap-gated exists and never on your own judgement of the change. If it ` +
    `printed its own gate message, copy it verbatim into gate_note.`,
    { label: `mutation:${attempt}`, schema: GATE, model: 'sonnet', effort: 'high' })
  if (reported?.scored === true) {
    scored = true
    if (reported?.gate_note) scoredNote = reported.gate_note
  } else if (reported?.gate_note) {
    unscoredNote = reported.gate_note
  }
  const verdict = await verifyMutation(`mutation-verify:${attempt}`)
  const { head_sha: agentHead, ...agentSaid } = reported ?? mutation
  mutation = verdict.reasons
    ? { ...agentSaid, green: false, verdict_unmeasured: true, verdict_reasons: verdict.reasons }
    : { ...agentSaid, green: verdict.exit === 0, head_sha: verdict.head,
        verify: { exit: verdict.exit, log: verdict.log },
        ...(verdict.exit !== 0 && verdict.exit !== VERIFY_UNRECORDED ? { verify_setup: true } : {}) }
}
sMut.close()

if (!mutation.green) {
  return await halted('Mutation', {
    plan: plan.plan, implemented: impl.summary, gates: gatesPayload(),
    mutation, unresolved_findings: open, notes,
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
        `the ledger green and the gate will cost milliseconds. ${prNote()}. ` +
        `mutation-pr-gate.py blocks gh pr ready until --verify reads green.`
      : mutation.verdict_unmeasured
      ? `The mutation gate's verdict could not be measured: the line that runs ` +
        `mutation-check.sh ${wt.path} --verify did not print what the script ` +
        `asked for, even after a retry (first: ${mutation.verdict_reasons[0]}; ` +
        `second: ${mutation.verdict_reasons[1]}). This halt is about ` +
        `measurement, not about mutants. ${prNote()}. ` +
        `mutation-pr-gate.py blocks gh pr ready until --verify reads green.`
      : mutation.verify_setup
      ? `mutation-check.sh ${wt.path} --verify could not run: it exited ` +
        `${mutation.verify.exit} (${mutation.verify.log}), which is neither green ` +
        `(0) nor a missing or stale ledger (${VERIFY_UNRECORDED}). 127 means the ` +
        `script was not found and 2 is a setup failure. No further mutation ` +
        `attempt was made. ${prNote()}. ` +
        `mutation-pr-gate.py blocks gh pr ready until --verify reads green.`
      : `Mutation gate still red after ${MAX_GATE_ATTEMPTS} attempt(s)` +
        (mutation.verify
          ? `: mutation-check.sh --verify exited ${mutation.verify.exit} ` +
            `(${mutation.verify.log}), so the gate has not recorded a green run ` +
            `for this head, either because mutants survived or because no run ` +
            `was recorded`
          : '') +
        `. ${prNote()}. mutation-pr-gate.py blocks gh pr ready until --verify reads green. ` +
        `Kill surviving mutants with tests, or approve a provably equivalent ` +
        `mutant with mutation-check.sh ${wt.path} --accept.`,
  })
}

// The mutation gate commits: new tests, and real fixes when a survivor exposes
// a genuine defect. Those are production changes nobody has read yet.
const mutHead = mutation.head_sha?.trim()
if (mutHead && mutHead !== reviewedThrough) {
  const leak = await planLeakHalt(mutHead, 'Mutation', { mutation, unresolved_findings: open, notes })
  if (leak) return leak
}
if (mutHead && mutHead !== reviewedThrough && settled.length) {
  const execSettledMut = await executeSettled(settled, 'reproduce:settled:mutation')
  if (execSettledMut.dirty) return await dirtyReproducerHalt('Review', execSettledMut)
  if (execSettledMut.reasons) {
    return await unmeasuredSettledHalt('Review', settled, execSettledMut, {
      mutation, unresolved_findings: [...open, ...settled.map(awaitingRecheck)], fix_rounds: round,
      fix_round_output: fixRoundSpend, notes,
    })
  }
  const { regressed: undone, errored: erroredMut } = regressedOf(settled, execSettledMut, 'mutation')
  if (undone.length || erroredMut.length) {
    return await halted('Review', {
      plan: plan.plan, implemented: impl.summary, mutation,
      gates: gatesPayload(),
      unresolved_findings: [...undone, ...erroredMut], fix_rounds: round, fix_round_output: fixRoundSpend,
      notes,
      note: `The mutation gate's own commits (${reviewedThrough}..${mutHead}) ` +
            (undone.length
              ? `undid ${undone.length} verified fix(es): their reproducers fail ` +
                `again at that head. `
              : '') +
            (erroredMut.length
              ? `left ${erroredMut.length} verified fix(es) unmeasured: their ` +
                `reproducer errored (nonzero, no marker) rather than confirming ` +
                `or failing. `
              : '') +
            `No fix round runs after the gate. ${prNote()}. Judge each: fix it, ` +
            `or reject it as wrong.`,
    })
  }
}
if (reviewerCount && mutHead && mutHead !== reviewedThrough && !outOfBudget()) {
  enterPhase('Review')
  const mutRange = `${reviewStart()}..${mutHead}`
  // False when no review has read the first range yet (it got no lens), so
  // mutRange also holds commits that are not the gate's own.
  const mutOnly = reviewStart() === reviewedThrough
  // Fetches this range's own new-side hunks before the lens runs, the same
  // rule classify() applies to every review after the initial one: a finding
  // whose span the mutation commits never touched is not a finding against
  // this range.
  const execHunks = await executeAtHead([], 'reproduce:mutation', mutRange)
  if (execHunks.dirty) return await dirtyReproducerHalt('Review', execHunks)
  // An undone fix is already caught above by executing its reproducer, so the
  // lens is not asked to report one.
  const { raised: raisedMut, dead } = await reviewOf(mutRange, 'review:mutation', [LENS.correctness], knownForRound(),
    `\nEach of those is already tracked, and an undone fix is caught by ` +
    `re-running its reproducer, so do not report one of them again. A defect ` +
    `you still perceive in code these commits do not touch is not a finding ` +
    `against this range: leave it out.`)
  if (dead.length) {
    return await deadLensHalt('Review', dead, {
      mutation, unresolved_findings: open, fix_rounds: round, fix_round_output: fixRoundSpend, notes,
    })
  }
  const { candidates, freshNotes } = classifyBatch(raisedMut, execHunks.hunks ?? null, 'mutation')
  notes.push(...freshNotes)
  let freshOpen = []
  if (candidates.length) {
    const disposed = await executeAndDispose(candidates, 'reproduce:mutation:fresh', 'mutation')
    freshOpen = disposed.opened
    notes.push(...disposed.asNotes)
    if (disposed.dirty) return await dirtyReproducerHalt('Review', disposed.exec, [...freshOpen, ...disposed.notExecuted])
    if (disposed.notExecuted.length) {
      return await notExecutedHalt('Review', disposed.notExecuted, {
        mutation, unresolved_findings: [...freshOpen, ...disposed.notExecuted],
        fix_rounds: round, fix_round_output: fixRoundSpend, notes,
      })
    }
  }
  if (freshOpen.length) {
    return await halted('Review', {
      plan: plan.plan, implemented: impl.summary, mutation,
      gates: gatesPayload(),
      unresolved_findings: freshOpen, fix_rounds: round, fix_round_output: fixRoundSpend,
      notes,
      note: (mutOnly
              ? `The mutation gate's own commits (${mutRange})`
              : `The commits in ${mutRange}, the mutation gate's own ` +
                `(${reviewedThrough}..${mutHead}) and earlier ones no review had read,`) +
            ` introduced ${freshOpen.length} finding(s) with a demonstrated reproducer. The ` +
            `fix rounds are spent. ${prNote()}. Judge each: fix it, or reject ` +
            `it as wrong.`,
    })
  }
  reviewedThrough = mutHead
  reviewedHead = mutHead
} else if (mutHead) {
  reviewedThrough = mutHead
}

const { checks: advisoryChecks } = checksFrom(wt.checks_source, ADVISORY_CHECKS_HEADING, 'advisory')
if (advisoryChecks.length && !outOfBudget()) {
  const advisory = await executeChecks(advisoryChecks)
  const { red, unmeasured } = classifyResults(advisoryChecks, advisory)
  for (const c of red) {
    notes.push({ category: 'advisory', reason: 'advisory', title: `Advisory check \`${c.command}\` reported`,
      claim: `exit ${c.exit_code}`, log: c.log })
  }
  if (unmeasured.length) {
    log(`advisory checks: ${unmeasured.map(c => c.id).join(', ')} not measured; nothing reported for them`)
  }
}

// Reaching here means every gate is green: the Gate, Fix and Mutation halts
// above are terminal, so there is no red state left to guard against.
// Script-rendered, not agent-composed: every note's own title and claim,
// with no mention of a reviewer, a lens, or this workflow, since none of
// that is something a PR reader can act on.
const notesSection = notes.length
  ? `\nThis run also produced ${notes.length} non-blocking note(s): things ` +
    `worth a human's look, not defects that had to be fixed before this PR ` +
    `could open. Add a short "Notes" section near the end of the PR body ` +
    `listing each one's title and claim exactly as given below, with no ` +
    `other attribution:\n` +
    notes.map(n => n.log
      ? `- ${n.title}: ${n.claim}. Read ${n.log} (from its end: it sits under the ` +
        `git directory, outside the worktree), quote what that check reported as ` +
        `this note's claim, and never put that path in the PR.`
      : `- ${n.title}: ${n.claim}`).join('\n') + `\n`
  : ''
// Every commit through reviewedThrough has been reviewed. Whether any came
// after it is counted by git as revisions, never by comparing SHA strings,
// which differ in abbreviation on an honest branch, and the shell prints the
// count: the pr agent used to run and judge this itself.
const unreviewedLine =
  `h="$(git -C ${shQuote(wt.path)} rev-parse HEAD 2>/dev/null)" && ` +
  `n="$(git -C ${shQuote(wt.path)} rev-list --count ${shQuote(reviewedThrough)}.."$h" 2>/dev/null)" && ` +
  `printf 'TOUCHSTONE_UNREVIEWED %s %s %s\\n' ${shQuote(reviewedThrough)} "$n" "$h"`
const countUnreviewed = async () => {
  const measure = async (label) => parseUnreviewed((await treeAgent(runnerPrompt(label, [unreviewedLine]),
    { label, schema: VERDICT_RUN, model: 'haiku', effort: 'low' }))?.output, reviewedThrough)
  const first = await measure('pr-unreviewed')
  if (!first.reason) return first
  log(`pr-unreviewed: unmeasured (${first.reason}), retrying once`)
  const second = await measure('pr-unreviewed:retry')
  if (!second.reason) return second
  return { reasons: [first.reason, second.reason] }
}
let pr = null
if (args?.openPr !== false && !outOfBudget()) {
  enterPhase('PR')
  if (reviewerCount) {
    const unreviewed = await countUnreviewed()
    if (unreviewed.reasons || unreviewed.count > 0) {
      return await halted('PR', {
        plan: plan.plan, implemented: impl.summary, gates: gatesPayload(),
        mutation, unresolved_findings: open, notes,
        note: unreviewed.reasons
          ? `Whether commits exist past the reviewed head ${reviewedThrough} could ` +
            `not be measured: the count line did not print what the script asked ` +
            `for, even after a retry (first: ${unreviewed.reasons[0]}; second: ` +
            `${unreviewed.reasons[1]}). The run stopped before the PR step. ${prNote()}.`
          : `${unreviewed.count} commit(s) in ${reviewedThrough}..${unreviewed.head} ` +
            `have not been reviewed, so the run stopped before the PR step. ${prNote()}. ` +
            `Read them with git log --oneline ${reviewedThrough}..${unreviewed.head}.`,
      })
    }
  }
  const sPr = stage('pr')
  pr = await treeAgent(
    `Open a pull request for the work on this branch.\n` +
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
      ? `A ${draftPr.draft ? 'draft ' : ''}PR already exists for this branch: #${draftPr.number}. Do NOT ` +
        `open a second one. Push the branch, update that PR's title and body to ` +
        `describe the finished change, then mark it ready for review with ` +
        `gh pr ready ${draftPr.number}. Marking it ready is the last thing you ` +
        `do and the only thing that signals the work is finished; a PR left in ` +
        `draft reads as abandoned. Return its url with opened=true.\n`
      : `No draft PR exists for this branch, so push it and open the PR with ` +
        `gh. Return the PR url.\n`) +
    notesSection +
    (planAdditions.length
      ? `The plan took on work the ticket did not ask for. Add a short "Beyond ` +
        `the ticket" section to the PR body listing each item and its reason ` +
        `exactly as given below:\n${additionsLines()}\n`
      : '') +
    `Do not merge it.`,
    { label: 'pr', schema: PR, model: 'sonnet', effort: 'medium' })
  sPr.close()
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
  plan_additions: planAdditions,
  scope_split: scopeSplit(),
  pipeline_version: pipelineVersion,
  stage_spend: stageSpend,
  implemented: impl.summary,
  gates: gatesPayload(),
  checks: checksPayload(),
  mutation,
  size,
  signals,
  reviewers: reviewerCount,
  // Raised but never blocking: wrong category, no reproducer, an unmet
  // criterion whose quote was not found, out of range, or a residual of a
  // fix already verified. Separate from unresolved_findings, which is
  // reserved for what actually held the run.
  notes,
  reviewed_through: reportedHead(),
  fix_rounds: round,
  fix_round_output: fixRoundSpend,
  unresolved_findings: open,
  pr,
  needs_user: args?.openPr !== false && !pr?.opened,
  record_file: runRecordFile,
}
return result

} catch (e) {
  // runBudgetSpent's presence, not this error's identity, is the only safe
  // test: parallel() (reviewOf) and markStale's own try/catch each re-throw
  // only when that flag is set, but a plain `throw e` from either still
  // arrives here as an ordinary Error, indistinguishable from one by message
  // alone. Closing every open stage first means the halt's stage_spend is
  // complete even for the stage that was actually running when the budget
  // was refused, not just the ones that reached their own close().
  if (runBudgetSpent) {
    const stillOpen = closeOpenStages()
    // commands/deliver.md tells the invoking session to report the note
    // verbatim, so the per-stage spend has to live in the note itself, not
    // only in the stage_spend payload a plain report never surfaces.
    const byStage = Object.entries(stageSpend)
      .map(([name, spent]) => `${name} ${Math.round(spent / 1000)}k`).join(', ')
    return await halted(currentPhase, {
      ...budgetHaltState(),
      note: `Run budget exhausted (${Math.round(runBudget / 1000)}k output ` +
        `tokens, ${runBudgetNote}). Spend at halt: ` +
        `${Math.round(runBudgetSpent.spent / 1000)}k output tokens (${byStage}). The ` +
        `'${runBudgetSpent.refused}' dispatch was refused before it could ` +
        `run` +
        (stillOpen.length
          ? `; still in progress when the budget was refused: ${stillOpen.join(', ')}`
          : '') +
        `. ${prNote()}`,
    })
  }
  // Any other throw (an agent out of structured-output retries, a stall the
  // host gave up on) still ends as a halt with a payload, so the invoking
  // session has a record to write rather than a crash with nothing in it.
  closeOpenStages()
  return await halted(currentPhase ?? 'Setup', {
    ...budgetHaltState(),
    note: `The run stopped on an error in ${currentPhase ?? 'Setup'}: ` +
      `${e?.message ?? String(e)}. ${prNote()}`,
  })
}
