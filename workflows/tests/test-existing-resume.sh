#!/usr/bin/env bash
# gh-154: an --existing run resumes from the head an earlier run's review
# finished at, instead of re-reviewing the whole branch, and carries that
# run's still-open findings and notes forward. Scenario ids R1-R8 map to the
# ticket's acceptance criteria; see harness.sh for the shared scenario runner.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/harness.sh"

run_js_scenarios <<'JS_EOF'
const P = 'a1b2c3d4e5f60718293a4b5c6d7e8f9012345678'
const Q = '0123456789abcdef0123456789abcdef01234567'
const FIX_HEAD = 'fix00000000000000000000000000000000000001'
const MUT_HEAD = 'mut00000000000000000000000000000000000001'
const PRIOR_OK = 'TOUCHSTONE_PRIOR_HEAD 0'
const ANCESTRY_STEP = (sha) =>
  `git -C <path> merge-base --is-ancestor ${sha} HEAD; echo TOUCHSTONE_PRIOR_HEAD $?`

function existing(over) {
  return { created: true, branch: 'feat/gh-21-stub', base: 'main', path: '/tmp/stub-worktree',
    ticket: '21', detail: 'stub', prior_head_check: PRIOR_OK, ...over }
}
function carriedFinding(id, over) {
  return { id, title: `Carried ${id}`, file: `src/${id}.js`, claim: `claim of ${id}`,
    evidence: `${id}.js:1`, category: 'wrong-result', scope: 'ticket', recorded_at: P,
    line_start: 1,
    reproducer: { kind: 'command', command: `carried-repro ${id}`, expected: 'exit 0', actual: 'exit 1' },
    ...over }
}
function carriedNote(id, over) {
  return { id, title: `Note ${id}`, file: `src/${id}.js`, claim: `note claim ${id}`,
    category: 'wording', reason: 'category', scope: 'ticket', round: 0, ...over }
}
function initialLensCalls(captured) {
  return captured.calls.filter(c => /^review:(correctness|advocate|requirements)$/.test(c.label))
}
const idsOf = (list) => (list ?? []).map(f => f.id)
function resumed(prior, over) {
  const { args, ...rest } = over ?? {}
  return { args: { existingBranch: true, priorRun: { reviewed_through: P, ...prior }, ...args },
    existingBranchResult: existing(), ...rest }
}
const mutationAt = (head) => () => ({ green: true, head_sha: head, detail: 'stub', scored: true })

async function scenarioR1() {
  console.log('\n== scenario R1: a resumed run reviews P..<impl head>, not the whole branch')
  const range = `${P}..${REVIEWED_THROUGH}`
  const { captured } = await run(resumed({}))
  const lenses = initialLensCalls(captured)
  check('both default lenses ran', lenses.map(c => c.label), ['review:correctness', 'review:advocate'])
  check('every initial lens prompt carries the narrowed range',
    lenses.every(c => c.prompt.includes(`Commit range: ${range}\n`)), true)
  check('every initial lens prompt tells the lens to diff the narrowed range',
    lenses.every(c => c.prompt.includes(`read git diff ${range} yourself`)), true)
  check('no initial lens prompt names the implementer\'s whole-branch range',
    lenses.some(c => c.prompt.includes(COMMIT_RANGE)), false)
  const draft = captured.calls.find(c => c.label === 'draft-pr')?.prompt ?? ''
  check('the draft-pr diffstat command names the narrowed range',
    draft.includes(`echo TOUCHSTONE_DIFFSTAT ${range};`) &&
    draft.includes(`diff --numstat --no-renames ${range};`), true)
  check('the draft-pr prompt does not name the whole-branch range', draft.includes(COMMIT_RANGE), false)

  const retried = await run(resumed({}, { diffstat: 'not a diffstat' }))
  const size = retried.captured.calls.find(c => c.label === 'size')?.prompt ?? ''
  check('the diffstat retry measures the narrowed range', size.includes(`echo TOUCHSTONE_DIFFSTAT ${range};`), true)
  check('a retry that recovers still reviews the narrowed range',
    initialLensCalls(retried.captured).every(c => c.prompt.includes(`Commit range: ${range}\n`)), true)
  const unmeasured = await run(resumed({}, { sizeUnmeasured: true }))
  check('an unmeasurable narrowed range halts naming it',
    (unmeasured.result.note ?? '').includes(`begin/end markers naming ${range}`), true)
}

async function scenarioR2() {
  console.log('\n== scenario R2: args.reviewedThrough wins over priorRun.reviewed_through')
  const { captured } = await run(resumed({}, { args: { reviewedThrough: Q } }))
  const lenses = initialLensCalls(captured)
  check('the lenses review from the override',
    lenses.every(c => c.prompt.includes(`Commit range: ${Q}..${REVIEWED_THROUGH}\n`)), true)
  check('no lens reviews from the record\'s head', lenses.some(c => c.prompt.includes(P)), false)
  const bx = captured.calls.find(c => c.label === 'branch:existing')?.prompt ?? ''
  check('the ancestry step verifies the override', bx.includes(ANCESTRY_STEP(Q)), true)
  check('the ancestry step does not verify the record\'s head', bx.includes(P), false)

  const alone = await run({
    args: { existingBranch: true, reviewedThrough: Q },
    existingBranchResult: existing(),
  })
  check('an override with no record narrows the range too',
    initialLensCalls(alone.captured).every(c => c.prompt.includes(`Commit range: ${Q}..${REVIEWED_THROUGH}\n`)), true)
}

async function scenarioR3() {
  console.log('\n== scenario R3: carried findings and notes are tracked, referenced by id, and ids continue above them')
  const { result, captured } = await run(resumed({
    unresolved_findings: [carriedFinding('f3'), carriedFinding('f4', { scope: 'weird' }), carriedFinding('x9')],
    notes: [carriedNote('f5'),
      { title: 'Advisory check `x` reported', claim: 'adv', category: 'advisory', reason: 'advisory' }],
  }, {
    args: { maxReviewRounds: 1 },
    initialReview: {
      correctness: [
        { title: 'Same carried bug, other words', file: 'src/f3.js', claim: 'reworded', evidence: 'e',
          duplicate_of: 'f3' },
        { title: 'Fresh defect', file: 'src/y.js', claim: 'fresh claim', evidence: 'y.js:2' },
      ],
      advocate: [],
    },
    verify: () => undefined,
    staleness: () => [],
  }))
  const lenses = initialLensCalls(captured)
  check('both lenses ran', lenses.length, 2)
  for (const known of ['[f3] Carried f3 (src/f3.js): claim of f3', '[f4] Carried f4 (src/f4.js): claim of f4',
    '[f5] Note f5 (src/f5.js): note claim f5']) {
    check(`every initial lens is told ${known}`, lenses.every(c => c.prompt.includes(known)), true)
  }
  check('an entry with no f-number id is not carried into a lens prompt',
    lenses.some(c => c.prompt.includes('Carried x9') || c.prompt.includes('Advisory check')), false)
  check('the lenses are told these came from an earlier run and are not to be re-raised',
    lenses.every(c => c.prompt.includes('earlier run on this branch') && c.prompt.includes('never raise')), true)
  const fix1 = captured.calls.find(c => c.label === 'fix:1')?.prompt ?? ''
  check('the fix:1 prompt carries the carried finding with its reproducer',
    fix1.includes('Carried f3 (src/f3.js:1): claim of f3 [reproduce: carried-repro f3]'), true)
  check('the fix:1 prompt carries the second carried finding', fix1.includes('Carried f4'), true)
  check('the fix:1 prompt carries the freshly raised finding', fix1.includes('Fresh defect'), true)
  check('a finding referencing a carried open id is dropped, not re-opened',
    fix1.includes('Same carried bug, other words'), false)
  check('open findings are the carried two plus the fresh one, which got an id above f5',
    idsOf(result.unresolved_findings), ['f3', 'f4', 'f7'])
  check('only the id-bearing carried note survives, and the dropped duplicate is not a note',
    idsOf(result.notes), ['f5'])
  check('an unknown carried scope counts as unattributed',
    result.scope_split, { ticket: 2, addition: 0, unattributed: 1 })
}

async function scenarioR4() {
  console.log('\n== scenario R4: a resumed run\'s budget is raised to fit a first review range bigger than triage estimated')
  const range = `${P}..${REVIEWED_THROUGH}`
  const raisedRun = (spend) => resumed({}, {
    args: { runBudget: undefined },
    triage: { estimated_loc: 100 },
    diffstatFiles: [['a.js', 1000, 0]],
    initialReview: { correctness: [{ title: 'Needs a fix', file: 'a.js', claim: 'c', evidence: 'e' }],
      advocate: [], requirements: [] },
    initialExit: () => { spend.v = spend.after; return 1 },
    verify: () => true,
    staleness: () => [],
    budget: { total: null, spent: () => spend.v, remaining: () => Infinity },
  })
  const raised = await run(raisedRun({ v: 0, after: 600_000 }))
  check('the derived budget is still logged first', raised.captured.logs.some(
    l => /run budget: 300k output tokens \(derived from triage's ~100 estimated LOC\)/.test(l)), true)
  check('the raise is logged with the range and the line count', raised.captured.logs.includes(
    `run budget raised to 1000k (first review range ${range}, 1000 changed lines)`), true)
  check('the run is not refused at 600k, which the unraised 300k would have refused',
    callCount(raised.captured, 'fix:1'), 1)

  const refused = await run(raisedRun({ v: 0, after: 1_100_000 }))
  check('the raised figure is the one dispatch() refuses at',
    (refused.result.note ?? '').includes('Run budget exhausted (1000k output tokens'), true)
  check('the halt note says the budget was raised', /raised/.test(refused.result.note ?? ''), true)

  const small = await run(resumed({}, { args: { runBudget: undefined },
    triage: { estimated_loc: 1000 }, diffstatFiles: [['a.js', 50, 0]] }))
  check('a range under the estimate leaves the budget alone',
    small.captured.logs.some(l => l.startsWith('run budget raised')), false)

  const explicit = await run(resumed({}, { args: { runBudget: 400_000 },
    triage: { estimated_loc: 100 }, diffstatFiles: [['a.js', 1000, 0]] }))
  check('an explicit args.runBudget is never raised',
    explicit.captured.logs.some(l => l.startsWith('run budget raised')), false)
  check('and its own log line is unchanged', explicit.captured.logs.includes(
    'run budget: 400k output tokens (set explicitly via args.runBudget)'), true)

  const fresh = await run({
    args: { runBudget: undefined, priorRun: { reviewed_through: P }, reviewedThrough: P },
    triage: { estimated_loc: 100 }, diffstatFiles: [['a.js', 1000, 0]],
  })
  check('a run that is not --existing never raises it, whatever the args carry',
    fresh.captured.logs.some(l => l.startsWith('run budget raised')), false)
  const noHead = await run({
    args: { existingBranch: true, runBudget: undefined },
    existingBranchResult: existing(),
    triage: { estimated_loc: 100 }, diffstatFiles: [['a.js', 1000, 0]],
  })
  check('an --existing run with no prior head never raises it either',
    noHead.captured.logs.some(l => l.startsWith('run budget raised')), false)
}

async function scenarioR5() {
  console.log('\n== scenario R5: without a verified 40-hex prior head the run reviews the whole branch and carries nothing')
  const prior = { unresolved_findings: [carriedFinding('f9')], notes: [carriedNote('f8')] }
  const withHead = { existingBranch: true, priorRun: { reviewed_through: P, ...prior } }
  const cases = [
    { name: 'not --existing, with both a record and an override',
      args: { reviewedThrough: P, priorRun: { reviewed_through: P, ...prior } }, ancestry: false, label: 'branch' },
    { name: 'no priorRun at all', args: { existingBranch: true }, ancestry: false },
    { name: 'a priorRun with no reviewed_through',
      args: { existingBranch: true, priorRun: { ...prior } }, ancestry: false },
    { name: 'a non-hex reviewed_through',
      args: { existingBranch: true, priorRun: { reviewed_through: 'not-a-sha', ...prior } }, ancestry: false,
      why: 'not a 40-character SHA' },
    { name: 'a 39-character reviewed_through',
      args: { existingBranch: true, priorRun: { reviewed_through: P.slice(1), ...prior } }, ancestry: false },
    { name: 'a 41-character reviewed_through',
      args: { existingBranch: true, priorRun: { reviewed_through: `${P}a`, ...prior } }, ancestry: false },
    { name: 'a 40-character non-hex reviewed_through',
      args: { existingBranch: true, priorRun: { reviewed_through: 'g'.repeat(40), ...prior } }, ancestry: false },
    { name: 'an invalid override beating a valid record',
      args: { existingBranch: true, reviewedThrough: 'nope', priorRun: { reviewed_through: P, ...prior } },
      ancestry: false },
    { name: 'an ancestry check that printed 1', args: withHead,
      check: 'TOUCHSTONE_PRIOR_HEAD 1', ancestry: true, why: 'not confirmed as an ancestor' },
    { name: 'an ancestry check that was never answered', args: withHead,
      check: undefined, ancestry: true, why: 'not confirmed as an ancestor' },
    { name: 'an empty ancestry check', args: withHead, check: '', ancestry: true },
    { name: 'an ancestry check with trailing text', args: withHead,
      check: 'TOUCHSTONE_PRIOR_HEAD 0 ', ancestry: true },
    { name: 'an ancestry check in the wrong case', args: withHead,
      check: 'touchstone_prior_head 0', ancestry: true },
  ]
  for (const c of cases) {
    const { result, captured } = await run({
      args: { maxReviewRounds: 1, runBudget: undefined, ...c.args },
      existingBranchResult: existing({ prior_head_check: c.check }),
      branchResult: existing(),
      triage: { estimated_loc: 100 }, diffstatFiles: [['a.js', 1000, 0]],
      initialReview: { correctness: [{ title: 'Fresh', file: 'src/y.js', claim: 'c', evidence: 'e' }],
        advocate: [] },
      verify: () => undefined,
      staleness: () => [],
    })
    const lenses = initialLensCalls(captured)
    check(`${c.name}: the review range is the implementer's`,
      lenses.length > 0 && lenses.every(l => l.prompt.includes(`Commit range: ${COMMIT_RANGE}\n`)), true)
    check(`${c.name}: nothing is carried and the first id is f1`,
      [idsOf(result.unresolved_findings), idsOf(result.notes)], [['f1'], []])
    check(`${c.name}: the budget log is today's and there is no raise`,
      [captured.logs.includes(`run budget: 300k output tokens (derived from triage's ~100 estimated LOC)`),
       captured.logs.some(l => l.startsWith('run budget raised'))], [true, false])
    check(`${c.name}: reviewed_through is this run's own review head`, result.reviewed_through, REVIEWED_THROUGH)
    const bx = captured.calls.find(l => l.label === (c.label ?? 'branch:existing'))?.prompt ?? ''
    check(`${c.name}: the ancestry step is ${c.ancestry ? 'asked for' : 'absent'}`,
      bx.includes('--is-ancestor'), c.ancestry)
    if (c.why) check(`${c.name}: the log says why`, captured.logs.some(l => l.includes(c.why)), true)
  }
}

async function scenarioR6() {
  console.log('\n== scenario R6: reviewed_through is the last head a review finished at, in every halt and the result')
  const prior = { unresolved_findings: [carriedFinding('f3')], notes: [carriedNote('f5')] }

  const done = await run(resumed({}))
  check('a finished resumed review reports the head it read up to, not the record\'s',
    done.result.reviewed_through, REVIEWED_THROUGH)

  const early = await run(resumed(prior, { args: { runBudget: 1_000_000 }, spendAllAfter: 'implementer' }))
  check('a budget halt before Draft PR is a halt', early.result.halted_at !== undefined, true)
  check('it reports the record\'s head', early.result.reviewed_through, P)
  check('it reports the carried findings', idsOf(early.result.unresolved_findings), ['f3'])
  check('it reports the carried notes', idsOf(early.result.notes), ['f5'])

  const inReview = await run(resumed(prior, { args: { runBudget: 1_000_000 }, spendAllAfter: 'draft-pr' }))
  check('a budget halt in the first review is a halt at Review', inReview.result.halted_at, 'Review')
  check('it reports the record\'s head, since that review never finished', inReview.result.reviewed_through, P)
  check('it reports the carried findings', idsOf(inReview.result.unresolved_findings), ['f3'])
  check('it reports the carried notes', idsOf(inReview.result.notes), ['f5'])

  const fixHalt = await run(resumed(prior, { args: { maxReviewRounds: 1 },
    verify: () => undefined, staleness: () => [] }))
  check('a Fix halt after the review reports the head that review read',
    [fixHalt.result.halted_at, fixHalt.result.reviewed_through], ['Fix', REVIEWED_THROUGH])

  const plain = await run({})
  check('a run that never resumed reports the head its review read', plain.result.reviewed_through, REVIEWED_THROUGH)

  const noLens = await run({ diffstatFiles: [['a.js', 5, 0]], mutationGated: true,
    mutationResult: mutationAt(MUT_HEAD) })
  check('a run with no reviewer lens never reports a head as reviewed, mutation commits included',
    noLens.result.reviewed_through, null)
  const noLensHalt = await run({ diffstatFiles: [['a.js', 5, 0]],
    args: { runBudget: 1_000_000, openPr: true }, spendAllAfter: 'draft-pr' })
  check('and neither does its halt', [noLensHalt.result.halted_at !== undefined, noLensHalt.result.reviewed_through],
    [true, null])

  const tinyResumed = await run(resumed({}, { diffstatFiles: [['a.js', 5, 0]] }))
  check('a resumed run whose range is too small for any lens keeps the record\'s head',
    tinyResumed.result.reviewed_through, P)

  const unreviewedFix = await run(resumed(prior, { args: { reviewers: 0 }, diffstatFiles: [['a.js', 5, 0]],
    verify: (id) => id === 'f3', fixHead: () => FIX_HEAD, staleness: () => [] }))
  check('a fix round committed with no tail review does not advance it',
    [callCount(unreviewedFix.captured, 'fix:1'), unreviewedFix.result.reviewed_through], [1, P])

  const mutated = await run(resumed({}, { mutationGated: true, mutationResult: mutationAt(MUT_HEAD) }))
  check('the reviewed mutation commits advance it', mutated.result.reviewed_through, MUT_HEAD)
}

async function scenarioR7() {
  console.log('\n== scenario R7: carried open findings keep fix-round tail reviews on when the first range gets no lens')
  const prior = { unresolved_findings: [carriedFinding('f3')], notes: [] }
  const base = {
    diffstatFiles: [['a.js', 5, 0]],
    verify: (id) => id === 'f3', fixHead: () => FIX_HEAD, staleness: () => [],
    prResult: { opened: true, url: 'https://example.invalid/pr/21', note: 'stub' },
  }
  const { result, captured } = await run(resumed(prior, { ...base, args: { openPr: true } }))
  check('no initial lens ran', initialLensCalls(captured).length, 0)
  check('the fix round ran', callCount(captured, 'fix:1'), 1)
  check('its commits got a tail review', callCount(captured, 'review:fix:1:correctness'), 1)
  const tail = captured.calls.find(c => c.label === 'review:fix:1:correctness')?.prompt ?? ''
  check('the tail review reads the fix round\'s own range',
    tail.includes(`Commit range: ${REVIEWED_THROUGH}..${FIX_HEAD}\n`), true)
  check('the run reports one reviewer', result.reviewers, 1)
  check('the head it reports is the fix round\'s', result.reviewed_through, FIX_HEAD)
  const pr = captured.calls.find(c => c.label === 'pr')?.prompt ?? ''
  check('the PR phase still guards against unreviewed commits',
    pr.includes(`git rev-list --count ${FIX_HEAD}..HEAD`), true)

  const optOut = await run(resumed(prior, { ...base, args: { openPr: true, reviewers: 0 } }))
  check('args.reviewers: 0 switches the floor off', callCount(optOut.captured, 'review:fix:1:correctness'), 0)
  check('and the run reports no reviewers', optOut.result.reviewers, 0)

  const notesOnly = await run(resumed({ notes: [carriedNote('f5')] }, { diffstatFiles: [['a.js', 5, 0]] }))
  check('carried notes alone do not raise the floor', notesOnly.result.reviewers, 0)
}

async function scenarioR8() {
  console.log('\n== scenario R8: the ancestry step is asked for exactly when a candidate head exists')
  const withHead = await run(resumed({}))
  const bx = withHead.captured.calls.find(c => c.label === 'branch:existing')
  check('the prompt gives the exact command', bx.prompt.includes(ANCESTRY_STEP(P)), true)
  check('the command is the only one asked to print the marker line',
    bx.prompt.split('echo TOUCHSTONE_PRIOR_HEAD').length - 1, 1)
  check('the schema carries prior_head_check as a string', bx.schema.properties.prior_head_check?.type, 'string')
  check('and does not require it', bx.schema.required.includes('prior_head_check'), false)

  for (const [name, args] of [
    ['no record', { existingBranch: true }],
    ['a record with no head', { existingBranch: true, priorRun: { unresolved_findings: [] } }],
    ['a non-hex head', { existingBranch: true, priorRun: { reviewed_through: 'abc123' } }],
  ]) {
    const { captured } = await run({ args, existingBranchResult: existing() })
    const p = captured.calls.find(c => c.label === 'branch:existing')?.prompt ?? ''
    check(`${name}: no ancestry command`, p.includes('merge-base --is-ancestor'), false)
    check(`${name}: no marker line`, p.includes('TOUCHSTONE_PRIOR_HEAD'), false)
    check(`${name}: no prior_head_check mention`, p.includes('prior_head_check'), false)
  }
}

const SCENARIOS = [scenarioR1, scenarioR2, scenarioR3, scenarioR4, scenarioR5, scenarioR6, scenarioR7,
  scenarioR8]
JS_EOF

finish
