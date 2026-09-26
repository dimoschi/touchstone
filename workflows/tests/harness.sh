#!/usr/bin/env bash
# Shared harness for workflows/tests/test-*.sh, sourced by each. Split out of
# a single 4651-line test-fix-loop-join.sh (gh-118) so each area stays under
# about 800 lines; behaviour and assertions are unchanged from that file.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
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

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The JS prelude every scenario file shares: imports, run(), makeAgent(), the
# checkInvocation/defaultFinding/reproduceResponse helpers, and the three
# cross-group scenario-builder helpers (convergedWithSuspect, lateFinding,
# overlapsWithExecutor). Verbatim from the pre-split test-fix-loop-join.sh.
JS_PRELUDE="$(cat <<'JS_PRELUDE_EOF'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import vm from 'node:vm'
import { execFileSync, spawnSync } from 'node:child_process'

const SCRIPT_PATH = process.argv[2]
const src = fs.readFileSync(SCRIPT_PATH, 'utf8')
const body = 'return (async () => {\n' +
  src.replace(/^export const meta/m, 'const meta') + '\n})();'

const COMMIT_RANGE =
  'base00000000000000000000000000000000000000..head00000000000000000000000000000000000001'
const REVIEWED_THROUGH = COMMIT_RANGE.split('..')[1]

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
    ticket: '21',
    task: 'test task for the fix-loop verdict join',
    record: false,
    openPr: false,
    maxReviewRounds: 3,
    maxGateAttempts: 1,
    ...overrides,
  }
}

// Pulls every [fN] token out of a prompt, in the order they appear -- how the
// reproduce and staleness stubs learn which ids the script actually assigned,
// without the scenario needing to predict them.
function idsIn(prompt) {
  return [...prompt.matchAll(/\[(f\d+)\]/g)].map(m => m[1])
}

// baseArgs()'s branch/branch:existing defaults both put the worktree here.
const STUB_WT_PATH = '/tmp/stub-worktree'

// The exact Bash invocation deliver-pipeline.js's own invocationFor builds
// for a check, id included since the trailing echo names it. A checkRuns
// stub uses this so a scenario testing the happy path does not have to
// duplicate the string, and a scenario testing the command-mismatch path can
// diverge from it on purpose. Mirrors the production shQuote's bare-vs-quoted
// split so the ~50 scenarios that use this for an unrelated behaviour (the
// fix-loop join, not quoting) keep matching STUB_WT_PATH, which is itself
// bare; scenario EM below asserts the literal production output directly
// instead of trusting this copy.
function shQuote(s) {
  const str = String(s)
  return /^[A-Za-z0-9/._+:@%=,-]+$/.test(str) ? str : `'${str.replace(/'/g, `'\\''`)}'`
}
const CHECK_EXIT_MARKER = 'TOUCHSTONE_CHECK_EXIT'
function checkInvocation(id, command, path = STUB_WT_PATH) {
  return `o=$(mktemp); bash -c ${shQuote(`cd ${shQuote(path)} && ${command}`)} >"$o" 2>&1; ` +
    `echo "${CHECK_EXIT_MARKER} ${id} $?"; tail -c 8192 "$o"; rm -f "$o"`
}
// A checkRuns stub's row for the common case: the command matches what was
// declared, and the output carries the one well-formed exit line a row now
// needs to be measured at all, rather than retried and then halted on.
function checkRow(id, command, exit, output) {
  return { id, command: checkInvocation(id, command), exit_code: exit,
    output: `${CHECK_EXIT_MARKER} ${id} ${exit}\n${output}` }
}

// Every finding literal in this file predates category and reproducer; both
// are now required for a finding to ever open. Filling in a default here
// (overridable per finding, since a scenario testing the category or
// no-reproducer note sets its own) is what lets the other ~50 scenarios,
// about unrelated behaviour, stay unchanged.
function defaultFinding(f) {
  return {
    category: 'wrong-result',
    // Permissive by default: the out-of-range rule is new behaviour, and a
    // scenario not testing it should still open, the same as before this
    // ticket. defaultHunkLines' giant hunk covers line 1 in every file.
    line_start: 1,
    reproducer: { kind: 'command', command: `stub-reproduce:${f.title ?? 'finding'}`,
      expected: 'exit 0', actual: 'exit 1' },
    ...f,
  }
}

// Maps the old boolean-or-undefined verdict shape a scenario's verify()
// returns onto an exit code: true is fixed / does-not-reproduce (0), false or
// no answer at all is still-fails (1) -- exactly what "stays open" meant
// under the old verifier join. A scenario exercising an exact exit code (126,
// 127) or the genuine no-executor-row path returns a number, or the sentinel
// 'norow', instead. `retry` is true only on a label's own ':retry' rerun, so
// a scenario can tell the two calls apart; others ignore the extra argument.
function exitFor(scenario, id, round, retry) {
  if (!scenario.verify) return 1
  const v = scenario.verify(id, round, retry)
  if (v === 'norow') return undefined
  if (typeof v === 'number') return v
  return v === true ? 0 : 1
}

function filesOf(arr) {
  return [...new Set((arr ?? []).map(f => f?.file).filter(Boolean))]
}
// A hunk covering essentially any line number, for every file a scenario's
// tail/post-mutation findings name, unless the scenario supplies its own via
// hunks(round) -- the out-of-range rule is new behaviour this ticket adds,
// so the default has to stay permissive for every scenario that predates it.
function defaultHunkLines(files) {
  return files.flatMap(f => [`+++ b/${f}`, `@@ -1,100000 +1,100000 @@`])
}

// gh-113: a bare nonzero exit no longer counts as a demonstration; the raw
// output also has to carry this marker on a line of its own. Every scenario
// predating gh-113 expects a bare nonzero to open, so reproduceResponse's
// default output below carries it for any exit code that is not 0, 126 or
// 127; a scenario testing the errored (crashed, no marker) path instead
// supplies its own via scenario.outputFor.
const REPRODUCED_MARKER = 'TOUCHSTONE_DEFECT_REPRODUCED'

function reproduceResponse(prompt, scenario, exitFn, hunkLines) {
  const ids = idsIn(prompt)
  const results = []
  for (const id of ids) {
    const code = exitFn(id)
    if (code === undefined) continue // no executor row: not-executed / stays open
    const returnedId = scenario.verifyBracketed ? `[${id}]` : id
    const output = scenario.outputFor
      ? scenario.outputFor(id, code)
      : `stub reproduce output for ${id} (${code})` +
        (code !== 0 && code !== 126 && code !== 127 ? `\n${REPRODUCED_MARKER}` : '')
    results.push({ id: returnedId, exit_code: code, output })
  }
  if (scenario.injectBogusVerdict) {
    results.push({ id: 'f999-not-a-real-finding', exit_code: 0, output: 'bogus' })
  }
  return {
    results,
    dirty: scenario.reproducerDirty === true,
    porcelain: scenario.reproducerDirty ? (scenario.reproducerPorcelain ?? 'M some-file.txt') : '',
    porcelain_before: scenario.porcelainBefore ?? '',
    ...(hunkLines !== undefined ? { diff_lines: hunkLines } : {}),
  }
}

function makeAgent(scenario, captured) {
  return async (prompt, opts) => {
    const label = opts.label
    captured.calls.push({ label, prompt, schema: opts.schema })

    if (label === 'ticket') {
      return scenario.ticketResult ?? { found: true, summary: 'stub ticket', description: 'd', comments: '' }
    }
    if (label === 'branch') {
      return scenario.branchResult ?? { created: true, branch: 'feat/gh-21-stub', base: 'main',
        path: '/tmp/stub-worktree', ticket: '21', detail: 'stub' }
    }
    if (label === 'branch:existing') {
      return scenario.existingBranchResult ?? { created: true, branch: 'feat/gh-21-stub', base: 'main',
        path: '/tmp/stub-worktree', ticket: '21', detail: 'stub' }
    }
    if (label === 'plugin:version') {
      return scenario.versionProbe ?? { found: false, name: '', version: '', detail: 'stub' }
    }
    if (label === 'triage') {
      // scope: 'inline' skips the Plan phase, which this test has no reason
      // to exercise: it is not part of the join this ticket fixes.
      return { scope: 'inline', complexity: 'trivial', complexity_note: 'stub',
        premise_ok: true, estimated_loc: 5, evidence: [], premise_note: 'stub',
        ...(scenario.triage ?? {}) }
    }
    if (label === 'planner') {
      return scenario.plannerResult ?? { plan: 'stub plan', acceptance_criteria: [],
        risky_areas: [], task_demands_implementation: false }
    }
    if (label === 'implementer') {
      return { summary: 'stub implementation', files_changed: scenario.implFilesChanged ?? ['a.js', 'b.js'],
        commit_range: COMMIT_RANGE, insertions: scenario.implInsertions ?? 20, scored: scenario.implScored ?? true,
        ...(scenario.implGateNote ? { gate_note: scenario.implGateNote } : {}) }
    }
    if (label === 'draft-pr') {
      return scenario.draftPr ?? { opened: false, detail: 'no draft in this test' }
    }
    // Opening the PR is the workflow's only write to GitHub. These two labels
    // posted comments on it; throwing rather than stubbing them means any
    // scenario that brings either back fails here, not just the ones whose
    // assertions were written for it.
    if (label.startsWith('halt-notice:') || label === 'regression-notice') {
      throw new Error(`agent '${label}' posts to GitHub; the workflow must not`)
    }
    if (label === 'run-record') {
      captured.runRecordPrompt = prompt
      if (scenario.runRecordFails) return null
      return '/stub/main/.claude/touchstone-runs/21.json'
    }
    if (label === 'review:dedup') {
      captured.dedupPrompt = prompt
      return { groups: scenario.dedupGroups ?? [] }
    }
    if (/^review:fix:\d+:/.test(label)) {
      return { findings: (scenario.tailReview ?? []).map(defaultFinding) }
    }
    if (label.startsWith('review:mutation:')) {
      return { findings: (scenario.postMutationReview ?? []).map(defaultFinding) }
    }
    if (label.startsWith('review:')) {
      const lens = label.slice('review:'.length)
      return { findings: ((scenario.initialReview ?? {})[lens] ?? []).map(defaultFinding) }
    }
    if (label.startsWith('fix:')) {
      const round = Number(label.slice('fix:'.length))
      const head = scenario.fixHead ? scenario.fixHead(round) : REVIEWED_THROUGH
      const scored = scenario.fixScored ? scenario.fixScored(round) : false
      return { head_sha: head, note: `stub fix round ${round}`, scored,
        ...(scenario.gateNote ? { gate_note: scenario.gateNote } : {}) }
    }
    // Replaces the old verify:* / VERDICTS join: whether a finding is fixed,
    // or a fresh candidate opens, now comes from an exit code, never a
    // model's verdict. reproduce:review is the initial classification, one
    // per fix round re-checks what was open and (via hunkLines) hands back
    // that round's diff hunks, :fresh classifies that round's newly raised
    // candidates, and reproduce:mutation / reproduce:residual are the
    // post-mutation and final-head passes. reproduce:review, :fresh and
    // reproduce:mutation:fresh each have a ':retry' twin -- the executor's
    // own rerun of whatever came back with no row -- matched on the full
    // label below (dirtyAt included), then dispatched on the label with any
    // trailing ':retry' stripped, with `retry` passed on to the scenario.
    if (scenario.dirtyAt === label) {
      return { results: [], dirty: true, porcelain: '?? stray-file', porcelain_before: '' }
    }
    const retry = /^reproduce:.+:retry$/.test(label)
    const base = retry ? label.slice(0, -':retry'.length) : label
    if (base === 'reproduce:review') {
      return reproduceResponse(prompt, scenario,
        (id) => scenario.initialExit ? scenario.initialExit(id, retry) : 1)
    }
    if (/^reproduce:fix:\d+:fresh$/.test(base)) {
      const round = Number(base.slice('reproduce:fix:'.length, -':fresh'.length))
      return reproduceResponse(prompt, scenario, (id) => exitFor(scenario, id, round, retry))
    }
    if (/^reproduce:fix:\d+$/.test(base)) {
      const round = Number(base.slice('reproduce:fix:'.length))
      const hunkLines = scenario.hunks ? scenario.hunks(round) : defaultHunkLines(filesOf(scenario.tailReview))
      return reproduceResponse(prompt, scenario, (id) => exitFor(scenario, id, round), hunkLines)
    }
    // Settled findings are re-run at every head the code moves to after they
    // settled. Still fixed (0) unless a scenario says otherwise, so a scenario
    // that never considered settled ids is unaffected by the recheck. No
    // ':retry' twin: a missing row here is a recheck of an already-open or
    // already-settled finding, not a fresh candidate, so it stays as today.
    if (/^reproduce:settled:/.test(base)) {
      const at = base.slice('reproduce:settled:'.length)
      const round = /^\d+$/.test(at) ? Number(at) : at
      return reproduceResponse(prompt, scenario,
        (id) => scenario.settledExit ? scenario.settledExit(id, round) : 0)
    }
    if (base === 'reproduce:mutation') {
      const hunkLines = scenario.hunks ? scenario.hunks('mutation') : defaultHunkLines(filesOf(scenario.postMutationReview))
      return reproduceResponse(prompt, scenario, () => undefined, hunkLines)
    }
    if (base === 'reproduce:mutation:fresh') {
      return reproduceResponse(prompt, scenario, (id) => exitFor(scenario, id, 'mutation', retry))
    }
    if (label === 'gate:opt-in') {
      if (scenario.gateProbeFails) return null
      return { crap_gated: scenario.crapGated ?? true,
        mutation_gated: scenario.mutationGated ?? false, detail: 'stub' }
    }
    if (label === 'checks:discover') {
      if (scenario.discoveryFails) return null
      return scenario.discovery ?? { file: '', sections: [], detail: 'stub: no repo checks' }
    }
    if (label.startsWith('checks:run:')) {
      const attempt = Number(label.slice('checks:run:'.length))
      return (scenario.checkRuns ?? (() => ({ results: [] })))(attempt)
    }
    if (label === 'checks:fix') {
      return scenario.checksFixResult ??
        { head_sha: 'checksfix00000000000000000000000000000001', note: 'stub', scored: false }
    }
    if (label.startsWith('mutation:')) {
      const attempt = Number(label.slice('mutation:'.length))
      return (scenario.mutationResult ?? (() => ({ green: true, head_sha: REVIEWED_THROUGH, detail: 'stub', scored: true })))(attempt)
    }
    if (label === 'staleness') {
      if (scenario.staleness === 'reject') throw new Error('staleness subagent failed')
      if (scenario.staleness === null) return null
      if (scenario.staleness === 'malformed') return { results: 'not-an-array' }
      const ids = idsIn(prompt)
      const results = scenario.staleness ? scenario.staleness(ids) : []
      return {
        results: scenario.stalenessBracketed
          ? results.map(r => ({ ...r, id: `[${r.id}]` }))
          : results,
      }
    }
    if (label === 'pr') {
      return scenario.prResult ?? { opened: false, url: '', note: 'stub' }
    }
    throw new Error(`unstubbed agent label in test scenario: ${label}`)
  }
}

async function run(scenario) {
  const captured = { calls: [], runRecordPrompt: null, dedupPrompt: null, logs: [], spans: [] }
  // Charged per agent call, not per read, so a spend assertion states "one
  // agent ran inside this window" rather than "the script read the budget
  // twice"; an added outOfBudget() check would otherwise break it silently.
  let agentCalls = 0
  let clock = 0
  const stubAgent = makeAgent(scenario, captured)
  const sandbox = {
    args: baseArgs(scenario.args),
    // Each call records a start and end tick. parallel() below is Promise.all,
    // so calls it starts together get interleaved ticks while calls awaited one
    // after another do not: that is what makes an overlap observable here.
    agent: async (prompt, opts) => {
      agentCalls++
      const span = { label: opts.label, start: clock++ }
      captured.spans.push(span)
      const r = await stubAgent(prompt, opts)
      span.end = clock++
      return r
    },
    // JSON round-tripped, not returned as-is: the real parallel() serializes
    // each thunk's result to hand it back across the boundary, and a class
    // instance (a Map, for instance) does not survive that. Promise.all alone
    // preserves object identity and masked the bug this test guards against.
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
    budget: scenario.budgetPerAgentCall
      ? { total: null, spent: () => agentCalls * scenario.budgetPerAgentCall,
          remaining: () => Infinity }
      : (scenario.budget ?? { total: null, spent: () => 0, remaining: () => Infinity }),
  }
  const ctx = vm.createContext(sandbox)
  const fn = vm.compileFunction(body, [], { parsingContext: ctx })
  const result = await fn()
  return { result, captured }
}

function callCount(captured, label) {
  return captured.calls.filter(c => c.label === label).length
}

// Scenarios X and Y -- the two exits past the fix loop, where a residual note
// from a round that converged is still carried in the payload.
function convergedWithSuspect(overrides) {
  return {
    draftPr: { opened: true, number: 23, url: 'https://example.invalid/pr/23', detail: 'stub draft' },
    initialReview: {
      correctness: [{ title: 'Off-by-one in parser', file: 'src/parser.js',
        claim: 'boundary is wrong', evidence: 'parser.js:12' }],
      advocate: [],
    },
    verify: (id) => id === 'f1' ? true : undefined,
    fixHead: () => 'fix00000000000000000000000000000000000001',
    tailReview: [{ title: 'Boundary check excludes the last element', file: 'parser.js',
      claim: 'off-by-one at the array end', evidence: 'see loop condition',
      duplicate_of: 'f1', reproducer: undefined }],
    staleness: () => [],
    mutationGated: true,
    ...overrides,
  }
}

// Scenarios AF and AG -- a finding the last round's tail review appended, which
// no round could have verified. AF: it was in fact fixed, so the run must not
// halt on it. AG: it was not, so the halt stands and says it was checked.
// The old "late pass" scenario: a finding a round's own tail review raises is
// now classified and executed in that same round (reproduce:fix:N:fresh),
// never left to a separate pass after the loop exits, so a fresh finding from
// the very last round still gets its reproducer run before the halt decision.
function lateFinding(fixedAtFinal) {
  return {
    args: { maxReviewRounds: 1 },
    initialReview: {
      correctness: [{ title: 'Off-by-one', file: 'src/p.js', claim: 'c1', evidence: 'e1' }],
      advocate: [],
    },
    verify: (id) => id === 'f1' ? true : fixedAtFinal,
    fixHead: () => 'fix00000000000000000000000000000000000001',
    tailReview: [{ title: 'Unrelated nil deref', file: 'src/q.js',
      claim: 'deref before guard', evidence: 'q.js:9' }],
    staleness: () => [],
  }
}

// Scenarios EG-EI -- executeAtHead() judges a reproducer by the worktree's
// porcelain before and after its own commands, so nothing else may run in that
// worktree meanwhile. A tail review running beside it once had its own test
// log blamed on a reproducer and halted a clean run.
function overlapsWithExecutor(captured) {
  const done = captured.spans.filter(s => s.end !== undefined)
  return done.filter(e => e.label.startsWith('reproduce:')).flatMap(e =>
    done.filter(o => o !== e && o.start < e.end && e.start < o.end)
      .map(o => `${e.label} overlaps ${o.label}`))
}
JS_PRELUDE_EOF
)"

# Writes JS_PRELUDE plus the calling file's own scenario code (read from
# stdin, which must define its own `const SCENARIOS = [...]`), appends a
# footer that runs SCENARIOS and reports failures, then executes it with
# node. printf, not an unquoted heredoc, is what actually writes the file: the
# JS itself is full of `$` and backticks that an unquoted heredoc would try to
# expand as shell syntax.
run_js_scenarios() {
  local area_js
  area_js="$(cat)"
  {
    printf '%s\n' "$JS_PRELUDE"
    printf '%s\n' "$area_js"
    cat <<'FOOTER_EOF'
for (const scenario of SCENARIOS) {
  await scenario()
}

console.log('')
if (failures === 0) {
  console.log('OK')
  process.exit(0)
} else {
  console.log(`FAILED: ${failures} assertion(s)`)
  process.exit(1)
}
FOOTER_EOF
  } > "$WORK/harness.mjs"
  node "$WORK/harness.mjs" "$SCRIPT"
  if [ "$?" -ne 0 ]; then
    failures=$((failures + 1))
  fi
}

finish() {
  echo ""
  if [ "$failures" -eq 0 ]; then
    echo "OK"
    exit 0
  else
    echo "FAILED: $failures suite(s)/assertion(s)"
    exit 1
  fi
}
