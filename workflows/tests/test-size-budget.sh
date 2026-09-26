#!/usr/bin/env bash
# The run-wide token budget (gh-118): how runBudget is derived from triage,
# how dispatch() refuses a call past it, and how that refusal reaches a halt
# rather than reading as a clean run. New for this ticket, not split out of
# test-fix-loop-join.sh; see harness.sh for the shared scenario runner.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/harness.sh"

# Real scratch repo for scenario SBW: a PHP 8 attribute and a Go pointer write,
# neither of which is a comment in a language the gates support.
COMMENT_REPO="$WORK/comment-heuristic"
git init -q "$COMMENT_REPO"
git -C "$COMMENT_REPO" config user.email test@example.com
git -C "$COMMENT_REPO" config user.name test
git -C "$COMMENT_REPO" config commit.gpgsign false
printf 'x\n' > "$COMMENT_REPO/README"
git -C "$COMMENT_REPO" add -A
git -C "$COMMENT_REPO" commit -qm "initial"
mkdir -p "$COMMENT_REPO/src"
cat > "$COMMENT_REPO/src/Order.php" <<'PHP'
<?php
#[ORM\Entity]
final class Order
{
    #[ORM\Id]
    #[ORM\Column(type: 'integer')]
    private int $id;
}
PHP
cat > "$COMMENT_REPO/src/set.go" <<'GO'
package src

func Set(p *int, v int) {
	*p = v
}
GO
git -C "$COMMENT_REPO" add -A
git -C "$COMMENT_REPO" commit -qm "add PHP attributes and a Go pointer write"
export COMMENT_REPO

run_js_scenarios <<'JS_EOF'
// Scenario SBA -- the formula: 100_000 + 1_500 * estimated_loc, logged so a run
// states what it derived and why.
async function scenarioSBA() {
  console.log('\n== scenario SBA: the run budget follows triage\'s estimated_loc')
  const { captured } = await run({
    args: { runBudget: undefined },
    triage: { estimated_loc: 300 },
    initialReview: { correctness: [], advocate: [] },
    verify: () => undefined,
    staleness: () => [],
  })
  check('the derived budget is logged', captured.logs.some(l => /run budget: 550k output tokens \(derived/.test(l)), true)
}

// Scenario SBB -- the derived figure is clamped at the floor: a tiny estimate
// still gets at least 150k, since even a one-line change spends a few calls
// on setup, triage, implement and review.
async function scenarioSBB() {
  console.log('\n== scenario SBB: a tiny estimated_loc clamps the derived budget to the 150k floor')
  const { captured } = await run({
    args: { runBudget: undefined },
    triage: { estimated_loc: 1 },
    initialReview: { correctness: [], advocate: [] },
    verify: () => undefined,
    staleness: () => [],
  })
  check('the budget is clamped up to 150k', captured.logs.some(l => /run budget: 150k output tokens/.test(l)), true)
}

// Scenario SBC -- and clamped at the ceiling: a huge estimate does not buy an
// unbounded run.
async function scenarioSBC() {
  console.log('\n== scenario SBC: a huge estimated_loc clamps the derived budget to the 800k ceiling')
  const { captured } = await run({
    args: { runBudget: undefined },
    triage: { estimated_loc: 10000 },
    initialReview: { correctness: [], advocate: [] },
    verify: () => undefined,
    staleness: () => [],
  })
  check('the budget is clamped down to 800k', captured.logs.some(l => /run budget: 800k output tokens/.test(l)), true)
}

// Scenario SBD -- no estimate at all falls back to a flat default by scope,
// never to the formula with a missing number silently read as zero.
async function scenarioSBD() {
  console.log('\n== scenario SBD: a missing estimated_loc falls back to the inline default')
  const { captured } = await run({
    args: { runBudget: undefined },
    triage: { estimated_loc: undefined },
    initialReview: { correctness: [], advocate: [] },
    verify: () => undefined,
    staleness: () => [],
  })
  check('the inline default (150k) is used, not a formula on a missing number',
    captured.logs.some(l => /run budget: 150k output tokens \(triage gave no estimated_loc; using the inline default\)/.test(l)), true)
}

// Scenario SBE -- the team-scoped default is higher, and a numeric
// args.runBudget overrides the derivation outright, formula or fallback.
async function scenarioSBE() {
  console.log('\n== scenario SBE: an explicit args.runBudget replaces the derived value')
  const { captured } = await run({
    args: { runBudget: 12345 },
    triage: { scope: 'team', estimated_loc: undefined },
    initialReview: { correctness: [], advocate: [] },
    verify: () => undefined,
    staleness: () => [],
  })
  check('the explicit value is used, not the team default',
    captured.logs.some(l => /run budget: 12k output tokens \(set explicitly via args\.runBudget\)/.test(l)), true)
}

// Scenario SBF -- the refusal itself: dispatch() checks budget.spent() before
// every call, so the very next dispatch past the budget never runs, and the
// stage it would have run under is still open when the halt fires -- its
// spend so far has to reach stage_spend the same as a stage that closed
// normally, or the accounting silently loses whatever that stage spent.
async function scenarioSBF() {
  console.log('\n== scenario SBF: a spent-out budget refuses the next dispatch and reports it, with the open stage in stage_spend')
  const { result, captured } = await run({
    args: { runBudget: 250_000 },
    budgetPerAgentCall: 100_000,
  })
  check('halted at Implement, the phase the refused dispatch belongs to', result.halted_at, 'Implement')
  check('the implementer was never dispatched', callCount(captured, 'implementer'), 0)
  check('the note names the refused label', (result.note ?? '').includes("'implementer'"), true)
  check('the note names the spend at the halt', (result.note ?? '').includes('300k'), true)
  check('the note explains this is a budget halt, not a code problem',
    (result.note ?? '').includes('Run budget exhausted'), true)
  check('the open implement stage reached stage_spend', typeof result.stage_spend?.implement, 'number')
  check('the closed triage stage is still reported too', typeof result.stage_spend?.triage, 'number')
  check('the note lists the still-open stage', (result.note ?? '').includes('still in progress'), true)
  // The note is what commands/deliver.md tells the invoking session to report
  // verbatim; stage_spend sitting only in the payload leaves the per-stage
  // spend invisible to whoever reads the note instead.
  check('the note gives the closed triage stage\'s own spend',
    new RegExp(`triage \\d+k`).test(result.note ?? ''), true)
  check('the note gives the still-open implement stage\'s own spend',
    new RegExp(`implement \\d+k`).test(result.note ?? ''), true)
}

// Scenario SBG -- gh-118: a budget refusal inside one of two lenses running
// in parallel used to be indistinguishable from that lens legitimately
// finding nothing, because parallel() (the runtime) catches a thunk's own
// throw and hands back null either way. Left unchecked, a review where one
// lens got refused mid-flight would read as a clean pass instead of halting.
async function scenarioSBG() {
  console.log('\n== scenario SBG: a budget refusal inside a parallel review lens halts, rather than reading as a clean review')
  const { result, captured } = await run({
    args: { runBudget: 550 },
    budgetPerAgentCall: 100,
    initialReview: { correctness: [], advocate: [] },
  })
  check('halted at Review, not a clean pass', result.halted_at, 'Review')
  check('the note names the refused lens', (result.note ?? '').includes('review:advocate'), true)
  check('the run never reached the PR phase', callCount(captured, 'pr'), 0)
}

// Scenario SBH -- a single file under the inline bar gets no lenses at all,
// the files<=1/totalChurn case in lensKeysFor.
async function scenarioSBH() {
  console.log('\n== scenario SBH: a tiny one-file diff gets no reviewer lenses')
  const { result, captured } = await run({
    diffstatFiles: [['a.js', 5, 0]],
  })
  check('no review lens ran', captured.calls.some(c => c.label.startsWith('review:')), false)
  check('the run does not halt', result.halted_at, undefined)
  check('the result reports zero reviewers', result.reviewers, 0)
}

// Scenario SBI -- under ONE_LENS_LOC a single correctness lens runs, and with
// fewer than two reviewers review:dedup is skipped by the guard it already
// has (reviewerCount < 2), so a small diff pays for neither a second lens
// nor the dedup call.
async function scenarioSBI() {
  console.log('\n== scenario SBI: a small diff (2 files, under ONE_LENS_LOC) runs correctness only, no dedup')
  const { captured } = await run({
    diffstatFiles: [['a.js', 50, 0], ['b.js', 50, 0]],
  })
  check('correctness ran', captured.calls.some(c => c.label === 'review:correctness'), true)
  check('advocate did not run', captured.calls.some(c => c.label === 'review:advocate'), false)
  check('review:dedup never ran', callCount(captured, 'review:dedup'), 0)
}

// Scenario SBJ -- between ONE_LENS_LOC and BIG_LOC, with at most BIG_FILES
// code files, correctness and the devil's advocate both run.
async function scenarioSBJ() {
  console.log('\n== scenario SBJ: a mid-sized diff runs correctness and advocate')
  const { result } = await run({
    diffstatFiles: [['a.js', 100, 0], ['b.js', 100, 0]],
  })
  check('two reviewers', result.reviewers, 2)
}

// Scenario SBK -- past BIG_LOC, or past BIG_FILES code files, the
// requirements lens joins the other two.
async function scenarioSBK() {
  console.log('\n== scenario SBK: a big diff (codeChurn > BIG_LOC) adds the requirements lens')
  const { result, captured } = await run({
    diffstatFiles: [['a.js', 500, 0]],
    ticketResult: { found: true, summary: 's', description: 'the ticket', comments: '' },
  })
  check('three reviewers', result.reviewers, 3)
  check('the requirements lens ran', captured.calls.some(c => c.label === 'review:requirements'), true)
}

// Scenario SBL -- more than BIG_FILES code files also trips the big case,
// even when each file's own churn is small.
async function scenarioSBL() {
  console.log('\n== scenario SBL: more than BIG_FILES code files also adds the requirements lens, even under BIG_LOC')
  const { result } = await run({
    // codeChurn = 6*30 = 180, between ONE_LENS_LOC and BIG_LOC: only the
    // file count (6 > BIG_FILES) should be why this promotes to three.
    diffstatFiles: [['a.js', 30, 0], ['b.js', 30, 0], ['c.js', 30, 0], ['d.js', 30, 0], ['e.js', 30, 0], ['f.js', 30, 0]],
  })
  check('three reviewers', result.reviewers, 3)
}

// Scenario SBM -- a diffstat probe that never produces a well-formed
// response (neither the first call nor its one retry) halts at Review as a
// measurement problem, never reaching a lens.
async function scenarioSBM() {
  console.log('\n== scenario SBM: an unmeasurable diffstat halts after one retry, never reaching a lens')
  const { result, captured } = await run({
    sizeUnmeasured: true,
  })
  check('halted at Review', result.halted_at, 'Review')
  check('the retry ran exactly once', callCount(captured, 'size'), 1)
  check('no review lens ran', captured.calls.some(c => c.label.startsWith('review:')), false)
  check('the note says this is a measurement problem', (result.note ?? '').includes('measurement problem'), true)
}

// Scenario SBN -- a diffstat whose begin line names a different range than
// the one asked about is unmeasured too, not silently accepted; it still
// gets its retry, which recovers here since the retry names the right range.
async function scenarioSBN() {
  console.log('\n== scenario SBN: a diffstat naming the wrong range counts as unmeasured, retried and recovered')
  const { result, captured } = await run({
    diffstat: 'TOUCHSTONE_DIFFSTAT wrong..range\n100\t0\ta.js\nTOUCHSTONE_COMMENT_LINES\nTOUCHSTONE_DIFFSTAT_END',
  })
  check('the retry ran exactly once', callCount(captured, 'size'), 1)
  check('the run recovered rather than halting', result.halted_at, undefined)
}

// Scenario SBO -- the ratio halt: support code (here, a test file) far
// outweighing the actual code halts before any lens runs, and the note
// carries every count and the limit.
async function scenarioSBO() {
  console.log('\n== scenario SBO: support code outweighing the actual change halts before any lens runs')
  const { result, captured } = await run({
    diffstatFiles: [['a.js', 20, 0], ['tests/x.js', 300, 0]],
  })
  check('halted at Review', result.halted_at, 'Review')
  check('no review lens ran', captured.calls.some(c => c.label.startsWith('review:')), false)
  check('the note carries the code count', (result.note ?? '').includes('20 code'), true)
  check('the note carries the test count', (result.note ?? '').includes('300 test'), true)
  check('the note carries the computed ratio', (result.note ?? '').includes('15.0:1'), true)
  check('the note carries the limit', (result.note ?? '').includes('10:1 limit'), true)
  check('the note names the override', (result.note ?? '').includes('args.supportRatio'), true)
}

// Scenario SBP -- below RATIO_MIN_CODE the ratio never applies, which is
// what lets a change that is mostly tests by design (an ordinary TDD change)
// through without halting.
async function scenarioSBP() {
  console.log('\n== scenario SBP: a tests-only change under the code floor does not trip the ratio halt')
  const { result } = await run({
    diffstatFiles: [['a.js', 5, 0], ['tests/x.js', 500, 0]],
  })
  check('the run does not halt on the ratio', (result.note ?? '').includes('Support code outweighs'), false)
}

// Scenario SBQ -- args.supportRatio raises the limit for a run that knows
// its own ratio is intentional.
async function scenarioSBQ() {
  console.log('\n== scenario SBQ: args.supportRatio raises the ratio limit past what would otherwise halt')
  const { result } = await run({
    args: { supportRatio: 20 },
    diffstatFiles: [['a.js', 20, 0], ['tests/x.js', 300, 0]],
  })
  check('the run does not halt', result.halted_at, undefined)
}

// Scenario SBR -- gh-118: an involved verdict with no reason, files or call
// sites demotes to routine; the log names why.
async function scenarioSBR() {
  console.log('\n== scenario SBR: an unjustified involved verdict demotes to routine, logged')
  const { captured } = await run({
    triage: { complexity: 'involved' },
  })
  check('the demotion is logged',
    captured.logs.some(l => /judged this involved without a reason/.test(l)), true)
  check('the summary reports routine, not involved',
    captured.logs.some(l => /triage judged this routine/.test(l)), true)
}

// Scenario SBS -- a justified involved verdict stands, and the log names the
// reason, the files, and the call sites.
async function scenarioSBS() {
  console.log('\n== scenario SBS: a justified involved verdict stands, with its reason, files and call sites logged')
  const { captured } = await run({
    triage: {
      complexity: 'involved',
      involved_reason: 'touches the signing path',
      expected_files: ['hooks/crap-commit-gate.py'],
      expected_call_sites: ['resolve_repo_root'],
    },
  })
  check('the summary reports involved, not a demotion',
    captured.logs.some(l => /triage judged this involved/.test(l)), true)
  check('the justification is logged with its reason',
    captured.logs.some(l => l.includes('touches the signing path')), true)
  check('the justification names the expected file',
    captured.logs.some(l => l.includes('hooks/crap-commit-gate.py')), true)
  check('the justification names the expected call site',
    captured.logs.some(l => l.includes('resolve_repo_root')), true)
}

// Scenario SBT -- partial justification (a reason but no expected files or
// call sites) still demotes: all three are required, not just one.
async function scenarioSBT() {
  console.log('\n== scenario SBT: a reason alone, with no expected files or call sites, still demotes')
  const { captured } = await run({
    triage: { complexity: 'involved', involved_reason: 'feels risky' },
  })
  check('the demotion is logged',
    captured.logs.some(l => /judged this involved without a reason/.test(l)), true)
}

// Scenario SBU -- the unrecognised-value fallback is unaffected: a garbage
// complexity value still reads as involved unconditionally, since that case
// is not a judgement about difficulty at all.
async function scenarioSBU() {
  console.log('\n== scenario SBU: an unrecognised complexity value still falls back to involved, never demoted')
  const { captured } = await run({
    triage: { complexity: 'urgent' },
  })
  check('the unrecognised-value log still fires',
    captured.logs.some(l => /unrecognised complexity/.test(l)), true)
  check('the demotion log does not also fire',
    captured.logs.some(l => /judged this involved without a reason/.test(l)), false)
  check('the summary reports involved', captured.logs.some(l => /triage judged this involved/.test(l)), true)
}

// Scenario SBV -- gh-118: the merged setup call returning nothing at all (an
// agent-level failure, not just one sub-answer coming back unconfirmed)
// still degrades safely: no task fallback is needed here (the harness
// always supplies one), the version comparison stays uncompared, and the
// gate markers read as unconfirmed rather than the run crashing on a
// missing setupResult.
async function scenarioSBV() {
  console.log('\n== scenario SBV: the merged setup call returning nothing degrades safely')
  const { result, captured } = await run({
    setupFails: true,
    prResult: { opened: true, url: 'https://example.invalid/pr/21', note: 'stub ready' },
    args: { openPr: true },
    initialReview: { correctness: [], advocate: [] },
    verify: () => undefined,
    staleness: () => [],
  })
  check('the run does not crash or halt', result.halted_at, undefined)
  check('pipeline_version stays uncompared', result.pipeline_version?.mismatch, null)
  check('the gate is reported as not hook-enforced', result.gates?.bypass_blocked, false)
  check('the run still reaches the PR phase', result.pr?.opened, true)
}

// Scenario SBW -- the probe's comment-line count against a real scratch repo:
// a PHP 8 attribute and a Go pointer write are code, in languages the gates
// support, and must not be counted as comments. Runs the probe's own command,
// lifted from its draft-pr prompt, so this exercises the actual awk rather
// than a JS reimplementation of it.
async function scenarioSBW() {
  console.log('\n== scenario SBW: a PHP attribute and a Go pointer write are not counted as comments')
  const repo = process.env.COMMENT_REPO
  const git = (...a) => execFileSync('git', ['-C', repo, ...a], { encoding: 'utf8' }).trim()
  const realRange = `${git('rev-parse', 'HEAD~1')}..${git('rev-parse', 'HEAD')}`
  const probe = await run({})
  const draftPrompt = probe.captured.calls.find(c => c.label === 'draft-pr')?.prompt ?? ''
  const at = draftPrompt.indexOf('echo TOUCHSTONE_DIFFSTAT ')
  const cmd = draftPrompt.slice(at).split(COMMIT_RANGE).join(realRange)
    .split('/tmp/stub-worktree').join(repo)
  const real = execFileSync('bash', ['-c', cmd], { encoding: 'utf8' })
    .split(realRange).join(COMMIT_RANGE)
  const { result } = await run({ diffstat: real })
  check('no comment lines are counted', result.size?.comment, 0)
}

// Scenario SBX -- gh-118: the checks stage opens twice (the pre-Implement
// baseline, then the post-Implement run), and closeOpenStages() -- the path a
// budget halt takes when it fires while the stage is still open -- has to
// carry the baseline's spend forward the same way every normal close site
// already does by hand (checksPreSpend + ...), or a halt mid-post-window
// reports only the post-window's own spend and drops the baseline entirely.
async function scenarioSBX() {
  console.log('\n== scenario SBX: a budget halt mid-post-Implement-checks keeps the pre-Implement checks baseline in stage_spend')
  const { result, captured } = await run({
    args: { runBudget: 450_000 },
    budgetPerAgentCall: 100_000,
    discovery: { file: '/repo/AGENTS.md',
      sections: [{ heading: '## Checks', fence: 'bash scripts/run-tests.sh' }], detail: 'stub' },
    checkRuns: () => ({ results: [checkRow('check:1', 'bash scripts/run-tests.sh', 0, 'ok')], dirty: false }),
  })
  check('the baseline checks run was dispatched', callCount(captured, 'checks:run:1'), 1)
  check('the post-window checks run was refused', (result.note ?? '').includes("'checks:run:2'"), true)
  check('stage_spend.checks carries the baseline spend forward, not just the post-window\'s',
    result.stage_spend?.checks, 100_000)
  check('the note\'s own checks figure agrees with stage_spend',
    (result.note ?? '').includes('checks 100k'), true)
}

const SCENARIOS = [scenarioSBA, scenarioSBB, scenarioSBC, scenarioSBD, scenarioSBE, scenarioSBF, scenarioSBG,
  scenarioSBH, scenarioSBI, scenarioSBJ, scenarioSBK, scenarioSBL, scenarioSBM, scenarioSBN, scenarioSBO,
  scenarioSBP, scenarioSBQ, scenarioSBR, scenarioSBS, scenarioSBT, scenarioSBU, scenarioSBV, scenarioSBW,
  scenarioSBX]
JS_EOF

finish
