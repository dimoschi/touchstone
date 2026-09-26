#!/usr/bin/env bash
# gh-114: reviewers get the ticket's settled decisions, verbatim, but not the
# rest of its text; see harness.sh for what run()/captured share.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/harness.sh"

run_js_scenarios <<'JS_EOF'
const PROBLEM_MARKER = 'PROBLEM_MARKER_TEXT'
const DECISION_MARKER = 'DECISION_MARKER_TEXT'
const AFTER_MARKER = 'AFTER_MARKER_TEXT'
const COMMENT_MARKER = 'COMMENT_MARKER_TEXT'

const DESCRIPTION_WITH_DECISIONS =
  `### The problem\n${PROBLEM_MARKER}\n\n` +
  `### Constraints, or decisions already taken\n- ${DECISION_MARKER}\n\n` +
  `### Expected outcome\n${AFTER_MARKER}\n`

const bigDiffstat = [['a.js', 500, 0]] // codeChurn 500 (> BIG_LOC), all three lenses

// Scenario A -- every initial lens's prompt: correctness and advocate get the
// settled decisions alone, framed as settled and non-blocking; requirements
// keeps the whole ticket (ticketSpec) and gets the decisions block besides.
async function scenarioSettledDecisionsInitialLenses() {
  console.log('\n== scenario: all three initial lenses see the settled decisions, not the rest of the ticket')
  const { captured } = await run({
    diffstatFiles: bigDiffstat,
    ticketResult: { found: true, summary: 'stub', comments: `author: ${COMMENT_MARKER}`,
      description: DESCRIPTION_WITH_DECISIONS },
    initialReview: { correctness: [], advocate: [], requirements: [] },
  })
  const correctness = captured.calls.find(c => c.label === 'review:correctness')?.prompt ?? ''
  const advocate = captured.calls.find(c => c.label === 'review:advocate')?.prompt ?? ''
  const requirements = captured.calls.find(c => c.label === 'review:requirements')?.prompt ?? ''

  for (const [label, p] of [['correctness', correctness], ['advocate', advocate]]) {
    check(`${label} prompt carries the settled decision`, p.includes(DECISION_MARKER), true)
    check(`${label} prompt marks it as settled`, p.includes('Settled decisions'), true)
    check(`${label} prompt states behaviour it specifies is not a defect`,
      p.includes('not a defect'), true)
    check(`${label} prompt states disagreement is at most a non-blocking note`,
      p.includes('design or scope note'), true)
    check(`${label} prompt lacks the problem section`, p.includes(PROBLEM_MARKER), false)
    check(`${label} prompt lacks the later section`, p.includes(AFTER_MARKER), false)
    check(`${label} prompt lacks the comments`, p.includes(COMMENT_MARKER), false)
  }
  check('requirements prompt still carries the full ticket (problem section)',
    requirements.includes(PROBLEM_MARKER), true)
  check('requirements prompt still carries the full ticket (later section)',
    requirements.includes(AFTER_MARKER), true)
  check('requirements prompt still carries the comments',
    requirements.includes(COMMENT_MARKER), true)
  check('requirements prompt also carries the settled decision',
    requirements.includes(DECISION_MARKER), true)
}

// Scenario B -- the tail review (a fix round's own correctness pass) and the
// post-mutation review both go through the same reviewOf, so both must carry
// the settled decisions too, without a separate call site to wire.
async function scenarioSettledDecisionsTailAndMutation() {
  console.log('\n== scenario: the tail review and the post-mutation review both see the settled decisions')
  const { captured } = await run(convergedWithSuspect({
    ticketResult: { found: true, summary: 'stub', comments: '', description: DESCRIPTION_WITH_DECISIONS },
    tailReview: [],
    postMutationReview: [],
  }))
  const tail = captured.calls.find(c => c.label === 'review:fix:1:correctness')?.prompt ?? ''
  check('the tail review ran', tail.length > 0, true)
  check('the tail review carries the settled decision', tail.includes(DECISION_MARKER), true)
  const mutation = captured.calls.find(c => c.label === 'review:mutation:correctness')?.prompt ?? ''
  check('the post-mutation review ran', mutation.length > 0, true)
  check('the post-mutation review carries the settled decision', mutation.includes(DECISION_MARKER), true)
}

// Scenario C -- no such section at all: lenses get no settled-decisions
// block, and the run log says why exactly once.
async function scenarioNoSection() {
  console.log('\n== scenario: a ticket with no "Constraints, or decisions already taken" section gets no settled-decisions block')
  const { captured } = await run({
    diffstatFiles: bigDiffstat,
    ticketResult: { found: true, summary: 'stub', comments: '',
      description: `### The problem\n${PROBLEM_MARKER}\n` },
    initialReview: { correctness: [], advocate: [], requirements: [] },
  })
  const correctness = captured.calls.find(c => c.label === 'review:correctness')?.prompt ?? ''
  check('no settled-decisions header reaches the lens', correctness.includes('Settled decisions'), false)
  check('the missing-section line is logged',
    captured.logs.some(l => l.includes('has no "Constraints, or decisions already taken" section')), true)
}

// Scenario D -- the section exists but is empty, or carries only GitHub's
// placeholder for an optional field left blank: both count as no decisions.
async function scenarioEmptyOrPlaceholder() {
  console.log('\n== scenario: an empty section and the "_No response_" placeholder both count as no settled decisions')
  for (const body of ['', '_No response_']) {
    const { captured } = await run({
      diffstatFiles: bigDiffstat,
      ticketResult: { found: true, summary: 'stub', comments: '',
        description: `### Constraints, or decisions already taken\n${body}\n` },
      initialReview: { correctness: [], advocate: [], requirements: [] },
    })
    const correctness = captured.calls.find(c => c.label === 'review:correctness')?.prompt ?? ''
    check(`body ${JSON.stringify(body)}: no settled-decisions header reaches the lens`,
      correctness.includes('Settled decisions'), false)
    check(`body ${JSON.stringify(body)}: the missing-section line is logged`,
      captured.logs.some(l => l.includes('has no "Constraints, or decisions already taken" section')), true)
  }
}

// Scenario E -- the heading phrase said in passing, inside a paragraph rather
// than as a heading, is not selected.
async function scenarioPhraseInParagraphNotSelected() {
  console.log('\n== scenario: the heading phrase inside a paragraph is not selected as the section')
  const { captured } = await run({
    diffstatFiles: bigDiffstat,
    ticketResult: { found: true, summary: 'stub', comments: '',
      description: `### The problem\nSee Constraints, or decisions already taken below for context.\n${PROBLEM_MARKER}\n` },
    initialReview: { correctness: [], advocate: [], requirements: [] },
  })
  const correctness = captured.calls.find(c => c.label === 'review:correctness')?.prompt ?? ''
  check('no settled-decisions header reaches the lens', correctness.includes('Settled decisions'), false)
}

// Scenario F -- an unreadable ticket: no settled decisions, and the run log
// still says so (reviewerCount > 0).
async function scenarioUnreadableTicket() {
  console.log('\n== scenario: an unreadable ticket gets no settled-decisions block, logged the same way')
  const { captured } = await run({
    diffstatFiles: bigDiffstat,
    ticketResult: { found: false, summary: 'could not fetch', comments: '', description: '' },
    initialReview: { correctness: [], advocate: [], requirements: [] },
  })
  const correctness = captured.calls.find(c => c.label === 'review:correctness')?.prompt ?? ''
  check('no settled-decisions header reaches the lens', correctness.includes('Settled decisions'), false)
  check('the missing-section line is logged',
    captured.logs.some(l => l.includes('has no "Constraints, or decisions already taken" section')), true)
}

// Scenario G -- a run with no lenses at all (a one-liner) never logs the
// missing-section line, so a quiet run stays quiet.
async function scenarioNoLensesStaysQuiet() {
  console.log('\n== scenario: a run with no review lenses logs nothing about settled decisions')
  const { captured } = await run({
    diffstatFiles: [['a.js', 1, 0]], // under INLINE_LOC: zero lenses
    ticketResult: { found: true, summary: 'stub', comments: '', description: `### The problem\n${PROBLEM_MARKER}\n` },
  })
  check('review was skipped (no lenses)', captured.logs.some(l => l.includes('review skipped')), true)
  check('the missing-section line is never logged',
    captured.logs.some(l => l.includes('Constraints, or decisions already taken')), false)
}

// Scenario H -- a '# comment' line inside a fenced code block is not a
// Markdown heading, so it must not cut the section short; a decision listed
// after the fence still reaches the lens.
async function scenarioFencedCommentNotAHeading() {
  console.log('\n== scenario: a "#" comment inside a fenced code block does not end the section')
  const { captured } = await run({
    diffstatFiles: bigDiffstat,
    ticketResult: { found: true, summary: 'stub', comments: '',
      description: `### The problem\n${PROBLEM_MARKER}\n\n` +
        `### Constraints, or decisions already taken\n` +
        `- Run the gate this way, never piped:\n\`\`\`bash\n# redirect, then read the file\nbash gate.sh > log 2>&1\n\`\`\`\n` +
        `- ${DECISION_MARKER}\n`,
    },
    initialReview: { correctness: [], advocate: [], requirements: [] },
  })
  const correctness = captured.calls.find(c => c.label === 'review:correctness')?.prompt ?? ''
  check('the decision listed after the fenced block still reaches the lens',
    correctness.includes(DECISION_MARKER), true)
}

const SCENARIOS = [
  scenarioSettledDecisionsInitialLenses,
  scenarioSettledDecisionsTailAndMutation,
  scenarioNoSection,
  scenarioEmptyOrPlaceholder,
  scenarioPhraseInParagraphNotSelected,
  scenarioUnreadableTicket,
  scenarioNoLensesStaysQuiet,
  scenarioFencedCommentNotAHeading,
]
JS_EOF

finish
