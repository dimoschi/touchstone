#!/usr/bin/env bash
# An agent call that throws (a subagent out of structured-output retries) ends
# the run as a halt with a payload, not as a crash with no record.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/harness.sh"

run_js_scenarios <<'JS_EOF'
async function scenarioThrowInImplement() {
  console.log('\n== scenario AE1: a throwing implementer halts at Implement with the error in the note')
  const { result } = await run({ throwOn: ['implementer'] })
  check('the run halts', result.halted_at, 'Implement')
  check('the note carries the error', (result.note ?? '').includes('StructuredOutput retry cap (5) exceeded for implementer'), true)
  check('the note names the phase', (result.note ?? '').includes('stopped on an error in Implement'), true)
  check('the payload carries the record file', typeof result.record_file, 'string')
}

async function scenarioThrowInReview() {
  console.log('\n== scenario AE2: a throw in the fix loop halts at Fix and keeps the plan')
  const { result } = await run({ throwOn: ['fix:1'], initialReview: {
    correctness: [{ title: 'Off-by-one', file: 'src/p.js', claim: 'c1', evidence: 'e1' }], advocate: [] } })
  check('the run halts at Fix', result.halted_at, 'Fix')
  check('the plan is kept', typeof result.plan, 'string')
}

async function scenarioBudgetStillWins() {
  console.log('\n== scenario AE3: a budget refusal is still reported as the budget halt')
  const { result } = await run({ args: { runBudget: 1_000_000 }, spendAllAfter: 'implementer' })
  check('budget note', (result.note ?? '').includes('Run budget exhausted'), true)
  check('not the error note', (result.note ?? '').includes('stopped on an error'), false)
}

const SCENARIOS = [scenarioThrowInImplement, scenarioThrowInReview, scenarioBudgetStillWins]
JS_EOF

finish
