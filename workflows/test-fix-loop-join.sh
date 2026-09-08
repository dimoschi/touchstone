#!/usr/bin/env bash
# Regression test for deliver-pipeline.js's fix-loop verdict join.
#
# The bug this guards against: the fix loop used to match a verifier's verdict
# back to a finding by the model-generated title, and asked the verifier to
# echo that title "verbatim". A reworded title could never match, so the
# finding was never cleared and the run halted for good after
# MAX_REVIEW_ROUNDS. The fix keys the join on an id the script assigns itself
# in reviewOf, never on anything a model produces.
#
# Three things are checked:
#   1. Static assertions on the source: the join reads only v.id, the
#      verifier's brief no longer asks for order or a verbatim title, and the
#      VERDICTS schema requires id.
#   2. The staleness probe's git command, run for real against a scratch repo,
#      so the exact command in the prompt is proven to answer "did this file
#      change" correctly rather than merely parsed as a string.
#   3. The fix loop's actual join behaviour, by running the real script (not a
#      reimplementation of its logic) under stubbed globals: a fake agent()
#      that answers each labelled call the way a real subagent would, with
#      just enough shape to drive the script through Review -> Fix -> the
#      loop's exits.
#
# Needs git and node. Exit 0 all green, 1 any assertion failed.

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

echo "== static: the join reads only v.id, never v.title"
check "no v.title reference remains" \
  "$(grep -c 'v\.title' "$SCRIPT" || true)" 0

echo "== static: VERDICTS requires id, title is optional"
check "VERDICTS lists id in its required array" \
  "$(grep -c "required: \['id', 'fixed', 'note'\]" "$SCRIPT" || true)" 1

echo "== static: the verifier's brief no longer demands order or a verbatim title"
# The old instruction, word for word. A hit elsewhere in the file (an
# unrelated comment, or this test's own header explaining the old bug) must
# not trip this, so the check is the exact old phrase, not the bare word.
check "the old 'title verbatim' instruction is gone" \
  "$(grep -Fc 'with the same title verbatim' "$SCRIPT" || true)" 0
check "the old 'one verdict per finding ... in the same order' instruction is gone" \
  "$(grep -Fc 'in the same order, with the same' "$SCRIPT" || true)" 0
# The verify brief, the staleness probe and the cross-lens dedup brief. Every
# brief that lists findings renders the id, because every one of them is joined
# back on it.
check "each brief that lists findings renders its id in brackets" \
  "$(grep -c '\[\${f\.id}\]' "$SCRIPT" || true)" 3

echo ""
echo "== static: the staleness probe checks evidence, not merely the file"
# Wrapped across two lines in the source, same as the old --oneline check, so
# checked as two substrings rather than one.
check "the probe reads the diff (git log -p), not just the commit list" \
  "$(grep -Fc 'git log -p' "$SCRIPT" || true)" 1
check "the probe still scopes the diff to <recorded_at>..HEAD" \
  "$(grep -Fc '<recorded_at>..HEAD' "$SCRIPT" || true)" 1
check "the probe hands the finding's evidence to the agent" \
  "$(grep -Fc 'Evidence: ${f.evidence}' "$SCRIPT" || true)" 1

echo ""
echo "== staleness probe: the git command against a real scratch repo"
# The prompt wraps this across two lines; checked as two substrings rather
# than one so a rewrap does not make this test outrun the actual source.
check "the prompt gives the path-scoping half of the command" \
  "$(grep -Fc -- '-- <file>' "$SCRIPT" || true)" 1

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

REPO="$WORK/scratch"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name test
git -C "$REPO" config commit.gpgsign false

echo "one" > "$REPO/changed.txt"
echo "one" > "$REPO/untouched.txt"
git -C "$REPO" add changed.txt untouched.txt
git -C "$REPO" commit -qm "recorded_at: both files exist"
RECORDED_AT="$(git -C "$REPO" rev-parse HEAD)"

echo "two" > "$REPO/changed.txt"
git -C "$REPO" add changed.txt
git -C "$REPO" commit -qm "a later round touches changed.txt only"

run_template() {
  local file="$1"
  # Same shape as the prompt, with <recorded_at> and <file> substituted.
  git -C "$REPO" log -p "$RECORDED_AT..HEAD" -- "$file"
}

check "a file with a commit in the range reports non-empty" \
  "$([ -n "$(run_template changed.txt)" ] && echo yes || echo no)" yes
check "a file with no commit in the range reports empty" \
  "$([ -n "$(run_template untouched.txt)" ] && echo yes || echo no)" no

echo ""
echo "== fix loop: running the real script under stubbed globals"

cat > "$WORK/harness.mjs" <<'JS_EOF'
import fs from 'node:fs'
import vm from 'node:vm'

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
// verify and staleness stubs learn which ids the script actually assigned,
// without the scenario needing to predict them.
function idsIn(prompt) {
  return [...prompt.matchAll(/\[(f\d+)\]/g)].map(m => m[1])
}

function makeAgent(scenario, captured) {
  return async (prompt, opts) => {
    const label = opts.label
    captured.calls.push({ label, prompt })

    if (label === 'ticket') {
      return { found: true, summary: 'stub ticket', description: 'd', comments: '' }
    }
    if (label === 'branch') {
      return { created: true, branch: 'feat/gh-21-stub', base: 'main',
        path: '/tmp/stub-worktree', ticket: '21', detail: 'stub' }
    }
    if (label === 'triage') {
      // scope: 'inline' skips the Plan phase, which this test has no reason
      // to exercise: it is not part of the join this ticket fixes.
      return { scope: 'inline', complexity: 'trivial', complexity_note: 'stub',
        premise_ok: true, estimated_loc: 5, evidence: [], premise_note: 'stub',
        ...(scenario.triage ?? {}) }
    }
    if (label === 'implementer') {
      return { summary: 'stub implementation', files_changed: ['a.js', 'b.js'],
        commit_range: COMMIT_RANGE, insertions: 20, scored: scenario.implScored ?? true }
    }
    if (label === 'draft-pr') {
      return scenario.draftPr ?? { opened: false, detail: 'no draft in this test' }
    }
    if (label.startsWith('halt-notice:')) {
      captured.haltNoticePrompt = prompt
      return true
    }
    if (label === 'run-record') {
      captured.runRecordPrompt = prompt
      if (scenario.runRecordFails) return null
      return '/stub/main/.claude/touchstone-runs/21.json'
    }
    if (label === 'regression-notice') {
      captured.regressionNoticePrompt = prompt
      return scenario.regressionNoticePosts !== false
    }
    if (label === 'review:dedup') {
      captured.dedupPrompt = prompt
      return { groups: scenario.dedupGroups ?? [] }
    }
    if (label.startsWith('review:fix:')) {
      return { findings: scenario.tailReview ?? [] }
    }
    if (label.startsWith('review:mutation:')) {
      return { findings: scenario.postMutationReview ?? [] }
    }
    if (label.startsWith('review:')) {
      const lens = label.slice('review:'.length)
      return { findings: (scenario.initialReview ?? {})[lens] ?? [] }
    }
    if (label.startsWith('fix:')) {
      const round = Number(label.slice('fix:'.length))
      const head = scenario.fixHead ? scenario.fixHead(round) : REVIEWED_THROUGH
      const scored = scenario.fixScored ? scenario.fixScored(round) : false
      return { head_sha: head, note: `stub fix round ${round}`, scored,
        ...(scenario.gateNote ? { gate_note: scenario.gateNote } : {}) }
    }
    if (label.startsWith('verify:')) {
      // The late pass is labelled verify:final, not by round: it runs after the
      // loop, on findings no round ever checked.
      const suffix = label.slice('verify:'.length)
      const round = suffix === 'final' ? 'final' : Number(suffix)
      const ids = idsIn(prompt)
      const verdicts = []
      for (const id of ids) {
        const decision = scenario.verify(id, round)
        if (decision === undefined) continue
        // A different title every time: the whole point is that this is
        // never read for matching. verifyBracketed copies the id exactly as
        // the prompt renders it, brackets included -- the near-miss a plain
        // trim was not enough to strip.
        const returnedId = scenario.verifyBracketed ? `[${id}]` : id
        verdicts.push({ id: returnedId, fixed: decision === true, title: `reworded-${id}-r${round}`,
          note: `stub verdict for ${id}` })
      }
      if (scenario.injectBogusVerdict) {
        verdicts.push({ id: 'f999-not-a-real-finding', fixed: true, title: 'bogus', note: 'should be discarded' })
      }
      return { verdicts }
    }
    if (label === 'gate:opt-in') {
      if (scenario.gateProbeFails) return null
      return { crap_gated: scenario.crapGated ?? true,
        mutation_gated: scenario.mutationGated ?? false, detail: 'stub' }
    }
    if (label.startsWith('mutation:')) {
      const attempt = Number(label.slice('mutation:'.length))
      return (scenario.mutationResult ?? (() => ({ green: true, head_sha: REVIEWED_THROUGH, detail: 'stub' })))(attempt)
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
  const captured = { calls: [], haltNoticePrompt: null, regressionNoticePrompt: null,
    runRecordPrompt: null, dedupPrompt: null, logs: [] }
  const sandbox = {
    args: baseArgs(scenario.args),
    agent: makeAgent(scenario, captured),
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
    budget: scenario.budget ?? { total: null, spent: () => 0, remaining: () => Infinity },
  }
  const ctx = vm.createContext(sandbox)
  const fn = vm.compileFunction(body, [], { parsingContext: ctx })
  const result = await fn()
  return { result, captured }
}

function callCount(captured, label) {
  return captured.calls.filter(c => c.label === label).length
}

// Scenario A -- the regression this ticket is about: a verifier that rewords
// every title still clears every finding, because the join reads id.
async function scenarioA() {
  console.log('\n== scenario A: reworded titles still clear via id')
  const { result } = await run({
    initialReview: {
      correctness: [{ title: 'Off-by-one in parser', file: 'src/parser.js',
        claim: 'boundary is wrong', evidence: 'parser.js:12' }],
      advocate: [],
    },
    verify: (id) => id === 'f1' ? true : undefined,
  })
  check('halted_at is absent (the run finished)', result.halted_at, undefined)
  check('unresolved_findings is empty', result.unresolved_findings, [])
  check('the loop took exactly 1 round', result.fix_rounds, 1)
}

// Scenario B -- two findings from different lenses share a title. Before this
// fix a title-keyed join would treat one verdict as clearing both.
async function scenarioB() {
  console.log('\n== scenario B: identical titles still get distinct ids')
  const { result, captured } = await run({
    args: { maxReviewRounds: 1 },
    initialReview: {
      correctness: [{ title: 'Dup Finding', file: 'fileA.js', claim: 'c1', evidence: 'e1' }],
      advocate: [{ title: 'Dup Finding', file: 'fileB.js', claim: 'c2', evidence: 'e2' }],
    },
    verify: (id) => id === 'f1' ? true : (id === 'f2' ? false : undefined),
    staleness: () => [],
  })
  const verifyPrompt = captured.calls.find(c => c.label === 'verify:1')?.prompt ?? ''
  check('the verifier saw both f1 and f2 for the identical title',
    idsIn(verifyPrompt).sort(), ['f1', 'f2'])
  check('halted at Fix', result.halted_at, 'Fix')
  check('only the unresolved finding remains open', result.unresolved_findings.length, 1)
  check('the surviving finding is the advocate\'s, not the correctness one',
    result.unresolved_findings[0].file, 'fileB.js')
}

// Scenario G -- a verdict for an id that names no open finding is discarded,
// and a finding with no verdict at all stays open.
async function scenarioG() {
  console.log('\n== scenario G: an unmatched verdict id is discarded, silence stays open')
  const { result } = await run({
    args: { maxReviewRounds: 1 },
    initialReview: {
      correctness: [{ title: 'Lonely Finding', file: 'only.js', claim: 'c', evidence: 'e' }],
      advocate: [],
    },
    verify: () => undefined, // no verdict at all for the real finding
    injectBogusVerdict: true, // a verdict for an id that names nothing open
    staleness: () => [],
  })
  check('halted at Fix', result.halted_at, 'Fix')
  check('the unverified finding stayed open', result.unresolved_findings.length, 1)
  check('it is still the same finding', result.unresolved_findings[0].file, 'only.js')
}

// Scenario C -- the staleness probe marks a surviving finding whose file has
// moved on, and the halt note says how many.
async function scenarioC() {
  console.log('\n== scenario C: staleness marks a finding whose code has moved on')
  const { result, captured } = await run({
    args: { maxReviewRounds: 1 },
    draftPr: { opened: true, url: 'https://example.test/pr/1', number: 1, detail: 'stub' },
    initialReview: {
      correctness: [{ title: 'Dup Finding', file: 'fileA.js', claim: 'c1', evidence: 'e1' }],
      advocate: [{ title: 'Dup Finding', file: 'fileB.js', claim: 'c2', evidence: 'e2' }],
    },
    verify: (id) => id === 'f1' ? true : (id === 'f2' ? false : undefined),
    staleness: (ids) => ids.map(id => ({ id, changed: true })),
  })
  check('staleness ran exactly once, not once per finding', callCount(captured, 'staleness'), 1)
  check('halted at Fix', result.halted_at, 'Fix')
  check('the surviving finding is still reported', result.unresolved_findings.length, 1)
  check('it is marked as changed since it was recorded',
    result.unresolved_findings[0].code_changed_since_recorded, true)
  check('the halt note says one finding needs a re-check',
    /1 of them have code that changed/.test(result.note), true)
  const expectedLine =
    `1. Dup Finding (fileB.js): c2 [code changed since recorded; re-check against HEAD]`
  check('the PR halt comment renders the re-check marker for it',
    (captured.haltNoticePrompt ?? '').includes(expectedLine), true)
}

// Scenario D -- the probe itself returns nothing (a dead subagent). The halt
// must still fire, flat, with no exception.
async function scenarioD() {
  console.log('\n== scenario D: a null staleness result still produces a flat halt')
  const { result } = await run({
    args: { maxReviewRounds: 1 },
    initialReview: {
      correctness: [{ title: 'Dup Finding', file: 'fileA.js', claim: 'c1', evidence: 'e1' }],
      advocate: [{ title: 'Dup Finding', file: 'fileB.js', claim: 'c2', evidence: 'e2' }],
    },
    verify: (id) => id === 'f1' ? true : (id === 'f2' ? false : undefined),
    staleness: null,
  })
  check('halted at Fix, no exception', result.halted_at, 'Fix')
  check('the surviving finding is reported unmarked',
    result.unresolved_findings[0].code_changed_since_recorded, undefined)
  check('the note carries no re-check count', /changed since they were recorded/.test(result.note), false)
}

// Scenario E -- the probe returns a malformed shape (results not an array).
// Same contract as a null result: no crash, nothing marked.
async function scenarioE() {
  console.log('\n== scenario E: a malformed staleness result still produces a flat halt')
  const { result } = await run({
    args: { maxReviewRounds: 1 },
    initialReview: {
      correctness: [{ title: 'Dup Finding', file: 'fileA.js', claim: 'c1', evidence: 'e1' }],
      advocate: [{ title: 'Dup Finding', file: 'fileB.js', claim: 'c2', evidence: 'e2' }],
    },
    verify: (id) => id === 'f1' ? true : (id === 'f2' ? false : undefined),
    staleness: 'malformed',
  })
  check('halted at Fix, no exception', result.halted_at, 'Fix')
  check('the surviving finding is reported unmarked',
    result.unresolved_findings[0].code_changed_since_recorded, undefined)
}

// Scenario H -- the post-mutation Review halt renders exactly as it did
// before this change: its findings pass through the same reviewOf as
// everything else and now carry an id and recorded_at, but never
// code_changed_since_recorded, so the comment must carry no marker.
async function scenarioH() {
  console.log('\n== scenario H: the post-mutation Review halt is unmarked, byte for byte')
  const mutHead = 'mut0000000000000000000000000000000000001'
  const { result, captured } = await run({
    draftPr: { opened: true, url: 'https://example.test/pr/2', number: 2, detail: 'stub' },
    initialReview: { correctness: [], advocate: [] }, // no Fix-loop findings at all
    verify: () => undefined,
    mutationGated: true,
    mutationResult: () => ({ green: true, head_sha: mutHead, detail: 'stub green' }),
    postMutationReview: [{ title: 'Mutation gate introduced X', file: 'mutfile.js',
      claim: 'c', evidence: 'e' }],
  })
  check('halted at Review (the mutation gate\'s own commits)', result.halted_at, 'Review')
  check('exactly the one post-mutation finding is reported', result.unresolved_findings.length, 1)
  const expectedLine = `1. Mutation gate introduced X (mutfile.js): c`
  check('the comment renders that finding with no marker at all',
    (captured.haltNoticePrompt ?? '').includes(expectedLine), true)
  check('no re-check marker text leaked into the comment',
    (captured.haltNoticePrompt ?? '').includes('code changed since recorded'), false)
}

// Scenario I -- a verifier that copies the id exactly as the prompt renders
// it, brackets included, must still clear the finding. This is the same
// permanent-halt failure the ticket fixes, just triggered by a bracket
// instead of a reworded title.
async function scenarioI() {
  console.log('\n== scenario I: a bracketed verdict id ([f1]) still clears the finding')
  const { result } = await run({
    initialReview: {
      correctness: [{ title: 'Off-by-one in parser', file: 'src/parser.js',
        claim: 'boundary is wrong', evidence: 'parser.js:12' }],
      advocate: [],
    },
    verify: (id) => id === 'f1' ? true : undefined,
    verifyBracketed: true,
  })
  check('halted_at is absent (the run finished)', result.halted_at, undefined)
  check('unresolved_findings is empty', result.unresolved_findings, [])
}

// Scenario J -- same bracket near-miss, on the staleness probe's join.
async function scenarioJ() {
  console.log('\n== scenario J: a bracketed staleness id ([f2]) still marks the finding')
  const { result } = await run({
    args: { maxReviewRounds: 1 },
    initialReview: {
      correctness: [{ title: 'Dup Finding', file: 'fileA.js', claim: 'c1', evidence: 'e1' }],
      advocate: [{ title: 'Dup Finding', file: 'fileB.js', claim: 'c2', evidence: 'e2' }],
    },
    verify: (id) => id === 'f1' ? true : (id === 'f2' ? false : undefined),
    staleness: (ids) => ids.map(id => ({ id, changed: true })),
    stalenessBracketed: true,
  })
  check('the surviving finding is marked as changed despite the bracketed id',
    result.unresolved_findings[0].code_changed_since_recorded, true)
}

// Scenario K -- a tail-review finding that happens to share a title with a
// finding the same round just settled must not be dropped for it: the two
// are unrelated, and only their model-generated title collides.
async function scenarioK() {
  console.log('\n== scenario K: a tail-review finding is not dropped for sharing a title with a settled one')
  const { result } = await run({
    args: { maxReviewRounds: 1 },
    initialReview: {
      correctness: [{ title: 'Same Title', file: 'orig.js', claim: 'c1', evidence: 'e1' }],
      advocate: [],
    },
    verify: (id) => id === 'f1' ? true : undefined,
    fixHead: () => 'fix00000000000000000000000000000000000001',
    tailReview: [{ title: 'Same Title', file: 'new.js', claim: 'c2', evidence: 'e2' }],
    staleness: () => [],
  })
  check('halted at Fix', result.halted_at, 'Fix')
  check('exactly the fresh finding survives', result.unresolved_findings.length, 1)
  check('it is the fresh finding, not the one already settled',
    result.unresolved_findings[0]?.file, 'new.js')
}

// Scenario L -- same collision, one stage later: a post-mutation finding
// sharing a title with a finding the fix loop already settled must still
// reach the halt.
async function scenarioL() {
  console.log('\n== scenario L: a post-mutation finding is not dropped for sharing a title with a settled one')
  const { result } = await run({
    initialReview: {
      correctness: [{ title: 'Repeated Title', file: 'orig.js', claim: 'c-orig', evidence: 'e-orig' }],
      advocate: [],
    },
    verify: (id) => id === 'f1' ? true : undefined,
    staleness: () => [],
    mutationGated: true,
    mutationResult: () => ({ green: true, head_sha: 'mut0000000000000000000000000000000000001', detail: 'stub green' }),
    postMutationReview: [{ title: 'Repeated Title', file: 'mutfile.js',
      claim: 'a different bug', evidence: 'e2' }],
  })
  check('halted at Review', result.halted_at, 'Review')
  check('exactly the post-mutation finding survives', result.unresolved_findings.length, 1)
  check('it is the post-mutation finding, not the one already settled',
    result.unresolved_findings[0]?.file, 'mutfile.js')
}

// Scenario M -- budget is already exhausted, so the fix loop runs zero
// rounds. The staleness probe must not fire: nothing could have changed,
// same guard as every other optional dispatch here.
async function scenarioM() {
  console.log('\n== scenario M: the staleness probe is skipped once the run is out of budget')
  const { result, captured } = await run({
    budget: { total: 200000, spent: () => 190000, remaining: () => 5000 },
    initialReview: {
      correctness: [{ title: 'Needs budget', file: 'fileA.js', claim: 'c', evidence: 'e' }],
      advocate: [],
    },
    verify: () => undefined,
  })
  check('staleness never ran', callCount(captured, 'staleness'), 0)
  check('halted at Fix', result.halted_at, 'Fix')
  check('the loop ran zero rounds', result.fix_rounds, 0)
  check('the surviving finding is reported unmarked',
    result.unresolved_findings[0]?.code_changed_since_recorded, undefined)
  check('the note blames the overall token budget',
    /passed its overall token budget/.test(result.note), true)
}

// Scenario N -- the staleness probe itself rejects (a dead subagent, not
// merely an empty answer). The halt must still return, not throw.
async function scenarioN() {
  console.log('\n== scenario N: a rejected staleness probe does not take the halt down with it')
  const { result } = await run({
    args: { maxReviewRounds: 1 },
    initialReview: {
      correctness: [{ title: 'Dup Finding', file: 'fileA.js', claim: 'c1', evidence: 'e1' }],
      advocate: [{ title: 'Dup Finding', file: 'fileB.js', claim: 'c2', evidence: 'e2' }],
    },
    verify: (id) => id === 'f1' ? true : (id === 'f2' ? false : undefined),
    staleness: 'reject',
  })
  check('halted at Fix, no exception', result.halted_at, 'Fix')
  check('the surviving finding is reported unmarked',
    result.unresolved_findings[0]?.code_changed_since_recorded, undefined)
}

// Scenario O -- an identical re-report: the tail review re-detects the exact
// same finding (same title, file, claim, evidence) that a verifier just
// confirmed fixed. Unlike K, nothing here differs -- this is the case the
// settled guard exists for, and keying it on id (which is always freshly
// minted) can never catch it.
async function scenarioO() {
  console.log('\n== scenario O: an identical re-report of a settled finding is not reopened')
  const { result } = await run({
    initialReview: {
      correctness: [{ title: 'Off-by-one in parser', file: 'src/parser.js',
        claim: 'boundary is wrong', evidence: 'parser.js:12' }],
      advocate: [],
    },
    verify: (id) => id === 'f1' ? true : undefined,
    fixHead: () => 'fix00000000000000000000000000000000000001',
    tailReview: [{ title: 'Off-by-one in parser', file: 'src/parser.js',
      claim: 'boundary is wrong', evidence: 'parser.js:12' }],
    staleness: () => [],
  })
  check('halted_at is absent (the run finished, the re-report was suppressed)',
    result.halted_at, undefined)
  check('unresolved_findings is empty', result.unresolved_findings, [])
}

// Scenario P -- same identical re-report, one stage later: the post-mutation
// review re-detects a finding the fix loop already settled. It must not
// reach the halt.
async function scenarioP() {
  console.log('\n== scenario P: an identical re-report at the post-mutation stage is not reopened')
  const { result } = await run({
    initialReview: {
      correctness: [{ title: 'Off-by-one in parser', file: 'src/parser.js',
        claim: 'boundary is wrong', evidence: 'parser.js:12' }],
      advocate: [],
    },
    verify: (id) => id === 'f1' ? true : undefined,
    staleness: () => [],
    mutationGated: true,
    mutationResult: () => ({ green: true, head_sha: 'mut0000000000000000000000000000000000001', detail: 'stub green' }),
    postMutationReview: [{ title: 'Off-by-one in parser', file: 'src/parser.js',
      claim: 'boundary is wrong', evidence: 'parser.js:12' }],
  })
  check('halted_at is absent (the run finished, the re-report was suppressed)',
    result.halted_at, undefined)
}

// Scenario Q -- the staleness probe must run even when the loop stopped on
// budget only after a round already ran and committed, not merely when the
// loop never got to run at all. Round 0 (scenario M) is the only state where
// skipping it is safe.
async function scenarioQ() {
  console.log('\n== scenario Q: the staleness probe still runs when budget ran out after a round already committed')
  let roundsRan = 0
  const { result, captured } = await run({
    budget: { total: 200000, spent: () => 0, remaining: () => (roundsRan > 0 ? 100 : 999999) },
    args: { maxReviewRounds: 3 },
    initialReview: {
      correctness: [{ title: 'Needs more rounds', file: 'fileA.js', claim: 'c', evidence: 'e' }],
      advocate: [],
    },
    verify: (id, round) => { roundsRan = round; return undefined },
    staleness: (ids) => ids.map(id => ({ id, changed: true })),
  })
  check('staleness ran despite the loop stopping on budget after a round',
    callCount(captured, 'staleness'), 1)
  check('halted at Fix', result.halted_at, 'Fix')
  check('the loop ran exactly 1 round before budget stopped it', result.fix_rounds, 1)
  check('the surviving finding is marked as changed since it was recorded',
    result.unresolved_findings[0]?.code_changed_since_recorded, true)
}

// Scenario R -- a reworded re-report of a settled finding. Unlike O (a
// byte-identical re-report), every field here differs from the original: only
// duplicate_of, copied from the known-findings list the tail-review lens was
// handed, ties it back. A join that still relies on title/file/claim/evidence
// matching (exactly the failure ticket 21 fixed for verdicts) cannot catch
// this; the run must finish rather than reopen already-fixed code.
async function scenarioR() {
  console.log('\n== scenario R: a reworded re-report of a settled finding is not reopened')
  const { result, captured } = await run({
    initialReview: {
      correctness: [{ title: 'Off-by-one in parser', file: 'src/parser.js',
        claim: 'boundary is wrong', evidence: 'parser.js:12' }],
      advocate: [],
    },
    verify: (id) => id === 'f1' ? true : undefined,
    fixHead: () => 'fix00000000000000000000000000000000000001',
    tailReview: [{ title: 'Boundary check excludes the last element', file: 'parser.js',
      claim: 'off-by-one at the array end', evidence: 'see loop condition',
      duplicate_of: 'f1' }],
    staleness: () => [],
  })
  const tailPrompt = captured.calls.find(c => c.label.startsWith('review:fix:1:'))?.prompt ?? ''
  check('the tail-review lens was handed the settled finding\'s id',
    tailPrompt.includes('[f1]'), true)
  check('halted_at is absent (the run finished, the reworded re-report was recognized)',
    result.halted_at, undefined)
  check('unresolved_findings is empty', result.unresolved_findings, [])
  check('the re-report is recorded as a regression suspect, not dropped in silence',
    result.regression_suspects?.length, 1)
  check('the suspect names the settled finding it was pointed at',
    result.regression_suspects?.[0]?.duplicate_of, 'f1')
}

// Scenario S -- a finding that stays open gets re-reported each round with
// drifting wording. Before this fix, full-content equality no longer matched
// the copy already in `open`, so each round appended another entry for the
// same bug. duplicate_of, referencing the still-open finding's id, must keep
// it to exactly one entry across both rounds.
async function scenarioS() {
  console.log('\n== scenario S: a reworded re-report of a still-open finding does not inflate open into two entries')
  const { result, captured } = await run({
    args: { maxReviewRounds: 2 },
    initialReview: {
      correctness: [{ title: 'Foo bug', file: 'f.js', claim: 'c1', evidence: 'e1' }],
      advocate: [],
    },
    verify: (id, round) => id === 'f1' ? (round === 2 ? true : false) : undefined,
    fixHead: (round) => `fix0000000000000000000000000000000000000${round}`,
    tailReview: [{ title: 'Different wording of foo bug', file: 'f.js',
      claim: 'reworded claim', evidence: 'reworded evidence', duplicate_of: 'f1' }],
    staleness: () => [],
  })
  const verify2Prompt = captured.calls.find(c => c.label === 'verify:2')?.prompt ?? ''
  check('round 2 verifies exactly one finding, not two',
    idsIn(verify2Prompt).length, 1)
  check('halted_at is absent (the run finished, both rounds resolved the one bug)',
    result.halted_at, undefined)
}

// Scenario T -- the mirror of P, one word different in kind: the post-mutation
// lens does not restate a settled finding, it *references* it against the
// mutation gate's own commits. That is a claim the gate undid a verified fix,
// and there are no fix rounds left to absorb it, so it must halt rather than
// be filtered away like P's byte-identical restatement.
async function scenarioT() {
  console.log('\n== scenario T: a referenced re-report at the post-mutation stage halts')
  const { result, captured } = await run({
    initialReview: {
      correctness: [{ title: 'Off-by-one in parser', file: 'src/parser.js',
        claim: 'boundary is wrong', evidence: 'parser.js:12' }],
      advocate: [],
    },
    verify: (id) => id === 'f1' ? true : undefined,
    staleness: () => [],
    mutationGated: true,
    mutationResult: () => ({ green: true, head_sha: 'mut0000000000000000000000000000000000001', detail: 'stub green' }),
    postMutationReview: [{ title: 'Boundary check excludes the last element', file: 'parser.js',
      claim: 'the mutation commits reverted the guard', evidence: 'parser.js:14',
      duplicate_of: 'f1' }],
  })
  check('halted at Review', result.halted_at, 'Review')
  check('the finding reaches the halt rather than being filtered',
    result.unresolved_findings?.length, 1)
  const lensPrompt = captured.calls.find(c => c.label.startsWith('review:mutation:'))?.prompt ?? ''
  check('the lens is told a reference means these commits undid a fix',
    lensPrompt.includes('undid one of those fixes'), true)
  check('the lens is told what referencing costs',
    lensPrompt.includes('ends the run with no pull request'), true)
  check('the lens is told a defect outside this range is not a finding here',
    lensPrompt.includes('commits do not touch is not a finding'), true)
}

// Scenario U -- a re-report that is byte-identical AND sets duplicate_of. It
// is a restatement: matching all four fields means the text was copied from
// the known list. Testing the reference before the content would promote it to
// a fresh claim, which costs a spurious suspect here and a halt at the gate.
async function scenarioU() {
  console.log('\n== scenario U: an identical re-report that also sets duplicate_of stays a restatement')
  const { result } = await run({
    initialReview: {
      correctness: [{ title: 'Off-by-one in parser', file: 'src/parser.js',
        claim: 'boundary is wrong', evidence: 'parser.js:12' }],
      advocate: [],
    },
    verify: (id) => id === 'f1' ? true : undefined,
    fixHead: () => 'fix00000000000000000000000000000000000001',
    tailReview: [{ title: 'Off-by-one in parser', file: 'src/parser.js',
      claim: 'boundary is wrong', evidence: 'parser.js:12', duplicate_of: 'f1' }],
    staleness: () => [],
  })
  check('halted_at is absent (the run finished)', result.halted_at, undefined)
  check('unresolved_findings is empty', result.unresolved_findings, [])
  check('it is dropped as a restatement, not recorded as a suspect',
    result.regression_suspects?.length, 0)
}

// Scenario V -- the halt note says "see regression_suspects", so the comment
// that outlives the session has to contain them. The payload does not survive
// the run; the PR comment is the whole point of halted() being async.
async function scenarioV() {
  console.log('\n== scenario V: the halt comment is handed the regression suspects')
  const { result, captured } = await run({
    args: { maxReviewRounds: 1 },
    draftPr: { opened: true, number: 23, url: 'https://example.invalid/pr/23', detail: 'stub draft' },
    initialReview: {
      correctness: [
        { title: 'Off-by-one in parser', file: 'src/parser.js',
          claim: 'boundary is wrong', evidence: 'parser.js:12' },
        { title: 'Unrelated leak', file: 'src/pool.js',
          claim: 'connection is never released', evidence: 'pool.js:40' },
      ],
      advocate: [],
    },
    verify: (id) => id === 'f1' ? true : undefined,
    fixHead: () => 'fix00000000000000000000000000000000000001',
    tailReview: [{ title: 'Boundary check excludes the last element', file: 'parser.js',
      claim: 'off-by-one at the array end', evidence: 'see loop condition',
      duplicate_of: 'f1' }],
    staleness: () => [],
  })
  check('halted at Fix (the leak was never fixed)', result.halted_at, 'Fix')
  check('a suspect was recorded', result.regression_suspects?.length, 1)
  check('the halt note says the fixes need checking, without naming a JSON field',
    (result.note ?? '').includes('check by hand that those fixes held'), true)
  check('the halt note does not leak the field name into prose',
    (result.note ?? '').includes('regression_suspects'), false)
  check('the comment prompt carries the suspect claim',
    (captured.haltNoticePrompt ?? '').includes('off-by-one at the array end'), true)
  check('the comment prompt says the fix was verified and not reopened',
    (captured.haltNoticePrompt ?? '').includes('not reopened'), true)
}

// Scenario W -- a green run that recorded a suspect. The findings all cleared,
// so nothing halts and the PR goes ready; without a comment the suspect exists
// only in a return value nobody reads.
async function scenarioW() {
  console.log('\n== scenario W: a green run reports its regression suspects on the PR')
  const { result, captured } = await run({
    args: { openPr: true },
    draftPr: { opened: true, number: 23, url: 'https://example.invalid/pr/23', detail: 'stub draft' },
    prResult: { opened: true, url: 'https://example.invalid/pr/23', note: 'stub ready' },
    initialReview: {
      correctness: [{ title: 'Off-by-one in parser', file: 'src/parser.js',
        claim: 'boundary is wrong', evidence: 'parser.js:12' }],
      advocate: [],
    },
    verify: (id) => id === 'f1' ? true : undefined,
    fixHead: () => 'fix00000000000000000000000000000000000001',
    tailReview: [{ title: 'Boundary check excludes the last element', file: 'parser.js',
      claim: 'off-by-one at the array end', evidence: 'see loop condition',
      duplicate_of: 'f1' }],
    staleness: () => [],
  })
  check('halted_at is absent (every finding cleared)', result.halted_at, undefined)
  check('the suspect is in the result', result.regression_suspects?.length, 1)
  check('a comment was posted for it',
    callCount(captured, 'regression-notice'), 1)
  check('the comment prompt carries the suspect claim',
    (captured.regressionNoticePrompt ?? '').includes('off-by-one at the array end'), true)
  check('the comment writer is told to keep the process out of it',
    (captured.regressionNoticePrompt ?? '').includes('Do not name this workflow'), true)
}

// Scenarios X and Y -- the two exits past the fix loop, where a suspect from a
// round that converged is still live and must reach the comment.
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
      duplicate_of: 'f1' }],
    staleness: () => [],
    mutationGated: true,
    ...overrides,
  }
}

async function scenarioX() {
  console.log('\n== scenario X: the Mutation halt carries the regression suspects')
  const { result, captured } = await run(convergedWithSuspect({
    mutationResult: () => ({ green: false, head_sha: 'mut0000000000000000000000000000000000001',
      detail: 'stub red', survivors: 1 }),
  }))
  check('halted at Mutation', result.halted_at, 'Mutation')
  check('the suspect is in the payload', result.regression_suspects?.length, 1)
  check('the comment prompt carries the suspect claim',
    (captured.haltNoticePrompt ?? '').includes('off-by-one at the array end'), true)
}

async function scenarioY() {
  console.log('\n== scenario Y: the post-mutation Review halt carries the regression suspects')
  const { result, captured } = await run(convergedWithSuspect({
    mutationResult: () => ({ green: true, head_sha: 'mut0000000000000000000000000000000000001', detail: 'stub green' }),
    postMutationReview: [{ title: 'New nil deref in the added test helper',
      file: 'src/helper.js', claim: 'deref before the guard', evidence: 'helper.js:8' }],
  }))
  check('halted at Review', result.halted_at, 'Review')
  check('the suspect is in the payload', result.regression_suspects?.length, 1)
  check('the comment prompt carries the suspect claim',
    (captured.haltNoticePrompt ?? '').includes('off-by-one at the array end'), true)
  check('the genuinely new finding is still reported',
    result.unresolved_findings?.length, 1)
}

// Scenario Z -- the halt exits must write the record, since a halt is the case
// that most needs one, and it must be keyed and located so a later session can
// find it: by ticket, under the main checkout, not the worktree that goes away.
async function scenarioZ() {
  console.log('\n== scenario Z: a halt writes the run record into the repo')
  const { result, captured } = await run({
    args: { maxReviewRounds: 1 },
    initialReview: {
      correctness: [{ title: 'Unrelated leak', file: 'src/pool.js',
        claim: 'connection is never released', evidence: 'pool.js:40' }],
      advocate: [],
    },
    verify: () => false,
    fixHead: () => 'fix00000000000000000000000000000000000001',
    staleness: () => [],
  })
  const p = captured.runRecordPrompt ?? ''
  check('halted at Fix', result.halted_at, 'Fix')
  check('the record was written once', callCount(captured, 'run-record'), 1)
  check('its path is reported back in the payload',
    result.record_path, '/stub/main/.claude/touchstone-runs/21.json')
  check('it is keyed by ticket', p.includes('touchstone-runs/21.json'), true)
  check('it is written to the main checkout, not the worktree',
    p.includes('--git-common-dir'), true)
  check('the record carries the unresolved finding',
    p.includes('connection is never released'), true)
  check('the record carries the halt phase', p.includes('"halted_at": "Fix"'), true)
}

// Scenario AA -- the green path writes it too. A run that opened a PR is the
// one a later session is most likely to come back to.
async function scenarioAA() {
  console.log('\n== scenario AA: a green run writes the run record')
  const { result, captured } = await run({
    args: { openPr: true },
    prResult: { opened: true, url: 'https://example.invalid/pr/23', note: 'stub ready' },
    initialReview: { correctness: [], advocate: [] },
    verify: () => undefined,
    staleness: () => [],
  })
  check('halted_at is absent', result.halted_at, undefined)
  check('the record was written once', callCount(captured, 'run-record'), 1)
  check('the record carries the PR url',
    (captured.runRecordPrompt ?? '').includes('https://example.invalid/pr/23'), true)
}

// Scenario AB -- the write is best-effort. A dead record agent must not take
// down a run whose work is already committed.
async function scenarioAB() {
  console.log('\n== scenario AB: a failed record write does not take the run down')
  const { result } = await run({
    args: { openPr: true },
    runRecordFails: true,
    prResult: { opened: true, url: 'https://example.invalid/pr/23', note: 'stub ready' },
    initialReview: { correctness: [], advocate: [] },
    verify: () => undefined,
    staleness: () => [],
  })
  check('the run still returns its result', result.pr?.opened, true)
  check('record_path is null rather than missing', result.record_path, null)
}

// Scenario AC -- ceilings follow the same judgement as effort. A trivial change
// used to get trivial effort and the full 80k review ceiling.
async function scenarioAC() {
  console.log('\n== scenario AC: a trivial triage scales the ceilings down')
  const { captured } = await run({
    triage: { complexity: 'trivial' },
    initialReview: { correctness: [], advocate: [] },
    verify: () => undefined,
    staleness: () => [],
  })
  const logs = captured.logs.join('\n')
  check('the scale is reported with the effort', logs.includes('ceilings x0.4'), true)
  check('the review ceiling scales 80k -> 32k', logs.includes('(ceiling 32k)'), true)
  check('the fix ceiling scales 170k -> 68k', logs.includes('(ceiling 68k)'), true)
}

// Scenario AD -- an explicit budget is a decision, so scaling must not overrule
// it. The unlisted stages still scale.
async function scenarioAD() {
  console.log('\n== scenario AD: an explicit stage budget is not scaled')
  const { captured } = await run({
    triage: { complexity: 'trivial' },
    args: { stageBudgets: { fix: 170000 } },
    initialReview: { correctness: [], advocate: [] },
    verify: () => undefined,
    staleness: () => [],
  })
  const logs = captured.logs.join('\n')
  check('the fix ceiling keeps the value passed in', logs.includes('(ceiling 170k)'), true)
  check('it is named as exempt', logs.includes('fix left at the value you passed'), true)
  check('review still scales', logs.includes('(ceiling 32k)'), true)
}

// Scenario AE -- read wide, report narrow. The charge authorises reading past
// the range, and one run then reported a defect in a file the branch never
// touched, which cost a fix round.
async function scenarioAE() {
  console.log('\n== scenario AE: the lens is told to report only what these commits caused')
  const { captured } = await run({
    initialReview: { correctness: [], advocate: [] },
    verify: () => undefined,
    staleness: () => [],
  })
  const p = captured.calls.find(c => c.label === 'review:correctness')?.prompt ?? ''
  check('it may still read the surrounding code', p.includes('surrounding code as well'), true)
  check('it is told to report narrow', p.includes('Read wide, report narrow'), true)
  check('a pre-existing defect in untouched code is out of scope',
    p.includes('already there in code this range does not touch'), true)
}

// Scenarios AF and AG -- a finding the last round's tail review appended, which
// no round could have verified. AF: it was in fact fixed, so the run must not
// halt on it. AG: it was not, so the halt stands and says it was checked.
function lateFinding(fixedAtFinal) {
  return {
    args: { maxReviewRounds: 1 },
    initialReview: {
      correctness: [{ title: 'Off-by-one', file: 'src/p.js', claim: 'c1', evidence: 'e1' }],
      advocate: [],
    },
    verify: (id, round) => {
      if (round === 'final') return fixedAtFinal
      return id === 'f1' ? true : undefined
    },
    fixHead: () => 'fix00000000000000000000000000000000000001',
    tailReview: [{ title: 'Unrelated nil deref', file: 'src/q.js',
      claim: 'deref before guard', evidence: 'q.js:9' }],
    staleness: () => [],
  }
}

async function scenarioAF() {
  console.log('\n== scenario AF: a late finding that was already fixed does not halt the run')
  const { result, captured } = await run(lateFinding(true))
  check('the late pass ran once', callCount(captured, 'verify:final'), 1)
  check('halted_at is absent', result.halted_at, undefined)
  check('nothing is left open', result.unresolved_findings, [])
}

async function scenarioAG() {
  console.log('\n== scenario AG: a late finding that is real still halts, and says it was checked')
  const { result, captured } = await run(lateFinding(false))
  check('the late pass ran once', callCount(captured, 'verify:final'), 1)
  check('halted at Fix', result.halted_at, 'Fix')
  check('the finding is reported', result.unresolved_findings?.length, 1)
  check('the stop reason no longer claims it survived every round',
    (result.stopped_because ?? '').includes('survived every round'), false)
  check('the stop reason says it was checked',
    (result.stopped_because ?? '').includes('checked against the code'), true)
}

// Scenario AH -- two lenses, one defect. Both were counted, so every fix round
// paid for it twice.
async function scenarioAH() {
  console.log('\n== scenario AH: one defect found by two lenses becomes one finding')
  const { captured } = await run({
    args: { maxReviewRounds: 1 },
    initialReview: {
      correctness: [{ title: 'Nil deref in Load', file: 'src/p.js',
        claim: 'derefs before the guard', evidence: 'p.js:12' }],
      advocate: [{ title: 'Load can panic on a missing key', file: 'src/p.js',
        claim: 'no guard before the dereference', evidence: 'p.js:12-14' }],
    },
    dedupGroups: [{ ids: ['f1', 'f2'], why: 'same dereference' }],
    verify: () => undefined,
    fixHead: () => 'fix00000000000000000000000000000000000001',
    staleness: () => [],
  })
  check('the dedup brief was handed both ids',
    idsIn(captured.dedupPrompt ?? '').length, 2)
  const verify1 = captured.calls.find(c => c.label === 'verify:1')?.prompt ?? ''
  check('the fix round is asked about one finding, not two', idsIn(verify1).length, 1)
  check('the survivor is the first of the group', idsIn(verify1)[0], 'f1')
}

// Scenario AI -- the dedup agent returning nothing must keep both findings.
// Losing a real defect is the failure that matters here; a duplicate is not.
async function scenarioAI() {
  console.log('\n== scenario AI: a dedup that finds nothing keeps every finding')
  const { captured } = await run({
    args: { maxReviewRounds: 1 },
    initialReview: {
      correctness: [{ title: 'Bug one', file: 'a.js', claim: 'c1', evidence: 'e1' }],
      advocate: [{ title: 'Bug two', file: 'b.js', claim: 'c2', evidence: 'e2' }],
    },
    dedupGroups: [],
    verify: () => undefined,
    fixHead: () => 'fix00000000000000000000000000000000000001',
    staleness: () => [],
  })
  const verify1 = captured.calls.find(c => c.label === 'verify:1')?.prompt ?? ''
  check('both findings reach the fix round', idsIn(verify1).length, 2)
}

// Scenario AJ -- a gated repo's Fix halt reports the CRAP gate as confirmed:
// a raw commit could not have bypassed it.
async function scenarioAJ() {
  console.log('\n== scenario AJ: a gated repo\'s Fix halt reports the CRAP gate as confirmed')
  const { result } = await run({
    args: { maxReviewRounds: 1 },
    crapGated: true,
    initialReview: {
      correctness: [{ title: 'Unrelated leak', file: 'src/pool.js',
        claim: 'connection is never released', evidence: 'pool.js:40' }],
      advocate: [],
    },
    verify: () => false,
    staleness: () => [],
  })
  check('halted at Fix', result.halted_at, 'Fix')
  check('gates.measured is scored', result.gates?.measured, 'scored')
  check('gates.bypass_blocked is true', result.gates?.bypass_blocked, true)
  check('gates says a raw commit could not have bypassed it',
    (result.gates?.detail ?? '').includes('could not have bypassed it'), true)
}

// Scenario AK -- an ungated repo's Fix halt still reports what was measured;
// only the bypass claim in `detail` and `bypass_blocked` change with the marker.
async function scenarioAK() {
  console.log('\n== scenario AK: an ungated repo\'s Fix halt reports bypass_blocked=false')
  const { result } = await run({
    args: { maxReviewRounds: 1 },
    crapGated: false,
    initialReview: {
      correctness: [{ title: 'Unrelated leak', file: 'src/pool.js',
        claim: 'connection is never released', evidence: 'pool.js:40' }],
      advocate: [],
    },
    verify: () => false,
    staleness: () => [],
  })
  check('halted at Fix', result.halted_at, 'Fix')
  check('gates.measured is scored, the measurement is not conflated with the bypass question',
    result.gates?.measured, 'scored')
  check('gates.bypass_blocked is false', result.gates?.bypass_blocked, false)
  check('gates says a raw commit was not hook-blocked from bypassing it',
    (result.gates?.detail ?? '').includes('.crap-gated absent at the repo root'), true)
}

// Scenario AL -- the same distinction, one halt later: the Mutation halt must
// also keep reporting bypass_blocked=false in an ungated repo.
async function scenarioAL() {
  console.log('\n== scenario AL: an ungated repo\'s Mutation halt reports bypass_blocked=false')
  const { result } = await run(convergedWithSuspect({
    crapGated: false,
    mutationResult: () => ({ green: false, head_sha: 'mut0000000000000000000000000000000000001',
      detail: 'stub red', survivors: 1 }),
  }))
  check('halted at Mutation', result.halted_at, 'Mutation')
  check('gates.bypass_blocked is false', result.gates?.bypass_blocked, false)
  check('gates.measured is scored', result.gates?.measured, 'scored')
}

// Scenario AM -- and the green path's final result carries the same
// distinction: an ungated repo's result still reports bypass_blocked=false.
async function scenarioAM() {
  console.log('\n== scenario AM: an ungated repo\'s green-path result reports bypass_blocked=false')
  const { result } = await run({
    args: { openPr: true },
    crapGated: false,
    prResult: { opened: true, url: 'https://example.invalid/pr/23', note: 'stub ready' },
    initialReview: { correctness: [], advocate: [] },
    verify: () => undefined,
    staleness: () => [],
  })
  check('halted_at is absent', result.halted_at, undefined)
  check('gates.measured is scored', result.gates?.measured, 'scored')
  check('gates.bypass_blocked is false', result.gates?.bypass_blocked, false)
}

// Scenario AN -- probe returns nothing: the bypass question is unconfirmed, so
// bypass_blocked stays false (never asserted true when nobody confirmed the
// marker), and the run logs the failure.
async function scenarioAN() {
  console.log('\n== scenario AN: a failed gate opt-in probe reports bypass_blocked=false')
  const { result, captured } = await run({
    args: { openPr: true },
    gateProbeFails: true,
    prResult: { opened: true, url: 'https://example.invalid/pr/23', note: 'stub ready' },
    initialReview: { correctness: [], advocate: [] },
    verify: () => undefined,
    staleness: () => [],
  })
  check('gates.bypass_blocked is false when the probe returns nothing',
    result.gates?.bypass_blocked, false)
  check('gates.measured is scored', result.gates?.measured, 'scored')
  check('the run logs that the probe returned nothing',
    captured.logs.some(l => l.includes('gate opt-in probe returned nothing')), true)
}

// Scenario AS -- the aggregate rule this ticket exists for: the implementer
// scored nothing, but a fix round did, so the run's overall `measured` claim
// is still 'scored'.
async function scenarioAS() {
  console.log('\n== scenario AS: a fix round that scores makes the run measured, even if the implementer did not')
  const { result } = await run({
    args: { maxReviewRounds: 1 },
    implScored: false,
    fixScored: (round) => round === 1,
    initialReview: {
      correctness: [{ title: 'Unrelated leak', file: 'src/pool.js',
        claim: 'connection is never released', evidence: 'pool.js:40' }],
      advocate: [],
    },
    verify: () => true,
    staleness: () => [],
  })
  check('gates.measured is scored', result.gates?.measured, 'scored')
}

// Scenario AT -- nothing scorable: the implementer reported scored=false and
// no fix round ran, so no committing phase ever scored anything.
async function scenarioAT() {
  console.log('\n== scenario AT: nothing scorable when no committing phase scored anything')
  const { result } = await run({
    implScored: false,
    initialReview: { correctness: [], advocate: [] },
    verify: () => undefined,
    staleness: () => [],
  })
  check('halted_at is absent', result.halted_at, undefined)
  check('gates.measured is nothing scorable', result.gates?.measured, 'nothing scorable')
}

// Scenario AO -- one gate-opt-in probe answers both the CRAP and mutation
// markers; the mutation phase must not ask the repo a second time.
async function scenarioAO() {
  console.log('\n== scenario AO: the gate opt-in probe is called exactly once for both markers')
  const { result, captured } = await run(convergedWithSuspect({
    crapGated: true,
    mutationGated: false,
  }))
  check('gate:opt-in was called exactly once', callCount(captured, 'gate:opt-in'), 1)
  check('mutation gate honoured the merged probe\'s answer',
    (result.mutation?.detail ?? '').includes('skipped'), true)
}

// Scenarios AP to AR -- the branch marker. It is the run's only record of
// which tracker the work came from, and the branch agent used to classify the
// ticket itself: GitHub issue 278 came back as feat/jira-278-...
async function scenarioAP() {
  console.log('\n== scenario AP: a bare number is handed to the branch agent as gh-')
  const { captured } = await run({
    args: { ticket: '278' },
    initialReview: { correctness: [], advocate: [] },
    verify: () => undefined,
    staleness: () => [],
  })
  const p = captured.calls.find(c => c.label === 'branch')?.prompt ?? ''
  check('the branch name is given with the gh- marker resolved',
    p.includes('feat/gh-278-<slug>'), true)
  check('the worktree path carries the same marker',
    p.includes('.claude/worktrees/gh-278-<slug>'), true)
  check('the agent is told not to swap the marker',
    p.includes('do not re-derive it'), true)
  check('it is no longer asked to classify the ticket',
    p.includes('when the ticket is a'), false)
}

async function scenarioAQ() {
  console.log('\n== scenario AQ: a Jira key is handed over as jira-, uppercased')
  const { captured } = await run({
    args: { ticket: 'proj-4821', branchType: 'fix' },
    initialReview: { correctness: [], advocate: [] },
    verify: () => undefined,
    staleness: () => [],
  })
  const p = captured.calls.find(c => c.label === 'branch')?.prompt ?? ''
  check('the key is canonicalised to upper case',
    p.includes('fix/jira-PROJ-4821-<slug>'), true)
}

async function scenarioAR() {
  console.log('\n== scenario AR: a ticket that is neither form refuses before any agent runs')
  let message = ''
  try {
    await run({ args: { ticket: 'retry-policy' } })
  } catch (e) {
    message = e?.message ?? String(e)
  }
  check('it throws rather than guessing a marker',
    message.includes('neither a GitHub issue number'), true)
}

for (const scenario of [scenarioA, scenarioB, scenarioG, scenarioC, scenarioD, scenarioE, scenarioH,
                        scenarioI, scenarioJ, scenarioK, scenarioL, scenarioM, scenarioN,
                        scenarioO, scenarioP, scenarioQ, scenarioR, scenarioS, scenarioT,
                        scenarioU, scenarioV, scenarioW, scenarioX, scenarioY,
                        scenarioZ, scenarioAA, scenarioAB, scenarioAC, scenarioAD,
                        scenarioAE, scenarioAF, scenarioAG, scenarioAH, scenarioAI,
                        scenarioAJ, scenarioAK, scenarioAL, scenarioAM, scenarioAN,
                        scenarioAO, scenarioAS, scenarioAT,
                        scenarioAP, scenarioAQ, scenarioAR]) {
  await scenario()
}

console.log('')
if (failures === 0) {
  console.log('OK (fix-loop join harness)')
  process.exit(0)
} else {
  console.log(`FAILED: ${failures} assertion(s)`)
  process.exit(1)
}
JS_EOF

node "$WORK/harness.mjs" "$SCRIPT"
if [ "$?" -ne 0 ]; then
  failures=$((failures + 1))
fi

echo ""
if [ "$failures" -eq 0 ]; then
  echo "OK"
else
  echo "FAILED: $failures suite(s)/assertion(s)"
  exit 1
fi
