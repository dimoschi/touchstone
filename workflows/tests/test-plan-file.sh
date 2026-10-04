#!/usr/bin/env bash
# A plan stays short, lives whole in an untracked file in the worktree, and the
# implementer has to prove it read all of it: the length gate on the planner,
# the plan:write step, the implementer's plan_id, and the probe that refuses a
# commit carrying .touchstone/.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/harness.sh"

PARTS="$REPO_ROOT/workflows/parts"

echo "== static: the plan is never clamped, and the implementer must return plan_id"
check "brief() is not applied to the plan anywhere" \
  "$(grep -c 'brief(plan' "$PARTS"/*.js.part | awk -F: '{s+=$NF} END{print s+0}')" 0
check "the IMPL schema requires plan_id" \
  "$(grep -Fc "required: ['summary', 'files_changed', 'commit_range', 'scored', 'plan_id']" "$SCRIPT" || true)" 1

run_js_scenarios <<'JS_EOF'
const TEAM = { scope: 'team', estimated_loc: 50 }
const CLEAN = { initialReview: { correctness: [], advocate: [] } }
const plannerWith = (plan) => ({ plan, acceptance_criteria: [], risky_areas: [],
  task_demands_implementation: false, additions: [] })
const promptOf = (captured, label) => captured.calls.find(c => c.label === label)?.prompt ?? ''
const labelsOf = (captured) => captured.calls.map(c => c.label)
const idxOf = (captured, label) => labelsOf(captured).indexOf(label)
const OVER = 'a'.repeat(6001)
const FIT = 'b'.repeat(5000)
const WITH_CHECKS = {
  discovery: { file: '/repo/AGENTS.md',
    sections: [{ heading: '## Checks', fence: 'bash scripts/run-tests.sh' }], detail: 'stub' },
  checkRuns: () => ({ results: [checkRow('check:1', 'bash scripts/run-tests.sh', 0, 'ok')], dirty: false }),
}
const leakOutput = (range, paths) =>
  `TOUCHSTONE_PLAN_LEAK ${range}\n${paths.map(p => `${p}\n`).join('')}TOUCHSTONE_PLAN_LEAK_END`
const LEAK = ['.touchstone/plan.md']
const planIdFor = async (overrides) => {
  const { captured } = await run({ triage: TEAM, ...CLEAN, ...overrides })
  return planFileIn(promptOf(captured, 'plan:write'))?.id
}

// Scenario PF1 -- a plan over the limit gets exactly one tighten call, and the
// plan that continues is the tightened one.
async function scenarioPF1() {
  console.log('\n== scenario PF1: a 6001-char plan is tightened once and the 5000-char result goes on')
  const { result, captured } = await run({
    triage: TEAM, plannerResult: plannerWith(OVER), tightenResult: plannerWith(FIT), ...CLEAN,
  })
  check('exactly one planner:tighten call', callCount(captured, 'planner:tighten'), 1)
  check('the run does not halt', result.halted_at, undefined)
  const tighten = promptOf(captured, 'planner:tighten')
  check('the tighten prompt carries the previous plan whole', tighten.includes(OVER), true)
  check('it states the length and the limit', tighten.includes('6001 chars, limit 6000'), true)
  const written = promptOf(captured, 'plan:write')
  check('the plan file carries the tightened plan', written.includes(FIT), true)
  check('the plan file does not carry the over-long plan', written.includes(OVER), false)
}

// Scenario PF2 -- still over after the retry, or no answer at all: the run
// stops at Plan, before anything is written or implemented.
async function scenarioPF2() {
  console.log('\n== scenario PF2: a plan still over the limit after one retry halts at Plan')
  const STILL_OVER = 'c'.repeat(6001)
  for (const [name, tightenResult, returned] of [['over again', plannerWith(STILL_OVER), STILL_OVER], ['null', null, OVER]]) {
    const { result, captured } = await run({
      triage: TEAM, plannerResult: plannerWith(OVER), tightenResult, ...CLEAN,
    })
    check(`${name}: halted at Plan`, result.halted_at, 'Plan')
    check(`${name}: the note says it did not fit`, /did not fit in 6000 chars after one retry/.test(result.note ?? ''), true)
    check(`${name}: the note says the ticket may need splitting`, /split/.test(result.note ?? ''), true)
    check(`${name}: one tighten call`, callCount(captured, 'planner:tighten'), 1)
    check(`${name}: the halt returns the last attempt`, result.plan, returned)
    check(`${name}: no plan:write`, callCount(captured, 'plan:write'), 0)
    check(`${name}: no implementer`, callCount(captured, 'implementer'), 0)
  }
}

async function scenarioPF3() {
  console.log('\n== scenario PF3: a plan of exactly 6000 chars is not tightened and is written unchanged')
  const tricky = 'use `${x}` and $HOME and "q" and \'s\' \\n'
  const plan = tricky + 'z'.repeat(6000 - tricky.length)
  const { captured } = await run({ triage: TEAM, plannerResult: plannerWith(plan), ...CLEAN })
  check('the plan is 6000 chars', plan.length, 6000)
  check('no planner:tighten call', callCount(captured, 'planner:tighten'), 0)
  const written = planFileIn(promptOf(captured, 'plan:write'))
  check('the file content is the plan, a blank line, and the end line',
    written?.content === `${plan}\n\nEND OF PLAN ${written?.id}\n`, true)
}

// Scenario PF4 -- the planner is told the limit, and args.planMaxChars moves it.
async function scenarioPF4() {
  console.log('\n== scenario PF4: the planner prompt states the limit; args.planMaxChars overrides it')
  const dflt = await run({ triage: TEAM, ...CLEAN })
  const p = promptOf(dflt.captured, 'planner')
  check('the default limit is stated', /at most 6000 characters/.test(p), true)
  const small = await run({ args: { planMaxChars: 3000 }, triage: TEAM,
    plannerResult: plannerWith('d'.repeat(3001)), tightenResult: plannerWith('e'.repeat(3000)), ...CLEAN })
  const q = promptOf(small.captured, 'planner')
  check('the override is stated', /at most 3000 characters/.test(q), true)
  check('the default is no longer stated', /at most 6000 characters/.test(q), false)
  check('the override gates the plan too', callCount(small.captured, 'planner:tighten'), 1)
}

// Scenario PF5 -- the plan file is written before the first check and before
// the implementer, whichever way the plan arrived.
async function scenarioPF5() {
  console.log('\n== scenario PF5: plan:write runs before checks:run and the implementer on every plan path')
  const paths = [
    ['planner', { triage: TEAM }],
    ['args.plan', { args: { plan: 'a plan from an earlier run' }, triage: TEAM }],
    ['inline', {}],
  ]
  for (const [name, scenario] of paths) {
    const { captured } = await run({ ...scenario, ...WITH_CHECKS, ...CLEAN })
    check(`${name}: one plan:write`, callCount(captured, 'plan:write'), 1)
    const w = idxOf(captured, 'plan:write')
    check(`${name}: before the first checks:run`, w >= 0 && w < idxOf(captured, 'checks:run:1'), true)
    check(`${name}: before the implementer`, w >= 0 && w < idxOf(captured, 'implementer'), true)
  }
}

// Scenario PF6 -- what the plan:write prompt asks for.
async function scenarioPF6() {
  console.log('\n== scenario PF6: the plan:write prompt carries the whole plan and the exact file, ignore and report steps')
  const plan = 'long plan. ' + 'f'.repeat(4500)
  const { captured } = await run({ args: { planMaxChars: 8000 }, triage: TEAM,
    plannerResult: plannerWith(plan), ...CLEAN })
  const p = promptOf(captured, 'plan:write')
  const written = planFileIn(p)
  check('the plan is longer than the brief clamp', plan.length > 4000, true)
  check('the whole plan is in the file content', written?.content.startsWith(plan), true)
  check('no brief truncation marker', p.includes('[brief truncated]'), false)
  check('the id is eight hex digits', /^[0-9a-f]{8}$/.test(written?.id ?? ''), true)
  check('the file ends with the end line', written?.content.endsWith(`\nEND OF PLAN ${written?.id}\n`), true)
  check('it targets the worktree plan file', p.includes('/tmp/stub-worktree/.touchstone/plan.md'), true)
  check('it creates the directory and clears any file from an earlier run',
    p.includes('mkdir -p /tmp/stub-worktree/.touchstone && rm -f /tmp/stub-worktree/.touchstone/plan.md'), true)
  check('it excludes through info/exclude under --git-common-dir',
    p.includes('--git-common-dir') && p.includes('info/exclude'), true)
  check('it never names a tracked ignore file', p.includes('.gitignore'), false)
  check('the exclude comes before the Write, so the hook sees an ignored path',
    p.indexOf('info/exclude') > 0 && p.indexOf('info/exclude') < p.indexOf('with the Write tool'), true)
  check('it asks for wc -c, tail -n 1 and check-ignore',
    p.includes('wc -c') && p.includes('tail -n 1') && p.includes('check-ignore -q .touchstone/plan.md'), true)
  check('it is dispatched on a cheap model', captured.calls.find(c => c.label === 'plan:write') !== undefined, true)
  const again = await planIdFor({ args: { planMaxChars: 8000 }, plannerResult: plannerWith(plan) })
  check('the id is deterministic', again, written?.id)
  const other = await planIdFor({ plannerResult: plannerWith(plan + 'x') })
  check('a different plan has a different id', other !== written?.id, true)
}

// Scenario PF7 -- plan:write has to prove the file is whole, or the run stops.
// A failed answer is retried once; only a second failure halts.
async function scenarioPF7() {
  console.log('\n== scenario PF7: a wrong byte count, last line or ignore status is retried once, then halts at Implement')
  const cases = [
    ['wrong byte count', { bytes: 1 }],
    ['wrong last line', { last_line: 'END OF PLAN 00000000' }],
    ['not ignored', { ignored_exit: 1 }],
    ['no answer', null],
  ]
  for (const [name, bad] of cases) {
    const once = await run({ triage: TEAM, plannerResult: plannerWith('plan'), ...CLEAN,
      planWrite: (attempt) => attempt === 1 ? bad : undefined })
    check(`${name}: a good retry continues the run`, once.result.halted_at, undefined)
    check(`${name}: one plan:write`, callCount(once.captured, 'plan:write'), 1)
    check(`${name}: one plan:write:retry`, callCount(once.captured, 'plan:write:retry'), 1)
    const body = (label) => promptOf(once.captured, label).replace(/^\[touchstone: [^\]]*\]\n/, '')
    check(`${name}: the retry prompt is the same`, body('plan:write:retry'), body('plan:write'))
    check(`${name}: the implementer ran`, callCount(once.captured, 'implementer'), 1)

    const { result, captured } = await run({ triage: TEAM, plannerResult: plannerWith('plan'), ...CLEAN,
      planWrite: () => bad })
    check(`${name}: halted at Implement`, result.halted_at, 'Implement')
    check(`${name}: the note names the plan file`, /plan file/.test(result.note ?? ''), true)
    check(`${name}: the note says it was retried`, /even after a retry/.test(result.note ?? ''), true)
    check(`${name}: exactly one retry`, callCount(captured, 'plan:write:retry'), 1)
    check(`${name}: no implementer`, callCount(captured, 'implementer'), 0)
    check(`${name}: no checks ran`, labelsOf(captured).some(l => l.startsWith('checks:run')), false)
  }
}

// Scenario PF8 -- the byte count is UTF-8 bytes, not characters.
async function scenarioPF8() {
  console.log('\n== scenario PF8: the expected byte count is the UTF-8 length of the content')
  const plan = 'café → 😀 done'
  const ok = await run({ triage: TEAM, plannerResult: plannerWith(plan), ...CLEAN })
  check('the true UTF-8 count is accepted', ok.result.halted_at, undefined)
  const written = planFileIn(promptOf(ok.captured, 'plan:write'))
  const chars = [...(written?.content ?? '')].length
  check('the content is longer in bytes than in characters',
    Buffer.byteLength(written?.content ?? '', 'utf8') > chars, true)
  const wrong = await run({ triage: TEAM, plannerResult: plannerWith(plan), ...CLEAN,
    planWrite: { bytes: chars } })
  check('a character count is refused', wrong.result.halted_at, 'Implement')
}

// Scenario PF9 -- the implementer is pointed at the file, never handed the plan.
async function scenarioPF9() {
  console.log('\n== scenario PF9: the implementer prompt names the file and carries neither the plan nor the id')
  const plan = 'A distinctive plan sentence about the retry path. ' + 'g'.repeat(300)
  const { captured } = await run({ triage: TEAM, plannerResult: plannerWith(plan), ...CLEAN })
  const id = planFileIn(promptOf(captured, 'plan:write'))?.id ?? ''
  const p = promptOf(captured, 'implementer')
  check('there was an id to look for', id.length, 8)
  check('no plan text', p.includes('A distinctive plan sentence'), false)
  check('no id', p.includes(id), false)
  check('it names the plan file', p.includes('/tmp/stub-worktree/.touchstone/plan.md'), true)
  check('it names the end line', p.includes('END OF PLAN'), true)
  check('it asks for plan_id', p.includes('plan_id'), true)
  check('it says to read all of it before any edit', /Read all of it before any edit/.test(p), true)
  check('it says to refuse to start if the file cannot be read whole',
    /If you cannot read the whole file, do not start/.test(p), true)
  check('it says never to commit .touchstone/', /never commit \.touchstone\//.test(p), true)
}

// Scenario PF10 -- a missing, empty or wrong plan_id is a refusal, and nothing
// downstream runs.
async function scenarioPF10() {
  console.log('\n== scenario PF10: a missing, empty or wrong plan_id halts at Implement')
  const id = await planIdFor({})
  for (const [name, implPlanId] of [['missing', undefined], ['empty', ''], ['wrong', 'deadbeef']]) {
    const { result, captured } = await run({ triage: TEAM, ...CLEAN, implPlanId })
    check(`${name}: halted at Implement`, result.halted_at, 'Implement')
    check(`${name}: the note names the expected id`, (result.note ?? '').includes(id), true)
    for (const l of ['plan:leak:Implement', 'draft-pr', 'review:correctness', 'fix:1']) {
      check(`${name}: no ${l}`, callCount(captured, l), 0)
    }
  }
  const padded = await run({ triage: TEAM, ...CLEAN, implPlanId: `  ${id}\n` })
  check('the right id with whitespace around it passes', padded.result.halted_at, undefined)
}

// Scenario PF11 -- a leak the probe lists halts before the draft PR pushes.
async function scenarioPF11() {
  console.log('\n== scenario PF11: a .touchstone/ path in the implementer range halts at Implement before draft-pr')
  const { result, captured } = await run({ triage: TEAM, ...CLEAN,
    planLeak: (at, range) => leakOutput(range, LEAK) })
  check('halted at Implement', result.halted_at, 'Implement')
  check('the note names the path', (result.note ?? '').includes('.touchstone/plan.md'), true)
  check('no draft-pr', callCount(captured, 'draft-pr'), 0)
  const probe = promptOf(captured, 'plan:leak:Implement')
  check('the probe covers the implementer range', probe.includes(`echo TOUCHSTONE_PLAN_LEAK ${COMMIT_RANGE};`), true)
  check('the probe is a git log of names over .touchstone',
    probe.includes('git -C /tmp/stub-worktree log --format= --name-only') &&
    probe.includes('-- .touchstone;'), true)
  const clean = await run({ triage: TEAM, ...CLEAN })
  check('a clean probe lets the run continue', clean.result.halted_at, undefined)
  check('and the draft PR is reached', callCount(clean.captured, 'draft-pr'), 1)
}

// Scenario PF12 -- a probe that cannot be read is retried once, and never a pass.
async function scenarioPF12() {
  console.log('\n== scenario PF12: malformed or missing probe output is retried once, then halts as unverified')
  const bad = [
    ['null', () => null],
    ['empty', () => ''],
    ['no markers', () => 'nothing to see'],
    ['no end marker', (r) => `TOUCHSTONE_PLAN_LEAK ${r}\n`],
    ['wrong range', () => leakOutput('other..range', [])],
    ['a stray line', (r) => `TOUCHSTONE_PLAN_LEAK ${r}\nfatal: bad revision\nTOUCHSTONE_PLAN_LEAK_END`],
  ]
  for (const [name, out] of bad) {
    const twice = await run({ triage: TEAM, ...CLEAN, planLeak: (at, r) => out(r) })
    check(`${name}: halted at Implement`, twice.result.halted_at, 'Implement')
    check(`${name}: the note says it was not verified`, /could not be verified/.test(twice.result.note ?? ''), true)
    check(`${name}: the note says it was retried`, /even after a retry/.test(twice.result.note ?? ''), true)
    check(`${name}: exactly one retry`, callCount(twice.captured, 'plan:leak:Implement:retry'), 1)
    check(`${name}: no draft-pr`, callCount(twice.captured, 'draft-pr'), 0)

    const once = await run({ triage: TEAM, ...CLEAN,
      planLeak: (at, r, prompt, attempt) => attempt === 1 ? out(r) : undefined })
    check(`${name}: a clean retry continues the run`, once.result.halted_at, undefined)
    check(`${name}: the draft PR is reached`, callCount(once.captured, 'draft-pr'), 1)
  }
  const leak = await run({ triage: TEAM, ...CLEAN, planLeak: (at, range) => leakOutput(range, LEAK) })
  check('a real leak halts at once', leak.result.halted_at, 'Implement')
  check('a real leak is not retried', callCount(leak.captured, 'plan:leak:Implement:retry'), 0)
  const leakOnRetry = await run({ triage: TEAM, ...CLEAN,
    planLeak: (at, range, prompt, attempt) => attempt === 1 ? 'garbage' : leakOutput(range, LEAK) })
  check('a leak found by the retry halts naming the path',
    (leakOnRetry.result.note ?? '').includes('.touchstone/plan.md'), true)
}

// Scenario PF13 -- the checks-only fix before Review is part of the range.
async function scenarioPF13() {
  console.log('\n== scenario PF13: a commit from the pre-review checks fix is probed from the implementer base')
  const fixHead = 'checksfix00000000000000000000000000000002'
  const base = COMMIT_RANGE.split('..')[0]
  const { result, captured } = await run({
    triage: TEAM, ...CLEAN,
    discovery: WITH_CHECKS.discovery,
    checkRuns: (attempt) => attempt === 2
      ? { results: [checkRow('check:1', 'bash scripts/run-tests.sh', 1, 'FAILURE')], dirty: false }
      : { results: [checkRow('check:1', 'bash scripts/run-tests.sh', 0, 'ok')], dirty: false },
    checksFixResult: { head_sha: fixHead, note: 'bumped', scored: true },
    planLeak: (at, range) => leakOutput(range, LEAK),
  })
  check('halted at Implement', result.halted_at, 'Implement')
  check('the probe ran from the implementer base to the fix head',
    promptOf(captured, 'plan:leak:Implement').includes(`echo TOUCHSTONE_PLAN_LEAK ${base}..${fixHead};`), true)
  check('no draft-pr', callCount(captured, 'draft-pr'), 0)
}

// Scenario PF14 -- a fix round's new head is probed before anything reviews it.
async function scenarioPF14() {
  console.log('\n== scenario PF14: a leak in a fix round halts at Fix')
  const fixHead = 'fix00000000000000000000000000000000000001'
  const base = COMMIT_RANGE.split('..')[0]
  const scenario = {
    args: { maxReviewRounds: 1 }, triage: TEAM,
    initialReview: { correctness: [{ title: 'Off-by-one', file: 'src/p.js', claim: 'c1', evidence: 'e1' }],
      advocate: [] },
    verify: () => true, fixHead: () => fixHead, staleness: () => [],
  }
  const { result, captured } = await run({ ...scenario, planLeak: (at, range) =>
    at === 'Fix' ? leakOutput(range, LEAK) : undefined })
  check('halted at Fix', result.halted_at, 'Fix')
  check('the note names the path', (result.note ?? '').includes('.touchstone/plan.md'), true)
  check('the probe ran from the implementer base to the new head',
    promptOf(captured, 'plan:leak:Fix').includes(`echo TOUCHSTONE_PLAN_LEAK ${base}..${fixHead};`), true)
  check('no tail review ran', callCount(captured, 'review:fix:1:correctness'), 0)
  const clean = await run(scenario)
  check('a clean probe lets the round go on', clean.result.halted_at, undefined)
  const malformed = await run({ ...scenario, planLeak: (at) => at === 'Fix' ? 'garbage' : undefined })
  check('a probe malformed on both attempts halts at Fix', malformed.result.halted_at, 'Fix')
  check('and was retried once', callCount(malformed.captured, 'plan:leak:Fix:retry'), 1)
  const unchanged = await run({ ...scenario, fixHead: () => REVIEWED_THROUGH })
  check('a round that committed nothing is not probed', callCount(unchanged.captured, 'plan:leak:Fix'), 0)
}

// Scenario PF15 -- the mutation gate's commits are probed too.
async function scenarioPF15() {
  console.log('\n== scenario PF15: a leak in the mutation gate\'s commits halts at Mutation')
  const mutHead = 'mut00000000000000000000000000000000000001'
  const base = COMMIT_RANGE.split('..')[0]
  const scenario = { triage: TEAM, ...CLEAN, mutationGated: true,
    mutationResult: () => ({ green: true, head_sha: mutHead, detail: 'stub', scored: true }) }
  const { result, captured } = await run({ ...scenario, planLeak: (at, range) =>
    at === 'Mutation' ? leakOutput(range, LEAK) : undefined })
  check('halted at Mutation', result.halted_at, 'Mutation')
  check('the note names the path', (result.note ?? '').includes('.touchstone/plan.md'), true)
  check('the probe ran from the implementer base to the new head',
    promptOf(captured, 'plan:leak:Mutation').includes(`echo TOUCHSTONE_PLAN_LEAK ${base}..${mutHead};`), true)
  check('nothing was reviewed or pushed after it',
    callCount(captured, 'review:mutation:correctness') + callCount(captured, 'pr'), 0)
  const clean = await run(scenario)
  check('a clean probe lets the run continue', clean.result.halted_at, undefined)
  const malformed = await run({ ...scenario, planLeak: (at) => at === 'Mutation' ? null : undefined })
  check('a probe missing on both attempts halts at Mutation', malformed.result.halted_at, 'Mutation')
  check('and was retried once', callCount(malformed.captured, 'plan:leak:Mutation:retry'), 1)
  const unchanged = await run({ ...scenario, mutationResult: () => ({ green: true, head_sha: REVIEWED_THROUGH,
    detail: 'stub', scored: true }) })
  check('a mutation gate that committed nothing is not probed', callCount(unchanged.captured, 'plan:leak:Mutation'), 0)
}

async function scenarioPF16() {
  console.log('\n== scenario PF16: the probe command against a real repo catches add-then-delete')
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'plan-leak-'))
  try {
    const git = (...a) => execFileSync('git', ['-C', dir, '-c', 'commit.gpgsign=false',
      '-c', 'user.name=t', '-c', 'user.email=t@t', ...a], { encoding: 'utf8' }).trim()
    execFileSync('git', ['init', '-q', dir])
    fs.writeFileSync(path.join(dir, 'a.txt'), 'a\n')
    git('add', '-A'); git('commit', '-qm', 'base')
    const base = git('rev-parse', 'HEAD')
    fs.mkdirSync(path.join(dir, '.touchstone'))
    fs.writeFileSync(path.join(dir, '.touchstone', 'plan.md'), 'plan\n')
    fs.writeFileSync(path.join(dir, 'b.txt'), 'b\n')
    git('add', '-A'); git('commit', '-qm', 'leaks the plan')
    git('rm', '-q', '.touchstone/plan.md'); git('commit', '-qm', 'removes it again')
    const head = git('rev-parse', 'HEAD')
    const probe = (_at, _range, prompt) => execFileSync('bash',
      ['-c', /echo TOUCHSTONE_PLAN_LEAK [^\n]*TOUCHSTONE_PLAN_LEAK_END/.exec(prompt)[0]], { encoding: 'utf8' })
    const repo = { branchResult: { created: true, branch: 'feat/gh-21-stub', base: 'main', path: dir,
      ticket: '21', detail: 'stub' }, triage: TEAM, ...CLEAN }
    const caught = await run({ ...repo, implRange: `${base}..${head}`, planLeak: probe })
    check('add then delete is caught', caught.result.halted_at, 'Implement')
    check('the path is named', (caught.result.note ?? '').includes('.touchstone/plan.md'), true)
    const clean = await run({ ...repo, implRange: `${base}..${base}`, planLeak: probe })
    check('a range that never touched it passes', clean.result.halted_at, undefined)
  } finally {
    fs.rmSync(dir, { recursive: true, force: true })
  }
}

// Scenario PF17 -- args.plan is held to the same limit, but is never tightened.
async function scenarioPF17() {
  console.log('\n== scenario PF17: an args.plan over the limit halts at Plan; one at the limit goes on')
  const { result, captured } = await run({ args: { plan: OVER }, triage: TEAM, ...CLEAN })
  check('halted at Plan', result.halted_at, 'Plan')
  check('the halt returns the supplied plan', result.plan, OVER)
  check('the note names the length', (result.note ?? '').includes('6001'), true)
  check('the note names the limit', (result.note ?? '').includes('6000'), true)
  check('the note says it was not retried', /not retried/.test(result.note ?? ''), true)
  check('the note says the ticket may need splitting', /split/.test(result.note ?? ''), true)
  for (const l of ['planner', 'planner:tighten', 'plan:write', 'implementer']) {
    check(`no ${l} call`, callCount(captured, l), 0)
  }
  const exact = 'h'.repeat(6000)
  const ok = await run({ args: { plan: exact }, triage: TEAM, ...CLEAN })
  check('a plan of exactly 6000 chars is not halted', ok.result.halted_at, undefined)
  check('it is written unchanged', promptOf(ok.captured, 'plan:write').includes(exact), true)
  const small = await run({ args: { plan: 'i'.repeat(3001), planMaxChars: 3000 }, triage: TEAM, ...CLEAN })
  check('args.planMaxChars moves the limit', small.result.halted_at, 'Plan')
}

const SCENARIOS = [scenarioPF1, scenarioPF2, scenarioPF3, scenarioPF4, scenarioPF5, scenarioPF6,
  scenarioPF7, scenarioPF8, scenarioPF9, scenarioPF10, scenarioPF11, scenarioPF12, scenarioPF13,
  scenarioPF14, scenarioPF15, scenarioPF16, scenarioPF17]
JS_EOF

finish
