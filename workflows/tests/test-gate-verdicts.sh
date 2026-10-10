#!/usr/bin/env bash
# gh-163: the mutation gate's verdict and the PR's unreviewed-commit guard are
# read from script-built lines the shell prints, never from a model's account.
# Covers the lines, the strict parse, the retry and halt on an unparseable
# reply, and the real lines run in bash against a scratch repo; see harness.sh.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/harness.sh"

run_js_scenarios <<'JS_EOF'
const promptOf = (captured, label) => captured.calls.find(c => c.label === label)?.prompt ?? ''
const fenceOf = (prompt) => /```bash\n([\s\S]*?)\n```/.exec(prompt)?.[1].split('\n') ?? []
const MUT_HEAD = 'mut0000000000000000000000000000000000001'
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
    `printf 'TOUCHSTONE_MUTATION_VERIFY %s %s %s %s\\n' ${rid} "$e" "$h" "$d/mutation-verify.log"; }`])
  check('it runs after the mutation attempt',
    captured.calls.findIndex(c => c.label === 'mutation-verify:1') > captured.calls.findIndex(c => c.label === 'mutation:1'), true)
  check('the schema asks for output and nothing else', JSON.stringify(call?.schema), OUTPUT_ONLY)
  check('it is a haiku call at low effort', [call?.model, call?.effort], ['haiku', 'low'])
  check('it says where mutation-check.sh is and allows only replacing that word',
    p.includes("crap-controlled-changes skill's directory") && p.includes('replace that one word with its absolute path'), true)
}

async function scenarioClaimedGreenButRed() {
  console.log('\n== scenario GB: an agent claiming green while --verify exits 1 halts at Mutation')
  const { result, captured } = await run(gated({ mutationResult: green(), mutationVerify: () => ({ exit: 1 }) }))
  check('halted at Mutation', result.halted_at, 'Mutation')
  check('the result is not green', result.mutation?.green, false)
  const log = mutationVerifyOutput(promptOf(captured, 'mutation-verify:1'), 1, MUT_HEAD).split(' ').pop()
  check('the note names the verify exit and its log', (result.note ?? '').includes(`--verify exited 1 (${log})`), true)
  check('the PR never ran', callCount(captured, 'pr'), 0)
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
    'a non-integer exit': (good) => good.replace(/^(\S+ \S+) 0 /, '$1 zero '),
    'a head that is not a sha': (good) => good.replace(` ${MUT_HEAD} `, ' HEAD~1 '),
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
// A fake mutation-check.sh first on PATH: it logs its arguments and exits
// with whatever FAKE_MUTATION_EXIT holds.
const withFakeGate = async (exit, fn) => {
  const bin = fs.mkdtempSync(path.join(os.tmpdir(), 'fake-gate-'))
  fs.writeFileSync(path.join(bin, 'mutation-check.sh'),
    '#!/usr/bin/env bash\nprintf \'fake verify %s\\n\' "$*"\nexit "$FAKE_MUTATION_EXIT"\n', { mode: 0o755 })
  const saved = { PATH: process.env.PATH, FAKE: process.env.FAKE_MUTATION_EXIT }
  process.env.PATH = `${bin}:${process.env.PATH}`
  process.env.FAKE_MUTATION_EXIT = String(exit)
  try { return await fn() } finally {
    process.env.PATH = saved.PATH
    if (saved.FAKE === undefined) delete process.env.FAKE_MUTATION_EXIT
    else process.env.FAKE_MUTATION_EXIT = saved.FAKE
    fs.rmSync(bin, { recursive: true, force: true })
  }
}
const realVerify = (outs) => (attempt, prompt) => {
  const output = runRunnerLines(prompt)
  outs.push(output)
  return { output }
}

async function scenarioRealVerify() {
  console.log('\n== scenario GR: the real verdict line, run in bash against a scratch repo with a fake gate')
  const { dir, commit } = scratchRepo()
  try {
    const head = commit('a.txt')
    for (const [exit, wantHalt] of [[1, 'Mutation'], [0, undefined]]) {
      await withFakeGate(exit, async () => {
        const outs = []
        const { result } = await run(gated({ branchResult: branchAt(dir), mutationResult: green(),
          mutationVerify: realVerify(outs) }))
        const m = /^TOUCHSTONE_MUTATION_VERIFY (\S+) (\d+) (\S+) (\/.+)$/.exec(outs[0]?.trim() ?? '')
        check(`exit ${exit}: one line, printed by the shell`, [outs[0]?.trim().split('\n').length, Boolean(m)], [1, true])
        check(`exit ${exit}: the exit is the gate's`, m?.[2], String(exit))
        check(`exit ${exit}: the head is git's`, m?.[3], head)
        check(`exit ${exit}: the log holds the gate's output, given the worktree and --verify`,
          fs.readFileSync(m?.[4] ?? '/nonexistent', 'utf8'), `fake verify ${dir} --verify\n`)
        check(`exit ${exit}: the log sits under the worktree's git dir`,
          path.dirname(fs.realpathSync(m?.[4] ?? '/nonexistent')),
          path.join(fs.realpathSync(dir), '.git', 'touchstone-gates', m?.[1] ?? ''))
        check(`exit ${exit}: the run's outcome`, [result.halted_at, result.mutation?.green], [wantHalt, exit === 0])
        check(`exit ${exit}: the tree stays clean`, execFileSync('git', ['-C', dir, 'status', '--porcelain'], { encoding: 'utf8' }), '')
      })
    }
  } finally {
    fs.rmSync(dir, { recursive: true, force: true })
  }
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

const SCENARIOS = [scenarioVerifyLine, scenarioClaimedGreenButRed, scenarioClaimedRedButGreen,
  scenarioHeadFromShell, scenarioNullAgentStillMeasured, scenarioUngatedSkips, scenarioParserRejects,
  scenarioUnparseableTwiceHalts, scenarioUnreviewedLine, scenarioUnreviewedHalts,
  scenarioUnreviewedUnparseable, scenarioNoReviewersNoCount, scenarioRealVerify, scenarioRealUnreviewed]
JS_EOF

finish
