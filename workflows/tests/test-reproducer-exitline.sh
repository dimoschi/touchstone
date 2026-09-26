#!/usr/bin/env bash
# Scenarios scenarioEH..scenarioFZ, split out of
# test-fix-loop-join.sh (gh-118); see harness.sh.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/harness.sh"

run_js_scenarios <<'JS_EOF'
async function scenarioEH() {
  console.log('\n== scenario EH: a dirty-tree halt in a fix round keeps the open findings, notes and round')
  const { result } = await run({
    args: { maxReviewRounds: 2 },
    dirtyAt: 'reproduce:fix:1',
    initialReview: {
      correctness: [{ title: 'Route resolves from cwd', file: 'src/route.js',
        claim: 'wrong repo', evidence: 'route.js:12' }],
      advocate: [{ category: 'docs', title: 'Stale README line', file: 'README.md',
        claim: 'mentions the old flag', evidence: 'README.md:3', reproducer: undefined }],
    },
    fixHead: () => 'fix00000000000000000000000000000000000001',
    staleness: () => [],
  })
  check('halted at Fix', result.halted_at, 'Fix')
  check('the open finding is carried', result.unresolved_findings?.some(f => f.file === 'src/route.js'), true)
  check('the note is carried', result.notes?.some(n => n.title === 'Stale README line'), true)
  check('the round is carried', result.fix_rounds, 1)
}

async function scenarioEI() {
  console.log('\n== scenario EI: a dirty-tree halt at the initial review keeps its notes, before any round exists')
  const { result } = await run({
    dirtyAt: 'reproduce:review',
    initialReview: {
      correctness: [{ title: 'Route resolves from cwd', file: 'src/route.js',
        claim: 'wrong repo', evidence: 'route.js:12' }],
      advocate: [{ category: 'docs', title: 'Stale README line', file: 'README.md',
        claim: 'mentions the old flag', evidence: 'README.md:3', reproducer: undefined }],
    },
  })
  check('halted at Review', result.halted_at, 'Review')
  check('the note is carried', result.notes?.some(n => n.title === 'Stale README line'), true)
  check('no fix round has run', result.fix_rounds, 0)
}

// Scenarios FA-FG -- gh-113: a nonzero exit alone no longer counts as a
// demonstration. outputFor lets a scenario control the executor's raw output
// per id/exit-code, independent of the auto-marker reproduceResponse gives
// every other scenario by default.
async function scenarioFA() {
  console.log('\n== scenario FA: a fresh candidate whose reproducer exits nonzero with no marker is a note (reproducer-errored), never a candidate that opens')
  const { result, captured } = await run({
    initialReview: {
      correctness: [{ title: 'Looks like a crash', file: 'a.js', claim: 'c', evidence: 'e' }],
      advocate: [],
    },
    initialExit: () => 1,
    outputFor: () => 'Traceback (most recent call last):\n  File "a.py", line 3\nValueError: boom',
  })
  check('nothing opens', result.unresolved_findings?.length ?? 0, 0)
  const note = result.notes?.find(n => n.title === 'Looks like a crash')
  check('the finding is a note with reason reproducer-errored', note?.reason, 'reproducer-errored')
  check('the note keeps the outcome', note?.reproducer_run?.outcome, 'errored')
  check('the note keeps the exit code', note?.reproducer_run?.exit_code, 1)
  check('the note keeps the real output', /ValueError: boom/.test(note?.reproducer_run?.output ?? ''), true)
  check('no fix round ran', callCount(captured, 'fix:1'), 0)
}

async function scenarioFB() {
  console.log('\n== scenario FB: the marker is matched against the raw output before truncation, even when truncation would otherwise have hidden it')
  const bigOutput = 'A'.repeat(2000) + `\n${REPRODUCED_MARKER}\n` + 'B'.repeat(10000)
  const { result } = await run({
    initialReview: {
      correctness: [{ title: 'Oversized reproduction', file: 'a.js', claim: 'c', evidence: 'e' }],
      advocate: [],
    },
    initialExit: () => 1,
    outputFor: () => bigOutput,
  })
  check('it opens: the marker was seen before truncation', result.unresolved_findings?.length, 1)
  const stored = result.unresolved_findings?.[0]?.reproducer_run?.output ?? ''
  check('the stored output shows the truncation marker', /\[touchstone: truncated,/.test(stored), true)
  check('the marker line itself fell in the omitted middle and is gone from the stored copy',
    stored.includes(REPRODUCED_MARKER), false)
}

async function scenarioFC() {
  console.log('\n== scenario FC: a marker embedded inside a longer line does not count, and the result is reproducer-errored')
  const { result } = await run({
    initialReview: {
      correctness: [{ title: 'Fooled by a substring marker', file: 'a.js', claim: 'c', evidence: 'e' }],
      advocate: [],
    },
    initialExit: () => 1,
    outputFor: () => `+ echo ${REPRODUCED_MARKER}\nsome other trailing text`,
  })
  check('nothing opens', result.unresolved_findings?.length ?? 0, 0)
  check('the finding is a note with reason reproducer-errored',
    result.notes?.find(n => n.title === 'Fooled by a substring marker')?.reason, 'reproducer-errored')
}

async function scenarioFD() {
  console.log('\n== scenario FD: an open finding settles on exit 0 regardless of the marker, stays open as reproduced on nonzero with it, and stays open as errored -- with the crash carried into the next fix brief -- on nonzero without it')
  const lastRoundById = {}
  const { result, captured } = await run({
    args: { maxReviewRounds: 2 },
    initialReview: {
      correctness: [
        { title: 'Gets fixed', file: 'a.js', claim: 'ca', evidence: 'ea' },
        { title: 'Still reproduces', file: 'b.js', claim: 'cb', evidence: 'eb' },
        { title: 'Reproducer crashes on recheck', file: 'c.js', claim: 'cc', evidence: 'ec' },
      ],
      advocate: [],
    },
    initialExit: (id) => { lastRoundById[id] = 0; return 1 },
    verify: (id, round) => { lastRoundById[id] = round; return (id === 'f1' && round >= 1) ? 0 : 1 },
    outputFor: (id, code) => {
      if (code === 0) return id === 'f1' ? `done\n${REPRODUCED_MARKER}` : 'ok'
      if (id === 'f3' && lastRoundById[id] >= 1) {
        return 'Traceback (most recent call last):\nRuntimeError: reproducer crashed, no marker'
      }
      return `still there\n${REPRODUCED_MARKER}`
    },
    tailReview: [],
    staleness: () => [],
  })
  check('halted at Fix (the round limit)', result.halted_at, 'Fix')
  check('f1 settled on exit 0 even though its output still carried the marker',
    result.unresolved_findings?.some(f => f.file === 'a.js'), false)
  const f2 = result.unresolved_findings?.find(f => f.file === 'b.js')
  const f3 = result.unresolved_findings?.find(f => f.file === 'c.js')
  check('f2 stays open as reproduced', f2?.reproducer_run?.outcome, 'reproduced')
  check('f3 stays open as errored', f3?.reproducer_run?.outcome, 'errored')
  check('f3 carries its crash exit code', f3?.reproducer_run?.exit_code, 1)
  check('f3 carries its crash output', /RuntimeError/.test(f3?.reproducer_run?.output ?? ''), true)
  const fixBrief2 = captured.calls.find(c => c.label === 'fix:2')?.prompt ?? ''
  check('the next fix brief says the reproducer itself failed to run',
    fixBrief2.includes('reproducer itself failed to run'), true)
  check('the next fix brief shows the crash exit code', fixBrief2.includes('exit 1'), true)
  check('the next fix brief shows the crash output', fixBrief2.includes('RuntimeError'), true)
}

async function scenarioFE() {
  console.log('\n== scenario FE: the settled recheck splits a regression from an errored reproducer, logs them separately, and reopens both')
  // outputFor only sees (id, code), and f2's own opening and round-1 checks
  // also pass it a nonzero code, so it needs to know the recheck it is
  // building output for, not just which id: phase records that.
  let phase = 'initial'
  const { result, captured } = await run({
    args: { maxReviewRounds: 2 },
    initialReview: {
      correctness: [
        { title: 'Fixed round 1', file: 'a.js', claim: 'ca', evidence: 'ea' },
        { title: 'Fixed round 1 too', file: 'b.js', claim: 'cb', evidence: 'eb' },
        { title: 'Never settles', file: 'z.js', claim: 'cz', evidence: 'ez' },
      ],
      advocate: [],
    },
    initialExit: () => { phase = 'initial'; return 1 },
    verify: (id, round) => {
      phase = `verify:${round}`
      if (id === 'f3') return 1 // keeps the loop alive through round 2
      return round === 1 ? 0 : 1
    },
    settledExit: (id, round) => {
      phase = `settled:${round}`
      return (round === 2 && (id === 'f1' || id === 'f2')) ? 1 : 0
    },
    outputFor: (id, code) => {
      if (code === 0) return 'ok'
      if (phase === 'settled:2' && id === 'f2') return 'Traceback: something else crashed, no marker'
      return `still there\n${REPRODUCED_MARKER}`
    },
    tailReview: [],
    staleness: () => [],
  })
  check('halted at Fix', result.halted_at, 'Fix')
  const a = result.unresolved_findings?.find(f => f.file === 'a.js')
  const b = result.unresolved_findings?.find(f => f.file === 'b.js')
  check('the still-reproducing settled finding reopens as regressed (reproduced)',
    a?.reproducer_run?.outcome, 'reproduced')
  check('the crashed settled finding reopens as errored', b?.reproducer_run?.outcome, 'errored')
  check('the regression is logged',
    captured.logs.some(l => l.includes('earlier fix(es) no longer hold at this head; reopened')), true)
  check('the errored settled recheck is logged separately',
    captured.logs.some(l => l.includes('could not be re-measured this round (reproducer errored')), true)
}

async function scenarioFF() {
  console.log('\n== scenario FF: the mutation gate\'s settled recheck counts an undone fix and an errored reproducer separately, and halts at Review either way')
  // Same reasoning as FE's phase tracking: f2 has to open and settle
  // normally first, and only crash (no marker) at the mutation recheck.
  let phase = 'initial'
  const { result } = await run(convergedWithSuspect({
    tailReview: [],
    initialReview: {
      correctness: [
        { title: 'Off-by-one in parser', file: 'src/parser.js', claim: 'boundary is wrong', evidence: 'parser.js:12' },
        { title: 'Missing null check', file: 'src/guard.js', claim: 'no guard', evidence: 'guard.js:3' },
      ],
      advocate: [],
    },
    verify: (id, round) => { phase = `verify:${round}`; return (id === 'f1' || id === 'f2') ? true : undefined },
    mutationResult: () => ({ green: true, head_sha: 'mut0000000000000000000000000000000000001',
      detail: 'stub green', scored: true }),
    settledExit: (id, round) => { phase = `settled:${round}`; return (round === 'mutation') ? 1 : 0 },
    outputFor: (id, code) => {
      if (code === 0) return 'ok'
      if (phase === 'settled:mutation' && id === 'f2') return 'Traceback: mutation-introduced crash, no marker'
      return `still fails\n${REPRODUCED_MARKER}`
    },
  }))
  check('halted at Review', result.halted_at, 'Review')
  const undoneF = result.unresolved_findings?.find(f => f.file === 'src/parser.js')
  const erroredF = result.unresolved_findings?.find(f => f.file === 'src/guard.js')
  check('the undone fix is reported and recorded as regressed (reproduced)',
    undoneF?.reproducer_run?.outcome, 'reproduced')
  check('the errored fix is reported and recorded distinctly', erroredF?.reproducer_run?.outcome, 'errored')
  check('the halt note counts the undone fix',
    /undid 1 verified fix/.test(result.note ?? ''), true)
  check('the halt note counts the errored fix separately',
    /left 1 verified fix/.test(result.note ?? ''), true)
}

// Scenario FG -- #109, the real-world case this ticket is about: node
// <scratch>/quote-repro.mjs read process.env.TOUCHSTONE_REPO_ROOT, which the
// recorded command never set itself, so the executor's own run of it always
// crashed (validateString(arg, 'path'), the real ERR_INVALID_ARG_TYPE) before
// it could ever demonstrate anything. Run for real via spawnSync, not
// simulated with a synthetic exit code, so the crash text this asserts
// against is what Node actually produces.
async function scenarioFG() {
  console.log('\n== scenario FG: #109 -- a real reproducer that crashes on an unset env var errors instead of demonstrating anything, and settles once the underlying fix removes the need for it')
  const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'touchstone-109-'))
  const scriptPath = path.join(scratch, 'repro109.mjs')
  const flagPath = path.join(scratch, 'fixed.flag')
  fs.writeFileSync(scriptPath, [
    "import path from 'node:path'",
    "import fs from 'node:fs'",
    "const flagPath = process.argv[2]",
    "if (fs.existsSync(flagPath)) process.exit(0)",
    "path.join(process.env.TOUCHSTONE_REPO_ROOT, 'quote-repro-target')",
    "console.log('TOUCHSTONE_DEFECT_REPRODUCED')",
    "process.exit(1)",
  ].join('\n') + '\n')
  const noRootEnv = { ...process.env }
  delete noRootEnv.TOUCHSTONE_REPO_ROOT
  const withRootEnv = { ...process.env, TOUCHSTONE_REPO_ROOT: scratch }
  let last = null
  const runReal = (env) => {
    const r = spawnSync('node', [scriptPath, flagPath], { env, encoding: 'utf8' })
    last = { status: r.status ?? 1, output: `${r.stdout ?? ''}${r.stderr ?? ''}` }
    return last.status
  }
  try {
    // Before a fix: run as recorded (variable unset) from the very first
    // execution. It crashes before ever printing the marker, so the finding
    // never opens at all.
    const before = await run({
      initialReview: {
        correctness: [{ title: 'Quote breaks the built invocation', file: 'workflows/deliver-pipeline.js',
          claim: 'a single quote in a check command reaches the shell unescaped', evidence: 'invocationFor',
          reproducer: { kind: 'command', command: `node ${scriptPath} ${flagPath}`,
            expected: 'exit 0', actual: 'crashes' } }],
        advocate: [],
      },
      initialExit: () => runReal(noRootEnv),
      outputFor: () => last.output,
    })
    check('before a fix: nothing opens', before.result.unresolved_findings?.length ?? 0, 0)
    const note = before.result.notes?.find(n => n.title === 'Quote breaks the built invocation')
    check('before a fix: it is a reproducer-errored note', note?.reason, 'reproducer-errored')
    check('before a fix: the note carries the real crash output',
      /ERR_INVALID_ARG_TYPE/.test(note?.reproducer_run?.output ?? ''), true)
    check('before a fix: no fix round ran', callCount(before.captured, 'fix:1'), 0)

    // After a fix: round 0 happens to run with the variable set, so the
    // marker prints for real and the finding opens genuinely. The recheck at
    // round 1 still runs the very same command as recorded -- variable
    // unset -- so it crashes again; the finding stays open as errored and
    // that crash reaches the next fix brief. Only once the underlying defect
    // is actually gone (flagPath exists) does the same recorded command,
    // still never setting the variable, exit 0 and settle.
    const after = await run({
      args: { maxReviewRounds: 3 },
      initialReview: {
        correctness: [{ title: 'Quote breaks the built invocation', file: 'workflows/deliver-pipeline.js',
          claim: 'a single quote in a check command reaches the shell unescaped', evidence: 'invocationFor',
          reproducer: { kind: 'command', command: `node ${scriptPath} ${flagPath}`,
            expected: 'exit 0', actual: 'crashes' } }],
        advocate: [],
      },
      initialExit: () => runReal(withRootEnv),
      verify: () => runReal(noRootEnv),
      outputFor: () => last.output,
      fixHead: (round) => {
        if (round === 2) fs.writeFileSync(flagPath, 'fixed')
        return `fix0000000000000000000000000000000000000${round}`
      },
      tailReview: [],
      staleness: () => [],
    })
    check('after a fix: the finding opened for real and got a fix round',
      callCount(after.captured, 'fix:1'), 1)
    check('after a fix: it stayed open into a second round (the recheck errored, not settled)',
      callCount(after.captured, 'fix:2'), 1)
    const fixBrief2 = after.captured.calls.find(c => c.label === 'fix:2')?.prompt ?? ''
    check('after a fix: the next fix brief says the reproducer itself failed to run',
      fixBrief2.includes('reproducer itself failed to run'), true)
    check('after a fix: the fix brief carries the real crash output',
      fixBrief2.includes('ERR_INVALID_ARG_TYPE'), true)
    check('after a fix: it settles once the reproducer exits 0, run as recorded (variable still unset)',
      after.result.halted_at, undefined)
    check('after a fix: no third round was needed', callCount(after.captured, 'fix:3'), 0)
  } finally {
    fs.rmSync(scratch, { recursive: true, force: true })
  }
}

// Scenario FH -- gh-113/#116: the executor dropping a row (or the whole call
// failing schema, which nulls every row) is retried once, at the same head.
// Still no row after that is not a note either -- unlike passed/could-not-run/
// errored, it is no verdict at all -- so it halts the run rather than waving
// a fresh blocking finding through or looping the round limit on nothing.
async function scenarioFH() {
  console.log('\n== scenario FH: gh-113 -- a candidate the executor never runs, even on retry, halts at Review rather than opening on nothing or becoming a note')
  const { result, captured } = await run({
    args: { openPr: true },
    draftPr: { opened: true, number: 23, url: 'https://example.invalid/pr/23', detail: 'stub draft' },
    prResult: { opened: true, url: 'https://example.invalid/pr/23', note: 'stub ready' },
    initialReview: {
      correctness: [{ title: 'Never demonstrated', file: 'a.js', claim: 'c', evidence: 'e' }],
      advocate: [{ category: 'docs', title: 'A style nit', file: 'b.js', claim: 'cosmetic', evidence: 'e2' }],
    },
    initialExit: () => undefined,
  })
  check('halted at Review', result.halted_at, 'Review')
  check('the retry ran exactly once', callCount(captured, 'reproduce:review:retry'), 1)
  check('no PR was marked ready', callCount(captured, 'pr'), 0)
  check('no fix round ran', callCount(captured, 'fix:1'), 0)
  const stuck = result.unresolved_findings?.find(f => f.title === 'Never demonstrated')
  check('the finding is carried with outcome not-executed', stuck?.reproducer_run?.outcome, 'not-executed')
  check('the halt note names the finding by id', (result.note ?? '').includes('f1'), true)
  check('the halt note names the finding by title', (result.note ?? '').includes('Never demonstrated'), true)
  check('the halt note says this is about measurement, not the code',
    (result.note ?? '').includes('about measurement, not the code'), true)
  check('the halt carries the checks payload', typeof result.checks?.discovered, 'number')
  check('fix_rounds is 0', result.fix_rounds, 0)
  check('notes is carried as an array', Array.isArray(result.notes), true)
  check('the unrelated non-blocking finding is still a note',
    result.notes?.some(n => n.title === 'A style nit'), true)
}

// Scenario FI -- gh-113: a candidate the executor drops on its first call but
// measures on the retry opens exactly as if the first call had reported it,
// and only the dropped candidate's id reaches the retry prompt.
async function scenarioFI() {
  console.log('\n== scenario FI: gh-113 -- a candidate the executor drops once opens once the retry returns a row')
  const { result, captured } = await run({
    args: { maxReviewRounds: 1 },
    initialReview: {
      correctness: [
        { title: 'Dropped once', file: 'a.js', claim: 'c1', evidence: 'e1' },
        { title: 'Measured first try', file: 'b.js', claim: 'c2', evidence: 'e2' },
      ],
      advocate: [],
    },
    initialExit: (id, retry) => (id === 'f1' && !retry) ? undefined : 1,
    verify: () => false,
    fixHead: () => 'fix00000000000000000000000000000000000001',
    staleness: () => [],
  })
  check('the retry ran exactly once', callCount(captured, 'reproduce:review:retry'), 1)
  const retryPrompt = captured.calls.find(c => c.label === 'reproduce:review:retry')?.prompt ?? ''
  check('only the dropped candidate reruns', idsIn(retryPrompt), ['f1'])
  check('the retried finding opened (a fix round ran on it)', callCount(captured, 'fix:1'), 1)
  check('nothing settled as a note instead', result.notes?.length ?? 0, 0)
  check('no executor call overlapped another agent', overlapsWithExecutor(captured), [])
}

// Scenario FJ -- the same retry-then-halt for a fresh tail-review candidate:
// the fix loop must not spend a second round guessing at a reproducer nobody
// ran, and the halt still carries the round's other open finding.
async function scenarioFJ() {
  console.log('\n== scenario FJ: gh-113 -- a fresh fix-round candidate the executor never runs, even on retry, halts at Fix')
  const { result, captured } = await run({
    args: { maxReviewRounds: 3 },
    initialReview: {
      correctness: [{ title: 'Off-by-one in parser', file: 'src/parser.js',
        claim: 'boundary is wrong', evidence: 'parser.js:12' }],
      advocate: [],
    },
    verify: (id, round) => id === 'f2' ? 'norow' : false,
    fixHead: () => 'fix00000000000000000000000000000000000001',
    tailReview: [{ title: 'Never demonstrated in the fix', file: 'src/guard.js',
      claim: 'no guard', evidence: 'guard.js:3' }],
    staleness: () => [],
  })
  check('halted at Fix', result.halted_at, 'Fix')
  check('the fresh candidate\'s retry ran exactly once', callCount(captured, 'reproduce:fix:1:fresh:retry'), 1)
  check('no second fix round ran', callCount(captured, 'fix:2'), 0)
  check('the original finding stays open',
    result.unresolved_findings?.some(f => f.title === 'Off-by-one in parser'), true)
  const stuck = result.unresolved_findings?.find(f => f.title === 'Never demonstrated in the fix')
  check('the fresh finding is carried with outcome not-executed', stuck?.reproducer_run?.outcome, 'not-executed')
  check('the halt carries the checks payload', typeof result.checks?.discovered, 'number')
  check('fix_rounds is 1', result.fix_rounds, 1)
  check('notes is present', Array.isArray(result.notes), true)
  check('the halt note names the fresh finding by title',
    (result.note ?? '').includes('Never demonstrated in the fix'), true)
}

// Scenario FK -- the same rule at the post-mutation review: a fresh finding
// the mutation gate's own commits raised, never measured even on retry,
// halts rather than reaching the PR phase, and keeps the round's residual
// note (gh-106) alongside it.
async function scenarioFK() {
  console.log('\n== scenario FK: gh-113 -- a fresh post-mutation candidate the executor never runs, even on retry, halts at Review')
  const { result, captured } = await run(convergedWithSuspect({
    args: { openPr: true },
    prResult: { opened: true, url: 'https://example.invalid/pr/23', note: 'stub ready' },
    mutationResult: () => ({ green: true, head_sha: 'mut0000000000000000000000000000000000001',
      detail: 'stub green', scored: true }),
    postMutationReview: [{ title: 'New nil deref in the added test helper',
      file: 'src/helper.js', claim: 'deref before the guard', evidence: 'helper.js:8' }],
    verify: (id, round) => round === 'mutation' ? 'norow' : (id === 'f1' ? true : undefined),
  }))
  check('halted at Review', result.halted_at, 'Review')
  check('the retry ran exactly once', callCount(captured, 'reproduce:mutation:fresh:retry'), 1)
  check('no PR was marked ready', callCount(captured, 'pr'), 0)
  const stuck = result.unresolved_findings?.find(f => f.title === 'New nil deref in the added test helper')
  check('the fresh finding is carried with outcome not-executed', stuck?.reproducer_run?.outcome, 'not-executed')
  check('the halt note names the finding by title',
    (result.note ?? '').includes('New nil deref in the added test helper'), true)
  check('the halt carries the checks payload', typeof result.checks?.discovered, 'number')
  check('the residual note from the earlier fix round is still carried',
    result.notes?.filter(n => n.reason === 'residual').length, 1)
}

// Scenarios FL-FN -- gh-113: a dirty retry must not throw away what the
// first call (clean, at the same head) already measured. Each covers one of
// executeAndDispose's three callers: the retry here only ever covers the
// notExecuted subset, so the other candidates' verdicts from the first call
// have to reach the halt.
async function scenarioFL() {
  console.log('\n== scenario FL: gh-113 -- a dirty retry at the initial review still carries the first call\'s reproduced finding and note')
  const { result } = await run({
    initialReview: {
      correctness: [
        { title: 'Reproduced on the first call', file: 'a.js', claim: 'c1', evidence: 'e1' },
        { title: 'Dropped on the first call', file: 'b.js', claim: 'c2', evidence: 'e2' },
        { title: 'Passed on the first call', file: 'c.js', claim: 'c3', evidence: 'e3' },
      ],
      advocate: [],
    },
    initialExit: (id) => ({ f1: 1, f2: undefined, f3: 0 })[id],
    dirtyAt: 'reproduce:review:retry',
  })
  check('halted at Review', result.halted_at, 'Review')
  check('the dirty halt still carries the finding the first call reproduced',
    result.unresolved_findings?.some(f => f.title === 'Reproduced on the first call'), true)
  check('the dirty halt carries the candidate the dirty retry ran',
    result.unresolved_findings?.some(f => f.title === 'Dropped on the first call'), true)
  check('the dirty halt still carries the first call\'s did-not-reproduce note',
    result.notes?.some(n => n.title === 'Passed on the first call' && n.reason === 'did-not-reproduce'), true)
}

async function scenarioFM() {
  console.log('\n== scenario FM: gh-113 -- a dirty retry on a fresh fix-round candidate still carries the first call\'s reproduced finding and note')
  const { result } = await run({
    args: { maxReviewRounds: 3 },
    initialReview: {
      correctness: [{ title: 'Off-by-one in parser', file: 'src/parser.js',
        claim: 'boundary is wrong', evidence: 'parser.js:12' }],
      advocate: [],
    },
    verify: (id) => id === 'f1' ? false : ({ f2: 1, f3: 'norow', f4: 0 })[id],
    fixHead: () => 'fix00000000000000000000000000000000000001',
    tailReview: [
      { title: 'Reproduced in the fix', file: 'src/guard.js', claim: 'c2', evidence: 'e2' },
      { title: 'Dropped in the fix', file: 'src/guard2.js', claim: 'c3', evidence: 'e3' },
      { title: 'Passed in the fix', file: 'src/guard3.js', claim: 'c4', evidence: 'e4' },
    ],
    dirtyAt: 'reproduce:fix:1:fresh:retry',
    staleness: () => [],
  })
  check('halted at Fix', result.halted_at, 'Fix')
  check('the original finding stays open',
    result.unresolved_findings?.some(f => f.title === 'Off-by-one in parser'), true)
  check('the dirty halt still carries the fresh finding the first call reproduced',
    result.unresolved_findings?.some(f => f.title === 'Reproduced in the fix'), true)
  check('the dirty halt carries the candidate the dirty retry ran',
    result.unresolved_findings?.some(f => f.title === 'Dropped in the fix'), true)
  check('the dirty halt still carries the first call\'s did-not-reproduce note',
    result.notes?.some(n => n.title === 'Passed in the fix' && n.reason === 'did-not-reproduce'), true)
  check('fix_rounds is 1', result.fix_rounds, 1)
}

async function scenarioFN() {
  console.log('\n== scenario FN: gh-113 -- a dirty retry on a fresh post-mutation candidate still carries the first call\'s reproduced finding and note')
  const { result } = await run({
    initialReview: { correctness: [], advocate: [] },
    mutationGated: true,
    mutationResult: () => ({ green: true, head_sha: 'mut0000000000000000000000000000000000001',
      detail: 'stub green', scored: true }),
    postMutationReview: [
      { title: 'Reproduced post-mutation', file: 'a.js', claim: 'c1', evidence: 'e1' },
      { title: 'Dropped post-mutation', file: 'b.js', claim: 'c2', evidence: 'e2' },
      { title: 'Passed post-mutation', file: 'c.js', claim: 'c3', evidence: 'e3' },
    ],
    verify: (id, round) => round === 'mutation' ? ({ f1: 1, f2: 'norow', f3: 0 })[id] : undefined,
    dirtyAt: 'reproduce:mutation:fresh:retry',
  })
  check('halted at Review', result.halted_at, 'Review')
  check('the dirty halt still carries the finding the first call reproduced',
    result.unresolved_findings?.some(f => f.title === 'Reproduced post-mutation'), true)
  check('the dirty halt carries the candidate the dirty retry ran',
    result.unresolved_findings?.some(f => f.title === 'Dropped post-mutation'), true)
  check('the dirty halt still carries the first call\'s did-not-reproduce note',
    result.notes?.some(n => n.title === 'Passed post-mutation' && n.reason === 'did-not-reproduce'), true)
}

// Scenario FO -- #120: invocationFor's echo sits outside the -c string and
// after `;`, so a check that calls exit itself still gets its own exit code
// captured. Run for real against the built invocation, not a copy of it.
async function scenarioFO() {
  console.log('\n== scenario FO: the exit line survives even when the check itself calls exit')
  // STUB_WT_PATH does not exist on disk, so a real cd is needed here (unlike
  // scenario EL/EM, which only inspect the prompt's text): a `cd` into a
  // missing directory would exit nonzero on its own and mask exit 3 with cd's
  // own failure code instead.
  const wtPath = fs.mkdtempSync(path.join(os.tmpdir(), 'touchstone-fo-'))
  try {
    const { captured } = await run({
      branchResult: { created: true, branch: 'feat/gh-21-stub', base: 'main',
        path: wtPath, ticket: '21', detail: 'stub', dirty: false },
      discovery: { file: '/repo/AGENTS.md', sections: [{ heading: '## Checks', fence: 'exit 3' }], detail: 'stub' },
    })
    const runPrompt = captured.calls.find(c => c.label === 'checks:run:1')?.prompt ?? ''
    const line = runPrompt.split('\n').find(l => l.startsWith('check:1: '))
    const invocation = line ? line.slice('check:1: '.length) : ''
    const out = invocation ? execFileSync('bash', ['-c', invocation]).toString() : ''
    check('the first printed line is the exit marker with the check\'s real exit code',
      out.split('\n')[0], 'TOUCHSTONE_CHECK_EXIT check:1 3')
  } finally {
    fs.rmSync(wtPath, { recursive: true, force: true })
  }
}

// Scenario FP -- #120: classifyResults reads a row's exit code only from its
// exit line, never from exit_code, in both directions: a line disagreeing
// with the field wins either way. existingBranch skips the baseline (as in
// scenario BX) so nothing here gets dropped as environmental first.
async function scenarioFP() {
  console.log('\n== scenario FP: the exit line wins over a disagreeing exit_code field, both directions')
  const { result } = await run({
    args: { existingBranch: true, openPr: true },
    discovery: { file: '/repo/AGENTS.md',
      sections: [{ heading: '## Checks', fence: 'make test\nmake lint' }], detail: 'stub' },
    checkRuns: () => ({ results: [
      { id: 'check:1', command: checkInvocation('check:1', 'make test'), exit_code: 0,
        output: 'TOUCHSTONE_CHECK_EXIT check:1 1\nok' },
      { id: 'check:2', command: checkInvocation('check:2', 'make lint'), exit_code: 1,
        output: 'TOUCHSTONE_CHECK_EXIT check:2 0\nok' },
    ], dirty: false }),
    prResult: { opened: true, url: 'https://example.invalid/pr/120fp', note: 'stub ready' },
  })
  check('check:1 is red, keyed on its exit line despite an exit_code: 0 field',
    result.checks?.red?.some(c => c.id === 'check:1'), true)
  check('check:1\'s reported exit_code is the parsed line, never the field',
    result.checks?.red?.find(c => c.id === 'check:1')?.exit_code, 1)
  check('check:2 is not red, keyed on its exit line despite an exit_code: 1 field',
    result.checks?.red?.some(c => c.id === 'check:2'), false)
  check('exactly one check is red', result.checks?.red?.length, 1)
}

// Scenario FQ -- #120: the bug this ticket is about. A summarised output
// with exit_code: 0 and no exit line must not read as a pass; it is
// unmeasured, retried once, and halts rather than reaching a fixer.
async function scenarioFQ() {
  console.log('\n== scenario FQ: a summarised output with exit_code: 0 and no exit line is unmeasured, never a pass')
  const { result, captured } = await run({
    discovery: { file: '/repo/AGENTS.md',
      sections: [{ heading: '## Checks', fence: 'bash scripts/run-hook-tests.sh' }], detail: 'stub' },
    checkRuns: () => ({ results: [{ id: 'check:1',
      command: checkInvocation('check:1', 'bash scripts/run-hook-tests.sh'), exit_code: 0,
      output: '[... all hook suites completed successfully ...]' }], dirty: false }),
  })
  check('halted at Implement: measurement, not the code', result.halted_at, 'Implement')
  check('the retry happened once', callCount(captured, 'checks:run:3'), 1)
  check('the unmeasured check is named', result.checks?.unmeasured?.[0]?.id, 'check:1')
  check('the halt note says why: no exit line', (result.note ?? '').includes('no exit line'), true)
}

// Scenario FR -- #120: an exit line naming a different check's id is
// unmeasured, never read as this check's own.
async function scenarioFR() {
  console.log('\n== scenario FR: an exit line naming a different id is unmeasured')
  const { result } = await run({
    discovery: { file: '/repo/AGENTS.md', sections: [{ heading: '## Checks', fence: 'make test' }], detail: 'stub' },
    checkRuns: () => ({ results: [{ id: 'check:1', command: checkInvocation('check:1', 'make test'),
      exit_code: 0, output: 'TOUCHSTONE_CHECK_EXIT check:2 0\nok' }], dirty: false }),
  })
  check('halted at Implement: measurement, not the code', result.halted_at, 'Implement')
  check('the halt note says the exit line named a different id',
    (result.note ?? '').includes('exit line names check:2'), true)
}

// Scenario FS -- #120: the invocation prints its exit line before anything
// else, so one found further down was moved there by whoever relayed the
// output, and the row is unmeasured rather than trusted.
async function scenarioFS() {
  console.log('\n== scenario FS: an exit line that is not the first line is unmeasured')
  const { result } = await run({
    discovery: { file: '/repo/AGENTS.md', sections: [{ heading: '## Checks', fence: 'make test' }], detail: 'stub' },
    checkRuns: () => ({ results: [{ id: 'check:1', command: checkInvocation('check:1', 'make test'),
      exit_code: 0,
      output: 'ok\nTOUCHSTONE_CHECK_EXIT check:1 0' }], dirty: false }),
  })
  check('halted at Implement: measurement, not the code', result.halted_at, 'Implement')
  check('the halt note says the exit line was not first', (result.note ?? '').includes('exit line not first'), true)
}

// Scenario FT -- #120: an exit line that does not match the expected shape
// is unmeasured, never guessed at.
async function scenarioFT() {
  console.log('\n== scenario FT: a malformed exit line is unmeasured')
  const { result } = await run({
    discovery: { file: '/repo/AGENTS.md', sections: [{ heading: '## Checks', fence: 'make test' }], detail: 'stub' },
    checkRuns: () => ({ results: [{ id: 'check:1', command: checkInvocation('check:1', 'make test'),
      exit_code: 0, output: 'TOUCHSTONE_CHECK_EXIT check:1 not-a-number\nok' }], dirty: false }),
  })
  check('halted at Implement: measurement, not the code', result.halted_at, 'Implement')
  check('the halt note says the line is malformed', (result.note ?? '').includes('malformed exit line'), true)
}

// Scenario FU -- #120: the ticket's own example of the bug. A check still
// printing its own progress when the runner reports it, exit_code: 0 and no
// exit line, is unmeasured rather than read as a premature pass.
async function scenarioFU() {
  console.log('\n== scenario FU: a check still writing its own status when reported is unmeasured, not a pass')
  const { result } = await run({
    discovery: { file: '/repo/AGENTS.md',
      sections: [{ heading: '## Checks', fence: 'bash scripts/long-suite.sh' }], detail: 'stub' },
    checkRuns: () => ({ results: [{ id: 'check:1',
      command: checkInvocation('check:1', 'bash scripts/long-suite.sh'), exit_code: 0,
      output: 'progress: 8/10 suites\nstatus: RUNNING/INCOMPLETE at reporting time' }], dirty: false }),
  })
  check('halted at Implement: measurement, not the code', result.halted_at, 'Implement')
  check('the halt note says why: no exit line', (result.note ?? '').includes('no exit line'), true)
}

// Scenario FV -- #120: the checks:run prompt demands one invocation at a
// time, in the foreground, and forbids the runner from writing the exit
// line itself.
async function scenarioFV() {
  console.log('\n== scenario FV: the checks:run prompt demands sequential foreground runs and forbids writing the exit line')
  const { captured } = await run({
    discovery: { file: '/repo/AGENTS.md', sections: [{ heading: '## Checks', fence: 'make test' }], detail: 'stub' },
  })
  const runPrompt = captured.calls.find(c => c.label === 'checks:run:1')?.prompt ?? ''
  check('it demands one at a time, in order', /one at a time, in the order given/.test(runPrompt), true)
  check('it names the foreground timeout', runPrompt.includes('600000 ms'), true)
  check('it forbids run_in_background', runPrompt.includes('run_in_background'), true)
  check('it forbids parallel runs', /never several at once/.test(runPrompt), true)
  check('it forbids writing the exit line',
    /never write, add, move, or change that\s+line yourself/.test(runPrompt), true)
  check('it tells the runner to wait for a return before starting the next',
    /wait for each to return before starting the next/.test(runPrompt), true)
  check('a call that times out is reported with no exit line',
    /A call that does not return within the timeout is reported with whatever it printed and no exit line/.test(runPrompt), true)
  check('git status --porcelain runs only after the last invocation returns',
    /Only once the last invocation has returned, run git -C/.test(runPrompt), true)
}

// Scenario FW -- #120: the unmeasured halt note renders each attempt's own
// reason, never the command-mismatch wording, for a check whose command
// always matched.
async function scenarioFW() {
  console.log('\n== scenario FW: the unmeasured halt note gives the exact rule that failed per attempt, never a false command mismatch')
  const { result } = await run({
    discovery: { file: '/repo/AGENTS.md', sections: [{ heading: '## Checks', fence: 'make test' }], detail: 'stub' },
    checkRuns: (attempt) => attempt === 3
      ? ({ results: [{ id: 'check:1', command: checkInvocation('check:1', 'make test'), exit_code: 0,
          output: 'ok\nTOUCHSTONE_CHECK_EXIT check:1 0' }] })
      : ({ results: [{ id: 'check:1', command: checkInvocation('check:1', 'make test'), exit_code: 0,
          output: 'ok' }] }),
  })
  check('halted at Implement: measurement, not the code', result.halted_at, 'Implement')
  check('first run reason is no exit line', (result.note ?? '').includes('first run no exit line'), true)
  check('second run reason is exit line not first', (result.note ?? '').includes('second run exit line not first'), true)
  check('the note never describes this matched command as a mismatch',
    (result.note ?? '').includes(', got `'), false)
}

// Scenario FX -- #120: a check whose own last printed byte is not a newline
// (printf with no trailing '\n', a `\r`-terminated progress line, an ANSI
// reset) must not merge invocationFor's own echo onto that same line: run
// for real against the built invocation, the same reason as FO, since a
// hand-written synthetic output could not show the merge actually happening.
async function scenarioFX() {
  console.log('\n== scenario FX: a check\'s last byte with no trailing newline does not merge into the exit line')
  const wtPath = fs.mkdtempSync(path.join(os.tmpdir(), 'touchstone-fx-'))
  try {
    const { captured } = await run({
      branchResult: { created: true, branch: 'feat/gh-21-stub', base: 'main',
        path: wtPath, ticket: '21', detail: 'stub', dirty: false },
      discovery: { file: '/repo/AGENTS.md', sections: [{ heading: '## Checks', fence: 'printf ok' }], detail: 'stub' },
    })
    const runPrompt = captured.calls.find(c => c.label === 'checks:run:1')?.prompt ?? ''
    const line = runPrompt.split('\n').find(l => l.startsWith('check:1: '))
    const invocation = line ? line.slice('check:1: '.length) : ''
    const out = invocation ? execFileSync('bash', ['-c', invocation]).toString() : ''
    check('the exit line is a whole first line, the check\'s output after it',
      out, `${CHECK_EXIT_MARKER} check:1 0\nok`)
  } finally {
    fs.rmSync(wtPath, { recursive: true, force: true })
  }
}

// Scenario FY -- #120: a check printing more than the runner can relay whole
// (this repo's own fix-loop suite prints about 56KB) reaches the runner as
// its exit line plus the output's last 8192 bytes, so the line is never past
// the Bash tool's inline preview and nothing has to be summarised. Run for
// real, and nothing is left behind in the worktree.
async function scenarioFY() {
  console.log('\n== scenario FY: a large check output is bounded to its exit line plus the last 8192 bytes')
  const wtPath = fs.mkdtempSync(path.join(os.tmpdir(), 'touchstone-fy-'))
  try {
    const { captured } = await run({
      branchResult: { created: true, branch: 'feat/gh-21-stub', base: 'main',
        path: wtPath, ticket: '21', detail: 'stub', dirty: false },
      discovery: { file: '/repo/AGENTS.md', sections: [{ heading: '## Checks',
        fence: 'head -c 20000 /dev/zero; printf END; exit 4' }], detail: 'stub' },
    })
    const runPrompt = captured.calls.find(c => c.label === 'checks:run:1')?.prompt ?? ''
    const line = runPrompt.split('\n').find(l => l.startsWith('check:1: '))
    const invocation = line ? line.slice('check:1: '.length) : ''
    const out = invocation ? execFileSync('bash', ['-c', invocation]).toString() : ''
    const [first, ...rest] = out.split('\n')
    check('the first line is the exit line with the real exit code', first, `${CHECK_EXIT_MARKER} check:1 4`)
    check('the rest is exactly the last 8192 bytes of the output', rest.join('\n').length, 8192)
    check('the output\'s end survives', out.endsWith('END'), true)
    check('nothing is left in the worktree', fs.readdirSync(wtPath).length, 0)
  } finally {
    fs.rmSync(wtPath, { recursive: true, force: true })
  }
}

// Scenario FZ -- #120: only the first line is read. A check's own output can
// print a line that looks like an exit line (a suite testing this very
// runner does), and it must neither override nor invalidate the real one.
async function scenarioFZ() {
  console.log('\n== scenario FZ: an exit-line lookalike in the check\'s own output is ignored')
  const { result } = await run({
    args: { existingBranch: true, openPr: true },
    discovery: { file: '/repo/AGENTS.md', sections: [{ heading: '## Checks', fence: 'make test' }], detail: 'stub' },
    checkRuns: () => ({ results: [{ id: 'check:1', command: checkInvocation('check:1', 'make test'),
      exit_code: 1, output: 'TOUCHSTONE_CHECK_EXIT check:1 1\nTOUCHSTONE_CHECK_EXIT check:1 0' }], dirty: false }),
    prResult: { opened: true, url: 'https://example.invalid/pr/120fz', note: 'stub ready' },
  })
  check('measured red from the first line', result.checks?.red?.[0]?.exit_code, 1)
  check('nothing unmeasured', result.checks?.unmeasured?.length, 0)
}

const SCENARIOS = [scenarioEH, scenarioEI, scenarioFA, scenarioFB, scenarioFC, scenarioFD, scenarioFE, scenarioFF, scenarioFG, scenarioFH, scenarioFI, scenarioFJ, scenarioFK, scenarioFL, scenarioFM, scenarioFN, scenarioFO, scenarioFP, scenarioFQ, scenarioFR, scenarioFS, scenarioFT, scenarioFU, scenarioFV, scenarioFW, scenarioFX, scenarioFY, scenarioFZ]
JS_EOF

finish
