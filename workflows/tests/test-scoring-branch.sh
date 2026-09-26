#!/usr/bin/env bash
# Scenarios scenarioAD..scenarioBG, split out of
# test-fix-loop-join.sh (gh-118); see harness.sh.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/harness.sh"

run_js_scenarios <<'JS_EOF'
// Scenario AD -- an explicit budget is a decision, so scaling must not overrule
// it. The unlisted stages still scale.
async function scenarioAD() {
  console.log('\n== scenario AD: an explicit stage budget is not scaled')
  const { captured } = await run({
    triage: { complexity: 'trivial' },
    args: { stageBudgets: { fix: 170000 } },
    initialReview: { correctness: [], advocate: [] },
    verify: () => undefined,
    staleness: () => [],
  })
  const logs = captured.logs.join('\n')
  check('the fix ceiling keeps the value passed in', logs.includes('(ceiling 170k)'), true)
  check('it is named as exempt', logs.includes('fix left at the value you passed'), true)
  check('review still scales', logs.includes('(ceiling 32k)'), true)
}

// Scenario AE -- read wide, report narrow. The charge authorises reading past
// the range, and one run then reported a defect in a file the branch never
// touched, which cost a fix round.
async function scenarioAE() {
  console.log('\n== scenario AE: the lens is told to report only what these commits caused')
  const { captured } = await run({
    initialReview: { correctness: [], advocate: [] },
    verify: () => undefined,
    staleness: () => [],
  })
  const p = captured.calls.find(c => c.label === 'review:correctness')?.prompt ?? ''
  check('it may still read the surrounding code', p.includes('surrounding code as well'), true)
  check('it is told to report narrow', p.includes('Read wide, report narrow'), true)
  check('a pre-existing defect in untouched code is out of scope',
    p.includes('already there in code this range does not touch'), true)
}

async function scenarioAF() {
  console.log('\n== scenario AF: a fresh finding from the last round that does not reproduce does not halt the run')
  const { result, captured } = await run(lateFinding(true))
  check('the fresh finding was executed in the same round', callCount(captured, 'reproduce:fix:1:fresh'), 1)
  check('halted_at is absent', result.halted_at, undefined)
  check('nothing is left open', result.unresolved_findings, [])
}

async function scenarioAG() {
  console.log('\n== scenario AG: a fresh finding from the last round that still reproduces halts, and says it was checked')
  const { result, captured } = await run(lateFinding(false))
  check('the fresh finding was executed in the same round', callCount(captured, 'reproduce:fix:1:fresh'), 1)
  check('halted at Fix', result.halted_at, 'Fix')
  check('the finding is reported', result.unresolved_findings?.length, 1)
  check('the stop reason no longer claims it survived every round',
    (result.stopped_because ?? '').includes('survived every round'), false)
  check('the stop reason says it was checked',
    (result.stopped_because ?? '').includes('checked against the code'), true)
}

// Scenario AH -- two lenses, one defect. Both were counted, so every fix round
// paid for it twice.
async function scenarioAH() {
  console.log('\n== scenario AH: one defect found by two lenses becomes one finding')
  const { captured } = await run({
    args: { maxReviewRounds: 1 },
    initialReview: {
      correctness: [{ title: 'Nil deref in Load', file: 'src/p.js',
        claim: 'derefs before the guard', evidence: 'p.js:12' }],
      advocate: [{ title: 'Load can panic on a missing key', file: 'src/p.js',
        claim: 'no guard before the dereference', evidence: 'p.js:12-14' }],
    },
    dedupGroups: [{ ids: ['f1', 'f2'], why: 'same dereference' }],
    verify: () => undefined,
    fixHead: () => 'fix00000000000000000000000000000000000001',
    staleness: () => [],
  })
  check('the dedup brief was handed both ids',
    idsIn(captured.dedupPrompt ?? '').length, 2)
  const reproduce1 = captured.calls.find(c => c.label === 'reproduce:fix:1')?.prompt ?? ''
  check('the fix round is asked about one finding, not two', idsIn(reproduce1).length, 1)
  check('the survivor is the first of the group', idsIn(reproduce1)[0], 'f1')
}

// Scenario AI -- the dedup agent returning nothing must keep both findings.
// Losing a real defect is the failure that matters here; a duplicate is not.
async function scenarioAI() {
  console.log('\n== scenario AI: a dedup that finds nothing keeps every finding')
  const { captured } = await run({
    args: { maxReviewRounds: 1 },
    initialReview: {
      correctness: [{ title: 'Bug one', file: 'a.js', claim: 'c1', evidence: 'e1' }],
      advocate: [{ title: 'Bug two', file: 'b.js', claim: 'c2', evidence: 'e2' }],
    },
    dedupGroups: [],
    verify: () => undefined,
    fixHead: () => 'fix00000000000000000000000000000000000001',
    staleness: () => [],
  })
  const reproduce1 = captured.calls.find(c => c.label === 'reproduce:fix:1')?.prompt ?? ''
  check('both findings reach the fix round', idsIn(reproduce1).length, 2)
}

// Scenario AJ -- a gated repo's Fix halt reports the CRAP gate as confirmed:
// a raw commit could not have bypassed it.
async function scenarioAJ() {
  console.log('\n== scenario AJ: a gated repo\'s Fix halt reports the CRAP gate as confirmed')
  const { result } = await run({
    args: { maxReviewRounds: 1 },
    crapGated: true,
    initialReview: {
      correctness: [{ title: 'Unrelated leak', file: 'src/pool.js',
        claim: 'connection is never released', evidence: 'pool.js:40' }],
      advocate: [],
    },
    verify: () => false,
    staleness: () => [],
  })
  check('halted at Fix', result.halted_at, 'Fix')
  check('gates.measured is scored', result.gates?.measured, 'scored')
  check('gates.bypass_blocked is true', result.gates?.bypass_blocked, true)
  check('gates says a raw commit could not have bypassed it',
    (result.gates?.detail ?? '').includes('could not have bypassed it'), true)
}

// Scenario AK -- an ungated repo's Fix halt still reports what was measured;
// only the bypass claim in `detail` and `bypass_blocked` change with the marker.
async function scenarioAK() {
  console.log('\n== scenario AK: an ungated repo\'s Fix halt reports bypass_blocked=false')
  const { result } = await run({
    args: { maxReviewRounds: 1 },
    crapGated: false,
    initialReview: {
      correctness: [{ title: 'Unrelated leak', file: 'src/pool.js',
        claim: 'connection is never released', evidence: 'pool.js:40' }],
      advocate: [],
    },
    verify: () => false,
    staleness: () => [],
  })
  check('halted at Fix', result.halted_at, 'Fix')
  check('gates.measured is scored, the measurement is not conflated with the bypass question',
    result.gates?.measured, 'scored')
  check('gates.bypass_blocked is false', result.gates?.bypass_blocked, false)
  check('gates says a raw commit was not hook-blocked from bypassing it',
    (result.gates?.detail ?? '').includes('.crap-gated absent at the repo root'), true)
}

// Scenario AL -- the same distinction, one halt later: the Mutation halt must
// also keep reporting bypass_blocked=false in an ungated repo.
async function scenarioAL() {
  console.log('\n== scenario AL: an ungated repo\'s Mutation halt reports bypass_blocked=false')
  const { result } = await run(convergedWithSuspect({
    crapGated: false,
    mutationResult: () => ({ green: false, head_sha: 'mut0000000000000000000000000000000000001',
      detail: 'stub red', survivors: 1, scored: true }),
  }))
  check('halted at Mutation', result.halted_at, 'Mutation')
  check('gates.bypass_blocked is false', result.gates?.bypass_blocked, false)
  check('gates.measured is scored', result.gates?.measured, 'scored')
}

// Scenario AM -- and the green path's final result carries the same
// distinction: an ungated repo's result still reports bypass_blocked=false.
async function scenarioAM() {
  console.log('\n== scenario AM: an ungated repo\'s green-path result reports bypass_blocked=false')
  const { result } = await run({
    args: { openPr: true },
    crapGated: false,
    prResult: { opened: true, url: 'https://example.invalid/pr/23', note: 'stub ready' },
    initialReview: { correctness: [], advocate: [] },
    verify: () => undefined,
    staleness: () => [],
  })
  check('halted_at is absent', result.halted_at, undefined)
  check('gates.measured is scored', result.gates?.measured, 'scored')
  check('gates.bypass_blocked is false', result.gates?.bypass_blocked, false)
}

// Scenario AN -- probe returns nothing: the bypass question is unconfirmed, so
// bypass_blocked stays false (never asserted true when nobody confirmed the
// marker), and the run logs the failure.
async function scenarioAN() {
  console.log('\n== scenario AN: a failed gate opt-in probe reports bypass_blocked=false')
  const { result, captured } = await run({
    args: { openPr: true },
    gateProbeFails: true,
    prResult: { opened: true, url: 'https://example.invalid/pr/23', note: 'stub ready' },
    initialReview: { correctness: [], advocate: [] },
    verify: () => undefined,
    staleness: () => [],
  })
  check('gates.bypass_blocked is false when the probe returns nothing',
    result.gates?.bypass_blocked, false)
  check('gates.measured is scored', result.gates?.measured, 'scored')
  check('the run logs that the probe returned nothing',
    captured.logs.some(l => l.includes('gate opt-in probe returned nothing')), true)
}

// Scenario AS -- the aggregate rule this ticket exists for: the implementer
// scored nothing, but a fix round did, so the run's overall `measured` claim
// is still 'scored'.
async function scenarioAS() {
  console.log('\n== scenario AS: a fix round that scores makes the run measured, even if the implementer did not')
  const { result } = await run({
    args: { maxReviewRounds: 1 },
    implScored: false,
    fixScored: (round) => round === 1,
    initialReview: {
      correctness: [{ title: 'Unrelated leak', file: 'src/pool.js',
        claim: 'connection is never released', evidence: 'pool.js:40' }],
      advocate: [],
    },
    verify: () => true,
    staleness: () => [],
  })
  check('gates.measured is scored', result.gates?.measured, 'scored')
}

// Scenario AT -- nothing scorable: the implementer reported scored=false and
// no fix round ran, so no committing phase ever scored anything.
async function scenarioAT() {
  console.log('\n== scenario AT: nothing scorable when no committing phase scored anything')
  const { result } = await run({
    implScored: false,
    initialReview: { correctness: [], advocate: [] },
    verify: () => undefined,
    staleness: () => [],
  })
  check('halted_at is absent', result.halted_at, undefined)
  check('gates.measured is nothing scorable', result.gates?.measured, 'nothing scorable')
}

// Scenario AU -- gates.detail must not claim "gates measured" when nothing
// was scorable: the sentence has to vary with the measured field it sits
// next to, not stay byte-identical to the scored case.
async function scenarioAU() {
  console.log('\n== scenario AU: gates.detail does not claim "measured" when nothing was scorable')
  const scored = await run({
    initialReview: { correctness: [], advocate: [] },
    verify: () => undefined,
    staleness: () => [],
  })
  const nothingScorable = await run({
    implScored: false,
    initialReview: { correctness: [], advocate: [] },
    verify: () => undefined,
    staleness: () => [],
  })
  check('the nothing-scorable detail does not open with "gates measured"',
    (nothingScorable.result.gates?.detail ?? '').startsWith('gates measured'), false)
  check('the two details are not byte-identical',
    nothingScorable.result.gates?.detail !== scored.result.gates?.detail, true)
}

// Scenario AV -- a gate_note from a phase that scored nothing must not be
// carried forward once a later phase reports scored=true: pairing an
// implementer's "nothing to score" message with an overall measured='scored'
// claims the wrong phase's evidence for the aggregate.
async function scenarioAV() {
  console.log('\n== scenario AV: an unscored phase\'s gate_note is dropped once a later phase scores')
  const { result } = await run({
    args: { maxReviewRounds: 1 },
    implScored: false,
    implGateNote: 'no staged source files in supported languages (go, php, python)',
    fixScored: (round) => round === 1,
    initialReview: {
      correctness: [{ title: 'Unrelated leak', file: 'src/pool.js',
        claim: 'connection is never released', evidence: 'pool.js:40' }],
      advocate: [],
    },
    verify: () => true,
    staleness: () => [],
  })
  check('gates.measured is scored', result.gates?.measured, 'scored')
  check('the unscored implementer\'s gate_note does not leak into detail',
    (result.gates?.detail ?? '').includes('no staged source files'), false)
}

// Scenario AW -- the aggregate rule extended past the fix loop: the mutation
// phase's own commit is the only thing that scored in the whole run, and it
// must still make the green-path result's measured claim 'scored'.
async function scenarioAW() {
  console.log('\n== scenario AW: a scoring mutation commit makes the green-path result measured')
  const { result } = await run({
    implScored: false,
    initialReview: { correctness: [], advocate: [] },
    verify: () => undefined,
    staleness: () => [],
    mutationGated: true,
    mutationResult: () => ({ green: true, head_sha: 'mut0000000000000000000000000000000000003',
      detail: 'stub green', scored: true }),
  })
  check('halted_at is absent', result.halted_at, undefined)
  check('gates.measured reflects the mutation phase\'s own scored commit',
    result.gates?.measured, 'scored')
}

// Scenario AX -- the same commit, but the attempt it came from still ended
// red: a losing mutation attempt can commit a real fix before failing, and
// the Mutation halt must not discard that just because the gate stayed red.
async function scenarioAX() {
  console.log('\n== scenario AX: the Mutation halt reflects a scored commit from a losing attempt')
  const { result } = await run({
    implScored: false,
    initialReview: { correctness: [], advocate: [] },
    verify: () => undefined,
    staleness: () => [],
    mutationGated: true,
    mutationResult: () => ({ green: false, head_sha: 'mut0000000000000000000000000000000000004',
      detail: 'stub red', survivors: 1, scored: true }),
  })
  check('halted at Mutation', result.halted_at, 'Mutation')
  check('gates.measured reflects the losing attempt\'s own scored commit',
    result.gates?.measured, 'scored')
}

// Scenario AY -- scored=false is not one cause: it covers "no commits", "the
// gate printed nothing to score" and more. When nothing ever scores, the
// implementer's own gate_note is the only observation of which one it was,
// so it must survive into detail rather than being replaced by a guess.
async function scenarioAY() {
  console.log('\n== scenario AY: the nothing-scorable detail carries the implementer\'s own gate_note')
  const { result } = await run({
    implScored: false,
    implGateNote: 'crap-commit.sh: no staged source files (go, php, python)',
    initialReview: { correctness: [], advocate: [] },
    verify: () => undefined,
    staleness: () => [],
  })
  check('gates.measured is nothing scorable', result.gates?.measured, 'nothing scorable')
  check('the implementer\'s own gate_note reaches detail',
    (result.gates?.detail ?? '').includes('no staged source files'), true)
}

// Scenario AO -- one merged setup call answers the CRAP and mutation markers
// together with the ticket and version probe; the mutation phase must not
// ask the repo a second time, and no separate gate:opt-in call must exist.
async function scenarioAO() {
  console.log('\n== scenario AO: the merged setup call answers both markers; nothing dispatches gate:opt-in separately')
  const { result, captured } = await run(convergedWithSuspect({
    crapGated: true,
    mutationGated: false,
  }))
  check('setup was called exactly once', callCount(captured, 'setup'), 1)
  check('gate:opt-in is never dispatched as its own call', callCount(captured, 'gate:opt-in'), 0)
  check('mutation gate honoured the merged probe\'s answer',
    (result.mutation?.detail ?? '').includes('skipped'), true)
}

// Scenarios AP to AR -- the branch marker. It is the run's only record of
// which tracker the work came from, and the branch agent used to classify the
// ticket itself: GitHub issue 278 came back as feat/jira-278-...
async function scenarioAP() {
  console.log('\n== scenario AP: a bare number is handed to the branch agent as gh-')
  const { captured } = await run({
    args: { ticket: '278' },
    initialReview: { correctness: [], advocate: [] },
    verify: () => undefined,
    staleness: () => [],
  })
  const p = captured.calls.find(c => c.label === 'branch')?.prompt ?? ''
  check('the branch name is given with the gh- marker resolved',
    p.includes('feat/gh-278-<slug>'), true)
  check('the worktree path carries the same marker',
    p.includes('.claude/worktrees/gh-278-<slug>'), true)
  check('the agent is told not to swap the marker',
    p.includes('do not re-derive it'), true)
  check('it is no longer asked to classify the ticket',
    p.includes('when the ticket is a'), false)
}

async function scenarioAQ() {
  console.log('\n== scenario AQ: a Jira key is handed over as jira-, uppercased')
  const { captured } = await run({
    args: { ticket: 'proj-4821', branchType: 'fix' },
    initialReview: { correctness: [], advocate: [] },
    verify: () => undefined,
    staleness: () => [],
  })
  const p = captured.calls.find(c => c.label === 'branch')?.prompt ?? ''
  check('the key is canonicalised to upper case',
    p.includes('fix/jira-PROJ-4821-<slug>'), true)
}

async function scenarioAR() {
  console.log('\n== scenario AR: a ticket that is neither form refuses before any agent runs')
  let message = ''
  try {
    await run({ args: { ticket: 'retry-policy' } })
  } catch (e) {
    message = e?.message ?? String(e)
  }
  check('it throws rather than guessing a marker',
    message.includes('neither a GitHub issue number'), true)
}

// Scenario BB -- the existingBranch prompt's guard checks the tree it is
// actually going to commit into (the matched record's own path), whichever
// tree that is, rather than special-casing the main checkout and waiving the
// check for a linked worktree.
async function scenarioBB() {
  console.log('\n== scenario BB: the existingBranch prompt checks the matched record\'s own path, main checkout or not')
  const { captured } = await run({
    args: { existingBranch: true },
    initialReview: { correctness: [], advocate: [] },
    verify: () => undefined,
    staleness: () => [],
  })
  const p = captured.calls.find(c => c.label === 'branch:existing')?.prompt ?? ''
  check('the guard checks the matched or re-attached path from step 4, 5, or 6',
    p.includes("using the matched or re-attached path from step 4, 5, or 6"), true)
  check('the guard applies whether that path is the main checkout or a linked worktree',
    p.includes('whether that is the main checkout or a linked worktree'), true)
  check('the incorrect main-checkout-only carve-out is gone',
    p.includes('A dirty main checkout is not a reason to stop'), false)
  check('the guard still forbids stashing, resetting or discarding',
    p.includes('Never stash, reset, or discard'), true)
}

// Scenario BC -- the default (non-existingBranch) branch prompt's own reuse
// path (an existing branch already checked out elsewhere) must check that
// record's path for dirty state before reusing it: that record can be the
// main checkout, and a later phase runs git add -A there.
async function scenarioBC() {
  console.log('\n== scenario BC: the default branch prompt\'s reuse path checks the matched record for dirty state')
  const { captured } = await run({
    initialReview: { correctness: [], advocate: [] },
    verify: () => undefined,
    staleness: () => [],
  })
  const p = captured.calls.find(c => c.label === 'branch')?.prompt ?? ''
  check('the reuse step checks the matched record\'s path for dirty state',
    p.includes('This mode commits into that tree, and a later phase runs git add -A there'), true)
  check('the reuse guard forbids stashing, resetting or discarding',
    p.includes('Never stash, reset, or discard'), true)
  // 'occupied' describes this agent's own step 8 halt, so a field it can see
  // is a field it may fill, and the run would then print the other mode's note.
  check('this agent is not handed halt_reason at all',
    captured.calls.find(c => c.label === 'branch')?.schema?.properties?.halt_reason, undefined)
}

// Scenario BD -- the script cannot resolve a fork point itself (no filesystem
// access), so the implementer is told to try both <base> and origin/<base>
// and pick between them at runtime. A given base must reach that rule bare in
// both shapes it arrives in: a stacked branch name with no remote ref, and an
// origin/<x> that must not double.
async function scenarioBD() {
  console.log('\n== scenario BD: a given base reaches the merge-base rule bare, never doubled')
  for (const [given, bare] of [['feat/gh-40-parent', 'feat/gh-40-parent'], ['origin/develop', 'develop']]) {
    const { captured } = await run({
      args: { base: given, openPr: true },
      branchResult: { created: true, branch: 'feat/gh-21-stub', base: 'main',
        path: '/tmp/stub-worktree', ticket: '21', detail: 'stub' },
      draftPr: { opened: true, number: 23, url: 'https://example.invalid/pr/23', detail: 'stub draft' },
      prResult: { opened: true, url: 'https://example.invalid/pr/23', note: 'stub ready' },
      initialReview: { correctness: [], advocate: [] },
      verify: () => undefined,
      staleness: () => [],
    })
    const p = captured.calls.find(c => c.label === 'implementer')?.prompt ?? ''
    check(`${given}: the bare candidate is offered`, p.includes(`with ${bare} and`), true)
    check(`${given}: the origin candidate is offered`, p.includes(`with origin/${bare}`), true)
    check(`${given}: it is never doubled`, p.includes('origin/origin/'), false)
    // gh resolves --base as a branch on the remote, so an origin/-qualified
    // name is rejected there -- at the very end of a run whose gates all went
    // green.
    for (const [label, call] of [['draft', 'draft-pr'], ['ready', 'pr']]) {
      const q = captured.calls.find(c => c.label === call)?.prompt ?? ''
      check(`${given}: the ${label} PR phase ran`, q.length > 0, true)
      check(`${given}: the ${label} PR targets the bare base`,
        q.includes(`--base ${bare}`), true)
      check(`${given}: the ${label} PR does not target an origin/ name`,
        q.includes('--base origin/'), false)
    }
  }
}

// Scenario BE -- only the fresh-cut prompt's own step 3 tells its agent to
// strip the origin/ prefix that git symbolic-ref --short refs/remotes/origin/HEAD
// prints; a reported base of "origin/main" must still reach the merge-base
// rule as the bare "main", not doubled into "origin/origin/main".
async function scenarioBE() {
  console.log('\n== scenario BE: a base reported as origin/main by the fresh-cut prompt is stripped to main')
  const { captured } = await run({
    branchResult: { created: true, branch: 'feat/gh-21-stub', base: 'origin/main',
      path: '/tmp/stub-worktree', ticket: '21', detail: 'stub' },
    initialReview: { correctness: [], advocate: [] },
    verify: () => undefined,
    staleness: () => [],
  })
  const p = captured.calls.find(c => c.label === 'implementer')?.prompt ?? ''
  check('the bare candidate is main, not origin/main', p.includes('with main and'), true)
  check('the origin candidate is origin/main, not origin/origin/main', p.includes('with origin/main'), true)
  check('it is never doubled', p.includes('origin/origin/'), false)
}

// Scenario BF -- the default (non-existingBranch) branch prompt's own dirty
// reuse halt (step 6) must report why: a dirty checkout, not the base-branch
// note meant for the other default-mode halts (an invalid baseOverride ref, a
// worktree path already on disk, a failed fetch or resolve).
async function scenarioBF() {
  console.log('\n== scenario BF: a dirty reused worktree halts with a dirty-checkout note, not a base-branch note')
  const { result } = await run({
    branchResult: { created: false, branch: 'feat/gh-21-stub', base: 'main',
      path: '/tmp/stub-worktree', ticket: '21', detail: 'staged.txt is dirty', dirty: true },
  })
  check('halted at Worktree', result.halted_at, 'Worktree')
  check('the note points at the dirty checkout', /[Cc]ommit or stash/.test(result.note ?? ''), true)
  check('the note does not blame a base branch problem',
    (result.note ?? '').includes('base branch problem'), false)
  check('the note does not send the user toward the existingBranch guard, ' +
    'which refuses the same tree for the same reason',
    (result.note ?? '').includes('existingBranch: true'), false)
}

// Scenario BG -- the existingBranch prompt's step 7 never tells its agent to
// strip an origin/ prefix off the base it reports, unlike the fresh-cut
// prompt's own step 3. A base of "origin/main" must still reach the
// merge-base rule stripped to "main", not doubled into "origin/origin/main".
async function scenarioBG() {
  console.log('\n== scenario BG: a base reported as origin/main by the existingBranch prompt is stripped to main')
  const { captured } = await run({
    args: { existingBranch: true },
    existingBranchResult: { created: true, branch: 'feat/gh-21-stub', base: 'origin/main',
      path: '/tmp/stub-worktree', ticket: '21', detail: 'stub' },
    initialReview: { correctness: [], advocate: [] },
    verify: () => undefined,
    staleness: () => [],
  })
  const p = captured.calls.find(c => c.label === 'implementer')?.prompt ?? ''
  check('the bare candidate is main, not origin/main', p.includes('with main and'), true)
  check('the origin candidate is origin/main, not origin/origin/main', p.includes('with origin/main'), true)
  check('it is never doubled', p.includes('origin/origin/'), false)
}

const SCENARIOS = [scenarioAD, scenarioAE, scenarioAF, scenarioAG, scenarioAH, scenarioAI, scenarioAJ, scenarioAK, scenarioAL, scenarioAM, scenarioAN, scenarioAS, scenarioAT, scenarioAU, scenarioAV, scenarioAW, scenarioAX, scenarioAY, scenarioAO, scenarioAP, scenarioAQ, scenarioAR, scenarioBB, scenarioBC, scenarioBD, scenarioBE, scenarioBF, scenarioBG]
JS_EOF

finish
