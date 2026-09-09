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
check "the Mutation prompt says never create/edit/delete the markers" \
  "$(grep -Fc 'Never create, edit or delete .crap-gated or' "$SCRIPT" || true)" 3
check "IMPL, FIXED and GATE each declare unsupported_language as a property" \
  "$(grep -Fc "unsupported_language: { type: 'boolean' }" "$SCRIPT" || true)" 3

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
    if (label === 'implementer') {
      return scenario.implementer
    }
    if (label === 'draft-pr') {
      captured.draftPrCalled = true
      return { opened: false, detail: 'should not be reached' }
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
    budget: scenario.budget ?? { total: null, spent: () => 0, remaining: () => Infinity },
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
    },
  })
  check('halted at Implement', result.halted_at, 'Implement')
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
        { title: 'off-by-one', file: 'a.go', claim: 'loop skips the last element',
          evidence: 'a.go:12' },
      ] },
      'fix:1': {
        head_sha: 'impl0000000000000000000000000000000000000',
        note: 'NEXT_ACTION is UNSUPPORTED_LANGUAGE: three options are (1) add ' +
          'support, (2) drop .crap-gated, (3) proceed ungated. Halting rather ' +
          'than editing the marker.',
        scored: false, unsupported_language: true,
      },
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
  check('regression suspects reach the halt payload',
    Array.isArray(result.regression_suspects), true)
  // Closing the stage is what records its spend, so an early return that skips
  // it reports a Fix halt whose fix phase apparently cost nothing.
  check('the fix stage spend is recorded',
    Object.prototype.hasOwnProperty.call(result.stage_spend ?? {}, 'fix'), true)
}

async function scenarioMutationHalts() {
  console.log('\n== scenario: a mutation agent reporting unsupported_language halts at Mutation')
  const { result } = await run({
    args: { maxGateAttempts: 3 },
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
        unsupported_language: true,
      },
    },
  })
  check('halted at Mutation', result.halted_at, 'Mutation')
  check('the halt note names UNSUPPORTED_LANGUAGE, not surviving mutants', {
    names_unsupported: /UNSUPPORTED_LANGUAGE/.test(result.note ?? ''),
    blames_mutants: /[Ss]urviving/.test(result.note ?? ''),
  }, { names_unsupported: true, blames_mutants: false })
}

async function main() {
  await scenarioUnsupportedLanguage()
  await scenarioFixHalts()
  await scenarioMutationHalts()
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
