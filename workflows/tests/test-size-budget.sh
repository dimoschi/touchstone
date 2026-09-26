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

// Scenario SBH -- a single file under the inline bar gets no lenses at all,
// the files<=1/totalChurn case in lensKeysFor.
async function scenarioSBH() {
  console.log('\n== scenario SBH: a tiny one-file diff gets no reviewer lenses')
  const { result, captured } = await run({
    diffstatFiles: [['a.js', 5, 0]],
  })
  check('no review lens ran', captured.calls.some(c => c.label.startsWith('review:')), false)
  check('the run does not halt', result.halted_at, undefined)
  check('the result reports zero reviewers', result.reviewers, 0)
}

// Scenario SBI -- under ONE_LENS_LOC a single correctness lens runs, and with
// fewer than two reviewers review:dedup is skipped by the guard it already
// has (reviewerCount < 2), so a small diff pays for neither a second lens
// nor the dedup call.
async function scenarioSBI() {
  console.log('\n== scenario SBI: a small diff (2 files, under ONE_LENS_LOC) runs correctness only, no dedup')
  const { captured } = await run({
    diffstatFiles: [['a.js', 50, 0], ['b.js', 50, 0]],
  })
  check('correctness ran', captured.calls.some(c => c.label === 'review:correctness'), true)
  check('advocate did not run', captured.calls.some(c => c.label === 'review:advocate'), false)
  check('review:dedup never ran', callCount(captured, 'review:dedup'), 0)
}

// Scenario SBJ -- between ONE_LENS_LOC and BIG_LOC, with at most BIG_FILES
// code files, correctness and the devil's advocate both run.
async function scenarioSBJ() {
  console.log('\n== scenario SBJ: a mid-sized diff runs correctness and advocate')
  const { result } = await run({
    diffstatFiles: [['a.js', 100, 0], ['b.js', 100, 0]],
  })
  check('two reviewers', result.reviewers, 2)
}

// Scenario SBK -- past BIG_LOC, or past BIG_FILES code files, the
// requirements lens joins the other two.
async function scenarioSBK() {
  console.log('\n== scenario SBK: a big diff (codeChurn > BIG_LOC) adds the requirements lens')
  const { result, captured } = await run({
    diffstatFiles: [['a.js', 500, 0]],
    ticketResult: { found: true, summary: 's', description: 'the ticket', comments: '' },
  })
  check('three reviewers', result.reviewers, 3)
  check('the requirements lens ran', captured.calls.some(c => c.label === 'review:requirements'), true)
}

// Scenario SBL -- more than BIG_FILES code files also trips the big case,
// even when each file's own churn is small.
async function scenarioSBL() {
  console.log('\n== scenario SBL: more than BIG_FILES code files also adds the requirements lens, even under BIG_LOC')
  const { result } = await run({
    // codeChurn = 6*30 = 180, between ONE_LENS_LOC and BIG_LOC: only the
    // file count (6 > BIG_FILES) should be why this promotes to three.
    diffstatFiles: [['a.js', 30, 0], ['b.js', 30, 0], ['c.js', 30, 0], ['d.js', 30, 0], ['e.js', 30, 0], ['f.js', 30, 0]],
  })
  check('three reviewers', result.reviewers, 3)
}

// Scenario SBM -- a diffstat probe that never produces a well-formed
// response (neither the first call nor its one retry) halts at Review as a
// measurement problem, never reaching a lens.
async function scenarioSBM() {
  console.log('\n== scenario SBM: an unmeasurable diffstat halts after one retry, never reaching a lens')
  const { result, captured } = await run({
    sizeUnmeasured: true,
  })
  check('halted at Review', result.halted_at, 'Review')
  check('the retry ran exactly once', callCount(captured, 'size'), 1)
  check('no review lens ran', captured.calls.some(c => c.label.startsWith('review:')), false)
  check('the note says this is a measurement problem', (result.note ?? '').includes('measurement problem'), true)
}

// Scenario SBN -- a diffstat whose begin line names a different range than
// the one asked about is unmeasured too, not silently accepted; it still
// gets its retry, which recovers here since the retry names the right range.
async function scenarioSBN() {
  console.log('\n== scenario SBN: a diffstat naming the wrong range counts as unmeasured, retried and recovered')
  const { result, captured } = await run({
    diffstat: 'TOUCHSTONE_DIFFSTAT wrong..range\n100\t0\ta.js\nTOUCHSTONE_COMMENT_LINES\nTOUCHSTONE_DIFFSTAT_END',
  })
  check('the retry ran exactly once', callCount(captured, 'size'), 1)
  check('the run recovered rather than halting', result.halted_at, undefined)
}

// Scenario SBO -- the ratio halt: support code (here, a test file) far
// outweighing the actual code halts before any lens runs, and the note
// carries every count and the limit.
async function scenarioSBO() {
  console.log('\n== scenario SBO: support code outweighing the actual change halts before any lens runs')
  const { result, captured } = await run({
    diffstatFiles: [['a.js', 20, 0], ['tests/x.js', 100, 0]],
  })
  check('halted at Review', result.halted_at, 'Review')
  check('no review lens ran', captured.calls.some(c => c.label.startsWith('review:')), false)
  check('the note carries the code count', (result.note ?? '').includes('20 code'), true)
  check('the note carries the test count', (result.note ?? '').includes('100 test'), true)
  check('the note carries the computed ratio', (result.note ?? '').includes('5.0:1'), true)
  check('the note carries the limit', (result.note ?? '').includes('3:1 limit'), true)
  check('the note names the override', (result.note ?? '').includes('args.supportRatio'), true)
}

// Scenario SBP -- below RATIO_MIN_CODE the ratio never applies, which is
// what lets a change that is mostly tests by design (an ordinary TDD change)
// through without halting.
async function scenarioSBP() {
  console.log('\n== scenario SBP: a tests-only change under the code floor does not trip the ratio halt')
  const { result } = await run({
    diffstatFiles: [['a.js', 5, 0], ['tests/x.js', 500, 0]],
  })
  check('the run does not halt on the ratio', (result.note ?? '').includes('Support code outweighs'), false)
}

// Scenario SBQ -- args.supportRatio raises the limit for a run that knows
// its own ratio is intentional.
async function scenarioSBQ() {
  console.log('\n== scenario SBQ: args.supportRatio raises the ratio limit past what would otherwise halt')
  const { result } = await run({
    args: { supportRatio: 10 },
    diffstatFiles: [['a.js', 20, 0], ['tests/x.js', 100, 0]],
  })
  check('the run does not halt', result.halted_at, undefined)
}

const SCENARIOS = [scenarioSBA, scenarioSBB, scenarioSBC, scenarioSBD, scenarioSBE, scenarioSBF, scenarioSBG,
  scenarioSBH, scenarioSBI, scenarioSBJ, scenarioSBK, scenarioSBL, scenarioSBM, scenarioSBN, scenarioSBO,
  scenarioSBP, scenarioSBQ]
JS_EOF

finish
