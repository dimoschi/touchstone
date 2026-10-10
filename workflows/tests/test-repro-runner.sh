#!/usr/bin/env bash
# gh-163: reproducers are run by script-built lines, never by a model copying
# commands, exit codes or output. Covers the prompt, the strict parse of what
# the runner printed, the shell's marker flag, the log path a fixer gets, and
# the real lines run in bash against a scratch repo; see harness.sh.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/harness.sh"

run_js_scenarios <<'JS_EOF'
const promptOf = (captured, label) => captured.calls.find(c => c.label === label)?.prompt ?? ''
const fenceOf = (prompt) => /```bash\n([\s\S]*?)\n```/.exec(prompt)?.[1].split('\n') ?? []
const finding = (title, command, over = {}) => ({ title, file: `${title}.js`, claim: 'c', evidence: 'e',
  reproducer: { kind: 'command', command, expected: 'exit 0', actual: 'exit 1' }, ...over })
const reviewOf = (...findings) => ({ correctness: findings, advocate: [] })
const MARKER_GREP = `grep -aqxE '[[:space:]]*TOUCHSTONE_DEFECT_REPRODUCED[[:space:]]*'`

async function scenarioPromptIsOneLinePerReproducer() {
  console.log('\n== scenario PA: reproduce:review carries a before line, one self-contained line per reproducer, an end line, and asks for output only')
  const { captured } = await run({
    initialReview: reviewOf(finding('one', 'make test'), finding('two', "bash t.sh 'a b'")),
  })
  const call = captured.calls.find(c => c.label === 'reproduce:review')
  const p = call?.prompt ?? ''
  const rid = reproRunOf(p)
  check('the run is the plan id, the label and a counter', /^[0-9a-f]{8}-reproduce-review-\d+$/.test(rid), true)
  const dir = `d="$(git -C /tmp/stub-worktree rev-parse --path-format=absolute --git-path touchstone-repro/${rid} 2>/dev/null)" && mkdir -p "$d"`
  const lineFor = (id, cmd) =>
    `${dir} && c="$(printf %s ${Buffer.from(cmd).toString('base64')} | base64 --decode)" && [ -n "$c" ] && ` +
    `{ (cd /tmp/stub-worktree && bash -c "$c") >|"$d/${id}.log" 2>&1; e=$?; ` +
    `if ${MARKER_GREP} "$d/${id}.log"; then m=1; else m=0; fi; ` +
    `r="$(printf 'TOUCHSTONE_REPRO %s %s %s %s' ${id} "$e" "$m" "$d/${id}.log")"; ` +
    `printf '%s\\n' "$r" >>"$d/rows"; printf '%s\\n' "$r"; }`
  const before = `${dir} && : >|"$d/rows" && git -C /tmp/stub-worktree status --porcelain >|"$d/before.log" 2>|"$d/before.err" && ` +
    `{ if [ -s "$d/before.log" ]; then s=dirty; else s=clean; fi; ` +
    `printf 'TOUCHSTONE_REPRO_BEFORE %s %s\\n' ${rid} "$s"; }`
  const end = `${dir} && git -C /tmp/stub-worktree status --porcelain >|"$d/status.log" 2>|"$d/status.err" && ` +
    `k="$(cksum < "$d/rows")" && { if [ -s "$d/status.log" ]; then s=dirty; else s=clean; fi; ` +
    `printf 'TOUCHSTONE_REPRO_END %s %s %s %s\\n' ${rid} "$s" "$k" "$d/status.log"; }`
  check('the fence is the before line, a line per reproducer, then the end line',
    fenceOf(p), [before, lineFor('f1', 'make test'), lineFor('f2', "bash t.sh 'a b'"), end])
  check('the schema asks for output and nothing else', JSON.stringify(call?.schema),
    JSON.stringify({ type: 'object', additionalProperties: false, required: ['output'],
      properties: { output: { type: 'string' } } }))
  check('it is a haiku call at low effort', [call?.model, call?.effort], ['haiku', 'low'])
  check('it demands one line at a time, in order', /one at a time, in the order given/.test(p), true)
  check('it forbids fixing', /Do not fix, edit, or investigate a failure/.test(p), true)
  check('it asks for the printed lines verbatim', /every line the calls printed, copied verbatim/.test(p), true)
  check('it never asks for an exit code or a command\'s output',
    ['exit_code', 'combined stdout', 'porcelain_before', 'diff_lines'].some(s => p.includes(s)), false)
}

async function scenarioPromptWithRange() {
  console.log('\n== scenario PB: a call given a diff range adds one line that prints the kept hunk lines between markers, counted by the shell')
  const { captured } = await run({
    args: { maxReviewRounds: 1 },
    initialReview: reviewOf(finding('one', 'make test')),
    fixHead: () => 'fix00000000000000000000000000000000000001',
    staleness: () => [],
  })
  const p = promptOf(captured, 'reproduce:fix:1')
  const rid = reproRunOf(p)
  const fence = fenceOf(p)
  check('before, the reproducer, the hunks line, then the end line', fence.length, 4)
  check('the hunks line', fence[2],
    `d="$(git -C /tmp/stub-worktree rev-parse --path-format=absolute --git-path touchstone-repro/${rid} 2>/dev/null)" && mkdir -p "$d" && ` +
    `{ git -C /tmp/stub-worktree diff --unified=0 --no-color ${REVIEWED_THROUGH}..fix00000000000000000000000000000000000001 ` +
    `>|"$d/diff.log" 2>|"$d/diff.err"; g=$?; ` +
    `if [ "$g" -ne 0 ]; then printf 'TOUCHSTONE_HUNKS_FAILED %s %s\\n' ${rid} "$g"; ` +
    `else grep -aE '^(\\+\\+\\+ |@@ )' "$d/diff.log" >|"$d/hunks.log"; ` +
    `printf 'TOUCHSTONE_HUNKS_BEGIN %s\\n' ${rid}; cat "$d/hunks.log"; ` +
    `printf 'TOUCHSTONE_HUNKS_END %s %s\\n' ${rid} "$(grep -c '' "$d/hunks.log")"; fi; }`)
  check('each call has a run of its own',
    reproRunOf(promptOf(captured, 'reproduce:review')) !== rid, true)
}

async function scenarioOutcomesFromTheShell() {
  console.log('\n== scenario PC: exit 0 passes, 127 could not run, nonzero with the marker flag reproduces, without it errors')
  const { result } = await run({
    args: { maxReviewRounds: 1 },
    initialReview: reviewOf(finding('ok', 'a'), finding('norun', 'b'), finding('repro', 'c'), finding('crash', 'd')),
    reproRuns: (label, prompt) => label === 'reproduce:review' ? { output: reproOutput(prompt, [
      { id: 'f1', exit: 0, output: REPRODUCED_MARKER },
      { id: 'f2', exit: 127, output: '' },
      { id: 'f3', exit: 1, output: REPRODUCED_MARKER },
      { id: 'f4', exit: 1, output: 'Traceback' },
    ]) } : undefined,
    verify: () => false,
    staleness: () => [],
  })
  const note = (t) => result.notes?.find(n => n.title === t)
  check('exit 0 is a did-not-reproduce note, marker or not', note('ok')?.reason, 'did-not-reproduce')
  check('127 is a could-not-run note', note('norun')?.reason, 'reproducer-could-not-run')
  check('nonzero with the marker opens', result.unresolved_findings?.map(f => f.title), ['repro'])
  check('nonzero without it is a reproducer-errored note', note('crash')?.reason, 'reproducer-errored')
  const rr = note('crash')?.reproducer_run
  check('the note keeps the exit code and the log path, not output',
    [rr?.exit_code, (rr?.log ?? "").endsWith("/f4.log") && (rr?.log ?? "").includes("/touchstone-repro/"), "output" in (rr ?? {})],
    [1, true, false])
  check('the log holds what the reproducer printed', fs.readFileSync(rr?.log ?? '/nonexistent', 'utf8'), 'Traceback')
}

async function scenarioTolerance() {
  console.log('\n== scenario PD: CRLF, blank lines and trailing spaces do not make a well-formed reply unmeasured')
  const { result } = await run({
    initialReview: reviewOf(finding('repro', 'c')),
    reproRuns: (label, prompt) => label === 'reproduce:review' ? { output: '\r\n' +
      reproOutput(prompt, [{ id: 'f1', exit: 1, output: REPRODUCED_MARKER }])
        .split('\n').map(l => `${l}  `).join('\r\n\r\n') + '\r\n' } : undefined,
    args: { maxReviewRounds: 1 },
    verify: () => false,
    staleness: () => [],
  })
  check('measured: it opened', result.unresolved_findings?.map(f => f.title), ['repro'])
}

const REJECTED = [
  ['no output at all', () => '', 'no output'],
  ['a summary instead of the lines', () => 'Both reproducers failed as expected.', 'no before line'],
  ['the before line not first', (l) => [l[1], l[0], ...l.slice(2)].join('\n'), 'no before line'],
  ['a malformed before line', (l) => ['TOUCHSTONE_REPRO_BEFORE', ...l.slice(1)].join('\n'), 'malformed before line'],
  ['a before line naming another run', (l) => [l[0].replace(/ \S+ clean$/, ' other-run clean'), ...l.slice(1)].join('\n'),
    'before line names run other-run, not '],
  ['no end line', (l) => l.slice(0, -1).join('\n'), 'no end line'],
  ['an end line that is not last', (l) => [l[0], l[3], l[1], l[2]].join('\n'), 'end line is not last'],
  ['two end lines', (l) => [...l, l[3]].join('\n'), 'end line repeated'],
  ['a malformed end line', (l) => [...l.slice(0, 3), 'TOUCHSTONE_REPRO_END'].join('\n'), 'malformed end line'],
  ['an end line naming another run', (l) => [...l.slice(0, 3), l[3].replace(/^(\S+) \S+/, '$1 other-run')].join('\n'),
    'end line names run other-run, not '],
  ['a status log outside the run directory', (l) => [...l.slice(0, 3), l[3].replace(/ \/\S+$/, ' /elsewhere/status.log')].join('\n'),
    'status log is not in the run directory'],
  ['a reproducer with no line', (l) => [l[0], l[1], l[3]].join('\n'), 'no line for f2'],
  ['a reproducer reported twice', (l) => [l[0], l[1], l[1], l[2], l[3]].join('\n'), 'f1 reported twice'],
  ['an id nobody asked for', (l) => [l[0], l[1], l[2], l[2].replace(/f2/g, 'f9'), l[3]].join('\n'), 'unexpected id f9'],
  ['the reproducers out of order', (l) => [l[0], l[2], l[1], l[3]].join('\n'), 'f2 reported where f1 was expected'],
  ['a line of prose', (l) => [l[0], 'Ran both.', l[1], l[2], l[3]].join('\n'), 'unexpected line "Ran both."'],
  ['a malformed reproducer line', (l) => [l[0], 'TOUCHSTONE_REPRO f1 1', l[2], l[3]].join('\n'), 'malformed reproducer line'],
  ['an exit that is not an integer', (l) => [l[0], l[1].replace(/^(\S+ \S+) 1 /, '$1 one '), l[2], l[3]].join('\n'),
    'exit of f1 is not an integer'],
  ['a marker flag that is not 0 or 1', (l) => [l[0], l[1].replace(/^(\S+ \S+ \S+) 1 /, '$1 yes '), l[2], l[3]].join('\n'),
    'marker of f1 is not 0 or 1'],
  ['a log path of another run', (l) => [l[0], l[1].replace(/\/touchstone-repro\/[^/]+\//, '/touchstone-repro/other-run/'), l[2], l[3]].join('\n'),
    'log path of f1 is not under this run'],
  ['a log path of another reproducer', (l) => [l[0], l[1].replace('f1.log', 'f2.log'), l[2], l[3]].join('\n'),
    'log path of f1 is not under this run'],
  ['a relative log path', (l) => [l[0], l[1].replace(/ \/\S*touchstone-repro/, ' touchstone-repro'), l[2], l[3]].join('\n'),
    'log path of f1 is not under this run'],
  ['a log in another directory than the other rows', (l) => [l[0], l[1].replace(/ \/\S*\/touchstone-repro\//, ' /elsewhere/touchstone-repro/'), l[2], l[3]].join('\n'),
    'log path of f1 is not in the run directory'],
  ['a hunks block nobody asked for', (l) => [l[0], l[1], l[2], 'TOUCHSTONE_HUNKS_BEGIN x', l[3]].join('\n'),
    'unexpected line "TOUCHSTONE_HUNKS_BEGIN x"'],
]

async function scenarioRejects() {
  console.log('\n== scenario PE: any deviation makes the whole run unmeasured, read exactly as a run that returned nothing')
  for (const [what, build, want] of REJECTED) {
    const { result, captured } = await run({
      initialReview: reviewOf(finding('one', 'a'), finding('two', 'b')),
      reproRuns: (label, prompt) => ({ output: build(reproOutput(prompt, [
        { id: 'f1', exit: 1, output: REPRODUCED_MARKER }, { id: 'f2', exit: 1, output: REPRODUCED_MARKER },
      ]).split('\n')) }),
    })
    check(`${what}: both candidates stay unmeasured and the run halts at Review`,
      [result.halted_at, result.unresolved_findings?.map(f => f.reproducer_run?.outcome)],
      ['Review', ['not-executed', 'not-executed']])
    check(`${what}: the retry ran once`, callCount(captured, 'reproduce:review:retry'), 1)
    check(`${what}: the reason is logged`,
      captured.logs.some(l => l.startsWith('reproduce:review: unmeasured (' + want)), true)
  }
}

async function scenarioNullIsUnmeasured() {
  console.log('\n== scenario PF: a runner that returned nothing is unmeasured, the same as before')
  const { result, captured } = await run({
    initialReview: reviewOf(finding('one', 'a')),
    reproRuns: () => null,
  })
  check('halted at Review on measurement', [result.halted_at, (result.note ?? '').includes('about measurement')], ['Review', true])
  check('the reason is logged', captured.logs.includes('reproduce:review: unmeasured (no output)'), true)
}

const HUNK_REJECTED = [
  ['no hunks block', (l) => [l[0], l[1], l[5]].join('\n'), 'no hunks block'],
  ['a malformed failed line', (l) => [l[0], l[1], 'TOUCHSTONE_HUNKS_FAILED x', l[5]].join('\n'),
    'malformed hunks failed line'],
  ['a failed line naming another run', (l) => [l[0], l[1], 'TOUCHSTONE_HUNKS_FAILED other-run 128', l[5]].join('\n'),
    'hunks failed line names run other-run, not '],
  ['a failed line beside a block', (l) => [l[0], l[1], l[2].replace('BEGIN', 'FAILED') + ' 128', ...l.slice(2)].join('\n'),
    'unexpected line "TOUCHSTONE_HUNKS_BEGIN'],
  ['a malformed begin line', (l) => [l[0], l[1], 'TOUCHSTONE_HUNKS_BEGIN', l[3], l[4], l[5]].join('\n'),
    'malformed hunks begin line'],
  ['a begin line naming another run', (l) => [l[0], l[1], 'TOUCHSTONE_HUNKS_BEGIN other-run', l[3], l[4], l[5]].join('\n'),
    'hunks block names run other-run, not '],
  ['no hunks end line', (l) => [l[0], l[1], l[2], l[3], l[5]].join('\n'), 'no hunks end line'],
  ['a count that does not match', (l) => [l[0], l[1], l[2], l[3], l[4].replace(/ 1$/, ' 2'), l[5]].join('\n'),
    'hunks count 2 does not match 1 line(s)'],
  ['a malformed end line', (l) => [l[0], l[1], l[2], l[3], l[4].replace(/ 1$/, ' one'), l[5]].join('\n'),
    'malformed hunks end line'],
  ['a line that is not a hunk header', (l) => [l[0], l[1], l[2], ' context', l[4], l[5]].join('\n'),
    'unexpected hunk line " context"'],
]

async function scenarioHunksRejected() {
  console.log('\n== scenario PG: a bad hunks block makes the run unmeasured: nothing settles and hunks are unknown, not empty')
  for (const [what, build, want] of HUNK_REJECTED) {
    const { result, captured } = await run({
      args: { maxReviewRounds: 1 },
      initialReview: reviewOf(finding('one', 'a')),
      fixHead: () => 'fix00000000000000000000000000000000000001',
      reproRuns: (label, prompt) => label === 'reproduce:fix:1' ? { output: build(reproOutput(prompt,
        [{ id: 'f1', exit: 0, output: '' }], { hunkLines: ['@@ -1 +1 @@'] }).split('\n')) } : undefined,
      tailReview: [finding('fresh', 'x', { file: 'x.js', line_start: 500 })],
      staleness: () => [],
    })
    check(`${what}: the reason is logged`,
      captured.logs.some(l => l.startsWith('reproduce:fix:1: unmeasured (' + want)), true)
    check(`${what}: the open finding did not settle on an exit nobody can trust`,
      result.unresolved_findings?.some(f => f.title === 'one'), true)
    check(`${what}: the fresh finding is not dismissed as out of range`,
      result.unresolved_findings?.some(f => f.title === 'fresh'), true)
  }
}

async function scenarioHunksFailed() {
  console.log('\n== scenario PI: a failed diff keeps the rows and leaves hunks unknown, not empty')
  const { result, captured } = await run({
    args: { maxReviewRounds: 1 },
    initialReview: reviewOf(finding('one', 'a')),
    fixHead: () => 'fix00000000000000000000000000000000000001',
    reproRuns: (label, prompt) => label === 'reproduce:fix:1' ? { output: reproOutput(prompt,
      [{ id: 'f1', exit: 0, output: '' }], { hunkLines: [] }).replace(/TOUCHSTONE_HUNKS_BEGIN (\S+)\nTOUCHSTONE_HUNKS_END \S+ 0/,
      'TOUCHSTONE_HUNKS_FAILED $1 128') } : undefined,
    tailReview: [finding('fresh', 'x', { file: 'x.js', line_start: 500 })],
    staleness: () => [],
  })
  check('the failure is logged with git\'s exit',
    captured.logs.includes('reproduce:fix:1: git diff exited 128, so this range\'s hunks are unknown'), true)
  check('the call was not unmeasured', captured.logs.some(l => l.startsWith('reproduce:fix:1: unmeasured')), false)
  check('the row counted: the open finding settled', result.unresolved_findings?.some(f => f.title === 'one'), false)
  check('the fresh finding is not dismissed as out of range',
    result.unresolved_findings?.some(f => f.title === 'fresh'), true)
}

async function scenarioFixerGetsLogPath() {
  console.log('\n== scenario PH: an errored open finding reaches the next fixer as its exit and log path, never its output')
  let phase = 'initial'
  const { captured } = await run({
    args: { maxReviewRounds: 2 },
    initialReview: reviewOf(finding('one', 'a')),
    initialExit: () => { phase = 'initial'; return 1 },
    verify: () => { phase = 'fix'; return 1 },
    outputFor: () => phase === 'fix' ? 'SECRET_CRASH_TEXT' : REPRODUCED_MARKER,
    fixHead: (round) => `fix000000000000000000000000000000000000${String(round).padStart(2, '0')}`,
    staleness: () => [],
  })
  const p = promptOf(captured, 'fix:2')
  const rid = reproRunOf(promptOf(captured, 'reproduce:fix:1'))
  const log = `${reproDirOf(rid)}/f1.log`
  check('the brief says the reproducer itself failed, with its exit', p.includes('failed to run last round: exit 1'), true)
  check('the brief carries the log path', p.includes(log), true)
  check('the brief says to read it from the end', /Read it from the end/.test(p), true)
  check('the brief never carries the output', p.includes('SECRET_CRASH_TEXT'), false)
}

const scratchRepo = () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "touchstone o'clock -"))
  const env = { ...process.env, GIT_AUTHOR_NAME: 'test', GIT_AUTHOR_EMAIL: 't@t',
    GIT_COMMITTER_NAME: 'test', GIT_COMMITTER_EMAIL: 't@t' }
  const git = (...a) => execFileSync('git', ['-C', dir, ...a], { env, encoding: 'utf8' }).trim()
  execFileSync('git', ['init', '-q', dir])
  const commit = (file, text) => {
    fs.writeFileSync(path.join(dir, file), text)
    git('add', '-A')
    git('-c', 'commit.gpgsign=false', '-c', 'gpg.format=openpgp', 'commit', '-q', '-m', file)
    return git('rev-parse', 'HEAD')
  }
  commit('a.txt', 'a\n')
  return { dir, commit }
}
const realOutputs = (labels) => {
  const outs = {}
  return { outs, reproRuns: (label, prompt) => {
    if (!labels.includes(label)) return undefined
    const output = runRunnerLines(prompt)
    outs[label] = output
    return { output }
  } }
}
const branchAt = (dir) => ({ created: true, branch: 'feat/gh-21-stub', base: 'main', path: dir,
  ticket: '21', detail: 'stub', dirty: false })

async function scenarioRealOutcomes() {
  console.log('\n== scenario PR: the real lines, run in bash, decide exit and marker for each reproducer')
  const { dir } = scratchRepo()
  try {
    const { outs, reproRuns } = realOutputs(['reproduce:review'])
    const { result } = await run({
      args: { maxReviewRounds: 1 },
      branchResult: branchAt(dir),
      initialReview: reviewOf(
        finding('marker', `echo noise; echo ${REPRODUCED_MARKER}; exit 1`),
        finding('nomarker', 'echo boom >&2; exit 1'),
        finding('passes', 'pwd -P'),
        finding('padded', `printf '  ${REPRODUCED_MARKER} \\r\\n'; exit 2`),
        finding('substring', `echo "+ echo ${REPRODUCED_MARKER}"; echo "${REPRODUCED_MARKER}x"; exit 1`),
      ),
      reproRuns, verify: () => false, staleness: () => [],
    })
    const lines = outs['reproduce:review'].split('\n').filter(Boolean)
    check('the runner printed a before line, five rows and an end line', lines.length, 7)
    check('the tree was clean before and after',
      [lines[0].split(' ')[2], lines[6].split(' ')[2]], ['clean', 'clean'])
    const row = (id) => lines.find(l => l.startsWith(`TOUCHSTONE_REPRO ${id} `))?.split(' ') ?? []
    check('the marker row: exit 1, marker 1', row('f1').slice(2, 4), ['1', '1'])
    check('the crash row: exit 1, marker 0', row('f2').slice(2, 4), ['1', '0'])
    check('the passing row: exit 0', row('f3')[2], '0')
    check('a marker with surrounding spaces and CRLF counts', row('f4').slice(2, 4), ['2', '1'])
    check('a marker inside a longer line does not', row('f5').slice(2, 4), ['1', '0'])
    check('the passing reproducer ran in the worktree, its output in the log',
      fs.readFileSync(row('f3').slice(4).join(' '), 'utf8'), `${fs.realpathSync(dir)}\n`)
    check('the crash log holds its stderr', fs.readFileSync(row('f2').slice(4).join(' '), 'utf8'), 'boom\n')
    check('the logs sit under the worktree\'s git dir',
      path.dirname(fs.realpathSync(row('f1').slice(4).join(' '))).startsWith(path.join(fs.realpathSync(dir), '.git', 'touchstone-repro')), true)
    const reason = (t) => result.notes?.find(n => n.title === t)?.reason
    check('marker and padded marker open', result.unresolved_findings?.map(f => f.title).sort(), ['marker', 'padded'])
    check('no marker is errored, a substring is errored, exit 0 passed',
      [reason('nomarker'), reason('substring'), reason('passes')],
      ['reproducer-errored', 'reproducer-errored', 'did-not-reproduce'])
  } finally {
    fs.rmSync(dir, { recursive: true, force: true })
  }
}

async function scenarioRealDirty() {
  console.log('\n== scenario PS: a reproducer that writes to the tree ends the run dirty, and the halt names the status log')
  const { dir } = scratchRepo()
  try {
    const { outs, reproRuns } = realOutputs(['reproduce:review'])
    const { result } = await run({
      branchResult: branchAt(dir),
      initialReview: reviewOf(finding('writes', `echo x > stray.txt; echo ${REPRODUCED_MARKER}; exit 1`)),
      reproRuns,
    })
    const lines = outs['reproduce:review'].split('\n').filter(Boolean)
    const end = lines.pop().split(' ')
    check('before clean, end dirty', [lines[0].split(' ')[2], end[2]], ['clean', 'dirty'])
    check('the status log holds the porcelain', fs.readFileSync(end.slice(5).join(' '), 'utf8'), '?? stray.txt\n')
    check('halted at Review', result.halted_at, 'Review')
    check('the note blames a reproducer and names the status log',
      (result.note ?? '').includes('A reproducer execution left the working tree dirty') &&
      (result.note ?? '').includes(end.slice(5).join(' ')), true)
  } finally {
    fs.rmSync(dir, { recursive: true, force: true })
  }
}

async function scenarioRealDirtyBefore() {
  console.log('\n== scenario PT: a tree already dirty before any reproducer ran is not blamed on one')
  const { dir } = scratchRepo()
  try {
    fs.writeFileSync(path.join(dir, 'left-over.txt'), 'x')
    const { outs, reproRuns } = realOutputs(['reproduce:review'])
    const { result } = await run({
      branchResult: branchAt(dir),
      initialReview: reviewOf(finding('clean', `echo ${REPRODUCED_MARKER}; exit 1`)),
      reproRuns,
    })
    const lines = outs['reproduce:review'].split('\n').filter(Boolean)
    check('before dirty', lines[0].split(' ')[2], 'dirty')
    check('the note says it was already dirty',
      [result.halted_at, (result.note ?? '').includes('already dirty before this check ran')], ['Review', true])
  } finally {
    fs.rmSync(dir, { recursive: true, force: true })
  }
}

async function scenarioRealHunks() {
  console.log('\n== scenario PU: a real diff range prints its hunk headers, and classify() reads them')
  const { dir, commit } = scratchRepo()
  try {
    const base = commit('impl.txt', 'one\ntwo\n')
    const implHead = commit('impl2.txt', 'x\n')
    const { outs, reproRuns } = realOutputs(['reproduce:review', 'reproduce:fix:1', 'reproduce:fix:1:fresh'])
    const { result } = await run({
      args: { maxReviewRounds: 1 },
      branchResult: branchAt(dir),
      implRange: `${base}..${implHead}`,
      initialReview: reviewOf(finding('needs fix', `test -f fixed.txt || { echo ${REPRODUCED_MARKER}; exit 1; }`)),
      fixHead: () => commit('fixed.txt', 'fixed\n'),
      tailReview: [
        finding('in range', 'true', { file: 'fixed.txt', line_start: 1 }),
        finding('out of range', 'true', { file: 'impl.txt', line_start: 1 }),
      ],
      reproRuns, staleness: () => [],
    })
    const lines = outs['reproduce:fix:1'].split('\n').filter(Boolean)
    const rid = lines[0].split(' ')[1]
    check('the hunks block holds the fix commit\'s header lines, counted',
      lines.slice(2, 6), [`TOUCHSTONE_HUNKS_BEGIN ${rid}`, '+++ b/fixed.txt', '@@ -0,0 +1 @@', `TOUCHSTONE_HUNKS_END ${rid} 2`])
    check('the open finding settled: its reproducer exits 0 after the fix', lines[1].split(' ').slice(1, 3), ['f1', '0'])
    check('a fresh finding on a touched line was executed', typeof outs['reproduce:fix:1:fresh'], 'string')
    const reason = (t) => result.notes?.find(n => n.title === t)?.reason
    check('in range: executed, passed', reason('in range'), 'did-not-reproduce')
    check('out of range: a note, never executed', reason('out of range'), 'out-of-range')
    check('nothing is open', result.unresolved_findings?.length ?? 0, 0)
  } finally {
    fs.rmSync(dir, { recursive: true, force: true })
  }
}

async function scenarioRealBadRange() {
  console.log('\n== scenario PV: a real range naming a nonexistent SHA prints a failed line; the rows still count and hunks are unknown')
  const { dir, commit } = scratchRepo()
  try {
    const base = commit('impl.txt', 'one\n')
    const implHead = commit('impl2.txt', 'x\n')
    const { outs, reproRuns } = realOutputs(['reproduce:review', 'reproduce:fix:1', 'reproduce:fix:1:fresh'])
    const { result, captured } = await run({
      args: { maxReviewRounds: 1 },
      branchResult: branchAt(dir),
      implRange: `${base}..${implHead}`,
      initialReview: reviewOf(finding('needs fix', `test -f fixed.txt || { echo ${REPRODUCED_MARKER}; exit 1; }`)),
      fixHead: () => { commit('fixed.txt', 'fixed\n'); return 'f'.repeat(40) },
      tailReview: [finding('fresh', `echo ${REPRODUCED_MARKER}; exit 1`, { file: 'elsewhere.txt', line_start: 9 })],
      reproRuns, staleness: () => [],
    })
    const lines = outs['reproduce:fix:1'].split('\n').filter(Boolean)
    const rid = lines[0].split(' ')[1]
    check('the row is measured: exit 0 after the fix', lines[1].split(' ').slice(1, 3), ['f1', '0'])
    check('the hunks line printed git\'s failure, decided by the shell', lines[2], `TOUCHSTONE_HUNKS_FAILED ${rid} 128`)
    check('then the end line', lines[3].split(' ').slice(0, 3), ['TOUCHSTONE_REPRO_END', rid, 'clean'])
    check('the call was not unmeasured', captured.logs.some(l => l.startsWith('reproduce:fix:1: unmeasured')), false)
    check('the open finding settled on its measured row', result.unresolved_findings?.some(f => f.title === 'needs fix'), false)
    check('hunks unknown: a fresh finding outside any hunk still opens',
      result.unresolved_findings?.map(f => f.title), ['fresh'])
  } finally {
    fs.rmSync(dir, { recursive: true, force: true })
  }
}

// The script's pure helpers, lifted out of its source and run on their own:
// each definition runs from its `const` to the next top-level statement.
const defsOf = (names) => names.map(n => {
  const start = src.search(new RegExp(`^const ${n} =`, 'm'))
  const rest = src.slice(start)
  return rest.slice(0, rest.slice(1).search(/^(const |let |function |\/\/)/m) + 1)
}).join('\n')
const pure = vm.runInNewContext(
  `${defsOf(['utf8Bytes', 'CKSUM_TABLE', 'cksum', 'BASE64_ALPHABET', 'base64Of'])}\n;({ cksum, base64Of })`)
const CKSUM_INPUTS = ['', 'abc\n', 'TOUCHSTONE_CHECK check:1 0 /tmp/x/check:1.log\n',
  'Grüße — 日本語 🎉\n', 'x'.repeat(300), 'y'.repeat(70000)]

async function scenarioCksumMatchesPosix() {
  console.log('\n== scenario PX: the script\'s cksum matches the real cksum, non-ASCII and long input included')
  for (const input of CKSUM_INPUTS) {
    const real = execFileSync('cksum', { input: Buffer.from(input, 'utf8'), encoding: 'utf8' }).trim().split(/\s+/).join(' ')
    check(`cksum of ${JSON.stringify(input.slice(0, 20))} (${input.length} chars)`, pure.cksum(input), real)
  }
}

async function scenarioBase64MatchesUtf8() {
  console.log('\n== scenario PY: the script\'s base64 encodes the UTF-8 bytes, and base64 --decode gives the text back')
  for (const input of ['', 'a', 'ab', 'abc', "python3 -c 'print(1)'\nexit 3", 'Grüße — 日本語 🎉']) {
    const b64 = pure.base64Of(input)
    check(`base64 of ${JSON.stringify(input)}`, b64, Buffer.from(input, 'utf8').toString('base64'))
    check(`it decodes back with base64 --decode`,
      spawnSync('bash', ['-c', `printf %s ${b64} | base64 --decode`], { encoding: 'utf8' }).stdout, input)
  }
}

async function scenarioRealMultiLine() {
  console.log('\n== scenario PW: multi-line commands stay one physical fence line each, and run whole in the worktree')
  const { dir } = scratchRepo()
  try {
    const { outs, reproRuns } = realOutputs(['reproduce:review'])
    const { result, captured } = await run({
      args: { maxReviewRounds: 1 },
      branchResult: branchAt(dir),
      initialReview: reviewOf(
        finding('python', `python3 -c 'import os, sys\nprint(os.getcwd())\nprint("${REPRODUCED_MARKER}")\nsys.exit(3)'`),
        finding('heredoc', `bash <<'EOS'\npwd -P\necho "${REPRODUCED_MARKER}"\nexit 4\nEOS`),
      ),
      reproRuns, verify: () => false, staleness: () => [],
    })
    check('the fence has exactly the before line, two reproducer lines and the end line',
      fenceOf(promptOf(captured, 'reproduce:review')).length, 4)
    const lines = outs['reproduce:review'].split('\n').filter(Boolean)
    check('the runner printed exactly four lines', lines.length, 4)
    const row = (id) => lines.find(l => l.startsWith(`TOUCHSTONE_REPRO ${id} `))?.split(' ') ?? []
    const real = fs.realpathSync(dir)
    check('the python row: its own exit, marker seen', row('f1').slice(2, 4), ['3', '1'])
    check('the python command ran in the worktree', fs.readFileSync(row('f1').slice(4).join(' '), 'utf8'),
      `${real}\n${REPRODUCED_MARKER}\n`)
    check('the heredoc row: its own exit, marker seen', row('f2').slice(2, 4), ['4', '1'])
    check('the heredoc ran in the worktree', fs.readFileSync(row('f2').slice(4).join(' '), 'utf8'),
      `${real}\n${REPRODUCED_MARKER}\n`)
    check('both opened', result.unresolved_findings?.map(f => f.title).sort(), ['heredoc', 'python'])
  } finally {
    fs.rmSync(dir, { recursive: true, force: true })
  }
}

async function scenarioRealInventedRow() {
  console.log('\n== scenario PZ: a reply with a row the runner never wrote is unmeasured, even when it looks right')
  const { dir } = scratchRepo()
  try {
    const { result, captured } = await run({
      branchResult: branchAt(dir),
      initialReview: reviewOf(finding('one', `echo ${REPRODUCED_MARKER}; exit 1`), finding('two', 'exit 0')),
      reproRuns: (label, prompt) => {
        const fence = fenceOf(prompt)
        const ran = [fence[0], fence[1], fence[3]].map(line => spawnSync('bash', ['-c', line], { encoding: 'utf8' }).stdout)
        const f1 = ran[1].trim()
        const invented = f1.replace(' f1 1 1 ', ' f2 0 0 ').replace(/f1\.log$/, 'f2.log')
        return { output: [ran[0].trim(), f1, invented, ran[2].trim()].join('\n') }
      },
    })
    check('the run is unmeasured on the checksum',
      captured.logs.some(l => l.startsWith('reproduce:review: unmeasured (rows checksum does not match')), true)
    check('halted on measurement, nothing decided', [result.halted_at,
      result.unresolved_findings?.map(f => f.reproducer_run?.outcome)], ['Review', ['not-executed', 'not-executed']])
  } finally {
    fs.rmSync(dir, { recursive: true, force: true })
  }
}

async function scenarioRealGenuineRunPassesChecksum() {
  console.log('\n== scenario PQ: a genuine run, re-run in the same directory, still passes the checksum')
  const { dir } = scratchRepo()
  try {
    const { result, captured } = await run({
      branchResult: branchAt(dir),
      initialReview: reviewOf(finding('one', 'exit 0')),
      reproRuns: (label, prompt) => { runRunnerLines(prompt); return { output: runRunnerLines(prompt) } },
    })
    check('measured', captured.logs.some(l => l.includes('unmeasured')), false)
    check('exit 0 is a did-not-reproduce note', result.notes?.[0]?.reason, 'did-not-reproduce')
  } finally {
    fs.rmSync(dir, { recursive: true, force: true })
  }
}

const SETTLED_BY_ROUND_1 = {
  args: { maxReviewRounds: 2 },
  initialReview: reviewOf(finding('gets fixed', 'a'), finding('stays open', 'b')),
  verify: (id, round) => id === 'f1' && round >= 1 ? 0 : 1,
  fixHead: (round) => `fix000000000000000000000000000000000000${String(round).padStart(2, '0')}`,
  staleness: () => [],
}

async function scenarioSettledUnmeasuredFixRound() {
  console.log('\n== scenario PJ: a settled re-check unmeasured twice in a fix round halts on measurement and reopens nothing')
  const { result, captured } = await run({ ...SETTLED_BY_ROUND_1,
    reproRuns: (label) => label.startsWith('reproduce:settled:2') ? { output: 'all still pass' } : undefined })
  check('retried once', [callCount(captured, 'reproduce:settled:2:retry'), callCount(captured, 'reproduce:settled:2:retry:retry')], [1, 0])
  check('halted at Fix', result.halted_at, 'Fix')
  check('the note says the re-check could not be measured, and that it is not a regression',
    /re-check of 1 settled finding\(s\) could not be measured/.test(result.note ?? '') &&
    (result.note ?? '').includes('not a regression'), true)
  check('the note names the settled finding', (result.note ?? '').includes('f1: gets fixed'), true)
  check('nothing was logged as an undone fix', captured.logs.some(l => l.includes('no longer hold')), false)
  const f1 = result.unresolved_findings?.find(f => f.id === 'f1')
  check('the settled finding is kept with its last measured run, not a regression', f1?.reproducer_run?.outcome, 'passed')
  check('the open finding is kept', result.unresolved_findings?.some(f => f.id === 'f2'), true)
}

async function scenarioSettledRetryMeasures() {
  console.log('\n== scenario PK: a settled re-check unmeasured once and measured on its retry goes on as before')
  const { result, captured } = await run({ ...SETTLED_BY_ROUND_1,
    reproRuns: (label) => label === 'reproduce:settled:2' ? { output: 'all still pass' } : undefined })
  check('retried once', callCount(captured, 'reproduce:settled:2:retry'), 1)
  check('the loop ran to its limit, not a measurement halt',
    [result.halted_at, (result.note ?? '').includes('could not be measured')], ['Fix', false])
  check('the settled finding stayed settled', result.unresolved_findings?.map(f => f.id), ['f2'])
}

async function scenarioSettledUnmeasuredMutation() {
  console.log('\n== scenario PL: a settled re-check at the mutation head unmeasured twice halts on measurement, never blaming the mutation commits')
  const { result, captured } = await run(convergedWithSuspect({
    tailReview: [],
    mutationResult: () => ({ green: true, head_sha: 'mut0000000000000000000000000000000000001', detail: 'stub green', scored: true }),
    reproRuns: (label) => label.startsWith('reproduce:settled:mutation') ? null : undefined,
  }))
  check('retried once', callCount(captured, 'reproduce:settled:mutation:retry'), 1)
  check('halted at Review', result.halted_at, 'Review')
  check('the note says it could not be measured', (result.note ?? '').includes('could not be measured'), true)
  check('the note does not say the mutation commits undid a fix', /undid|mutation gate's own commits/.test(result.note ?? ''), false)
  check('the settled finding is carried with its last measured run',
    result.unresolved_findings?.map(f => [f.id, f.reproducer_run?.outcome]), [['f1', 'passed']])
}

const SCENARIOS = [scenarioPromptIsOneLinePerReproducer, scenarioPromptWithRange, scenarioOutcomesFromTheShell,
  scenarioTolerance, scenarioRejects, scenarioNullIsUnmeasured, scenarioHunksRejected, scenarioFixerGetsLogPath,
  scenarioHunksFailed, scenarioRealOutcomes, scenarioRealDirty, scenarioRealDirtyBefore, scenarioRealHunks,
  scenarioRealBadRange, scenarioCksumMatchesPosix, scenarioBase64MatchesUtf8, scenarioRealMultiLine,
  scenarioRealInventedRow, scenarioRealGenuineRunPassesChecksum, scenarioSettledUnmeasuredFixRound,
  scenarioSettledRetryMeasures, scenarioSettledUnmeasuredMutation]
JS_EOF

finish
