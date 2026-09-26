#!/usr/bin/env bash
# The run-wide token budget (gh-118): how runBudget is derived from triage,
# how dispatch() refuses a call past it, and how that refusal reaches a halt
# rather than reading as a clean run. New for this ticket, not split out of
# test-fix-loop-join.sh; see harness.sh for the shared scenario runner.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/harness.sh"

run_js_scenarios <<'JS_EOF'
// Scenario SBA -- the formula: 60_000 + 800 * estimated_loc, logged so a run
// states what it derived and why.
async function scenarioSBA() {
  console.log('\n== scenario SBA: the run budget follows triage\'s estimated_loc')
  const { captured } = await run({
    args: { runBudget: undefined },
    triage: { estimated_loc: 300 },
    initialReview: { correctness: [], advocate: [] },
    verify: () => undefined,
    staleness: () => [],
  })
  check('the derived budget is logged', captured.logs.some(l => /run budget: 300k output tokens \(derived/.test(l)), true)
}

// Scenario SBB -- the derived figure is clamped at the floor: a tiny estimate
// still gets at least 80k, since even a one-line change spends a few calls
// on setup, triage, implement and review.
async function scenarioSBB() {
  console.log('\n== scenario SBB: a tiny estimated_loc clamps the derived budget to the 80k floor')
  const { captured } = await run({
    args: { runBudget: undefined },
    triage: { estimated_loc: 1 },
    initialReview: { correctness: [], advocate: [] },
    verify: () => undefined,
    staleness: () => [],
  })
  check('the budget is clamped up to 80k', captured.logs.some(l => /run budget: 80k output tokens/.test(l)), true)
}

// Scenario SBC -- and clamped at the ceiling: a huge estimate does not buy an
// unbounded run.
async function scenarioSBC() {
  console.log('\n== scenario SBC: a huge estimated_loc clamps the derived budget to the 500k ceiling')
  const { captured } = await run({
    args: { runBudget: undefined },
    triage: { estimated_loc: 10000 },
    initialReview: { correctness: [], advocate: [] },
    verify: () => undefined,
    staleness: () => [],
  })
  check('the budget is clamped down to 500k', captured.logs.some(l => /run budget: 500k output tokens/.test(l)), true)
}

// Scenario SBD -- no estimate at all falls back to a flat default by scope,
// never to the formula with a missing number silently read as zero.
async function scenarioSBD() {
  console.log('\n== scenario SBD: a missing estimated_loc falls back to the inline default')
  const { captured } = await run({
    args: { runBudget: undefined },
    triage: { estimated_loc: undefined },
    initialReview: { correctness: [], advocate: [] },
    verify: () => undefined,
    staleness: () => [],
  })
  check('the inline default (80k) is used, not a formula on a missing number',
    captured.logs.some(l => /run budget: 80k output tokens \(triage gave no estimated_loc; using the inline default\)/.test(l)), true)
}

// Scenario SBE -- the team-scoped default is higher, and a numeric
// args.runBudget overrides the derivation outright, formula or fallback.
async function scenarioSBE() {
  console.log('\n== scenario SBE: an explicit args.runBudget replaces the derived value')
  const { captured } = await run({
    args: { runBudget: 12345 },
    triage: { scope: 'team', estimated_loc: undefined },
    initialReview: { correctness: [], advocate: [] },
    verify: () => undefined,
    staleness: () => [],
  })
  check('the explicit value is used, not the team default',
    captured.logs.some(l => /run budget: 12k output tokens \(set explicitly via args\.runBudget\)/.test(l)), true)
}

// Scenario SBF -- the refusal itself: dispatch() checks budget.spent() before
// every call, so the very next dispatch past the budget never runs, and the
// stage it would have run under is still open when the halt fires -- its
// spend so far has to reach stage_spend the same as a stage that closed
// normally, or the accounting silently loses whatever that stage spent.
async function scenarioSBF() {
  console.log('\n== scenario SBF: a spent-out budget refuses the next dispatch and reports it, with the open stage in stage_spend')
  const { result, captured } = await run({
    args: { runBudget: 250_000 },
    budgetPerAgentCall: 100_000,
  })
  check('halted at Implement, the phase the refused dispatch belongs to', result.halted_at, 'Implement')
  check('the implementer was never dispatched', callCount(captured, 'implementer'), 0)
  check('the note names the refused label', (result.note ?? '').includes("'implementer'"), true)
  check('the note names the spend at the halt', (result.note ?? '').includes('300k'), true)
  check('the note explains this is a budget halt, not a code problem',
    (result.note ?? '').includes('Run budget exhausted'), true)
  check('the open implement stage reached stage_spend', typeof result.stage_spend?.implement, 'number')
  check('the closed triage stage is still reported too', typeof result.stage_spend?.triage, 'number')
  check('the note lists the still-open stage', (result.note ?? '').includes('still in progress'), true)
}

// Scenario SBG -- gh-118: a budget refusal inside one of two lenses running
// in parallel used to be indistinguishable from that lens legitimately
// finding nothing, because parallel() (the runtime) catches a thunk's own
// throw and hands back null either way. Left unchecked, a review where one
// lens got refused mid-flight would read as a clean pass instead of halting.
async function scenarioSBG() {
  console.log('\n== scenario SBG: a budget refusal inside a parallel review lens halts, rather than reading as a clean review')
  const { result, captured } = await run({
    args: { runBudget: 550 },
    budgetPerAgentCall: 100,
    initialReview: { correctness: [], advocate: [] },
  })
  check('halted at Review, not a clean pass', result.halted_at, 'Review')
  check('the note names the refused lens', (result.note ?? '').includes('review:advocate'), true)
  check('the run never reached the PR phase', callCount(captured, 'pr'), 0)
}

const SCENARIOS = [scenarioSBA, scenarioSBB, scenarioSBC, scenarioSBD, scenarioSBE, scenarioSBF, scenarioSBG]
JS_EOF

finish
