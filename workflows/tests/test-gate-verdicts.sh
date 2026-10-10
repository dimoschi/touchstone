#!/usr/bin/env bash
# gh-163: the mutation gate's verdict and the PR's unreviewed-commit guard are
# read from script-built lines the shell prints, never from a model's account.
# Covers the lines, the strict parse, the retry and halt on an unparseable
# reply, and the real lines run in bash against a scratch repo; see harness.sh.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/harness.sh"

run_js_scenarios <<'JS_EOF'
const promptOf = (captured, label) => captured.calls.find(c => c.label === label)?.prompt ?? ''
const fenceOf = (prompt) => /```bash\n([\s\S]*?)\n```/.exec(prompt)?.[1].split('\n') ?? []
const MUT_HEAD = 'aaa0000000000000000000000000000000000001'
const SHELL_HEAD = 'abc0000000000000000000000000000000000009'
const gated = (over = {}) => ({ mutationGated: true, ...over })
const red = (head = MUT_HEAD) => () => ({ green: false, head_sha: head, detail: 'stub red', scored: false })
const green = (head = MUT_HEAD) => () => ({ green: true, head_sha: head, detail: 'stub green', scored: true })
const OUTPUT_ONLY = JSON.stringify({ type: 'object', additionalProperties: false, required: ['output'],
  properties: { output: { type: 'string' } } })

async function scenarioVerifyLine() {
  console.log('\n== scenario GA: after a mutation attempt, one script-built line runs mutation-check.sh --verify and prints exit, head and log')
  const { captured } = await run(gated({ mutationResult: green() }))
  const call = captured.calls.find(c => c.label === 'mutation-verify:1')
  const p = call?.prompt ?? ''
  const rid = mutationVerifyRunOf(p)
  check('the run is the plan id and a counter', /^[0-9a-f]{8}-mutation-verify-\d+$/.test(rid), true)
  check('the fence is the one verdict line', fenceOf(p), [
    `d="$(git -C /tmp/stub-worktree rev-parse --path-format=absolute --git-path touchstone-gates/${rid} 2>/dev/null)" && mkdir -p "$d" && ` +
    `h="$(git -C /tmp/stub-worktree rev-parse HEAD 2>/dev/null)" && ` +
    `{ mutation-check.sh /tmp/stub-worktree --verify >|"$d/mutation-verify.log" 2>&1; e=$?; ` +
    `t="$(sed -n '$s/^mutation-check: EXIT=\\([0-9][0-9]*\\) .*$/\\1/p' "$d/mutation-verify.log")"; ` +
    `printf 'TOUCHSTONE_MUTATION_VERIFY %s %s %s %s %s\\n' ${rid} "$e" "\${t:--}" "$h" "$d/mutation-verify.log"; }`])
  check('it runs after the mutation attempt',
    captured.calls.findIndex(c => c.label === 'mutation-verify:1') > captured.calls.findIndex(c => c.label === 'mutation:1'), true)
  check('the schema asks for output and nothing else', JSON.stringify(call?.schema), OUTPUT_ONLY)
  check('it is a haiku call at low effort', [call?.model, call?.effort], ['haiku', 'low'])
  check('it says where mutation-check.sh is and allows only replacing that word',
    p.includes("crap-controlled-changes skill's directory") && p.includes('replace that one word with its absolute path'), true)
}

async function scenarioClaimedGreenButRed() {
  console.log('\n== scenario GB: an agent claiming green while --verify exits 5 halts at Mutation')
  const { result, captured } = await run(gated({ mutationResult: green(), mutationVerify: () => ({ exit: 5 }) }))
  check('halted at Mutation', result.halted_at, 'Mutation')
  check('the result is not green', result.mutation?.green, false)
  const log = mutationVerifyOutput(promptOf(captured, 'mutation-verify:1'), 5, MUT_HEAD).split(' ').pop()
  check('the note names the verify exit and its log', (result.note ?? '').includes(`--verify exited 5 (${log})`), true)
  check('the note says no green run is recorded for this head',
    (result.note ?? '').includes('has not recorded a green run for this head'), true)
  check('the PR never ran', callCount(captured, 'pr'), 0)
  const twice = await run(gated({ args: { maxGateAttempts: 2 }, mutationResult: green(), mutationVerify: () => ({ exit: 5 }) }))
  check('exit 5 keeps the loop going: a second attempt runs', callCount(twice.captured, 'mutation:2'), 1)
}

async function scenarioSetupExitStops() {
  console.log('\n== scenario GM: an exit other than 0 or 5 is a setup failure: no further attempt, its own halt note')
  for (const [exit, trailer] of [[127, '-'], [2, 2]]) {
    const { result, captured } = await run(gated({ args: { maxGateAttempts: 3 }, mutationResult: green(),
      mutationVerify: () => ({ exit, trailer }) }))
    const lastVerify = exit === 127 ? 'mutation-verify:1:retry' : 'mutation-verify:1'
    const log = mutationVerifyOutput(promptOf(captured, lastVerify), exit, MUT_HEAD).split(' ').pop()
    const note = result.note ?? ''
    check(`exit ${exit}: halted at Mutation after exactly one attempt`,
      [result.halted_at, captured.calls.filter(c => /^mutation:\d+$/.test(c.label)).length], ['Mutation', 1])
    check(`exit ${exit}: asked once more only when the script was not found`,
      callCount(captured, 'mutation-verify:1:retry'), exit === 127 ? 1 : 0)
    check(`exit ${exit}: the note names the exit and the log`, note.includes(`exited ${exit}`) && note.includes(log), true)
    check(`exit ${exit}: it is a setup note, not survivors or unmeasured`,
      [/could not run/.test(note), /[Ss]urviving|has not recorded/.test(note), /could not be measured/.test(note)],
      [true, false, false])
  }
}

async function scenarioClaimedRedButGreen() {
  console.log('\n== scenario GC: an agent claiming red while --verify exits 0 proceeds')
  const { result } = await run(gated({ mutationResult: red(), mutationVerify: () => ({ exit: 0 }) }))
  check('no halt', result.halted_at, undefined)
  check('the result is green', result.mutation?.green, true)
  check('the agent\'s detail is kept', result.mutation?.detail, 'stub red')
}

async function scenarioHeadFromShell() {
  console.log('\n== scenario GD: the head comes from the shell, not the agent')
  const moved = await run(gated({ mutationResult: green(REVIEWED_THROUGH), mutationVerify: () => ({ exit: 0, head: SHELL_HEAD }) }))
  const lens = promptOf(moved.captured, 'review:mutation:correctness')
  check('an agent reporting no new commit is overruled: the post-mutation review reads the shell\'s range',
    lens.includes(`Commit range: ${REVIEWED_THROUGH}..${SHELL_HEAD}\n`), true)
  check('the result carries the shell\'s head', moved.result.mutation?.head_sha, SHELL_HEAD)
  check('and reports it as reviewed', moved.result.reviewed_through, SHELL_HEAD)
  const still = await run(gated({ mutationResult: green(MUT_HEAD), mutationVerify: () => ({ exit: 0, head: REVIEWED_THROUGH }) }))
  check('an agent claiming a head the shell does not see triggers no review',
    callCount(still.captured, 'review:mutation:correctness'), 0)
  check('and the reported head stays the reviewed one', still.result.reviewed_through, REVIEWED_THROUGH)
}

async function scenarioNullAgentStillMeasured() {
  console.log('\n== scenario GE: a mutation agent that returns nothing still gets its verdict measured')
  const { result, captured } = await run(gated({ mutationResult: () => null, mutationVerify: () => ({ exit: 0 }) }))
  check('the verdict line ran', callCount(captured, 'mutation-verify:1'), 1)
  check('and its exit 0 makes it green', [result.halted_at, result.mutation?.green], [undefined, true])
}

async function scenarioUngatedSkips() {
  console.log('\n== scenario GF: a repo without .mutation-gated runs no verdict line')
  const { result, captured } = await run({})
  check('no verdict line', captured.calls.filter(c => c.label.startsWith('mutation-verify')).length, 0)
  check('the skip stays green', result.mutation?.green, true)
}

async function scenarioParserRejects() {
  console.log('\n== scenario GG: a verdict reply that is not exactly the line is retried once, then read')
  const bad = {
    'no output': () => '',
    'two lines': (good) => `${good}\n${good}`,
    'another run': (good) => good.replace(/-mutation-verify-\d+ /, '-mutation-verify-99 '),
    'a non-integer exit': (good) => good.replace(/^(\S+ \S+) 0 0 /, '$1 zero zero '),
    'a head that is not a sha': (good) => good.replace(` ${MUT_HEAD} `, ' HEAD~1 '),
    'a 7-char head': (good) => good.replace(` ${MUT_HEAD} `, ` ${MUT_HEAD.slice(0, 7)} `),
    'a trailer that disagrees with the exit': (good) => good.replace(/^(\S+ \S+ 0) 0 /, '$1 1 '),
    'exit 0 with no gate trailer': (good) => good.replace(/^(\S+ \S+ 0) 0 /, '$1 - '),
    'a log outside the run': (good) => good.replace(/\/touchstone-gates\//, '/elsewhere/'),
    'a relative log': (good) => good.replace(/ \/\S+$/, ' mutation-verify.log'),
    'a prefixed line': (good) => `ok: ${good}`,
  }
  for (const [name, mangle] of Object.entries(bad)) {
    const { result, captured } = await run(gated({ mutationResult: red(),
      mutationVerify: (attempt, prompt, retry) => retry ? { exit: 0 }
        : { output: mangle(mutationVerifyOutput(prompt, 0, MUT_HEAD)) } }))
    check(`${name}: retried once`, callCount(captured, 'mutation-verify:1:retry'), 1)
    check(`${name}: the retry's exit 0 is green`, [result.halted_at, result.mutation?.green], [undefined, true])
  }
  const { captured } = await run(gated({ mutationResult: red(), mutationVerify: () => ({ exit: 0 }) }))
  check('a well-formed line is not retried', callCount(captured, 'mutation-verify:1:retry'), 0)
}

async function scenarioUnparseableTwiceHalts() {
  console.log('\n== scenario GH: a verdict unparseable twice halts at Mutation as unmeasured, not as survivors')
  const { result, captured } = await run(gated({ args: { maxGateAttempts: 3 }, mutationResult: green(),
    mutationVerify: (attempt, prompt, retry) => retry ? null : { output: 'garbage' } }))
  check('halted at Mutation', result.halted_at, 'Mutation')
  check('not green', result.mutation?.green, false)
  check('the note says the verdict could not be measured', /verdict could not be measured/.test(result.note ?? ''), true)
  check('it names both reasons', (result.note ?? '').includes('malformed verdict line') && (result.note ?? '').includes('no output'), true)
  check('it does not blame surviving mutants', /[Ss]urviving/.test(result.note ?? ''), false)
  check('no second mutation attempt is spent on a relay failure', callCount(captured, 'mutation:2'), 0)
  check('the agent\'s head is not carried as if measured', result.mutation?.head_sha, undefined)
  const noTrailer = await run(gated({ mutationResult: green(), mutationVerify: () => ({ exit: 5, trailer: '-' }) }))
  check('exit 5 with no gate trailer is unmeasured too', /verdict could not be measured/.test(noTrailer.result.note ?? ''), true)
}

const prRun = ({ args, ...over } = {}) => ({
  prResult: { opened: true, url: 'https://example.invalid/pr/21', note: 'stub' }, ...over,
  args: { openPr: true, ...args } })

async function scenarioUnreviewedLine() {
  console.log('\n== scenario GI: before the PR, one script-built line counts commits past the reviewed head')
  const { result, captured } = await run(prRun())
  const call = captured.calls.find(c => c.label === 'pr-unreviewed')
  check('the fence is the one count line', fenceOf(call?.prompt ?? ''), [
    `h="$(git -C /tmp/stub-worktree rev-parse HEAD 2>/dev/null)" && ` +
    `n="$(git -C /tmp/stub-worktree rev-list --count ${REVIEWED_THROUGH}.."$h" 2>/dev/null)" && ` +
    `printf 'TOUCHSTONE_UNREVIEWED %s %s %s\\n' ${REVIEWED_THROUGH} "$n" "$h"`])
  check('the schema asks for output and nothing else', JSON.stringify(call?.schema), OUTPUT_ONLY)
  check('it is a haiku call at low effort', [call?.model, call?.effort], ['haiku', 'low'])
  check('it runs before pr', captured.calls.findIndex(c => c.label === 'pr-unreviewed') <
    captured.calls.findIndex(c => c.label === 'pr'), true)
  const pr = promptOf(captured, 'pr')
  check('count 0 dispatches pr', [callCount(captured, 'pr'), result.halted_at], [1, undefined])
  check('the pr prompt no longer asks it to count commits', /rev-list/.test(pr), false)
  check('nor to judge unreviewed commits', /unreviewed|adversarially reviewed/i.test(pr), false)
}

async function scenarioUnreviewedHalts() {
  console.log('\n== scenario GJ: two unreviewed commits halt at PR without dispatching pr')
  const { result, captured } = await run(prRun({ unreviewed: () => ({ count: 2, head: SHELL_HEAD }) }))
  check('halted at PR', result.halted_at, 'PR')
  check('pr never ran', callCount(captured, 'pr'), 0)
  check('the note names the count and the range',
    (result.note ?? '').includes('2 commit(s)') && (result.note ?? '').includes(`${REVIEWED_THROUGH}..${SHELL_HEAD}`), true)
}

async function scenarioUnreviewedUnparseable() {
  console.log('\n== scenario GK: an unreviewed count unparseable twice halts at PR as unmeasured')
  const bad = {
    'another reviewed head': (from) => `TOUCHSTONE_UNREVIEWED ${MUT_HEAD} 0 ${from}`,
    'a non-integer count': (from) => `TOUCHSTONE_UNREVIEWED ${from} none ${from}`,
    'a missing head': (from) => `TOUCHSTONE_UNREVIEWED ${from} 0`,
    'a 7-char head': (from) => `TOUCHSTONE_UNREVIEWED ${from} 0 ${from.slice(0, 7)}`,
    'two lines': (from) => `TOUCHSTONE_UNREVIEWED ${from} 0 ${from}\nTOUCHSTONE_UNREVIEWED ${from} 0 ${from}`,
  }
  for (const [name, mangle] of Object.entries(bad)) {
    const { result, captured } = await run(prRun({
      unreviewed: (retry, prompt) => ({ output: mangle(unreviewedFromOf(prompt)) }) }))
    check(`${name}: retried once`, callCount(captured, 'pr-unreviewed:retry'), 1)
    check(`${name}: halted at PR without pr`, [result.halted_at, callCount(captured, 'pr')], ['PR', 0])
    check(`${name}: the note says it could not be measured`, /could not be measured/.test(result.note ?? ''), true)
  }
  const recovered = await run(prRun({ unreviewed: (retry) => retry ? undefined : null }))
  check('a retry that reads 0 dispatches pr', [callCount(recovered.captured, 'pr'), recovered.result.halted_at], [1, undefined])
}

async function scenarioNoReviewersNoCount() {
  console.log('\n== scenario GL: with no reviewer lens, nothing counts unreviewed commits')
  const { captured } = await run(prRun({ diffstatFiles: [['a.js', 5, 0]] }))
  check('no count line', captured.calls.filter(c => c.label.startsWith('pr-unreviewed')).length, 0)
  check('pr ran', callCount(captured, 'pr'), 1)
}

const scratchRepo = () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "touchstone o'clock -"))
  const env = { ...process.env, GIT_AUTHOR_NAME: 'test', GIT_AUTHOR_EMAIL: 't@t',
    GIT_COMMITTER_NAME: 'test', GIT_COMMITTER_EMAIL: 't@t' }
  const git = (...a) => execFileSync('git', ['-C', dir, ...a], { env, encoding: 'utf8' }).trim()
  execFileSync('git', ['init', '-q', dir])
  const commit = (file) => {
    fs.writeFileSync(path.join(dir, file), `${file}\n`)
    git('add', '-A')
    git('-c', 'commit.gpgsign=false', '-c', 'gpg.format=openpgp', 'commit', '-q', '-m', file)
    return git('rev-parse', 'HEAD')
  }
  return { dir, commit }
}
const branchAt = (dir) => ({ created: true, branch: 'feat/gh-21-stub', base: 'main', path: dir,
  ticket: '21', detail: 'stub', dirty: false })
// PATH without any real mutation-check.sh, plus `bin` first when given, so
// the bare name in the line resolves only to what a scenario put there.
const withPath = async (bin, env, fn) => {
  const saved = { ...process.env }
  const clean = process.env.PATH.split(':').filter(d => !fs.existsSync(path.join(d, 'mutation-check.sh')))
  process.env.PATH = [...(bin ? [bin] : []), ...clean].join(':')
  Object.assign(process.env, env)
  try { return await fn() } finally {
    for (const k of Object.keys(process.env)) if (!(k in saved)) delete process.env[k]
    Object.assign(process.env, saved)
  }
}
// A fake mutation-check.sh: it logs its arguments, prints the real gate's
// trailer unless FAKE_NO_TRAILER is set, and exits with FAKE_MUTATION_EXIT.
const withFakeGate = async (exit, fn, env = {}) => {
  const bin = fs.mkdtempSync(path.join(os.tmpdir(), 'fake-gate-'))
  fs.writeFileSync(path.join(bin, 'mutation-check.sh'),
    '#!/usr/bin/env bash\nprintf \'fake verify %s\\n\' "$*"\n' +
    '[ -n "${FAKE_NO_TRAILER:-}" ] || echo "mutation-check: EXIT=$FAKE_MUTATION_EXIT FAKE_VERDICT"\n' +
    'exit "$FAKE_MUTATION_EXIT"\n', { mode: 0o755 })
  try { return await withPath(bin, { FAKE_MUTATION_EXIT: String(exit), ...env }, fn) } finally {
    fs.rmSync(bin, { recursive: true, force: true })
  }
}
const realVerify = (outs, edit = (l) => l) => (attempt, prompt) => {
  const fence = /```bash\n([\s\S]*?)\n```/.exec(prompt)
  const output = spawnSync('bash', ['-c', edit(fence[1])], { encoding: 'utf8' }).stdout
  outs.push(output)
  return { output }
}
const VERIFY_ROW = /^TOUCHSTONE_MUTATION_VERIFY (\S+) (\d+) (\S+) (\S+) (\/.+)$/
const attemptsOf = (captured) => captured.calls.filter(c => /^mutation:\d+$/.test(c.label)).length

async function scenarioRealVerify() {
  console.log('\n== scenario GR: the real verdict line, run in bash against a scratch repo with a fake gate')
  const { dir, commit } = scratchRepo()
  try {
    const head = commit('a.txt')
    for (const [exit, wantHalt] of [[5, 'Mutation'], [0, undefined]]) {
      await withFakeGate(exit, async () => {
        const outs = []
        const { result } = await run(gated({ branchResult: branchAt(dir), mutationResult: green(),
          mutationVerify: realVerify(outs) }))
        const m = VERIFY_ROW.exec(outs[0]?.trim() ?? '')
        check(`exit ${exit}: one line, printed by the shell`, [outs[0]?.trim().split('\n').length, Boolean(m)], [1, true])
        check(`exit ${exit}: the exit and the gate's trailer`, [m?.[2], m?.[3]], [String(exit), String(exit)])
        check(`exit ${exit}: the head is git's`, m?.[4], head)
        check(`exit ${exit}: the log holds the gate's output, given the worktree and --verify`,
          fs.readFileSync(m?.[5] ?? '/nonexistent', 'utf8'),
          `fake verify ${dir} --verify\nmutation-check: EXIT=${exit} FAKE_VERDICT\n`)
        check(`exit ${exit}: the log sits under the worktree's git dir`,
          path.dirname(fs.realpathSync(m?.[5] ?? '/nonexistent')),
          path.join(fs.realpathSync(dir), '.git', 'touchstone-gates', m?.[1] ?? ''))
        check(`exit ${exit}: the run's outcome`, [result.halted_at, result.mutation?.green], [wantHalt, exit === 0])
        check(`exit ${exit}: the tree stays clean`, execFileSync('git', ['-C', dir, 'status', '--porcelain'], { encoding: 'utf8' }), '')
      })
    }
  } finally {
    fs.rmSync(dir, { recursive: true, force: true })
  }
}

async function scenarioRealVerifyNotTheGate() {
  console.log('\n== scenario GT: a line that did not run the real gate is not read as green, and a missing gate is a setup halt')
  const { dir, commit } = scratchRepo()
  try {
    commit('a.txt')
    await withFakeGate(0, async () => {
      const outs = []
      const { result, captured } = await run(gated({ branchResult: branchAt(dir), mutationResult: green(),
        mutationVerify: realVerify(outs, (l) => l.replace('{ mutation-check.sh ', '{ true ')) }))
      check('`true` substituted prints exit 0 with no trailer', VERIFY_ROW.exec(outs[0]?.trim() ?? '')?.slice(2, 4), ['0', '-'])
      check('and reads as unmeasured after the retry', [result.halted_at, /verdict could not be measured/.test(result.note ?? ''),
        callCount(captured, 'mutation-verify:1:retry')], ['Mutation', true, 1])
    })
    await withFakeGate(0, async () => {
      const { result } = await run(gated({ branchResult: branchAt(dir), mutationResult: green(),
        mutationVerify: realVerify([]) }))
      check('a gate that exits 0 without its trailer is unmeasured', /verdict could not be measured/.test(result.note ?? ''), true)
    }, { FAKE_NO_TRAILER: '1' })
    await withPath(null, {}, async () => {
      const outs = []
      const { result, captured } = await run(gated({ args: { maxGateAttempts: 3 }, branchResult: branchAt(dir),
        mutationResult: green(), mutationVerify: realVerify(outs) }))
      check('no gate on PATH: exit 127, no trailer', VERIFY_ROW.exec(outs[0]?.trim() ?? '')?.slice(2, 4), ['127', '-'])
      check('a 127 verdict is asked once more, in case the relay left the bare name',
        [outs.length, callCount(captured, 'mutation-verify:1:retry')], [2, 1])
      check('a setup halt at Mutation after exactly one attempt',
        [result.halted_at, attemptsOf(captured), /exited 127/.test(result.note ?? '')], ['Mutation', 1, true])
    })
  } finally {
    fs.rmSync(dir, { recursive: true, force: true })
  }
}

// The lines the script builds have to get past the plugin's own gate-pipe
// hook, which an agent running them in a gated session triggers.
const HOOK = path.join(path.dirname(SCRIPT_PATH), '..', 'hooks', 'gate-pipe-gate.py')
const hookExit = (command) => spawnSync('python3', [HOOK],
  { input: JSON.stringify({ tool_input: { command } }), encoding: 'utf8' }).status

async function scenarioHookAllowsLines() {
  console.log('\n== scenario GN: gate-pipe-gate.py allows every built line, including ones that name a gate')
  const { captured } = await run(prRun({ mutationGated: true, mutationResult: green(),
    discovery: { file: '/repo/AGENTS.md', sections: [{ heading: '## Checks',
      fence: 'mutation-check.sh /repo --verify' }], detail: 'stub' },
    initialReview: { correctness: [{ title: 't', file: 't.js', claim: 'c', evidence: 'e', category: 'wrong-result',
      reproducer: { kind: 'command', command: 'crap-check.sh /repo > /dev/null', expected: 'exit 0', actual: 'exit 1' } }],
      advocate: [] },
    verify: () => true, fixHead: () => 'fff0000000000000000000000000000000000001', staleness: () => [] }))
  const linesOf = (label) => fenceOf(promptOf(captured, label))
  for (const label of ['mutation-verify:1', 'pr-unreviewed', 'checks:run:1', 'reproduce:review']) {
    const lines = linesOf(label)
    check(`${label}: has lines`, lines.length > 0, true)
    check(`${label}: every line passes the hook`, lines.map(hookExit), lines.map(() => 0))
  }
  check('the hook still refuses a real pipe of the gate', hookExit('mutation-check.sh /r --verify | tail'), 2)
}

async function scenarioRealUnreviewed() {
  console.log('\n== scenario GS: the real count line, run in bash against a repo with commits past the reviewed head')
  const { dir, commit } = scratchRepo()
  try {
    const reviewed = commit('a.txt')
    commit('b.txt')
    const tip = commit('c.txt')
    const outs = []
    const real = (retry, prompt) => { const output = runRunnerLines(prompt); outs.push(output); return { output } }
    const behind = await run(prRun({ branchResult: branchAt(dir), implRange: `${reviewed}..${reviewed}`, unreviewed: real }))
    check('it prints the reviewed head, 2 and the tip', outs[0]?.trim(), `TOUCHSTONE_UNREVIEWED ${reviewed} 2 ${tip}`)
    check('halted at PR without pr', [behind.result.halted_at, callCount(behind.captured, 'pr')], ['PR', 0])
    check('the note names the range', (behind.result.note ?? '').includes(`${reviewed}..${tip}`), true)
    const level = await run(prRun({ branchResult: branchAt(dir), implRange: `${reviewed}..${tip}`, unreviewed: real }))
    check('at the tip it prints 0', outs[1]?.trim(), `TOUCHSTONE_UNREVIEWED ${tip} 0 ${tip}`)
    check('and pr is dispatched', [level.result.halted_at, callCount(level.captured, 'pr')], [undefined, 1])
  } finally {
    fs.rmSync(dir, { recursive: true, force: true })
  }
}

// The verdict line reads the real gate's last line; if mutation-check.sh ever
// changes it, this fails rather than every verdict silently going unmeasured.
// A scratch branch off main reaches the gate's exit trap on any machine.
async function scenarioRealGateTrailer() {
  console.log('\n== scenario GU: the real mutation-check.sh --verify ends with the trailer the verdict line reads')
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'gate-trailer-'))
  try {
    const env = { ...process.env, GIT_AUTHOR_NAME: 't', GIT_AUTHOR_EMAIL: 't@t',
      GIT_COMMITTER_NAME: 't', GIT_COMMITTER_EMAIL: 't@t' }
    const git = (...a) => execFileSync('git', ['-C', dir, '-c', 'commit.gpgsign=false', ...a], { env })
    git('init', '-q', '-b', 'main')
    fs.writeFileSync(path.join(dir, 'a.txt'), 'a\n'); git('add', '-A'); git('commit', '-qm', 'a')
    git('checkout', '-qb', 'feat')
    fs.writeFileSync(path.join(dir, 'm.py'), 'x = 1\n'); git('add', '-A'); git('commit', '-qm', 'b')
    const gate = path.resolve(path.dirname(SCRIPT_PATH), '..', 'skills', 'crap-controlled-changes', 'mutation-check.sh')
    const run = spawnSync('bash', ['-c', 'bash "$0" "$1" --verify 2>&1', gate, dir], { encoding: 'utf8' })
    const m = /^mutation-check: EXIT=([0-9]+) /.exec(run.stdout.trim().split('\n').pop() ?? '')
    check('a branch with no recorded run exits 5', run.status, 5)
    check('its last line is the trailer', Boolean(m), true)
    check('and the trailer\'s number is the exit code', Number(m?.[1]), run.status)
  } finally {
    fs.rmSync(dir, { recursive: true, force: true })
  }
}

const SCENARIOS = [scenarioRealGateTrailer, scenarioVerifyLine, scenarioClaimedGreenButRed, scenarioSetupExitStops, scenarioHookAllowsLines, scenarioClaimedRedButGreen,
  scenarioHeadFromShell, scenarioNullAgentStillMeasured, scenarioUngatedSkips, scenarioParserRejects,
  scenarioUnparseableTwiceHalts, scenarioUnreviewedLine, scenarioUnreviewedHalts,
  scenarioUnreviewedUnparseable, scenarioNoReviewersNoCount, scenarioRealVerify, scenarioRealVerifyNotTheGate, scenarioRealUnreviewed]
JS_EOF

finish
