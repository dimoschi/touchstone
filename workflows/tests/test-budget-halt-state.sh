#!/usr/bin/env bash
# A run-budget halt carries the same work and review state as any other halt
# at the phase it fires in (gh-135): the findings, notes and fix rounds a run
# had when the budget refused a dispatch reach its result, not just the note.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/harness.sh"

run_js_scenarios <<'JS_EOF'
const BUDGETED = { runBudget: 1_000_000 }
const has = (obj, key) => Object.prototype.hasOwnProperty.call(obj, key)

// Scenario BHA -- refused before any implementation exists: the plan is
// reported, and nothing the implementer would have produced is invented.
async function scenarioBHA() {
  console.log('\n== scenario BHA: a refusal at the implementer reports the plan and nothing later')
  const { result } = await run({ args: BUDGETED, spendAllAfter: 'plan:write' })
  check('halted at Implement', result.halted_at, 'Implement')
  check('the implementer was the refused dispatch', (result.note ?? '').includes("'implementer'"), true)
  check('the plan is reported', typeof result.plan, 'string')
  check('the checks are reported', typeof result.checks, 'object')
  check('no implementation summary is invented', has(result, 'implemented'), false)
  check('no findings field before Review ran', has(result, 'unresolved_findings'), false)
}

// Scenario BHB -- refused after Implement, before Review: implementation,
// gates and checks are reported.
async function scenarioBHB() {
  console.log('\n== scenario BHB: a refusal after Implement reports the implementation, gates and checks')
  const { result } = await run({ args: BUDGETED, spendAllAfter: 'implementer' })
  check('the note is still the budget note', (result.note ?? '').includes('Run budget exhausted'), true)
  check('the plan is reported', typeof result.plan, 'string')
  check('the implementation is reported', result.implemented, 'stub implementation')
  check('the gates are reported', typeof result.gates?.measured, 'string')
  check('the checks are reported', typeof result.checks?.discovered, 'number')
  check('no findings field before Review ran', has(result, 'unresolved_findings'), false)
}

// Scenario BHC -- refused in Review, after the lenses raised findings and
// before their reproducers ran: the notes classification already made are in
// the payload.
async function scenarioBHC() {
  console.log('\n== scenario BHC: a refusal in Review keeps the notes already classified')
  const { result } = await run({
    args: BUDGETED,
    spendAllAfter: 'review:dedup',
    initialReview: {
      correctness: [{ title: 'Off-by-one', file: 'src/p.js', claim: 'c1', evidence: 'e1' }],
      advocate: [{ title: 'Unproven worry', file: 'src/q.js', claim: 'c2', evidence: 'e2',
        reproducer: undefined }],
    },
  })
  check('halted at Review', result.halted_at, 'Review')
  check('the reproducer run was the refused dispatch', (result.note ?? '').includes("'reproduce:review'"), true)
  check('the note raised by the review is reported',
    (result.notes ?? []).map(n => n.title), ['Unproven worry'])
  check('the open findings so far are reported', result.unresolved_findings, [])
  check('fix rounds are reported', result.fix_rounds, 0)
  check('the implementation is reported', result.implemented, 'stub implementation')
}

// Scenario BHD -- the case the ticket was filed from: fix round 1 ran and the
// budget refused that round's reproducer run.
async function scenarioBHD() {
  console.log('\n== scenario BHD: a refusal in Fix keeps the open findings, notes and fix rounds')
  const { result } = await run({
    args: BUDGETED,
    spendAllAfter: 'plan:leak:Fix',
    initialReview: {
      correctness: [{ title: 'Off-by-one', file: 'src/p.js', claim: 'c1', evidence: 'e1' }],
      advocate: [{ title: 'Unproven worry', file: 'src/q.js', claim: 'c2', evidence: 'e2',
        reproducer: undefined }],
    },
    fixHead: () => 'fix00000000000000000000000000000000000001',
  })
  check('halted at Fix', result.halted_at, 'Fix')
  check('the round\'s reproducer run was the refused dispatch', (result.note ?? '').includes("'reproduce:fix:1'"), true)
  check('the open finding is reported',
    (result.unresolved_findings ?? []).map(f => f.title), ['Off-by-one'])
  check('the note is reported', (result.notes ?? []).map(n => n.title), ['Unproven worry'])
  check('the fix round is reported', result.fix_rounds, 1)
  check('the fix round output is reported', (result.fix_round_output ?? []).map(r => r.round), [1])
  check('the plan is reported', typeof result.plan, 'string')
  check('the gates are reported', typeof result.gates?.measured, 'string')
  check('the checks are reported', typeof result.checks?.discovered, 'number')
}

// Scenario BHE -- refused at the review of the mutation gate's own commits:
// the mutation result is reported alongside the review state. (The mutation
// loop itself stops on its stage ceiling before the budget can refuse it.)
async function scenarioBHE() {
  console.log('\n== scenario BHE: a refusal after Mutation keeps the mutation result')
  const { result } = await run({
    args: BUDGETED,
    spendAllAfter: 'plan:leak:Mutation',
    mutationGated: true,
    initialReview: { correctness: [], advocate: [] },
    mutationResult: () => ({ green: true, head_sha: 'aaa0000000000000000000000000000000000001',
      detail: 'killed every mutant', scored: false }),
  })
  check('halted at the post-mutation Review', result.halted_at, 'Review')
  check('the post-mutation reproducer run was the refused dispatch', (result.note ?? '').includes("'reproduce:mutation'"), true)
  check('the mutation result is reported', result.mutation?.detail, 'killed every mutant')
  check('the open findings are reported', result.unresolved_findings, [])
}

// Scenario BHF -- refused at the plan file write, the first dispatch after the
// plan exists: the plan is still reported.
async function scenarioBHF() {
  console.log('\n== scenario BHF: a refusal at plan:write still reports the plan')
  const { result } = await run({ args: BUDGETED, spendAllAfter: 'triage' })
  check('halted at Implement', result.halted_at, 'Implement')
  check('plan:write was the refused dispatch', (result.note ?? '').includes("'plan:write'"), true)
  check('the plan is reported', typeof result.plan, 'string')
}

const SCENARIOS = [scenarioBHA, scenarioBHB, scenarioBHC, scenarioBHD, scenarioBHE, scenarioBHF]
JS_EOF

finish
