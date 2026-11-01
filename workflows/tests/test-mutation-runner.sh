#!/usr/bin/env bash
# gh-159: the mutation run is started by a script-built line, detached, and asked
# about until its exit file exists, so a gate longer than one Bash call is not
# cut off and no model reads its verdict. Covers the lines run in bash against a
# scratch repo with a fake gate (a long run, a failing one, a dead one, one the
# stage budget kills, the flags a later pass asks for) and the strict parse of
# what the runner printed; see harness.sh.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/harness.sh"

run_js_scenarios <<'JS_EOF'
const promptOf = (captured, label) => captured.calls.find(c => c.label === label)?.prompt ?? ''
const fenceOf = (prompt) => /```bash\n([\s\S]*?)\n```/.exec(prompt)?.[1].split('\n') ?? []
const gated = (over = {}) => ({ mutationGated: true, ...over })
const red = () => ({ green: false, head_sha: REVIEWED_THROUGH, detail: 'stub red', scored: false })
const green = () => ({ green: true, head_sha: REVIEWED_THROUGH, detail: 'stub green', scored: true })
const SHELL_HEAD = 'abc0000000000000000000000000000000000009'
const runLabels = (captured) => captured.calls.map(c => c.label).filter(l => l.startsWith('mutation-run:'))
const agentCalls = (captured) => captured.calls.filter(c => /^mutation:\d+$/.test(c.label)).length

const scratchRepo = () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "touchstone o'clock -"))
  const env = { ...process.env, GIT_AUTHOR_NAME: 'test', GIT_AUTHOR_EMAIL: 't@t',
    GIT_COMMITTER_NAME: 'test', GIT_COMMITTER_EMAIL: 't@t' }
  const git = (...a) => execFileSync('git', ['-C', dir, ...a], { env })
  execFileSync('git', ['init', '-q', dir])
  fs.writeFileSync(path.join(dir, 'a.txt'), 'a\n')
  git('add', '-A')
  git('-c', 'commit.gpgsign=false', '-c', 'gpg.format=openpgp', 'commit', '-q', '-m', 'scratch')
  return dir
}
const branchAt = (dir) => ({ created: true, branch: 'feat/gh-21-stub', base: 'main', path: dir,
  ticket: '21', detail: 'stub', dirty: false })

// A fake mutation-check.sh at the plugin's own layout under a path with a space,
// with this plugin's manifest two levels above it, so the line's checks on which
// copy ran pass. body is the script after its shebang.
const withFakeGate = async (body, fn, { manifest = true } = {}) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'fake gate-'))
  const skill = path.join(root, 'skills', 'crap-controlled-changes')
  fs.mkdirSync(skill, { recursive: true })
  if (manifest) {
    fs.mkdirSync(path.join(root, '.claude-plugin'))
    fs.writeFileSync(path.join(root, '.claude-plugin', 'plugin.json'),
      JSON.stringify({ name: 'touchstone', version: STUB_PLUGIN_VERSION }))
  }
  const gate = path.join(skill, 'mutation-check.sh')
  fs.writeFileSync(gate, `#!/usr/bin/env bash\n${body}\n`, { mode: 0o755 })
  try { return await fn(gate) } finally { fs.rmSync(root, { recursive: true, force: true }) }
}
const withWait = async (seconds, fn) => {
  process.env.TOUCHSTONE_CHECK_WAIT = String(seconds)
  try { return await fn() } finally { delete process.env.TOUCHSTONE_CHECK_WAIT }
}
const substituteGate = (gate) => (l) => l.replace('g=mutation-check.sh ', gate.includes(' ') ? `g='${gate}' ` : `g=${gate} `)
// The relay: runs every line of the prompt for real, after putting the gate's
// path where the bare name stands, and returns what they printed. outs keeps
// each reply, so a scenario can read what a poll saw.
const relay = (gate, outs, edit = substituteGate(gate)) => (label, prompt) => {
  const output = fenceOf(prompt).map(line =>
    spawnSync('bash', ['-c', edit(line)], { encoding: 'utf8' }).stdout).join('')
  outs.push({ label, output })
  return { output }
}
const RUN_ROW = /^TOUCHSTONE_MUTATION_RUN (\S+) (\d+) (\S+) (\/.+?\/mutation\.log) (\S+) (\S+) (.+)$/
const PENDING_ROW = /^TOUCHSTONE_MUTATION_PENDING mutation ([01]) (\/.+\/mutation\.log)$/
const rowOf = (outs, re) => outs.map(o => re.exec(o.output.trim())).filter(Boolean).pop()
// Whether a process is still alive: kill -0 throws once it is gone.
const alive = (pid) => { try { process.kill(pid, 0); return true } catch { return false } }
// The lines have to get past the plugin's own gate-pipe hook, which an agent running
// them in a gated session triggers.
const HOOK = path.join(path.dirname(SCRIPT_PATH), '..', 'hooks', 'gate-pipe-gate.py')
const hookExit = (command) => spawnSync('python3', [HOOK],
  { input: JSON.stringify({ tool_input: { command } }), encoding: 'utf8' }).status
const pidOf = (dir, run) => Number(fs.readFileSync(path.join(dir, '.git', 'touchstone-gates', run, 'mutation.pid'), 'utf8'))

async function scenarioLongRunIsPolled() {
  console.log('\n== scenario MA: a run that outlasts one wait is asked about again until its exit file exists, and the agent is told its exit and log')
  const dir = scratchRepo()
  try {
    await withFakeGate('sleep 4\necho "mutation-check: EXIT=0 MUTATION_OK"', async (gate) => {
      const outs = []
      const { result, captured } = await withWait(1, () => run(gated({ branchResult: branchAt(dir),
        mutationRun: relay(gate, outs), mutationResult: green })))
      const polls = runLabels(captured).filter(l => /^mutation-run:1(:poll:\d+)?$/.test(l))
      check('the first attempt was asked about more than once', polls.length > 1, true)
      check('the polls are labelled in order', polls.slice(0, 2), ['mutation-run:1', 'mutation-run:1:poll:2'])
      check('an early reply said the run was still going', PENDING_ROW.exec(outs[0].output.trim())?.[1], '1')
      const done = RUN_ROW.exec(outs[outs.length - 1].output.trim())
      check('the last reply carries the exit, the gate\'s trailer and the gate it ran',
        [done?.[2], done?.[3], done?.[7]], ['0', '0', gate])
      check('the log holds what the gate printed', fs.readFileSync(done?.[4] ?? '/nonexistent', 'utf8'),
        'mutation-check: EXIT=0 MUTATION_OK\n')
      check('the log sits under the worktree\'s git dir, in this run\'s directory',
        path.dirname(fs.realpathSync(done?.[4] ?? '/nonexistent')),
        path.join(fs.realpathSync(dir), '.git', 'touchstone-gates', done?.[1] ?? ''))
      check('the gate that ran is recorded beside it',
        fs.readFileSync(path.join(path.dirname(done?.[4] ?? '/nonexistent'), 'mutation.gate'), 'utf8'), gate)
      const p = promptOf(captured, 'mutation:1')
      check('the agent is told the exit', p.includes('exited 0'), true)
      check('and where the log is', p.includes(done?.[4] ?? 'no log'), true)
      check('the run came before the agent, and the verdict line after it',
        [captured.calls.findIndex(c => c.label === 'mutation-run:1') < captured.calls.findIndex(c => c.label === 'mutation:1'),
         captured.calls.findIndex(c => c.label === 'mutation:1') < captured.calls.findIndex(c => c.label === 'mutation-verify:1')],
        [true, true])
      check('green, and nothing halted', [result.halted_at, result.mutation?.green], [undefined, true])
      check('the tree stays clean', execFileSync('git', ['-C', dir, 'status', '--porcelain'], { encoding: 'utf8' }), '')
    })
  } finally {
    fs.rmSync(dir, { recursive: true, force: true })
  }
}

async function scenarioFailingRunReachesTheAgent() {
  console.log('\n== scenario MB: a run that exits 1 hands its log path to the mutation agent, which owns killing the survivors')
  const dir = scratchRepo()
  try {
    await withFakeGate('echo "pkg/a.py:3  ReplaceTrue  SURVIVED  id=abc"\necho "mutation-check: EXIT=1 KILL_SURVIVORS"\nexit 1', async (gate) => {
      const outs = []
      const { result, captured } = await run(gated({ branchResult: branchAt(dir),
        mutationRun: relay(gate, outs), mutationResult: red }))
      const row = rowOf(outs, RUN_ROW)
      check('the line printed exit 1 with the gate\'s own trailer', [row?.[2], row?.[3]], ['1', '1'])
      check('the log holds the survivor row', fs.readFileSync(row?.[4] ?? '/nonexistent', 'utf8').includes('SURVIVED  id=abc'), true)
      const p = promptOf(captured, 'mutation:1')
      check('the agent prompt says exit 1 and names the log', [p.includes('exited 1'), p.includes(row?.[4] ?? 'no log')], [true, true])
      check('the agent ran once', agentCalls(captured), 1)
      check('the run is not green, so it halts at Mutation', [result.halted_at, result.mutation?.green], ['Mutation', false])
      check('the note names the exit and the log of the last run',
        (result.note ?? '').includes(`exited 1; its output is ${row?.[4]}`), true)
    })
  } finally {
    fs.rmSync(dir, { recursive: true, force: true })
  }
}

async function scenarioSetupExitReachesTheAgent() {
  console.log('\n== scenario MC: a run that exits 2 or 4 is not a pass and not a halt of its own: the agent reads the log')
  const dir = scratchRepo()
  try {
    for (const exit of [2, 4]) {
      await withFakeGate(`echo "mutation-check: EXIT=${exit} see the output above"\nexit ${exit}`, async (gate) => {
        const outs = []
        const { result, captured } = await run(gated({ branchResult: branchAt(dir),
          mutationRun: relay(gate, outs), mutationResult: red }))
        check(`exit ${exit}: the agent is told the exit`, promptOf(captured, 'mutation:1').includes(`exited ${exit}`), true)
        check(`exit ${exit}: it is red`, [result.halted_at, result.mutation?.green], ['Mutation', false])
      })
    }
  } finally {
    fs.rmSync(dir, { recursive: true, force: true })
  }
}

async function scenarioDeadRunHalts() {
  console.log('\n== scenario MD: a run whose process dies without an exit file halts at Mutation, names its log, and no further attempt runs')
  const dir = scratchRepo()
  try {
    await withFakeGate('sleep 2\nkill -9 0', async (gate) => {
      const outs = []
      const { result, captured } = await withWait(1, () => run(gated({ args: { maxGateAttempts: 3 },
        branchResult: branchAt(dir), mutationRun: relay(gate, outs), mutationResult: green })))
      const pending = rowOf(outs, PENDING_ROW)
      check('the last reply said the process was gone', pending?.[1], '0')
      check('halted at Mutation, not green', [result.halted_at, result.mutation?.green], ['Mutation', false])
      check('the note names the log', (result.note ?? '').includes(pending?.[2] ?? 'no log'), true)
      check('the note says no exit code was recorded', (result.note ?? '').includes('stopped without recording an exit code'), true)
      check('the log is the run\'s own', (pending?.[2] ?? '').includes('/touchstone-gates/'), true)
      check('no agent and no second run', [agentCalls(captured), runLabels(captured).filter(l => l.startsWith('mutation-run:2')).length], [0, 0])
      check('no verdict line after it either', callCount(captured, 'mutation-verify:1'), 0)
    })
  } finally {
    fs.rmSync(dir, { recursive: true, force: true })
  }
}

async function scenarioBudgetKillsTheRun() {
  console.log('\n== scenario ME: a mutation stage budget stops the asking, kills the run and halts naming its log')
  const dir = scratchRepo()
  try {
    await withFakeGate('sleep 30', async (gate) => {
      const outs = []
      const { result, captured } = await withWait(1, () => run(gated({
        args: { stageBudgets: { mutation: 1500 }, maxGateAttempts: 3 },
        budgetPerAgentCall: 1000, branchResult: branchAt(dir), mutationRun: relay(gate, outs) })))
      const pending = rowOf(outs, PENDING_ROW)
      check('a kill was sent for the attempt', callCount(captured, 'mutation-run:1:kill'), 1)
      check('the run is not asked about again after the kill',
        runLabels(captured).filter(l => /^mutation-run:1:poll:/.test(l)).length, 0)
      const pid = pidOf(dir, /\/touchstone-gates\/([^/]+)\//.exec(pending?.[2] ?? '')?.[1] ?? '')
      await new Promise(r => setTimeout(r, 500))
      check('the process is gone', alive(pid), false)
      check('the kill line passes the gate-pipe hook', fenceOf(promptOf(captured, 'mutation-run:1:kill')).map(hookExit), [0])
      check('halted at Mutation, not green', [result.halted_at, result.mutation?.green], ['Mutation', false])
      check('the note names the budget and the log',
        [/mutation stage budget/.test(result.note ?? ''), (result.note ?? '').includes(pending?.[2] ?? 'no log')], [true, true])
      check('no agent and no second attempt', [agentCalls(captured), runLabels(captured).some(l => l.startsWith('mutation-run:2'))], [0, false])
    })
  } finally {
    fs.rmSync(dir, { recursive: true, force: true })
  }
}

async function scenarioNoBudgetNoCeiling() {
  console.log('\n== scenario MF: with no mutation stage budget a live run is asked about for as long as it lives, however much was spent')
  const polls = 9
  let asked = 0
  const { result, captured } = await run(gated({ budgetPerAgentCall: 10_000_000, mutationResult: green,
    mutationRun: (label, prompt) => label.endsWith(':kill') ? { output: '' }
      : ++asked <= polls ? { output: mutationPendingOutput(prompt) } : {} }))
  check('every poll got its answer and the run then finished',
    runLabels(captured).filter(l => !l.endsWith(':kill')).length, polls + 1)
  check('no kill was ever sent', callCount(captured, 'mutation-run:1:kill'), 0)
  check('a poll\'s line differs from the first ask\'s only by the cleanup of an earlier run',
    promptOf(captured, 'mutation-run:1').includes('rm -rf "$d"') && !promptOf(captured, 'mutation-run:1:poll:2').includes('rm -rf'), true)
  check('and both pass the gate-pipe hook',
    [promptOf(captured, 'mutation-run:1'), promptOf(captured, 'mutation-run:1:poll:2')].map(p => fenceOf(p).map(hookExit)), [[0], [0]])
  check('green', [result.halted_at, result.mutation?.green], [undefined, true])
}

async function scenarioNextPassFlags() {
  console.log('\n== scenario MG: the flags the agent asks for reach the next run line quoted once, and only that one')
  const dir = scratchRepo()
  try {
    const only = "a  b\n it's"
    const seen = "a b it's"
    await withFakeGate('printf \'saw MUTATION_ONLY=%s args=%s\\n\' "${MUTATION_ONLY-unset}" "$*"\n' +
      'echo "mutation-check: EXIT=0 MUTATION_OK"', async (gate) => {
      const outs = []
      const { captured } = await run(gated({ args: { maxGateAttempts: 3 }, branchResult: branchAt(dir),
        mutationRun: relay(gate, outs),
        mutationResult: (attempt) => ({ ...red(), head_sha: String(attempt).padStart(40, '0'),
          ...(attempt === 1 ? { next_pass: { only, full: true } } : {}) }) }))
      const logs = outs.filter(o => RUN_ROW.test(o.output.trim())).map(o => fs.readFileSync(RUN_ROW.exec(o.output.trim())[4], 'utf8'))
      check('the first run had neither flag', [logs[0]], [`saw MUTATION_ONLY=unset args=${dir}\nmutation-check: EXIT=0 MUTATION_OK\n`])
      check('the second run saw the globs as one value, on one line, and --full',
        logs[1], `saw MUTATION_ONLY=${seen} args=${dir} --full\nmutation-check: EXIT=0 MUTATION_OK\n`)
      check('the run line is still one line', fenceOf(promptOf(captured, 'mutation-run:2')).length, 1)
      check('the third run is back to no flags: a pass asks for its own', logs[2]?.startsWith('saw MUTATION_ONLY=unset'), true)
      check('the first run line carries neither', [promptOf(captured, 'mutation-run:1').includes('MUTATION_ONLY'),
        promptOf(captured, 'mutation-run:1').includes('--full')], [false, false])
    })
  } finally {
    fs.rmSync(dir, { recursive: true, force: true })
  }
}

async function scenarioGateEnvIsEvaluated() {
  console.log('\n== scenario MH: a repo\'s scripts/gate-env.sh is evaluated in the run\'s own shell before the gate')
  const dir = scratchRepo()
  try {
    fs.mkdirSync(path.join(dir, 'scripts'))
    fs.writeFileSync(path.join(dir, 'scripts', 'gate-env.sh'), '#!/usr/bin/env bash\necho "export FROM_GATE_ENV=$1"\n', { mode: 0o755 })
    await withFakeGate('echo "env=${FROM_GATE_ENV-unset}"\necho "mutation-check: EXIT=0 MUTATION_OK"', async (gate) => {
      const outs = []
      await run(gated({ branchResult: branchAt(dir), mutationRun: relay(gate, outs), mutationResult: green }))
      check('the gate saw what gate-env.sh exported for the mutation target',
        fs.readFileSync(RUN_ROW.exec(outs[0].output.trim())?.[4] ?? '/nonexistent', 'utf8'),
        'env=mutation\nmutation-check: EXIT=0 MUTATION_OK\n')
    })
  } finally {
    fs.rmSync(dir, { recursive: true, force: true })
  }
}

async function scenarioNotTheGate() {
  console.log('\n== scenario MI: a run that did not run the real gate is unmeasured: a missing or wrong trailer, or another copy')
  const dir = scratchRepo()
  try {
    const cases = [
      ['exit 0 with no trailer', 'exit 0', (gate) => gate],
      ['exit 1 with no trailer', 'echo SURVIVED\nexit 1', (gate) => gate],
      ['`true` in place of the gate', 'exit 0', () => 'true'],
      ['a trailer that disagrees with the exit', 'echo "mutation-check: EXIT=0 MUTATION_OK"\nexit 1', (gate) => gate],
    ]
    for (const [name, body, pick] of cases) {
      await withFakeGate(body, async (gate) => {
        const outs = []
        const { result, captured } = await run(gated({ args: { maxGateAttempts: 3 }, branchResult: branchAt(dir),
          mutationRun: relay(pick(gate), outs, substituteGate(pick(gate))), mutationResult: green }))
        check(`${name}: asked once more, then halted as unmeasured`,
          [callCount(captured, 'mutation-run:1:retry'), result.halted_at, /could not be measured/.test(result.note ?? '')],
          [1, 'Mutation', true])
        check(`${name}: no agent, no second attempt`, [agentCalls(captured), runLabels(captured).some(l => l.startsWith('mutation-run:2'))], [0, false])
        check(`${name}: not green`, result.mutation?.green, false)
      })
    }
    await withFakeGate('echo "mutation-check: EXIT=0 MUTATION_OK"', async (gate) => {
      const { result } = await run(gated({ branchResult: branchAt(dir), mutationRun: relay(gate, []), mutationResult: green }))
      check('a copy with no plugin manifest beside it is another copy, and is named',
        [result.halted_at, (result.note ?? '').includes(`ran a different copy of mutation-check.sh: ${gate} (no plugin manifest beside it)`)],
        ['Mutation', true])
    }, { manifest: false })
  } finally {
    fs.rmSync(dir, { recursive: true, force: true })
  }
}

async function scenarioParserRejects() {
  console.log('\n== scenario MJ: a reply that is not exactly one well-formed line is asked about once more, then halts as unmeasured')
  const bad = {
    'no output': () => '',
    'two lines': (good) => `${good}\n${good}`,
    'another run': (good) => good.replace(/-mutation-run-\d+ /, '-mutation-run-99 '),
    'a non-integer exit': (good) => good.replace(/^(\S+ \S+) 0 0 /, '$1 zero zero '),
    'a trailer that disagrees with the exit': (good) => good.replace(/^(\S+ \S+ 0) 0 /, '$1 1 '),
    'exit 0 with no trailer': (good) => good.replace(/^(\S+ \S+ 0) 0 /, '$1 - '),
    'a log outside the run': (good) => good.replace(/\/touchstone-gates\//, '/elsewhere/'),
    'another run\'s log': (good) => good.replace(/mutation-run-1\/mutation\.log/, 'mutation-run-2/mutation.log'),
    'a relative log': (good) => good.replace(/ \/\S+\/mutation\.log /, ' mutation.log '),
    'a prefixed line': (good) => `ok: ${good}`,
    'another version of this plugin': (good) => good.replace(` touchstone ${STUB_PLUGIN_VERSION} `, ' touchstone 0.1.0 '),
    'another plugin': (good) => good.replace(` touchstone ${STUB_PLUGIN_VERSION} `, ` other ${STUB_PLUGIN_VERSION} `),
    'a bare gate name': (good) => good.replace(PLUGIN_GATE, 'mutation-check.sh'),
    'another script in the plugin': (good) => good.replace(PLUGIN_GATE, PLUGIN_GATE.replace('mutation-check.sh', 'crap-check.sh')),
    'no gate field': (good) => good.replace(` ${PLUGIN_GATE}`, ''),
    'a malformed pending line': () => 'TOUCHSTONE_MUTATION_PENDING mutation maybe /x/mutation.log',
    'a pending line for another id': (good, prompt) => mutationPendingOutput(prompt).replace(' mutation ', ' check:1 '),
    'a pending line with a log outside the run': (good, prompt) => mutationPendingOutput(prompt).replace('/touchstone-gates/', '/elsewhere/'),
  }
  const notTheGate = ['a trailer that disagrees with the exit', 'exit 0 with no trailer', 'another version of this plugin',
    'another plugin', 'a bare gate name', 'another script in the plugin']
  for (const [name, mangle] of Object.entries(bad)) {
    const { result, captured } = await run(gated({ args: { maxGateAttempts: 3 }, mutationResult: green,
      mutationRun: (label, prompt) => label.endsWith(':kill') ? { output: '' } : { output: mangle(mutationRunOutput(prompt, 0), prompt) } }))
    check(`${name}: asked once more`, callCount(captured, 'mutation-run:1:retry'), 1)
    check(`${name}: a new run only when what ran was not the gate`,
      callCount(captured, 'mutation-run:1:rerun'), notTheGate.includes(name) ? 1 : 0)
    check(`${name}: halted as unmeasured, with both reasons`,
      [result.halted_at, /could not be measured/.test(result.note ?? ''), result.mutation?.run_unmeasured?.reasons?.length], ['Mutation', true, 2])
    check(`${name}: no agent`, agentCalls(captured), 0)
  }
  const recovers = await run(gated({ mutationResult: green,
    mutationRun: (label, prompt) => label.endsWith(':retry') ? {} : { output: 'garbage' } }))
  check('a retry that reads well is used', [recovers.result.halted_at, recovers.result.mutation?.green], [undefined, true])
  const unreadableThenGone = await run(gated({ mutationResult: green,
    mutationRun: (label, prompt) => label.endsWith(':retry') ? { output: mutationPendingOutput(prompt, 0) } : { output: 'garbage' } }))
  check('a retry that finds the process gone halts as a dead run, not as unmeasured',
    [unreadableThenGone.result.halted_at, /stopped without recording an exit code/.test(unreadableThenGone.result.note ?? '')], ['Mutation', true])
}

async function scenarioScriptNotFoundRunsAgain() {
  console.log('\n== scenario MK: exit 127 means the relay left the bare name, which nothing ran: a fresh run is made once')
  const missing = { exit: 127, trailer: '-', gate: 'mutation-check.sh', name: '-', version: '-' }
  const once = await run(gated({ mutationResult: green,
    mutationRun: (label) => label === 'mutation-run:1' ? missing : {} }))
  check('a second relay got it right: the rerun is its own run and the agent follows',
    [callCount(once.captured, 'mutation-run:1:rerun'), agentCalls(once.captured), once.result.halted_at], [1, 1, undefined])
  check('the rerun is a different run id',
    mutationRunOf(promptOf(once.captured, 'mutation-run:1')) !== mutationRunOf(promptOf(once.captured, 'mutation-run:1:rerun')), true)
  const twice = await run(gated({ args: { maxGateAttempts: 3 }, mutationResult: green, mutationRun: () => missing }))
  check('still not found: halted as unmeasured, saying so, with no agent',
    [twice.result.halted_at, /not found/.test(twice.result.note ?? ''), agentCalls(twice.captured)], ['Mutation', true, 0])
}

async function scenarioPreLoopVerify() {
  console.log('\n== scenario ML: a branch --verify already reads green needs no run, and an ungated repo starts no line at all')
  const green0 = await run(gated({ mutationVerifyFirst: () => ({ exit: 0, head: SHELL_HEAD }) }))
  check('green, from the shell\'s head', [green0.result.halted_at, green0.result.mutation?.green, green0.result.mutation?.head_sha],
    [undefined, true, SHELL_HEAD])
  check('no run and no agent', [runLabels(green0.captured).length, agentCalls(green0.captured)], [0, 0])
  check('one verdict line, before anything else',
    [callCount(green0.captured, 'mutation-verify:0'), callCount(green0.captured, 'mutation-verify:1')], [1, 0])
  const red5 = await run(gated({ mutationResult: green }))
  check('exit 5 before the loop leaves it to the loop: the run and the agent follow',
    [callCount(red5.captured, 'mutation-run:1'), agentCalls(red5.captured), red5.result.halted_at], [1, 1, undefined])
  const setup = await run(gated({ args: { maxGateAttempts: 3 }, mutationVerifyFirst: () => ({ exit: 2, trailer: 2 }) }))
  check('a --verify that cannot run halts as setup, before any run',
    [setup.result.halted_at, /could not run/.test(setup.result.note ?? ''), runLabels(setup.captured).length], ['Mutation', true, 0])
  const bare = await run({})
  check('an ungated repo runs no verdict line and no run line', [
    bare.captured.calls.filter(c => c.label.startsWith('mutation-verify')).length, runLabels(bare.captured).length,
    agentCalls(bare.captured)], [0, 0, 0])
  check('and stays green', bare.result.mutation?.green, true)
}

async function scenarioPromptsAreDirectAboutTheRun() {
  console.log('\n== scenario MM: no prompt sends the agent to run the gate or to split a run to fit a Bash call, and needs_user_run is gone')
  const { captured } = await run(gated({ mutationResult: green }))
  const agent = promptOf(captured, 'mutation:1')
  const relayPrompt = promptOf(captured, 'mutation-run:1')
  for (const [name, text] of [['the mutation agent prompt', agent], ['the run relay prompt', relayPrompt]]) {
    check(`${name}: no needs_user_run, split or Bash ceiling`, /needs_user_run|SPLIT|Bash ceiling|ceiling/.test(text), false)
  }
  check('the agent is told not to run the gate itself, bar --verify', /Never run mutation-check\.sh yourself/.test(agent), true)
  check('the agent prompt does not allow a background run', /run_in_background/.test(agent), false)
  check('the agent may ask for the next pass', /next_pass/.test(agent), true)
  const src = fs.readFileSync(SCRIPT_PATH, 'utf8')
  check('the script no longer mentions needs_user_run anywhere', src.includes('needs_user_run'), false)
  const schema = captured.calls.find(c => c.label === 'mutation:1')?.schema
  check('the GATE schema has next_pass and no needs_user_run',
    [Boolean(schema?.properties?.next_pass), schema?.properties?.needs_user_run], [true, undefined])
  check('next_pass asks for only and full, both optional',
    [Object.keys(schema?.properties?.next_pass?.properties ?? {}), schema?.properties?.next_pass?.required], [['only', 'full'], undefined])
  check('the run relay names the namespaced skill and warns off the bare one',
    [relayPrompt.includes('touchstone:crap-controlled-changes'), relayPrompt.includes('never a skill named plain crap-controlled-changes')], [true, true])
  check('the relay is a haiku call at low effort and the fence is one line',
    [captured.calls.find(c => c.label === 'mutation-run:1')?.model, captured.calls.find(c => c.label === 'mutation-run:1')?.effort,
     fenceOf(relayPrompt).length], ['haiku', 'low', 1])
}

async function scenarioRerunOfTheSamePlan() {
  console.log('\n== scenario MN: a rerun of the same plan in the same worktree measures afresh instead of reading what the last run left')
  const dir = scratchRepo()
  try {
    await withFakeGate('sleep 30', async (gate) => {
      await withWait(1, () => run(gated({ args: { stageBudgets: { mutation: 1500 } }, budgetPerAgentCall: 1000,
        branchResult: branchAt(dir), mutationRun: relay(gate, []) })))
    })
    await withFakeGate('echo "mutation-check: EXIT=1 KILL_SURVIVORS"\nexit 1', async (gate) => {
      const outs = []
      const { captured } = await withWait(1, () => run(gated({ branchResult: branchAt(dir),
        mutationRun: relay(gate, outs), mutationResult: red })))
      check('the killed run\'s pid and running file did not stand in for this run',
        [outs.length, RUN_ROW.exec(outs[0]?.output.trim() ?? '')?.[2]], [1, '1'])
      check('so the agent was told this run\'s exit', promptOf(captured, 'mutation:1').includes('exited 1'), true)
    })
    await withFakeGate('echo "mutation-check: EXIT=0 MUTATION_OK"', async (gate) => {
      const outs = []
      const { result } = await run(gated({ branchResult: branchAt(dir), mutationRun: relay(gate, outs), mutationResult: green }))
      check('and a finished run\'s exit file did not either: this one exited 0',
        RUN_ROW.exec(outs[0]?.output.trim() ?? '')?.[2], '0')
      check('and its log is this gate\'s output', fs.readFileSync(RUN_ROW.exec(outs[0]?.output.trim() ?? '')?.[4] ?? '/nonexistent', 'utf8'),
        'mutation-check: EXIT=0 MUTATION_OK\n')
      check('green', result.mutation?.green, true)
    })
  } finally {
    fs.rmSync(dir, { recursive: true, force: true })
  }
}

const replies = (kinds) => {
  let n = 0
  return (label, prompt) => {
    if (label.endsWith(':kill')) return { output: '' }
    const kind = kinds[n++] ?? 'done'
    return kind === 'pending' ? { output: mutationPendingOutput(prompt) }
      : kind === 'garbage' ? { output: 'garbage' } : {}
  }
}
const GLITCH_LIMIT = 5

async function scenarioFlakyRelayDuringLiveRun() {
  console.log('\n== scenario MO: replies that cannot be read while the run is known alive are asked about again; the gate is killed before any halt')
  const glitches = (n) => Array(n).fill('garbage')
  const scattered = await run(gated({ mutationResult: green,
    mutationRun: replies(['pending', 'garbage', 'pending', 'garbage', 'pending', 'garbage']) }))
  check('glitches between good polls never end the run: it finishes green, and nothing was killed',
    [scattered.result.halted_at, scattered.result.mutation?.green, callCount(scattered.captured, 'mutation-run:1:kill')],
    [undefined, true, 0])
  check('every glitch was asked about again, in the same run',
    runLabels(scattered.captured).filter(l => !l.endsWith(':kill')).length, 7)
  const nearly = await run(gated({ mutationResult: green,
    mutationRun: replies(['pending', ...glitches(GLITCH_LIMIT - 1)]) }))
  check('one fewer glitch in a row than the limit is still asked again',
    [nearly.result.halted_at, nearly.result.mutation?.green, callCount(nearly.captured, 'mutation-run:1:kill')], [undefined, true, 0])
  const stuck = await run(gated({ mutationResult: green,
    mutationRun: replies(['pending', ...glitches(GLITCH_LIMIT + 2)]) }))
  check('the limit of glitches in a row halts as unmeasured', [stuck.result.halted_at, /could not be measured/.test(stuck.result.note ?? '')], ['Mutation', true])
  check('and sends the kill first, since the process was last seen alive', callCount(stuck.captured, 'mutation-run:1:kill'), 1)
  check('the kill line is the same run\'s, and passes the gate-pipe hook',
    fenceOf(promptOf(stuck.captured, 'mutation-run:1:kill')).map(hookExit), [0])
  check('the note says the gate was killed, names where its log is and what to check',
    [/killed/.test(stuck.result.note ?? ''), /touchstone-gates\/\S*mutation-run-1\/mutation\.log/.test(stuck.result.note ?? ''),
     /status and git -C \S+ stash list/.test(stuck.result.note ?? '')], [true, true, true])
  check('no agent and no second attempt', [agentCalls(stuck.captured), runLabels(stuck.captured).some(l => l.startsWith('mutation-run:2'))], [0, false])
  const never = await run(gated({ mutationResult: green, mutationRun: replies(['garbage', 'garbage']) }))
  check('two unreadable replies from the start leave the run in an unknown state: killed too',
    [never.result.halted_at, callCount(never.captured, 'mutation-run:1:kill')], ['Mutation', 1])
}

async function scenarioWrongGateGetsAFreshRun() {
  console.log('\n== scenario MP: a finished run that read as another copy of the gate is read once more, then run again as a new run that can reach the real gate')
  const dir = scratchRepo()
  try {
    await withFakeGate('echo "mutation-check: EXIT=0 MUTATION_OK"', async (gate) => {
      const outs = []
      let asked = 0
      const relayPinnedOnce = (label, prompt) => {
        const pick = asked++ === 0 ? 'true' : gate
        return relay(pick, outs, substituteGate(pick))(label, prompt)
      }
      const { result, captured } = await run(gated({ args: { maxGateAttempts: 3 }, branchResult: branchAt(dir),
        mutationRun: relayPinnedOnce, mutationResult: green }))
      check('the first ask ran the substitute, the retry only read it again, and the new run is its own',
        [callCount(captured, 'mutation-run:1'), callCount(captured, 'mutation-run:1:retry'), callCount(captured, 'mutation-run:1:rerun')], [1, 1, 1])
      const rows = outs.map(o => RUN_ROW.exec(o.output.trim())).filter(Boolean)
      check('the new run is another run id, and it ran the real gate',
        [new Set(rows.map(r => r[1])).size, rows.pop()?.[7]], [2, gate])
      check('green, with the agent told this run\'s exit',
        [result.halted_at, result.mutation?.green, promptOf(captured, 'mutation:1').includes('exited 0')], [undefined, true, true])
    })
  } finally {
    fs.rmSync(dir, { recursive: true, force: true })
  }
  const miscopy = await run(gated({ mutationResult: green,
    mutationRun: (label, prompt) => label.endsWith(':retry') ? {}
      : { output: mutationRunOutput(prompt, 0).replace(PLUGIN_GATE, 'mutation-check.sh') } }))
  check('a finished run misread once and read fine on the retry is not run again',
    [callCount(miscopy.captured, 'mutation-run:1:rerun'), miscopy.result.halted_at, miscopy.result.mutation?.green], [0, undefined, true])
}

async function scenarioFullPassAskedOnGreenIsRun() {
  console.log('\n== scenario MQ: a pass the agent asks for runs even when --verify already reads green')
  const runLines = (captured) => captured.calls.filter(c => /^mutation-run:\d+$/.test(c.label))
    .map(c => fenceOf(c.prompt).join('\n'))
  for (const next_pass of [{ full: true }, { only: 'pkg/**' }]) {
    const { result, captured } = await run(gated({ args: { maxGateAttempts: 3 },
      mutationResult: (attempt) => ({ green: true, head_sha: REVIEWED_THROUGH, scored: false, detail: 'a fixture changed',
        ...(attempt === 1 ? { next_pass } : {}) }),
      mutationVerify: () => ({ exit: 0, head: REVIEWED_THROUGH }) }))
    const lines = runLines(captured)
    const flag = next_pass.full ? ' --full' : 'MUTATION_ONLY='
    check(`${JSON.stringify(next_pass)}: a second run follows, with the flag, and a third does not`,
      [lines.length, lines[0].includes(flag), lines[1]?.includes(flag)], [2, false, true])
    check(`${JSON.stringify(next_pass)}: the agent read both runs, and the phase is green`,
      [agentCalls(captured), result.halted_at, result.mutation?.green], [2, undefined, true])
  }
}

async function scenarioRunBudgetKillsTheRun() {
  console.log('\n== scenario MR: a run budget that runs out between polls kills the gate, and the halt names its log')
  const dir = scratchRepo()
  try {
    await withFakeGate('sleep 30', async (gate) => {
      const outs = []
      const { result, captured } = await withWait(1, () => run(gated({
        args: { runBudget: 5_000_000 }, spendAllAfter: 'mutation-run:1',
        branchResult: branchAt(dir), mutationRun: relay(gate, outs) })))
      const pending = rowOf(outs, PENDING_ROW)
      check('the refused poll never ran, and the kill was sent past the spent budget',
        runLabels(captured), ['mutation-run:1', 'mutation-run:1:kill'])
      const pid = pidOf(dir, /\/touchstone-gates\/([^/]+)\//.exec(pending?.[2] ?? '')?.[1] ?? '')
      await new Promise(r => setTimeout(r, 500))
      check('the gate is no longer running', alive(pid), false)
      check('halted at Mutation on the run budget', [result.halted_at, /Run budget exhausted/.test(result.note ?? '')], ['Mutation', true])
      check('the note names the log, says the gate was killed and what to check',
        [(result.note ?? '').includes(pending?.[2] ?? 'no log'), /killed/.test(result.note ?? ''),
         /status and git -C .+ stash list/.test(result.note ?? '')], [true, true, true])
      check('the halt state carries the log', result.mutation?.run_cut_off?.log, pending?.[2])
    })
  } finally {
    fs.rmSync(dir, { recursive: true, force: true })
  }
}

async function scenarioRunBudgetRefusesTheFirstAsk() {
  console.log('\n== scenario MS: a run budget spent before the run started kills in case, and the halt does not say a gate was running')
  const { result, captured } = await run(gated({
    args: { runBudget: 5_000_000 }, spendAllAfter: 'mutation-verify:0',
    mutationResult: green, mutationRun: () => ({ output: '' }) }))
  const note = result.note ?? ''
  check('the refused ask never ran, and the kill was still sent', runLabels(captured), ['mutation-run:1:kill'])
  check('halted at Mutation on the run budget', [result.halted_at, /Run budget exhausted/.test(note)], ['Mutation', true])
  check('the note does not claim a gate was running', /was still running/.test(note), false)
  check('the note says a kill was sent in case the gate had started, and names the log it would write',
    [/kill was sent to the mutation gate in case it had started/.test(note),
     /touchstone-gates\/\S*mutation-run-1\/mutation\.log/.test(note)], [true, true])
  check('the halt state says no poll saw the gate alive', result.mutation?.run_cut_off?.seen_alive, false)
}

const SCENARIOS = [scenarioLongRunIsPolled, scenarioFailingRunReachesTheAgent, scenarioSetupExitReachesTheAgent,
  scenarioDeadRunHalts, scenarioBudgetKillsTheRun, scenarioNoBudgetNoCeiling, scenarioNextPassFlags,
  scenarioGateEnvIsEvaluated, scenarioNotTheGate, scenarioParserRejects, scenarioScriptNotFoundRunsAgain,
  scenarioRerunOfTheSamePlan, scenarioPreLoopVerify, scenarioPromptsAreDirectAboutTheRun,
  scenarioFlakyRelayDuringLiveRun, scenarioWrongGateGetsAFreshRun, scenarioFullPassAskedOnGreenIsRun,
  scenarioRunBudgetKillsTheRun, scenarioRunBudgetRefusesTheFirstAsk]
JS_EOF

finish
