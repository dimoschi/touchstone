#!/usr/bin/env bash
# The change-risk signals the Draft PR phase records: one probe, over the range
# the diffstat measured, that is parsed strictly, carried in the result and in
# every halt after it, and read by nothing that decides how the run goes. See
# harness.sh for what run()/captured share.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/harness.sh"

echo "== static: the bounds the signals must not move"
for line in \
  "const MAX_REVIEW_ROUNDS = args?.maxReviewRounds ?? 3" \
  "const INLINE_LOC = args?.inlineLoc ?? 10" \
  "const ONE_LENS_LOC = 150" \
  "const BIG_LOC = 400" \
  "const BIG_FILES = 5" \
  "const RATIO_MIN_CODE = 20" \
  "const MAX_SUPPORT_RATIO = 10" \
  "  setup: null," "  triage: 15_000," "  branch: 10_000," "  plan: null," "  implement: null," \
  "  checks: 20_000," "  review: 80_000," "  fix: 170_000," "  mutation: 150_000," "  pr: 30_000,"; do
  check "unchanged: $line" "$(grep -Fxc -- "$line" "$SCRIPT" || true)" 1
done

run_js_scenarios <<'JS_EOF'
const STUB_RANGE = COMMIT_RANGE
const signalsCalls = (captured) => captured.calls.filter(c => c.label === 'signals')

// What the script is told the probe printed: a record for `range` with the
// given entries, as lines, so a scenario can break one of them.
function recordLines(range, overrides = {}) {
  return signalsOutput(range, overrides).split('\n')
}

async function scenarioSignalsReachTheResult() {
  console.log('\n== scenario: the signals are carried in the result, as the probe reported them')
  const { result, captured } = await run({
    signalValues: {
      la: signalEntry(42), la_lt: signalEntry(0.5), api_broken: signalEntry(true),
      reachable: signalEntry('unmeasured', 'no main package'),
    },
  })
  check('the run does not halt', result.halted_at, undefined)
  check('the range is the one the draft was measured over', result.signals?.range, STUB_RANGE)
  check('every name is there, in the script\'s order', Object.keys(result.signals?.values ?? {}), SIGNAL_NAMES)
  check('a number is kept', result.signals?.values.la.value, 42)
  check('a fraction is kept', result.signals?.values.la_lt.value, 0.5)
  check('a true is kept', result.signals?.values.api_broken.value, true)
  check('an unmeasured value keeps its reason', result.signals?.values.reachable,
    signalEntry('unmeasured', 'no main package'))
  check('the evidence is kept', result.signals?.values.ld.evidence, { command: 'stub', exit: 0, output: '' })
  check('what was measured and what was not is logged',
    captured.logs.includes('signals: 13 of 14 measured; unmeasured: reachable'), true)
}

async function scenarioSignalsAreOneDispatchAfterTheDraft() {
  console.log('\n== scenario: one cheap probe, after the draft PR and before any review')
  const { captured } = await run({
    initialReview: { correctness: [], advocate: [] },
    verify: () => undefined,
    staleness: () => [],
  })
  const labels = captured.calls.map(c => c.label)
  const probe = signalsCalls(captured)
  check('dispatched once', probe.length, 1)
  check('right after draft-pr', labels[labels.indexOf('draft-pr') + 1], 'signals')
  check('before the first review lens', labels.indexOf('signals') < labels.findIndex(l => l.startsWith('review:')), true)
  check('on the cheapest model', probe[0].model, 'haiku')
  check('at low effort', probe[0].effort, 'low')
  check('grouped with the Draft PR phase', probe[0].phase, 'Draft PR')
  check('the command is on a line of its own', probe[0].prompt.split('\n').includes(
    `change-signals.sh ${STUB_WT_PATH} ${STUB_RANGE}`), true)
  check('it is the crap-controlled-changes skill\'s script, found by invoking the skill',
    probe[0].prompt.includes('crap-controlled-changes skill') && probe[0].prompt.includes('invoke that skill'), true)
  check('the Bash timeout is 600000', probe[0].prompt.includes('Bash timeout of 600000'), true)
  check('the output is relayed verbatim', probe[0].prompt.includes('verbatim in output'), true)
  check('it stops after the one run', probe[0].prompt.includes('then STOP'), true)
  check('and says never to run it twice', probe[0].prompt.includes('never twice'), true)
  check('the probe is asked for output and nothing else',
    JSON.stringify(probe[0].schema.required), JSON.stringify(['output']))
}

async function scenarioSignalsAreMeasuredOverTheDiffstatRange() {
  console.log('\n== scenario: a pre-review fix that moves the head moves the range the signals are measured over')
  const folded = 'checksfix00000000000000000000000000000002'
  const { result, captured } = await run({
    args: { openPr: true },
    discovery: { file: '/repo/AGENTS.md',
      sections: [{ heading: '## Checks', fence: 'bash scripts/run-tests.sh' }], detail: 'stub' },
    checkRuns: (attempt) => attempt === 2
      ? { results: [checkRow('check:1', 'bash scripts/run-tests.sh', 1, 'FAILURE')], dirty: false }
      : { results: [checkRow('check:1', 'bash scripts/run-tests.sh', 0, 'ok')], dirty: false },
    checksFixResult: { head_sha: folded, note: 'bumped', scored: true },
    prResult: { opened: true, url: 'https://example.invalid/pr/141', note: 'stub ready' },
  })
  const range = `${COMMIT_RANGE.split('..')[0]}..${folded}`
  const diffstat = captured.calls.find(c => c.label === 'draft-pr').prompt
  check('the diffstat was measured over the folded range', diffstat.includes(`TOUCHSTONE_DIFFSTAT ${range};`), true)
  check('so were the signals', result.signals?.range, range)
  check('the probe was asked about that range',
    signalsCalls(captured)[0].prompt.split('\n').includes(`change-signals.sh ${STUB_WT_PATH} ${range}`), true)
}

async function scenarioSignalsAreInEveryHaltAfterTheDraft() {
  console.log('\n== scenario: a halt after the draft carries the signals')
  const sized = await run({ sizeUnmeasured: true })
  check('a Review halt', sized.result.halted_at, 'Review')
  check('carries them', sized.result.signals?.range, STUB_RANGE)
  const fix = await run({
    args: { maxReviewRounds: 1 },
    initialReview: { correctness: [{ title: 'Open', file: 'a.js', claim: 'c', evidence: 'e', line_start: 3 }], advocate: [] },
    verify: () => undefined,
    staleness: () => [],
  })
  check('a Fix halt', fix.result.halted_at, 'Fix')
  check('carries them', fix.result.signals?.range, STUB_RANGE)
  const mutation = await run({
    args: { maxGateAttempts: 1 },
    mutationGated: true,
    mutationResult: () => ({ green: false, head_sha: REVIEWED_THROUGH, detail: 'survivors', scored: false }),
    initialReview: { correctness: [], advocate: [] },
    staleness: () => [],
  })
  check('a Mutation halt', mutation.result.halted_at, 'Mutation')
  check('carries them', mutation.result.signals?.range, STUB_RANGE)
}

async function scenarioSignalsAreNullInEveryHaltBeforeTheDraft() {
  console.log('\n== scenario: a halt before the draft has no signals, and the probe never ran')
  const { result, captured } = await run({ implPlanId: 'not-the-plan-id' })
  check('halted at Implement', result.halted_at, 'Implement')
  check('signals is null, not absent', result.signals, null)
  check('the probe was not dispatched', signalsCalls(captured).length, 0)
}

async function scenarioAProbeThatFailsLeavesNullAndTheRunGoesOn() {
  console.log('\n== scenario: a probe that fails never stops the run')
  const failures = {
    'no answer': { signalsReply: () => null },
    'a dispatch that throws': { signalsThrows: true },
    'output that is not a record': { signalsReply: () => 'sorry, I could not run that' },
    'output that is empty': { signalsReply: () => '' },
  }
  for (const [what, scenario] of Object.entries(failures)) {
    const { result, captured } = await run({
      ...scenario,
      initialReview: { correctness: [], advocate: [] },
      staleness: () => [],
    })
    check(`${what}: signals is null`, result.signals, null)
    check(`${what}: the run does not halt`, result.halted_at, undefined)
    check(`${what}: it still reviewed`, captured.calls.some(c => c.label === 'review:correctness'), true)
    check(`${what}: no retry`, signalsCalls(captured).length, 1)
    check(`${what}: it says so`, captured.logs.some(l => l.startsWith('signals: ') && l.includes('continuing without them')), true)
  }
}

const record = (lines) => lines.join('\n')
const withValue = (name, entry) => {
  const values = signalValues({ [name]: entry })
  return record([`TOUCHSTONE_SIGNALS ${STUB_RANGE}`, JSON.stringify({ range: STUB_RANGE, values }), 'TOUCHSTONE_SIGNALS_END'])
}
const withBody = (body) => record([`TOUCHSTONE_SIGNALS ${STUB_RANGE}`, body, 'TOUCHSTONE_SIGNALS_END'])

async function scenarioParseSignalsRejects() {
  console.log('\n== scenario: anything short of an exact record is not recorded')
  const good = recordLines(STUB_RANGE)
  const missing = signalValues()
  delete missing.defect_files
  const rejected = {
    'no begin marker': record(good.slice(1)),
    'prose before the record': `Here is the output:\n${record(good)}`,
    'prose after the record': `${record(good)}\nDone.`,
    'the begin line names another range': record(['TOUCHSTONE_SIGNALS other..range', good[1], good[2]]),
    'the begin line has trailing text': record([`${good[0]} extra`, good[1], good[2]]),
    'no end marker': record(good.slice(0, 2)),
    'the end marker is wrong': record([good[0], good[1], 'TOUCHSTONE_SIGNALS_ENDED']),
    'two JSON lines': record([good[0], good[1], good[1], good[2]]),
    'the JSON is split over lines': record([good[0], '{"range":', `"${STUB_RANGE}","values":{}}`, good[2]]),
    'not JSON': withBody('{broken'),
    'JSON that is not an object': withBody('[1,2,3]'),
    'JSON null': withBody('null'),
    'the body names another range': withBody(JSON.stringify({ range: 'a..b', values: signalValues() })),
    'no range in the body': withBody(JSON.stringify({ values: signalValues() })),
    'no values': withBody(JSON.stringify({ range: STUB_RANGE })),
    'values that are not an object': withBody(JSON.stringify({ range: STUB_RANGE, values: [1] })),
    'a name missing': withBody(JSON.stringify({ range: STUB_RANGE, values: missing })),
    'a value that is a string': withValue('la', { value: 'maybe', evidence: {} }),
    'a value that is null': withValue('la', { value: null, evidence: {} }),
    'a value beyond a finite number': withBody(JSON.stringify({ range: STUB_RANGE, values: signalValues() })
      .replace('"la":{"value":false', '"la":{"value":1e999')),
    'unmeasured with no reason': withValue('api_broken', { value: 'unmeasured', evidence: {} }),
    'unmeasured with a blank reason': withValue('api_broken', { value: 'unmeasured', reason: '  ', evidence: {} }),
    'unmeasured with a reason that is not text': withValue('api_broken', { value: 'unmeasured', reason: 3, evidence: {} }),
    'an entry that is a bare number': withValue('la', 3),
    'an entry that is null': withValue('la', null),
    'an answer with no output field': {},
    'an output that is not text': { output: 42 },
  }
  for (const [what, output] of Object.entries(rejected)) {
    const { result } = await run({ signalsReply: () => output })
    check(`rejected: ${what}`, result.signals, null)
  }
}

async function scenarioParseSignalsAccepts() {
  console.log('\n== scenario: the record is accepted whatever surrounds it harmlessly')
  const good = recordLines(STUB_RANGE)
  const accepted = {
    'blank lines around it': `\n\n${record(good)}\n\n`,
    'CRLF line endings': `${record(good)}`.split('\n').join('\r\n'),
    'trailing spaces on its lines': record(good.map(l => `${l}   `)),
    'zero, a fraction and a negative number': withBody(JSON.stringify({ range: STUB_RANGE,
      values: signalValues({ la: signalEntry(0), la_lt: signalEntry(0.333), crap_max: signalEntry(-1) }) })),
    'every value unmeasured with a reason': withBody(JSON.stringify({ range: STUB_RANGE,
      values: Object.fromEntries(SIGNAL_NAMES.map(n => [n, signalEntry('unmeasured', 'nothing to measure with')])) })),
  }
  for (const [what, output] of Object.entries(accepted)) {
    const { result } = await run({ signalsReply: () => output })
    check(`accepted: ${what}`, Object.keys(result.signals?.values ?? {}), SIGNAL_NAMES)
  }
  const { result } = await run({ signalsReply: () => withBody(JSON.stringify({ range: STUB_RANGE,
    values: { ...signalValues(), invented: signalEntry(7) } })) })
  check('a name the script does not know is left out', Object.keys(result.signals?.values ?? {}), SIGNAL_NAMES)
}

async function scenarioARefusedDispatchStillReachesTheBudgetHalt() {
  console.log('\n== scenario: a run budget refusal at the probe is a budget halt, not a swallowed failure')
  const { result, captured } = await run({
    args: { runBudget: 1000 },
    spendAllAfter: 'draft-pr',
  })
  check('halted at the phase the probe belongs to', result.halted_at, 'Draft PR')
  check('the note names the refused dispatch', (result.note ?? '').includes("'signals' dispatch was refused"), true)
  check('nothing was reviewed', captured.calls.some(c => c.label.startsWith('review:')), false)
  check('signals is null, present', result.signals, null)
}

// The same run, three ways: every signal raised, every one clear, and the probe
// failing. Nothing about how the run goes may differ.
const RAISED = signalValues({
  la: signalEntry(100000), ld: signalEntry(100000), lt: signalEntry(1), la_lt: signalEntry(100000),
  files: signalEntry(500), directories: signalEntry(90), dependency_surface: signalEntry(true),
  api_broken: signalEntry(true), security_pattern: signalEntry(true), semantic_noop: signalEntry(false),
  crap_max: signalEntry(99), coverage_min: signalEntry(0), reachable: signalEntry(true),
  defect_files: signalEntry(40),
})
const CLEAR = signalValues({
  la: signalEntry(0), ld: signalEntry(0), files: signalEntry(0), directories: signalEntry(0),
  semantic_noop: signalEntry(true), crap_max: signalEntry(1), coverage_min: signalEntry(100),
  defect_files: signalEntry(0),
})
const FINDING = { title: 'Off by one', file: 'a.js', claim: 'c', evidence: 'e', line_start: 3 }

async function outcomeOf(overrides) {
  const { result, captured } = await run({
    args: { maxReviewRounds: 2 },
    initialReview: { correctness: [FINDING], advocate: [] },
    verify: (id, round) => round === 1,
    fixHead: () => 'fix00000000000000000000000000000000000001',
    tailReview: [],
    staleness: () => [],
    ...overrides,
  })
  return JSON.stringify({
    labels: captured.calls.map(c => c.label).filter(l => l !== 'signals'),
    halted_at: result.halted_at, reviewers: result.reviewers, fix_rounds: result.fix_rounds,
    unresolved: (result.unresolved_findings ?? []).map(f => f.id), notes: (result.notes ?? []).length,
    size: result.size,
  })
}

async function scenarioNothingTheRunDecidesReadsTheSignals() {
  console.log('\n== scenario: raised, clear and missing signals give the same run')
  const shapes = {
    'a mid-sized diff, one fix round': {},
    'a big diff, three lenses': { diffstatFiles: [['a.js', 300, 0], ['b.js', 300, 0]] },
    'a one-line diff, no lenses': { diffstatFiles: [['a.js', 5, 0]] },
    'support code outweighing the change, the ratio halt': { diffstatFiles: [['a.js', 20, 0], ['a_test.js', 1000, 0]] },
    'a finding that is never fixed, the fix halt': { verify: () => undefined },
  }
  for (const [what, shape] of Object.entries(shapes)) {
    const raised = await outcomeOf({ ...shape, signalValues: RAISED })
    const clear = await outcomeOf({ ...shape, signalValues: CLEAR })
    const missing = await outcomeOf({ ...shape, signalsReply: () => null })
    check(`${what}: raised and clear agree`, raised, clear)
    check(`${what}: raised and missing agree`, raised, missing)
  }
  const reviewers = {}
  for (const [what, files] of Object.entries({ mid: [['a.js', 100, 0], ['b.js', 100, 0]],
      big: [['a.js', 300, 0], ['b.js', 300, 0]], tiny: [['a.js', 5, 0]] })) {
    reviewers[what] = JSON.parse(await outcomeOf({ diffstatFiles: files, signalValues: RAISED })).reviewers
  }
  check('the lens counts are still the size\'s', reviewers, { mid: 2, big: 3, tiny: 0 })
  check('the ratio halt still fires on the size alone',
    JSON.parse(await outcomeOf({ diffstatFiles: [['a.js', 20, 0], ['a_test.js', 1000, 0]], signalValues: CLEAR })).halted_at,
    'Review')
}

const SCENARIOS = [
  scenarioSignalsReachTheResult,
  scenarioSignalsAreOneDispatchAfterTheDraft,
  scenarioSignalsAreMeasuredOverTheDiffstatRange,
  scenarioSignalsAreInEveryHaltAfterTheDraft,
  scenarioSignalsAreNullInEveryHaltBeforeTheDraft,
  scenarioAProbeThatFailsLeavesNullAndTheRunGoesOn,
  scenarioParseSignalsRejects,
  scenarioParseSignalsAccepts,
  scenarioARefusedDispatchStillReachesTheBudgetHalt,
  scenarioNothingTheRunDecidesReadsTheSignals,
]
JS_EOF

finish
