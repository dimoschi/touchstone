#!/usr/bin/env bash
# gh-163: a check batch is run by one script-built line per check, never by a
# model copying commands or output. Covers the prompt, the strict parse of what
# the runner printed, the baseline's retry and halt, the log paths a fixer gets,
# and the real lines run in bash against a scratch repo; see harness.sh.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/harness.sh"

run_js_scenarios <<'JS_EOF'
const section = (fence) => ({ file: '/repo/AGENTS.md',
  sections: [{ heading: '## Checks', fence }], detail: 'stub' })
const ONE = section('make test')
const TWO = section('make test\nmake lint')
const THREE = section('make test\nmake lint\nmake vet')
const resumed = (discovery, checkRuns) => ({
  args: { existingBranch: true, openPr: true }, discovery, checkRuns,
  prResult: { opened: true, url: 'https://example.invalid/pr/163', note: 'stub ready' },
})
const promptOf = (captured, label) => captured.calls.find(c => c.label === label)?.prompt ?? ''
const WORKTREE_PATH_RE = /\/touchstone-checks\/[^/]+\//

async function scenarioPromptIsOneLinePerCheck() {
  console.log('\n== scenario RP: checks:run carries one self-contained line per check, an end line, and asks for output only')
  const { captured } = await run({ discovery: section("make test\nbash scripts/echo.sh 'a # b'") })
  const call = captured.calls.find(c => c.label === 'checks:run:1')
  const p = call?.prompt ?? ''
  const id = runIdOf(p)
  check('the run is the plan id and the attempt', /^[0-9a-f]{8}-1$/.test(id), true)
  const lineFor = (n, cmd) =>
    `d="$(git -C /tmp/stub-worktree rev-parse --path-format=absolute --git-path touchstone-checks/${id} 2>/dev/null)" && ` +
    `mkdir -p "$d" && { bash -c 'cd /tmp/stub-worktree && ${cmd}' >|"$d/check:${n}.log" 2>&1; ` +
    `printf 'TOUCHSTONE_CHECK %s %s %s\\n' check:${n} "$?" "$d/check:${n}.log"; }`
  check('check:1 is one line that logs to the git dir and prints only its id, exit and log',
    runnerLineOf(p, 'check:1'), lineFor(1, 'make test'))
  check('a command with quotes is quoted once, in the same line',
    runnerLineOf(p, 'check:2'), lineFor(2, `bash scripts/echo.sh '\\''a # b'\\''`))
  const endLine = `d="$(git -C /tmp/stub-worktree rev-parse --path-format=absolute --git-path touchstone-checks/${id} 2>/dev/null)" && ` +
    `mkdir -p "$d" && git -C /tmp/stub-worktree status --porcelain >|"$d/status.log" 2>|"$d/status.err" && ` +
    `{ if [ -s "$d/status.log" ]; then s=dirty; else s=clean; fi; ` +
    `printf 'TOUCHSTONE_CHECKS_END %s %s\\n' ${id} "$s"; }`
  const fence = /```bash\n([\s\S]*?)\n```/.exec(p)?.[1].split('\n')
  check('the fence is the two check lines, then the end line, and nothing else',
    fence, [lineFor(1, 'make test'), lineFor(2, `bash scripts/echo.sh '\\''a # b'\\''`), endLine])
  check('the schema asks for output and nothing else', JSON.stringify(call?.schema),
    JSON.stringify({ type: 'object', additionalProperties: false, required: ['output'],
      properties: { output: { type: 'string' } } }))
  check('it is a haiku call at low effort', [call?.model, call?.effort], ['haiku', 'low'])
  check('it demands one line at a time, in order', /one at a time, in the order given/.test(p), true)
  check('it names the foreground timeout', p.includes('600000 ms'), true)
  check('it forbids run_in_background', p.includes('run_in_background'), true)
  check('it forbids parallel runs', /never several at once/.test(p), true)
  check('it waits for each to return', /wait for each to return before starting the next/.test(p), true)
  check('it forbids fixing', /Do not fix, edit, or investigate a failure/.test(p), true)
  check('it names the bash -c cd as the one exception to never-cd',
    /exception to the rule above about never running cd/.test(p) && p.includes('bash -c'), true)
  check('it asks for the printed lines verbatim', /every line the calls printed, copied verbatim/.test(p), true)
  check('it never asks for a command, an exit_line or a check\'s output',
    ['exit_line', 'combined stdout', 'Report command'].some(s => p.includes(s)), false)
}

async function scenarioParserMeasures() {
  console.log('\n== scenario RA: a well-formed reply is measured; exit 0 is green, any nonzero (2 and 4 too) is red')
  const { result, captured } = await run(resumed(THREE,
    (attempt, prompt) => ({ output: runnerOutput(prompt, [0, 2, 4]) })))
  const id = runIdOf(promptOf(captured, 'checks:run:1'))
  check('nothing is unmeasured', result.checks?.unmeasured?.length, 0)
  check('the checks that exited 2 and 4 are red, the one that exited 0 is not',
    result.checks?.red?.map(c => [c.id, c.exit_code]), [['check:2', 2], ['check:3', 4]])
  check('a red check carries its declared command', result.checks?.red?.[0]?.command, 'make lint')
  check('and its log path', result.checks?.red?.[0]?.log, runnerLogOf(id, 'check:2'))
  check('no retry was needed', callCount(captured, 'checks:run:2'), 0)
}

async function scenarioParserTolerance() {
  console.log('\n== scenario RB: CRLF, blank lines and trailing spaces do not make a well-formed reply unmeasured')
  const { result } = await run(resumed(TWO, (attempt, prompt) => ({
    output: '\r\n' + runnerOutput(prompt, [0, 1]).split('\n').map(l => `${l}  `).join('\r\n\r\n') + '\r\n' })))
  check('measured, not unmeasured', result.checks?.unmeasured?.length, 0)
  check('the second check is red', result.checks?.red?.map(c => c.id), ['check:2'])
}

const REJECTED = [
  ['no output at all', () => '', 'no output'],
  ['a summary instead of the lines', () => '[... all hook suites completed successfully ...]', 'no end line'],
  ['no end line', (l) => l.slice(0, -1).join('\n'), 'no end line'],
  ['an end line that is not last', (l) => [l[0], l[2], l[1]].join('\n'), 'end line is not last'],
  ['two end lines', (l) => [...l, l[2]].join('\n'), 'end line repeated'],
  ['a malformed end line', (l) => [l[0], l[1], 'TOUCHSTONE_CHECKS_END'].join('\n'), 'malformed end line'],
  ['an end line naming another run', (l) => [l[0], l[1], 'TOUCHSTONE_CHECKS_END other-run clean'].join('\n'),
    'end line names run other-run, not '],
  ['a check with no line', (l) => [l[0], l[2]].join('\n'), 'no line for check:2'],
  ['a check reported twice', (l) => [l[0], l[0], l[1], l[2]].join('\n'), 'check:1 reported twice'],
  ['an id nobody asked for', (l) => [l[0], l[1], l[1].replace('check:2', 'check:9'), l[2]].join('\n'),
    'unexpected id check:9'],
  ['the checks out of order', (l) => [l[1], l[0], l[2]].join('\n'), 'check:2 reported where check:1 was expected'],
  ['a line of prose', (l) => [l[0], 'All checks passed.', l[1], l[2]].join('\n'), 'unexpected line "All checks passed."'],
  ['a malformed check line', (l) => [l[0], 'TOUCHSTONE_CHECK check:2', l[2]].join('\n'), 'malformed check line'],
  ['an exit that is not an integer', (l) => [l[0].replace(/^(\S+ \S+) 0 /, '$1 ok '), l[1], l[2]].join('\n'),
    'exit of check:1 is not an integer'],
  ['a fractional exit', (l) => [l[0].replace(/^(\S+ \S+) 0 /, '$1 1.5 '), l[1], l[2]].join('\n'),
    'exit of check:1 is not an integer'],
  ['a log path of another run', (l) => [l[0].replace(WORKTREE_PATH_RE, '/touchstone-checks/other-run/'), l[1], l[2]].join('\n'),
    'log path of check:1 is not under this run'],
  ['a log path of another check', (l) => [l[0].replace('check:1.log', 'check:2.log'), l[1], l[2]].join('\n'),
    'log path of check:1 is not under this run'],
  ['a log in another directory than the other rows', (l) => [l[0].replace(/ (\/.*)\/touchstone-checks\//, ' /elsewhere/touchstone-checks/'), l[1], l[2]].join('\n'),
    'log path of check:2 is not in the run directory'],
  ['a relative log path', (l) => [l[0].replace(/ \/.*touchstone-checks/, ' touchstone-checks'), l[1], l[2]].join('\n'),
    'log path of check:1 is not under this run'],
]

async function scenarioParserRejects() {
  console.log('\n== scenario RC: any deviation makes the whole batch unmeasured, with its own reason')
  for (const [what, build, want] of REJECTED) {
    const { result } = await run(resumed(TWO, (attempt, prompt) => ({
      output: build(runnerOutput(prompt, [0, 0]).split('\n'), prompt) })))
    const unmeasured = result.checks?.unmeasured ?? []
    check(`${what}: both checks are unmeasured, not just the one at fault`, unmeasured.map(u => u.id), ['check:1', 'check:2'])
    check(`${what}: nothing reads as red`, result.checks?.red?.length, 0)
    check(`${what}: the reason`, (unmeasured[0]?.reason ?? '').startsWith(want), true)
    check(`${what}: the same reason after the retry`, (unmeasured[0]?.reason_again ?? '').startsWith(want), true)
  }
}

async function scenarioNullReplyIsUnmeasured() {
  console.log('\n== scenario RD: a runner that returned nothing is unmeasured')
  const { result } = await run(resumed(ONE, () => null))
  check('unmeasured, with the reason', result.checks?.unmeasured?.map(u => [u.id, u.reason]), [['check:1', 'no output']])
}

async function scenarioBaselineRetriesOnce() {
  console.log('\n== scenario RE: an unmeasured baseline is retried once, under its own run, and the run goes on')
  const { result, captured } = await run({
    discovery: ONE,
    checkRuns: (attempt, prompt) => attempt === 1
      ? { output: 'I ran them and they all passed.' } : { output: runnerOutput(prompt, [0]) },
  })
  check('the run does not halt', result.halted_at, undefined)
  check('the baseline ran twice before Implement', [callCount(captured, 'checks:run:1'), callCount(captured, 'checks:run:2')], [1, 1])
  check('the post-Implement run is the third', callCount(captured, 'checks:run:3'), 1)
  check('the retry has a run of its own, so the first logs are never overwritten',
    runIdOf(promptOf(captured, 'checks:run:1')) !== runIdOf(promptOf(captured, 'checks:run:2')), true)
  check('the implementer ran', callCount(captured, 'implementer'), 1)
  check('nothing is red or unmeasured', [result.checks?.red?.length, result.checks?.unmeasured?.length], [0, 0])
}

async function scenarioBaselineHaltsWhenStillUnmeasured() {
  console.log('\n== scenario RF: a baseline still unmeasured after the retry halts before Implement')
  const { result, captured } = await run({
    discovery: ONE,
    checkRuns: (attempt) => ({ output: attempt === 1 ? 'all passed' : '' }),
  })
  check('halted at Implement', result.halted_at, 'Implement')
  check('the implementer never ran', callCount(captured, 'implementer'), 0)
  check('there was one retry and no more', [callCount(captured, 'checks:run:2'), callCount(captured, 'checks:run:3')], [1, 0])
  check('the note says the baseline could not be established',
    (result.note ?? '').includes('baseline could not be established'), true)
  check('the note says nothing was implemented', (result.note ?? '').includes('Nothing was implemented'), true)
  check('the note gives each attempt\'s reason',
    (result.note ?? '').includes('first run no end line; second run no output'), true)
  check('the unmeasured check is named', result.checks?.unmeasured?.map(u => u.id), ['check:1'])
  check('the plan is kept in the halt', typeof result.plan, 'string')
  check('no fixer ran', [callCount(captured, 'checks:fix'), callCount(captured, 'fix:1')], [0, 0])
  check('nothing is red', result.checks?.red?.length, 0)
}

async function scenarioUnmeasuredAfterImplementHalts() {
  console.log('\n== scenario RG: a check unmeasured after Implement is retried once, then halts rather than reaching a fixer')
  const { result, captured } = await run({
    discovery: ONE,
    checkRuns: (attempt, prompt) => attempt === 1
      ? { output: runnerOutput(prompt, [0]) }
      : { output: attempt === 2 ? 'done' : '' },
  })
  check('halted at Implement: measurement, not the code', result.halted_at, 'Implement')
  check('the implementer ran', callCount(captured, 'implementer'), 1)
  check('the retry happened once', [callCount(captured, 'checks:run:3'), callCount(captured, 'checks:run:4')], [1, 0])
  check('no fixer ran', [callCount(captured, 'checks:fix'), callCount(captured, 'fix:1')], [0, 0])
  check('the check is named', result.checks?.unmeasured?.[0]?.id, 'check:1')
  check('both reasons are in the note',
    (result.note ?? '').includes('first run no end line; second run no output'), true)
  check('the note says it is about measurement, not the code', (result.note ?? '').includes('not the code'), true)
}

async function scenarioFixersGetLogPaths() {
  console.log('\n== scenario RH: checks:fix and fix:N get each red check\'s id, command, exit and log path, never its output')
  const { captured } = await run({
    args: { maxReviewRounds: 1 },
    discovery: ONE,
    checkRuns: (attempt, prompt) => ({ output: runnerOutput(prompt, [attempt === 1 ? 0 : 7]) }),
    checksFixResult: { head_sha: 'checksfix00000000000000000000000000000003', note: 'tried', scored: false },
  })
  for (const [label, attempt] of [['checks:fix', 2], ['fix:1', 3]]) {
    const p = promptOf(captured, label)
    const log = runnerLogOf(runIdOf(promptOf(captured, `checks:run:${attempt}`)), 'check:1')
    check(`${label}: names the check, its command and its exit`, p.includes('Check check:1 (make test) exited 7.'), true)
    check(`${label}: carries the log path of the run that saw it red`, p.includes(`Full output: ${log}`), true)
    check(`${label}: says the log sits under the git dir, outside the worktree, and to read from the end`,
      /under the worktree's git directory, outside the worktree/.test(p) && /from the end/.test(p), true)
  }
}

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
const realRun = (dir, fence, extra = {}) => {
  const outs = []
  const scenario = {
    branchResult: { created: true, branch: 'feat/gh-21-stub', base: 'main', path: dir,
      ticket: '21', detail: 'stub', dirty: false },
    discovery: section(fence),
    checkRuns: (attempt, prompt) => { const output = runRunnerLines(prompt); outs.push(output); return { output } },
    ...extra,
  }
  return { outs, scenario }
}
const linesOf = (out) => out.split('\n').filter(Boolean)

async function scenarioRealRunner() {
  console.log('\n== scenario RR: the real lines, run in bash against a scratch repo with a passing and a failing check')
  const dir = scratchRepo()
  try {
    const { outs, scenario } = realRun(dir, 'echo fine\necho boom; exit 3')
    const { result, captured } = await run(scenario)
    const id = runIdOf(promptOf(captured, 'checks:run:1'))
    const [first, second] = outs.map(linesOf)
    const m1 = /^TOUCHSTONE_CHECK check:1 0 (\/.+)$/.exec(first[0] ?? '')
    const m2 = /^TOUCHSTONE_CHECK check:2 3 (\/.+)$/.exec(first[1] ?? '')
    check('the baseline printed a line per check and the end line, nothing else', first.length, 3)
    check('check:1 printed its own exit 0', Boolean(m1), true)
    check('check:2 printed the exit 3 its command chose', Boolean(m2), true)
    check('the end line reads clean: the logs are not in the tree', first[2], `TOUCHSTONE_CHECKS_END ${id} clean`)
    check('check:1\'s log holds its output', fs.readFileSync(m1?.[1] ?? '/nonexistent', 'utf8'), 'fine\n')
    check('check:2\'s log holds its output', fs.readFileSync(m2?.[1] ?? '/nonexistent', 'utf8'), 'boom\n')
    check('the logs sit under the worktree\'s git dir, in this run\'s directory',
      path.dirname(fs.realpathSync(m1?.[1] ?? '/nonexistent')),
      path.join(fs.realpathSync(dir), '.git', 'touchstone-checks', id))
    check('the pipeline parsed it: nothing unmeasured, no halt',
      [result.checks?.unmeasured?.length, result.halted_at], [0, undefined])
    check('check:2 was dropped as environmental at the baseline',
      (result.checks?.detail ?? '').includes('dropped 1 as environmental at the base commit: check:2'), true)
    check('only check:1 ran after Implement',
      [second?.length, second?.[0]?.split(' ').slice(0, 3)], [2, ['TOUCHSTONE_CHECK', 'check:1', '0']])
    check('the fixer never ran for the dropped check', callCount(captured, 'checks:fix'), 0)
  } finally {
    fs.rmSync(dir, { recursive: true, force: true })
  }
}

async function scenarioRealRunnerDirtyTree() {
  console.log('\n== scenario RS: a check that leaves the tree dirty ends the run as dirty, and the status log holds what it wrote')
  const dir = scratchRepo()
  try {
    const { outs, scenario } = realRun(dir, 'echo x > stray.txt')
    const { result, captured } = await run(scenario)
    const id = runIdOf(promptOf(captured, 'checks:run:1'))
    check('the end line reads dirty', linesOf(outs[0]).pop(), `TOUCHSTONE_CHECKS_END ${id} dirty`)
    const statusLog = path.join(path.dirname(/^\S+ \S+ \S+ (\/.+)$/.exec(linesOf(outs[0])[0])[1]), 'status.log')
    check('the status log holds the porcelain', fs.readFileSync(statusLog, 'utf8'), '?? stray.txt\n')
    check('halted before Implement', [result.halted_at, callCount(captured, 'implementer')], ['Implement', 0])
    check('the note names the status log', (result.note ?? '').includes(statusLog), true)
  } finally {
    fs.rmSync(dir, { recursive: true, force: true })
  }
}

const readOrNull = (p) => { try { return fs.readFileSync(p, 'utf8') } catch { return null } }

async function scenarioRealRunnerStatusWarning() {
  console.log('\n== scenario RT: a git status warning on stderr does not make a clean tree read as dirty')
  const dir = scratchRepo()
  const noread = path.join(dir, '.git', 'noread')
  try {
    fs.writeFileSync(noread, '')
    fs.chmodSync(noread, 0o000)
    execFileSync('git', ['-C', dir, 'config', 'core.excludesFile', noread])
    const probe = spawnSync('git', ['-C', dir, 'status', '--porcelain'], { encoding: 'utf8' })
    check('the premise: git status warns on stderr and prints nothing on stdout',
      [probe.stdout, probe.stderr.includes('unable to access')], ['', true])
    const { outs, scenario } = realRun(dir, 'echo fine')
    const { result, captured } = await run(scenario)
    const id = runIdOf(promptOf(captured, 'checks:run:1'))
    const lines = linesOf(outs[0])
    check('the end line reads clean', lines.pop(), `TOUCHSTONE_CHECKS_END ${id} clean`)
    const logDir = path.dirname(/^\S+ \S+ \S+ (\/.+)$/.exec(lines[0])[1])
    check('the status log is empty', readOrNull(path.join(logDir, 'status.log')), '')
    check('the warning is kept in status.err, where a human can read it',
      (readOrNull(path.join(logDir, 'status.err')) ?? '').includes('unable to access'), true)
    check('the baseline did not halt', [result.halted_at, callCount(captured, 'implementer')], [undefined, 1])
  } finally {
    try { fs.chmodSync(noread, 0o600) } catch {}
    fs.rmSync(dir, { recursive: true, force: true })
  }
}

async function scenarioRealRunnerRevParseWarning() {
  console.log('\n== scenario RU: a git warning while resolving the log directory never reaches what the agent sees')
  const dir = scratchRepo()
  const shim = fs.mkdtempSync(path.join(os.tmpdir(), 'touchstone-gitshim-'))
  try {
    const realGit = spawnSync('sh', ['-c', 'command -v git'], { encoding: 'utf8' }).stdout.trim()
    fs.writeFileSync(path.join(shim, 'git'),
      `#!/bin/sh\ncase " $* " in *" rev-parse "*) echo 'warning: shim' >&2;; esac\nexec '${realGit}' "$@"\n`,
      { mode: 0o755 })
    const env = { ...process.env, PATH: `${shim}:${process.env.PATH}` }
    const stderrs = []
    const { scenario } = realRun(dir, 'echo fine', {
      checkRuns: (attempt, prompt) => {
        const lines = /```bash\n([\s\S]*?)\n```/.exec(prompt)[1].split('\n')
        const ran = lines.map(line => spawnSync('bash', ['-c', line], { encoding: 'utf8', env }))
        stderrs.push(ran.map(r => r.stderr).join(''))
        return { output: ran.map(r => r.stdout).join('') }
      },
    })
    const { result, captured } = await run(scenario)
    check('the premise: the shim warns when git rev-parse runs',
      spawnSync('git', ['-C', dir, 'rev-parse', '--git-dir'], { encoding: 'utf8', env }).stderr, 'warning: shim\n')
    check('the lines printed nothing on stderr', stderrs[0], '')
    check('the pipeline measured the run and did not halt',
      [result.checks?.unmeasured?.length, result.halted_at, callCount(captured, 'implementer')], [0, undefined, 1])
  } finally {
    fs.rmSync(shim, { recursive: true, force: true })
    fs.rmSync(dir, { recursive: true, force: true })
  }
}

async function scenarioRealRunnerCwd() {
  console.log('\n== scenario RW: a check runs in the worktree even when its path needs quoting')
  const dir = scratchRepo()
  try {
    const { outs, scenario } = realRun(dir, 'pwd -P')
    await run(scenario)
    const log = /^\S+ \S+ \S+ (\/.+)$/.exec(linesOf(outs[0])[0])?.[1] ?? '/nonexistent'
    check('this path is one a bare word cannot hold', /^[A-Za-z0-9/._+:@%=,-]+$/.test(dir), false)
    check('the check ran in the real worktree directory', fs.readFileSync(log, 'utf8'), `${fs.realpathSync(dir)}\n`)
  } finally {
    fs.rmSync(dir, { recursive: true, force: true })
  }
}

async function scenarioRealRunnerLargeOutput() {
  console.log('\n== scenario RX: a large output stays in its log and never reaches what the runner prints')
  const dir = scratchRepo()
  try {
    const { outs, scenario } = realRun(dir, "head -c 20000 /dev/zero | tr '\\0' x; exit 4")
    const { result } = await run(scenario)
    const lines = linesOf(outs[0])
    check('the runner printed one check line and the end line', lines.length, 2)
    check('the exit is the check\'s own', lines[0].split(' ').slice(0, 3), ['TOUCHSTONE_CHECK', 'check:1', '4'])
    check('the log holds all of the output',
      fs.statSync(/^\S+ \S+ \S+ (\/.+)$/.exec(lines[0])[1]).size, 20000)
    check('exit 4 is red, so the baseline dropped it', (result.checks?.detail ?? '').includes('dropped 1 as environmental'), true)
  } finally {
    fs.rmSync(dir, { recursive: true, force: true })
  }
}

async function scenarioRealRunnerNoclobber() {
  console.log('\n== scenario RV: a shell with noclobber set, writing over an existing run directory, still measures')
  const dir = scratchRepo()
  try {
    const { scenario } = realRun(dir, 'echo fine')
    scenario.checkRuns = (attempt, prompt) => {
      const fence = /```bash\n([\s\S]*?)\n```/.exec(prompt)
      const lines = fence ? fence[1].split('\n') : []
      const once = () => lines.map(line => spawnSync('bash', ['-c', `set -o noclobber; ${line}`], { encoding: 'utf8' }).stdout).join('')
      once()
      return { output: once() }
    }
    const { result } = await run(scenario)
    check('nothing is unmeasured', result.checks?.unmeasured?.length, 0)
    check('the passing check is not red', result.checks?.red?.length, 0)
  } finally {
    fs.rmSync(dir, { recursive: true, force: true })
  }
}

const SCENARIOS = [scenarioPromptIsOneLinePerCheck, scenarioParserMeasures, scenarioParserTolerance,
  scenarioParserRejects, scenarioNullReplyIsUnmeasured, scenarioBaselineRetriesOnce,
  scenarioBaselineHaltsWhenStillUnmeasured, scenarioUnmeasuredAfterImplementHalts,
  scenarioFixersGetLogPaths, scenarioRealRunner, scenarioRealRunnerDirtyTree, scenarioRealRunnerNoclobber,
  scenarioRealRunnerStatusWarning, scenarioRealRunnerRevParseWarning, scenarioRealRunnerCwd,
  scenarioRealRunnerLargeOutput]
JS_EOF

finish
