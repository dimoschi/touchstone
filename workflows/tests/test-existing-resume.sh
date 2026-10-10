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
const PRIOR = (n) => `TOUCHSTONE_PRIOR_HEAD_LINEAR ${n}`
const PRIOR_OK = PRIOR(0)
const PRIOR_MERGED = PRIOR(2)
const ANCESTRY_STEP = (sha) =>
  `git -C <path> merge-base --is-ancestor ${sha} HEAD; a=$?; ` +
  `m=$(git -C <path> rev-list --merges --count ${sha}..HEAD); ` +
  `echo TOUCHSTONE_PRIOR_HEAD_LINEAR $((a ? 1 : (m ? 2 : 0)))`

const gitIn = (repo, ...a) => execFileSync('git',
  ['-C', repo, '-c', 'commit.gpgsign=false', '-c', 'gpg.format=openpgp', '-c', 'core.hooksPath=/dev/null', ...a],
  { encoding: 'utf8', env: { ...process.env, GIT_AUTHOR_NAME: 'test', GIT_AUTHOR_EMAIL: 't@t',
    GIT_COMMITTER_NAME: 'test', GIT_COMMITTER_EMAIL: 't@t' } }).trim()
const commit = (repo, file) => {
  fs.writeFileSync(path.join(repo, file), file)
  gitIn(repo, 'add', '-A')
  gitIn(repo, 'commit', '-q', '-m', file)
  return gitIn(repo, 'rev-parse', 'HEAD')
}

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
  const labels = captured.calls.map(c => c.label)
  check('the head is checked once, and before the range is measured',
    [callCount(captured, 'resume:range-check'), labels.indexOf('resume:range-check') < labels.indexOf('draft-pr')],
    [1, true])

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
  const raisedRun = (spend, triage = { estimated_loc: 100 }) => resumed({}, {
    args: { runBudget: undefined },
    triage,
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
  check('the halt note names the line count and range it was raised to fit',
    (refused.result.note ?? '').includes(`raised to fit the 1000 changed lines of the first review range ${range}`), true)
  check('and still names triage\'s estimate, as the figure it was raised from',
    (refused.result.note ?? '').includes(`from 300k (derived from triage's ~100 estimated LOC)`), true)

  const unestimated = await run(raisedRun({ v: 0, after: 1_100_000 }, { estimated_loc: null }))
  const unestimatedNote = unestimated.result.note ?? ''
  check('with no triage estimate the raise is still logged with the range and the line count',
    unestimated.captured.logs.includes(`run budget raised to 1000k (first review range ${range}, 1000 changed lines)`), true)
  check('the halt note says the budget was raised to fit the measured lines',
    unestimatedNote.includes('raised to fit the 1000 changed lines'), true)
  check('and keeps the note that triage gave no estimate, with the default it was raised from',
    unestimatedNote.includes('from 300k (triage gave no estimated_loc; using the inline default)'), true)
  check('and never claims a triage estimate that did not exist',
    unestimatedNote.includes('triage estimated'), false)

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
      check: PRIOR(1), ancestry: true, why: 'not confirmed as an ancestor' },
    { name: 'an ancestry check that printed a status it was never asked for', args: withHead,
      check: PRIOR(128), ancestry: true, why: 'not confirmed as an ancestor' },
    { name: 'the ancestry-only answer an earlier version asked for', args: withHead,
      check: 'TOUCHSTONE_PRIOR_HEAD 0', ancestry: true, why: 'not confirmed as an ancestor' },
    { name: 'an ancestry check that was never answered', args: withHead,
      check: undefined, ancestry: true, why: 'not confirmed as an ancestor' },
    { name: 'an empty ancestry check', args: withHead, check: '', ancestry: true },
    { name: 'an ancestry check with trailing text', args: withHead,
      check: `${PRIOR_OK} `, ancestry: true },
    { name: 'an ancestry check in the wrong case', args: withHead,
      check: PRIOR_OK.toLowerCase(), ancestry: true },
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
  check('the tail review starts at the record\'s head, so the first range\'s commits are read too',
    tail.includes(`Commit range: ${P}..${FIX_HEAD}\n`), true)
  check('the run reports one reviewer', result.reviewers, 1)
  check('the head it reports is the fix round\'s, which that review read up to', result.reviewed_through, FIX_HEAD)
  const count = captured.calls.find(c => c.label === 'pr-unreviewed')?.prompt ?? ''
  check('the PR phase still guards against unreviewed commits',
    count.includes(`rev-list --count ${FIX_HEAD}.."$h"`), true)

  const optOut = await run(resumed(prior, { ...base, args: { openPr: true, reviewers: 0 } }))
  check('args.reviewers: 0 switches the floor off', callCount(optOut.captured, 'review:fix:1:correctness'), 0)
  check('and the run reports no reviewers', optOut.result.reviewers, 0)

  const notesOnly = await run(resumed({ notes: [carriedNote('f5')] }, { diffstatFiles: [['a.js', 5, 0]] }))
  check('carried notes alone do not raise the floor', notesOnly.result.reviewers, 0)

  const uncommitted = await run(resumed(prior, { ...base, fixHead: () => REVIEWED_THROUGH }))
  check('a fix round that commits nothing is not reviewed, so the record\'s head stays',
    [callCount(uncommitted.captured, 'review:fix:1:correctness'), uncommitted.result.reviewed_through], [0, P])

  const mutated = await run(resumed(prior, { ...base, fixHead: () => REVIEWED_THROUGH,
    mutationGated: true, mutationResult: mutationAt(MUT_HEAD) }))
  const mutTail = mutated.captured.calls.find(c => c.label === 'review:mutation:correctness')?.prompt ?? ''
  check('the mutation review starts at the record\'s head too',
    mutTail.includes(`Commit range: ${P}..${MUT_HEAD}\n`), true)
  check('and moves the head it reports to the mutation head', mutated.result.reviewed_through, MUT_HEAD)

  const mutFinding = [{ title: 'Mutation commits introduced Z', file: 'a.js', claim: 'c', evidence: 'e' }]
  const gateOwn = (note, head) => note.includes(`The mutation gate's own commits (${head}..${MUT_HEAD})`)
  const floorMut = await run(resumed(prior, { ...base, fixHead: () => REVIEWED_THROUGH,
    mutationGated: true, mutationResult: mutationAt(MUT_HEAD), postMutationReview: mutFinding }))
  const floorNote = floorMut.result.note ?? ''
  check('a reproduced finding in the mutation review halts at Review',
    [floorMut.result.halted_at, floorMut.result.unresolved_findings?.length], ['Review', 1])
  check('the halt note does not blame the mutation gate for commits that start at the record\'s head',
    floorNote.includes(`gate's own commits (${P}..`), false)
  check('it names the range the review read', floorNote.includes(`${P}..${MUT_HEAD}`), true)
  check('and the gate\'s own range inside it', floorNote.includes(`(${REVIEWED_THROUGH}..${MUT_HEAD})`), true)
  const floorLens = floorMut.captured.calls.find(c => c.label === 'review:mutation:correctness')?.prompt ?? ''
  check('the mutation lens is not told the known findings were fixed before the commits it reads',
    floorLens.includes('fixed before the commits you are reviewing'), false)
  check('it is still told not to report a known finding again',
    floorLens.includes('do not report one of them again'), true)
  check('and that a defect in untouched code is not a finding here',
    floorLens.includes('commits do not touch is not a finding'), true)

  const lensedMut = await run(resumed({}, { mutationGated: true, mutationResult: mutationAt(MUT_HEAD),
    postMutationReview: mutFinding, verify: () => false }))
  check('a resumed run whose first range got its lenses still names only the gate\'s own commits',
    gateOwn(lensedMut.result.note ?? '', REVIEWED_THROUGH), true)
  const freshMut = await run({ mutationGated: true, mutationResult: mutationAt(MUT_HEAD),
    postMutationReview: mutFinding, verify: () => false })
  check('and so does a run that never resumed', gateOwn(freshMut.result.note ?? '', REVIEWED_THROUGH), true)
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

  const printed = async (repo, sha) => {
    const { captured } = await run({ args: { existingBranch: true, reviewedThrough: sha },
      existingBranchResult: existing() })
    const command = captured.calls.find(c => c.label === 'branch:existing').prompt.split('\n').pop()
    return execFileSync('bash', ['-c', command.split('<path>').join(repo)], { encoding: 'utf8' }).trim()
  }
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ts-ancestry-'))
  try {
    const repo = path.join(dir, 'repo')
    fs.mkdirSync(repo)
    gitIn(repo, 'init', '-q', '-b', 'main')
    const base = commit(repo, 'base.txt')
    gitIn(repo, 'checkout', '-q', '-b', 'other')
    const stray = commit(repo, 'stray.txt')
    gitIn(repo, 'checkout', '-q', '-b', 'feat', base)
    const reviewed = commit(repo, 'b1.txt')
    commit(repo, 'b2.txt')
    check('the command prints 0 for an ancestor with no merge after it',
      await printed(repo, reviewed), PRIOR_OK)
    check('and 1 for a commit that is not on the branch', await printed(repo, stray), PRIOR(1))
    check('and 1 for a commit git cannot resolve', await printed(repo, 'e'.repeat(40)), PRIOR(1))
    gitIn(repo, 'checkout', '-q', 'main')
    commit(repo, 'main-only.txt')
    gitIn(repo, 'checkout', '-q', 'feat')
    gitIn(repo, 'merge', '-q', '--no-ff', '-m', 'Merge main', 'main')
    commit(repo, 'b3.txt')
    check('and 2 once the base was merged in after it: still an ancestor, but a range from it carries the base',
      await printed(repo, reviewed), PRIOR_MERGED)
    check('a head after that merge prints 0 again', await printed(repo, gitIn(repo, 'rev-parse', 'HEAD~1')),
      PRIOR_OK)
  } finally {
    fs.rmSync(dir, { recursive: true, force: true })
  }
}

async function scenarioR9() {
  console.log('\n== scenario R9: a halt before the carry hands the record back whole')
  const prior = { unresolved_findings: [carriedFinding('f3')], notes: [carriedNote('f5')] }
  const worktreeHalt = (over) => ({ created: false, dirty: false, branch: 'feat/gh-21-stub', base: 'main',
    path: '/tmp/stub-worktree', ticket: '21', detail: 'stub', halt_reason: 'none', ...over })
  const kept = (name, result, at) => {
    check(`${name}: halts at ${at}`, result.halted_at, at)
    check(`${name}: reviewed_through is the record's`, result.reviewed_through, P)
    check(`${name}: the findings are the record's`, idsOf(result.unresolved_findings), ['f3'])
    check(`${name}: the notes are the record's`, idsOf(result.notes), ['f5'])
  }
  for (const [name, halt] of [
    ['a dirty checkout', { dirty: true, detail: 'M some-file' }],
    ['an ambiguous match', { halt_reason: 'ambiguous' }],
    ['an already merged branch', { halt_reason: 'merged' }],
    ['an occupied directory', { halt_reason: 'occupied' }],
    ['another ticket\'s branch', { halt_reason: 'wrong-ticket' }],
    ['no branch found', {}],
  ]) {
    kept(name, (await run(resumed(prior, { existingBranchResult: worktreeHalt(halt) }))).result, 'Worktree')
  }
  kept('an oversized supplied plan', (await run(resumed(prior, { args: { plan: 'x'.repeat(6001) } }))).result, 'Plan')

  const noHead = await run({ args: { existingBranch: true, priorRun: prior },
    existingBranchResult: worktreeHalt({ dirty: true }) })
  check('a record with no head hands back nothing',
    [noHead.result.reviewed_through, noHead.result.unresolved_findings, noHead.result.notes], [null, undefined, undefined])
  const fresh = await run({ args: { priorRun: { reviewed_through: P, ...prior } },
    branchResult: worktreeHalt({ dirty: true }) })
  check('a run that is not --existing hands back nothing either',
    [fresh.result.reviewed_through, fresh.result.unresolved_findings, fresh.result.notes], [null, undefined, undefined])

  const dropped = await run(resumed(prior, { existingBranchResult: existing({ prior_head_check: PRIOR(1) }),
    args: { runBudget: 1_000_000 }, spendAllAfter: 'implementer' }))
  check('a head that is not confirmed is dropped from a later halt, record and all',
    [dropped.result.halted_at !== undefined, dropped.result.reviewed_through,
     dropped.result.unresolved_findings, dropped.result.notes], [true, null, undefined, undefined])
}

async function scenarioR10() {
  console.log('\n== scenario R10: a carried finding whose reproducer nobody ran is measured again, not held open')
  const unmeasured = (id, over) => carriedFinding(id, { reproducer_run: { outcome: 'not-executed' }, ...over })
  const small = { diffstatFiles: [['a.js', 5, 0]], staleness: () => [] }
  const withF2 = { unresolved_findings: [unmeasured('f2')] }

  const cannotRun = await run(resumed(withF2, { ...small, verify: () => 127 }))
  check('its reproducer is run once, before any review or fix', callCount(cannotRun.captured, 'reproduce:carried'), 1)
  check('a reproducer that cannot run makes it a note, as it would a fresh candidate',
    [idsOf(cannotRun.result.notes), cannotRun.result.notes[0]?.reason], [['f2'], 'reproducer-could-not-run'])
  check('so nothing is open and no fix round runs',
    [idsOf(cannotRun.result.unresolved_findings), callCount(cannotRun.captured, 'fix:1'), cannotRun.result.halted_at],
    [[], 0, undefined])

  const errored = await run(resumed(withF2, { ...small, verify: () => 2,
    outputFor: () => 'crashed, no marker' }))
  check('a reproducer that errors without the marker makes it a note too',
    [idsOf(errored.result.notes), errored.result.notes[0]?.reason, callCount(errored.captured, 'fix:1')],
    [['f2'], 'reproducer-errored', 0])

  const passed = await run(resumed(withF2, { ...small, verify: () => true }))
  check('a reproducer that passes makes it a note',
    [idsOf(passed.result.notes), passed.result.notes[0]?.reason, callCount(passed.captured, 'fix:1')],
    [['f2'], 'did-not-reproduce', 0])

  const reproduced = await run(resumed(withF2, { ...small, verify: (id, round) => round === 0 ? 1 : true }))
  const fix1 = reproduced.captured.calls.find(c => c.label === 'fix:1')?.prompt ?? ''
  check('one that reproduces is open, handed to the fixer with its reproducer',
    fix1.includes('Carried f2 (src/f2.js:1): claim of f2 [reproduce: carried-repro f2]'), true)
  check('and is settled once the fix passes', [idsOf(reproduced.result.unresolved_findings), reproduced.result.halted_at],
    [[], undefined])

  const stillUnmeasured = await run(resumed(withF2, { ...small, verify: () => 'norow' }))
  check('one still unmeasured after the retry halts the run on measurement',
    [stillUnmeasured.result.halted_at, callCount(stillUnmeasured.captured, 'reproduce:carried:retry'),
     idsOf(stillUnmeasured.result.unresolved_findings)], ['Review', 1, ['f2']])
  check('the halt reports the record\'s head, since no review finished', stillUnmeasured.result.reviewed_through, P)
  check('and the finding as still unmeasured',
    stillUnmeasured.result.unresolved_findings?.[0]?.reproducer_run?.outcome, 'not-executed')

  const dirty = await run(resumed(withF2, { ...small, dirtyAt: 'reproduce:carried' }))
  check('a reproducer that leaves the tree dirty halts and keeps the finding',
    [dirty.result.halted_at, idsOf(dirty.result.unresolved_findings)], ['Review', ['f2']])

  const mixed = await run(resumed({ unresolved_findings: [unmeasured('f2'), carriedFinding('f3')] },
    { ...small, verify: (id, round) => round === 0 ? 127 : id === 'f3' }))
  const mixedFix = mixed.captured.calls.find(c => c.label === 'fix:1')?.prompt ?? ''
  check('only the unmeasured one is run first; a measured one goes straight to the fixer',
    [mixedFix.includes('Carried f3'), mixedFix.includes('Carried f2'), idsOf(mixed.result.notes)],
    [true, false, ['f2']])

  const reviewed = await run(resumed(withF2, { verify: () => 127, staleness: () => [] }))
  const lenses = initialLensCalls(reviewed.captured)
  check('the lenses run after it and are told the outcome by id',
    [lenses.length, lenses.every(c => c.prompt.includes('[f2] Carried f2 (src/f2.js)'))], [2, true])
}

async function scenarioR11() {
  console.log('\n== scenario R11: a head the base was merged after is still an ancestor, so its record is kept and the whole branch is reviewed')
  const prior = { unresolved_findings: [carriedFinding('f3')], notes: [carriedNote('f5')] }
  const merged = existing({ prior_head_check: PRIOR_MERGED })
  const BASE = COMMIT_RANGE.split('..')[0]

  const reviewed = await run(resumed(prior, { existingBranchResult: merged, args: { maxReviewRounds: 1, runBudget: undefined },
    triage: { estimated_loc: 100 }, diffstatFiles: [['a.js', 1000, 0]],
    verify: () => undefined, staleness: () => [] }))
  const lenses = initialLensCalls(reviewed.captured)
  check('the lenses review the whole branch', lenses.length > 0 &&
    lenses.every(c => c.prompt.includes(`Commit range: ${COMMIT_RANGE}\n`)), true)
  check('no lens is given a range from the record\'s head', lenses.some(c => c.prompt.includes(P)), false)
  check('the carried finding and note are still tracked, so the lenses are told of them',
    lenses.every(c => c.prompt.includes('[f3] Carried f3 (src/f3.js)') && c.prompt.includes('[f5] Note f5 (src/f5.js)')), true)
  check('the carried finding reaches the fixer',
    (reviewed.captured.calls.find(c => c.label === 'fix:1')?.prompt ?? '').includes('Carried f3'), true)
  check('the carried finding and note are in the result',
    [idsOf(reviewed.result.unresolved_findings), idsOf(reviewed.result.notes)], [['f3'], ['f5']])
  check('the whole branch is what the first review reads, so the budget is raised to fit it, not left at triage\'s estimate of the narrowed task',
    reviewed.captured.logs.includes(`run budget raised to 1000k (first review range ${COMMIT_RANGE}, 1000 changed lines)`), true)
  check('the head check is not repeated once the branch step found the merge',
    callCount(reviewed.captured, 'resume:range-check'), 0)
  check('the head it reports is the one that review read up to', reviewed.result.reviewed_through, REVIEWED_THROUGH)

  const tiny = await run(resumed(prior, { existingBranchResult: merged, diffstatFiles: [['a.js', 5, 0]],
    verify: (id) => id === 'f3', fixHead: () => FIX_HEAD, staleness: () => [] }))
  check('a branch too small for any lens still reviews the carried finding\'s fix', callCount(tiny.captured, 'review:fix:1:correctness'), 1)
  const tail = tiny.captured.calls.find(c => c.label === 'review:fix:1:correctness')?.prompt ?? ''
  check('that review starts where the whole branch does, so the commits no lens read are read too',
    tail.includes(`Commit range: ${BASE}..${FIX_HEAD}\n`), true)
  check('and the head it reports is the one that review read up to', tiny.result.reviewed_through, FIX_HEAD)

  const halted = await run(resumed(prior, { existingBranchResult: merged, args: { runBudget: 1_000_000 },
    spendAllAfter: 'draft-pr' }))
  check('a halt before any review keeps the record whole',
    [halted.result.halted_at, halted.result.reviewed_through, idsOf(halted.result.unresolved_findings),
     idsOf(halted.result.notes)], ['Review', P, ['f3'], ['f5']])
}

async function scenarioR12() {
  console.log('\n== scenario R12: a demonstrated finding whose latest row went missing is carried open; only one nobody ever ran is measured again')
  const small = { diffstatFiles: [['a.js', 5, 0]], staleness: () => [] }
  const openDropped = await run({ args: { maxReviewRounds: 1 },
    initialReview: { correctness: [{ title: 'Open then dropped', file: 'src/p.js', claim: 'c', evidence: 'e' }], advocate: [] },
    verify: (id, round) => round >= 1 ? 'norow' : 1, fixHead: () => FIX_HEAD, staleness: () => [] })
  check('an open finding the executor drops in a fix round halts the setup run at Fix',
    [openDropped.result.halted_at, idsOf(openDropped.result.unresolved_findings)], ['Fix', ['f1']])
  const settledDropped = await run(convergedWithSuspect({ tailReview: [],
    initialReview: { correctness: [{ title: 'Settled then dropped', file: 'src/q.js', claim: 'c', evidence: 'e' }], advocate: [] },
    verify: (id) => id === 'f1' ? true : undefined, mutationResult: mutationAt(MUT_HEAD),
    settledExit: (id, round) => round === 'mutation' ? undefined : 0 }))
  check('a settled finding whose recheck row is dropped halts the setup run at Review',
    [settledDropped.result.halted_at, idsOf(settledDropped.result.unresolved_findings)], ['Review', ['f1']])

  check('a settled finding whose re-check could not be measured is carried as awaiting a re-check',
    (settledDropped.result.unresolved_findings ?? []).map(f => f.awaiting_recheck), [true])
  const recheck = await run(resumed({ unresolved_findings: settledDropped.result.unresolved_findings,
    notes: settledDropped.result.notes }, { ...small, verify: () => 2, outputFor: () => 'crashed, no marker' }))
  check('a settled one: it never reaches a fixer', callCount(recheck.captured, 'fix:1'), 0)
  check('a settled one: it is not run first as a candidate', callCount(recheck.captured, 'reproduce:carried'), 0)
  for (const [name, setup] of [['an open one', openDropped]]) {
    const rec = setup.result
    const { result, captured } = await run(resumed({ unresolved_findings: rec.unresolved_findings, notes: rec.notes },
      { ...small, verify: () => 2, outputFor: () => 'crashed, no marker' }))
    check(`${name}: its reproducer is not run first as a candidate`, callCount(captured, 'reproduce:carried'), 0)
    check(`${name}: it reaches the fixer`,
      (captured.calls.find(c => c.label === 'fix:1')?.prompt ?? '').includes(rec.unresolved_findings[0].title), true)
    check(`${name}: it stays open, and is not demoted to a note`,
      [idsOf(result.unresolved_findings), idsOf(result.notes)], [['f1'], []])
  }

  const never = await run({ initialReview: { correctness: [{ title: 'Never measured', file: 'src/r.js', claim: 'c', evidence: 'e' }], advocate: [] },
    initialExit: () => undefined })
  check('a candidate no row ever came back for halts the setup run on measurement',
    [never.result.halted_at, never.result.unresolved_findings?.[0]?.reproducer_run?.outcome], ['Review', 'not-executed'])
  const remeasured = await run(resumed({ unresolved_findings: never.result.unresolved_findings, notes: never.result.notes },
    { ...small, verify: () => true }))
  check('and is the only kind a resumed run measures first', callCount(remeasured.captured, 'reproduce:carried'), 1)
}

async function scenarioR13() {
  console.log('\n== scenario R13: a base merge made during the run is not reviewed as this branch\'s work')
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ts-merge-in-run-'))
  try {
    const repo = path.join(dir, 'repo')
    fs.mkdirSync(repo)
    gitIn(repo, 'init', '-q', '-b', 'main')
    commit(repo, 'base.txt')
    gitIn(repo, 'checkout', '-q', '-b', 'feat')
    const reviewed = commit(repo, 'b1.txt')
    gitIn(repo, 'checkout', '-q', 'main')
    commit(repo, 'main-only.txt')
    gitIn(repo, 'checkout', '-q', 'feat')
    gitIn(repo, 'merge', '-q', '--no-ff', '-m', 'Merge main', 'main')
    const head = commit(repo, 'b2.txt')
    const whole = `${gitIn(repo, 'merge-base', head, 'main')}..${head}`
    const rangeOf = (c) => (/Commit range: (\S+)\n/.exec(c.prompt) ?? [])[1]
    const prior = { reviewed_through: reviewed, unresolved_findings: [carriedFinding('f3')], notes: [carriedNote('f5')] }
    const inRun = (over) => resumed(prior, {
      existingBranchResult: existing({ path: repo }), implRange: whole,
      args: { maxReviewRounds: 1, runBudget: undefined },
      triage: { estimated_loc: 100 }, diffstatFiles: [['a.js', 1000, 0]],
      verify: () => undefined, staleness: () => [], fixHead: () => head, ...over })

    const merged = await run(inRun())
    const lenses = initialLensCalls(merged.captured)
    check('the head is checked once, at the head Implement left',
      (merged.captured.calls.filter(c => c.label === 'resume:range-check').map(c => c.prompt.split('\n').pop())), [
        `git -C ${repo} merge-base --is-ancestor ${reviewed} ${head}; a=$?; ` +
        `m=$(git -C ${repo} rev-list --merges --count ${reviewed}..${head}); ` +
        `echo TOUCHSTONE_PRIOR_HEAD_LINEAR $((a ? 1 : (m ? 2 : 0)))`])
    check('the lenses review the whole branch', lenses.length > 0 && lenses.every(c => rangeOf(c) === whole), true)
    check('no lens range holds the base\'s own changes',
      lenses.flatMap(c => gitIn(repo, 'diff', '--name-only', rangeOf(c)).split('\n')).includes('main-only.txt'), false)
    check('the diffstat measures the whole branch, not the range from the record\'s head',
      (merged.captured.calls.find(c => c.label === 'draft-pr')?.prompt ?? '').includes(`echo TOUCHSTONE_DIFFSTAT ${whole};`), true)
    check('the budget is raised to fit the whole branch it now reviews',
      merged.captured.logs.includes(`run budget raised to 1000k (first review range ${whole}, 1000 changed lines)`), true)
    check('the record is still carried',
      [idsOf(merged.result.unresolved_findings), idsOf(merged.result.notes)], [['f3'], ['f5']])
    check('the head reported is the one the whole-branch review read up to', merged.result.reviewed_through, head)
    check('the fallback is logged', merged.captured.logs.some(
      l => l.includes(`reviewed head ${reviewed}`) && l.includes('reviewing the whole branch')), true)

    const rangesOf = (r) => [...new Set(initialLensCalls(r.captured).map(rangeOf))]
    const follow = commit(repo, 'b3.txt')
    const linear = await run(inRun({ implRange: `${whole.split('..')[0]}..${follow}`, fixHead: () => follow,
      args: { maxReviewRounds: 1, runBudget: undefined, reviewedThrough: head } }))
    check('with no merge after the record\'s head the first review is still narrowed to it',
      rangesOf(linear), [`${head}..${follow}`])

    for (const [name, out] of [['no answer', null], ['an unreadable answer', 'not the marker'],
      ['a head no longer on the branch', 'TOUCHSTONE_PRIOR_HEAD_LINEAR 1']]) {
      const unsure = await run(inRun({ rangeCheck: () => out }))
      check(`${name} reviews the whole branch rather than trusting the narrowed range`,
        rangesOf(unsure), [whole])
    }
  } finally {
    fs.rmSync(dir, { recursive: true, force: true })
  }

  for (const [name, args] of [
    ['a run with no record', { existingBranch: true }],
    ['a run whose head the branch step did not confirm', { existingBranch: true, priorRun: { reviewed_through: P } }],
  ]) {
    const { captured } = await run({ args, existingBranchResult: existing({ prior_head_check: PRIOR(1) }) })
    check(`${name} never repeats the head check`, callCount(captured, 'resume:range-check'), 0)
  }
}

async function scenarioR14() {
  console.log('\n== scenario R14: a carried finding whose last run passed waits for the settled re-check, never a fixer')
  const passed = carriedFinding('f3', { awaiting_recheck: true,
    reproducer_run: { outcome: 'passed', exit_code: 0, log: '/x/f3.log', round: 1 } })
  const live = carriedFinding('f4', { reproducer_run: { outcome: 'reproduced', exit_code: 1, log: '/x/f4.log', round: 1 } })
  const { result, captured } = await run(resumed({ unresolved_findings: [passed, live] }, {
    initialReview: { correctness: [], advocate: [] },
    fixHead: () => 'fix00000000000000000000000000000000000001' }))
  const fixer = captured.calls.find(c => c.label === 'fix:1')?.prompt ?? ''
  check('the fixer is briefed on the live finding', fixer.includes('Carried f4'), true)
  check('the fixer is not briefed on the passed one', fixer.includes('Carried f3'), false)
  const settledCheck = captured.calls.find(c => c.label === 'reproduce:settled:1')?.prompt ?? ''
  check('the passed one is re-checked as settled', settledCheck.includes('f3'), true)
  check('it is no longer marked as awaiting a re-check once it was re-checked',
    (result.unresolved_findings ?? []).some(f => f.awaiting_recheck), false)
}

const SCENARIOS = [scenarioR1, scenarioR2, scenarioR3, scenarioR4, scenarioR5, scenarioR6, scenarioR7,
  scenarioR8, scenarioR9, scenarioR10, scenarioR11, scenarioR12, scenarioR13, scenarioR14]
JS_EOF

finish
