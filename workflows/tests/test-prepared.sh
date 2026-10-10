#!/usr/bin/env bash
# args.prepared, the JSON prepare-delivery.sh prints, replaces the branch
# agents and the marker and version halves of setup, and every field is checked
# before anything is dispatched. Also the agent path's two fixes: success is
# decided from the reply's facts rather than from `created`, and a fresh branch
# name already on the remote is refused. See harness.sh.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/harness.sh"

run_js_scenarios <<'JS_EOF'
const VERSION = /const PIPELINE_VERSION = '([^']+)'/.exec(src)[1]
const ROOT = '/work/repo'
const WT = `${ROOT}/.claude/worktrees/gh-21-stub`
const P = 'a1b2c3d4e5f60718293a4b5c6d7e8f9012345678'

function prepared(over) {
  return {
    repo_root: ROOT, worktree: WT, branch: 'feat/gh-21-stub', base: 'main', ticket: '21',
    ticket_marker: 'gh-21', mode: 'fresh', worktree_action: 'created', detail: 'cut it',
    markers: { crap_gated: true, mutation_gated: false },
    plugin: { name: 'touchstone', version: VERSION },
    base_manifest: { found: true, refreshed: true, name: 'touchstone', version: VERSION, detail: 'read' },
    checks_source: { file: `${WT}/AGENTS.md`, sections: [{ heading: '## Other', fence: '' }], detail: 'read' },
    prior_head: null, prior_head_check: null,
    ...over,
  }
}
const quiet = { initialReview: { correctness: [], advocate: [] }, verify: () => undefined, staleness: () => [] }

async function scenarioPA() {
  console.log('\n== scenario PA: prepared args skip the branch dispatch and setup asks only for the ticket')
  const { result, captured } = await run({ args: { prepared: prepared() }, ...quiet })
  check('no branch agent ran', callCount(captured, 'branch') + callCount(captured, 'branch:existing'), 0)
  check('setup still ran once, for the ticket', callCount(captured, 'setup'), 1)
  const setup = captured.calls.find(c => c.label === 'setup')
  check('setup does not read the manifest', setup.prompt.includes('plugin.json'), false)
  check('setup does not test the markers', setup.prompt.includes('.crap-gated'), false)
  check('setup still fetches the ticket', setup.prompt.includes('gh issue view'), true)
  check('setup asks for the ticket alone', Object.keys(setup.schema.properties), ['ticket'])
  check('the run is not halted', result.halted_at, undefined)
  check('the run carries the prepared branch', result.branch, 'feat/gh-21-stub')
  const impl = captured.calls.find(c => c.label === 'implementer')?.prompt ?? ''
  check('the implementer works in the prepared worktree', impl.includes(`Repo worktree: ${WT}\n`), true)
  check('the log names the prepared worktree',
    captured.logs.includes(`worktree ${WT} created for branch feat/gh-21-stub (base main)`), true)
}

async function scenarioPB() {
  console.log('\n== scenario PB: the prepared markers decide the mutation phase')
  const off = await run({ args: { prepared: prepared() }, ...quiet })
  check('mutation_gated false skips mutation', callCount(off.captured, 'mutation:1'), 0)
  const on = await run({ args: { prepared: prepared({ markers: { crap_gated: false, mutation_gated: true } }) },
    mutationGated: false, ...quiet })
  check('mutation_gated true runs mutation, whatever setup says', callCount(on.captured, 'mutation:1'), 1)
}

async function scenarioPC() {
  console.log('\n== scenario PC: the prepared base manifest decides pipeline_version')
  const same = await run({ args: { prepared: prepared() }, ...quiet })
  check('agreement', same.result.pipeline_version,
    { executed: VERSION, base_branch: VERSION, mismatch: false, base_refreshed: true })
  const drift = await run({ args: { prepared: prepared({ base_manifest: { found: true, refreshed: false,
    name: 'touchstone', version: '0.1.0', detail: 'stale' } }) }, ...quiet })
  check('drift', drift.result.pipeline_version,
    { executed: VERSION, base_branch: '0.1.0', mismatch: true, base_refreshed: false })
  const none = await run({ args: { prepared: prepared({ base_manifest: { found: false, refreshed: true,
    name: '', version: '', detail: 'no manifest' } }) }, ...quiet })
  check('no manifest leaves it uncompared', none.result.pipeline_version.mismatch, null)
}

async function scenarioPD() {
  console.log('\n== scenario PD: the prepared checks_source is what the checks come from')
  const { result, captured } = await run({ args: { prepared: prepared({ checks_source: { file: `${WT}/AGENTS.md`,
    sections: [{ heading: '## Checks', fence: '```\nmake test\n```' }], detail: 'read' } }) }, ...quiet })
  check('one check was discovered', result.checks?.discovered, 1)
  const runner = captured.calls.find(c => c.label.startsWith('checks:run:'))?.prompt ?? ''
  check('the checks runner runs it', runner.includes('make test'), true)
}

async function scenarioPE() {
  console.log('\n== scenario PE: an existing prepared run resumes from the head its check confirmed')
  const ok = await run({ args: { existingBranch: true, priorRun: { reviewed_through: P },
    prepared: prepared({ mode: 'existing', worktree_action: 'reused', prior_head: P,
      prior_head_check: 'TOUCHSTONE_PRIOR_HEAD_LINEAR 0' }) }, ...quiet })
  check('no branch:existing agent ran', callCount(ok.captured, 'branch:existing'), 0)
  check('it resumes from the prior head', ok.captured.logs.some(l => l.startsWith(`resuming from reviewed head ${P}`)), true)
  const other = await run({ args: { existingBranch: true, priorRun: { reviewed_through: P },
    prepared: prepared({ mode: 'existing', worktree_action: 'reattached', prior_head: 'b'.repeat(40),
      prior_head_check: 'TOUCHSTONE_PRIOR_HEAD_LINEAR 0' }) }, ...quiet })
  check('a check of another head is not used',
    other.captured.logs.some(l => l.startsWith(`reviewed head ${P} is not confirmed`)), true)
  check('the log says the worktree was reused',
    other.captured.logs.includes(`worktree ${WT} reused for branch feat/gh-21-stub (base main)`), true)
}

async function scenarioPF() {
  console.log('\n== scenario PF: a 40-hex base and a matching args.base are accepted')
  const sha = await run({ args: { prepared: prepared({ base: 'c'.repeat(40) }) }, ...quiet })
  check('40-hex base accepted', sha.result.halted_at, undefined)
  const stacked = await run({ args: { base: 'feat/gh-20-parent', prepared: prepared({ base: 'feat/gh-20-parent' }) }, ...quiet })
  check('matching override accepted', stacked.result.halted_at, undefined)
  const jira = await run({ args: { ticket: 'proj-7', prepared: prepared({ ticket: 'proj-7', ticket_marker: 'jira-PROJ-7',
    worktree: `${ROOT}/.claude/worktrees/jira-PROJ-7-x`, branch: 'fix/jira-PROJ-7-x',
    checks_source: { file: '', sections: [], detail: 'none' } }) }, ...quiet })
  check('a jira marker is accepted', jira.result.halted_at, undefined)
}

const MALFORMED = [
  ['not an object', 'prepared', 'nope'],
  ['an array', 'prepared', []],
  ['relative repo_root', 'repo_root', prepared({ repo_root: 'work/repo' })],
  ['repo_root with a trailing slash', 'repo_root', prepared({ repo_root: `${ROOT}/` })],
  ['worktree outside .claude/worktrees', 'worktree', prepared({ worktree: '/tmp/gh-21-stub' })],
  ['worktree nested below it', 'worktree', prepared({ worktree: `${ROOT}/.claude/worktrees/x/gh-21-stub` })],
  ['worktree under another repo', 'worktree', prepared({ worktree: '/other/.claude/worktrees/gh-21-stub' })],
  ['worktree without the marker', 'worktree', prepared({ worktree: `${ROOT}/.claude/worktrees/gh-22-stub` })],
  ['worktree climbing out', 'worktree', prepared({ worktree: `${ROOT}/.claude/worktrees/gh-21-../x` })],
  ['branch without the marker', 'branch', prepared({ branch: 'feat/gh-22-stub' })],
  ['branch sharing only a prefix', 'branch', prepared({ branch: 'feat/gh-210-stub' })],
  ['branch without a type', 'branch', prepared({ branch: 'gh-21-stub' })],
  ['branch with a space', 'branch', prepared({ branch: 'feat/gh-21-a b' })],
  ['empty base', 'base', prepared({ base: '' })],
  ['base with ..', 'base', prepared({ base: 'main..x' })],
  ['base starting with -', 'base', prepared({ base: '-main' })],
  ['base not args.base', 'base', prepared({ base: 'main' }), { base: 'feat/gh-20-parent' }],
  ['wrong ticket_marker', 'ticket_marker', prepared({ ticket_marker: 'gh-22' })],
  ['existing mode on a fresh run', 'mode', prepared({ mode: 'existing', worktree_action: 'reused' })],
  ['fresh mode on an existing run', 'mode', prepared(), { existingBranch: true }],
  ['reused on a fresh run', 'worktree_action', prepared({ worktree_action: 'reused' })],
  ['created on an existing run', 'worktree_action',
    prepared({ mode: 'existing', worktree_action: 'created' }), { existingBranch: true }],
  ['detail not a string', 'detail', prepared({ detail: 3 })],
  ['markers missing', 'markers', prepared({ markers: null })],
  ['crap_gated not boolean', 'markers', prepared({ markers: { crap_gated: 'true', mutation_gated: false } })],
  ['mutation_gated missing', 'markers', prepared({ markers: { crap_gated: true } })],
  ['plugin from another name', 'plugin', prepared({ plugin: { name: 'other', version: VERSION } })],
  ['plugin from another version', 'plugin', prepared({ plugin: { name: 'touchstone', version: '0.0.1' } })],
  ['base_manifest found not boolean', 'base_manifest',
    prepared({ base_manifest: { found: 1, refreshed: true, name: '', version: '', detail: '' } })],
  ['base_manifest version missing', 'base_manifest',
    prepared({ base_manifest: { found: true, refreshed: true, name: 'touchstone', detail: '' } })],
  ['base_manifest refreshed missing', 'base_manifest',
    prepared({ base_manifest: { found: true, name: 'touchstone', version: VERSION, detail: '' } })],
  ['checks_source sections not an array', 'checks_source',
    prepared({ checks_source: { file: '', sections: 'x', detail: '' } })],
  ['checks_source heading without ##', 'checks_source',
    prepared({ checks_source: { file: `${WT}/AGENTS.md`, sections: [{ heading: '# Checks', fence: '' }], detail: '' } })],
  ['checks_source fence not a string', 'checks_source',
    prepared({ checks_source: { file: `${WT}/AGENTS.md`, sections: [{ heading: '## Checks', fence: null }], detail: '' } })],
  ['checks_source file outside the worktree', 'checks_source',
    prepared({ checks_source: { file: '/elsewhere/AGENTS.md', sections: [], detail: '' } })],
  ['checks_source detail missing', 'checks_source',
    prepared({ checks_source: { file: '', sections: [] } })],
  ['prior_head not a sha', 'prior_head', prepared({ prior_head: 'abc' })],
  ['prior_head_check not the line', 'prior_head_check', prepared({ prior_head: P, prior_head_check: 'ok' })],
  ['prior_head_check without a head', 'prior_head_check',
    prepared({ prior_head_check: 'TOUCHSTONE_PRIOR_HEAD_LINEAR 0' })],
]

async function scenarioPG() {
  console.log('\n== scenario PG: each malformed field halts before anything is dispatched')
  for (const [what, field, value, args] of MALFORMED) {
    const { result, captured } = await run({ args: { prepared: value, ...args }, ...quiet })
    check(`${what}: halts at Worktree`, result.halted_at, 'Worktree')
    check(`${what}: the note names ${field}`, String(result.note).includes(`args.prepared${field === 'prepared' ? '' : `.${field}`}`), true)
    check(`${what}: nothing was dispatched`, captured.calls.length, 0)
  }
  const { result } = await run({ args: { prepared: prepared({ branch: 'feat/gh-22-stub' }) }, ...quiet })
  check('the note says to re-run prepare-delivery.sh', result.note.includes('prepare-delivery.sh'), true)
}

async function scenarioPH() {
  console.log('\n== scenario PH (gh-156): created=false with a found, clean, marked worktree proceeds')
  const { result, captured } = await run({
    args: { existingBranch: true },
    existingBranchResult: { created: false, halt_reason: 'none', dirty: false, branch: 'feat/gh-21-stub',
      base: 'main', path: '/tmp/wt/gh-21-stub', ticket: '21', detail: 'Found existing worktree' },
    ...quiet,
  })
  check('the run does not halt at Worktree', result.halted_at === 'Worktree', false)
  check('the implementer ran', callCount(captured, 'implementer'), 1)
  check('the run carries the found branch', result.branch, 'feat/gh-21-stub')
}

async function scenarioPI() {
  console.log('\n== scenario PI (gh-156): replies whose facts do not hold still halt')
  const cases = [
    ['an empty path', { created: false, halt_reason: 'none', dirty: false, branch: 'feat/gh-21-stub', path: '' }],
    ['an unmarked branch', { created: false, halt_reason: 'none', dirty: false, branch: 'feat/other', path: '/tmp/wt/gh-21-stub' }],
    ['an unmarked path', { created: false, halt_reason: 'none', dirty: false, branch: 'feat/gh-21-stub', path: '/tmp/wt/other' }],
    ['a prefix-only marker', { created: false, halt_reason: 'none', dirty: false, branch: 'feat/gh-210-x', path: '/tmp/wt/gh-210-x' }],
    ['a dirty tree', { created: true, halt_reason: 'none', dirty: true, branch: 'feat/gh-21-stub', path: '/tmp/wt/gh-21-stub' }],
    ['a halt reason', { created: true, halt_reason: 'ambiguous', dirty: false, branch: 'feat/gh-21-stub', path: '/tmp/wt/gh-21-stub' }],
    ['created with no path', { created: true, halt_reason: 'none', dirty: false, branch: 'feat/gh-21-stub', path: '' }],
  ]
  for (const [what, reply] of cases) {
    const { result } = await run({ args: { existingBranch: true },
      existingBranchResult: { base: 'main', ticket: '21', detail: 'stub', ...reply }, ...quiet })
    check(`${what}: halts at Worktree`, result.halted_at, 'Worktree')
  }
}

async function scenarioPJ() {
  console.log('\n== scenario PJ (gh-152): the fresh branch prompt refuses a name already on the remote')
  const { captured } = await run({ ...quiet })
  const p = captured.calls.find(c => c.label === 'branch')?.prompt ?? ''
  check('the prompt runs ls-remote on the name', p.includes('git ls-remote --heads origin <name>'), true)
  check('the prompt says to return remote-exists', p.includes('halt_reason=remote-exists'), true)
  check('the schema allows that halt reason',
    captured.calls.find(c => c.label === 'branch').schema.properties.halt_reason.enum, ['none', 'remote-exists'])
  const { result } = await run({ branchResult: { created: false, halt_reason: 'remote-exists', dirty: false,
    branch: 'feat/gh-21-stub', base: 'main', path: '', ticket: '21', detail: 'origin has feat/gh-21-stub' }, ...quiet })
  check('a remote collision halts at Worktree', result.halted_at, 'Worktree')
  check('the note names the collision', result.note.includes('already exists on origin'), true)
  check('the note carries the detail', result.note.includes('origin has feat/gh-21-stub'), true)
}

const SCENARIOS = [scenarioPA, scenarioPB, scenarioPC, scenarioPD, scenarioPE, scenarioPF, scenarioPG,
  scenarioPH, scenarioPI, scenarioPJ]
JS_EOF

DELIVER_MD="$REPO_ROOT/commands/deliver.md"
echo ""
echo "== static: commands/deliver.md runs prepare-delivery.sh and passes its JSON as prepared"
check "deliver.md names the shipped script" \
  "$(grep -Fc '${CLAUDE_PLUGIN_ROOT}/skills/crap-controlled-changes/prepare-delivery.sh' "$DELIVER_MD")" 1
check "deliver.md passes the output as prepared" \
  "$(grep -Fc 'pass the printed JSON unchanged as `prepared`' "$DELIVER_MD")" 1
check "deliver.md stops on a refusal" \
  "$(grep -Fc 'report both verbatim and stop.' "$DELIVER_MD")" 1
check "deliver.md derives the slug from the ticket title" \
  "$(grep -Fc 'Derive the slug from it: lowercase,' "$DELIVER_MD")" 1

finish
