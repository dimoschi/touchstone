#!/usr/bin/env bash
# Scenarios scenarioEH..scenarioFN, split out of
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
  check('the note\'s log holds the real output',
    /ValueError: boom/.test(fs.readFileSync(note?.reproducer_run?.log ?? '/nonexistent', 'utf8')), true)
  check('no fix round ran', callCount(captured, 'fix:1'), 0)
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
  check('f3\'s log holds its crash output',
    /RuntimeError/.test(fs.readFileSync(f3?.reproducer_run?.log ?? '/nonexistent', 'utf8')), true)
  const fixBrief2 = captured.calls.find(c => c.label === 'fix:2')?.prompt ?? ''
  check('the next fix brief says the reproducer itself failed to run',
    fixBrief2.includes('reproducer itself failed to run'), true)
  check('the next fix brief shows the crash exit code', fixBrief2.includes('exit 1'), true)
  check('the next fix brief carries the path of round 1\'s crash log',
    /Its full output is in \/\S*reproduce-fix-1-\d+\/f3\.log,/.test(fixBrief2), true)
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
          claim: 'a single quote in a check command reaches the shell unescaped', evidence: 'checkLineFor',
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
    check('before a fix: the note\'s log holds the real crash output',
      /ERR_INVALID_ARG_TYPE/.test(fs.readFileSync(note?.reproducer_run?.log ?? '/nonexistent', 'utf8')), true)
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
          claim: 'a single quote in a check command reaches the shell unescaped', evidence: 'checkLineFor',
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
    const crashLog = (/Its full output is in (\/\S+\.log),/.exec(fixBrief2) ?? [])[1] ?? '/nonexistent'
    check('after a fix: the fix brief carries the log of the real crash',
      /ERR_INVALID_ARG_TYPE/.test(fs.readFileSync(crashLog, 'utf8')), true)
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
// measures on the retry opens exactly as if the first call had reported it. A
// dropped row makes the whole first call unmeasured, so every candidate reruns.
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
  check('both candidates rerun: one dropped row leaves the whole first call unmeasured', idsIn(retryPrompt), ['f1', 'f2'])
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

// Scenarios FL-FN -- gh-113: a dirty retry must not lose a candidate. Each
// covers one of executeAndDispose's three callers. A dropped row leaves the
// whole first call unmeasured, so every candidate reruns and the dirty halt
// carries all of them unresolved, none decided on the first call.
async function scenarioFL() {
  console.log('\n== scenario FL: gh-113 -- a dirty retry at the initial review carries every candidate unresolved')
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
  check('the dirty halt carries the reproducing candidate',
    result.unresolved_findings?.some(f => f.title === 'Reproduced on the first call'), true)
  check('the dirty halt carries the candidate the dirty retry ran',
    result.unresolved_findings?.some(f => f.title === 'Dropped on the first call'), true)
  check('the passing candidate is carried unresolved, not decided on an unmeasured call',
    result.unresolved_findings?.some(f => f.title === 'Passed on the first call'), true)
}

async function scenarioFM() {
  console.log('\n== scenario FM: gh-113 -- a dirty retry on a fresh fix-round candidate carries every candidate unresolved')
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
  check('the dirty halt carries the reproducing fresh candidate',
    result.unresolved_findings?.some(f => f.title === 'Reproduced in the fix'), true)
  check('the dirty halt carries the candidate the dirty retry ran',
    result.unresolved_findings?.some(f => f.title === 'Dropped in the fix'), true)
  check('the passing candidate is carried unresolved, not decided on an unmeasured call',
    result.unresolved_findings?.some(f => f.title === 'Passed in the fix'), true)
  check('fix_rounds is 1', result.fix_rounds, 1)
}

async function scenarioFN() {
  console.log('\n== scenario FN: gh-113 -- a dirty retry on a fresh post-mutation candidate carries every candidate unresolved')
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
  check('the dirty halt carries the reproducing candidate',
    result.unresolved_findings?.some(f => f.title === 'Reproduced post-mutation'), true)
  check('the dirty halt carries the candidate the dirty retry ran',
    result.unresolved_findings?.some(f => f.title === 'Dropped post-mutation'), true)
  check('the passing candidate is carried unresolved, not decided on an unmeasured call',
    result.unresolved_findings?.some(f => f.title === 'Passed post-mutation'), true)
}

const SCENARIOS = [scenarioEH, scenarioEI, scenarioFA, scenarioFD, scenarioFE, scenarioFF, scenarioFG, scenarioFH, scenarioFI, scenarioFJ, scenarioFK, scenarioFL, scenarioFM, scenarioFN]
JS_EOF

finish
