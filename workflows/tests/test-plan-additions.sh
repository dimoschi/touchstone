#!/usr/bin/env bash
# Work a plan adds beyond its ticket (gh-95): the planner returns it apart from
# the ticket's own work, the implementer and every reviewer see it marked as
# such, findings are attributed to ticket or addition scope, and the run
# record carries both so the split can be measured.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/harness.sh"

run_js_scenarios <<'JS_EOF'
const ADDITION = { item: 'Add reviewBase for the review range',
  consequence: 'removing the fast-forward moves the cut point the review range starts from' }
const planWith = (additions) => ({ plan: 'stub plan', acceptance_criteria: [], risky_areas: [],
  task_demands_implementation: false, additions })
const promptOf = (captured, label) => captured.calls.find(c => c.label === label)?.prompt ?? ''
const TEAM = { scope: 'team', estimated_loc: 50 }
const TWO_FINDINGS = {
  correctness: [{ title: 'Range reaches past the fork', file: 'src/p.js', claim: 'c1', evidence: 'e1',
    scope: 'addition' }],
  advocate: [{ title: 'Dirty main still refused', file: 'src/q.js', claim: 'c2', evidence: 'e2',
    scope: 'ticket' }],
}

// Scenario PAA -- the normal case: no additions. The planner is asked for
// them; nothing downstream grows by a word.
async function scenarioPAA() {
  console.log('\n== scenario PAA: a plan with no additions changes no implementer or review prompt')
  const { result, captured } = await run({
    triage: TEAM, plannerResult: planWith([]),
    initialReview: { correctness: [], advocate: [] },
  })
  check('the planner is asked for additions', /additions/.test(promptOf(captured, 'planner')), true)
  check('the implementer sees no additions section', /beyond the ticket/i.test(promptOf(captured, 'implementer')), false)
  check('a reviewer is not asked for scope', /Set scope/.test(promptOf(captured, 'review:correctness')), false)
  check('the record carries an empty additions list', result.plan_additions, [])
  check('the record carries the split', result.scope_split, { ticket: 0, addition: 0, unattributed: 0 })
}

// Scenario PAB -- an addition reaches the implementer and every lens marked
// as beyond the ticket, with its stated consequence.
async function scenarioPAB() {
  console.log('\n== scenario PAB: an addition reaches the implementer and the reviewers, marked')
  const { result, captured } = await run({
    triage: TEAM, plannerResult: planWith([ADDITION]),
    initialReview: { correctness: [], advocate: [] },
  })
  const impl = promptOf(captured, 'implementer')
  check('the implementer sees the addition', impl.includes(ADDITION.item), true)
  check('the implementer sees its consequence', impl.includes(ADDITION.consequence), true)
  check('the implementer is told it is beyond the ticket', /beyond the ticket/i.test(impl), true)
  for (const lens of ['review:correctness', 'review:advocate']) {
    const p = promptOf(captured, lens)
    check(`${lens} sees the addition`, p.includes(ADDITION.item), true)
    check(`${lens} is asked for scope`, /Set scope/.test(p), true)
  }
  check('the record carries the addition', result.plan_additions, [ADDITION])
}

// Scenario PAC -- a run halts at Fix with a finding in the addition: the halt
// says which scope each open finding sits in.
async function scenarioPAC() {
  console.log('\n== scenario PAC: a Fix halt attributes each open finding and reports the split')
  const { result } = await run({
    args: { maxReviewRounds: 1 },
    triage: TEAM, plannerResult: planWith([ADDITION]),
    initialReview: TWO_FINDINGS,
    verify: () => false,
    fixHead: () => 'fix00000000000000000000000000000000000001',
    staleness: () => [],
  })
  check('halted at Fix', result.halted_at, 'Fix')
  check('each open finding carries its scope',
    (result.unresolved_findings ?? []).map(f => [f.title, f.scope]),
    [['Range reaches past the fork', 'addition'], ['Dirty main still refused', 'ticket']])
  check('the halt reports the split', result.scope_split, { ticket: 1, addition: 1, unattributed: 0 })
  check('the halt carries the additions', result.plan_additions, [ADDITION])
}

// Scenario PAD -- without additions everything is ticket scope, whatever a
// reviewer wrote.
async function scenarioPAD() {
  console.log('\n== scenario PAD: with no additions every finding is ticket scope')
  const { result } = await run({
    args: { maxReviewRounds: 1 },
    triage: TEAM, plannerResult: planWith([]),
    initialReview: TWO_FINDINGS,
    verify: () => false,
    fixHead: () => 'fix00000000000000000000000000000000000001',
    staleness: () => [],
  })
  check('every finding is ticket scope',
    (result.unresolved_findings ?? []).map(f => f.scope), ['ticket', 'ticket'])
  check('the split counts both as ticket', result.scope_split, { ticket: 2, addition: 0, unattributed: 0 })
}

// Scenario PAE -- with additions, a finding whose reviewer gave no valid scope
// is counted as unattributed, never guessed into one side.
async function scenarioPAE() {
  console.log('\n== scenario PAE: a missing or invalid scope is unattributed')
  const { result } = await run({
    args: { maxReviewRounds: 1 },
    triage: TEAM, plannerResult: planWith([ADDITION]),
    initialReview: {
      correctness: [{ title: 'No scope given', file: 'src/p.js', claim: 'c1', evidence: 'e1' }],
      advocate: [{ title: 'Bad scope given', file: 'src/q.js', claim: 'c2', evidence: 'e2', scope: 'both' }],
    },
    verify: () => false,
    fixHead: () => 'fix00000000000000000000000000000000000001',
    staleness: () => [],
  })
  check('both are unattributed',
    (result.unresolved_findings ?? []).map(f => f.scope), ['unattributed', 'unattributed'])
  check('the split counts them as unattributed', result.scope_split, { ticket: 0, addition: 0, unattributed: 2 })
}

// Scenario PAF -- a finished run counts the findings it fixed too: where the
// defects landed is the measure, not only where they survived.
async function scenarioPAF() {
  console.log('\n== scenario PAF: a finished run counts settled findings in the split and lists additions in the PR')
  const { result, captured } = await run({
    args: { openPr: true },
    triage: TEAM, plannerResult: planWith([ADDITION]),
    initialReview: TWO_FINDINGS,
    verify: () => true,
    fixHead: () => 'fix00000000000000000000000000000000000001',
    staleness: () => [],
    prResult: { opened: true, url: 'https://example.invalid/pr/1', note: 'stub' },
  })
  check('the run does not halt', result.halted_at, undefined)
  check('the split counts the settled findings', result.scope_split, { ticket: 1, addition: 1, unattributed: 0 })
  check('the result carries the additions', result.plan_additions, [ADDITION])
  const pr = promptOf(captured, 'pr')
  check('the PR body is asked to list the addition', pr.includes(ADDITION.item), true)
  check('the PR body is asked to give its consequence', pr.includes(ADDITION.consequence), true)
}

// Scenario PAG -- a plan reused through args.plan keeps the additions it came
// with.
async function scenarioPAG() {
  console.log('\n== scenario PAG: args.planAdditions travels with a reused plan')
  const { result, captured } = await run({
    args: { plan: 'reused plan', planAdditions: [ADDITION] },
    triage: TEAM,
    initialReview: { correctness: [], advocate: [] },
  })
  check('the planner did not run', callCount(captured, 'planner'), 0)
  check('the implementer sees the reused addition', promptOf(captured, 'implementer').includes(ADDITION.item), true)
  check('the record carries it', result.plan_additions, [ADDITION])
}

const SCENARIOS = [scenarioPAA, scenarioPAB, scenarioPAC, scenarioPAD, scenarioPAE, scenarioPAF, scenarioPAG]
JS_EOF

finish
