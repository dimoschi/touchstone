#!/usr/bin/env bash
# Scenarios scenarioCL..scenarioDK, split out of
# test-fix-loop-join.sh (gh-118); see harness.sh.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/harness.sh"

run_js_scenarios <<'JS_EOF'
// Scenario CL -- a single-line finding is the shape the charge asks for most
// often, since a second line is wanted only when the span covers more than
// one. Losing the locus for exactly that shape would restore the old bare
// filename brief everywhere and break nothing else.
async function scenarioCL() {
  console.log('\n== scenario CL: a finding with only line_start still reaches the fixer with its line')
  const { captured } = await run({
    args: { maxReviewRounds: 1 },
    initialReview: {
      correctness: [{ title: 'Still open', file: 'a.js', claim: 'c', evidence: 'e',
        line_start: 42 }],
      advocate: [],
    },
    verify: () => undefined,
    staleness: () => [],
  })
  const fix1 = captured.calls.find(c => c.label === 'fix:1')?.prompt ?? ''
  check('the fix phase ran', fix1.length > 0, true)
  check('the single-line locus reaches the brief', fix1.includes('a.js:42'), true)
  check('it is not degraded to a bare filename',
    /\(a\.js\)/.test(fix1), false)
}

// Scenario CM -- the spanless count is the only thing that makes locus drift
// visible, so it has to be observable itself: a lens quietly dropping spans
// would otherwise look exactly like a lens that never had them.
async function scenarioCM() {
  console.log('\n== scenario CM: findings arriving with no line span are counted and named')
  const { captured } = await run({
    args: { maxReviewRounds: 1 },
    initialReview: {
      correctness: [{ title: 'No span', file: 'noloc.js', claim: 'c', evidence: 'e',
                      line_start: undefined },
                    { title: 'Has one', file: 'b.js', claim: 'c2', evidence: 'e2',
                      line_start: 7, line_end: 9 }],
      advocate: [],
    },
    verify: () => undefined,
    staleness: () => [],
  })
  const spanLog = captured.logs.find(l => l.includes('carry no line span')) ?? ''
  check('the count is logged at all', spanLog.length > 0, true)
  check('it counts only the spanless one, against the total raised',
    spanLog.includes('1 of 2'), true)
  check('it names which finding and file, so drift is attributable',
    spanLog.includes('noloc.js'), true)
  check('the one that carried a span is not counted',
    spanLog.includes('b.js'), false)
}

// Scenario CN -- a run whose loop executes no rounds at all (maxReviewRounds
// 0) still classifies and executes the initial finding's reproducer before
// halting; the round-0 classification is not something only a fix round
// triggers.
async function scenarioCN() {
  console.log('\n== scenario CN: with maxReviewRounds 0, the initial finding is still classified and halts without any fix round')
  const { result, captured } = await run({
    args: { maxReviewRounds: 0 },
    initialReview: {
      correctness: [{ title: 'Never fixed', file: 'a.js', claim: 'c', evidence: 'e',
        line_start: 3 }],
      advocate: [],
    },
    staleness: () => [],
  })
  check('no fix round ran', captured.calls.filter(c => c.label.startsWith('fix:')).length, 0)
  check('the initial classification still ran', callCount(captured, 'reproduce:review'), 1)
  check('halted at Fix', result.halted_at, 'Fix')
  check('the finding is reported', result.unresolved_findings?.length, 1)
}

// Scenario CO -- the scratch rule lives in the prompt builder every phase
// shares, and static greps only prove the text is in the file. Emitting it
// for one label and not the rest would leave every grep green while the
// phases that actually run experiments never see it.
async function scenarioCO() {
  console.log('\n== scenario CO: the scratch rule reaches every phase that runs commands')
  const { captured } = await run({
    args: { maxReviewRounds: 1, mutationGated: true },
    mutationGated: true,
    initialReview: {
      correctness: [{ title: 'Open', file: 'a.js', claim: 'c', evidence: 'e', line_start: 3 }],
      advocate: [],
    },
    verify: () => undefined,
    staleness: () => [],
  })
  for (const label of ['implementer', 'review:correctness', 'fix:1']) {
    const p = captured.calls.find(c => c.label === label)?.prompt ?? ''
    check(`${label} ran`, p.length > 0, true)
    check(`${label} is told where scratch work goes`,
      p.includes('touchstone-scratch'), true)
    check(`${label} is told not to use /tmp`,
      p.includes('anything you would otherwise drop in /tmp'), true)
  }
}

// Scenario CG -- #44: a lens that cannot name a clean span (a deletion, a
// repo-wide pattern) must not break the run; the schema field is optional.
async function scenarioCG() {
  console.log('\n== scenario CG: a finding without a line span still flows through the fix loop unbroken')
  const { result, captured } = await run({
    initialReview: {
      // line_start explicitly absent (undefined defeats defaultFinding's
      // permissive default of 1): a deletion or a repo-wide pattern has no
      // single span, and that must not break the run.
      correctness: [{ title: 'No span reported', file: 'noloc.js', claim: 'c', evidence: 'e',
        line_start: undefined }],
      advocate: [],
    },
    verify: (id) => id === 'f1' ? true : undefined,
  })
  const fix1 = captured.calls.find(c => c.label === 'fix:1')?.prompt ?? ''
  check('the fix phase ran', fix1.length > 0, true)
  check('the finding still renders by its bare file', fix1.includes('(noloc.js):'), true)
  check('halted_at is absent (the run finished; the missing span did not break it)',
    result.halted_at, undefined)
}

// Scenario CH -- #44: the fix agent's own per-round spend, the cost this
// ticket targets, must reach a halt so a round that never converges is still
// measurable against the ceiling that stopped it.
async function scenarioCH() {
  console.log('\n== scenario CH: fix_round_output records the fix agent\'s own spend per round, on a halt')
  const { result } = await run({
    args: { maxReviewRounds: 1 },
    initialReview: {
      correctness: [{ title: 'Still open', file: 'a.js', claim: 'c', evidence: 'e' }],
      advocate: [],
    },
    verify: () => undefined,
    staleness: () => [],
  })
  check('halted at Fix', result.halted_at, 'Fix')
  check('one round ran', result.fix_rounds, 1)
  check('fix_round_output has one entry', result.fix_round_output?.length, 1)
  check('the entry names round 1', result.fix_round_output?.[0]?.round, 1)
  check('the entry carries a finite output figure',
    Number.isFinite(result.fix_round_output?.[0]?.output), true)
}

// Scenario CI -- #44: the same field on the ordinary, non-halt exit, so a run
// that resolves cleanly is comparable to one that halts.
async function scenarioCI() {
  console.log('\n== scenario CI: fix_round_output reaches the final result on a run that resolves cleanly')
  const { result } = await run({
    initialReview: {
      correctness: [{ title: 'Will be fixed', file: 'a.js', claim: 'c', evidence: 'e' }],
      advocate: [],
    },
    verify: (id) => id === 'f1' ? true : undefined,
  })
  check('halted_at is absent (the run finished)', result.halted_at, undefined)
  check('exactly one fix round ran', result.fix_rounds, 1)
  check('fix_round_output carries that one round', result.fix_round_output?.length, 1)
}

// Scenario CP -- gh-106: a non-blocking category (docs) never becomes a
// candidate at all, regardless of what its reproducer would report: the
// script's rule fires before any reproducer for it is ever run.
async function scenarioCP() {
  console.log('\n== scenario CP: a docs-category finding is a note, never a candidate, and never reaches Fix')
  const { result, captured } = await run({
    initialReview: {
      correctness: [{ category: 'docs', title: 'Stale comment', file: 'a.js',
        claim: 'comment names the wrong caller', evidence: 'a.js:3',
        reproducer: { kind: 'command', command: 'true', expected: 'exit 0', actual: 'exit 1' } }],
      advocate: [],
    },
  })
  check('halted_at is absent', result.halted_at, undefined)
  check('no fix round ran', callCount(captured, 'fix:1'), 0)
  check('no reproducer was ever run for it', callCount(captured, 'reproduce:review'), 0)
  check('the finding is a note with reason category',
    result.notes?.some(n => n.reason === 'category' && n.title === 'Stale comment'), true)
}

// Scenario CQ -- gh-106: a blocking category with an incomplete reproducer
// (explicitly absent here) is a note, not a candidate.
async function scenarioCQ() {
  console.log('\n== scenario CQ: a blocking-category finding with no complete reproducer is a note, never entering the fix loop')
  const { result, captured } = await run({
    initialReview: {
      correctness: [{ category: 'wrong-result', title: 'Looks wrong', file: 'a.js',
        claim: 'c', evidence: 'e', reproducer: undefined }],
      advocate: [],
    },
  })
  check('halted_at is absent', result.halted_at, undefined)
  check('no fix round ran', callCount(captured, 'fix:1'), 0)
  check('no reproducer was ever run for it', callCount(captured, 'reproduce:review'), 0)
  check('the finding is a note with reason no-reproducer',
    result.notes?.some(n => n.reason === 'no-reproducer' && n.title === 'Looks wrong'), true)
}

// Scenario CR -- gh-106: the initial-classification exit-code rule, every
// non-row disposition in one run. 0, 126 and 127 are notes; any other exit
// code opens a candidate. The no-row path (gh-113's retry-then-halt) is
// covered separately by FH/FI/FJ/FK.
async function scenarioCR() {
  console.log('\n== scenario CR: initial classification dispositions by exit code')
  const { result } = await run({
    initialReview: {
      correctness: [
        { title: 'Exits 0', file: 'a.js', claim: 'c0', evidence: 'e0' },
        { title: 'Exits 126', file: 'b.js', claim: 'c126', evidence: 'e126' },
        { title: 'Exits 127', file: 'c.js', claim: 'c127', evidence: 'e127' },
        { title: 'Exits 2', file: 'e.js', claim: 'c2', evidence: 'e2' },
      ],
      advocate: [],
    },
    initialExit: (id) => ({ f1: 0, f2: 126, f3: 127, f4: 2 })[id],
  })
  const notesByTitle = Object.fromEntries((result.notes ?? []).map(n => [n.title, n.reason]))
  check('exit 0 is a note: did-not-reproduce', notesByTitle['Exits 0'], 'did-not-reproduce')
  check('exit 126 is a note: reproducer-could-not-run', notesByTitle['Exits 126'], 'reproducer-could-not-run')
  check('exit 127 is a note: reproducer-could-not-run', notesByTitle['Exits 127'], 'reproducer-could-not-run')
  check('any other exit code opens the finding',
    result.unresolved_findings?.some(f => f.title === 'Exits 2'), true)
  check('exactly one finding opened (the rest are notes)',
    result.unresolved_findings?.length, 1)
}

// Scenario CS -- gh-106: an unmet-criterion finding blocks only when its
// quote is a verbatim substring of the ticket text; a reworded quote is a
// note instead, never a silent pass for the reviewer's paraphrase.
async function scenarioCS() {
  console.log('\n== scenario CS: an unmet-criterion finding blocks only when its quote is verbatim in the ticket text')
  const { result } = await run({
    ticketResult: { found: true, summary: 'stub', comments: '',
      description: 'Acceptance: the client must retry on a 503 with backoff.' },
    initialReview: {
      correctness: [
        { category: 'unmet-criterion', title: 'Missing retry path', file: 'a.js',
          claim: 'the retry path was never implemented', evidence: 'a.js:1',
          criterion_quote: 'the client must retry on a 503 with backoff',
          reproducer: { kind: 'command', command: 'true', expected: 'exit 0', actual: 'exit 1' } },
        { category: 'unmet-criterion', title: 'Reworded criterion', file: 'b.js',
          claim: 'paraphrased, not verbatim', evidence: 'b.js:1',
          criterion_quote: 'clients should retry on server errors eventually',
          reproducer: { kind: 'command', command: 'true', expected: 'exit 0', actual: 'exit 1' } },
      ],
      advocate: [],
    },
    initialExit: () => 1,
  })
  check('the verbatim quote opens the finding',
    result.unresolved_findings?.some(f => f.title === 'Missing retry path'), true)
  check('the reworded quote is a note with reason quote-not-found',
    result.notes?.some(n => n.title === 'Reworded criterion' && n.reason === 'quote-not-found'), true)
}

// Scenario CT -- gh-106: the per-lens cap. The script slices to
// MAX_FINDINGS_PER_LENS itself rather than trusting a maxItems schema
// failure, and logs what it dropped.
async function scenarioCT() {
  console.log('\n== scenario CT: reviewOf slices a lens\'s findings to the per-lens cap and logs the drop')
  const many = Array.from({ length: 7 }, (_, i) => ({
    title: `Bug ${i + 1}`, file: `f${i + 1}.js`, claim: `c${i + 1}`, evidence: `e${i + 1}`,
  }))
  const { result, captured } = await run({
    initialReview: { correctness: many, advocate: [] },
    initialExit: () => 1,
  })
  const total = (result.notes?.length ?? 0) + (result.unresolved_findings?.length ?? 0)
  check('at most 5 of the 7 raised findings survive the per-lens cap', total <= 5, true)
  check('the drop is logged', captured.logs.some(l => l.includes('keeping the first 5, dropping 2')), true)
}

// Scenario CU -- gh-106: ticketSpec() reaches only the requirements lens,
// via the needsTicket flag on its LENS entry; correctness and advocate never
// see the ticket text, per the envelope rule.
async function scenarioCU() {
  console.log('\n== scenario CU: only the requirements lens is shown the ticket text')
  const { captured } = await run({
    diffstatFiles: [['a.js', 500, 0]], // codeChurn 500 (> BIG_LOC), adds the requirements lens
    ticketResult: { found: true, summary: 'stub', comments: '', description: 'ACCEPTANCE_TEXT_MARKER' },
    initialReview: { correctness: [], advocate: [], requirements: [] },
  })
  const correctnessPrompt = captured.calls.find(c => c.label === 'review:correctness')?.prompt ?? ''
  const advocatePrompt = captured.calls.find(c => c.label === 'review:advocate')?.prompt ?? ''
  const requirementsPrompt = captured.calls.find(c => c.label === 'review:requirements')?.prompt ?? ''
  check('the requirements lens ran', requirementsPrompt.length > 0, true)
  check('only the requirements lens sees the ticket text',
    requirementsPrompt.includes('ACCEPTANCE_TEXT_MARKER'), true)
  check('the correctness lens does not', correctnessPrompt.includes('ACCEPTANCE_TEXT_MARKER'), false)
  check('the advocate lens does not', advocatePrompt.includes('ACCEPTANCE_TEXT_MARKER'), false)
}

// Scenario CV -- gh-106: a reproducer that writes to the tree halts outright
// and names the porcelain output, the same principle runChecks already
// applies to the repo's own discovered checks.
async function scenarioCV() {
  console.log('\n== scenario CV: a reproducer execution that dirties the tree halts and names the porcelain output')
  const { result } = await run({
    initialReview: {
      correctness: [{ title: 'Needs a look', file: 'a.js', claim: 'c', evidence: 'e' }],
      advocate: [],
    },
    initialExit: () => 1,
    reproducerDirty: true,
    reproducerPorcelain: ' M fixture.txt',
  })
  check('halted at Review', result.halted_at, 'Review')
  check('the note names the porcelain output', (result.note ?? '').includes('fixture.txt'), true)
}

// Scenario CW -- gh-106: the expected outcome this ticket exists for. A run
// whose only finding is a note (never blocking) proceeds through Mutation to
// the PR, exactly as if no finding had been raised at all.
async function scenarioCW() {
  console.log('\n== scenario CW: a run whose findings are all notes continues through Mutation to the PR phase')
  const { result, captured } = await run({
    args: { openPr: true },
    prResult: { opened: true, url: 'https://example.invalid/pr/30', note: 'stub ready' },
    initialReview: {
      correctness: [{ category: 'docs', title: 'Stale doc', file: 'a.js', claim: 'c', evidence: 'e' }],
      advocate: [],
    },
    mutationGated: true,
  })
  check('halted_at is absent', result.halted_at, undefined)
  check('the finding is recorded as a note', result.notes?.some(n => n.reason === 'category'), true)
  check('mutation actually ran', callCount(captured, 'mutation:1'), 1)
  check('the PR opened', result.pr?.opened, true)
}

// Scenario CX -- gh-106: from the first tail review on, a finding blocks only
// if its line span overlaps a new-side hunk of the preceding fix range. Out
// of range is a note, not a silent pass and not a block.
async function scenarioCX() {
  console.log('\n== scenario CX: a tail-review finding outside the round\'s own diff hunk is a note, not open')
  const { result } = await run({
    args: { maxReviewRounds: 1 },
    initialReview: {
      correctness: [{ title: 'Needs a fix', file: 'x.js', claim: 'c', evidence: 'e' }],
      advocate: [],
    },
    verify: (id) => id === 'f1' ? true : undefined,
    fixHead: () => 'fix00000000000000000000000000000000000001',
    hunks: () => ['+++ b/x.js', '@@ -100,5 +100,5 @@'],
    tailReview: [{ title: 'Unrelated to this fix', file: 'x.js', claim: 'c2', evidence: 'e2',
      line_start: 500 }],
    staleness: () => [],
  })
  check('halted_at is absent (the run finished; the out-of-range finding did not block)',
    result.halted_at, undefined)
  check('the out-of-range finding is a note with reason out-of-range',
    result.notes?.some(n => n.reason === 'out-of-range' && n.title === 'Unrelated to this fix'), true)
}

// Scenario CY -- the control for CX: the same shape, but the finding's line
// does sit inside the round's own hunk, and it opens as usual.
async function scenarioCY() {
  console.log('\n== scenario CY: an in-range tail-review finding still opens and halts')
  const { result } = await run({
    args: { maxReviewRounds: 1 },
    initialReview: {
      correctness: [{ title: 'Needs a fix', file: 'x.js', claim: 'c', evidence: 'e' }],
      advocate: [],
    },
    verify: (id) => id === 'f1' ? true : undefined,
    fixHead: () => 'fix00000000000000000000000000000000000001',
    hunks: () => ['+++ b/x.js', '@@ -100,5 +100,5 @@'],
    tailReview: [{ title: 'In this fix\'s own hunk', file: 'x.js', claim: 'c2', evidence: 'e2',
      line_start: 102 }],
    staleness: () => [],
  })
  check('halted at Fix (the in-range finding blocks)', result.halted_at, 'Fix')
  check('the in-range finding is reported as unresolved',
    result.unresolved_findings?.some(f => f.title === 'In this fix\'s own hunk'), true)
}

async function scenarioCZ() {
  console.log('\n== scenario CZ: a finding against a pure-deletion hunk is not out-of-range')
  const { result } = await run({
    args: { maxReviewRounds: 1 },
    initialReview: {
      correctness: [{ title: 'Needs a fix', file: 'x.js', claim: 'c', evidence: 'e' }],
      advocate: [],
    },
    verify: (id) => id === 'f1' ? true : undefined,
    fixHead: () => 'fix00000000000000000000000000000000000001',
    hunks: () => ['+++ b/x.js', '@@ -3 +2,0 @@'],
    tailReview: [{ title: 'Guard removed here', file: 'x.js', claim: 'c2', evidence: 'e2',
      line_start: 2 }],
    staleness: () => [],
  })
  check('halted at Fix (the deletion-hunk finding is in range and blocks)', result.halted_at, 'Fix')
  check('the finding against the deletion is reported as unresolved',
    result.unresolved_findings?.some(f => f.title === 'Guard removed here'), true)
}

async function scenarioDA() {
  console.log('\n== scenario DA: an absolute, ./-prefixed, or :line-suffixed file path still matches its hunk')
  const { result } = await run({
    args: { maxReviewRounds: 1 },
    initialReview: {
      correctness: [{ title: 'Needs a fix', file: 'x.js', claim: 'c', evidence: 'e' }],
      advocate: [],
    },
    verify: (id) => id === 'f1' ? true : undefined,
    fixHead: () => 'fix00000000000000000000000000000000000001',
    hunks: () => ['+++ b/x.js', '@@ -100,5 +100,5 @@'],
    tailReview: [
      { title: 'Absolute path', file: '/tmp/stub-worktree/x.js', claim: 'c2', evidence: 'e2', line_start: 102 },
      { title: 'Dot-slash path', file: './x.js', claim: 'c3', evidence: 'e3', line_start: 102 },
      { title: 'Path with line suffix', file: 'x.js:102-104', claim: 'c4', evidence: 'e4', line_start: 102 },
    ],
    staleness: () => [],
  })
  check('halted at Fix (none of the three spellings is waved through as out-of-range)', result.halted_at, 'Fix')
  const titles = new Set((result.unresolved_findings ?? []).map(f => f.title))
  check('the absolute-path finding opened', titles.has('Absolute path'), true)
  check('the dot-slash finding opened', titles.has('Dot-slash path'), true)
  check('the :line-suffixed finding opened', titles.has('Path with line suffix'), true)
}

async function scenarioDB() {
  console.log('\n== scenario DB: cross-lens dedup keeps the blocking survivor, not just the first id')
  const { result } = await run({
    args: { maxReviewRounds: 1 },
    initialReview: {
      correctness: [{ title: 'Nil deref in Load', file: 'src/p.js',
        claim: 'derefs before the guard', evidence: 'p.js:12' }],
      advocate: [{ category: 'design', title: 'Load can panic on a missing key', file: 'src/p.js',
        claim: 'no guard before the dereference', evidence: 'p.js:12-14', reproducer: undefined }],
    },
    dedupGroups: [{ ids: ['f2', 'f1'], why: 'same dereference' }],
    staleness: () => [],
  })
  check('halted at Fix (the blocking finding survived dedup)', result.halted_at, 'Fix')
  check('the blocking correctness finding is the one that opened',
    result.unresolved_findings?.some(f => f.title === 'Nil deref in Load'), true)
  check('the non-blocking advocate finding did not absorb it into a note',
    result.notes?.every(n => n.title !== 'Nil deref in Load'), true)
}

async function scenarioDC() {
  console.log('\n== scenario DC: a fix the mutation commits undo halts at Review before the mutation review is spent')
  const { result, captured } = await run(convergedWithSuspect({
    tailReview: [],
    postMutationReview: [{ title: 'Boundary check excludes the last element', file: 'parser.js',
      claim: 'the mutation commits reverted the guard', evidence: 'parser.js:14',
      duplicate_of: 'f1', reproducer: undefined }],
    mutationResult: () => ({ green: true, head_sha: 'mut0000000000000000000000000000000000001', detail: 'stub green', scored: true }),
    settledExit: (id, round) => (id === 'f1' && round === 'mutation' ? 1 : 0),
  }))
  check('halted at Review (the mutation gate undid the fix)', result.halted_at, 'Review')
  check('the reopened finding is reported as unresolved',
    result.unresolved_findings?.some(f => f.file === 'src/parser.js'), true)
  check('the mutation review did not run: the halt was already certain',
    callCount(captured, 'review:mutation:correctness'), 0)
}

async function scenarioDD() {
  console.log('\n== scenario DD: a residual note never blocks, even with its own failing reproducer')
  const { result } = await run({
    args: { maxReviewRounds: 1 },
    draftPr: { opened: true, number: 31, url: 'https://example.invalid/pr/31', detail: 'stub draft' },
    initialReview: {
      correctness: [{ title: 'Off-by-one in parser', file: 'src/parser.js',
        claim: 'boundary is wrong', evidence: 'parser.js:12' }],
      advocate: [],
    },
    verify: (id) => id === 'f1' ? true : false,
    fixHead: () => 'fix00000000000000000000000000000000000001',
    tailReview: [{ title: 'The fix introduced a null deref', file: 'src/parser.js',
      claim: 'the added guard derefs before checking', evidence: 'parser.js:20',
      duplicate_of: 'f1' }],
    staleness: () => [],
  })
  check('the run did not halt on the residual', result.halted_at, undefined)
  check('nothing is left unresolved', (result.unresolved_findings ?? []).length, 0)
  check('the variant is recorded as a residual note',
    result.notes?.some(n => n.title === 'The fix introduced a null deref' && n.reason === 'residual'), true)
}

async function scenarioDE() {
  console.log('\n== scenario DE: a finding referencing a note is classified on its own merits, not dropped')
  const { result } = await run({
    args: { maxReviewRounds: 1 },
    initialReview: {
      correctness: [{ title: 'Needs a fix', file: 'x.js', claim: 'c', evidence: 'e' }],
      advocate: [{ category: 'docs', title: 'Stale comment', file: 'x.js',
        claim: 'comment names the wrong caller', evidence: 'x.js:3', reproducer: undefined }],
    },
    verify: (id) => id === 'f1' ? true : (id === 'f3' ? false : undefined),
    fixHead: () => 'fix00000000000000000000000000000000000001',
    tailReview: [{ title: 'Actually a live bug', file: 'x.js', claim: 'c3', evidence: 'e3',
      duplicate_of: 'f2' }],
    staleness: () => [],
  })
  check('halted at Fix (the reference to a note did not silently drop the new defect)', result.halted_at, 'Fix')
  check('the finding referencing a note still opened',
    result.unresolved_findings?.some(f => f.title === 'Actually a live bug'), true)
  check('the note it referenced is unaffected',
    result.notes?.some(n => n.title === 'Stale comment' && n.reason === 'category'), true)
}

async function scenarioDF() {
  console.log('\n== scenario DF: the known-findings prompt also asks for duplicate_of on a variant of an already-fixed defect')
  const { captured } = await run({
    args: { maxReviewRounds: 1 },
    initialReview: {
      correctness: [{ title: 'Needs a fix', file: 'x.js', claim: 'c', evidence: 'e' }],
      advocate: [],
    },
    verify: (id) => id === 'f1' ? true : undefined,
    fixHead: () => 'fix00000000000000000000000000000000000001',
    staleness: () => [],
  })
  const tailPrompt = captured.calls.find(c => c.label.startsWith('review:fix:1:'))?.prompt ?? ''
  check('the prompt also asks for a variant of an already-fixed defect',
    tailPrompt.includes('variant'), true)
}

async function scenarioDG() {
  console.log('\n== scenario DG: a failed hunk fetch is unmeasured, not read as an empty, in-range-nowhere diff')
  const { result } = await run({
    args: { maxReviewRounds: 1 },
    initialReview: {
      correctness: [{ title: 'Needs a fix', file: 'x.js', claim: 'c', evidence: 'e' }],
      advocate: [],
    },
    verify: (id) => id === 'f1' ? true : undefined,
    fixHead: () => 'fix00000000000000000000000000000000000001',
    hunks: () => undefined,
    tailReview: [{ title: 'Fresh defect', file: 'x.js', claim: 'c2', evidence: 'e2', line_start: 500 }],
    staleness: () => [],
  })
  check('halted at Fix (an unmeasured range does not classify as out-of-range)', result.halted_at, 'Fix')
  check('the fresh finding opened rather than being dismissed as out-of-range',
    result.unresolved_findings?.some(f => f.title === 'Fresh defect'), true)
}

// Scenario DH -- a verbatim quote proves the criterion exists, not that the
// change misses it. Blocking rests on something executed, so without a
// reproducer the finding is a note, and no model is ever asked to judge the
// criterion met in place of an exit code.
async function scenarioDH() {
  console.log('\n== scenario DH: an unmet-criterion finding with a verbatim quote but no reproducer is a note, not a halt')
  const { result, captured } = await run({
    ticketResult: { found: true, summary: 'stub', comments: '',
      description: 'Acceptance: the client must retry on a 503 with backoff.' },
    initialReview: {
      correctness: [
        { category: 'unmet-criterion', title: 'Missing retry path', file: 'a.js',
          claim: 'the retry path was never implemented', evidence: 'a.js:1',
          criterion_quote: 'the client must retry on a 503 with backoff',
          reproducer: undefined },
      ],
      advocate: [],
    },
  })
  check('the run did not halt', result.halted_at, undefined)
  check('it is a note for lack of a reproducer',
    result.notes?.some(n => n.title === 'Missing retry path' && n.reason === 'no-reproducer'), true)
  check('no agent was asked to judge whether a criterion is met',
    captured.calls.some(c => /decide whether it is met/i.test(c.prompt ?? '')), false)
}


// Scenario DJ -- gh-106: the mutation-hunk fetch runs zero reproducers
// (`executeAtHead([], ...)`), so dirt found there can never be a reproducer's
// fault; the halt used to say "a reproducer execution" regardless.
async function scenarioDJ() {
  console.log('\n== scenario DJ: dirt found by the zero-reproducer mutation-hunk fetch is not blamed on a reproducer')
  const { result } = await run({
    initialReview: {
      correctness: [{ category: 'docs', title: 'Stale doc', file: 'a.js', claim: 'c', evidence: 'e' }],
      advocate: [],
    },
    mutationGated: true,
    mutationResult: () => ({ green: true, head_sha: 'mut0000000000000000000000000000000000001',
      detail: 'stub green', scored: true }),
    reproducerDirty: true,
    reproducerPorcelain: '?? stray-mutation-file.txt',
  })
  check('halted at Review', result.halted_at, 'Review')
  check('the note does not blame a reproducer for dirt nothing here ran',
    (result.note ?? '').includes('reproducer execution'), false)
  check('the note still names the porcelain output',
    (result.note ?? '').includes('stray-mutation-file.txt'), true)
}

// Scenario DK -- a fix that a later round breaks is reopened inside the loop,
// so it gets the next round like any other open finding instead of halting
// the run right past the loop.
async function scenarioDK() {
  console.log('\n== scenario DK: a fix a later round breaks still gets a fix round when rounds remain')
  const { result } = await run({
    args: { maxReviewRounds: 3 },
    initialReview: {
      correctness: [
        { title: 'Off-by-one in parser', file: 'src/parser.js', claim: 'boundary is wrong', evidence: 'parser.js:12' },
        { title: 'Missing guard', file: 'src/guard.js', claim: 'no guard', evidence: 'guard.js:3' },
      ],
      advocate: [],
    },
    verify: (id, round) => id === 'f1' ? (round === 1 || round === 3) : (id === 'f2' ? round === 2 : undefined),
    settledExit: (id, round) => (id === 'f1' && round === 2 ? 1 : 0),
    fixHead: (round) => `fix0000000000000000000000000000000000000${round}`,
    tailReview: [],
    staleness: () => [],
  })
  check('the run finished rather than halting', result.halted_at, undefined)
  check('a third round settled the reopened fix', result.fix_rounds, 3)
}

const SCENARIOS = [scenarioCL, scenarioCM, scenarioCN, scenarioCO, scenarioCG, scenarioCH, scenarioCI, scenarioCP, scenarioCQ, scenarioCR, scenarioCS, scenarioCT, scenarioCU, scenarioCV, scenarioCW, scenarioCX, scenarioCY, scenarioCZ, scenarioDA, scenarioDB, scenarioDC, scenarioDD, scenarioDE, scenarioDF, scenarioDG, scenarioDH, scenarioDJ, scenarioDK]
JS_EOF

finish
