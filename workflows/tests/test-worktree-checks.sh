#!/usr/bin/env bash
# Scenarios scenarioBH..scenarioCK, split out of
# test-fix-loop-join.sh (gh-118); see harness.sh.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/harness.sh"

run_js_scenarios <<'JS_EOF'
// Scenario BH -- the script has no filesystem access, so it cannot resolve a
// fork point itself; the implementer must be told the exact tiebreak rule
// (descendant wins, origin/<base> on a genuine divergence) rather than being
// left to guess, since the gates measure against origin/HEAD and a different
// pick here would review a range the gates never scored.
async function scenarioBH() {
  console.log('\n== scenario BH: the prompt states the two-candidate merge-base rule')
  const { captured } = await run({
    branchResult: { created: true, branch: 'feat/gh-21-stub', base: 'main',
      path: '/tmp/stub-worktree', ticket: '21', detail: 'stub' },
    initialReview: { correctness: [], advocate: [] },
    verify: () => undefined,
    staleness: () => [],
  })
  const p = captured.calls.find(c => c.label === 'implementer')?.prompt ?? ''
  check('only-one-resolves is covered', p.includes('If only one of those refs resolves'), true)
  check('the descendant tiebreak is covered', p.includes('--is-ancestor'), true)
  check('the origin fallback names the reason: the gates diff against origin/HEAD',
    p.includes('origin/HEAD first'), true)
}

// Scenario BI -- a marker-matching worktree record must be usable regardless
// of the invoking checkout: it must actually carry the run through Plan, not
// merely fail to halt at Worktree, because the two used to be conflated (the
// old guard halted at Worktree for exactly this case).
async function scenarioBI() {
  console.log('\n== scenario BI: existingBranch with a matched worktree and team-scoped triage reaches Plan')
  const { result, captured } = await run({
    args: { existingBranch: true },
    existingBranchResult: { created: true, branch: 'feat/gh-21-stub', base: 'main',
      path: '/tmp/stub-worktree', ticket: '21', detail: 'stub' },
    triage: { scope: 'team', estimated_loc: 50 },
    plannerResult: { plan: 'stub plan', acceptance_criteria: [], risky_areas: [],
      task_demands_implementation: false },
    initialReview: { correctness: [], advocate: [] },
    verify: () => undefined,
    staleness: () => [],
  })
  check('the run does not halt at Worktree', result.halted_at === 'Worktree', false)
  check('the planner ran exactly once', callCount(captured, 'planner'), 1)
  // A hand-fed created:true record carries through the old pipeline too, so
  // the only part of this the stub does not decide is what the lookup agent
  // was told: that the invoking checkout's branch does not gate the match.
  const bx = captured.calls.find(c => c.label === 'branch:existing')?.prompt ?? ''
  check('the branch:existing phase ran', bx.length > 0, true)
  check('the lookup runs whatever the invoking checkout is on',
    bx.includes('regardless of what the invoking checkout is on'), true)
  check('being on the base branch is named as fine, not an error',
    bx.includes('the base branch, another feature branch, or detached HEAD are all'), true)
  check('the matched record\'s branch is what the run carries',
    result.branch, 'feat/gh-21-stub')
  const impl = captured.calls.find(c => c.label === 'implementer')?.prompt ?? ''
  check('the implementer phase ran', impl.length > 0, true)
  check('the matched record\'s path is where the work happens',
    impl.includes('/tmp/stub-worktree'), true)
}

// Scenario BJ -- the existingBranch halt note used to tell the user to check
// out the branch in the main checkout, the one thing this project's own
// CONTRIBUTING.md tells an agent never to do. It must instead name what the
// prompt actually looked for -- and the lookup ignores branch type (#87), so
// the note must not claim it searched a type-scoped name like
// feat/gh-21-<slug>: with --type fix that claim is both wrong and, since the
// type has no effect on the lookup, useless advice to re-run with a different
// --type.
async function scenarioBJ() {
  console.log('\n== scenario BJ: the existingBranch halt note names what it looked for, not a checkout instruction')
  const { result } = await run({
    args: { existingBranch: true },
    existingBranchResult: { created: false, branch: '', base: '', path: '',
      detail: 'no worktree found for gh-21', dirty: false },
  })
  check('halted at Worktree', result.halted_at, 'Worktree')
  check('the note does not advise checking out a branch',
    /check out the branch/i.test(result.note ?? ''), false)
  check('the note names the marker it looked for, with no branch-type prefix',
    (result.note ?? '').includes('gh-21-<slug>') && !(result.note ?? '').includes('feat/gh-21-<slug>'),
    true)
  check('the note names the directory the prompt looked for',
    (result.note ?? '').includes('.claude/worktrees/gh-21-<slug>'), true)
  check('the note says the search was not scoped to one branch type',
    /any branch type/i.test(result.note ?? ''), true)
}

// Scenario BK -- #87: a branch the pipeline created can lose its worktree (the
// directory gets cleaned up by hand while the PR stays open) without losing
// the branch itself, since git worktree prune only drops the registration.
// The existingBranch prompt must fall back to a plain branch lookup and
// re-attach a worktree to it, rather than stopping at the worktree-only
// lookup and telling the user to cut a duplicate branch.
async function scenarioBK() {
  console.log('\n== scenario BK: the existingBranch prompt falls back to a worktree-less branch match')
  const { captured } = await run({
    args: { existingBranch: true },
    initialReview: { correctness: [], advocate: [] },
    verify: () => undefined,
    staleness: () => [],
  })
  const p = captured.calls.find(c => c.label === 'branch:existing')?.prompt ?? ''
  check('the prompt looks up a branch with no worktree of its own',
    p.includes('git branch --list'), true)
  check('the prompt re-attaches a worktree rather than creating a new branch',
    p.includes('git worktree add') && p.includes('no -b, the branch already exists'), true)
  check('the prompt explains why the branch can outlive its worktree',
    p.includes('git worktree prune') && p.includes('never the branch itself'), true)
  check('the top-line restriction no longer bars every worktree creation',
    p.includes('do not create a worktree, do not fetch'), false)
  check('the top-line restriction still bars creating a branch',
    p.includes('Do not create a branch'), true)
}

// Scenario BL -- #87: the step 5/6 fallback to whatever is checked out here
// must not bless a branch marked for a different ticket. The invoking
// session usually runs inside another worktree, so this is reachable: run
// with --existing on ticket 88 from inside the gh-87 worktree, and if 88 has
// no worktree or branch of its own yet, the old fallback took gh-87's branch
// unguarded and committed 88's work onto 87's PR.
async function scenarioBL() {
  console.log('\n== scenario BL: the existingBranch prompt refuses a fallback branch marked for another ticket')
  const { captured } = await run({
    args: { existingBranch: true },
    initialReview: { correctness: [], advocate: [] },
    verify: () => undefined,
    staleness: () => [],
  })
  const p = captured.calls.find(c => c.label === 'branch:existing')?.prompt ?? ''
  check('the fallback refuses a branch carrying another ticket\'s marker',
    p.includes('a jira- or gh- marker other than'), true)
  check('the refusal is distinguished from the plain not-found halt',
    p.includes('wrong-ticket'), true)
}

// Scenario BM -- #87: two or more matching branches (from either the
// worktree lookup or the worktree-less branch lookup) must halt with a note
// that says an ambiguous match was found, not the plain not-found note
// (which used to fire for both cases and, worse, told the user to cut a
// third branch for the same ticket).
async function scenarioBM() {
  console.log('\n== scenario BM: an ambiguous existingBranch match halts with its own note, not the not-found note')
  const { result, captured } = await run({
    args: { existingBranch: true },
    existingBranchResult: { created: false, branch: '', base: '', path: '',
      detail: 'two branches carry the gh-21 marker: feat/gh-21-a, fix/gh-21-b',
      dirty: false, halt_reason: 'ambiguous' },
  })
  // Read off the schema the harness was handed, not the source text: an
  // omitted halt_reason reads as the plain not-found note, so it has to fail
  // validation rather than default.
  const schema = captured.calls.find(c => c.label === 'branch:existing')?.schema
  check('the branch:existing schema requires halt_reason',
    (schema?.required ?? []).includes('halt_reason'), true)
  check('its enum has a member for the ordinary response',
    (schema?.properties?.halt_reason?.enum ?? []).includes('none'), true)
  check('halted at Worktree', result.halted_at, 'Worktree')
  check('the note reports the ambiguity rather than claiming nothing was found',
    /more than one/i.test(result.note ?? ''), true)
  check('the note is the ambiguity note, not the not-found note it replaced',
    (result.note ?? '').startsWith('Found more than one branch carrying'), true)
  check('the note carries the matched branches',
    (result.note ?? '').includes('feat/gh-21-a'), true)
}

// Scenario BN -- #87: the wrong-ticket refusal (scenario BL's prompt text)
// must halt with a note naming the mismatch, not the plain not-found note.
async function scenarioBN() {
  console.log('\n== scenario BN: a fallback branch for another ticket halts with its own note')
  const { result } = await run({
    args: { existingBranch: true },
    existingBranchResult: { created: false, branch: '', base: '', path: '',
      detail: 'checked-out branch fix/gh-99-other carries the gh-99 marker, not gh-21',
      dirty: false, halt_reason: 'wrong-ticket' },
  })
  check('halted at Worktree', result.halted_at, 'Worktree')
  check('the note names the mismatch rather than claiming nothing was found',
    /different ticket/i.test(result.note ?? ''), true)
  check('cutting a new branch is safe advice here: the lookup already ' +
    'covered every worktree and branch for this ticket and found none',
    (result.note ?? '').includes('Re-run without existingBranch to cut one'), true)
}

// Scenario BO -- #87: the worktree-less branch fallback (scenario BK's
// prompt text) must not re-attach a worktree to a branch whose pull request
// already merged. The common way a branch outlives its worktree is the PR
// merging and the directory being cleaned up because the work was done, not
// because it was abandoned mid-flight -- so silently re-attaching runs a full
// implement-and-gate cycle on a ticket that already shipped.
async function scenarioBO() {
  console.log('\n== scenario BO: the worktree-less fallback checks the matched branch\'s PR state before re-attaching')
  const { captured } = await run({
    args: { existingBranch: true },
    initialReview: { correctness: [], advocate: [] },
    verify: () => undefined,
    staleness: () => [],
  })
  const p = captured.calls.find(c => c.label === 'branch:existing')?.prompt ?? ''
  check('the prompt checks the matched branch\'s PR state before re-attaching',
    p.includes('gh pr view') && p.includes('MERGED'), true)
  check('a merged PR halts distinctly, not as ambiguous or wrong-ticket',
    p.includes('halt_reason=merged'), true)
  check('the prompt refuses to re-attach a merged branch',
    p.includes('Do not re-attach a worktree to it'), true)
}

// Scenario BP -- #87: a worktree-less branch whose PR already merged must
// halt with its own note, not the plain not-found note, whose advice to cut
// a new branch would duplicate a branch this ticket already has.
async function scenarioBP() {
  console.log('\n== scenario BP: a merged-PR branch halts with its own note')
  const { result } = await run({
    args: { existingBranch: true },
    existingBranchResult: { created: false, branch: '', base: '', path: '',
      detail: 'branch fix/gh-21-retry-path carries the gh-21 marker but its PR #40 is MERGED',
      dirty: false, halt_reason: 'merged' },
  })
  check('halted at Worktree', result.halted_at, 'Worktree')
  check('the note reports the merged PR rather than claiming nothing was found',
    /merged/i.test(result.note ?? ''), true)
  check('the note carries the matched branch',
    (result.note ?? '').includes('fix/gh-21-retry-path'), true)
}

// Scenario BQ -- #87: the occupied-path halt in the worktree-less fallback (a
// branch was found, but its canonical worktree directory already holds
// something else) must halt with its own note, not the plain not-found note,
// which would tell the user to cut a duplicate branch for a ticket that
// already has one.
async function scenarioBQ() {
  console.log('\n== scenario BQ: an occupied canonical worktree path halts with its own note')
  const { result } = await run({
    args: { existingBranch: true },
    existingBranchResult: { created: false, branch: '', base: '', path: '',
      detail: '.claude/worktrees/gh-21-retry-path already holds an unrelated checkout',
      dirty: false, halt_reason: 'occupied' },
  })
  check('halted at Worktree', result.halted_at, 'Worktree')
  check('the note is the occupied note, not the not-found note it replaced',
    (result.note ?? '').startsWith('A branch carrying the gh-21 marker was found with no'), true)
  check('the note names what is occupying the path',
    (result.note ?? '').includes('already holds an unrelated checkout'), true)
}

// Scenario BR -- #87 review: the pipeline never removes a worktree, so a
// worktree left behind by a ticket branch whose PR already merged is just as
// reachable through step 4 (the worktree lookup) as through step 5's
// worktree-less fallback. Step 4 used to reuse an exactly-one match with no
// PR-state check at all, so the guard step 5 enforces was skipped whenever
// the merged branch's worktree directory happened to still exist on disk.
async function scenarioBR() {
  console.log('\n== scenario BR: the worktree-match path (step 4) also checks PR state before reusing it')
  const { captured } = await run({
    args: { existingBranch: true },
    initialReview: { correctness: [], advocate: [] },
    verify: () => undefined,
    staleness: () => [],
  })
  const p = captured.calls.find(c => c.label === 'branch:existing')?.prompt ?? ''
  const step4 = p.slice(p.indexOf('4. Ticket lookup'), p.indexOf('5. Only if step 4 matched nothing'))
  // Both markers missing makes the slice empty, and every absence check below
  // then passes on nothing.
  check('the step 4 slice was actually found', step4.length > 0, true)
  check('step 4 no longer reuses a bare match with no PR-state check at all',
    step4.includes('Exactly one match: that is the tree to use. Go to step 7.'), false)
  check('step 4 checks the matched branch\'s PR state before reusing it',
    step4.includes('gh pr view') && step4.includes('MERGED'), true)
  check('step 4 halts distinctly on a merged match, same as step 5',
    step4.includes('halt_reason=merged'), true)
}

// Scenario BS -- #87 review: the merged halt's own advice told the user to
// "re-run without existingBranch to cut a fresh branch". What that path does
// turns entirely on the branch name it re-derives from the task: the same
// name reuses the merged branch and pushes onto its closed pull request, a
// different one cuts fresh or halts on the directory. The note has to cover
// both, because the run cannot tell which it will get.
async function scenarioBS() {
  console.log('\n== scenario BS: the merged halt note covers both outcomes of re-running without existingBranch')
  const { result } = await run({
    args: { existingBranch: true },
    existingBranchResult: { created: false, branch: '', base: '', path: '',
      detail: 'branch fix/gh-21-retry-path carries the gh-21 marker but its PR #40 is MERGED',
      dirty: false, halt_reason: 'merged' },
  })
  const note = result.note ?? ''
  check('it makes the outcome turn on the re-derived name, not on the marker',
    /only the name decides/.test(note), true)
  check('it names the reuse outcome and the fresh-cut outcome, not just one',
    /reuses the merged branch/.test(note) && /cuts a fresh branch/.test(note), true)
  check('it names the way out: clear the leftovers, or use another ticket',
    /delete the branch/.test(note) && /ticket of its own/.test(note), true)
}

// Scenario BT -- #87 review: step 5's re-attach action used to live in a
// "Not merged" bullet that sits between "Exactly one match" and "Two or more
// matches", mixing two axes (match count, PR state) in one bullet list. That
// left the re-attach action naming no match count, and put the
// two-or-more-matches bullet after the one that should never run for that
// case.
async function scenarioBT() {
  console.log('\n== scenario BT: step 5 bullets are keyed only on match count, not mixed with a PR-state sibling')
  const { captured } = await run({
    args: { existingBranch: true },
    initialReview: { correctness: [], advocate: [] },
    verify: () => undefined,
    staleness: () => [],
  })
  const p = captured.calls.find(c => c.label === 'branch:existing')?.prompt ?? ''
  const step5 = p.slice(p.indexOf('5. Only if step 4 matched nothing'), p.indexOf('6. Only if steps 4 and 5 matched nothing'))
  check('the step 5 slice was actually found', step5.length > 0, true)
  check('the re-attach action is folded into the Exactly one match bullet, not a sibling Not merged bullet',
    step5.includes('- Not merged:'), false)
  check('Two or more matches sits directly after Exactly one match, before No match',
    step5.indexOf('Two or more matches') > step5.indexOf('Exactly one match') &&
    step5.indexOf('No match') > step5.indexOf('Two or more matches'), true)
  check('the re-attach action (git worktree add, no -b) is still reachable from Exactly one match',
    step5.includes('git worktree add') && step5.includes('no -b, the branch already'), true)
}

// Scenario AZ -- the defect #81 is about. A lens points a fresh finding at a
// settled one because the fix for that finding introduced this one. Assuming
// it was a re-report readied a PR carrying a real regression, under
// unresolved_findings: []. The verifier decides now, and a suspect that still
// reproduces blocks like any other finding.
// Scenario AZ -- a later round that breaks an earlier round's fix is caught by
// re-running every settled reproducer at that round's own head, whatever any
// lens reported. With no round left the run halts on the reopened finding, and
// says it hit the round limit: every reopen happens inside the loop, so the
// "should not happen" fallback in fixStopReason stays unreachable.
async function scenarioAZ() {
  console.log('\n== scenario AZ: a fix a later round breaks reopens and halts at Fix')
  const { result, captured } = await run({
    args: { maxReviewRounds: 2 },
    draftPr: { opened: true, number: 24, url: 'https://example.invalid/pr/24', detail: 'stub draft' },
    initialReview: {
      correctness: [
        { title: 'Route resolves from cwd', file: 'src/route.js', claim: 'wrong repo', evidence: 'route.js:12' },
        { title: 'Missing guard', file: 'src/guard.js', claim: 'no guard', evidence: 'guard.js:3' },
      ],
      advocate: [],
    },
    verify: (id, round) => id === 'f1' ? round === 1 : (id === 'f2' ? round === 2 : undefined),
    settledExit: (id, round) => (id === 'f1' && round === 2 ? 1 : 0),
    fixHead: (round) => `fix0000000000000000000000000000000000000${round}`,
    tailReview: [],
    staleness: () => [],
  })
  check('halted at Fix rather than readying the PR', result.halted_at, 'Fix')
  check('only the regressed finding is unresolved', result.unresolved_findings?.length, 1)
  check('it is the finding round 1 fixed', result.unresolved_findings?.[0]?.file, 'src/route.js')
  check('the stop reason is the round limit, not the "should not happen" fallback',
    /2-round limit/.test(result.stopped_because ?? ''), true)
  check('nothing was settled before round 1, so no settled recheck ran there',
    callCount(captured, 'reproduce:settled:1'), 0)
  check('round 2 re-ran what round 1 settled', callCount(captured, 'reproduce:settled:2'), 1)
}

// Scenario BA -- the settled recheck is not gated on budget: silently trusting
// a fix nobody re-checked is worse than one more cheap dispatch, so it runs
// even in a round where the rest of the run reads as out of budget.
async function scenarioBA() {
  console.log('\n== scenario BA: the settled recheck still runs once the run is otherwise out of budget')
  let exhausted = false
  const { captured } = await run({
    args: { maxReviewRounds: 2 },
    budget: { total: 200000, spent: () => 0, remaining: () => (exhausted ? 100 : 999999) },
    draftPr: { opened: true, number: 25, url: 'https://example.invalid/pr/25', detail: 'stub draft' },
    initialReview: {
      correctness: [
        { title: 'Route resolves from cwd', file: 'src/route.js', claim: 'wrong repo', evidence: 'route.js:12' },
        { title: 'Missing guard', file: 'src/guard.js', claim: 'no guard', evidence: 'guard.js:3' },
      ],
      advocate: [],
    },
    verify: (id, round) => id === 'f1' ? round === 1 : (id === 'f2' ? round === 2 : undefined),
    fixHead: (round) => { if (round === 2) exhausted = true; return `fix0000000000000000000000000000000000000${round}` },
    tailReview: [],
    staleness: () => [],
  })
  check('the budget really was out: round 2 got no tail review', callCount(captured, 'review:fix:2'), 0)
  check('the settled recheck still ran in round 2', callCount(captured, 'reproduce:settled:2'), 1)
}

// Scenario BU -- #38: a check green at the base commit and red after
// Implement (the version-bump incident this ticket is about) is fixed in
// one checks-only round before Review ever runs, so the diff a reviewer
// reads already carries the fix and no reviewer finding is ever recorded.
async function scenarioBU() {
  console.log('\n== scenario BU: a check green at baseline and red after Implement is fixed before Review, with no reviewer finding')
  const { result, captured } = await run({
    args: { openPr: true },
    discovery: { file: '/repo/AGENTS.md',
      sections: [{ heading: '## Checks', fence: 'bash scripts/run-tests.sh' }], detail: 'stub' },
    checkRuns: (attempt) => attempt === 1
      ? { results: [checkRow('check:1', 'bash scripts/run-tests.sh', 0, 'ok')], dirty: false }
      : attempt === 2
      ? { results: [checkRow('check:1', 'bash scripts/run-tests.sh', 1,
          'FAILURE: workflows/ changed with no version bump')], dirty: false }
      : { results: [checkRow('check:1', 'bash scripts/run-tests.sh', 0, 'OK')], dirty: false },
    checksFixResult: { head_sha: 'checksfix00000000000000000000000000000002',
      note: 'bumped the version', scored: true },
    prResult: { opened: true, url: 'https://example.invalid/pr/38', note: 'stub ready' },
  })
  check('the baseline ran green, before Implement', callCount(captured, 'checks:run:1'), 1)
  const checksFix = captured.calls.find(c => c.label === 'checks:fix')?.prompt ?? ''
  check('the checks-only fix ran', checksFix.length > 0, true)
  check('the fix prompt carries the failing check\'s command',
    checksFix.includes('bash scripts/run-tests.sh'), true)
  check('the fix prompt carries its exit code', checksFix.includes('exited 1'), true)
  check('the fix prompt carries its output verbatim',
    checksFix.includes('FAILURE: workflows/ changed with no version bump'), true)
  check('the check was re-run after the pre-review fix landed', callCount(captured, 'checks:run:3'), 1)
  const checksFixIdx = captured.calls.findIndex(c => c.label === 'checks:fix')
  const reviewIdx = captured.calls.findIndex(c => c.label.startsWith('review:'))
  check('the checks-only fix ran before any review lens',
    checksFixIdx >= 0 && reviewIdx >= 0 && checksFixIdx < reviewIdx, true)
  const reviewPrompt = captured.calls.find(c => c.label.startsWith('review:'))?.prompt ?? ''
  check('a review lens ran', reviewPrompt.length > 0, true)
  check('review reads the fixed range, including the checks-only commit',
    reviewPrompt.includes('checksfix00000000000000000000000000000002'), true)
  check('the run does not halt', result.halted_at, undefined)
  check('no reviewer finding was recorded for the check', (result.unresolved_findings ?? []).length, 0)
  check('the result reports the check as no longer red', result.checks?.red?.length, 0)
  check('the run reaches the PR phase', result.pr?.opened, true)
}

// Scenario BV -- #38: a check red at the base commit, before any work
// started, is the repo's own environment, not this run's doing. It must be
// dropped outright, never merely downgraded, so it cannot re-enter later as
// something an unrelated fix round is told to act on.
async function scenarioBV() {
  console.log('\n== scenario BV: a check red at baseline is dropped as environmental and never reaches a fixer')
  const { result, captured } = await run({
    args: { maxReviewRounds: 1 },
    discovery: { file: '/repo/AGENTS.md',
      sections: [{ heading: '## Checks', fence: 'bash scripts/run-go-tests.sh' }], detail: 'stub' },
    checkRuns: () => ({ results: [checkRow('check:1', 'bash scripts/run-go-tests.sh', 1,
      'go: command not found')], dirty: false }),
    initialReview: {
      correctness: [{ title: 'Off-by-one', file: 'src/parser.js',
        claim: 'boundary is wrong', evidence: 'parser.js:12' }],
      advocate: [],
    },
    verify: () => undefined,
    fixHead: () => 'fix00000000000000000000000000000000000003',
    staleness: () => [],
  })
  check('the baseline ran exactly once', callCount(captured, 'checks:run:1'), 1)
  check('nothing was re-checked after Implement, nothing left to check', callCount(captured, 'checks:run:2'), 0)
  check('the checks-only pre-review fix never ran', callCount(captured, 'checks:fix'), 0)
  check('halted at Fix, over the unrelated finding, not a check', result.halted_at, 'Fix')
  const fix1 = captured.calls.find(c => c.label === 'fix:1')?.prompt ?? ''
  check('the fix phase ran', fix1.length > 0, true)
  check('the dropped check\'s command never reaches the fixer',
    fix1.includes('run-go-tests.sh'), false)
  check('the result explains it was dropped, not left open',
    (result.checks?.detail ?? '').includes('dropped 1 as environmental'), true)
  check('no red check is reported', result.checks?.red?.length, 0)
}

// Scenario CA -- a discovered check may write: a ledger, a generated file, a
// marker. The baseline runs it against the tree the implementer is about to
// be handed, so a write there lands in the change under review as work nobody
// did. Refusing is the only safe answer; the pipeline cannot undo it.
async function scenarioCA() {
  console.log('\n== scenario CA: a check that dirties the tree during the baseline halts before Implement')
  const { result, captured } = await run({
    discovery: { file: '/repo/AGENTS.md',
      sections: [{ heading: '## Checks', fence: 'bash gen.sh' }], detail: 'stub' },
    checkRuns: () => ({ results: [checkRow('check:1', 'bash gen.sh', 0, 'ok')],
      dirty: true, porcelain: '?? generated.txt' }),
  })
  check('halted before any implementation ran', result.halted_at, 'Implement')
  check('the implementer never ran', callCount(captured, 'implementer'), 0)
  check('the note names what the check wrote',
    (result.note ?? '').includes('?? generated.txt'), true)
  check('the note says it happened before implementation, not during it',
    (result.note ?? '').includes('before any implementation ran'), true)
  check('no check is reported red: the baseline itself was green',
    result.checks?.red?.length, 0)
}

// Scenario CB -- #116: asked to run several commands and report every byte of
// their output, a cheap agent dropping a row is the expected failure, not a
// rare one. A row nobody reported is not evidence either way -- runChecks
// retries it once, and a check still unreported after that halts, since a
// fixer cannot change what the runner echoes back.
async function scenarioCB() {
  console.log('\n== scenario CB: a check the runner never reports on halts after a retry, never reaches a fixer')
  const { result, captured } = await run({
    discovery: { file: '/repo/AGENTS.md',
      sections: [{ heading: '## Checks', fence: 'bash a.sh\nbash b.sh' }], detail: 'stub' },
    checkRuns: (attempt) => attempt === 1
      ? ({ results: [checkRow('check:1', 'bash a.sh', 0, 'ok'),
                     checkRow('check:2', 'bash b.sh', 0, 'ok')] })
      : ({ results: [checkRow('check:1', 'bash a.sh', 0, 'ok')] }),
    initialReview: { correctness: [], advocate: [] },
    verify: () => undefined,
    staleness: () => [],
  })
  check('halted at Implement: measurement, not the code', result.halted_at, 'Implement')
  check('the post-Implement run happened', callCount(captured, 'checks:run:2'), 1)
  check('the retry happened once', callCount(captured, 'checks:run:3'), 1)
  check('no third attempt was made', callCount(captured, 'checks:run:4'), 0)
  check('the checks-only fixer never ran', callCount(captured, 'checks:fix'), 0)
  check('no fix round ever ran', callCount(captured, 'fix:1'), 0)
  check('the unreported check is the one named', result.checks?.unmeasured?.[0]?.id, 'check:2')
  check('its expected invocation is named',
    (result.note ?? '').includes(checkInvocation('check:2', 'bash b.sh')), true)
  check('it says no result was reported, on either attempt',
    (result.note ?? '').includes('no result reported'), true)
  check('the halt says it is about measurement, not the code',
    (result.note ?? '').includes('not the code'), true)
  check('the reported green check is never in the unmeasured list',
    (result.checks?.unmeasured ?? []).some(c => c.id === 'check:1'), false)
  check('no check is reported red', result.checks?.red?.length, 0)
}

// Scenario BW -- #38: most repos have never heard of any of this. Discovery
// finding nothing must be a logged, ordinary outcome, never a halt, and must
// not spend a check-run call it has nothing to run.
async function scenarioBW() {
  console.log('\n== scenario BW: discovery finding no repo checks is logged, not a halt')
  const { result, captured } = await run({})
  check('checks:discover is never dispatched as its own call', callCount(captured, 'checks:discover'), 0)
  check('no check-run call was made', callCount(captured, 'checks:run:1'), 0)
  check('the run does not halt', result.halted_at, undefined)
  check('discovery finding nothing is logged',
    captured.logs.some(l => /no repo-advertised checks found/.test(l)), true)
  check('the final result reports zero discovered checks', result.checks?.discovered, 0)
}

// Scenario BX -- #38, #87: existingBranch resumes a worktree that already
// carries the branch's own commits, so there is no clean base tree left to
// classify a check against. A red check there is reported, never blocking.
async function scenarioBX() {
  console.log('\n== scenario BX: existingBranch skips the baseline and never blocks on a discovered check')
  const { result, captured } = await run({
    args: { existingBranch: true, openPr: true },
    discovery: { file: '/repo/AGENTS.md',
      sections: [{ heading: '## Checks', fence: 'bash scripts/lint.sh' }], detail: 'stub' },
    checkRuns: () => ({ results: [checkRow('check:1', 'bash scripts/lint.sh', 1,
      'lint: 3 problems')], dirty: false }),
    prResult: { opened: true, url: 'https://example.invalid/pr/38x', note: 'stub ready' },
  })
  const runLabels = captured.calls.filter(c => c.label.startsWith('checks:run:'))
  check('exactly one check run happened, no separate baseline pass', runLabels.length, 1)
  check('the checks-only pre-review fix never ran', callCount(captured, 'checks:fix'), 0)
  check('the run does not halt', result.halted_at, undefined)
  check('the check is reported as non-blocking', result.checks?.blocking, false)
  check('the check is still reported red, for visibility', result.checks?.red?.length, 1)
  check('the run reaches the PR phase', result.pr?.opened, true)
}

// Scenario BY -- #38: a cap stated only in a prompt is a request; this
// proves the bound is a real slice. Both ends of a huge check's output must
// survive, since a gate prints its resolved repo and branch first and its
// verdict last, and only the middle is safe to drop.
async function scenarioBY() {
  console.log('\n== scenario BY: oversized check output is truncated with head and tail kept, middle marked')
  const bigOutput = 'HEAD_MARKER' + 'x'.repeat(5000) + 'MIDDLE_MARKER_XYZ' + 'y'.repeat(15000) + 'TAIL_MARKER'
  const { captured } = await run({
    discovery: { file: '/repo/AGENTS.md',
      sections: [{ heading: '## Checks', fence: 'bash scripts/run-tests.sh' }], detail: 'stub' },
    checkRuns: (attempt) => attempt === 1
      ? { results: [checkRow('check:1', 'bash scripts/run-tests.sh', 0, 'ok')], dirty: false }
      : { results: [checkRow('check:1', 'bash scripts/run-tests.sh', 1, bigOutput)], dirty: false },
  })
  const checksFix = captured.calls.find(c => c.label === 'checks:fix')?.prompt ?? ''
  check('the pre-review fix ran', checksFix.length > 0, true)
  check('the head of the output survives', checksFix.includes('HEAD_MARKER'), true)
  check('the tail of the output survives', checksFix.includes('TAIL_MARKER'), true)
  check('the truncation marker is present', checksFix.includes('[touchstone: truncated,'), true)
  check('the middle of the output does not reach the prompt',
    checksFix.includes('MIDDLE_MARKER_XYZ'), false)
}

// Scenario BZ -- #38: redness is keyed on the check's own exit line. AGENTS.md
// is explicit that exit 2 and exit 4 are not passes either, and the schema
// carries no pass/fail field a model could misjudge one against.
async function scenarioBZ() {
  console.log('\n== scenario BZ: a non-zero exit code (4, could-not-measure) is treated as red')
  const { captured } = await run({
    discovery: { file: '/repo/AGENTS.md',
      sections: [{ heading: '## Checks', fence: 'bash scripts/coverage-gate.sh' }], detail: 'stub' },
    checkRuns: (attempt) => attempt === 1
      ? { results: [checkRow('check:1', 'bash scripts/coverage-gate.sh', 0, 'ok')], dirty: false }
      : { results: [checkRow('check:1', 'bash scripts/coverage-gate.sh', 4, 'could not measure')], dirty: false },
  })
  check('a check that merely ran, exit 4, still triggers the pre-review fix', callCount(captured, 'checks:fix'), 1)
  const checksFix = captured.calls.find(c => c.label === 'checks:fix')?.prompt ?? ''
  check('the fix phase ran', checksFix.length > 0, true)
  check('the prompt carries the exit code verbatim', checksFix.includes('exited 4'), true)
}

// Scenario CC -- #44: a locus a reviewer already read reaches the fix brief
// verbatim, so the fixer can open the location directly. A single-line span
// (line_end === line_start) must not render a redundant N-N range.
async function scenarioCC() {
  console.log('\n== scenario CC: a finding\'s locus reaches the fix brief with its file and line span')
  const { result, captured } = await run({
    initialReview: {
      correctness: [
        { title: 'Off-by-one span', file: 'src/parser.js', claim: 'boundary is wrong',
          evidence: 'parser.js:12', line_start: 12, line_end: 18 },
        { title: 'Single-line span', file: 'src/other.js', claim: 'wrong guard',
          evidence: 'other.js:40', line_start: 40, line_end: 40 },
      ],
      advocate: [],
    },
    verify: (id) => (id === 'f1' || id === 'f2') ? true : undefined,
  })
  const fix1 = captured.calls.find(c => c.label === 'fix:1')?.prompt ?? ''
  check('the fix phase ran', fix1.length > 0, true)
  check('a multi-line locus reaches the fix brief', fix1.includes('src/parser.js:12-18'), true)
  check('a single-line locus reaches the fix brief', fix1.includes('src/other.js:40'), true)
  check('the single-line locus is not rendered as a 40-40 range', fix1.includes('src/other.js:40-40'), false)
  check('halted_at is absent (both findings verified fixed)', result.halted_at, undefined)
}

// Scenario CD -- #44: the fix brief used to tell the fixer to read the whole
// commit range for context. That instruction is gone; the locus replaces it.
async function scenarioCD() {
  console.log('\n== scenario CD: the fix brief no longer tells the agent to read the whole commit range for context')
  const { captured } = await run({
    initialReview: {
      correctness: [{ title: 'Needs a fix', file: 'a.js', claim: 'c', evidence: 'e',
        line_start: 5, line_end: 9 }],
      advocate: [],
    },
    verify: (id) => id === 'f1' ? true : undefined,
  })
  const fix1 = captured.calls.find(c => c.label === 'fix:1')?.prompt ?? ''
  check('the fix phase ran', fix1.length > 0, true)
  check('the old whole-range-for-context instruction is gone',
    fix1.includes('read that diff for context'), false)
  check('the fix brief carries the locus instead', fix1.includes('a.js:5-9'), true)
}

// Scenario CE -- #44: verify used to be given no range at all (an implicit,
// unbounded read of the whole tree). It is now judged against exactly the
// diff the fix round it follows produced.
async function scenarioCE() {
  console.log('\n== scenario CE: the reproduce step fetches exactly the fix round\'s own diff')
  const { captured } = await run({
    initialReview: {
      correctness: [{ title: 'Needs a fix', file: 'a.js', claim: 'c', evidence: 'e',
        line_start: 5, line_end: 9 }],
      advocate: [],
    },
    verify: (id) => id === 'f1' ? true : undefined,
    fixHead: () => 'fix00000000000000000000000000000000000001',
  })
  const reproduce1 = captured.calls.find(c => c.label === 'reproduce:fix:1')?.prompt ?? ''
  check('the reproduce step ran', reproduce1.length > 0, true)
  check('it is handed exactly this round\'s diff',
    reproduce1.includes(`--no-color ${REVIEWED_THROUGH}..fix00000000000000000000000000000000000001`), true)
}

// Scenario CJ -- a fix round that commits nothing leaves HEAD where it was,
// and <sha>..<sha> is an empty diff: the verifier would be told to judge
// against nothing, and any uncommitted work the fixer left would be invisible.
// The bare SHA compares that commit to the working tree instead.
async function scenarioCJ() {
  console.log('\n== scenario CJ: a round that committed nothing verifies against the tree, not an empty range')
  const { captured } = await run({
    initialReview: {
      correctness: [{ title: 'Needs a fix', file: 'a.js', claim: 'c', evidence: 'e',
        line_start: 5, line_end: 9 }],
      advocate: [],
    },
    verify: (id) => id === 'f1' ? true : undefined,
    fixHead: () => REVIEWED_THROUGH,
  })
  const reproduce1 = captured.calls.find(c => c.label === 'reproduce:fix:1')?.prompt ?? ''
  check('the reproduce step ran', reproduce1.length > 0, true)
  check('the range is not an empty self-comparison',
    reproduce1.includes(`${REVIEWED_THROUGH}..${REVIEWED_THROUGH}`), false)
  check('it diffs the bare commit against the working tree instead',
    reproduce1.includes(`--no-color ${REVIEWED_THROUGH} and return`), true)
}

// Scenario CK -- the per-round figure is this ticket's measurement
// instrument, so its arithmetic has to be pinned, not just its presence: a
// stub budget that never moves makes any expression look right. This one
// charges a fixed amount per agent call, so only the fix agent's own delta
// gives the expected number.
async function scenarioCK() {
  console.log('\n== scenario CK: fix_round_output is the fix agent\'s own delta, not a running total')
  const { result } = await run({
    args: { maxReviewRounds: 1 },
    budgetPerAgentCall: 100,
    initialReview: {
      correctness: [{ title: 'Still open', file: 'a.js', claim: 'c', evidence: 'e',
        line_start: 5 }],
      advocate: [],
    },
    verify: () => undefined,
    staleness: () => [],
  })
  const entry = result.fix_round_output?.[0]
  check('one round was recorded', result.fix_round_output?.length, 1)
  check('the figure is positive: a reversed subtraction reads negative',
    entry?.output > 0, true)
  // Exactly one agent call inside the measured window. The running total at
  // that point is a far larger multiple, and a reversed subtraction is
  // negative, so both read differently from this.
  check('it spans exactly one agent call: the fixer, and nothing before it',
    entry?.output, 100)
}

const SCENARIOS = [scenarioBH, scenarioBI, scenarioBJ, scenarioBK, scenarioBL, scenarioBM, scenarioBN, scenarioBO, scenarioBP, scenarioBQ, scenarioBR, scenarioBS, scenarioBT, scenarioAZ, scenarioBA, scenarioBU, scenarioBV, scenarioCA, scenarioCB, scenarioBW, scenarioBX, scenarioBY, scenarioBZ, scenarioCC, scenarioCD, scenarioCE, scenarioCJ, scenarioCK]
JS_EOF

finish
