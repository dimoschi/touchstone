#!/usr/bin/env bash
# gh-96: commands under AGENTS.md's `## Advisory checks` run once before the
# PR and reach it as notes. They never block, and a fixer is never asked to
# satisfy one; see harness.sh for what run()/captured share.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/harness.sh"

run_js_scenarios <<'JS_EOF'
const ADVISORY = 'bash scripts/advisory.sh'

const withAdvisory = {
  file: '/repo/AGENTS.md',
  sections: [
    { heading: '## Checks', fence: 'make test' },
    { heading: '## Advisory checks', fence: ADVISORY },
  ],
  detail: 'stub',
}

const rows = (advisoryExit) => () => ({ results: [
  checkRow('check:1', 'make test', 0, 'ok'),
  checkRow('advisory:1', ADVISORY, advisoryExit, 'a.sh:12: this assertion cannot fail'),
], dirty: false })

async function scenarioAdvisoryReportReachesThePr() {
  console.log('\n== scenario: a red advisory check becomes a PR note and blocks nothing')
  const { result, captured } = await run({
    args: { openPr: true },
    discovery: withAdvisory,
    checkRuns: rows(1),
    initialReview: { correctness: [], advocate: [] },
    prResult: { opened: true, url: 'https://example.invalid/pr/96a', note: 'stub ready' },
  })
  const prPrompt = captured.calls.find(c => c.label === 'pr')?.prompt ?? ''
  check('the run does not halt', result.halted_at, undefined)
  check('no checks-only fixer ran', callCount(captured, 'checks:fix'), 0)
  check('the PR prompt names the advisory command',
    prPrompt.includes(`Advisory check \`${ADVISORY}\` reported`), true)
  const advisoryRun = captured.calls.filter(c => c.label.startsWith('checks:run:')).pop()
  const log = runnerLogOf(runIdOf(advisoryRun?.prompt ?? ''), 'advisory:1')
  check('the PR prompt says it exited 1', prPrompt.includes('exit 1'), true)
  check('the PR prompt carries the log path and tells the agent to read it',
    prPrompt.includes(`Read ${log}`), true)
  check('and to keep that path out of the PR', prPrompt.includes('never put that path in the PR'), true)
  check('the advisory command never ran as a blocking check',
    captured.calls.filter(c => c.label.startsWith('checks:run:'))
      .slice(0, -1).some(c => c.prompt.includes(ADVISORY)), false)
}

async function scenarioGreenAdvisoryAddsNothing() {
  console.log('\n== scenario: a green advisory check adds no note')
  const { captured } = await run({
    args: { openPr: true },
    discovery: withAdvisory,
    checkRuns: rows(0),
    initialReview: { correctness: [], advocate: [] },
    prResult: { opened: true, url: 'https://example.invalid/pr/96b', note: 'stub ready' },
  })
  const prPrompt = captured.calls.find(c => c.label === 'pr')?.prompt ?? ''
  check('the advisory check ran', captured.calls.some(c => c.label.startsWith('checks:run:') && c.prompt.includes(ADVISORY)), true)
  check('no advisory note', prPrompt.includes('Advisory check'), false)
}

async function scenarioNoAdvisorySectionRunsNothingExtra() {
  console.log('\n== scenario: without an advisory section no extra check run happens')
  const { captured } = await run({
    args: { openPr: true },
    discovery: { file: '/repo/AGENTS.md', sections: [{ heading: '## Checks', fence: 'make test' }], detail: 'stub' },
    checkRuns: rows(0),
    initialReview: { correctness: [], advocate: [] },
    prResult: { opened: true, url: 'https://example.invalid/pr/96c', note: 'stub ready' },
  })
  check('only the baseline and post-Implement check runs',
    captured.calls.filter(c => c.label.startsWith('checks:run:')).length, 2)
}

const PENDING = { output: 'TOUCHSTONE_CHECK_PENDING advisory:1 1' }
const isAdvisoryRun = (prompt) => prompt.includes(ADVISORY)

async function scenarioAdvisoryStillRunningIsAskedAgain() {
  console.log('\n== scenario: an advisory check still running on its first poll is asked about again')
  let advisoryCalls = 0
  const normal = rows(1)
  const { result, captured } = await run({
    args: { openPr: true },
    discovery: withAdvisory,
    checkRuns: (attempt, prompt) => isAdvisoryRun(prompt) && ++advisoryCalls === 1 ? PENDING : normal(),
    initialReview: { correctness: [], advocate: [] },
    prResult: { opened: true, url: 'https://example.invalid/pr/186a', note: 'stub ready' },
  })
  const prPrompt = captured.calls.find(c => c.label === 'pr')?.prompt ?? ''
  const first = captured.calls.find(c => c.label.startsWith('checks:run:') && isAdvisoryRun(c.prompt))
  check('the run does not halt', result.halted_at, undefined)
  check('the advisory attempt was asked about a second time',
    callCount(captured, `${first?.label}:poll:2`), 1)
  check('the PR prompt carries the note from the later reply',
    prPrompt.includes(`Advisory check \`${ADVISORY}\` reported`) && prPrompt.includes('exit 1'), true)
}

async function scenarioMutationBudgetStopsAskingAboutAdvisory() {
  console.log('\n== scenario: a mutation stage budget stops asking about a pending advisory check')
  const { result, captured } = await run({
    args: { openPr: true, stageBudgets: { mutation: 1000 } },
    budgetPerAgentCall: 5000,
    discovery: withAdvisory,
    checkRuns: (attempt, prompt) => isAdvisoryRun(prompt) ? PENDING : rows(1)(),
    initialReview: { correctness: [], advocate: [] },
    prResult: { opened: true, url: 'https://example.invalid/pr/186b', note: 'stub ready' },
  })
  const prPrompt = captured.calls.find(c => c.label === 'pr')?.prompt ?? ''
  const first = captured.calls.find(c => c.label.startsWith('checks:run:') && isAdvisoryRun(c.prompt))
  check('the run does not halt', result.halted_at, undefined)
  check('a kill was sent for the advisory attempt', callCount(captured, `${first?.label}:kill`), 1)
  check('the PR still opened', captured.calls.some(c => c.label === 'pr'), true)
  check('no advisory note', prPrompt.includes('Advisory check'), false)
}

async function scenarioNoBudgetKeepsAskingAboutAdvisory() {
  console.log('\n== scenario: without a stage budget a pending advisory check is asked about until it exits')
  let advisoryCalls = 0
  const normal = rows(1)
  const { result, captured } = await run({
    args: { openPr: true },
    budgetPerAgentCall: 5000,
    discovery: withAdvisory,
    checkRuns: (attempt, prompt) => isAdvisoryRun(prompt) && ++advisoryCalls <= 3 ? PENDING : normal(),
    initialReview: { correctness: [], advocate: [] },
    prResult: { opened: true, url: 'https://example.invalid/pr/186c', note: 'stub ready' },
  })
  const prPrompt = captured.calls.find(c => c.label === 'pr')?.prompt ?? ''
  const first = captured.calls.find(c => c.label.startsWith('checks:run:') && isAdvisoryRun(c.prompt))
  check('the run does not halt', result.halted_at, undefined)
  check('it was asked until the fourth call', callCount(captured, `${first?.label}:poll:4`), 1)
  check('no kill was sent', callCount(captured, `${first?.label}:kill`), 0)
  check('the PR prompt carries the advisory note', prPrompt.includes('Advisory check'), true)
}

const SCENARIOS = [
  scenarioAdvisoryReportReachesThePr,
  scenarioGreenAdvisoryAddsNothing,
  scenarioNoAdvisorySectionRunsNothingExtra,
  scenarioAdvisoryStillRunningIsAskedAgain,
  scenarioMutationBudgetStopsAskingAboutAdvisory,
  scenarioNoBudgetKeepsAskingAboutAdvisory,
]
JS_EOF

finish
