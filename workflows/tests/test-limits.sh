#!/usr/bin/env bash
# Spend limits are opt-in: with none set a run keeps going while it makes
# progress, stops on a stall rather than a count, and a limit comes from a
# /touchstone:deliver flag or the repo's .touchstone.json (prepared.limits),
# the flag winning. See harness.sh.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/harness.sh"

run_js_scenarios <<'JS_EOF'
const VERSION = /const PIPELINE_VERSION = '([^']+)'/.exec(src)[1]
const ROOT = '/work/repo'
const WT = `${ROOT}/.claude/worktrees/gh-21-stub`

function prepared(over) {
  return {
    repo_root: ROOT, worktree: WT, branch: 'feat/gh-21-stub', base: 'main', ticket: '21',
    ticket_marker: 'gh-21', mode: 'fresh', worktree_action: 'created', detail: 'cut it',
    markers: { crap_gated: true, mutation_gated: false },
    plugin: { name: 'touchstone', version: VERSION },
    base_manifest: { found: true, refreshed: true, name: 'touchstone', version: VERSION, detail: 'read' },
    checks_source: { file: `${WT}/AGENTS.md`, sections: [{ heading: '## Other', fence: '' }], detail: 'read' },
    prior_head: null, prior_head_check: null, limits: {},
    ...over,
  }
}

const UNBOUNDED = { maxReviewRounds: undefined, maxGateAttempts: undefined, runBudget: undefined }
const headOf = (n) => `c${String(n).padStart(39, '0')}`
const findings = (n) => Array.from({ length: n }, (_, i) =>
  ({ title: `Finding ${i + 1}`, file: `src/f${i + 1}.js`, claim: 'c', evidence: 'e' }))
// Round r fixes f1..fr: every round closes one more finding.
const oneFixedPerRound = (id, round) => Number(id.slice(1)) <= round ? true : undefined
const progressing = (n) => ({
  initialReview: { correctness: findings(n), advocate: [] },
  verify: oneFixedPerRound, fixHead: headOf, staleness: () => [],
})
const stuck = {
  initialReview: { correctness: findings(1), advocate: [] },
  verify: () => undefined, fixHead: headOf, staleness: () => [],
}

async function scenarioLA() {
  console.log('\n== scenario LA: with no round limit, the fix loop runs past three rounds while each closes a finding')
  const { result, captured } = await run({ args: { ...UNBOUNDED }, ...progressing(4) })
  check('a fourth round ran', callCount(captured, 'fix:4'), 1)
  check('the run did not halt at Fix', result.halted_at === 'Fix', false)
}

async function scenarioLB() {
  console.log('\n== scenario LB: with no round limit, two rounds that close nothing end the loop')
  const { result, captured } = await run({ args: { ...UNBOUNDED }, ...stuck })
  check('a second round ran', callCount(captured, 'fix:2'), 1)
  check('no third round ran', callCount(captured, 'fix:3'), 0)
  check('it halts at Fix', result.halted_at, 'Fix')
  check('the reason is the stall, not a limit',
    /last 2 rounds closed no finding or check/.test(result.stopped_because ?? ''), true)
}

async function scenarioLC() {
  console.log('\n== scenario LC: a round limit in .touchstone.json applies when no flag sets one')
  const { result, captured } = await run({
    args: { ...UNBOUNDED, prepared: prepared({ limits: { maxReviewRounds: 1 } }) }, ...stuck })
  check('no second round ran', callCount(captured, 'fix:2'), 0)
  check('the reason is the repo limit',
    /1-round limit was reached/.test(result.stopped_because ?? ''), true)
}

async function scenarioLD() {
  console.log('\n== scenario LD: a round limit passed as a flag wins over .touchstone.json')
  const { captured } = await run({
    args: { ...UNBOUNDED, maxReviewRounds: 2, prepared: prepared({ limits: { maxReviewRounds: 1 } }) },
    ...progressing(3) })
  check('the second round ran', callCount(captured, 'fix:2'), 1)
  check('no third round ran', callCount(captured, 'fix:3'), 0)
}

async function scenarioLE() {
  console.log('\n== scenario LE: a stage budget in .touchstone.json caps that stage')
  const { result, captured } = await run({
    args: { ...UNBOUNDED, prepared: prepared({ limits: { stageBudgets: { fix: 1000 } } }) },
    budgetPerAgentCall: 5000, ...stuck })
  check('no second round ran', callCount(captured, 'fix:2'), 0)
  check('the reason is the fix ceiling',
    /fix stage passed its 1k output-token ceiling/.test(result.stopped_because ?? ''), true)
}

async function scenarioLF() {
  console.log('\n== scenario LF: limits naming an unknown stage are refused before anything dispatches')
  const { result, captured } = await run({
    args: { ...UNBOUNDED, prepared: prepared({ limits: { stageBudgets: { fixes: 1000 } } }) }, ...stuck })
  check('it halts at Worktree', result.halted_at, 'Worktree')
  check('the note names the limits field', /limits/.test(result.note ?? ''), true)
  check('nothing was implemented', callCount(captured, 'implementer'), 0)
}

async function scenarioLG() {
  console.log('\n== scenario LG: with no run budget set, none is derived')
  const { captured } = await run({ args: { ...UNBOUNDED }, ...progressing(1) })
  check('the log says there is none', captured.logs.includes('run budget: none'), true)
}

async function scenarioLH() {
  console.log('\n== scenario LH: with no attempt limit, mutation keeps going while each attempt commits')
  const { captured } = await run({
    args: { ...UNBOUNDED }, mutationGated: true,
    initialReview: { correctness: [], advocate: [] }, staleness: () => [],
    mutationResult: (a) => ({ green: a >= 4, head_sha: headOf(100 + a), detail: 'stub', scored: true }),
  })
  check('a fourth attempt ran', callCount(captured, 'mutation:4'), 1)
}

async function scenarioLI() {
  console.log('\n== scenario LI: with no attempt limit, two mutation attempts that commit nothing end the loop')
  const { result, captured } = await run({
    args: { ...UNBOUNDED }, mutationGated: true,
    initialReview: { correctness: [], advocate: [] }, staleness: () => [],
    mutationResult: () => ({ green: false, head_sha: REVIEWED_THROUGH, detail: 'stub', scored: false }),
  })
  check('a second attempt ran', callCount(captured, 'mutation:2'), 1)
  check('no third attempt ran', callCount(captured, 'mutation:3'), 0)
  check('it halts at Mutation', result.halted_at, 'Mutation')
  check('the note gives the stall as the reason',
    /the last 2 of which committed nothing/.test(result.note ?? ''), true)
}

async function scenarioLJ() {
  console.log('\n== scenario LJ: the documented example passes the limits check and applies')
  const example = JSON.parse(fs.readFileSync(
    path.join(path.dirname(SCRIPT_PATH), '..', 'docs', 'touchstone.example.json'), 'utf8'))
  const { result, captured } = await run({
    args: { ...UNBOUNDED, prepared: prepared({ limits: example }) }, ...progressing(5) })
  check('it is not refused', result.halted_at === 'Worktree', false)
  check('its round limit applies', callCount(captured, 'fix:4'), 0)
}

const SCENARIOS = [scenarioLA, scenarioLB, scenarioLC, scenarioLD, scenarioLE,
  scenarioLF, scenarioLG, scenarioLH, scenarioLI, scenarioLJ]
JS_EOF

finish
