#!/usr/bin/env bash
# Regression test for ticket 9: a NEXT_ACTION of UNSUPPORTED_LANGUAGE must not
# leave the pipeline silently continuing past whichever phase hits it. Three
# phases can commit -- Implement, Fix, Mutation -- and each needs both a
# schema field to report the halt on and code that actually stops the run on
# it, rather than reading the halt as a normal result and sailing on with the
# refused work uncommitted.
#
# Checked:
#   1. Static: the Mutation prompt states the marker prohibition, matching the
#      Implement and Fix prompts.
#   2. Dynamic, against the real script under stubbed globals: an implementer
#      that reports unsupported_language=true halts the run at Implement,
#      before Draft PR, Fix or Mutation ever run.
#   3. Dynamic: a fixer that reports unsupported_language=true halts the run
#      at Fix, before Mutation ever runs.
#   4. Dynamic: a mutation agent that reports unsupported_language=true halts
#      the run at Mutation without blaming surviving mutants or a timeout.
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

echo "== static: the Mutation prompt carries the marker prohibition"
# Four now, not three: the pre-review checks-only fix round commits too, so it
# carries the same prohibition as Implement, Fix and Mutation.
check "the Mutation prompt says never create/edit/delete the markers" \
  "$(grep -Fc 'Never create, edit or delete .crap-gated,' "$SCRIPT" || true)" 4
check "IMPL, FIXED and GATE each declare unsupported_language as a property" \
  "$(grep -Fc "unsupported_language: { type: 'boolean' }" "$SCRIPT" || true)" 3

# Three passes fixed one instance each of the same defect: a note stating the
# PR's fate from an assumption rather than from draftPr. Only the helper that
# checks may name either outcome. Bump the last count with a new call site.
echo "== static: only prNote() states what happened to the PR"
check "the 'no PR was opened' wording appears only in prNote" \
  "$(grep -Fc 'PR was opened' "$SCRIPT" || true)" 1
check "the 'left as a draft' wording appears only in prNote" \
  "$(grep -Fc 'left as a draft' "$SCRIPT" || true)" 1
check "no text claims the work cannot open a PR, which the draft already did" \
  "$(grep -Fc 'cannot open a PR' "$SCRIPT" || true)" 0
check "every note that reports the PR's fate reads the helper" \
  "$(grep -Fc '${prNote()}' "$SCRIPT" || true)" 5

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/harness.mjs" <<'JS_EOF'
import fs from 'node:fs'
import vm from 'node:vm'

const SCRIPT_PATH = process.argv[2]
const src = fs.readFileSync(SCRIPT_PATH, 'utf8')
const body = 'return (async () => {\n' +
  src.replace(/^export const meta/m, 'const meta') + '\n})();'

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
    ticket: '9',
    task: 'test task for the unsupported-language halt',
    record: false,
    openPr: false,
    maxReviewRounds: 3,
    maxGateAttempts: 1,
    reviewers: 0,
    ...overrides,
  }
}

// `responses` lets a scenario answer one exact label without re-implementing
// every default below it; a label not listed falls through to the defaults,
// which is what makes each scenario only state the one call it cares about.
function makeAgent(scenario, captured) {
  const responses = scenario.responses ?? {}
  return async (prompt, opts) => {
    const label = opts.label
    captured.calls.push({ label, prompt })

    if (Object.prototype.hasOwnProperty.call(responses, label)) {
      return responses[label]
    }
    if (label === 'ticket') {
      return { found: true, summary: 'stub ticket', description: 'd', comments: '' }
    }
    if (label === 'branch') {
      return { created: true, branch: 'feat/gh-9-stub', base: 'main',
        path: '/tmp/stub-worktree', ticket: '9', detail: 'stub' }
    }
    if (label === 'triage') {
      return { scope: 'inline', complexity: 'trivial', complexity_note: 'stub',
        premise_ok: true, estimated_loc: 5, evidence: [], premise_note: 'stub' }
    }
    if (label === 'gate:opt-in') {
      return { crap_gated: true, mutation_gated: true, detail: 'stub' }
    }
    if (label === 'checks:discover') {
      return { checks: [], detail: 'stub: no repo checks' }
    }
    if (label === 'implementer') {
      return scenario.implementer
    }
    if (label === 'draft-pr') {
      captured.draftPrCalled = true
      // Default has no number, so draftPr stays null and prNote() reports that
      // nothing was opened. A scenario that wants a draft must say so.
      return scenario.draftPr ?? { opened: false, detail: 'should not be reached' }
    }
    if (label.startsWith('halt-notice:')) {
      captured.haltAt = label.slice('halt-notice:'.length)
      return true
    }
    if (label === 'run-record') {
      return '/stub/main/.claude/touchstone-runs/9.json'
    }
    if (label.startsWith('fix:')) { captured.fixCalled = true; throw new Error('Fix must not run') }
    if (label.startsWith('mutation:')) { captured.mutationCalled = true; throw new Error('Mutation must not run') }
    if (label.startsWith('review:')) { captured.reviewCalled = true; return { findings: [] } }
    // reproduce:review runs once, right after the initial review, to decide
    // open-vs-note for whatever candidates it raised; this file's one scenario
    // that reaches Review needs its finding to reproduce (nonzero) so it is
    // still open when the fixer halts on it.
    if (label === 'reproduce:review') {
      const ids = [...prompt.matchAll(/\[(f\d+)\]/g)].map(m => m[1])
      return { results: ids.map(id => ({ id, exit_code: 1, output: 'stub: still reproduces' })), dirty: false }
    }
    throw new Error(`unstubbed agent label in test scenario: ${label}`)
  }
}

async function run(scenario) {
  const captured = { calls: [], draftPrCalled: false, fixCalled: false, mutationCalled: false, reviewCalled: false }
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
    log: () => {},
    // A function form as well as an object, because a stage's over() compares
    // spend against the reading taken when the stage opened: a constant spend
    // can never exceed a ceiling, so forcing an overrun needs a spend keyed off
    // which agents have run by then.
    budget: typeof scenario.budget === 'function'
      ? scenario.budget(captured)
      : scenario.budget ?? { total: null, spent: () => 0, remaining: () => Infinity },
  }
  const ctx = vm.createContext(sandbox)
  const fn = vm.compileFunction(body, [], { parsingContext: ctx })
  const result = await fn()
  return { result, captured }
}

async function scenarioUnsupportedLanguage() {
  console.log('\n== scenario: an implementer reporting unsupported_language halts at Implement')
  const { result, captured } = await run({
    implementer: {
      summary: 'NEXT_ACTION is UNSUPPORTED_LANGUAGE: the repo has no crap-check.sh ' +
        'support for this language. Three options: (1) add support, (2) drop ' +
        '.crap-gated, (3) proceed ungated for this change. Halting for a human ' +
        'decision rather than editing the marker.',
      files_changed: [], commit_range: 'base00000000000000000000000000000000000000..base00000000000000000000000000000000000000',
      insertions: 0, scored: false, unsupported_language: true,
      gate_note: 'crap-check: FAILED TO MEASURE - 2 staged file(s)',
    },
  })
  check('halted at Implement', result.halted_at, 'Implement')
  // The implementer may have committed and scored before hitting the refusal,
  // and commands/deliver.md tells the caller to report the gate result, so a
  // halt that omits it leaves the caller with nothing to report.
  check('the gate result reaches the halt payload', result.gates?.measured ?? null, 'nothing scorable')
  // Presence is not the claim: the refusing implementer's own gate message has
  // to survive into detail, which is the only place it is ever reported.
  check('the refusing implementer\'s gate note reaches detail',
    /FAILED TO MEASURE - 2 staged file/.test(result.gates?.detail ?? ''), true)
  check('Draft PR never ran', captured.draftPrCalled, false)
  check('Fix never ran', captured.fixCalled, false)
  check('Mutation never ran', captured.mutationCalled, false)
  check('Review never ran', captured.reviewCalled, false)
  check('the halt note reports the three options', /Three options/.test(result.note ?? ''), true)
}

async function scenarioFixHalts() {
  console.log('\n== scenario: a fixer reporting unsupported_language halts at Fix')
  const { result, captured } = await run({
    args: { reviewers: 1 },
    implementer: {
      summary: 'implemented the feature', files_changed: ['a.go', 'b.go'],
      commit_range: 'base00000000000000000000000000000000000000..impl0000000000000000000000000000000000000',
      insertions: 50, scored: true,
    },
    responses: {
      'review:correctness': { findings: [
        { category: 'wrong-result', title: 'off-by-one', file: 'a.go',
          claim: 'loop skips the last element', evidence: 'a.go:12',
          reproducer: { kind: 'command', command: 'go test ./... -run TestLoop',
            expected: 'exit 0', actual: 'exit 1' } },
      ] },
      'fix:1': {
        head_sha: 'impl0000000000000000000000000000000000000',
        note: 'NEXT_ACTION is UNSUPPORTED_LANGUAGE: three options are (1) add ' +
          'support, (2) drop .crap-gated, (3) proceed ungated. Halting rather ' +
          'than editing the marker.',
        scored: false, unsupported_language: true,
      },
      staleness: { results: [{ id: 'f1', changed: true }] },
    },
  })
  check('halted at Fix', result.halted_at, 'Fix')
  check('Mutation never ran', captured.mutationCalled, false)
  check('the halt note reports the three options', /three options/.test(result.note ?? ''), true)
  // The findings cost an opus review round and halted() builds the draft-PR
  // comment out of them, so a halt that drops them leaves a reviewer with a
  // stop and no list of what to judge.
  check('the open finding reaches the halt payload', {
    count: result.unresolved_findings?.length ?? 0,
    title: result.unresolved_findings?.[0]?.title ?? null,
  }, { count: 1, title: 'off-by-one' })
  check('the gate result reaches the halt payload', result.gates?.measured ?? null, 'scored')
  check('the fix round count reaches the halt payload', result.fix_rounds, 1)
  check('the halt says why the loop stopped',
    /UNSUPPORTED_LANGUAGE/.test(result.stopped_because ?? ''), true)
  check('notes reach the halt payload',
    Array.isArray(result.notes), true)
  // Closing the stage is what records its spend, so an early return that skips
  // it reports a Fix halt whose fix phase apparently cost nothing.
  check('the fix stage spend is recorded',
    Object.prototype.hasOwnProperty.call(result.stage_spend ?? {}, 'fix'), true)
  // The sibling halt marks findings whose evidence has moved, and halted()
  // renders that marker into the PR comment. Unmarked, a human re-checks
  // nothing and acts on a finding that has already been overtaken.
  check('the finding carries the stale marker the sibling halt applies',
    result.unresolved_findings?.[0]?.code_changed_since_recorded, true)
}

// The other Implement halt. It reported no gate result at all, and asserted in
// prose that the gates had not run -- which is wrong for an implementer that
// committed and scored before overrunning.
async function scenarioImplementCeiling() {
  console.log('\n== scenario: the Implement ceiling halt reports the gate result')
  const { result } = await run({
    args: { stageBudgets: { implement: 1000 } },
    budget: (captured) => ({
      total: null,
      spent: () => captured.calls.some(c => c.label === 'implementer') ? 999999 : 0,
      remaining: () => Infinity,
    }),
    implementer: {
      summary: 'committed two of four steps, then ran out of ceiling',
      files_changed: ['a.go'],
      commit_range: 'base00000000000000000000000000000000000000..impl0000000000000000000000000000000000000',
      insertions: 40, scored: true, gate_note: 'crap-check: PASS on 1 function',
    },
  })
  check('halted at Implement', result.halted_at, 'Implement')
  check('the gate result reaches the halt payload', result.gates?.measured ?? null, 'scored')
  check('the scoring implementer\'s own gate note reaches detail',
    /PASS on 1 function/.test(result.gates?.detail ?? ''), true)
  check('the note no longer claims the gates did not run',
    /gates and review did not run/.test(result.note ?? ''), false)
  check('the note still says review did not run',
    /review did not run/.test(result.note ?? ''), true)
}

const DRAFT_OPEN = { opened: true, url: 'https://example.test/pr/5', number: 5, detail: 'stub' }

async function scenarioMutationHalts() {
  console.log('\n== scenario: a mutation agent reporting unsupported_language halts at Mutation')
  const { result } = await run({
    args: { maxGateAttempts: 3 },
    draftPr: DRAFT_OPEN,
    implementer: {
      summary: 'implemented the feature', files_changed: ['a.go'],
      commit_range: 'base00000000000000000000000000000000000000..impl0000000000000000000000000000000000000',
      insertions: 5, scored: true,
    },
    responses: {
      'mutation:1': {
        green: false, head_sha: 'impl0000000000000000000000000000000000000',
        detail: 'NEXT_ACTION is UNSUPPORTED_LANGUAGE: three options are (1) add ' +
          'support, (2) drop .mutation-gated, (3) proceed ungated.',
        unsupported_language: true, scored: false,
      },
    },
  })
  check('halted at Mutation', result.halted_at, 'Mutation')
  check('the halt note names UNSUPPORTED_LANGUAGE, not surviving mutants', {
    names_unsupported: /UNSUPPORTED_LANGUAGE/.test(result.note ?? ''),
    blames_mutants: /[Ss]urviving/.test(result.note ?? ''),
  }, { names_unsupported: true, blames_mutants: false })
  // The draft PR is opened before Review, so one exists by the time Mutation
  // runs, and halted() posts this note as a comment on it. A note claiming
  // nothing was opened contradicts the PR it is written on.
  check('the note does not claim no PR was opened',
    /[Nn]o PR was opened/.test(result.note ?? ''), false)
  check('the note says the PR was left as a draft',
    /left as a draft/.test(result.note ?? ''), true)
}

// The sibling arm of the same ternary, which made the same claim. Covered
// separately because only one arm renders per halt.
async function scenarioMutationNeedsUserRun() {
  console.log('\n== scenario: the Bash-ceiling halt does not claim no PR was opened either')
  const { result } = await run({
    args: { maxGateAttempts: 3 },
    draftPr: DRAFT_OPEN,
    implementer: {
      summary: 'implemented the feature', files_changed: ['a.go'],
      commit_range: 'base00000000000000000000000000000000000000..impl0000000000000000000000000000000000000',
      insertions: 5, scored: true,
    },
    responses: {
      'mutation:1': {
        green: false, head_sha: 'impl0000000000000000000000000000000000000',
        detail: 'the run does not fit the Bash ceiling', needs_user_run: true, scored: false,
      },
    },
  })
  check('halted at Mutation', result.halted_at, 'Mutation')
  check('the note blames the Bash ceiling', /Bash ceiling/.test(result.note ?? ''), true)
  check('the note does not claim no PR was opened',
    /[Nn]o PR was opened/.test(result.note ?? ''), false)
  check('the note says the PR was left as a draft',
    /left as a draft/.test(result.note ?? ''), true)
}

// Opening the draft may fail without ending the run, so "left as a draft"
// stated unconditionally is the same class of wrong as the claim it replaced.
async function scenarioMutationHaltWithNoDraft() {
  console.log('\n== scenario: with no draft opened, the Mutation halt says so')
  const { result } = await run({
    args: { maxGateAttempts: 3 },
    draftPr: { opened: false, detail: 'gh pr create failed' },
    implementer: {
      summary: 'implemented the feature', files_changed: ['a.go'],
      commit_range: 'base00000000000000000000000000000000000000..impl0000000000000000000000000000000000000',
      insertions: 5, scored: true,
    },
    responses: {
      'mutation:1': {
        green: false, head_sha: 'impl0000000000000000000000000000000000000',
        detail: 'NEXT_ACTION is UNSUPPORTED_LANGUAGE: three options.',
        unsupported_language: true, scored: false,
      },
    },
  })
  check('halted at Mutation', result.halted_at, 'Mutation')
  check('the note says no PR was opened', /[Nn]o PR was opened/.test(result.note ?? ''), true)
  check('the note does not claim a draft was left',
    /left as a draft/.test(result.note ?? ''), false)
  check('there was no PR to report the halt on', result.halt_reported_to ?? null, null)
}

async function main() {
  await scenarioUnsupportedLanguage()
  await scenarioImplementCeiling()
  await scenarioFixHalts()
  await scenarioMutationHalts()
  await scenarioMutationNeedsUserRun()
  await scenarioMutationHaltWithNoDraft()
  if (failures) { console.log(`\nFAILED: ${failures} assertion(s)`); process.exit(1) }
  console.log('\nOK (unsupported-language halt harness)')
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
