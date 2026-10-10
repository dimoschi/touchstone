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
# runnerOutput/defaultFinding/reproduceResponse helpers, and the three
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
    openPr: false,
    maxReviewRounds: 3,
    maxGateAttempts: 1,
    // Infinite so existing scenarios' own fixed budget.spent() (see run()
    // below) keeps meaning what it always did; a scenario testing the run
    // budget itself passes its own args.runBudget to override this.
    runBudget: Infinity,
    ...overrides,
  }
}

// Pulls every [fN] token out of a prompt, in the order they appear -- how the
// reproduce and staleness stubs learn which ids the script actually assigned,
// without the scenario needing to predict them.
function idsIn(prompt) {
  return [...prompt.matchAll(/\[(f\d+)\]|printf 'TOUCHSTONE_REPRO %s %s %s %s' (f\d+) /g)]
    .map(m => m[1] ?? m[2])
}

// The names change-signals.sh prints, and a reply to the signals probe that
// carries all of them for `range`. values overrides individual entries.
const SIGNAL_NAMES = [
  'la', 'ld', 'lt', 'la_lt', 'files', 'directories', 'dependency_surface',
  'api_broken', 'security_pattern', 'semantic_noop', 'crap_max', 'coverage_min',
  'reachable', 'defect_files']
function signalEntry(value, reason) {
  return { value, ...(reason ? { reason } : {}),
    evidence: { command: 'stub', exit: 0, output: '' } }
}
function signalValues(overrides = {}) {
  return { ...Object.fromEntries(SIGNAL_NAMES.map(n => [n, signalEntry(false)])), ...overrides }
}
function signalsOutput(range, overrides = {}) {
  return `TOUCHSTONE_SIGNALS ${range}\n${JSON.stringify({ range, values: signalValues(overrides) })}\n` +
    `TOUCHSTONE_SIGNALS_END`
}

// baseArgs()'s branch/branch:existing defaults both put the worktree here.
const STUB_WT_PATH = '/tmp/stub-worktree'

// The heredoc body of the plan:write command, which is what the script asked
// to have written.
function planFileIn(prompt) {
  const m = /<<'PLAN FILE END ([0-9a-f]{8})'\n([\s\S]*?)^PLAN FILE END \1$/m.exec(prompt)
  return m ? { id: m[1], content: m[2] } : null
}

// What the plan:write prompt's digest command prints for a file's text.
function planDigest(text) {
  const bytes = Buffer.from(text.replace(/[ \t\n\r]+/g, ' ').replace(/^ | $/g, ''), 'utf8')
  let h = 0x811c9dc5
  for (const b of bytes) { h ^= b; h = Math.imul(h, 0x01000193) >>> 0 }
  return h.toString(16).padStart(8, '0')
}

// The command the plan:write prompt gives for appending the end line.
function planEndCommand(id) {
  return `printf '\\nEND OF PLAN %s\\n' ${id} >> ${STUB_WT_PATH}/.touchstone/plan.md`
}

// What a checks:run runner prints. The prompt carries one self-contained line
// per check and an end line; the ids and the run are read back out of it here,
// never predicted by a scenario, so a stub answers whatever the script asked.
// The log paths sit where a real runner puts them, under the worktree's git dir.
function checkIdsOf(prompt) {
  return [...prompt.matchAll(/printf 'TOUCHSTONE_CHECK %s %s %s' (\S+) "\$e"/g)].map(m => m[1])
}
function runIdOf(prompt) {
  return (/printf 'TOUCHSTONE_CHECKS_END %s %s %s\\n' (\S+) "\$s"/.exec(prompt) ?? [])[1] ?? ''
}
// What `cksum < "$d/rows"` prints for these rows, from the real cksum, so
// every stubbed run also holds the script's own cksum to the real one.
function rowsSum(rows) {
  return execFileSync('cksum', { input: rows.length ? `${rows.join('\n')}\n` : '', encoding: 'utf8' })
    .trim().split(/\s+/).join(' ')
}
function runnerLogOf(run, id, wtPath = STUB_WT_PATH) {
  return `${wtPath}/.git/touchstone-checks/${run}/${id}.log`
}
// The one line of the prompt that runs `id`.
function runnerLineOf(prompt, id) {
  return prompt.split('\n').find(l => l.includes(`printf 'TOUCHSTONE_CHECK %s %s %s' ${id} `)) ?? ''
}
// Well-formed runner output for the prompt's own checks: exits[i] is the i-th
// check's exit code (0 when absent).
function runnerOutput(prompt, exits = [], state = 'clean') {
  const run = runIdOf(prompt)
  const rows = checkIdsOf(prompt).map((id, i) => `TOUCHSTONE_CHECK ${id} ${exits[i] ?? 0} ${runnerLogOf(run, id)}`)
  return [...rows, `TOUCHSTONE_CHECKS_END ${run} ${state} ${rowsSum(rows)}`].join('\n')
}
// The lines inside the prompt's one fence, run for real, one bash per line as
// the agent runs them. stdout is what the agent would return.
function runRunnerLines(prompt) {
  const fence = /```bash\n([\s\S]*?)\n```/.exec(prompt)
  return (fence ? fence[1].split('\n') : [])
    .map(line => spawnSync('bash', ['-c', line], { encoding: 'utf8' }).stdout).join('')
}
// What the mutation verdict line prints, for the run its prompt names.
function mutationVerifyRunOf(prompt) {
  return (/printf 'TOUCHSTONE_MUTATION_VERIFY %s %s %s %s\\n' (\S+) /.exec(prompt) ?? [])[1] ?? ''
}
function mutationVerifyOutput(prompt, exit, head, wtPath = STUB_WT_PATH) {
  const run = mutationVerifyRunOf(prompt)
  return `TOUCHSTONE_MUTATION_VERIFY ${run} ${exit} ${head} ${wtPath}/.git/touchstone-gates/${run}/mutation-verify.log`
}
// The reviewed head the unreviewed-commit line counts from.
function unreviewedFromOf(prompt) {
  return (/printf 'TOUCHSTONE_UNREVIEWED %s %s %s\\n' (\S+) /.exec(prompt) ?? [])[1] ?? ''
}
// A checkRuns stub's row, in the old shape. The stub turns it into what a
// runner would print for that check: only its exit code is read.
function checkRow(id, command, exit, output) {
  return { id, command, exit_code: exit, output }
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

// What a reproduce:* runner prints. The ids and the run are read back out of
// the prompt's own lines, never predicted by a scenario. Logs are written for
// real, under this harness's own work dir, so a scenario can read what a log
// path a finding carries holds.
const STUB_GIT_DIR = path.join(path.dirname(process.argv[1]), 'stub-git')
function reproIdsOf(prompt) {
  return [...prompt.matchAll(/printf 'TOUCHSTONE_REPRO %s %s %s %s' (\S+) "\$e"/g)].map(m => m[1])
}
function reproRunOf(prompt) {
  return (/printf 'TOUCHSTONE_REPRO_END %s %s %s %s\\n' (\S+) "\$s"/.exec(prompt) ?? [])[1] ?? ''
}
function reproDirOf(run) {
  return `${STUB_GIT_DIR}/touchstone-repro/${run}`
}
// The stub stands in for the shell's grep, so it applies the same rule: a line
// that is exactly the marker once surrounding whitespace is trimmed.
function markerLineIn(output) {
  return String(output).split(/\r?\n/).some(l => l.trim() === REPRODUCED_MARKER)
}
// Well-formed runner output for the prompt's own lines. rows are
// { id, exit, output }; a range prompt gets the hunks block only when
// hunkLines is an array, so leaving it out reads as a runner that skipped it.
function reproOutput(prompt, rows, { before = 'clean', dirty = false, porcelain = '', hunkLines } = {}) {
  const run = reproRunOf(prompt)
  const dir = reproDirOf(run)
  fs.mkdirSync(dir, { recursive: true })
  const lines = [`TOUCHSTONE_REPRO_BEFORE ${run} ${before}`]
  const printed = rows.map(r => {
    fs.writeFileSync(`${dir}/${r.id}.log`, r.output ?? '')
    return `TOUCHSTONE_REPRO ${r.id} ${r.exit} ${markerLineIn(r.output ?? '') ? 1 : 0} ${dir}/${r.id}.log`
  })
  lines.push(...printed)
  if (prompt.includes('TOUCHSTONE_HUNKS_BEGIN') && Array.isArray(hunkLines)) {
    lines.push(`TOUCHSTONE_HUNKS_BEGIN ${run}`, ...hunkLines, `TOUCHSTONE_HUNKS_END ${run} ${hunkLines.length}`)
  }
  fs.writeFileSync(`${dir}/status.log`, dirty ? `${porcelain}\n` : '')
  lines.push(`TOUCHSTONE_REPRO_END ${run} ${dirty ? 'dirty' : 'clean'} ${rowsSum(printed)} ${dir}/status.log`)
  return lines.join('\n')
}

// exitFn(id) undefined drops that id's row, which the parser reads as the
// whole run unmeasured: a runner cannot leave out one row and be trusted on
// the others.
function reproduceResponse(prompt, scenario, exitFn, hunkLines) {
  const rows = []
  for (const id of reproIdsOf(prompt)) {
    const code = exitFn(id)
    if (code === undefined) continue
    const output = scenario.outputFor
      ? scenario.outputFor(id, code)
      : `stub reproduce output for ${id} (${code})` +
        (code !== 0 && code !== 126 && code !== 127 ? `\n${REPRODUCED_MARKER}` : '')
    rows.push({ id, exit: code, output })
  }
  if (scenario.injectBogusVerdict) rows.push({ id: 'f999', exit: 0, output: 'bogus' })
  return { output: reproOutput(prompt, rows, {
    before: scenario.porcelainBefore ? 'dirty' : 'clean',
    dirty: scenario.reproducerDirty === true,
    porcelain: scenario.reproducerPorcelain ?? 'M some-file.txt',
    hunkLines,
  }) }
}

function makeAgent(scenario, captured) {
  return async (prompt, opts) => {
    const label = opts.label
    captured.calls.push({ label, prompt, schema: opts.schema, model: opts.model, effort: opts.effort,
      phase: opts.phase })
    // scenario.throwOn names labels whose dispatch throws, the way agent()
    // does when a subagent exhausts its structured-output retries.
    if ((scenario.throwOn ?? []).includes(label)) {
      throw new Error(`StructuredOutput retry cap (5) exceeded for ${label}`)
    }

    // Replaces the old separate ticket/plugin:version/gate:opt-in dispatches
    // (gh-118): one call, before any worktree exists, answers all three.
    // Each scenario field keeps its old name and meaning; only the label and
    // the object shape they arrive under changed.
    if (label === 'setup') {
      if (scenario.setupFails) return null
      return {
        ticket: scenario.ticketResult ?? { found: true, summary: 'stub ticket', description: 'd', comments: '' },
        version: scenario.versionProbe ?? { found: false, name: '', version: '', detail: 'stub' },
        markers: scenario.gateProbeFails ? null : { crap_gated: scenario.crapGated ?? true,
          mutation_gated: scenario.mutationGated ?? false, detail: 'stub' },
      }
    }
    // checks_source used to come back from a separate checks:discover call;
    // it now rides on the same branch/branch:existing response, folded in
    // here so the ~30 scenarios that set scenario.discovery or
    // scenario.discoveryFails need no change beyond the label they attach to.
    const checksSourceFor = () => scenario.discoveryFails ? null :
      (scenario.discovery ?? { file: '', sections: [], detail: 'stub: no repo checks' })
    if (label === 'branch') {
      return { checks_source: checksSourceFor(),
        ...(scenario.branchResult ?? { created: true, branch: 'feat/gh-21-stub', base: 'main',
          path: '/tmp/stub-worktree', ticket: '21', detail: 'stub' }) }
    }
    if (label === 'branch:existing') {
      return { checks_source: checksSourceFor(),
        ...(scenario.existingBranchResult ?? { created: true, branch: 'feat/gh-21-stub', base: 'main',
          path: '/tmp/stub-worktree', ticket: '21', detail: 'stub' }) }
    }
    if (label === 'triage') {
      // scope: 'inline' skips the Plan phase, which this test has no reason
      // to exercise: it is not part of the join this ticket fixes.
      return { scope: 'inline', complexity: 'trivial', expected_files: [],
        complexity_note: 'stub', premise_ok: true, estimated_loc: 5, evidence: [],
        premise_note: 'stub', ...(scenario.triage ?? {}) }
    }
    if (label === 'planner') {
      return scenario.plannerResult ?? { plan: 'stub plan', acceptance_criteria: [],
        risky_areas: [], task_demands_implementation: false }
    }
    if (label === 'planner:tighten') {
      if (Object.prototype.hasOwnProperty.call(scenario, 'tightenResult')) return scenario.tightenResult
      return { plan: 'tightened stub plan', acceptance_criteria: [],
        risky_areas: [], task_demands_implementation: false }
    }
    // Default answer is a correct write of whatever the prompt asked for;
    // scenario.planWrite overrides fields of it, or is null for no answer; a
    // function of the attempt (1, or 2 on 'plan:write:retry') returns either.
    if (label === 'plan:write' || label === 'plan:write:retry') {
      const attempt = label === 'plan:write' ? 1 : 2
      const override = typeof scenario.planWrite === 'function'
        ? scenario.planWrite(attempt) : scenario.planWrite
      if (override === null) return null
      const copied = planFileIn(prompt)
      // The copied text, plus the end line only when the prompt carries the
      // command that appends it, as the shell would run it.
      const appends = copied && new RegExp(
        `^printf '\\\\nEND OF PLAN %s\\\\n' ${copied.id} >> .*/\\.touchstone/plan\\.md'?$`, 'm')
        .test(prompt)
      const appended = appends ? `\nEND OF PLAN ${copied.id}\n` : ''
      const file = copied ? copied.content + appended : ''
      return { digest: planDigest(file),
        last_line: file.replace(/\n$/, '').split('\n').pop(),
        ignored_exit: 0, ...(override ?? {}) }
    }
    // implPlanId: undefined omits plan_id from the response altogether.
    const planIdOf = () => planFileIn(captured.calls.find(c => c.label === 'plan:write')?.prompt ?? '')?.id ?? ''
    if (label === 'implementer') {
      return { summary: 'stub implementation', files_changed: scenario.implFilesChanged ?? ['a.js', 'b.js'],
        commit_range: scenario.implRange ?? COMMIT_RANGE, scored: scenario.implScored ?? true,
        plan_id: Object.prototype.hasOwnProperty.call(scenario, 'implPlanId') ? scenario.implPlanId : planIdOf(),
        ...(scenario.implGateNote ? { gate_note: scenario.implGateNote } : {}) }
    }
    // Clean unless scenario.planLeak(at, range, prompt, attempt) returns the
    // probe's raw output as a string, or null for no answer. attempt is 2 on
    // the ':retry' rerun.
    if (label.startsWith('plan:leak:')) {
      const attempt = label.endsWith(':retry') ? 2 : 1
      const at = label.slice('plan:leak:'.length).replace(/:retry$/, '')
      const range = (/echo TOUCHSTONE_PLAN_LEAK ([^\s;]+);/.exec(prompt) ?? [])[1] ?? ''
      const custom = scenario.planLeak ? scenario.planLeak(at, range, prompt, attempt) : undefined
      if (custom === null) return null
      return { output: custom ?? `TOUCHSTONE_PLAN_LEAK ${range}\nTOUCHSTONE_PLAN_LEAK_END` }
    }
    // draft-pr and size (gh-118): the diffstat probe and its one retry. Both
    // read the range straight out of their own prompt (diffstatCommandFor
    // embeds it verbatim after "TOUCHSTONE_DIFFSTAT "), so the default
    // diffstat always names whatever range the script actually asked about,
    // including a range a pre-review checks fix already folded in.
    // diffstatFiles defaults to a two-file, two-lens-sized diff (matching
    // this file's old implFilesChanged/implInsertions defaults, so the ~90
    // scenarios that never touch sizing keep getting the same two lenses).
    // scenario.diffstat/.sizeRetryDiffstat override one call each;
    // scenario.sizeUnmeasured makes both return something parseDiffstat
    // rejects, for the still-unmeasured-after-retry halt.
    if (label === 'draft-pr' || label === 'size') {
      const range = (/TOUCHSTONE_DIFFSTAT ([^\n;]+);/.exec(prompt) ?? [])[1]?.trim() ?? COMMIT_RANGE
      const files = scenario.diffstatFiles ?? [['a.js', 100, 0], ['b.js', 100, 0]]
      const goodDiffstat = `TOUCHSTONE_DIFFSTAT ${range}\n` +
        files.map(([p, a, r]) => `${a}\t${r}\t${p}`).join('\n') +
        `\nTOUCHSTONE_COMMENT_LINES\nTOUCHSTONE_DIFFSTAT_END`
      if (label === 'size') {
        if (scenario.sizeRetryFails) return null
        return { diffstat: scenario.sizeRetryDiffstat ??
          (scenario.sizeUnmeasured ? 'still not a real diffstat' : goodDiffstat) }
      }
      const diffstat = scenario.diffstat ??
        (scenario.sizeUnmeasured ? 'not a real diffstat' : goodDiffstat)
      return { diffstat, ...(scenario.draftPr ?? { opened: false, detail: 'no draft in this test' }) }
    }
    // The change-signals probe. The reply names the range the script
    // asked about, read from the command line of its own prompt, so it always
    // matches whatever range a pre-review fix folded in. signalValues overrides
    // entries; signalsReply(range) -> string | object | null replaces the reply
    // (a string is the output field, an object the whole response, null no answer); signalsThrows makes the dispatch itself fail.
    if (label === 'signals') {
      if (scenario.signalsThrows) throw new Error('signals probe failed')
      const range = (/^change-signals\.sh \S+ (\S+)$/m.exec(prompt) ?? [])[1] ?? COMMIT_RANGE
      const custom = scenario.signalsReply ? scenario.signalsReply(range) : undefined
      if (custom === null) return null
      if (custom !== undefined && typeof custom === 'object') return custom
      return { output: custom ?? signalsOutput(range, scenario.signalValues) }
    }
    // The command is run for real when its worktree exists on disk, as an agent
    // would; otherwise (the stub path) the head is clean. scenario.rangeCheck(command)
    // returns the output instead, or null for none.
    if (label === 'resume:range-check') {
      const command = prompt.split('\n').pop()
      const worktree = (/^git -C (\S+) /.exec(command) ?? [])[1]
      const out = scenario.rangeCheck ? scenario.rangeCheck(command)
        : worktree && fs.existsSync(worktree) ? execFileSync('bash', ['-c', command], { encoding: 'utf8' }).trim()
        : 'TOUCHSTONE_PRIOR_HEAD_LINEAR 0'
      return out === null ? null : { output: out }
    }
    // Opening the PR is the workflow's only write to GitHub. These two labels
    // posted comments on it; throwing rather than stubbing them means any
    // scenario that brings either back fails here, not just the ones whose
    // assertions were written for it.
    if (label.startsWith('halt-notice:') || label === 'regression-notice') {
      throw new Error(`agent '${label}' posts to GitHub; the workflow must not`)
    }
    // ticket, plugin:version, gate:opt-in and checks:discover folded into
    // 'setup' (or, for checks:discover, into branch/branch:existing) and
    // run-record dropped outright (gh-118): a script dispatching any of
    // these five again is a regression the suite must catch, not silently
    // stub.
    if (['ticket', 'plugin:version', 'gate:opt-in', 'checks:discover', 'run-record'].includes(label)) {
      throw new Error(`agent '${label}' should no longer be dispatched`)
    }
    if (label === 'review:dedup') {
      captured.dedupPrompt = prompt
      return { groups: scenario.dedupGroups ?? [] }
    }
    // scenario.deadLenses names review labels (review:advocate,
    // review:fix:1:correctness, ...) whose lens returns null: what parallel()
    // hands back for a lens that threw or failed its schema after retries.
    if ((scenario.deadLenses ?? []).includes(label)) return null
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
    // scenario.reproRuns(label, prompt) answers a reproduce:* call itself:
    // { output }, or null for no answer; undefined falls through to the stubs.
    if (label.startsWith('reproduce:') && scenario.reproRuns) {
      const reply = scenario.reproRuns(label, prompt)
      if (reply !== undefined) return reply
    }
    if (scenario.dirtyAt === label) {
      return reproduceResponse(prompt, { reproducerDirty: true, reproducerPorcelain: '?? stray-file' },
        () => 1, [])
    }
    const retry = /^reproduce:.+:retry$/.test(label)
    const base = retry ? label.slice(0, -':retry'.length) : label
    if (base === 'reproduce:review') {
      return reproduceResponse(prompt, scenario,
        (id) => scenario.initialExit ? scenario.initialExit(id, retry) : 1)
    }
    if (base === 'reproduce:carried') {
      return reproduceResponse(prompt, scenario, (id) => exitFor(scenario, id, 0, retry))
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
        (id) => scenario.settledExit ? scenario.settledExit(id, round, retry) : 0)
    }
    if (base === 'reproduce:mutation') {
      const hunkLines = scenario.hunks ? scenario.hunks('mutation') : defaultHunkLines(filesOf(scenario.postMutationReview))
      return reproduceResponse(prompt, scenario, () => undefined, hunkLines)
    }
    if (base === 'reproduce:mutation:fresh') {
      return reproduceResponse(prompt, scenario, (id) => exitFor(scenario, id, 'mutation', retry))
    }
    // scenario.checkRuns(attempt, prompt) answers with { output } (raw, what the
    // agent returned) or null, or in the old { results, dirty } shape, which is
    // printed as a runner would: one line per check of the prompt that has a
    // row with an integer exit_code, then the end line. Without checkRuns every
    // check exits 0.
    if (label.startsWith('checks:run:')) {
      const attempt = Number(label.slice('checks:run:'.length))
      const reply = scenario.checkRuns ? scenario.checkRuns(attempt, prompt) : undefined
      if (reply === null || typeof reply?.output === 'string') return reply
      const exits = checkIdsOf(prompt).map(id =>
        reply?.results ? reply.results.find(r => r.id === id)?.exit_code : 0)
      const run = runIdOf(prompt)
      const rows = checkIdsOf(prompt).flatMap((id, i) => Number.isInteger(exits[i])
        ? [`TOUCHSTONE_CHECK ${id} ${exits[i]} ${runnerLogOf(run, id)}`] : [])
      return { output: [...rows,
        `TOUCHSTONE_CHECKS_END ${run} ${reply?.dirty === true ? 'dirty' : 'clean'} ${rowsSum(rows)}`].join('\n') }
    }
    if (label === 'checks:fix') {
      return scenario.checksFixResult ??
        { head_sha: 'checksfix00000000000000000000000000000001', note: 'stub', scored: false }
    }
    if (label.startsWith('mutation:')) {
      const attempt = Number(label.slice('mutation:'.length))
      const reported = (scenario.mutationResult ?? (() => ({ green: true, head_sha: REVIEWED_THROUGH, detail: 'stub', scored: true })))(attempt)
      captured.lastMutation = reported ?? captured.lastMutation
      return reported
    }
    // The verdict line run after each mutation attempt. By default it agrees
    // with the agent: exit 0 when its last answer said green, else 1, at the
    // head it reported. scenario.mutationVerify(attempt, prompt, retry)
    // returns { exit, head } to override either, { output } for a raw reply,
    // or null for no answer.
    const verifyAt = /^mutation-verify:(\d+)(:retry)?$/.exec(label)
    if (verifyAt) {
      const custom = scenario.mutationVerify
        ? scenario.mutationVerify(Number(verifyAt[1]), prompt, Boolean(verifyAt[2])) : undefined
      if (custom === null || typeof custom?.output === 'string') return custom
      const last = captured.lastMutation
      return { output: mutationVerifyOutput(prompt, custom?.exit ?? (last?.green ? 0 : 1),
        custom?.head ?? (last?.head_sha || REVIEWED_THROUGH)) }
    }
    // The unreviewed-commit count before the PR. Count 0 at the reviewed head
    // unless scenario.unreviewed(retry, prompt) returns { count, head },
    // { output } for a raw reply, or null for no answer.
    if (label === 'pr-unreviewed' || label === 'pr-unreviewed:retry') {
      const custom = scenario.unreviewed ? scenario.unreviewed(label.endsWith(':retry'), prompt) : undefined
      if (custom === null || typeof custom?.output === 'string') return custom
      const from = unreviewedFromOf(prompt)
      return { output: `TOUCHSTONE_UNREVIEWED ${from} ${custom?.count ?? 0} ${custom?.head ?? from}` }
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
  const captured = { calls: [], dedupPrompt: null, logs: [], spans: [] }
  // Charged per agent call, not per read, so a spend assertion states "one
  // agent ran inside this window" rather than "the script read the budget
  // twice"; an added outOfBudget() check would otherwise break it silently.
  let agentCalls = 0
  let clock = 0
  // scenario.spendAllAfter names a label: once that agent returns, the budget
  // reads as spent, so the very next dispatch is the one refused.
  let spentAll = false
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
      if (opts.label === scenario.spendAllAfter) spentAll = true
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
    budget: scenario.spendAllAfter
      ? { total: null, spent: () => spentAll ? 10_000_000 : 0, remaining: () => Infinity }
      : scenario.budgetPerAgentCall
      ? { total: null, spent: () => agentCalls * scenario.budgetPerAgentCall,
          remaining: () => Infinity }
      : (scenario.budget ?? { total: null, spent: () => 0, remaining: () => Infinity }),
  }
  const ctx = vm.createContext(sandbox)
  // Strict, as the host runs it: the script is an ES module (export const
  // meta), and a sloppy-mode compile lets an undeclared assignment pass here
  // that throws a ReferenceError on every real run.
  const fn = vm.compileFunction(`'use strict';\n${body}`, [], { parsingContext: ctx })
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
  try {
    await scenario()
  } catch (e) {
    console.log(`  ABORTED: ${scenario.name}: ${e.message}`)
    failures++
  }
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
