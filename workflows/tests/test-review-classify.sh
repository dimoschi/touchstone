#!/usr/bin/env bash
# Scenarios scenarioA..scenarioAC, split out of
# test-fix-loop-join.sh (gh-118); see harness.sh.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/harness.sh"

run_js_scenarios <<'JS_EOF'
// Scenario A -- the regression this ticket is about: a verifier that rewords
// every title still clears every finding, because the join reads id.
async function scenarioA() {
  console.log('\n== scenario A: reworded titles still clear via id')
  const { result } = await run({
    initialReview: {
      correctness: [{ title: 'Off-by-one in parser', file: 'src/parser.js',
        claim: 'boundary is wrong', evidence: 'parser.js:12' }],
      advocate: [],
    },
    verify: (id) => id === 'f1' ? true : undefined,
  })
  check('halted_at is absent (the run finished)', result.halted_at, undefined)
  check('unresolved_findings is empty', result.unresolved_findings, [])
  check('the loop took exactly 1 round', result.fix_rounds, 1)
}

// Scenario B -- two findings from different lenses share a title. Before this
// fix a title-keyed join would treat one verdict as clearing both.
async function scenarioB() {
  console.log('\n== scenario B: identical titles still get distinct ids')
  const { result, captured } = await run({
    args: { maxReviewRounds: 1 },
    initialReview: {
      correctness: [{ title: 'Dup Finding', file: 'fileA.js', claim: 'c1', evidence: 'e1' }],
      advocate: [{ title: 'Dup Finding', file: 'fileB.js', claim: 'c2', evidence: 'e2' }],
    },
    verify: (id) => id === 'f1' ? true : (id === 'f2' ? false : undefined),
    staleness: () => [],
  })
  const reproducePrompt = captured.calls.find(c => c.label === 'reproduce:fix:1')?.prompt ?? ''
  check('the reproducer step ran both f1 and f2 for the identical title',
    idsIn(reproducePrompt).sort(), ['f1', 'f2'])
  check('halted at Fix', result.halted_at, 'Fix')
  check('only the unresolved finding remains open', result.unresolved_findings.length, 1)
  check('the surviving finding is the advocate\'s, not the correctness one',
    result.unresolved_findings[0].file, 'fileB.js')
}

// Scenario G -- a verdict for an id that names no open finding is discarded,
// and a finding with no verdict at all stays open.
async function scenarioG() {
  console.log('\n== scenario G: an unmatched verdict id is discarded, silence stays open')
  const { result } = await run({
    args: { maxReviewRounds: 1 },
    initialReview: {
      correctness: [{ title: 'Lonely Finding', file: 'only.js', claim: 'c', evidence: 'e' }],
      advocate: [],
    },
    verify: () => undefined, // no verdict at all for the real finding
    injectBogusVerdict: true, // a verdict for an id that names nothing open
    staleness: () => [],
  })
  check('halted at Fix', result.halted_at, 'Fix')
  check('the unverified finding stayed open', result.unresolved_findings.length, 1)
  check('it is still the same finding', result.unresolved_findings[0].file, 'only.js')
}

// Scenario C -- the staleness probe marks a surviving finding whose file has
// moved on, and the halt note says how many.
async function scenarioC() {
  console.log('\n== scenario C: staleness marks a finding whose code has moved on')
  const { result, captured } = await run({
    args: { maxReviewRounds: 1 },
    draftPr: { opened: true, url: 'https://example.test/pr/1', number: 1, detail: 'stub' },
    initialReview: {
      correctness: [{ title: 'Dup Finding', file: 'fileA.js', claim: 'c1', evidence: 'e1' }],
      advocate: [{ title: 'Dup Finding', file: 'fileB.js', claim: 'c2', evidence: 'e2' }],
    },
    verify: (id) => id === 'f1' ? true : (id === 'f2' ? false : undefined),
    staleness: (ids) => ids.map(id => ({ id, changed: true })),
  })
  check('staleness ran exactly once, not once per finding', callCount(captured, 'staleness'), 1)
  check('halted at Fix', result.halted_at, 'Fix')
  check('the surviving finding is still reported', result.unresolved_findings.length, 1)
  check('it is marked as changed since it was recorded',
    result.unresolved_findings[0].code_changed_since_recorded, true)
  check('the halt note says one finding needs a re-check',
    /1 of them have code that changed/.test(result.note), true)
  check('no halt comment is posted to the PR',
    callCount(captured, 'halt-notice:Fix'), 0)
}

// Scenario D -- the probe itself returns nothing (a dead subagent). The halt
// must still fire, flat, with no exception.
async function scenarioD() {
  console.log('\n== scenario D: a null staleness result still produces a flat halt')
  const { result } = await run({
    args: { maxReviewRounds: 1 },
    initialReview: {
      correctness: [{ title: 'Dup Finding', file: 'fileA.js', claim: 'c1', evidence: 'e1' }],
      advocate: [{ title: 'Dup Finding', file: 'fileB.js', claim: 'c2', evidence: 'e2' }],
    },
    verify: (id) => id === 'f1' ? true : (id === 'f2' ? false : undefined),
    staleness: null,
  })
  check('halted at Fix, no exception', result.halted_at, 'Fix')
  check('the surviving finding is reported unmarked',
    result.unresolved_findings[0].code_changed_since_recorded, undefined)
  check('the note carries no re-check count', /changed since they were recorded/.test(result.note), false)
}

// Scenario E -- the probe returns a malformed shape (results not an array).
// Same contract as a null result: no crash, nothing marked.
async function scenarioE() {
  console.log('\n== scenario E: a malformed staleness result still produces a flat halt')
  const { result } = await run({
    args: { maxReviewRounds: 1 },
    initialReview: {
      correctness: [{ title: 'Dup Finding', file: 'fileA.js', claim: 'c1', evidence: 'e1' }],
      advocate: [{ title: 'Dup Finding', file: 'fileB.js', claim: 'c2', evidence: 'e2' }],
    },
    verify: (id) => id === 'f1' ? true : (id === 'f2' ? false : undefined),
    staleness: 'malformed',
  })
  check('halted at Fix, no exception', result.halted_at, 'Fix')
  check('the surviving finding is reported unmarked',
    result.unresolved_findings[0].code_changed_since_recorded, undefined)
}

// Scenario H -- the post-mutation Review halt renders exactly as it did
// before this change: its findings pass through the same reviewOf as
// everything else and now carry an id and recorded_at, but never
// code_changed_since_recorded, so the comment must carry no marker.
async function scenarioH() {
  console.log('\n== scenario H: the post-mutation Review halt is unmarked, byte for byte')
  const mutHead = 'mut0000000000000000000000000000000000001'
  const { result, captured } = await run({
    draftPr: { opened: true, url: 'https://example.test/pr/2', number: 2, detail: 'stub' },
    initialReview: { correctness: [], advocate: [] }, // no Fix-loop findings at all
    verify: () => undefined,
    mutationGated: true,
    mutationResult: () => ({ green: true, head_sha: mutHead, detail: 'stub green', scored: true }),
    postMutationReview: [{ title: 'Mutation gate introduced X', file: 'mutfile.js',
      claim: 'c', evidence: 'e' }],
  })
  check('halted at Review (the mutation gate\'s own commits)', result.halted_at, 'Review')
  check('exactly the one post-mutation finding is reported', result.unresolved_findings.length, 1)
  check('the finding carries no stale marker',
    result.unresolved_findings[0].code_changed_since_recorded, undefined)
  check('no halt comment is posted to the PR',
    callCount(captured, 'halt-notice:Review'), 0)
  // This halt is strictly downstream of the Mutation halt, so the draft PR
  // always exists by here, and halted() posts this note as a comment on it.
  check('the note does not claim no PR was opened',
    /[Nn]o PR was opened/.test(result.note ?? ''), false)
  check('the note says the PR was left as a draft',
    /left as a draft/.test(result.note ?? ''), true)
  // The last halt that reported no gate result, and the one where it is most
  // complete: mutation green, everything through the fix loop scored.
  check('the gate result reaches the halt payload', result.gates?.measured ?? null, 'scored')
}

// Scenario I -- a verifier that copies the id exactly as the prompt renders
// it, brackets included, must still clear the finding. This is the same
// permanent-halt failure the ticket fixes, just triggered by a bracket
// instead of a reworded title.
async function scenarioI() {
  console.log('\n== scenario I: a bracketed verdict id ([f1]) still clears the finding')
  const { result } = await run({
    initialReview: {
      correctness: [{ title: 'Off-by-one in parser', file: 'src/parser.js',
        claim: 'boundary is wrong', evidence: 'parser.js:12' }],
      advocate: [],
    },
    verify: (id) => id === 'f1' ? true : undefined,
    verifyBracketed: true,
  })
  check('halted_at is absent (the run finished)', result.halted_at, undefined)
  check('unresolved_findings is empty', result.unresolved_findings, [])
}

// Scenario J -- same bracket near-miss, on the staleness probe's join.
async function scenarioJ() {
  console.log('\n== scenario J: a bracketed staleness id ([f2]) still marks the finding')
  const { result } = await run({
    args: { maxReviewRounds: 1 },
    initialReview: {
      correctness: [{ title: 'Dup Finding', file: 'fileA.js', claim: 'c1', evidence: 'e1' }],
      advocate: [{ title: 'Dup Finding', file: 'fileB.js', claim: 'c2', evidence: 'e2' }],
    },
    verify: (id) => id === 'f1' ? true : (id === 'f2' ? false : undefined),
    staleness: (ids) => ids.map(id => ({ id, changed: true })),
    stalenessBracketed: true,
  })
  check('the surviving finding is marked as changed despite the bracketed id',
    result.unresolved_findings[0].code_changed_since_recorded, true)
}

// Scenario K -- a tail-review finding that happens to share a title with a
// finding the same round just settled must not be dropped for it: the two
// are unrelated, and only their model-generated title collides.
async function scenarioK() {
  console.log('\n== scenario K: a tail-review finding is not dropped for sharing a title with a settled one')
  const { result } = await run({
    args: { maxReviewRounds: 1 },
    initialReview: {
      correctness: [{ title: 'Same Title', file: 'orig.js', claim: 'c1', evidence: 'e1' }],
      advocate: [],
    },
    verify: (id) => id === 'f1' ? true : undefined,
    fixHead: () => 'fix00000000000000000000000000000000000001',
    tailReview: [{ title: 'Same Title', file: 'new.js', claim: 'c2', evidence: 'e2' }],
    staleness: () => [],
  })
  check('halted at Fix', result.halted_at, 'Fix')
  check('exactly the fresh finding survives', result.unresolved_findings.length, 1)
  check('it is the fresh finding, not the one already settled',
    result.unresolved_findings[0]?.file, 'new.js')
}

// Scenario L -- same collision, one stage later: a post-mutation finding
// sharing a title with a finding the fix loop already settled must still
// reach the halt.
async function scenarioL() {
  console.log('\n== scenario L: a post-mutation finding is not dropped for sharing a title with a settled one')
  const { result } = await run({
    initialReview: {
      correctness: [{ title: 'Repeated Title', file: 'orig.js', claim: 'c-orig', evidence: 'e-orig' }],
      advocate: [],
    },
    verify: (id) => id === 'f1' ? true : undefined,
    staleness: () => [],
    mutationGated: true,
    mutationResult: () => ({ green: true, head_sha: 'mut0000000000000000000000000000000000001', detail: 'stub green', scored: true }),
    postMutationReview: [{ title: 'Repeated Title', file: 'mutfile.js',
      claim: 'a different bug', evidence: 'e2' }],
  })
  check('halted at Review', result.halted_at, 'Review')
  check('exactly the post-mutation finding survives', result.unresolved_findings.length, 1)
  check('it is the post-mutation finding, not the one already settled',
    result.unresolved_findings[0]?.file, 'mutfile.js')
}

// Scenario M -- budget is already exhausted, so the fix loop runs zero
// rounds. The staleness probe must not fire: nothing could have changed,
// same guard as every other optional dispatch here.
async function scenarioM() {
  console.log('\n== scenario M: the staleness probe is skipped once the run is out of budget')
  const { result, captured } = await run({
    budget: { total: 200000, spent: () => 190000, remaining: () => 5000 },
    initialReview: {
      correctness: [{ title: 'Needs budget', file: 'fileA.js', claim: 'c', evidence: 'e' }],
      advocate: [],
    },
    verify: () => undefined,
  })
  check('staleness never ran', callCount(captured, 'staleness'), 0)
  check('halted at Fix', result.halted_at, 'Fix')
  check('the loop ran zero rounds', result.fix_rounds, 0)
  check('the surviving finding is reported unmarked',
    result.unresolved_findings[0]?.code_changed_since_recorded, undefined)
  check('the note blames the overall token budget',
    /passed its overall token budget/.test(result.note), true)
}

// Scenario N -- the staleness probe itself rejects (a dead subagent, not
// merely an empty answer). The halt must still return, not throw.
async function scenarioN() {
  console.log('\n== scenario N: a rejected staleness probe does not take the halt down with it')
  const { result } = await run({
    args: { maxReviewRounds: 1 },
    initialReview: {
      correctness: [{ title: 'Dup Finding', file: 'fileA.js', claim: 'c1', evidence: 'e1' }],
      advocate: [{ title: 'Dup Finding', file: 'fileB.js', claim: 'c2', evidence: 'e2' }],
    },
    verify: (id) => id === 'f1' ? true : (id === 'f2' ? false : undefined),
    staleness: 'reject',
  })
  check('halted at Fix, no exception', result.halted_at, 'Fix')
  check('the surviving finding is reported unmarked',
    result.unresolved_findings[0]?.code_changed_since_recorded, undefined)
}

// Scenario O -- an identical re-report: the tail review re-detects the exact
// same finding (same title, file, claim, evidence) that a verifier just
// confirmed fixed. Unlike K, nothing here differs -- this is the case the
// settled guard exists for, and keying it on id (which is always freshly
// minted) can never catch it.
async function scenarioO() {
  console.log('\n== scenario O: an identical re-report of a settled finding is not reopened')
  const { result } = await run({
    initialReview: {
      correctness: [{ title: 'Off-by-one in parser', file: 'src/parser.js',
        claim: 'boundary is wrong', evidence: 'parser.js:12' }],
      advocate: [],
    },
    verify: (id) => id === 'f1' ? true : undefined,
    fixHead: () => 'fix00000000000000000000000000000000000001',
    tailReview: [{ title: 'Off-by-one in parser', file: 'src/parser.js',
      claim: 'boundary is wrong', evidence: 'parser.js:12' }],
    staleness: () => [],
  })
  check('halted_at is absent (the run finished, the re-report was suppressed)',
    result.halted_at, undefined)
  check('unresolved_findings is empty', result.unresolved_findings, [])
}

// Scenario P -- same identical re-report, one stage later: the post-mutation
// review re-detects a finding the fix loop already settled. It must not
// reach the halt.
async function scenarioP() {
  console.log('\n== scenario P: an identical re-report at the post-mutation stage is not reopened')
  const { result } = await run({
    initialReview: {
      correctness: [{ title: 'Off-by-one in parser', file: 'src/parser.js',
        claim: 'boundary is wrong', evidence: 'parser.js:12' }],
      advocate: [],
    },
    verify: (id) => id === 'f1' ? true : undefined,
    staleness: () => [],
    mutationGated: true,
    mutationResult: () => ({ green: true, head_sha: 'mut0000000000000000000000000000000000001', detail: 'stub green', scored: true }),
    postMutationReview: [{ title: 'Off-by-one in parser', file: 'src/parser.js',
      claim: 'boundary is wrong', evidence: 'parser.js:12' }],
  })
  check('halted_at is absent (the run finished, the re-report was suppressed)',
    result.halted_at, undefined)
}

// Scenario Q -- the staleness probe must run even when the loop stopped on
// budget only after a round already ran and committed, not merely when the
// loop never got to run at all. Round 0 (scenario M) is the only state where
// skipping it is safe.
async function scenarioQ() {
  console.log('\n== scenario Q: the staleness probe still runs when budget ran out after a round already committed')
  let roundsRan = 0
  const { result, captured } = await run({
    budget: { total: 200000, spent: () => 0, remaining: () => (roundsRan > 0 ? 100 : 999999) },
    args: { maxReviewRounds: 3 },
    initialReview: {
      correctness: [{ title: 'Needs more rounds', file: 'fileA.js', claim: 'c', evidence: 'e' }],
      advocate: [],
    },
    verify: (id, round) => { roundsRan = round; return undefined },
    staleness: (ids) => ids.map(id => ({ id, changed: true })),
  })
  check('staleness ran despite the loop stopping on budget after a round',
    callCount(captured, 'staleness'), 1)
  check('halted at Fix', result.halted_at, 'Fix')
  check('the loop ran exactly 1 round before budget stopped it', result.fix_rounds, 1)
  check('the surviving finding is marked as changed since it was recorded',
    result.unresolved_findings[0]?.code_changed_since_recorded, true)
}

// Scenario R -- a reworded re-report of a settled finding. Unlike O (a
// byte-identical re-report), every field here differs from the original: only
// duplicate_of, copied from the known-findings list the tail-review lens was
// handed, ties it back. A join that still relies on title/file/claim/evidence
// matching (exactly the failure ticket 21 fixed for verdicts) cannot catch
// this; the run must finish rather than reopen already-fixed code.
async function scenarioR() {
  console.log('\n== scenario R: a reworded re-report of a settled finding is not reopened')
  const { result, captured } = await run({
    initialReview: {
      correctness: [{ title: 'Off-by-one in parser', file: 'src/parser.js',
        claim: 'boundary is wrong', evidence: 'parser.js:12' }],
      advocate: [],
    },
    // f2 is the suspect: this scenario's re-report is genuine noise, so the
    // verifier confirms it does not reproduce.
    verify: (id) => (id === 'f1' || id === 'f2') ? true : undefined,
    fixHead: () => 'fix00000000000000000000000000000000000001',
    tailReview: [{ title: 'Boundary check excludes the last element', file: 'parser.js',
      claim: 'off-by-one at the array end', evidence: 'see loop condition',
      duplicate_of: 'f1' }],
    staleness: () => [],
  })
  const tailPrompt = captured.calls.find(c => c.label.startsWith('review:fix:1:'))?.prompt ?? ''
  check('the tail-review lens was handed the settled finding\'s id',
    tailPrompt.includes('[f1]'), true)
  check('halted_at is absent (the run finished, the reworded re-report was recognized)',
    result.halted_at, undefined)
  check('unresolved_findings is empty', result.unresolved_findings, [])
  check('the re-report is recorded as a residual note, not dropped in silence',
    result.notes?.filter(n => n.reason === 'residual').length, 1)
  check('the note names the settled finding it was pointed at',
    result.notes?.find(n => n.reason === 'residual')?.residual_of, 'f1')
}

// Scenario S -- a finding that stays open gets re-reported each round with
// drifting wording. Before this fix, full-content equality no longer matched
// the copy already in `open`, so each round appended another entry for the
// same bug. duplicate_of, referencing the still-open finding's id, must keep
// it to exactly one entry across both rounds.
async function scenarioS() {
  console.log('\n== scenario S: a reworded re-report of a still-open finding does not inflate open into two entries')
  const { result, captured } = await run({
    args: { maxReviewRounds: 2 },
    initialReview: {
      correctness: [{ title: 'Foo bug', file: 'f.js', claim: 'c1', evidence: 'e1' }],
      advocate: [],
    },
    // Anything that is not f1 is the round-2 suspect, which this scenario
    // means as the same bug, now fixed; the residual recheck asks about f1
    // again at the final head, so f1 has to stay fixed there too, not just
    // at round 2.
    verify: (id, round) => id === 'f1' ? (round === 1 ? false : true) : true,
    fixHead: (round) => `fix0000000000000000000000000000000000000${round}`,
    tailReview: [{ title: 'Different wording of foo bug', file: 'f.js',
      claim: 'reworded claim', evidence: 'reworded evidence', duplicate_of: 'f1' }],
    staleness: () => [],
  })
  const reproduce2Prompt = captured.calls.find(c => c.label === 'reproduce:fix:2')?.prompt ?? ''
  check('round 2 checks exactly one finding, not two',
    idsIn(reproduce2Prompt).length, 1)
  check('halted_at is absent (the run finished, both rounds resolved the one bug)',
    result.halted_at, undefined)
}

// Scenario T -- the mirror of P, one word different in kind: the post-mutation
// lens does not restate a settled finding, it *references* it against the
// mutation gate's own commits. Under classify()'s uniform dedup rule that is
// a residual note, not a halt: a reference alone, with no reproducer of its
// own confirmed failing, is exactly the noise this ticket stops blocking on.
async function scenarioT() {
  console.log('\n== scenario T: a referenced re-report at the post-mutation stage becomes a residual note, not a halt')
  const { result, captured } = await run({
    initialReview: {
      correctness: [{ title: 'Off-by-one in parser', file: 'src/parser.js',
        claim: 'boundary is wrong', evidence: 'parser.js:12' }],
      advocate: [],
    },
    verify: (id) => id === 'f1' ? true : undefined,
    staleness: () => [],
    mutationGated: true,
    mutationResult: () => ({ green: true, head_sha: 'mut0000000000000000000000000000000000001', detail: 'stub green', scored: true }),
    // No reproducer of its own: this scenario is about the reference alone
    // becoming a residual note, not about gh-106's separate check of a
    // residual's own claim (scenario DD), which needs one.
    postMutationReview: [{ title: 'Boundary check excludes the last element', file: 'parser.js',
      claim: 'the mutation commits reverted the guard', evidence: 'parser.js:14',
      duplicate_of: 'f1', reproducer: undefined }],
  })
  check('halted_at is absent (a reference at post-mutation is a residual note, not a halt)',
    result.halted_at, undefined)
  check('the residual note references the settled finding',
    result.notes?.some(n => n.reason === 'residual' && n.residual_of === 'f1'), true)
  const lensPrompt = captured.calls.find(c => c.label.startsWith('review:mutation:'))?.prompt ?? ''
  check('the lens is told settled fixes were already re-run, not to report them again',
    lensPrompt.includes('already been re-run at their head'), true)
  check('the lens is told a defect outside this range is not a finding here',
    lensPrompt.includes('commits do not touch is not a finding'), true)
}

// Scenario U -- a re-report that is byte-identical AND sets duplicate_of. It
// is a restatement: matching all four fields means the text was copied from
// the known list. Testing the reference before the content would promote it to
// a fresh claim, which costs a spurious suspect here and a halt at the gate.
async function scenarioU() {
  console.log('\n== scenario U: an identical re-report that also sets duplicate_of stays a restatement')
  const { result } = await run({
    initialReview: {
      correctness: [{ title: 'Off-by-one in parser', file: 'src/parser.js',
        claim: 'boundary is wrong', evidence: 'parser.js:12' }],
      advocate: [],
    },
    // f2 is the suspect: this scenario's re-report is genuine noise, so the
    // verifier confirms it does not reproduce.
    verify: (id) => (id === 'f1' || id === 'f2') ? true : undefined,
    fixHead: () => 'fix00000000000000000000000000000000000001',
    tailReview: [{ title: 'Off-by-one in parser', file: 'src/parser.js',
      claim: 'boundary is wrong', evidence: 'parser.js:12', duplicate_of: 'f1' }],
    staleness: () => [],
  })
  check('halted_at is absent (the run finished)', result.halted_at, undefined)
  check('unresolved_findings is empty', result.unresolved_findings, [])
  check('it is dropped as a restatement, not recorded as a note',
    result.notes?.length ?? 0, 0)
}

// Scenario V -- the halt payload carries the residual note as well as the
// finding that is genuinely still open, so a human reading the halt sees
// both: what has to be fixed, and what is just a re-report to sanity-check.
async function scenarioV() {
  console.log('\n== scenario V: the halt payload carries the residual note alongside the still-open finding')
  const { result, captured } = await run({
    args: { maxReviewRounds: 1 },
    draftPr: { opened: true, number: 23, url: 'https://example.invalid/pr/23', detail: 'stub draft' },
    initialReview: {
      correctness: [
        { title: 'Off-by-one in parser', file: 'src/parser.js',
          claim: 'boundary is wrong', evidence: 'parser.js:12' },
        { title: 'Unrelated leak', file: 'src/pool.js',
          claim: 'connection is never released', evidence: 'pool.js:40' },
      ],
      advocate: [],
    },
    // The leak (f2) is never confirmed fixed and must stay open.
    verify: (id) => id === 'f1' ? true : undefined,
    fixHead: () => 'fix00000000000000000000000000000000000001',
    tailReview: [{ title: 'Boundary check excludes the last element', file: 'parser.js',
      claim: 'off-by-one at the array end', evidence: 'see loop condition',
      duplicate_of: 'f1', reproducer: undefined }],
    staleness: () => [],
  })
  check('halted at Fix (the leak was never fixed)', result.halted_at, 'Fix')
  check('the still-open finding is the leak, not the settled parser bug',
    result.unresolved_findings?.[0]?.file, 'src/pool.js')
  check('a residual note was recorded', result.notes?.filter(n => n.reason === 'residual').length, 1)
  check('it references the settled parser finding',
    result.notes?.find(n => n.reason === 'residual')?.residual_of, 'f1')
  check('no halt comment is posted to the PR',
    callCount(captured, 'halt-notice:Fix'), 0)
}

// Scenario W -- a green run that recorded a residual note. The findings all
// cleared, so nothing halts and the PR goes ready; the note reaches the PR
// body itself, not a separate comment nobody reads.
async function scenarioW() {
  console.log('\n== scenario W: a green run reports its residual note in the PR body')
  const { result, captured } = await run({
    args: { openPr: true },
    draftPr: { opened: true, number: 23, url: 'https://example.invalid/pr/23', detail: 'stub draft' },
    prResult: { opened: true, url: 'https://example.invalid/pr/23', note: 'stub ready' },
    initialReview: {
      correctness: [{ title: 'Off-by-one in parser', file: 'src/parser.js',
        claim: 'boundary is wrong', evidence: 'parser.js:12' }],
      advocate: [],
    },
    verify: (id) => id === 'f1' ? true : undefined,
    fixHead: () => 'fix00000000000000000000000000000000000001',
    tailReview: [{ title: 'Boundary check excludes the last element', file: 'parser.js',
      claim: 'off-by-one at the array end', evidence: 'see loop condition',
      duplicate_of: 'f1', reproducer: undefined }],
    staleness: () => [],
  })
  check('halted_at is absent (every finding cleared)', result.halted_at, undefined)
  check('the residual note is in the result', result.notes?.filter(n => n.reason === 'residual').length, 1)
  check('no separate comment is posted for it',
    callCount(captured, 'regression-notice'), 0)
  const prPrompt = captured.calls.find(c => c.label === 'pr')?.prompt ?? ''
  check('the PR prompt carries the note\'s title and claim',
    prPrompt.includes('Boundary check excludes the last element') &&
    prPrompt.includes('off-by-one at the array end'), true)
}

async function scenarioX() {
  console.log('\n== scenario X: the Mutation halt carries the residual note')
  const { result, captured } = await run(convergedWithSuspect({
    mutationResult: () => ({ green: false, head_sha: 'mut0000000000000000000000000000000000001',
      detail: 'stub red', survivors: 1, scored: true }),
  }))
  check('halted at Mutation', result.halted_at, 'Mutation')
  check('the residual note is in the payload', result.notes?.filter(n => n.reason === 'residual').length, 1)
  check('no halt comment is posted to the PR',
    callCount(captured, 'halt-notice:Mutation'), 0)
  // A mutation agent that omits scored is indistinguishable from one that
  // scored nothing, which is exactly how a scoring commit can still report
  // "nothing scorable": the schema handed to the agent must force the field.
  const mutationCall = captured.calls.find((c) => c.label === 'mutation:1')
  check('the mutation schema requires scored',
    mutationCall?.schema?.required?.includes('scored'), true)
  // The fourth phase the scratch rule has to reach, and the only one no
  // other scenario gets far enough to see.
  check('the mutation phase is told where scratch work goes',
    (mutationCall?.prompt ?? '').includes('touchstone-scratch'), true)
}

async function scenarioY() {
  console.log('\n== scenario Y: the post-mutation Review halt carries the residual note plus the fresh finding')
  const { result, captured } = await run(convergedWithSuspect({
    mutationResult: () => ({ green: true, head_sha: 'mut0000000000000000000000000000000000001', detail: 'stub green', scored: true }),
    postMutationReview: [{ title: 'New nil deref in the added test helper',
      file: 'src/helper.js', claim: 'deref before the guard', evidence: 'helper.js:8' }],
  }))
  check('halted at Review', result.halted_at, 'Review')
  check('the residual note is in the payload', result.notes?.filter(n => n.reason === 'residual').length, 1)
  check('no halt comment is posted to the PR',
    callCount(captured, 'halt-notice:Review'), 0)
  check('the genuinely new finding is still reported',
    result.unresolved_findings?.length, 1)
}

// Scenario Z -- the halt exits must write the record, since a halt is the case
// that most needs one, and it must be keyed and located so a later session can
// find it: by ticket, under the main checkout, not the worktree that goes away.
async function scenarioZ() {
  console.log('\n== scenario Z: a halt writes the run record into the repo')
  const { result, captured } = await run({
    args: { maxReviewRounds: 1 },
    initialReview: {
      correctness: [{ title: 'Unrelated leak', file: 'src/pool.js',
        claim: 'connection is never released', evidence: 'pool.js:40' }],
      advocate: [],
    },
    verify: () => false,
    fixHead: () => 'fix00000000000000000000000000000000000001',
    staleness: () => [],
  })
  const p = captured.runRecordPrompt ?? ''
  check('halted at Fix', result.halted_at, 'Fix')
  check('the record was written once', callCount(captured, 'run-record'), 1)
  check('its path is reported back in the payload',
    result.record_path, '/stub/main/.claude/touchstone-runs/21.json')
  check('it is keyed by ticket', p.includes('touchstone-runs/21.json'), true)
  check('it is written to the main checkout, not the worktree',
    p.includes('--git-common-dir'), true)
  check('the record carries the unresolved finding',
    p.includes('connection is never released'), true)
  check('the record carries the halt phase', p.includes('"halted_at": "Fix"'), true)
}

// Scenario AA -- the green path writes it too. A run that opened a PR is the
// one a later session is most likely to come back to.
async function scenarioAA() {
  console.log('\n== scenario AA: a green run writes the run record')
  const { result, captured } = await run({
    args: { openPr: true },
    prResult: { opened: true, url: 'https://example.invalid/pr/23', note: 'stub ready' },
    initialReview: { correctness: [], advocate: [] },
    verify: () => undefined,
    staleness: () => [],
  })
  check('halted_at is absent', result.halted_at, undefined)
  check('the record was written once', callCount(captured, 'run-record'), 1)
  check('the record carries the PR url',
    (captured.runRecordPrompt ?? '').includes('https://example.invalid/pr/23'), true)
}

// Scenario AB -- the write is best-effort. A dead record agent must not take
// down a run whose work is already committed.
async function scenarioAB() {
  console.log('\n== scenario AB: a failed record write does not take the run down')
  const { result } = await run({
    args: { openPr: true },
    runRecordFails: true,
    prResult: { opened: true, url: 'https://example.invalid/pr/23', note: 'stub ready' },
    initialReview: { correctness: [], advocate: [] },
    verify: () => undefined,
    staleness: () => [],
  })
  check('the run still returns its result', result.pr?.opened, true)
  check('record_path is null rather than missing', result.record_path, null)
}

// Scenario AC -- ceilings follow the same judgement as effort. A trivial change
// used to get trivial effort and the full 80k review ceiling.
async function scenarioAC() {
  console.log('\n== scenario AC: a trivial triage scales the ceilings down')
  const { captured } = await run({
    triage: { complexity: 'trivial' },
    initialReview: { correctness: [], advocate: [] },
    verify: () => undefined,
    staleness: () => [],
  })
  const logs = captured.logs.join('\n')
  check('the scale is reported with the effort', logs.includes('ceilings x0.4'), true)
  check('the review ceiling scales 80k -> 32k', logs.includes('(ceiling 32k)'), true)
  check('the fix ceiling scales 170k -> 68k', logs.includes('(ceiling 68k)'), true)
}

const SCENARIOS = [scenarioA, scenarioB, scenarioG, scenarioC, scenarioD, scenarioE, scenarioH, scenarioI, scenarioJ, scenarioK, scenarioL, scenarioM, scenarioN, scenarioO, scenarioP, scenarioQ, scenarioR, scenarioS, scenarioT, scenarioU, scenarioV, scenarioW, scenarioX, scenarioY, scenarioZ, scenarioAA, scenarioAB, scenarioAC]
JS_EOF

finish
