#!/usr/bin/env bash
# The change-risk signals (gh-141): how the script reads the probe's block,
# retries a malformed one exactly once, carries the result on every halt from
# Draft PR on and on the final result, and changes nothing about review.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/harness.sh"

run_js_scenarios <<'JS_EOF'
const BUDGETED = { runBudget: 1_000_000 }
const has = (obj, key) => Object.prototype.hasOwnProperty.call(obj, key)
const PARSED = { range: COMMIT_RANGE, signals: riskEntries() }
const riskCalls = (captured) => captured.calls.filter(c => c.label.startsWith('risk-signals'))

// Scenario RSA -- a well-formed block is read once and kept as it came.
async function scenarioRSA() {
  console.log('\n== scenario RSA: a well-formed block is parsed, kept, and asked for once')
  const { result, captured } = await run({ initialReview: { correctness: [], advocate: [] } })
  check('the record is the range and the parsed signals', result.risk_signals, PARSED)
  check('the probe was dispatched once, with no retry', riskCalls(captured).map(c => c.label), ['risk-signals'])
  const call = riskCalls(captured)[0]
  check('it names the script, the worktree and the exact range',
    call.prompt.includes(`risk-signals.sh ${STUB_WT_PATH} ${COMMIT_RANGE}`), true)
  check('it is a cheap relay: haiku at low effort, in the Draft PR phase',
    [call.model, call.effort, call.phase], ['haiku', 'low', 'Draft PR'])
  check('it asks for the output verbatim', call.prompt.includes('verbatim'), true)
  check('its schema takes the output as one string',
    call.schema?.properties?.output?.type, 'string')
}

// Scenario RSB -- every way a block can be malformed is refused, asked for once
// more, and then recorded as unmeasured with the run carrying on.
const MALFORMED = {
  'a wrong range': (range) => riskOutput(range.replace('base', 'other')),
  'a missing begin marker': (range) => riskOutput(range).split('\n').slice(1).join('\n'),
  'a missing end marker': (range) => riskOutput(range).split('\n').slice(0, 2).join('\n'),
  'an extra body line': (range) => riskOutput(range)
    .replace('\nTOUCHSTONE_RISK_SIGNALS_END', '\nextra\nTOUCHSTONE_RISK_SIGNALS_END'),
  'prose around the block': (range) => `Here is the output:\n${riskOutput(range)}`,
  'invalid JSON': (range) => `TOUCHSTONE_RISK_SIGNALS ${range}\n{not json}\nTOUCHSTONE_RISK_SIGNALS_END`,
  'a JSON line that is not an object with signals': (range) =>
    `TOUCHSTONE_RISK_SIGNALS ${range}\n[1]\nTOUCHSTONE_RISK_SIGNALS_END`,
  'a missing key': (range) => {
    const entries = riskEntries()
    delete entries.files
    return riskOutput(range, {}, entries)
  },
  'an extra key': (range) => riskOutput(range, {}, { ...riskEntries(), bonus: { value: true, evidence: 'x' } }),
  'an entry that is not an object': (range) => riskOutput(range, { la: 3 }),
  'an entry with no evidence': (range) => riskOutput(range, { la: { value: 3 } }),
  'an entry with a reason but a measured value': (range) => riskOutput(range, { la: { value: 3, reason: 'x' } }),
  'an unmeasured entry with no reason': (range) => riskOutput(range, { la: { value: 'unmeasured' } }),
  'a string value': (range) => riskOutput(range, { la: { value: 'yes', evidence: 'x' } }),
  'a null value': (range) => riskOutput(range, { la: { value: null, evidence: 'x' } }),
  'empty evidence': (range) => riskOutput(range, { la: { value: 3, evidence: '' } }),
  'evidence over 400 characters': (range) => riskOutput(range, { la: { value: 3, evidence: 'x'.repeat(401) } }),
  'a field an entry should not have': (range) => riskOutput(range, { la: { value: 3, evidence: 'x', note: 'y' } }),
}
async function scenarioRSB() {
  for (const [name, make] of Object.entries(MALFORMED)) {
    console.log(`\n== scenario RSB: ${name} is refused, retried once, and recorded as unmeasured`)
    const { result, captured } = await run({ risk: make, initialReview: { correctness: [], advocate: [] } })
    check('one probe and exactly one retry', riskCalls(captured).map(c => c.label), ['risk-signals', 'risk-signals:retry'])
    check('the record says the range was not measured', result.risk_signals?.range, COMMIT_RANGE)
    check('and why', typeof result.risk_signals?.unmeasured === 'string' &&
      result.risk_signals.unmeasured.includes('even after a retry'), true)
    check('it carries no signals', has(result.risk_signals ?? {}, 'signals'), false)
    check('the run carried on: no new halt', result.halted_at, undefined)
    check('review still ran', captured.calls.some(c => c.label === 'review:correctness'), true)
  }
}

// Scenario RSC -- a malformed first answer followed by a good retry is a good record.
async function scenarioRSC() {
  console.log('\n== scenario RSC: a malformed block followed by a good one on the retry is parsed')
  const { result, captured } = await run({
    risk: 'not a block', riskRetry: (range) => riskOutput(range),
    initialReview: { correctness: [], advocate: [] },
  })
  check('the retry\'s block is the record', result.risk_signals, PARSED)
  check('the retry was dispatched once', riskCalls(captured).map(c => c.label), ['risk-signals', 'risk-signals:retry'])
  const [first, retry] = riskCalls(captured)
  check('it runs the same command', retry.prompt.includes(`risk-signals.sh ${STUB_WT_PATH} ${COMMIT_RANGE}`), true)
  check('with the same model and effort', [retry.model, retry.effort], [first.model, first.effort])
}

// Scenario RSD -- a probe that returns nothing at all is the same as a malformed one.
async function scenarioRSD() {
  console.log('\n== scenario RSD: a probe that fails outright is retried once, then unmeasured')
  const { result, captured } = await run({ risk: null, initialReview: { correctness: [], advocate: [] } })
  check('one probe and one retry', riskCalls(captured).map(c => c.label), ['risk-signals', 'risk-signals:retry'])
  check('the record is unmeasured', typeof result.risk_signals?.unmeasured, 'string')
  check('the run did not halt', result.halted_at, undefined)
}

// Scenario RSE -- a halt before the implementer returns has no signals; one after
// it says why none were measured; every halt from Draft PR on carries the block,
// the run-budget halt included.
async function scenarioRSE() {
  console.log('\n== scenario RSE: halts before the implementer returns carry risk_signals: null')
  const early = await run({ args: BUDGETED, spendAllAfter: 'triage' })
  check('halted at Implement', early.result.halted_at, 'Implement')
  check('the key is present', has(early.result, 'risk_signals'), true)
  check('and null', early.result.risk_signals, null)
  check('the probe never ran', riskCalls(early.captured).length, 0)
  const refusedImpl = await run({ implExtra: { unsupported_language: true } })
  check('a halt at Implement after the implementer returned', refusedImpl.result.halted_at, 'Implement')
  check('names the range it committed', refusedImpl.result.risk_signals?.range, COMMIT_RANGE)
  check('and says it was not measured', typeof refusedImpl.result.risk_signals?.unmeasured, 'string')
  check('the probe never ran', riskCalls(refusedImpl.captured).length, 0)
  const afterImpl = await run({ args: BUDGETED, spendAllAfter: 'implementer' })
  check('the draft-pr dispatch is the first one refused', afterImpl.result.halted_at, 'Draft PR')
  check('so Draft PR is the first phase whose halt carries a record',
    typeof afterImpl.result.risk_signals?.unmeasured, 'string')

  console.log('\n== scenario RSE: the run budget refusing the probe itself still leaves a record')
  const refused = await run({ args: BUDGETED, spendAllAfter: 'draft-pr' })
  check('halted at Draft PR', refused.result.halted_at, 'Draft PR')
  check('the probe was the refused dispatch', (refused.result.note ?? '').includes("'risk-signals'"), true)
  check('the record names the range', refused.result.risk_signals?.range, COMMIT_RANGE)
  check('and says it was not measured', typeof refused.result.risk_signals?.unmeasured, 'string')

  console.log('\n== scenario RSE: a halt at Review carries the block')
  const review = await run({ sizeUnmeasured: true })
  check('halted at Review', review.result.halted_at, 'Review')
  check('the block is there', review.result.risk_signals, PARSED)

  console.log('\n== scenario RSE: the run-budget halt after the probe carries the block')
  const budget = await run({
    args: BUDGETED, spendAllAfter: 'fix:1',
    initialReview: { correctness: [{ title: 'Off-by-one', file: 'src/p.js', claim: 'c1', evidence: 'e1' }], advocate: [] },
    fixHead: () => 'fix00000000000000000000000000000000000001',
  })
  check('halted at Fix by the budget', (budget.result.note ?? '').includes('Run budget exhausted'), true)
  check('the block is there', budget.result.risk_signals, PARSED)

  console.log('\n== scenario RSE: a halt at Fix carries the block')
  const fix = await run(exhausting())
  check('halted at Fix', fix.result.halted_at, 'Fix')
  check('the block is there', fix.result.risk_signals, PARSED)

  console.log('\n== scenario RSE: a halt at Mutation carries the block')
  const mutation = await run({
    mutationGated: true, initialReview: { correctness: [], advocate: [] },
    mutationResult: () => ({ green: false, head_sha: 'mut0000000000000000000000000000000000001',
      detail: 'stub red', scored: false }),
  })
  check('halted at Mutation', mutation.result.halted_at, 'Mutation')
  check('the block is there', mutation.result.risk_signals, PARSED)

  console.log('\n== scenario RSE: the final result carries the block')
  const done = await run({ initialReview: { correctness: [], advocate: [] } })
  check('the run finished', done.result.halted_at, undefined)
  check('the block is there', done.result.risk_signals, PARSED)
}

// What a run reviews and fixes must not depend on what the probe measured: the
// same lenses, the same rounds, the same ceilings. Two runs per diffstat size,
// one that fixes nothing until the rounds run out and one that converges and
// goes on to the mutation gate, each with every kind of block.
const KINDS = {
  clear: (range) => riskOutput(range),
  raised: (range) => riskOutput(range, Object.fromEntries(RISK_KEYS.map(k =>
    [k, { value: RISK_NUMBERS.has(k) ? 999 : true, evidence: 'raised' }]))),
  unmeasured: (range) => riskOutput(range, Object.fromEntries(RISK_KEYS.map(k =>
    [k, { value: 'unmeasured', reason: 'no tool' }]))),
  malformed: () => 'not a signals block',
}
const TWO_LENSES = [['a.js', 100, 0], ['b.js', 100, 0]]
const THREE_LENSES = [['a.js', 300, 0], ['b.js', 300, 0]]
const FINDING = { title: 'Off-by-one', file: 'src/p.js', claim: 'c1', evidence: 'e1' }
const roundHead = (round) => `fix${String(round).padStart(2, '0')}${'0'.repeat(36)}`

function exhausting(extra = {}) {
  return {
    initialReview: { correctness: [FINDING], advocate: [], requirements: [] },
    verify: () => false, fixHead: roundHead, staleness: () => [],
    budgetPerAgentCall: 1000, ...extra,
  }
}
function converging(extra = {}) {
  return {
    initialReview: { correctness: [FINDING], advocate: [], requirements: [] },
    verify: (id) => id === 'f1', fixHead: roundHead, staleness: () => [],
    mutationGated: true, budgetPerAgentCall: 1000, ...extra,
  }
}
const reviewShape = (captured, result) => ({
  labels: captured.calls.map(c => c.label).filter(l => /^(review|fix|mutation|reproduce)/.test(l)),
  rounds: result.fix_rounds,
  halted: result.halted_at,
  ceilings: captured.logs.filter(l => /^\w+: \d+k output tokens/.test(l)),
  stage_spend: result.stage_spend,
})
async function scenarioRSF() {
  for (const [lensName, files, lensLabels] of [
    ['two lenses', TWO_LENSES, ['review:correctness', 'review:advocate']],
    ['three lenses', THREE_LENSES, ['review:correctness', 'review:advocate', 'review:requirements']]]) {
    for (const [runName, build, expectedRounds] of [['rounds run out', exhausting, 3], ['converges through mutation', converging, 1]]) {
      console.log(`\n== scenario RSF: ${lensName}, ${runName}: review does not depend on the signals`)
      const shapes = {}
      for (const [kind, make] of Object.entries(KINDS)) {
        const { result, captured } = await run(build({ diffstatFiles: files, risk: make }))
        shapes[kind] = reviewShape(captured, result)
      }
      const { clear } = shapes
      check(`the lenses that ran are ${lensLabels.join(', ')}`,
        lensLabels.every(l => clear.labels.includes(l)) &&
        clear.labels.includes('review:requirements') === (lensLabels.length === 3), true)
      check(`fix rounds are ${expectedRounds} (MAX_REVIEW_ROUNDS is 3)`, clear.rounds, expectedRounds)
      check('the ceiling logs are not empty', clear.ceilings.length > 3, true)
      if (runName === 'converges through mutation') {
        check('the mutation gate ran', clear.labels.includes('mutation:1'), true)
      }
      for (const kind of ['raised', 'unmeasured', 'malformed']) {
        check(`${kind} blocks leave labels, rounds, halts, ceilings and spend as a clear block has them`,
          shapes[kind], clear)
      }
    }
  }
}

const SCENARIOS = [scenarioRSA, scenarioRSB, scenarioRSC, scenarioRSD, scenarioRSE, scenarioRSF]
JS_EOF

echo ""
echo "== static: review is untouched =="
check "lensKeysFor is still the one pure sizing function" \
  "$(grep -Fc 'const lensKeysFor = (size) =>' "$SCRIPT" || true)" 1
check "MAX_REVIEW_ROUNDS is still 3 by default" \
  "$(grep -Fc 'const MAX_REVIEW_ROUNDS = args?.maxReviewRounds ?? 3' "$SCRIPT" || true)" 1
check "the probe opens no stage and has no ceiling" \
  "$(grep -Ec "stage\('risk|risk[a-z-]*: [0-9_]+,? *\$" "$SCRIPT" || true)" 0
check "the probe is dispatched through treeAgent, so through dispatch()" \
  "$(grep -Fc "treeAgent(riskPromptFor(riskRange), riskOpts('risk-signals'))" "$SCRIPT" || true)" 1
check "the retry has its own label" \
  "$(grep -Fc "treeAgent(riskPromptFor(riskRange), riskOpts('risk-signals:retry'))" "$SCRIPT" || true)" 1

finish
