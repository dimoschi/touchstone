#!/usr/bin/env bash
# Scenarios scenarioDL..scenarioEG, split out of
# test-fix-loop-join.sh (gh-118); see harness.sh.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/harness.sh"

run_js_scenarios <<'JS_EOF'
// Scenario DL -- gh-106: the residual own-claim recheck used to select by
// hasCompleteReproducer alone, so a non-blocking category (docs, design,
// wording) could still reopen the run on its own claim.
async function scenarioDL() {
  console.log('\n== scenario DL: a residual note in a non-blocking category never reopens on its own claim')
  const { result } = await run({
    args: { maxReviewRounds: 1 },
    initialReview: {
      correctness: [{ title: 'Off-by-one in parser', file: 'src/parser.js',
        claim: 'boundary is wrong', evidence: 'parser.js:12' }],
      advocate: [],
    },
    verify: (id) => id === 'f1' ? true : (id === 'f2' ? false : undefined),
    fixHead: () => 'fix00000000000000000000000000000000000001',
    tailReview: [{ category: 'docs', title: 'Stale comment nearby', file: 'src/parser.js',
      claim: 'a variant the fix missed', evidence: 'parser.js:20', duplicate_of: 'f1' }],
    staleness: () => [],
  })
  check('the run finished rather than halting on a non-blocking residual', result.halted_at, undefined)
  check('the residual note stays recorded', result.notes?.some(n => n.reason === 'residual'), true)
}

// Scenario DM -- gh-106: the residual own-claim recheck used to treat a
// missing row or exit 126/127 (could not run) the same as a genuine failure,
// unlike disposeCandidates' identical rule for a fresh candidate.
async function scenarioDM() {
  console.log('\n== scenario DM: a residual note whose own reproducer could not run does not reopen either')
  const { result } = await run({
    args: { maxReviewRounds: 1 },
    initialReview: {
      correctness: [{ title: 'Off-by-one in parser', file: 'src/parser.js',
        claim: 'boundary is wrong', evidence: 'parser.js:12' }],
      advocate: [],
    },
    verify: (id, round) => id === 'f1' ? true : (id === 'f2' && round === 'residual' ? 127 : undefined),
    fixHead: () => 'fix00000000000000000000000000000000000001',
    tailReview: [{ title: 'A variant the fix missed', file: 'src/parser.js',
      claim: 'edge case at the far end', evidence: 'parser.js:22', duplicate_of: 'f1' }],
    staleness: () => [],
  })
  check('the run finished rather than halting on a could-not-run residual claim', result.halted_at, undefined)
}

// Scenario DN -- gh-106: the residual own-claim recheck had no hunks to
// apply classify()'s out-of-range rule against, so a claim far outside the
// fix's own hunks could still reopen the run.
async function scenarioDN() {
  console.log('\n== scenario DN: a residual note whose own claim sits outside this round\'s hunks does not reopen either')
  const { result } = await run({
    args: { maxReviewRounds: 1 },
    initialReview: {
      correctness: [{ title: 'Off-by-one in parser', file: 'src/parser.js',
        claim: 'boundary is wrong', evidence: 'parser.js:12' }],
      advocate: [],
    },
    verify: (id) => id === 'f1' ? true : (id === 'f2' ? false : undefined),
    fixHead: () => 'fix00000000000000000000000000000000000001',
    hunks: () => ['+++ b/src/parser.js', '@@ -100,5 +100,5 @@'],
    tailReview: [{ title: 'A variant the fix missed', file: 'src/parser.js',
      claim: 'edge case at the far end', evidence: 'parser.js:500', line_start: 500,
      duplicate_of: 'f1' }],
    staleness: () => [],
  })
  check('the run finished rather than halting on an out-of-range residual claim', result.halted_at, undefined)
}

// Scenario DO -- a residual never blocks, whatever its own fields claim. An
// unmet-criterion residual with an invented quote and a failing reproducer is
// the case where a second, hand-copied gate once disagreed with classify().
async function scenarioDO() {
  console.log('\n== scenario DO: a residual with an invented criterion quote and a failing reproducer is still only a note')
  const { result } = await run({
    args: { maxReviewRounds: 1 },
    ticketResult: { found: true, summary: 'stub', comments: '',
      description: 'Acceptance: the parser rejects an index past the end.' },
    initialReview: {
      correctness: [{ title: 'Off-by-one in parser', file: 'src/parser.js',
        claim: 'boundary is wrong', evidence: 'parser.js:12' }],
      advocate: [],
    },
    verify: (id) => id === 'f1' ? true : false,
    fixHead: () => 'fix00000000000000000000000000000000000001',
    tailReview: [{ category: 'unmet-criterion', title: 'Negative index accepted', file: 'src/parser.js',
      claim: 'negative indexes pass', evidence: 'parser.js:20', duplicate_of: 'f1',
      criterion_quote: 'the parser must reject every negative index outright' }],
    staleness: () => [],
  })
  check('the run did not halt', result.halted_at, undefined)
  check('the residual is a note',
    result.notes?.some(n => n.title === 'Negative index accepted' && n.reason === 'residual'), true)
}

// Scenario DP -- a fix the mutation commits undo is caught by re-running the
// settled reproducer at the mutation head, even when no lens reports it.
async function scenarioDP() {
  console.log('\n== scenario DP: a fix the mutation commits undo halts even when no lens reports it')
  const { result, captured } = await run(convergedWithSuspect({
    tailReview: [],
    postMutationReview: [],
    mutationResult: () => ({ green: true, head_sha: 'mut0000000000000000000000000000000000001', detail: 'stub green', scored: true }),
    settledExit: (id, round) => (id === 'f1' && round === 'mutation' ? 1 : 0),
  }))
  check('halted at Review', result.halted_at, 'Review')
  check('the undone fix is unresolved', result.unresolved_findings?.some(f => f.file === 'src/parser.js'), true)
  check('the settled recheck ran at the mutation head', callCount(captured, 'reproduce:settled:mutation'), 1)
}

// Scenarios DQ-DV -- #109: only a heading that equals '## Checks', trailing
// whitespace aside, is ever read as a check list. Each of these resembles it
// closely enough that a looser match would have caught it.
async function scenarioDQ() {
  console.log('\n== scenario DQ: a "## Commands" heading is not read as checks')
  const { result, captured } = await run({
    discovery: { file: '/repo/AGENTS.md',
      sections: [{ heading: '## Commands', fence: 'bash scripts/run-tests.sh' }], detail: 'stub' },
  })
  check('no check-run call was made', callCount(captured, 'checks:run:1'), 0)
  check('zero checks discovered', result.checks?.discovered, 0)
  check('the run does not halt', result.halted_at, undefined)
  check('a log line explains the ## Commands heading is no longer read as checks',
    captured.logs.some(l => l.includes('## Commands') && l.includes('no longer read as checks')), true)
}

async function scenarioDR() {
  console.log('\n== scenario DR: a "## Build & Development Commands" heading is not read as checks')
  const { result, captured } = await run({
    discovery: { file: '/repo/AGENTS.md',
      sections: [{ heading: '## Build & Development Commands', fence: 'bash scripts/run-tests.sh' }], detail: 'stub' },
  })
  check('no check-run call was made', callCount(captured, 'checks:run:1'), 0)
  check('zero checks discovered', result.checks?.discovered, 0)
  check('the run does not halt', result.halted_at, undefined)
}

async function scenarioDS() {
  console.log('\n== scenario DS: a "### Checks" heading (wrong level) is not read as checks')
  const { result, captured } = await run({
    discovery: { file: '/repo/AGENTS.md',
      sections: [{ heading: '### Checks', fence: 'bash scripts/run-tests.sh' }], detail: 'stub' },
  })
  check('no check-run call was made', callCount(captured, 'checks:run:1'), 0)
  check('zero checks discovered', result.checks?.discovered, 0)
  check('the run does not halt', result.halted_at, undefined)
}

async function scenarioDT() {
  console.log('\n== scenario DT: a "## checks" heading (wrong case) is not read as checks')
  const { result, captured } = await run({
    discovery: { file: '/repo/AGENTS.md',
      sections: [{ heading: '## checks', fence: 'bash scripts/run-tests.sh' }], detail: 'stub' },
  })
  check('no check-run call was made', callCount(captured, 'checks:run:1'), 0)
  check('zero checks discovered', result.checks?.discovered, 0)
  check('the run does not halt', result.halted_at, undefined)
}

async function scenarioDU() {
  console.log('\n== scenario DU: a "##Checks" heading (no space) is not read as checks')
  const { result, captured } = await run({
    discovery: { file: '/repo/AGENTS.md',
      sections: [{ heading: '##Checks', fence: 'bash scripts/run-tests.sh' }], detail: 'stub' },
  })
  check('no check-run call was made', callCount(captured, 'checks:run:1'), 0)
  check('zero checks discovered', result.checks?.discovered, 0)
  check('the run does not halt', result.halted_at, undefined)
}

async function scenarioDV() {
  console.log('\n== scenario DV: a "# Checks" heading (wrong level) is not read as checks')
  const { result, captured } = await run({
    discovery: { file: '/repo/AGENTS.md',
      sections: [{ heading: '# Checks', fence: 'bash scripts/run-tests.sh' }], detail: 'stub' },
  })
  check('no check-run call was made', callCount(captured, 'checks:run:1'), 0)
  check('zero checks discovered', result.checks?.discovered, 0)
  check('the run does not halt', result.halted_at, undefined)
}

// Scenario DW -- #109: when both headings exist, '## Commands' is simply
// irrelevant, not a second source and not a notice: only the '## Checks'
// section's own fence ever runs.
async function scenarioDW() {
  console.log('\n== scenario DW: a "## Commands" heading alongside "## Checks" is ignored, with no notice logged')
  const { result, captured } = await run({
    discovery: { file: '/repo/AGENTS.md',
      sections: [
        { heading: '## Commands', fence: 'bash scripts/should-not-run.sh' },
        { heading: '## Checks', fence: 'bash scripts/run-tests.sh' },
      ], detail: 'stub' },
    checkRuns: () => ({ results: [checkRow('check:1', 'bash scripts/run-tests.sh', 0, 'ok')], dirty: false }),
  })
  check('one check discovered, from ## Checks only', result.checks?.discovered, 1)
  check('the ## Commands notice is not logged when ## Checks is present',
    captured.logs.some(l => l.includes('no longer read as checks')), false)
  check('the baseline ran the ## Checks command', callCount(captured, 'checks:run:1'), 1)
}

// Scenario DX -- #109: splitting a fence into commands is script code, not
// the model's account of it. Blank lines, a full-line comment, a trailing
// comment, surrounding whitespace, CRLF line endings and a quoted '#' are
// all exercised in one fence, and the ordered result must reflect exactly
// three real commands.
async function scenarioDX() {
  console.log('\n== scenario DX: fence parsing keeps only real commands, in order, past comments, blanks, whitespace and CRLF')
  const fence = '  bash scripts/run-tests.sh  \r\n' +
    '\r\n' +
    '# full line comment\r\n' +
    'bash scripts/lint.sh # trailing comment\r\n' +
    '\r\n' +
    "bash scripts/echo.sh 'a # b'\r\n"
  const { captured } = await run({
    discovery: { file: '/repo/AGENTS.md', sections: [{ heading: '## Checks', fence }], detail: 'stub' },
    checkRuns: () => ({ results: [
      checkRow('check:1', 'bash scripts/run-tests.sh', 0, 'ok'),
      checkRow('check:2', 'bash scripts/lint.sh', 0, 'ok'),
      checkRow('check:3', "bash scripts/echo.sh 'a # b'", 0, 'ok'),
    ], dirty: false }),
  })
  const runPrompt = captured.calls.find(c => c.label === 'checks:run:1')?.prompt ?? ''
  const expectedOrder = [
    'check:1: ' + checkInvocation('check:1', 'bash scripts/run-tests.sh'),
    'check:2: ' + checkInvocation('check:2', 'bash scripts/lint.sh'),
    'check:3: ' + checkInvocation('check:3', "bash scripts/echo.sh 'a # b'"),
  ]
  check('exactly three checks, each with the expected trimmed command',
    expectedOrder.every(line => runPrompt.includes(line)), true)
  check('the ordered command list is preserved',
    expectedOrder.every((line, i) => i === 0 || runPrompt.indexOf(expectedOrder[i - 1]) < runPrompt.indexOf(line)), true)
  check('the full-line comment and blank lines produced no fourth check',
    runPrompt.includes('check:4'), false)
}

// Scenario DY -- gh-118: checks discovery is folded into the branch prompt
// itself (its own last step) rather than a separate checks:discover
// dispatch, since the worktree path the discovery step needs is one that
// agent derives in an earlier step of the same call, not one the script
// already knows. The gate markers, by contrast, still resolve from
// --git-common-dir, and now live in the merged 'setup' call.
async function scenarioDY() {
  console.log('\n== scenario DY: discovery lives in the branch prompt; git-common-dir is only in setup')
  const { captured } = await run({
    discovery: { file: '', sections: [], detail: 'stub' },
  })
  check('checks:discover is never dispatched as its own call', callCount(captured, 'checks:discover'), 0)
  const branchPrompt = captured.calls.find(c => c.label === 'branch')?.prompt ?? ''
  check('the branch prompt reads AGENTS.md', branchPrompt.includes('AGENTS.md'), true)
  check('the branch prompt reads CLAUDE.md', branchPrompt.includes('CLAUDE.md'), true)
  check('the branch prompt populates checks_source itself',
    branchPrompt.includes('checks_source.sections'), true)
  const setupPrompt = captured.calls.find(c => c.label === 'setup')?.prompt ?? ''
  check('the markers probe in setup still resolves from git-common-dir', setupPrompt.includes('git-common-dir'), true)
}

// Scenario DZ -- gh-118: branch:existing folds the same discovery step into
// its own last step, pointed at whichever path steps 4-6 matched -- again a
// path the agent derives, never one the script could name literally here.
async function scenarioDZ() {
  console.log('\n== scenario DZ: existingBranch folds discovery into its own last step, not a separate call')
  const { captured } = await run({
    args: { existingBranch: true },
    existingBranchResult: { created: true, branch: 'feat/gh-21-stub', base: 'main',
      path: '/tmp/distinct-worktree', ticket: '21', detail: 'stub' },
    discovery: { file: '', sections: [], detail: 'stub' },
  })
  check('checks:discover is never dispatched as its own call', callCount(captured, 'checks:discover'), 0)
  const bxPrompt = captured.calls.find(c => c.label === 'branch:existing')?.prompt ?? ''
  check('the branch:existing prompt reads AGENTS.md', bxPrompt.includes('AGENTS.md'), true)
  check('the branch:existing prompt populates checks_source itself',
    bxPrompt.includes('checks_source.sections'), true)
}

// Scenario EA -- #109: two identical command lines are two distinct checks,
// each with its own id. Baseline drop is by id, so dropping the one that is
// genuinely red at baseline must never sweep away its identical twin, and
// both must get a real, separate result afterwards.
async function scenarioEA() {
  console.log('\n== scenario EA: a repeated full command stays two distinct checks; only the one red at baseline drops')
  const { result, captured } = await run({
    discovery: { file: '/repo/AGENTS.md',
      sections: [{ heading: '## Checks', fence: 'make test\nmake lint\nmake test' }], detail: 'stub' },
    checkRuns: (attempt) => attempt === 1
      ? { results: [
          checkRow('check:1', 'make test', 0, 'ok'),
          checkRow('check:2', 'make lint', 1, 'lint failed'),
          checkRow('check:3', 'make test', 0, 'ok'),
        ], dirty: false }
      : { results: [
          checkRow('check:1', 'make test', 0, 'ok again'),
          checkRow('check:3', 'make test', 0, 'ok again'),
        ], dirty: false },
  })
  check('two checks remain after the baseline drops the failing lint check', result.checks?.discovered, 2)
  check('the drop is reported as environmental',
    (result.checks?.detail ?? '').includes('dropped 1 as environmental'), true)
  check('the dropped id is check:2', (result.checks?.detail ?? '').includes('check:2'), true)
  check('no red check remains: both duplicate test entries passed', result.checks?.red?.length, 0)
  const secondRun = captured.calls.find(c => c.label === 'checks:run:2')?.prompt ?? ''
  check('the second run asks for both surviving duplicate ids separately',
    secondRun.includes('check:1:') && secondRun.includes('check:3:'), true)
  check('the run does not halt', result.halted_at, undefined)
}

// Scenario EB -- #109, #116: the script builds each check's exact Bash
// invocation itself; a reported command that merely resembles it (an extra
// `timeout`) is not measured, is never a pass, and is never dropped as the
// repo's own environment at baseline. An unmeasured row gets one retry after
// Implement; still mismatched on the retry, it halts rather than reaching a
// fixer that cannot change what the runner echoes back. The mismatched row
// still carries a valid exit line for its own (wrong) command, to prove the
// command-mismatch check runs before the exit-line check, not after it.
async function scenarioEB() {
  console.log('\n== scenario EB: a mismatched reported command is never dropped at baseline, and halts after a retry rather than reaching a fixer')
  const { result, captured } = await run({
    discovery: { file: '/repo/AGENTS.md',
      sections: [{ heading: '## Checks', fence: 'make run' }], detail: 'stub' },
    checkRuns: () => ({ results: [{ id: 'check:1', command: 'timeout 10 make run', exit_code: 0,
      output: 'TOUCHSTONE_CHECK_EXIT check:1 0\nok' }], dirty: false }),
    initialReview: { correctness: [], advocate: [] },
    verify: () => undefined,
    staleness: () => [],
  })
  check('the check was not dropped at baseline: still discovered', result.checks?.discovered, 1)
  check('the baseline detail does not claim anything was dropped',
    (result.checks?.detail ?? '').includes('dropped'), false)
  check('halted at Implement: measurement, not the code', result.halted_at, 'Implement')
  check('the retry happened once', callCount(captured, 'checks:run:3'), 1)
  check('no third attempt was made', callCount(captured, 'checks:run:4'), 0)
  check('the checks-only fixer never ran', callCount(captured, 'checks:fix'), 0)
  check('no fix round ever ran', callCount(captured, 'fix:1'), 0)
  check('the mismatched check is the one named', result.checks?.unmeasured?.[0]?.id, 'check:1')
  check('the note states the invocation that was expected',
    (result.note ?? '').includes(checkInvocation('check:1', 'make run')), true)
  check('the note carries the mismatched command actually reported',
    (result.note ?? '').includes('timeout 10 make run'), true)
  check('the halt says it is about measurement, not the code',
    (result.note ?? '').includes('not the code'), true)
}

// Scenarios EC-EE -- #109: the three remaining zero-checks cases, each
// logged and none a halt.
async function scenarioEC() {
  console.log('\n== scenario EC: neither AGENTS.md nor CLAUDE.md exists gives zero checks, logged, no halt')
  const { result, captured } = await run({
    discovery: { file: '', sections: [], detail: 'stub' },
  })
  check('no check-run call was made', callCount(captured, 'checks:run:1'), 0)
  check('zero checks discovered', result.checks?.discovered, 0)
  check('the run does not halt', result.halted_at, undefined)
  check('a log line gives the reason',
    captured.logs.some(l => l.includes('no repo-advertised checks found') && l.includes('neither AGENTS.md nor CLAUDE.md exists')), true)
}

async function scenarioED() {
  console.log('\n== scenario ED: a null checks:discover response gives zero checks, logged, no halt')
  const { result, captured } = await run({
    discoveryFails: true,
  })
  check('no check-run call was made', callCount(captured, 'checks:run:1'), 0)
  check('zero checks discovered', result.checks?.discovered, 0)
  check('the run does not halt', result.halted_at, undefined)
  check('a log line gives the reason',
    captured.logs.some(l => l.includes('no repo-advertised checks found') && l.includes('discovery returned nothing')), true)
}

async function scenarioEE() {
  console.log('\n== scenario EE: a "## Checks" heading with no command lines gives zero checks, logged, no halt')
  const { result, captured } = await run({
    discovery: { file: '/repo/AGENTS.md',
      sections: [{ heading: '## Checks', fence: '# just a comment\n\n' }], detail: 'stub' },
  })
  check('no check-run call was made', callCount(captured, 'checks:run:1'), 0)
  check('zero checks discovered', result.checks?.discovered, 0)
  check('the run does not halt', result.halted_at, undefined)
  check('a log line gives the reason',
    captured.logs.some(l => l.includes('no repo-advertised checks found') && l.includes('no fence, or no command lines')), true)
}

// Scenario EF -- #109: invocationFor splices the worktree path and the
// declared command into single quotes by plain interpolation. A quote in
// either ends the outer -c string early, so the invocation the runner is
// told to execute is not the command the repo declared. Proven by actually
// running the built invocation, not by predicting its string: a worktree
// path holding a space and a quote, and a declared command holding a quoted
// '#', both have to survive into the real run untouched.
async function scenarioEF() {
  console.log('\n== scenario EF: #109 -- the built invocation actually runs the declared command, worktree-path quote and all')
  const wtPath = fs.mkdtempSync(path.join(os.tmpdir(), "touchstone o'clock -"))
  const declared = "echo 'a # b'"
  try {
    const { captured } = await run({
      branchResult: { created: true, branch: 'feat/gh-21-stub', base: 'main',
        path: wtPath, ticket: '21', detail: 'stub', dirty: false },
      discovery: { file: '/repo/AGENTS.md',
        sections: [{ heading: '## Checks', fence: declared }], detail: 'stub' },
    })
    const runPrompt = captured.calls.find(c => c.label === 'checks:run:1')?.prompt ?? ''
    const line = runPrompt.split('\n').find(l => l.startsWith('check:1: '))
    const invocation = line ? line.slice('check:1: '.length) : ''
    const want = execFileSync('bash', ['-c', declared]).toString()
    const got = invocation ? execFileSync('bash', ['-c', invocation]).toString() : `<no invocation: ${runPrompt}>`
    check('the exit line comes first, then the declared command\'s output byte for byte',
      got, `TOUCHSTONE_CHECK_EXIT check:1 0\n${want}`)
  } finally {
    fs.rmSync(wtPath, { recursive: true, force: true })
  }
}

// Scenario EJ -- #109: "the verbatim contents between the opening and
// closing markers" is ambiguous about whether the info string on the
// opening marker line (` ```bash `) counts as content. The agent now
// transcribes the fence including its marker lines, so checksFrom() must
// drop exactly the first and last lines when they are markers, never
// letting the info string surface as a spurious check:1 that shifts every
// id after it.
async function scenarioEJ() {
  console.log('\n== scenario EJ: a fence transcribed with its ```bash marker lines strips them, not just the plain contents')
  const { result, captured } = await run({
    discovery: { file: '/repo/AGENTS.md',
      sections: [{ heading: '## Checks', fence: '```bash\nmake test\nmake lint\n```' }], detail: 'stub' },
    checkRuns: () => ({ results: [
      checkRow('check:1', 'make test', 0, 'ok'),
      checkRow('check:2', 'make lint', 0, 'ok'),
    ], dirty: false }),
  })
  check('exactly two checks discovered', result.checks?.discovered, 2)
  const runPrompt = captured.calls.find(c => c.label === 'checks:run:1')?.prompt ?? ''
  check('check:1 is make test, not the bash info string',
    runPrompt.includes('check:1: ' + checkInvocation('check:1', 'make test')), true)
  check('check:2 is make lint', runPrompt.includes('check:2: ' + checkInvocation('check:2', 'make lint')), true)
  check('there is no check:3', runPrompt.includes('check:3'), false)
}

// Only a marker at fenceLines[0] or the last slot gets dropped. A newline
// outside the fence occupies that slot first, so the marker survives untouched.
async function scenarioEK() {
  console.log('\n== scenario EK: a fence transcribed with a leading or trailing newline still strips only its marker lines')
  for (const fence of ['```bash\nmake test\nmake lint\n```\n', '\n```bash\nmake test\nmake lint\n```']) {
    const { result, captured } = await run({
      discovery: { file: '/repo/AGENTS.md',
        sections: [{ heading: '## Checks', fence }], detail: 'stub' },
      checkRuns: () => ({ results: [
        checkRow('check:1', 'make test', 0, 'ok'),
        checkRow('check:2', 'make lint', 0, 'ok'),
      ], dirty: false }),
    })
    check(`exactly two checks discovered (${JSON.stringify(fence)})`, result.checks?.discovered, 2)
    const runPrompt = captured.calls.find(c => c.label === 'checks:run:1')?.prompt ?? ''
    check('check:1 is make test, not a marker line',
      runPrompt.includes('check:1: ' + checkInvocation('check:1', 'make test')), true)
    check('check:2 is make lint', runPrompt.includes('check:2: ' + checkInvocation('check:2', 'make lint')), true)
    check('there is no check:3', runPrompt.includes('check:3'), false)
  }
}

// Scenario EL -- every check invocation is `bash -c 'cd <worktree> && ...'`,
// while treeAgent's own preamble tells every agent never to cd into the
// worktree, not even as `cd <path> && <cmd>`. Without an explicit exception
// the runner is told both to run the invocation exactly and never to run it,
// and a runner that obeys the preamble reports a different command, which the
// exact-match rule then counts as not measured.
async function scenarioEL() {
  console.log('\n== scenario EL: the check runner is told its bash -c cd is the one exception to never-cd')
  const { captured } = await run({
    discovery: { file: '/repo/AGENTS.md', sections: [{ heading: '## Checks', fence: 'make test' }], detail: 'stub' },
  })
  const runPrompt = captured.calls.find(c => c.label === 'checks:run:1')?.prompt ?? ''
  check('the preamble forbids cd into the worktree', /Never cd there/.test(runPrompt), true)
  check('the runner is told this call is the exception, in the bash -c form only',
    /exception to the rule above about never running cd/.test(runPrompt) && runPrompt.includes('bash -c'), true)
}

// Scenario EM -- #116: a worktree path made only of characters no shell
// treats specially is spliced into the invocation bare, with no nested
// quoting for the runner to copy. Asserted against a literal string, not
// against this file's own (necessarily identical) shQuote copy: the point is
// to prove what invocationFor actually outputs, not to restate its logic.
async function scenarioEM() {
  console.log('\n== scenario EM: a bare-safe worktree path has no nested quoting to copy')
  const { captured } = await run({
    discovery: { file: '/repo/AGENTS.md', sections: [{ heading: '## Checks', fence: 'make test' }], detail: 'stub' },
  })
  const runPrompt = captured.calls.find(c => c.label === 'checks:run:1')?.prompt ?? ''
  check('the invocation is exactly bash -c \'cd <path> && <command>\', no \\\'\\\' near the path, plus the exit echo',
    runPrompt.includes(
      'check:1: o=$(mktemp); bash -c \'cd /tmp/stub-worktree && make test\' >"$o" 2>&1; echo "TOUCHSTONE_CHECK_EXIT check:1 $?"; tail -c 8192 "$o"; rm -f "$o"'),
    true)
}

// Scenario EN -- #116: a worktree path that does need quoting (a space, a
// single quote) still lands the `cd` in the real directory when the built
// invocation actually runs, not merely that a command indifferent to its cwd
// still produces the right output (scenario EF).
async function scenarioEN() {
  console.log('\n== scenario EN: a worktree path needing quoting still cds to the real directory')
  const wtPath = fs.mkdtempSync(path.join(os.tmpdir(), "touchstone o'clock -"))
  const realPath = fs.realpathSync(wtPath)
  try {
    const { captured } = await run({
      branchResult: { created: true, branch: 'feat/gh-21-stub', base: 'main',
        path: wtPath, ticket: '21', detail: 'stub', dirty: false },
      discovery: { file: '/repo/AGENTS.md',
        sections: [{ heading: '## Checks', fence: 'pwd -P' }], detail: 'stub' },
    })
    const runPrompt = captured.calls.find(c => c.label === 'checks:run:1')?.prompt ?? ''
    const line = runPrompt.split('\n').find(l => l.startsWith('check:1: '))
    const invocation = line ? line.slice('check:1: '.length) : ''
    check('this path is one the bare-word regex rejects, so it stays quoted',
      /^[A-Za-z0-9/._+:@%=,-]+$/.test(wtPath), false)
    const got = invocation
      ? execFileSync('bash', ['-c', invocation]).toString().split('\n')[1]
      : `<no invocation: ${runPrompt}>`
    check('cd actually lands in the real worktree directory', got, realPath)
  } finally {
    fs.rmSync(wtPath, { recursive: true, force: true })
  }
}

// Scenario EO -- #116: existingBranch has no clean base tree to block on
// (:1433-1437), so the retry-then-halt rule applies to measurement itself,
// never to blocking. A check still unmeasured after the retry is reported,
// not halted.
async function scenarioEO() {
  console.log('\n== scenario EO: existingBranch never halts on an unmeasured check, even after the retry')
  const { result, captured } = await run({
    args: { existingBranch: true, openPr: true },
    discovery: { file: '/repo/AGENTS.md',
      sections: [{ heading: '## Checks', fence: 'bash scripts/lint.sh' }], detail: 'stub' },
    checkRuns: () => ({ results: [] }),
    prResult: { opened: true, url: 'https://example.invalid/pr/38o', note: 'stub ready' },
  })
  check('the first run happened', callCount(captured, 'checks:run:1'), 1)
  check('the retry happened once', callCount(captured, 'checks:run:2'), 1)
  check('no third attempt was made', callCount(captured, 'checks:run:3'), 0)
  check('the run does not halt', result.halted_at, undefined)
  check('the check is reported as unmeasured', result.checks?.unmeasured?.length, 1)
  check('it is never counted as red', result.checks?.red?.length, 0)
  check('the run reaches the PR phase', result.pr?.opened, true)
}

async function scenarioEG() {
  console.log('\n== scenario EG: no reproducer execution overlaps another agent in the worktree')
  const { captured } = await run({
    args: { maxReviewRounds: 2 },
    initialReview: {
      correctness: [
        { title: 'Route resolves from cwd', file: 'src/route.js', claim: 'wrong repo', evidence: 'route.js:12' },
        { title: 'Missing guard', file: 'src/guard.js', claim: 'no guard', evidence: 'guard.js:3' },
      ],
      advocate: [],
    },
    verify: (id, round) => id === 'f1' ? round === 1 : (id === 'f2' ? round === 2 : undefined),
    fixHead: (round) => `fix0000000000000000000000000000000000000${round}`,
    tailReview: [{ category: 'docs', title: 'A stale comment', file: 'src/route.js',
      claim: 'says cwd', evidence: 'route.js:1', reproducer: undefined }],
    staleness: () => [],
  })
  check('round 2 re-ran the settled finding, the open one and a tail review',
    ['reproduce:settled:2', 'reproduce:fix:2', 'review:fix:2:correctness']
      .every(l => callCount(captured, l) === 1), true)
  check('no executor call overlapped another agent', overlapsWithExecutor(captured), [])
}

// Scenarios GA-GC -- the #118 run's runner reported the command in forms other
// than the full invocation (the bare declared command at baseline, the inner
// bash -c after Implement) and, on the later runs, dropped the exit line from
// output. A row is measured when the command is one of the three forms the
// script built and the exit line arrives in exit_line or as output's first
// line; anything else stays unmeasured.
async function scenarioGA() {
  console.log('\n== scenario GA: a row reporting the bare declared command, exit line first in output, is measured')
  const { result } = await run({
    args: { existingBranch: true, openPr: true },
    discovery: { file: '/repo/AGENTS.md', sections: [{ heading: '## Checks', fence: 'make test' }], detail: 'stub' },
    checkRuns: () => ({ results: [{ id: 'check:1', command: 'make test', exit_code: 0,
      output: 'TOUCHSTONE_CHECK_EXIT check:1 1\nboom' }], dirty: false }),
    prResult: { opened: true, url: 'https://example.invalid/pr/118ga', note: 'stub ready' },
  })
  check('measured red from its exit line', result.checks?.red?.[0]?.exit_code, 1)
  check('nothing unmeasured', result.checks?.unmeasured?.length, 0)
}

async function scenarioGB() {
  console.log('\n== scenario GB: a row reporting the inner bash -c, exit line only in exit_line, is measured')
  const { result } = await run({
    args: { existingBranch: true, openPr: true },
    discovery: { file: '/repo/AGENTS.md', sections: [{ heading: '## Checks', fence: 'make test' }], detail: 'stub' },
    checkRuns: () => ({ results: [{ id: 'check:1', command: "bash -c 'cd /tmp/stub-worktree && make test'",
      exit_code: 0, exit_line: 'TOUCHSTONE_CHECK_EXIT check:1 2', output: 'the tail of the log' }], dirty: false }),
    prResult: { opened: true, url: 'https://example.invalid/pr/118gb', note: 'stub ready' },
  })
  check('measured red from exit_line', result.checks?.red?.[0]?.exit_code, 2)
  check('nothing unmeasured', result.checks?.unmeasured?.length, 0)
}

async function scenarioGC() {
  console.log('\n== scenario GC: an exit_line naming another check is unmeasured')
  const { result } = await run({
    args: { existingBranch: true, openPr: true },
    discovery: { file: '/repo/AGENTS.md', sections: [{ heading: '## Checks', fence: 'make test' }], detail: 'stub' },
    checkRuns: () => ({ results: [{ id: 'check:1', command: 'make test', exit_code: 0,
      exit_line: 'TOUCHSTONE_CHECK_EXIT check:2 0', output: 'TOUCHSTONE_CHECK_EXIT check:1 0' }], dirty: false }),
    prResult: { opened: true, url: 'https://example.invalid/pr/118gc', note: 'stub ready' },
  })
  check('not red', result.checks?.red?.length, 0)
  check('unmeasured, naming the other id', result.checks?.unmeasured?.[0]?.reason, 'exit line names check:2')
}

async function scenarioGD() {
  console.log('\n== scenario GD: an exit_line disagreeing with the exit line in output is unmeasured, never a pass')
  const { result } = await run({
    args: { existingBranch: true, openPr: true },
    discovery: { file: '/repo/AGENTS.md', sections: [{ heading: '## Checks', fence: 'make test' }], detail: 'stub' },
    checkRuns: () => ({ results: [{ id: 'check:1', command: 'make test', exit_code: 0,
      exit_line: 'TOUCHSTONE_CHECK_EXIT check:1 0', output: 'TOUCHSTONE_CHECK_EXIT check:1 1\nboom' }], dirty: false }),
    prResult: { opened: true, url: 'https://example.invalid/pr/118gd', note: 'stub ready' },
  })
  check('not a pass: nothing red is not enough', result.checks?.unmeasured?.[0]?.reason, 'exit_line disagrees with output')
}

async function scenarioGE() {
  console.log('\n== scenario GE: reusing an existing worktree still reaches the check-discovery step')
  const { captured } = await run({})
  const prompt = captured.calls.find(c => c.label === 'branch')?.prompt ?? ''
  const reuse = prompt.split('\n').find(l => l.includes('reused rather than created, then')) ?? ''
  check('the reuse step goes on to discovery instead of stopping', /go straight to step 11/.test(prompt), true)
  check('step 11 is the discovery step', /\n11\. Before you return from the step above: read /.test(prompt), true)
  check('the reuse step no longer says stop', /reused rather than created, and stop/.test(prompt), false)
  check('found the reuse line', reuse !== '', true)
}

const SCENARIOS = [scenarioDL, scenarioDM, scenarioDN, scenarioDO, scenarioDP, scenarioDQ, scenarioDR, scenarioDS, scenarioDT, scenarioDU, scenarioDV, scenarioDW, scenarioDX, scenarioDY, scenarioDZ, scenarioEA, scenarioEB, scenarioEC, scenarioED, scenarioEE, scenarioEF, scenarioEJ, scenarioEK, scenarioEL, scenarioEM, scenarioEN, scenarioEO, scenarioEG, scenarioGA, scenarioGB, scenarioGC, scenarioGD, scenarioGE]
JS_EOF

finish
