#!/usr/bin/env bash
# gh-163: the draft PR's adoption and the diffstat are read from script-built
# lines the shell prints. A PR is adopted only when its head is an ancestor of
# the branch (#152), a ready one is converted to a draft before the push, and
# every halt note states the PR state the run read (#149); see harness.sh.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/harness.sh"

run_js_scenarios <<'JS_EOF'
const promptOf = (captured, label) => captured.calls.find(c => c.label === label)?.prompt ?? ''
const fenceOf = (prompt) => /```bash\n([\s\S]*?)\n```/.exec(prompt)?.[1].split('\n') ?? []
const labelsOf = (captured) => captured.calls.map(c => c.label)
const OUTPUT_ONLY = JSON.stringify({ type: 'object', additionalProperties: false, required: ['output'],
  properties: { output: { type: 'string' } } })
const BRANCH = 'feat/gh-21-stub'
const withPr = (pr, over = {}) => ({ prState: () => pr, ...over })
const openPr = (over = {}) => ({ prResult: { opened: true, url: 'https://example.invalid/pr/42', note: 'stub' },
  ...over, args: { openPr: true, ...(over.args ?? {}) } })
const mutationRed = (over = {}) => ({ mutationGated: true,
  mutationResult: () => ({ green: false, head_sha: REVIEWED_THROUGH, detail: 'stub red', scored: false }),
  mutationVerify: () => ({ exit: 5 }), ...over })
const READY_NOTE = 'read as ready for review, with commits the gates have not passed'

async function scenarioStateLine() {
  console.log('\n== scenario DP1: one script-built line reads the branch\'s PR and whether its head is an ancestor')
  const { captured } = await run({})
  const call = captured.calls.find(c => c.label === 'pr:state')
  check('the fence is the one PR line', fenceOf(call?.prompt ?? ''), [
    `p="$(cd /tmp/stub-worktree && gh pr view ${BRANCH} --json number,state,isDraft,headRefOid ` +
    `--jq '"\\(.number) \\(.state) \\(.isDraft) \\(.headRefOid)"' 2>/dev/null)" || p=''; ` +
    `read -r n s r h <<<"$p"; ` +
    `if [ -n "$h" ] && git -C /tmp/stub-worktree merge-base --is-ancestor "$h" HEAD 2>/dev/null; then a=1; else a=0; fi; ` +
    `printf 'TOUCHSTONE_PR %s %s %s %s %s %s\\n' ${BRANCH} "\${n:-none}" "\${s:-none}" "\${r:-none}" "\${h:-none}" "$a"`])
  check('the schema asks for output and nothing else', JSON.stringify(call?.schema), OUTPUT_ONLY)
  check('it is a haiku call at low effort', [call?.model, call?.effort], ['haiku', 'low'])
  check('it runs after Implement and before draft-pr',
    [labelsOf(captured).indexOf('implementer') < labelsOf(captured).indexOf('pr:state'),
      labelsOf(captured).indexOf('pr:state') < labelsOf(captured).indexOf('draft-pr')], [true, true])
}

async function scenarioNoPrOpens() {
  console.log('\n== scenario DP2: no PR for the branch: the draft-pr agent opens one, and adopts nothing')
  const { result, captured } = await run(openPr({
    draftPr: { opened: true, number: 23, url: 'https://example.invalid/pr/23', detail: 'opened' } }))
  const p = promptOf(captured, 'draft-pr')
  check('draft-pr ran once', callCount(captured, 'draft-pr'), 1)
  check('its prompt opens a draft', p.includes(`gh pr create --draft`) && p.includes(`git push -u origin ${BRANCH}`), true)
  check('its prompt carries no adoption logic', [/adopt/i.test(p), p.includes('gh pr view')], [false, false])
  check('its prompt no longer measures the diff', p.includes('TOUCHSTONE_DIFFSTAT'), false)
  check('no conversion and no separate push', [callCount(captured, 'pr:undo'), callCount(captured, 'pr:push')], [0, 0])
  check('the PR phase addresses the PR it opened, as a draft',
    promptOf(captured, 'pr').includes('A draft PR already exists for this branch: #23'), true)
  check('the run completes', result.halted_at, undefined)
}

async function scenarioUnrelatedPrHalts() {
  console.log('\n== scenario DP3: a PR whose head is not an ancestor of the branch is never adopted: the run halts naming both')
  const head = 'dead000000000000000000000000000000000142'
  const { result, captured } = await run(withPr({ number: 142, head, ancestor: 0 },
    { draftPr: { opened: true, number: 142, url: 'u', detail: 'would adopt' } }))
  check('halted at Draft PR', result.halted_at, 'Draft PR')
  const note = result.note ?? ''
  check('the note names the PR, its head and the branch',
    [note.includes('#142'), note.includes(head), note.includes(BRANCH)], [true, true, true])
  check('it says the PR was not adopted', /not adopt/.test(note), true)
  check('nothing ran against it: no draft-pr, conversion, push or review',
    [callCount(captured, 'draft-pr'), callCount(captured, 'pr:undo'), callCount(captured, 'pr:push'),
      captured.calls.some(c => c.label.startsWith('review:'))], [0, 0, 0, false])
  for (const state of ['MERGED', 'CLOSED']) {
    const both = await run(withPr({ number: 142, head, ancestor: 0, state }))
    check(`${state} and unrelated: still the unrelated halt`, /not adopt/.test(both.result.note ?? ''), true)
  }
}

async function scenarioRelatedDraftAdopted() {
  console.log('\n== scenario DP4: an open draft PR that is an ancestor is adopted, with the number the shell read')
  const { result, captured } = await run(openPr(withPr({ number: 42, isDraft: true },
    { draftPr: { opened: true, number: 99, url: 'u', detail: 'not asked' } })))
  check('no draft-pr agent', callCount(captured, 'draft-pr'), 0)
  check('no conversion for a draft', callCount(captured, 'pr:undo'), 0)
  check('the branch is pushed by a script-built line', callCount(captured, 'pr:push'), 1)
  check('the push line', fenceOf(promptOf(captured, 'pr:push')).map(l => l.replace(/touchstone-pr\/\S+ /, 'touchstone-pr/RUN ')), [
    `d="$(git -C /tmp/stub-worktree rev-parse --path-format=absolute --git-path touchstone-pr/RUN 2>/dev/null)" && mkdir -p "$d" && ` +
    `{ git -C /tmp/stub-worktree push -u origin ${BRANCH} >|"$d/push.log" 2>&1; e=$?; ` +
    `printf 'TOUCHSTONE_PUSH %s %s %s\\n' ${BRANCH} "$e" "$d/push.log"; }`])
  check('the PR phase addresses #42, the shell\'s number',
    promptOf(captured, 'pr').includes('A draft PR already exists for this branch: #42'), true)
  check('the run completes', result.halted_at, undefined)
  const pushFails = await run(withPr({ number: 42 }, { prPush: () => ({ exit: 1 }) }))
  check('a failed push is logged and is not fatal',
    [pushFails.result.halted_at, pushFails.captured.logs.some(l => /pr:push/.test(l) && /exited 1/.test(l))], [undefined, true])
}

async function scenarioReadyConverted() {
  console.log('\n== scenario DP5: a ready PR is converted to a draft before the push, and a later halt says draft')
  const { result, captured } = await run(mutationRed(withPr({ number: 42, isDraft: false })))
  const labels = labelsOf(captured)
  check('the conversion runs before the push',
    [labels.includes('pr:undo'), labels.indexOf('pr:undo') < labels.indexOf('pr:push')], [true, true])
  check('the conversion line undoes ready, then re-reads isDraft',
    fenceOf(promptOf(captured, 'pr:undo')).map(l => l.replace(/touchstone-pr\/\S+ /, 'touchstone-pr/RUN ')), [
      `d="$(git -C /tmp/stub-worktree rev-parse --path-format=absolute --git-path touchstone-pr/RUN 2>/dev/null)" && mkdir -p "$d" && ` +
      `{ (cd /tmp/stub-worktree && gh pr ready 42 --undo) >|"$d/pr-undo.log" 2>&1; e=$?; ` +
      `r="$(cd /tmp/stub-worktree && gh pr view 42 --json isDraft --jq .isDraft 2>/dev/null)"; ` +
      `printf 'TOUCHSTONE_PR_UNDO %s %s %s %s\\n' 42 "$e" "\${r:-none}" "$d/pr-undo.log"; }`])
  check('halted at Mutation', result.halted_at, 'Mutation')
  check('the halt says the PR was left as a draft', (result.note ?? '').includes('The PR was left as a draft'), true)
  check('and not that it is ready', (result.note ?? '').includes(READY_NOTE), false)
  const exitButDraft = await run(mutationRed(withPr({ number: 42, isDraft: false }, { prUndo: () => ({ exit: 1, isDraft: 'true' }) })))
  check('a nonzero exit whose re-read says draft is a draft',
    (exitButDraft.result.note ?? '').includes('The PR was left as a draft'), true)
}

async function scenarioConversionFails() {
  console.log('\n== scenario DP6: a conversion that fails keeps the PR, and every halt note says it is ready with ungated commits')
  const failed = await run(mutationRed(withPr({ number: 42, isDraft: false }, { prUndo: () => ({ exit: 1, isDraft: 'false' }) })))
  const note = failed.result.note ?? ''
  check('halted at Mutation', failed.result.halted_at, 'Mutation')
  check('the note says ready with commits the gates have not passed', note.includes(`PR #42 ${READY_NOTE}`), true)
  check('it names the exit', note.includes('exited 1'), true)
  check('it never says draft', /left as a draft/.test(note), false)
  check('the push still ran', callCount(failed.captured, 'pr:push'), 1)
  const garbled = await run(mutationRed(withPr({ number: 42, isDraft: false }, { prUndo: () => ({ output: 'done' }) })))
  check('an unparseable conversion is retried once', callCount(garbled.captured, 'pr:undo:retry'), 1)
  check('then reads as ready, unverified', [(garbled.result.note ?? '').includes(READY_NOTE),
    /could not be verified/.test(garbled.result.note ?? '')], [true, true])
  const atReview = await run(withPr({ number: 42, isDraft: false }, { prUndo: () => ({ exit: 1, isDraft: 'false' }), sizeUnmeasured: true }))
  check('a Review halt reads as ready too', [atReview.result.halted_at, (atReview.result.note ?? '').includes(READY_NOTE)],
    ['Review', true])
  const pr = await run(openPr(withPr({ number: 42, isDraft: false }, { prUndo: () => ({ exit: 1, isDraft: 'false' }) })))
  check('the PR phase is not told it is a draft', [promptOf(pr.captured, 'pr').includes('A PR already exists for this branch: #42'),
    promptOf(pr.captured, 'pr').includes('A draft PR already exists')], [true, false])
}

async function scenarioMergedHalts() {
  console.log('\n== scenario DP7: a merged or closed PR for the branch halts; nothing is pushed to it')
  for (const state of ['MERGED', 'CLOSED']) {
    const { result, captured } = await run(withPr({ number: 42, state }))
    check(`${state}: halted at Draft PR`, result.halted_at, 'Draft PR')
    check(`${state}: the note names the PR and its state`,
      [(result.note ?? '').includes('#42'), (result.note ?? '').includes(state.toLowerCase())], [true, true])
    check(`${state}: no draft-pr, conversion or push`,
      [callCount(captured, 'draft-pr'), callCount(captured, 'pr:undo'), callCount(captured, 'pr:push')], [0, 0, 0])
  }
}

async function scenarioStateParser() {
  console.log('\n== scenario DP8: a PR line that is not exactly the line is retried once; unparseable twice opens and adopts nothing')
  const good = `TOUCHSTONE_PR ${BRANCH} 42 OPEN true ${PR_HEAD} 1`
  const bad = {
    'no output': '',
    'two lines': `${good}\n${good}`,
    'another branch': good.replace(BRANCH, 'feat/gh-142-other'),
    'a non-integer number': good.replace(' 42 ', ' #42 '),
    'an unknown state': good.replace(' OPEN ', ' DRAFT '),
    'isDraft not a boolean': good.replace(' true ', ' yes '),
    'a 7-char head': good.replace(PR_HEAD, PR_HEAD.slice(0, 7)),
    'ancestor not 0 or 1': good.replace(/ 1$/, ' 2'),
    'none with PR fields': `TOUCHSTONE_PR ${BRANCH} none OPEN true ${PR_HEAD} 1`,
    'a prefixed line': `ok: ${good}`,
    'a missing field': `TOUCHSTONE_PR ${BRANCH} 42 OPEN true ${PR_HEAD}`,
  }
  for (const [name, output] of Object.entries(bad)) {
    const { result, captured } = await run(openPr({ prState: (retry) => retry ? { number: 42 } : { output } }))
    check(`${name}: retried once`, callCount(captured, 'pr:state:retry'), 1)
    check(`${name}: the retry's PR is adopted`, promptOf(captured, 'pr').includes('#42'), true)
    check(`${name}: no halt`, result.halted_at, undefined)
  }
  const ok = await run({ prState: () => ({ output: good }) })
  check('a well-formed line is not retried', callCount(ok.captured, 'pr:state:retry'), 0)
  const none = await run({ prState: () => ({ output: `TOUCHSTONE_PR ${BRANCH} none none none none 0` }) })
  check('none is accepted as no PR', [callCount(none.captured, 'pr:state:retry'), callCount(none.captured, 'draft-pr')], [0, 1])
  const twice = await run(mutationRed({ prState: () => ({ output: 'garbage' }),
    draftPr: { opened: true, number: 23, url: 'u', detail: 'must not open' } }))
  check('twice unparseable: no draft-pr, no conversion, no push',
    [callCount(twice.captured, 'draft-pr'), callCount(twice.captured, 'pr:undo'), callCount(twice.captured, 'pr:push')], [0, 0, 0])
  check('it is logged with both reasons', twice.captured.logs.some(l => /^pr:state: unmeasured/.test(l) && l.includes('malformed PR line')), true)
  check('the run goes on, and its halt says no PR was opened',
    [twice.result.halted_at, (twice.result.note ?? '').includes('No PR was opened')], ['Mutation', true])
}

async function scenarioDiffstatLine() {
  console.log('\n== scenario DP9: the diffstat is its own script-built line with a shell-computed line count')
  const { result, captured } = await run({})
  const call = captured.calls.find(c => c.label === 'diffstat')
  const line = fenceOf(call?.prompt ?? '')
  check('one line', line.length, 1)
  check('it writes the numstat and comment counts to a log, then prints them between the markers',
    [line[0]?.includes(`git -C /tmp/stub-worktree diff --numstat --no-renames ${COMMIT_RANGE} >|"$d/diffstat.log"`),
      line[0]?.includes(`printf 'TOUCHSTONE_DIFFSTAT %s\\n' ${COMMIT_RANGE}; cat "$d/diffstat.log"; `),
      line[0]?.endsWith(`printf 'TOUCHSTONE_DIFFSTAT_END %s %s\\n' "$(grep -c '' "$d/diffstat.log")" "$g"; }`)],
    [true, true, true])
  check('the schema asks for output and nothing else', JSON.stringify(call?.schema), OUTPUT_ONLY)
  check('it is a haiku call at low effort', [call?.model, call?.effort], ['haiku', 'low'])
  check('the size comes from it', [result.size?.files, result.size?.codeChurn], [2, 200])
  check('no size agent exists any more', captured.calls.some(c => c.label === 'size'), false)
  const range = COMMIT_RANGE
  const bad = {
    'a count that disagrees': diffstatOutput(range, [['a.js', 100, 0]]).replace(/END \d+ /, 'END 9 '),
    'a git diff that failed': diffstatOutput(range, [['a.js', 100, 0]], [], 128),
    'no count': diffstatOutput(range, [['a.js', 100, 0]]).replace(/ \d+ 0$/, ''),
    'the old end line': diffstatOutput(range, [['a.js', 100, 0]]).replace(/_END .*$/, '_END'),
    'another range': diffstatOutput('wrong..range', [['a.js', 100, 0]]),
  }
  for (const [name, output] of Object.entries(bad)) {
    const r = await run({ diffstat: output })
    check(`${name}: retried once and recovered`, [callCount(r.captured, 'diffstat:retry'), r.result.halted_at], [1, undefined])
  }
  const twice = await run({ sizeUnmeasured: true })
  check('malformed twice: the existing unmeasured halt at Review',
    [twice.result.halted_at, (twice.result.note ?? '').includes('measurement problem')], ['Review', true])
  check('and no lens ran', twice.captured.calls.some(c => c.label.startsWith('review:')), false)
}

const scratchRepo = () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'draft-pr-'))
  const env = { ...process.env, GIT_AUTHOR_NAME: 'test', GIT_AUTHOR_EMAIL: 't@t',
    GIT_COMMITTER_NAME: 'test', GIT_COMMITTER_EMAIL: 't@t' }
  const git = (...a) => execFileSync('git', ['-C', dir, ...a], { env, encoding: 'utf8' }).trim()
  execFileSync('git', ['init', '-q', dir])
  const commit = (file) => {
    fs.writeFileSync(path.join(dir, file), `${file}\n`)
    git('add', '-A')
    git('-c', 'commit.gpgsign=false', 'commit', '-q', '-m', file)
    return git('rev-parse', 'HEAD')
  }
  return { dir, git, commit }
}
const branchAt = (dir) => ({ created: true, branch: BRANCH, base: 'main', path: dir,
  ticket: '21', detail: 'stub', dirty: false })
// A fake gh on PATH: it records its cwd and arguments, answers the PR query
// from FAKE_GH_PR (none: exit 1), isDraft from FAKE_GH_ISDRAFT, and exits
// FAKE_GH_UNDO_EXIT for pr ready.
const withFakeGh = async (env, fn) => {
  const bin = fs.mkdtempSync(path.join(os.tmpdir(), 'fake-gh-'))
  const log = path.join(bin, 'calls.log')
  fs.writeFileSync(path.join(bin, 'gh'), [
    '#!/usr/bin/env bash',
    'printf \'%s|%s\\n\' "$PWD" "$*" >> "$FAKE_GH_LOG"',
    'case "$1 $2" in',
    '  "pr view") case "$*" in',
    '    *headRefOid*) [ -n "${FAKE_GH_PR:-}" ] || { echo "no pull requests found" >&2; exit 1; }; printf \'%s\\n\' "$FAKE_GH_PR" ;;',
    '    *isDraft*) printf \'%s\\n\' "${FAKE_GH_ISDRAFT:-false}" ;;',
    '  esac ;;',
    '  "pr ready") exit "${FAKE_GH_UNDO_EXIT:-0}" ;;',
    'esac', ''].join('\n'), { mode: 0o755 })
  const saved = { ...process.env }
  process.env.PATH = `${bin}:${process.env.PATH}`
  Object.assign(process.env, { FAKE_GH_LOG: log }, env)
  try {
    return await fn(() => fs.existsSync(log) ? fs.readFileSync(log, 'utf8').trim().split('\n') : [])
  } finally {
    for (const k of Object.keys(process.env)) if (!(k in saved)) delete process.env[k]
    Object.assign(process.env, saved)
    fs.rmSync(bin, { recursive: true, force: true })
  }
}
const real = (outs) => (...a) => {
  const prompt = a.find(x => typeof x === 'string' && x.includes('```bash'))
  const output = runRunnerLines(prompt)
  outs.push(output.trim())
  return { output }
}

async function scenarioRealLines() {
  console.log('\n== scenario DP10: the real lines, run in bash against a scratch repo with a stub gh on PATH')
  const { dir, git, commit } = scratchRepo()
  const remote = fs.mkdtempSync(path.join(os.tmpdir(), 'draft-pr-remote-'))
  try {
    commit('base.txt')
    const base = git('rev-parse', 'HEAD')
    git('checkout', '-qb', 'other')
    const unrelated = commit('other.txt')
    git('checkout', '-qb', BRANCH, base)
    const prHead = commit('a.txt')
    commit('b.txt')
    execFileSync('git', ['init', '-q', '--bare', remote])
    git('remote', 'add', 'origin', remote)
    const lines = () => ({ states: [], undos: [], pushes: [] })

    await withFakeGh({ FAKE_GH_PR: `42 OPEN true ${prHead}` }, async (calls) => {
      const o = lines()
      const { result, captured } = await run(openPr({ branchResult: branchAt(dir),
        prState: real(o.states), prUndo: real(o.undos), prPush: real(o.pushes) }))
      check('an ancestor head prints 1', o.states[0], `TOUCHSTONE_PR ${BRANCH} 42 OPEN true ${prHead} 1`)
      check('gh ran in the worktree', fs.realpathSync(calls()[0]?.split('|')[0] ?? '/'), fs.realpathSync(dir))
      check('the draft is adopted and pushed', [promptOf(captured, 'pr').includes('#42'), o.pushes[0]?.split(' ').slice(0, 3).join(' ')],
        [true, `TOUCHSTONE_PUSH ${BRANCH} 0`])
      check('the remote has the branch at the head', execFileSync('git', ['-C', remote, 'rev-parse', BRANCH], { encoding: 'utf8' }).trim(),
        git('rev-parse', 'HEAD'))
      check('no conversion for a draft', o.undos.length, 0)
      check('the run completes', result.halted_at, undefined)
    })
    for (const [name, head] of [['a head on another branch', unrelated], ['a head this clone does not have', 'dead000000000000000000000000000000000142']]) {
      await withFakeGh({ FAKE_GH_PR: `142 OPEN true ${head}` }, async () => {
        const o = lines()
        const { result, captured } = await run({ branchResult: branchAt(dir), prState: real(o.states) })
        check(`${name}: prints 0`, o.states[0], `TOUCHSTONE_PR ${BRANCH} 142 OPEN true ${head} 0`)
        check(`${name}: halts at Draft PR without adopting`, [result.halted_at, callCount(captured, 'pr:push')], ['Draft PR', 0])
      })
    }
    await withFakeGh({}, async () => {
      const o = lines()
      const { captured } = await run({ branchResult: branchAt(dir), prState: real(o.states) })
      check('gh failing prints none', o.states[0], `TOUCHSTONE_PR ${BRANCH} none none none none 0`)
      check('and draft-pr opens one', callCount(captured, 'draft-pr'), 1)
    })
    await withFakeGh({ FAKE_GH_PR: `42 OPEN false ${prHead}`, FAKE_GH_ISDRAFT: 'true' }, async (calls) => {
      const o = lines()
      const { result } = await run(mutationRed({ branchResult: branchAt(dir),
        prState: real(o.states), prUndo: real(o.undos), prPush: real(o.pushes) }))
      check('a ready PR: the conversion prints exit 0 and isDraft true',
        o.undos[0]?.split(' ').slice(0, 4).join(' '), 'TOUCHSTONE_PR_UNDO 42 0 true')
      check('gh pr ready --undo ran', calls().some(c => c.endsWith('|pr ready 42 --undo')), true)
      check('the halt says draft', (result.note ?? '').includes('The PR was left as a draft'), true)
    })
    await withFakeGh({ FAKE_GH_PR: `42 OPEN false ${prHead}`, FAKE_GH_ISDRAFT: 'false', FAKE_GH_UNDO_EXIT: '1' }, async () => {
      const o = lines()
      const { result } = await run(mutationRed({ branchResult: branchAt(dir),
        prState: real(o.states), prUndo: real(o.undos), prPush: real(o.pushes) }))
      check('a failed conversion prints exit 1 and isDraft false',
        o.undos[0]?.split(' ').slice(0, 4).join(' '), 'TOUCHSTONE_PR_UNDO 42 1 false')
      check('the halt says ready with ungated commits', (result.note ?? '').includes(`PR #42 ${READY_NOTE}`), true)
    })
    const ds = await run({ branchResult: branchAt(dir), implRange: `${base}..${git('rev-parse', 'HEAD')}` })
    const printed = runRunnerLines(promptOf(ds.captured, 'diffstat')).trim().split('\n')
    check('the real diffstat line prints begin, body and an end line whose count is the body',
      [printed[0], printed[printed.length - 1]],
      [`TOUCHSTONE_DIFFSTAT ${base}..${git('rev-parse', 'HEAD')}`, `TOUCHSTONE_DIFFSTAT_END ${printed.length - 2} 0`])
    check('the tree stays clean', git('status', '--porcelain'), '')
  } finally {
    fs.rmSync(dir, { recursive: true, force: true })
    fs.rmSync(remote, { recursive: true, force: true })
  }
}

const HOOK = path.join(path.dirname(SCRIPT_PATH), '..', 'hooks', 'gate-pipe-gate.py')
const hookExit = (command) => spawnSync('python3', [HOOK],
  { input: JSON.stringify({ tool_input: { command } }), encoding: 'utf8' }).status

async function scenarioHookAllowsLines() {
  console.log('\n== scenario DP11: gate-pipe-gate.py allows every built line')
  const { captured } = await run(withPr({ number: 42, isDraft: false }))
  for (const label of ['pr:state', 'pr:undo', 'pr:push', 'diffstat']) {
    const lines = fenceOf(promptOf(captured, label))
    check(`${label}: has lines`, lines.length > 0, true)
    check(`${label}: every line passes the hook`, lines.map(hookExit), lines.map(() => 0))
  }
}

const SCENARIOS = [scenarioStateLine, scenarioNoPrOpens, scenarioUnrelatedPrHalts, scenarioRelatedDraftAdopted,
  scenarioReadyConverted, scenarioConversionFails, scenarioMergedHalts, scenarioStateParser, scenarioDiffstatLine,
  scenarioRealLines, scenarioHookAllowsLines]
JS_EOF

finish
