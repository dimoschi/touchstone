#!/usr/bin/env bash
# Regression test for ticket 101: a delivery run can execute an older
# deliver-pipeline.js than the one on main, and nothing said so. PLUGIN_NAME
# and PIPELINE_VERSION are literals (the script has no fs to read
# .claude-plugin/plugin.json at runtime), checked against the manifest by
# scripts/check-version-bump.sh (scripts/test-version-bump.sh covers that
# half). This file covers the runtime half: the version half of the merged
# setup call (gh-118 folded the old standalone plugin:version probe into it)
# resolves the repository's actual base branch itself, never wt.base or
# baseOverride (both undefined at that point anyway, since setup runs before
# any worktree exists), fetches that base fresh, then reads its manifest
# once before Worktree, and every exit path -- a halt at Worktree, a halt at
# any later phase, and normal completion -- carries a `pipeline_version`
# object reporting what it found.
#
# Checked:
#   1. Static: the two literals and the MANIFEST_PROBE schema exist, the
#      merged setup call is labelled setup and embeds MANIFEST_PROBE as its
#      version sub-object, and both the halt payload and the final result
#      carry pipeline_version.
#   2. Dynamic, against the real script under stubbed globals: a halt at
#      Worktree still carries `executed` with the other two fields null (the
#      default stub's found:false), even though setup -- and so the version
#      half -- already ran before Worktree, unlike before gh-118.
#   3. Dynamic: a probe reporting this plugin's name with a different version
#      sets mismatch=true, base_branch to that version, logs a line naming
#      both versions, and the run reaches PR rather than halting.
#   4. Dynamic: a probe reporting this plugin's name with the same version
#      sets mismatch=false, not null -- a confirmed match is a real answer.
#   5. Dynamic: a probe reporting no manifest, or a different plugin's name,
#      reports base_branch=null, mismatch=null, and no halt, but logs a
#      diagnostic line either way: the ordinary case for every repo but
#      touchstone's own, still worth a line distinguishing it from check 6.
#   6. Dynamic: a probe returning nothing at all also reports base_branch=null,
#      mismatch=null, but logs a line saying the probe did not respond, so
#      that silent non-comparison is never indistinguishable from the
#      ordinary one in check 5.
#   7. Static: the setup prompt resolves and fetches the repository's base
#      branch itself rather than trusting wt.base or baseOverride, neither of
#      which exists yet at this point in the run.
#   8. Static: a failed fetch is not by itself instructed to read as a missing
#      manifest -- the probe is told to attempt the read regardless, since
#      origin/<base> can already be populated from an earlier fetch or the
#      initial clone.
#
# Needs node. Exit 0 all green, 1 any assertion failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/workflows/deliver-pipeline.js"

failures=0

check() {
  local label="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then
    echo "  ok:   $label ($got)"
  else
    echo "  FAIL: $label (got $got, want $want)"
    failures=$((failures + 1))
  fi
}

echo "== static: the two literals and the schema exist"
check "PLUGIN_NAME literal, single-quoted" \
  "$(grep -Ec "^const PLUGIN_NAME = '[^']*'$" "$SCRIPT" || true)" 1
check "PIPELINE_VERSION literal, single-quoted" \
  "$(grep -Ec "^const PIPELINE_VERSION = '[^']*'$" "$SCRIPT" || true)" 1
check "MANIFEST_PROBE schema declared" \
  "$(grep -Fc 'const MANIFEST_PROBE = {' "$SCRIPT" || true)" 1
check "the version probe is folded into the merged setup call" \
  "$(grep -Fc "label: 'setup'" "$SCRIPT" || true)" 1
check "SETUP embeds MANIFEST_PROBE as its version sub-object" \
  "$(grep -Fc 'version: MANIFEST_PROBE' "$SCRIPT" || true)" 1

echo "== static: pipeline_version reaches both a halt and the final result"
check "pipeline_version: pipelineVersion appears in halted()'s payload and the final result" \
  "$(grep -Fc 'pipeline_version: pipelineVersion' "$SCRIPT" || true)" 2

echo "== static: the setup call resolves its own base rather than trusting wt.base or baseOverride"
PROBE_BLOCK="$(awk '/const setupResult = await dispatch/,/label: .setup./' "$SCRIPT")"
check "the setup prompt never interpolates wt.base" \
  "$(printf '%s' "$PROBE_BLOCK" | grep -Fc 'wt.base' || true)" 0
check "the setup prompt never interpolates baseOverride" \
  "$(printf '%s' "$PROBE_BLOCK" | grep -Fc 'baseOverride' || true)" 0
check "the version half resolves the base itself off the remote HEAD" \
  "$(printf '%s' "$PROBE_BLOCK" | grep -Fc 'symbolic-ref' || true)" 1
check "the version half fetches the resolved base before reading it" \
  "$(printf '%s' "$PROBE_BLOCK" | grep -Fc 'fetch origin' || true)" 1
check "a failed fetch is not listed as its own found=false cause" \
  "$(printf '%s' "$PROBE_BLOCK" | grep -Fc 'the fetch fails,' || true)" 0
check "the version half is told to read the manifest even when the fetch fails" \
  "$(printf '%s' "$PROBE_BLOCK" | grep -Fc 'read it anyway' || true)" 1

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/harness.mjs" <<'JS_EOF'
import fs from 'node:fs'
import vm from 'node:vm'

const SCRIPT_PATH = process.argv[2]
const src = fs.readFileSync(SCRIPT_PATH, 'utf8')
const body = 'return (async () => {\n' +
  src.replace(/^export const meta/m, 'const meta') + '\n})();'

const SCRIPT_PLUGIN_NAME = /^const PLUGIN_NAME = '([^']*)'/m.exec(src)?.[1]
const SCRIPT_PIPELINE_VERSION = /^const PIPELINE_VERSION = '([^']*)'/m.exec(src)?.[1]

let failures = 0
function check(label, got, want) {
  const gotStr = JSON.stringify(got)
  const wantStr = JSON.stringify(want)
  if (gotStr === wantStr) {
    console.log(`  ok:   ${label} (${gotStr})`)
  } else {
    console.log(`  FAIL: ${label} (got ${gotStr}, want ${wantStr})`)
    failures++
  }
}

function baseArgs(overrides) {
  return {
    ticket: '101',
    task: 'test task for pipeline_version transparency',
    record: false,
    maxReviewRounds: 3,
    maxGateAttempts: 1,
    reviewers: 0,
    ...overrides,
  }
}

// The default diffstat every scenario here gets unless it overrides one:
// small enough that lensKeysFor would pick a lens, irrelevant since
// args.reviewers: 0 always slices the lens list to nothing, but it still has
// to parse cleanly or Review halts on a measurement problem before any of
// these scenarios reach Draft PR/PR at all.
const DEFAULT_DIFFSTAT_BODY = '5\t0\ta.js\nTOUCHSTONE_COMMENT_LINES\nTOUCHSTONE_DIFFSTAT_END'

function makeAgent(scenario, captured) {
  const responses = scenario.responses ?? {}
  return async (prompt, opts) => {
    const label = opts.label
    captured.calls.push({ label, prompt })

    if (Object.prototype.hasOwnProperty.call(responses, label)) {
      return responses[label]
    }
    // Replaces the old separate ticket/plugin:version/gate:opt-in dispatches
    // (gh-118): one call, before any worktree exists, answers all three.
    if (label === 'setup') {
      captured.versionProbeCalled = true
      // ?? would replace an explicit `versionProbe: null` (the "probe
      // returned nothing" scenario) with this default, indistinguishable
      // from never overriding it at all: check the key itself, not its value.
      const version = Object.prototype.hasOwnProperty.call(scenario, 'versionProbe')
        ? scenario.versionProbe
        : { found: false, name: '', version: '', detail: 'stub' }
      return {
        ticket: { found: true, summary: 'stub ticket', description: 'd', comments: '' },
        version,
        markers: { crap_gated: true, mutation_gated: true, detail: 'stub' },
      }
    }
    if (label === 'branch') {
      return scenario.branchResult ??
        { created: true, branch: 'feat/gh-101-stub', base: 'main',
          path: '/stub-worktree', ticket: '101', detail: 'stub',
          checks_source: { file: '', sections: [], detail: 'stub: no repo checks' } }
    }
    if (label === 'triage') {
      return scenario.triage ??
        { scope: 'inline', complexity: 'trivial', expected_files: [], complexity_note: 'stub',
          premise_ok: true, estimated_loc: 5, evidence: [], premise_note: 'stub' }
    }
    if (label === 'implementer') {
      return scenario.implementer ??
        { summary: 'implemented the feature', files_changed: ['a.js'],
          commit_range: 'base00000000000000000000000000000000000000..impl0000000000000000000000000000000000000',
          scored: true }
    }
    if (label === 'draft-pr') {
      captured.draftPrCalled = true
      const range = scenario.implementer?.commit_range ??
        'base00000000000000000000000000000000000000..impl0000000000000000000000000000000000000'
      return scenario.draftPr ?? { opened: true, url: 'https://example.test/pr/1', number: 1, detail: 'stub',
        diffstat: `TOUCHSTONE_DIFFSTAT ${range}\n${DEFAULT_DIFFSTAT_BODY}` }
    }
    if (label.startsWith('mutation:')) {
      return scenario.mutationResult ??
        { green: true, head_sha: 'impl0000000000000000000000000000000000000',
          detail: 'stub', scored: true }
    }
    if (label === 'pr') {
      captured.prCalled = true
      return scenario.prResult ?? { opened: true, url: 'https://example.test/pr/1', note: 'stub' }
    }
    if (label.startsWith('review:') || label.startsWith('fix:') || label.startsWith('verify:')) {
      throw new Error(`${label} must not run with reviewers: 0`)
    }
    if (['ticket', 'plugin:version', 'gate:opt-in', 'checks:discover', 'run-record'].includes(label)) {
      throw new Error(`agent '${label}' should no longer be dispatched (folded into setup/branch, or dropped)`)
    }
    throw new Error(`unstubbed agent label in test scenario: ${label}`)
  }
}

async function run(scenario) {
  const captured = { calls: [], logs: [], versionProbeCalled: false, draftPrCalled: false, prCalled: false }
  const sandbox = {
    args: baseArgs(scenario.args),
    agent: makeAgent(scenario, captured),
    parallel: (thunks) => Promise.all(thunks.map(async (t) => {
      try {
        const r = await t()
        return r === undefined ? undefined : JSON.parse(JSON.stringify(r))
      } catch { return null }
    })),
    pipeline: async () => { throw new Error('pipeline() not stubbed for this test') },
    workflow: async () => { throw new Error('workflow() not stubbed for this test') },
    phase: () => {},
    log: (m) => captured.logs.push(m),
    budget: { total: null, spent: () => 0, remaining: () => Infinity },
  }
  const ctx = vm.createContext(sandbox)
  const fn = vm.compileFunction(body, [], { parsingContext: ctx })
  const result = await fn()
  return { result, captured }
}

async function scenarioWorktreeHaltCarriesExecuted() {
  console.log('\n== scenario: a halt at Worktree still carries executed, even though setup (and the version half) already ran')
  const { result, captured } = await run({
    branchResult: { created: false, branch: '', base: '', path: '', detail: 'no base branch found' },
  })
  check('halted at Worktree', result.halted_at, 'Worktree')
  // Unlike before gh-118: setup runs before Worktree, so it has already run
  // by the time a branch-creation failure halts here.
  check('setup (and so the version half) already ran', captured.versionProbeCalled, true)
  check('executed is the script\'s own literal', result.pipeline_version?.executed, SCRIPT_PIPELINE_VERSION)
  check('base_branch is null', result.pipeline_version?.base_branch, null)
  check('mismatch is null', result.pipeline_version?.mismatch, null)
  // The script no longer writes its own record; it only names where one
  // belongs, on every exit path including this halt.
  check('a record_file is still named even on a halt', typeof result.record_file, 'string')
}

async function scenarioDefaultProbeCompletesNormally() {
  console.log('\n== scenario: the default stubbed probe (found:false) completes normally with no alarm')
  const { result, captured } = await run({})
  check('no halt', result.halted_at, undefined)
  check('the probe ran', captured.versionProbeCalled, true)
  check('the PR phase ran', captured.prCalled, true)
  check('executed is the script\'s own literal', result.pipeline_version?.executed, SCRIPT_PIPELINE_VERSION)
  check('base_branch is null', result.pipeline_version?.base_branch, null)
  check('mismatch is null', result.pipeline_version?.mismatch, null)
  check('no log line mentions a version mismatch',
    captured.logs.some(m => /working|mismatch|drift/i.test(m)), false)
}

async function scenarioMismatchLogsAndContinues() {
  console.log('\n== scenario: a version drift is reported and logged, but never halts')
  // No ordering word in the fixture itself: the direction assertion below
  // greps the log line, and a version string carrying one would fake it.
  const drifted = '9.9.9'
  const { result, captured } = await run({
    versionProbe: { found: true, name: SCRIPT_PLUGIN_NAME, version: drifted, detail: 'stub' },
  })
  check('no halt', result.halted_at, undefined)
  check('the PR phase ran', captured.prCalled, true)
  check('mismatch is true', result.pipeline_version?.mismatch, true)
  check('base_branch is the drifted version', result.pipeline_version?.base_branch, drifted)
  check('executed is unchanged', result.pipeline_version?.executed, SCRIPT_PIPELINE_VERSION)
  check('a log line names both versions', captured.logs.some(
    m => m.includes(SCRIPT_PIPELINE_VERSION) && m.includes(drifted)), true)
  // The executed snapshot can legitimately be the newer of the two, so the
  // line may not imply the base moved ahead of it.
  check('no log line claims which version is ahead', captured.logs.some(
    m => /is now at|newer|older|ahead|behind|stale snapshot/i.test(m)), false)
}

async function scenarioExactMatchIsFalseNotNull() {
  console.log('\n== scenario: a probe confirming an exact match reports mismatch=false, not null')
  const { result } = await run({
    versionProbe: { found: true, name: SCRIPT_PLUGIN_NAME, version: SCRIPT_PIPELINE_VERSION, detail: 'stub' },
  })
  check('no halt', result.halted_at, undefined)
  check('mismatch is false', result.pipeline_version?.mismatch, false)
  check('base_branch equals executed', result.pipeline_version?.base_branch, SCRIPT_PIPELINE_VERSION)
}

async function scenarioOtherPluginIsNullNotFalse() {
  console.log('\n== scenario: a manifest for a different plugin reports null, the ordinary case for every consumer repo')
  const { result, captured } = await run({
    versionProbe: { found: true, name: 'some-other-plugin', version: '9.9.9', detail: 'stub' },
  })
  check('no halt', result.halted_at, undefined)
  check('base_branch is null', result.pipeline_version?.base_branch, null)
  check('mismatch is null', result.pipeline_version?.mismatch, null)
  check('no log line mentions a version mismatch',
    captured.logs.some(m => /working|mismatch|drift/i.test(m)), false)
  check('a diagnostic log line still names the uncomparable manifest',
    captured.logs.some(m => m.includes('some-other-plugin') || /no comparable manifest/i.test(m)), true)
}

async function scenarioNoManifestFoundIsNull() {
  console.log('\n== scenario: found:false reports null, same as no manifest at all')
  const { result, captured } = await run({
    versionProbe: { found: false, name: '', version: '', detail: 'no .claude-plugin/plugin.json here' },
  })
  check('no halt', result.halted_at, undefined)
  check('base_branch is null', result.pipeline_version?.base_branch, null)
  check('mismatch is null', result.pipeline_version?.mismatch, null)
  check('a diagnostic log line reports what the probe found instead',
    captured.logs.some(m => /no comparable manifest/i.test(m)), true)
}

// Asserts the prompt the runtime actually receives. The static grep above
// can only see the prompt literal, so it stays green while a future change
// hands the setup call a stacked base some other way.
async function scenarioProbeNeverSeesTheStackedBase() {
  console.log('\n== scenario: the composed setup prompt never carries a stacked base')
  const stacked = 'feat/gh-100-a-stacked-branch'
  const { captured } = await run({
    args: { base: stacked },
  })
  const probe = captured.calls.find(c => c.label === 'setup')?.prompt ?? ''
  check('the setup call was prompted at all', probe.length > 0, true)
  check('the composed prompt never names the stacked base', probe.includes(stacked), false)
}

// The fetch exists so a stale remote-tracking ref cannot pass as an agreement.
// Reading an unrefreshed ref anyway is the right call, but only if the run says
// it did: otherwise this is the silent mismatch:false the fetch was added for.
async function scenarioUnrefreshedBaseIsReportedNotSilent() {
  console.log('\n== scenario: a base read from an unrefreshed ref is reported, even when the versions agree')
  const { result, captured } = await run({
    versionProbe: { found: true, name: SCRIPT_PLUGIN_NAME, version: SCRIPT_PIPELINE_VERSION,
                    refreshed: false, detail: 'fetch failed: no network' },
  })
  check('no halt', result.halted_at, undefined)
  check('mismatch is still false', result.pipeline_version?.mismatch, false)
  check('the result records that the base was never refreshed',
    result.pipeline_version?.base_refreshed, false)
  check('a log line says the comparison may be stale',
    captured.logs.some(m => /could not refresh|unrefreshed|stale/i.test(m)
      && /may predate|stale/i.test(m)), true)
}

async function scenarioProbeReturningNothingIsNull() {
  console.log('\n== scenario: the probe returning nothing at all reports null, not a crash, but logs that the comparison did not run')
  const { result, captured } = await run({ versionProbe: null })
  check('no halt', result.halted_at, undefined)
  check('base_branch is null', result.pipeline_version?.base_branch, null)
  check('mismatch is null', result.pipeline_version?.mismatch, null)
  check('a log line reports the probe returned nothing',
    captured.logs.some(m => /plugin:version|returned nothing/i.test(m)), true)
}

async function main() {
  await scenarioWorktreeHaltCarriesExecuted()
  await scenarioDefaultProbeCompletesNormally()
  await scenarioMismatchLogsAndContinues()
  await scenarioExactMatchIsFalseNotNull()
  await scenarioOtherPluginIsNullNotFalse()
  await scenarioNoManifestFoundIsNull()
  await scenarioProbeReturningNothingIsNull()
  await scenarioProbeNeverSeesTheStackedBase()
  await scenarioUnrefreshedBaseIsReportedNotSilent()
  if (failures) { console.log(`\nFAILED: ${failures} assertion(s)`); process.exit(1) }
  console.log('\nOK (pipeline-version harness)')
}
main()
JS_EOF

node "$WORK/harness.mjs" "$SCRIPT"
harness_status=$?
if [ "$harness_status" -ne 0 ]; then
  failures=$((failures + 1))
fi

echo ""
if [ "$failures" -eq 0 ]; then
  echo "OK"
else
  echo "FAILED: $failures assertion(s)"
  exit 1
fi
