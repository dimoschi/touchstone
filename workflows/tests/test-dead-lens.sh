#!/usr/bin/env bash
# gh-147: a review lens that returned no result (the null parallel() hands back for
# a lens that threw or failed its schema) is not a clean review. The run halts
# instead of classifying what the other lenses found, and reviewed_through never
# moves past a range no review read. Scenario ids DL1-DL7; see harness.sh for the
# shared scenario runner.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/harness.sh"

run_js_scenarios <<'JS_EOF'
const P = 'a1b2c3d4e5f60718293a4b5c6d7e8f9012345678'
const FIX_HEAD = 'fix00000000000000000000000000000000000001'
const MUT_HEAD = 'aaa0000000000000000000000000000000000001'
const NOT_RUN = 'the review did not run'

const bug = (n) => ({ title: `Bug ${n}`, file: `src/b${n}.js`, claim: `claim ${n}`, evidence: `b${n}.js:1` })
const idsOf = (list) => (list ?? []).map(f => f.id)
const mutationAt = (head) => () => ({ green: true, head_sha: head, detail: 'stub', scored: true })
const staysOpen = { initialReview: { correctness: [bug(1)], advocate: [] },
  verify: () => false, fixHead: () => FIX_HEAD, staleness: () => [] }

function existing(over) {
  return { created: true, branch: 'feat/gh-21-stub', base: 'main', path: '/tmp/stub-worktree',
    ticket: '21', detail: 'stub', prior_head_check: 'TOUCHSTONE_PRIOR_HEAD_LINEAR 0', ...over }
}
function carriedFinding(id) {
  return { id, title: `Carried ${id}`, file: `src/${id}.js`, claim: `claim of ${id}`,
    evidence: `${id}.js:1`, category: 'wrong-result', scope: 'ticket', recorded_at: P,
    line_start: 1,
    reproducer: { kind: 'command', command: `carried-repro ${id}`, expected: 'exit 0', actual: 'exit 1' } }
}
function resumed(over) {
  return { args: { existingBranch: true,
      priorRun: { reviewed_through: P, unresolved_findings: [carriedFinding('f3')] } },
    existingBranchResult: existing(), ...over }
}

async function scenarioDL1() {
  console.log('\n== scenario DL1: one dead initial lens halts at Review, and what the live lens found is not classified')
  const { result, captured } = await run({
    initialReview: { correctness: [bug(1), bug(2)], advocate: [] },
    deadLenses: ['review:advocate'],
  })
  const note = result.note ?? ''
  check('the run halts at Review', result.halted_at, 'Review')
  check('the note names the dead lens by its full label', note.includes('review:advocate'), true)
  check('and not the lens that returned', note.includes('review:correctness'), false)
  check('and says the review did not run', note.includes(NOT_RUN), true)
  check('nothing the live lens raised is deduped, reproduced or fixed',
    ['review:dedup', 'reproduce:review', 'fix:1'].map(l => callCount(captured, l)), [0, 0, 0])
  check('and none of it is reported as a finding or a note',
    [idsOf(result.unresolved_findings), idsOf(result.notes)], [[], []])
  check('no head is reported as reviewed', result.reviewed_through, null)
}

async function scenarioDL2() {
  console.log('\n== scenario DL2: every initial lens dead halts at Review and nothing after it runs')
  const { result, captured } = await run({
    mutationGated: true,
    deadLenses: ['review:correctness', 'review:advocate'],
  })
  const note = result.note ?? ''
  check('the run halts at Review', result.halted_at, 'Review')
  check('the note names both lenses',
    [note.includes('review:correctness'), note.includes('review:advocate')], [true, true])
  check('and says the review did not run', note.includes(NOT_RUN), true)
  check('no fix round and no mutation gate ran',
    [callCount(captured, 'fix:1'), callCount(captured, 'mutation:1')], [0, 0])
  check('no head is reported as reviewed', result.reviewed_through, null)
}

async function scenarioDL3() {
  console.log('\n== scenario DL3: a dead fix-round lens halts at Fix, and no further round runs')
  const { result, captured } = await run({ ...staysOpen, deadLenses: ['review:fix:1:correctness'] })
  const note = result.note ?? ''
  check('the run halts at Fix after one round', [result.halted_at, result.fix_rounds], ['Fix', 1])
  check('the note names the dead lens by its full label', note.includes('review:fix:1:correctness'), true)
  check('and says the review did not run', note.includes(NOT_RUN), true)
  check('the open finding is still reported', idsOf(result.unresolved_findings), ['f1'])
  check('no second round ran', callCount(captured, 'fix:2'), 0)
  check('reviewed_through stays at the head the initial review read, not the fix commit',
    result.reviewed_through, REVIEWED_THROUGH)
}

async function scenarioDL4() {
  console.log('\n== scenario DL4: a lens that returns an empty list is a clean review')
  const initial = await run({ initialReview: { correctness: [], advocate: [] } })
  check('empty initial lenses do not halt', initial.result.halted_at, undefined)
  check('and reviewed_through is the head they read', initial.result.reviewed_through, REVIEWED_THROUGH)

  const fixed = await run({ ...staysOpen, verify: () => true })
  check('an empty fix-round review does not halt', fixed.result.halted_at, undefined)
  check('and reviewed_through advances to the fix commit', fixed.result.reviewed_through, FIX_HEAD)
}

async function scenarioDL5() {
  console.log('\n== scenario DL5: a dead post-mutation lens halts at Review without moving reviewed_through')
  const { result } = await run({ mutationGated: true, mutationResult: mutationAt(MUT_HEAD),
    deadLenses: ['review:mutation:correctness'] })
  const note = result.note ?? ''
  check('the run halts at Review', result.halted_at, 'Review')
  check('the note names the dead lens by its full label', note.includes('review:mutation:correctness'), true)
  check('and says the review did not run', note.includes(NOT_RUN), true)
  check('reviewed_through is the head the initial review read, not the mutation head',
    result.reviewed_through, REVIEWED_THROUGH)
}

async function scenarioDL6() {
  console.log('\n== scenario DL6: a resumed run keeps the head and the carried findings a dead lens left unread')
  const initial = await run(resumed({ deadLenses: ['review:advocate'] }))
  check('a dead initial lens halts at Review', initial.result.halted_at, 'Review')
  check('reviewed_through stays at the record\'s head', initial.result.reviewed_through, P)
  check('the carried finding is still reported', idsOf(initial.result.unresolved_findings), ['f3'])
  check('and the note says the review did not run', (initial.result.note ?? '').includes(NOT_RUN), true)

  const fix = await run(resumed({ deadLenses: ['review:fix:1:correctness'],
    verify: () => false, fixHead: () => FIX_HEAD, staleness: () => [] }))
  check('a dead fix-round lens halts at Fix', fix.result.halted_at, 'Fix')
  check('reviewed_through stays at the head the first review read', fix.result.reviewed_through, REVIEWED_THROUGH)

  const mutation = await run(resumed({ mutationGated: true, mutationResult: mutationAt(MUT_HEAD),
    verify: () => true, deadLenses: ['review:mutation:correctness'] }))
  check('a dead mutation lens halts at Review', mutation.result.halted_at, 'Review')
  check('reviewed_through stays at the head the first review read, not the mutation head',
    mutation.result.reviewed_through, REVIEWED_THROUGH)
}

async function scenarioDL7() {
  console.log('\n== scenario DL7: a budget refusal during review is still the budget halt')
  const { result } = await run({ args: { runBudget: 1_000_000 }, spendAllAfter: 'draft-pr' })
  const note = result.note ?? ''
  check('the run halts at Review', result.halted_at, 'Review')
  check('the note is the budget one', note.includes('Run budget exhausted'), true)
  check('and does not claim a lens died', note.includes(NOT_RUN), false)
}

const SCENARIOS = [scenarioDL1, scenarioDL2, scenarioDL3, scenarioDL4, scenarioDL5, scenarioDL6, scenarioDL7]
JS_EOF

finish
