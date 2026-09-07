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
check "the verifier's brief lists each finding's id in brackets" \
  "$(grep -c '\[\${f\.id}\]' "$SCRIPT" || true)" 2

echo ""
echo "== staleness probe: the git command against a real scratch repo"
# The prompt wraps this across two lines; checked as two substrings rather
# than one so a rewrap does not make this test outrun the actual source.
check "the prompt gives the git log half of the command" \
  "$(grep -Fc 'git log --oneline <recorded_at>..HEAD' "$SCRIPT" || true)" 1
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
  git -C "$REPO" log --oneline "$RECORDED_AT..HEAD" -- "$file"
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
        premise_ok: true, estimated_loc: 5, evidence: [], premise_note: 'stub' }
    }
    if (label === 'implementer') {
      return { summary: 'stub implementation', files_changed: ['a.js', 'b.js'],
        commit_range: COMMIT_RANGE, insertions: 20 }
    }
    if (label === 'draft-pr') {
      return scenario.draftPr ?? { opened: false, detail: 'no draft in this test' }
    }
    if (label.startsWith('halt-notice:')) {
      captured.haltNoticePrompt = prompt
      return true
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
      return { head_sha: head, note: `stub fix round ${round}` }
    }
    if (label.startsWith('verify:')) {
      const round = Number(label.slice('verify:'.length))
      const ids = idsIn(prompt)
      const verdicts = []
      for (const id of ids) {
        const decision = scenario.verify(id, round)
        if (decision === undefined) continue
        // A different title every time: the whole point is that this is
        // never read for matching.
        verdicts.push({ id, fixed: decision === true, title: `reworded-${id}-r${round}`,
          note: `stub verdict for ${id}` })
      }
      if (scenario.injectBogusVerdict) {
        verdicts.push({ id: 'f999-not-a-real-finding', fixed: true, title: 'bogus', note: 'should be discarded' })
      }
      return { verdicts }
    }
    if (label === 'mutation:opt-in') {
      return { gated: scenario.mutationGated ?? false, detail: 'stub' }
    }
    if (label.startsWith('mutation:')) {
      const attempt = Number(label.slice('mutation:'.length))
      return (scenario.mutationResult ?? (() => ({ green: true, head_sha: REVIEWED_THROUGH, detail: 'stub' })))(attempt)
    }
    if (label === 'staleness') {
      if (scenario.staleness === null) return null
      if (scenario.staleness === 'malformed') return { results: 'not-an-array' }
      const ids = idsIn(prompt)
      return { results: scenario.staleness ? scenario.staleness(ids) : [] }
    }
    if (label === 'pr') {
      return { opened: false, url: '', note: 'stub' }
    }
    throw new Error(`unstubbed agent label in test scenario: ${label}`)
  }
}

async function run(scenario) {
  const captured = { calls: [], haltNoticePrompt: null, logs: [] }
  const sandbox = {
    args: baseArgs(scenario.args),
    agent: makeAgent(scenario, captured),
    parallel: (thunks) => Promise.all(thunks.map(async (t) => {
      try { return await t() } catch { return null }
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

for (const scenario of [scenarioA, scenarioB, scenarioG, scenarioC, scenarioD, scenarioE, scenarioH]) {
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
