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

echo ""
echo "== static: BRANCH requires dirty on every response"
# A haiku-at-low-effort branch agent that simply omits dirty must fail schema
# validation, not have it default to false and mask a dirty checkout as clean.
check "BRANCH's required array lists dirty" \
  "$(grep -c "required: \['created', 'branch', 'base', 'path', 'detail', 'dirty'\]" "$SCRIPT" || true)" 1

echo "== static: BRANCH's halt_reason enum covers the merged and occupied halts, not just ambiguous and wrong-ticket"
check "halt_reason enum lists all five" \
  "$(grep -c "enum: \['none', 'ambiguous', 'wrong-ticket', 'merged', 'occupied'\]" "$SCRIPT" || true)" 1

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

echo ""
echo "== static: the scored/gateNote comments agree on which phases feed measured"
check "the aggregate comment does not stop the scope at the fix loop" \
  "$(grep -Fc 'from here through the fix loop' "$SCRIPT" || true)" 0
check "the aggregate comment names the mutation loop, matching gatesPayload's own comment" \
  "$(grep -Fc 'from here through the mutation loop' "$SCRIPT" || true)" 1

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
echo "== worktree phase: the default cut is unaffected by a dirty main checkout"
# Runs the exact command sequence the branch prompt now prescribes for the
# non-baseOverride cut (git fetch origin; git rev-parse --verify
# origin/<base>; git worktree add <path> -b <branch> origin/<base>) against a
# real remote and a real main checkout, proving the main tree's dirty state
# and its stale local base are both irrelevant to the cut.
ORIGIN="$WORK/wt-origin.git"
git init -q --bare "$ORIGIN"

MAIN="$WORK/wt-main"
git clone -q "$ORIGIN" "$MAIN"
git -C "$MAIN" config user.email test@example.com
git -C "$MAIN" config user.name test
git -C "$MAIN" config commit.gpgsign false

echo "base v1" > "$MAIN/tracked.txt"
git -C "$MAIN" add tracked.txt
git -C "$MAIN" commit -qm "initial commit on main"
git -C "$MAIN" push -q origin HEAD:main
LOCAL_BASE_SHA_BEFORE="$(git -C "$MAIN" rev-parse main)"

# A second clone advances the remote past what MAIN has fetched, so
# origin/main (once fetched) differs from MAIN's own stale local main.
OTHER_CLONE="$WORK/wt-other-clone"
git clone -q "$ORIGIN" "$OTHER_CLONE"
git -C "$OTHER_CLONE" config user.email test@example.com
git -C "$OTHER_CLONE" config user.name test
git -C "$OTHER_CLONE" config commit.gpgsign false
echo "base v2" > "$OTHER_CLONE/tracked.txt"
git -C "$OTHER_CLONE" add tracked.txt
git -C "$OTHER_CLONE" commit -qm "a commit MAIN has not fetched yet"
git -C "$OTHER_CLONE" push -q origin HEAD:main
REMOTE_HEAD_SHA="$(git -C "$OTHER_CLONE" rev-parse HEAD)"

# Dirty the main checkout: a modified tracked file, a staged new file, an
# untracked file.
echo "modified locally" > "$MAIN/tracked.txt"
echo "staged new file" > "$MAIN/staged.txt"
git -C "$MAIN" add staged.txt
echo "untracked" > "$MAIN/untracked.txt"

STATUS_BEFORE="$(git -C "$MAIN" status --porcelain)"
TRACKED_BEFORE="$(cat "$MAIN/tracked.txt")"
STAGED_BEFORE="$(cat "$MAIN/staged.txt")"
BRANCH_BEFORE="$(git -C "$MAIN" branch --show-current)"

WTPATH="$WORK/wt-new-worktree"
git -C "$MAIN" fetch -q origin
git -C "$MAIN" rev-parse --verify origin/main >/dev/null 2>&1
FETCH_VERIFY_STATUS=$?
git -C "$MAIN" worktree add -q "$WTPATH" -b feat/gh-999-test origin/main

check "the fetch and verify step succeeded" "$FETCH_VERIFY_STATUS" 0
check "git status --porcelain in the main checkout is unchanged" \
  "$(git -C "$MAIN" status --porcelain)" "$STATUS_BEFORE"
check "the modified tracked file's content is unchanged" \
  "$(cat "$MAIN/tracked.txt")" "$TRACKED_BEFORE"
check "the staged file's content is unchanged" \
  "$(cat "$MAIN/staged.txt")" "$STAGED_BEFORE"
check "the local base branch SHA is unchanged" \
  "$(git -C "$MAIN" rev-parse main)" "$LOCAL_BASE_SHA_BEFORE"
check "the main checkout is still on the same branch" \
  "$(git -C "$MAIN" branch --show-current)" "$BRANCH_BEFORE"
check "the new worktree's HEAD equals origin/main, not the stale local main" \
  "$(git -C "$WTPATH" rev-parse HEAD)" "$REMOTE_HEAD_SHA"
check "origin/main (fetched) actually differs from the stale local main" \
  "$([ "$REMOTE_HEAD_SHA" != "$LOCAL_BASE_SHA_BEFORE" ] && echo yes || echo no)" yes

echo ""
echo "== worktree phase: a missing origin/<base> ref fails the verify step"
git -C "$MAIN" rev-parse --verify origin/does-not-exist >/dev/null 2>&1
MISSING_REF_STATUS=$?
check "git rev-parse --verify on a missing remote ref exits non-zero" \
  "$([ "$MISSING_REF_STATUS" -ne 0 ] && echo yes || echo no)" yes

echo ""
echo "== implementer's merge-base rule: the origin candidate stays at the true fork point when the local base goes stale"
# Clone at A, a colleague pushes three commits straight to the remote, a
# branch is cut from origin/<base> and gets one commit of its own. The local
# <base> ref never moves, so merge-base against it alone reaches back through
# the colleague's three commits too.
TC_REMOTE="$WORK/tc-origin.git"
git init -q --bare "$TC_REMOTE"

TC_CLONE="$WORK/tc-clone"
git clone -q "$TC_REMOTE" "$TC_CLONE"
git -C "$TC_CLONE" config user.email test@example.com
git -C "$TC_CLONE" config user.name test
git -C "$TC_CLONE" config commit.gpgsign false

echo "a" > "$TC_CLONE/f.txt"
git -C "$TC_CLONE" add f.txt
git -C "$TC_CLONE" commit -qm "A: initial commit"
git -C "$TC_CLONE" push -q origin HEAD:main
LOCAL_MAIN_SHA="$(git -C "$TC_CLONE" rev-parse main)"

TC_COLLEAGUE="$WORK/tc-colleague"
git clone -q "$TC_REMOTE" "$TC_COLLEAGUE"
git -C "$TC_COLLEAGUE" config user.email test@example.com
git -C "$TC_COLLEAGUE" config user.name test
git -C "$TC_COLLEAGUE" config commit.gpgsign false
for n in 1 2 3; do
  echo "colleague $n" >> "$TC_COLLEAGUE/f.txt"
  git -C "$TC_COLLEAGUE" add f.txt
  git -C "$TC_COLLEAGUE" commit -qm "colleague commit $n"
done
git -C "$TC_COLLEAGUE" push -q origin HEAD:main
COLLEAGUE_HEAD_SHA="$(git -C "$TC_COLLEAGUE" rev-parse HEAD)"

git -C "$TC_CLONE" fetch -q origin
git -C "$TC_CLONE" checkout -q -b feat/tc-test origin/main
echo "own change" > "$TC_CLONE/g.txt"
git -C "$TC_CLONE" add g.txt
git -C "$TC_CLONE" commit -qm "run 1's own commit"

ORIGIN_MERGE_BASE="$(git -C "$TC_CLONE" merge-base HEAD origin/main)"
LOCAL_MERGE_BASE="$(git -C "$TC_CLONE" merge-base HEAD main)"
check "the origin candidate is the true fork point" "$ORIGIN_MERGE_BASE" "$COLLEAGUE_HEAD_SHA"
check "the local candidate is the stale pre-fetch main" "$LOCAL_MERGE_BASE" "$LOCAL_MAIN_SHA"

git -C "$TC_CLONE" merge-base --is-ancestor "$LOCAL_MERGE_BASE" "$ORIGIN_MERGE_BASE"
check "the origin candidate is a descendant of the local one, so the rule picks it" "$?" 0

ORIGIN_RANGE_COUNT="$(git -C "$TC_CLONE" rev-list --count "$ORIGIN_MERGE_BASE"..HEAD)"
LOCAL_RANGE_COUNT="$(git -C "$TC_CLONE" rev-list --count "$LOCAL_MERGE_BASE"..HEAD)"
check "the origin candidate reviews exactly this run's one commit" "$ORIGIN_RANGE_COUNT" 1
check "the stale local base alone would widen the range past it" \
  "$([ "$LOCAL_RANGE_COUNT" -gt "$ORIGIN_RANGE_COUNT" ] && echo yes || echo no)" yes

echo ""
echo "== premise: git reports a ticket's linked worktree while the main checkout sits on the base branch"
# Establishes the git facts the lookup rests on; it never runs the pipeline, so
# it cannot fail if the lookup regresses. Scenarios BI, BJ and BK cover that.
EXIST_ORIGIN="$WORK/exist-origin.git"
git init -q --bare "$EXIST_ORIGIN"

EXIST_MAIN="$WORK/exist-main"
git clone -q "$EXIST_ORIGIN" "$EXIST_MAIN"
git -C "$EXIST_MAIN" config user.email test@example.com
git -C "$EXIST_MAIN" config user.name test
git -C "$EXIST_MAIN" config commit.gpgsign false

echo "base" > "$EXIST_MAIN/tracked.txt"
git -C "$EXIST_MAIN" add tracked.txt
git -C "$EXIST_MAIN" commit -qm "initial commit on main"
git -C "$EXIST_MAIN" push -q origin HEAD:main

EXIST_WT="$WORK/exist-worktree-gh-21"
git -C "$EXIST_MAIN" worktree add -q "$EXIST_WT" -b feat/gh-21-retry-path origin/main
# git's own porcelain output reports the canonical path (symlinks resolved),
# which on macOS differs from $EXIST_WT under /var; resolve the same way
# before comparing rather than string-matching the pre-resolution form.
EXIST_WT_CANON="$(cd "$EXIST_WT" && pwd -P)"

MATCHED_PATH="$(git -C "$EXIST_MAIN" worktree list --porcelain | awk '
  /^worktree / { path = $2 }
  /^branch refs\/heads\/feat\/gh-21-retry-path$/ { print path }
')"

check "the git worktree list --porcelain match resolves to the linked worktree path" \
  "$MATCHED_PATH" "$EXIST_WT_CANON"
check "git branch --show-current in the main checkout reports main, not the ticket branch" \
  "$(git -C "$EXIST_MAIN" branch --show-current)" "main"

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
    captured.calls.push({ label, prompt, schema: opts.schema })

    if (label === 'ticket') {
      return { found: true, summary: 'stub ticket', description: 'd', comments: '' }
    }
    if (label === 'branch') {
      return scenario.branchResult ?? { created: true, branch: 'feat/gh-21-stub', base: 'main',
        path: '/tmp/stub-worktree', ticket: '21', detail: 'stub' }
    }
    if (label === 'branch:existing') {
      return scenario.existingBranchResult ?? { created: true, branch: 'feat/gh-21-stub', base: 'main',
        path: '/tmp/stub-worktree', ticket: '21', detail: 'stub' }
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
      return { summary: 'stub implementation', files_changed: ['a.js', 'b.js'],
        commit_range: COMMIT_RANGE, insertions: 20, scored: scenario.implScored ?? true,
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
    if (label === 'checks:discover') {
      return scenario.discovery ?? { checks: [], detail: 'stub: no repo checks' }
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
  const captured = { calls: [], runRecordPrompt: null, dedupPrompt: null, logs: [] }
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
  check('no halt comment is posted to the PR',
    callCount(captured, 'halt-notice:Fix'), 0)
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
    mutationResult: () => ({ green: true, head_sha: mutHead, detail: 'stub green', scored: true }),
    postMutationReview: [{ title: 'Mutation gate introduced X', file: 'mutfile.js',
      claim: 'c', evidence: 'e' }],
  })
  check('halted at Review (the mutation gate\'s own commits)', result.halted_at, 'Review')
  check('exactly the one post-mutation finding is reported', result.unresolved_findings.length, 1)
  check('the finding carries no stale marker',
    result.unresolved_findings[0].code_changed_since_recorded, undefined)
  check('no halt comment is posted to the PR',
    callCount(captured, 'halt-notice:Review'), 0)
  // This halt is strictly downstream of the Mutation halt, so the draft PR
  // always exists by here, and halted() posts this note as a comment on it.
  check('the note does not claim no PR was opened',
    /[Nn]o PR was opened/.test(result.note ?? ''), false)
  check('the note says the PR was left as a draft',
    /left as a draft/.test(result.note ?? ''), true)
  // The last halt that reported no gate result, and the one where it is most
  // complete: mutation green, everything through the fix loop scored.
  check('the gate result reaches the halt payload', result.gates?.measured ?? null, 'scored')
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
    mutationResult: () => ({ green: true, head_sha: 'mut0000000000000000000000000000000000001', detail: 'stub green', scored: true }),
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
    mutationResult: () => ({ green: true, head_sha: 'mut0000000000000000000000000000000000001', detail: 'stub green', scored: true }),
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
    // f2 is the suspect: this scenario's re-report is genuine noise, so the
    // verifier confirms it does not reproduce.
    verify: (id) => (id === 'f1' || id === 'f2') ? true : undefined,
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
    // Anything that is not f1 is the round-2 suspect, which this scenario
    // means as the same bug, now fixed.
    verify: (id, round) => id === 'f1' ? (round === 2 ? true : false) : true,
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
    // f2 is the suspect: this scenario's re-report is genuine noise, so the
    // verifier confirms it does not reproduce.
    verify: (id) => (id === 'f1' || id === 'f2') ? true : undefined,
    staleness: () => [],
    mutationGated: true,
    mutationResult: () => ({ green: true, head_sha: 'mut0000000000000000000000000000000000001', detail: 'stub green', scored: true }),
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
    lensPrompt.includes('without the PR being marked ready'), true)
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
    // f2 is the suspect: this scenario's re-report is genuine noise, so the
    // verifier confirms it does not reproduce.
    verify: (id) => (id === 'f1' || id === 'f2') ? true : undefined,
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
    // f2 is the leak that must stay open; f3 is the suspect, which this
    // scenario means as genuine noise.
    verify: (id) => (id === 'f1' || id === 'f3') ? true : undefined,
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
  check('the suspect claim is in the result, not on the PR',
    result.regression_suspects[0].claim, 'off-by-one at the array end')
  check('no halt comment is posted to the PR',
    callCount(captured, 'halt-notice:Fix'), 0)
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
    // f2 is the suspect: this scenario's re-report is genuine noise, so the
    // verifier confirms it does not reproduce.
    verify: (id) => (id === 'f1' || id === 'f2') ? true : undefined,
    fixHead: () => 'fix00000000000000000000000000000000000001',
    tailReview: [{ title: 'Boundary check excludes the last element', file: 'parser.js',
      claim: 'off-by-one at the array end', evidence: 'see loop condition',
      duplicate_of: 'f1' }],
    staleness: () => [],
  })
  check('halted_at is absent (every finding cleared)', result.halted_at, undefined)
  check('the suspect is in the result', result.regression_suspects?.length, 1)
  check('no comment is posted for it',
    callCount(captured, 'regression-notice'), 0)
  check('the suspect claim is in the result instead',
    result.regression_suspects[0].claim, 'off-by-one at the array end')
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
    // f2 is the suspect: this scenario's re-report is genuine noise, so the
    // verifier confirms it does not reproduce.
    verify: (id) => (id === 'f1' || id === 'f2') ? true : undefined,
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
      detail: 'stub red', survivors: 1, scored: true }),
  }))
  check('halted at Mutation', result.halted_at, 'Mutation')
  check('the suspect is in the payload', result.regression_suspects?.length, 1)
  check('no halt comment is posted to the PR',
    callCount(captured, 'halt-notice:Mutation'), 0)
  // A mutation agent that omits scored is indistinguishable from one that
  // scored nothing, which is exactly how a scoring commit can still report
  // "nothing scorable": the schema handed to the agent must force the field.
  const mutationCall = captured.calls.find((c) => c.label === 'mutation:1')
  check('the mutation schema requires scored',
    mutationCall?.schema?.required?.includes('scored'), true)
}

async function scenarioY() {
  console.log('\n== scenario Y: the post-mutation Review halt carries the regression suspects')
  const { result, captured } = await run(convergedWithSuspect({
    mutationResult: () => ({ green: true, head_sha: 'mut0000000000000000000000000000000000001', detail: 'stub green', scored: true }),
    postMutationReview: [{ title: 'New nil deref in the added test helper',
      file: 'src/helper.js', claim: 'deref before the guard', evidence: 'helper.js:8' }],
  }))
  check('halted at Review', result.halted_at, 'Review')
  check('the suspect is in the payload', result.regression_suspects?.length, 1)
  check('no halt comment is posted to the PR',
    callCount(captured, 'halt-notice:Review'), 0)
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
      detail: 'stub red', survivors: 1, scored: true }),
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

// Scenario AU -- gates.detail must not claim "gates measured" when nothing
// was scorable: the sentence has to vary with the measured field it sits
// next to, not stay byte-identical to the scored case.
async function scenarioAU() {
  console.log('\n== scenario AU: gates.detail does not claim "measured" when nothing was scorable')
  const scored = await run({
    initialReview: { correctness: [], advocate: [] },
    verify: () => undefined,
    staleness: () => [],
  })
  const nothingScorable = await run({
    implScored: false,
    initialReview: { correctness: [], advocate: [] },
    verify: () => undefined,
    staleness: () => [],
  })
  check('the nothing-scorable detail does not open with "gates measured"',
    (nothingScorable.result.gates?.detail ?? '').startsWith('gates measured'), false)
  check('the two details are not byte-identical',
    nothingScorable.result.gates?.detail !== scored.result.gates?.detail, true)
}

// Scenario AV -- a gate_note from a phase that scored nothing must not be
// carried forward once a later phase reports scored=true: pairing an
// implementer's "nothing to score" message with an overall measured='scored'
// claims the wrong phase's evidence for the aggregate.
async function scenarioAV() {
  console.log('\n== scenario AV: an unscored phase\'s gate_note is dropped once a later phase scores')
  const { result } = await run({
    args: { maxReviewRounds: 1 },
    implScored: false,
    implGateNote: 'no staged source files in supported languages (go, php, python)',
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
  check('the unscored implementer\'s gate_note does not leak into detail',
    (result.gates?.detail ?? '').includes('no staged source files'), false)
}

// Scenario AW -- the aggregate rule extended past the fix loop: the mutation
// phase's own commit is the only thing that scored in the whole run, and it
// must still make the green-path result's measured claim 'scored'.
async function scenarioAW() {
  console.log('\n== scenario AW: a scoring mutation commit makes the green-path result measured')
  const { result } = await run({
    implScored: false,
    initialReview: { correctness: [], advocate: [] },
    verify: () => undefined,
    staleness: () => [],
    mutationGated: true,
    mutationResult: () => ({ green: true, head_sha: 'mut0000000000000000000000000000000000003',
      detail: 'stub green', scored: true }),
  })
  check('halted_at is absent', result.halted_at, undefined)
  check('gates.measured reflects the mutation phase\'s own scored commit',
    result.gates?.measured, 'scored')
}

// Scenario AX -- the same commit, but the attempt it came from still ended
// red: a losing mutation attempt can commit a real fix before failing, and
// the Mutation halt must not discard that just because the gate stayed red.
async function scenarioAX() {
  console.log('\n== scenario AX: the Mutation halt reflects a scored commit from a losing attempt')
  const { result } = await run({
    implScored: false,
    initialReview: { correctness: [], advocate: [] },
    verify: () => undefined,
    staleness: () => [],
    mutationGated: true,
    mutationResult: () => ({ green: false, head_sha: 'mut0000000000000000000000000000000000004',
      detail: 'stub red', survivors: 1, scored: true }),
  })
  check('halted at Mutation', result.halted_at, 'Mutation')
  check('gates.measured reflects the losing attempt\'s own scored commit',
    result.gates?.measured, 'scored')
}

// Scenario AY -- scored=false is not one cause: it covers "no commits", "the
// gate printed nothing to score" and more. When nothing ever scores, the
// implementer's own gate_note is the only observation of which one it was,
// so it must survive into detail rather than being replaced by a guess.
async function scenarioAY() {
  console.log('\n== scenario AY: the nothing-scorable detail carries the implementer\'s own gate_note')
  const { result } = await run({
    implScored: false,
    implGateNote: 'crap-commit.sh: no staged source files (go, php, python)',
    initialReview: { correctness: [], advocate: [] },
    verify: () => undefined,
    staleness: () => [],
  })
  check('gates.measured is nothing scorable', result.gates?.measured, 'nothing scorable')
  check('the implementer\'s own gate_note reaches detail',
    (result.gates?.detail ?? '').includes('no staged source files'), true)
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

// Scenario BB -- the existingBranch prompt's guard checks the tree it is
// actually going to commit into (the matched record's own path), whichever
// tree that is, rather than special-casing the main checkout and waiving the
// check for a linked worktree.
async function scenarioBB() {
  console.log('\n== scenario BB: the existingBranch prompt checks the matched record\'s own path, main checkout or not')
  const { captured } = await run({
    args: { existingBranch: true },
    initialReview: { correctness: [], advocate: [] },
    verify: () => undefined,
    staleness: () => [],
  })
  const p = captured.calls.find(c => c.label === 'branch:existing')?.prompt ?? ''
  check('the guard checks the matched or re-attached path from step 4, 5, or 6',
    p.includes("using the matched or re-attached path from step 4, 5, or 6"), true)
  check('the guard applies whether that path is the main checkout or a linked worktree',
    p.includes('whether that is the main checkout or a linked worktree'), true)
  check('the incorrect main-checkout-only carve-out is gone',
    p.includes('A dirty main checkout is not a reason to stop'), false)
  check('the guard still forbids stashing, resetting or discarding',
    p.includes('Never stash, reset, or discard'), true)
}

// Scenario BC -- the default (non-existingBranch) branch prompt's own reuse
// path (an existing branch already checked out elsewhere) must check that
// record's path for dirty state before reusing it: that record can be the
// main checkout, and a later phase runs git add -A there.
async function scenarioBC() {
  console.log('\n== scenario BC: the default branch prompt\'s reuse path checks the matched record for dirty state')
  const { captured } = await run({
    initialReview: { correctness: [], advocate: [] },
    verify: () => undefined,
    staleness: () => [],
  })
  const p = captured.calls.find(c => c.label === 'branch')?.prompt ?? ''
  check('the reuse step checks the matched record\'s path for dirty state',
    p.includes('This mode commits into that tree, and a later phase runs git add -A there'), true)
  check('the reuse guard forbids stashing, resetting or discarding',
    p.includes('Never stash, reset, or discard'), true)
  // 'occupied' describes this agent's own step 8 halt, so a field it can see
  // is a field it may fill, and the run would then print the other mode's note.
  check('this agent is not handed halt_reason at all',
    captured.calls.find(c => c.label === 'branch')?.schema?.properties?.halt_reason, undefined)
}

// Scenario BD -- the script cannot resolve a fork point itself (no filesystem
// access), so the implementer is told to try both <base> and origin/<base>
// and pick between them at runtime. A given base must reach that rule bare in
// both shapes it arrives in: a stacked branch name with no remote ref, and an
// origin/<x> that must not double.
async function scenarioBD() {
  console.log('\n== scenario BD: a given base reaches the merge-base rule bare, never doubled')
  for (const [given, bare] of [['feat/gh-40-parent', 'feat/gh-40-parent'], ['origin/develop', 'develop']]) {
    const { captured } = await run({
      args: { base: given, openPr: true },
      branchResult: { created: true, branch: 'feat/gh-21-stub', base: 'main',
        path: '/tmp/stub-worktree', ticket: '21', detail: 'stub' },
      draftPr: { opened: true, number: 23, url: 'https://example.invalid/pr/23', detail: 'stub draft' },
      prResult: { opened: true, url: 'https://example.invalid/pr/23', note: 'stub ready' },
      initialReview: { correctness: [], advocate: [] },
      verify: () => undefined,
      staleness: () => [],
    })
    const p = captured.calls.find(c => c.label === 'implementer')?.prompt ?? ''
    check(`${given}: the bare candidate is offered`, p.includes(`with ${bare} and`), true)
    check(`${given}: the origin candidate is offered`, p.includes(`with origin/${bare}`), true)
    check(`${given}: it is never doubled`, p.includes('origin/origin/'), false)
    // gh resolves --base as a branch on the remote, so an origin/-qualified
    // name is rejected there -- at the very end of a run whose gates all went
    // green.
    for (const [label, call] of [['draft', 'draft-pr'], ['ready', 'pr']]) {
      const q = captured.calls.find(c => c.label === call)?.prompt ?? ''
      check(`${given}: the ${label} PR phase ran`, q.length > 0, true)
      check(`${given}: the ${label} PR targets the bare base`,
        q.includes(`--base ${bare}`), true)
      check(`${given}: the ${label} PR does not target an origin/ name`,
        q.includes('--base origin/'), false)
    }
  }
}

// Scenario BE -- only the fresh-cut prompt's own step 3 tells its agent to
// strip the origin/ prefix that git symbolic-ref --short refs/remotes/origin/HEAD
// prints; a reported base of "origin/main" must still reach the merge-base
// rule as the bare "main", not doubled into "origin/origin/main".
async function scenarioBE() {
  console.log('\n== scenario BE: a base reported as origin/main by the fresh-cut prompt is stripped to main')
  const { captured } = await run({
    branchResult: { created: true, branch: 'feat/gh-21-stub', base: 'origin/main',
      path: '/tmp/stub-worktree', ticket: '21', detail: 'stub' },
    initialReview: { correctness: [], advocate: [] },
    verify: () => undefined,
    staleness: () => [],
  })
  const p = captured.calls.find(c => c.label === 'implementer')?.prompt ?? ''
  check('the bare candidate is main, not origin/main', p.includes('with main and'), true)
  check('the origin candidate is origin/main, not origin/origin/main', p.includes('with origin/main'), true)
  check('it is never doubled', p.includes('origin/origin/'), false)
}

// Scenario BF -- the default (non-existingBranch) branch prompt's own dirty
// reuse halt (step 6) must report why: a dirty checkout, not the base-branch
// note meant for the other default-mode halts (an invalid baseOverride ref, a
// worktree path already on disk, a failed fetch or resolve).
async function scenarioBF() {
  console.log('\n== scenario BF: a dirty reused worktree halts with a dirty-checkout note, not a base-branch note')
  const { result } = await run({
    branchResult: { created: false, branch: 'feat/gh-21-stub', base: 'main',
      path: '/tmp/stub-worktree', ticket: '21', detail: 'staged.txt is dirty', dirty: true },
  })
  check('halted at Worktree', result.halted_at, 'Worktree')
  check('the note points at the dirty checkout', /[Cc]ommit or stash/.test(result.note ?? ''), true)
  check('the note does not blame a base branch problem',
    (result.note ?? '').includes('base branch problem'), false)
  check('the note does not send the user toward the existingBranch guard, ' +
    'which refuses the same tree for the same reason',
    (result.note ?? '').includes('existingBranch: true'), false)
}

// Scenario BG -- the existingBranch prompt's step 7 never tells its agent to
// strip an origin/ prefix off the base it reports, unlike the fresh-cut
// prompt's own step 3. A base of "origin/main" must still reach the
// merge-base rule stripped to "main", not doubled into "origin/origin/main".
async function scenarioBG() {
  console.log('\n== scenario BG: a base reported as origin/main by the existingBranch prompt is stripped to main')
  const { captured } = await run({
    args: { existingBranch: true },
    existingBranchResult: { created: true, branch: 'feat/gh-21-stub', base: 'origin/main',
      path: '/tmp/stub-worktree', ticket: '21', detail: 'stub' },
    initialReview: { correctness: [], advocate: [] },
    verify: () => undefined,
    staleness: () => [],
  })
  const p = captured.calls.find(c => c.label === 'implementer')?.prompt ?? ''
  check('the bare candidate is main, not origin/main', p.includes('with main and'), true)
  check('the origin candidate is origin/main, not origin/origin/main', p.includes('with origin/main'), true)
  check('it is never doubled', p.includes('origin/origin/'), false)
}

// Scenario BH -- the script has no filesystem access, so it cannot resolve a
// fork point itself; the implementer must be told the exact tiebreak rule
// (descendant wins, origin/<base> on a genuine divergence) rather than being
// left to guess, since the gates measure against origin/HEAD and a different
// pick here would review a range the gates never scored.
async function scenarioBH() {
  console.log('\n== scenario BH: the prompt states the two-candidate merge-base rule')
  const { captured } = await run({
    branchResult: { created: true, branch: 'feat/gh-21-stub', base: 'main',
      path: '/tmp/stub-worktree', ticket: '21', detail: 'stub' },
    initialReview: { correctness: [], advocate: [] },
    verify: () => undefined,
    staleness: () => [],
  })
  const p = captured.calls.find(c => c.label === 'implementer')?.prompt ?? ''
  check('only-one-resolves is covered', p.includes('If only one of those refs resolves'), true)
  check('the descendant tiebreak is covered', p.includes('--is-ancestor'), true)
  check('the origin fallback names the reason: the gates diff against origin/HEAD',
    p.includes('origin/HEAD first'), true)
}

// Scenario BI -- a marker-matching worktree record must be usable regardless
// of the invoking checkout: it must actually carry the run through Plan, not
// merely fail to halt at Worktree, because the two used to be conflated (the
// old guard halted at Worktree for exactly this case).
async function scenarioBI() {
  console.log('\n== scenario BI: existingBranch with a matched worktree and team-scoped triage reaches Plan')
  const { result, captured } = await run({
    args: { existingBranch: true },
    existingBranchResult: { created: true, branch: 'feat/gh-21-stub', base: 'main',
      path: '/tmp/stub-worktree', ticket: '21', detail: 'stub' },
    triage: { scope: 'team', estimated_loc: 50 },
    plannerResult: { plan: 'stub plan', acceptance_criteria: [], risky_areas: [],
      task_demands_implementation: false },
    initialReview: { correctness: [], advocate: [] },
    verify: () => undefined,
    staleness: () => [],
  })
  check('the run does not halt at Worktree', result.halted_at === 'Worktree', false)
  check('the planner ran exactly once', callCount(captured, 'planner'), 1)
  // A hand-fed created:true record carries through the old pipeline too, so
  // the only part of this the stub does not decide is what the lookup agent
  // was told: that the invoking checkout's branch does not gate the match.
  const bx = captured.calls.find(c => c.label === 'branch:existing')?.prompt ?? ''
  check('the branch:existing phase ran', bx.length > 0, true)
  check('the lookup runs whatever the invoking checkout is on',
    bx.includes('regardless of what the invoking checkout is on'), true)
  check('being on the base branch is named as fine, not an error',
    bx.includes('the base branch, another feature branch, or detached HEAD are all'), true)
  check('the matched record\'s branch is what the run carries',
    result.branch, 'feat/gh-21-stub')
  const impl = captured.calls.find(c => c.label === 'implementer')?.prompt ?? ''
  check('the implementer phase ran', impl.length > 0, true)
  check('the matched record\'s path is where the work happens',
    impl.includes('/tmp/stub-worktree'), true)
}

// Scenario BJ -- the existingBranch halt note used to tell the user to check
// out the branch in the main checkout, the one thing this project's own
// CONTRIBUTING.md tells an agent never to do. It must instead name what the
// prompt actually looked for -- and the lookup ignores branch type (#87), so
// the note must not claim it searched a type-scoped name like
// feat/gh-21-<slug>: with --type fix that claim is both wrong and, since the
// type has no effect on the lookup, useless advice to re-run with a different
// --type.
async function scenarioBJ() {
  console.log('\n== scenario BJ: the existingBranch halt note names what it looked for, not a checkout instruction')
  const { result } = await run({
    args: { existingBranch: true },
    existingBranchResult: { created: false, branch: '', base: '', path: '',
      detail: 'no worktree found for gh-21', dirty: false },
  })
  check('halted at Worktree', result.halted_at, 'Worktree')
  check('the note does not advise checking out a branch',
    /check out the branch/i.test(result.note ?? ''), false)
  check('the note names the marker it looked for, with no branch-type prefix',
    (result.note ?? '').includes('gh-21-<slug>') && !(result.note ?? '').includes('feat/gh-21-<slug>'),
    true)
  check('the note names the directory the prompt looked for',
    (result.note ?? '').includes('.claude/worktrees/gh-21-<slug>'), true)
  check('the note says the search was not scoped to one branch type',
    /any branch type/i.test(result.note ?? ''), true)
}

// Scenario BK -- #87: a branch the pipeline created can lose its worktree (the
// directory gets cleaned up by hand while the PR stays open) without losing
// the branch itself, since git worktree prune only drops the registration.
// The existingBranch prompt must fall back to a plain branch lookup and
// re-attach a worktree to it, rather than stopping at the worktree-only
// lookup and telling the user to cut a duplicate branch.
async function scenarioBK() {
  console.log('\n== scenario BK: the existingBranch prompt falls back to a worktree-less branch match')
  const { captured } = await run({
    args: { existingBranch: true },
    initialReview: { correctness: [], advocate: [] },
    verify: () => undefined,
    staleness: () => [],
  })
  const p = captured.calls.find(c => c.label === 'branch:existing')?.prompt ?? ''
  check('the prompt looks up a branch with no worktree of its own',
    p.includes('git branch --list'), true)
  check('the prompt re-attaches a worktree rather than creating a new branch',
    p.includes('git worktree add') && p.includes('no -b, the branch already exists'), true)
  check('the prompt explains why the branch can outlive its worktree',
    p.includes('git worktree prune') && p.includes('never the branch itself'), true)
  check('the top-line restriction no longer bars every worktree creation',
    p.includes('do not create a worktree, do not fetch'), false)
  check('the top-line restriction still bars creating a branch',
    p.includes('Do not create a branch'), true)
}

// Scenario BL -- #87: the step 5/6 fallback to whatever is checked out here
// must not bless a branch marked for a different ticket. The invoking
// session usually runs inside another worktree, so this is reachable: run
// with --existing on ticket 88 from inside the gh-87 worktree, and if 88 has
// no worktree or branch of its own yet, the old fallback took gh-87's branch
// unguarded and committed 88's work onto 87's PR.
async function scenarioBL() {
  console.log('\n== scenario BL: the existingBranch prompt refuses a fallback branch marked for another ticket')
  const { captured } = await run({
    args: { existingBranch: true },
    initialReview: { correctness: [], advocate: [] },
    verify: () => undefined,
    staleness: () => [],
  })
  const p = captured.calls.find(c => c.label === 'branch:existing')?.prompt ?? ''
  check('the fallback refuses a branch carrying another ticket\'s marker',
    p.includes('a jira- or gh- marker other than'), true)
  check('the refusal is distinguished from the plain not-found halt',
    p.includes('wrong-ticket'), true)
}

// Scenario BM -- #87: two or more matching branches (from either the
// worktree lookup or the worktree-less branch lookup) must halt with a note
// that says an ambiguous match was found, not the plain not-found note
// (which used to fire for both cases and, worse, told the user to cut a
// third branch for the same ticket).
async function scenarioBM() {
  console.log('\n== scenario BM: an ambiguous existingBranch match halts with its own note, not the not-found note')
  const { result, captured } = await run({
    args: { existingBranch: true },
    existingBranchResult: { created: false, branch: '', base: '', path: '',
      detail: 'two branches carry the gh-21 marker: feat/gh-21-a, fix/gh-21-b',
      dirty: false, halt_reason: 'ambiguous' },
  })
  // Read off the schema the harness was handed, not the source text: an
  // omitted halt_reason reads as the plain not-found note, so it has to fail
  // validation rather than default.
  const schema = captured.calls.find(c => c.label === 'branch:existing')?.schema
  check('the branch:existing schema requires halt_reason',
    (schema?.required ?? []).includes('halt_reason'), true)
  check('its enum has a member for the ordinary response',
    (schema?.properties?.halt_reason?.enum ?? []).includes('none'), true)
  check('halted at Worktree', result.halted_at, 'Worktree')
  check('the note reports the ambiguity rather than claiming nothing was found',
    /more than one/i.test(result.note ?? ''), true)
  check('the note is the ambiguity note, not the not-found note it replaced',
    (result.note ?? '').startsWith('Found more than one branch carrying'), true)
  check('the note carries the matched branches',
    (result.note ?? '').includes('feat/gh-21-a'), true)
}

// Scenario BN -- #87: the wrong-ticket refusal (scenario BL's prompt text)
// must halt with a note naming the mismatch, not the plain not-found note.
async function scenarioBN() {
  console.log('\n== scenario BN: a fallback branch for another ticket halts with its own note')
  const { result } = await run({
    args: { existingBranch: true },
    existingBranchResult: { created: false, branch: '', base: '', path: '',
      detail: 'checked-out branch fix/gh-99-other carries the gh-99 marker, not gh-21',
      dirty: false, halt_reason: 'wrong-ticket' },
  })
  check('halted at Worktree', result.halted_at, 'Worktree')
  check('the note names the mismatch rather than claiming nothing was found',
    /different ticket/i.test(result.note ?? ''), true)
  check('cutting a new branch is safe advice here: the lookup already ' +
    'covered every worktree and branch for this ticket and found none',
    (result.note ?? '').includes('Re-run without existingBranch to cut one'), true)
}

// Scenario BO -- #87: the worktree-less branch fallback (scenario BK's
// prompt text) must not re-attach a worktree to a branch whose pull request
// already merged. The common way a branch outlives its worktree is the PR
// merging and the directory being cleaned up because the work was done, not
// because it was abandoned mid-flight -- so silently re-attaching runs a full
// implement-and-gate cycle on a ticket that already shipped.
async function scenarioBO() {
  console.log('\n== scenario BO: the worktree-less fallback checks the matched branch\'s PR state before re-attaching')
  const { captured } = await run({
    args: { existingBranch: true },
    initialReview: { correctness: [], advocate: [] },
    verify: () => undefined,
    staleness: () => [],
  })
  const p = captured.calls.find(c => c.label === 'branch:existing')?.prompt ?? ''
  check('the prompt checks the matched branch\'s PR state before re-attaching',
    p.includes('gh pr view') && p.includes('MERGED'), true)
  check('a merged PR halts distinctly, not as ambiguous or wrong-ticket',
    p.includes('halt_reason=merged'), true)
  check('the prompt refuses to re-attach a merged branch',
    p.includes('Do not re-attach a worktree to it'), true)
}

// Scenario BP -- #87: a worktree-less branch whose PR already merged must
// halt with its own note, not the plain not-found note, whose advice to cut
// a new branch would duplicate a branch this ticket already has.
async function scenarioBP() {
  console.log('\n== scenario BP: a merged-PR branch halts with its own note')
  const { result } = await run({
    args: { existingBranch: true },
    existingBranchResult: { created: false, branch: '', base: '', path: '',
      detail: 'branch fix/gh-21-retry-path carries the gh-21 marker but its PR #40 is MERGED',
      dirty: false, halt_reason: 'merged' },
  })
  check('halted at Worktree', result.halted_at, 'Worktree')
  check('the note reports the merged PR rather than claiming nothing was found',
    /merged/i.test(result.note ?? ''), true)
  check('the note carries the matched branch',
    (result.note ?? '').includes('fix/gh-21-retry-path'), true)
}

// Scenario BQ -- #87: the occupied-path halt in the worktree-less fallback (a
// branch was found, but its canonical worktree directory already holds
// something else) must halt with its own note, not the plain not-found note,
// which would tell the user to cut a duplicate branch for a ticket that
// already has one.
async function scenarioBQ() {
  console.log('\n== scenario BQ: an occupied canonical worktree path halts with its own note')
  const { result } = await run({
    args: { existingBranch: true },
    existingBranchResult: { created: false, branch: '', base: '', path: '',
      detail: '.claude/worktrees/gh-21-retry-path already holds an unrelated checkout',
      dirty: false, halt_reason: 'occupied' },
  })
  check('halted at Worktree', result.halted_at, 'Worktree')
  check('the note is the occupied note, not the not-found note it replaced',
    (result.note ?? '').startsWith('A branch carrying the gh-21 marker was found with no'), true)
  check('the note names what is occupying the path',
    (result.note ?? '').includes('already holds an unrelated checkout'), true)
}

// Scenario BR -- #87 review: the pipeline never removes a worktree, so a
// worktree left behind by a ticket branch whose PR already merged is just as
// reachable through step 4 (the worktree lookup) as through step 5's
// worktree-less fallback. Step 4 used to reuse an exactly-one match with no
// PR-state check at all, so the guard step 5 enforces was skipped whenever
// the merged branch's worktree directory happened to still exist on disk.
async function scenarioBR() {
  console.log('\n== scenario BR: the worktree-match path (step 4) also checks PR state before reusing it')
  const { captured } = await run({
    args: { existingBranch: true },
    initialReview: { correctness: [], advocate: [] },
    verify: () => undefined,
    staleness: () => [],
  })
  const p = captured.calls.find(c => c.label === 'branch:existing')?.prompt ?? ''
  const step4 = p.slice(p.indexOf('4. Ticket lookup'), p.indexOf('5. Only if step 4 matched nothing'))
  // Both markers missing makes the slice empty, and every absence check below
  // then passes on nothing.
  check('the step 4 slice was actually found', step4.length > 0, true)
  check('step 4 no longer reuses a bare match with no PR-state check at all',
    step4.includes('Exactly one match: that is the tree to use. Go to step 7.'), false)
  check('step 4 checks the matched branch\'s PR state before reusing it',
    step4.includes('gh pr view') && step4.includes('MERGED'), true)
  check('step 4 halts distinctly on a merged match, same as step 5',
    step4.includes('halt_reason=merged'), true)
}

// Scenario BS -- #87 review: the merged halt's own advice told the user to
// "re-run without existingBranch to cut a fresh branch". What that path does
// turns entirely on the branch name it re-derives from the task: the same
// name reuses the merged branch and pushes onto its closed pull request, a
// different one cuts fresh or halts on the directory. The note has to cover
// both, because the run cannot tell which it will get.
async function scenarioBS() {
  console.log('\n== scenario BS: the merged halt note covers both outcomes of re-running without existingBranch')
  const { result } = await run({
    args: { existingBranch: true },
    existingBranchResult: { created: false, branch: '', base: '', path: '',
      detail: 'branch fix/gh-21-retry-path carries the gh-21 marker but its PR #40 is MERGED',
      dirty: false, halt_reason: 'merged' },
  })
  const note = result.note ?? ''
  check('it makes the outcome turn on the re-derived name, not on the marker',
    /only the name decides/.test(note), true)
  check('it names the reuse outcome and the fresh-cut outcome, not just one',
    /reuses the merged branch/.test(note) && /cuts a fresh branch/.test(note), true)
  check('it names the way out: clear the leftovers, or use another ticket',
    /delete the branch/.test(note) && /ticket of its own/.test(note), true)
}

// Scenario BT -- #87 review: step 5's re-attach action used to live in a
// "Not merged" bullet that sits between "Exactly one match" and "Two or more
// matches", mixing two axes (match count, PR state) in one bullet list. That
// left the re-attach action naming no match count, and put the
// two-or-more-matches bullet after the one that should never run for that
// case.
async function scenarioBT() {
  console.log('\n== scenario BT: step 5 bullets are keyed only on match count, not mixed with a PR-state sibling')
  const { captured } = await run({
    args: { existingBranch: true },
    initialReview: { correctness: [], advocate: [] },
    verify: () => undefined,
    staleness: () => [],
  })
  const p = captured.calls.find(c => c.label === 'branch:existing')?.prompt ?? ''
  const step5 = p.slice(p.indexOf('5. Only if step 4 matched nothing'), p.indexOf('6. Only if steps 4 and 5 matched nothing'))
  check('the step 5 slice was actually found', step5.length > 0, true)
  check('the re-attach action is folded into the Exactly one match bullet, not a sibling Not merged bullet',
    step5.includes('- Not merged:'), false)
  check('Two or more matches sits directly after Exactly one match, before No match',
    step5.indexOf('Two or more matches') > step5.indexOf('Exactly one match') &&
    step5.indexOf('No match') > step5.indexOf('Two or more matches'), true)
  check('the re-attach action (git worktree add, no -b) is still reachable from Exactly one match',
    step5.includes('git worktree add') && step5.includes('no -b, the branch already'), true)
}

// Scenario AZ -- the defect #81 is about. A lens points a fresh finding at a
// settled one because the fix for that finding introduced this one. Assuming
// it was a re-report readied a PR carrying a real regression, under
// unresolved_findings: []. The verifier decides now, and a suspect that still
// reproduces blocks like any other finding.
async function scenarioAZ() {
  console.log('\n== scenario AZ: a suspect that still reproduces becomes open and halts')
  const { result } = await run({
    args: { maxReviewRounds: 1 },
    draftPr: { opened: true, number: 24, url: 'https://example.invalid/pr/24', detail: 'stub draft' },
    initialReview: {
      correctness: [{ title: 'Route resolves from cwd', file: 'src/route.js',
        claim: 'wrong repo', evidence: 'route.js:12' }],
      advocate: [],
    },
    // f1 is fixed; f2, the suspect, is the hole that fix opened, so it is not.
    verify: (id) => id === 'f1' ? true : false,
    fixHead: () => 'fix00000000000000000000000000000000000001',
    tailReview: [{ title: 'The fix fails open when the path is unprovable',
      file: 'src/route.js', claim: 'gate is skipped entirely',
      evidence: 'route.js:20', duplicate_of: 'f1' }],
    staleness: () => [],
  })
  check('halted at Fix rather than readying the PR', result.halted_at, 'Fix')
  check('the suspect is reported as unresolved, not as noise',
    result.unresolved_findings?.length, 1)
  check('it is the suspect that is open',
    result.unresolved_findings?.[0]?.claim, 'gate is skipped entirely')
  check('it is no longer filed as an advisory suspect',
    result.regression_suspects?.length, 0)
}

// Scenario BA -- the budget case. Skipping verification must not silently
// downgrade a suspect to noise, so the run says it could not tell.
async function scenarioBA() {
  console.log('\n== scenario BA: an unverifiable suspect is reported unverified, not as noise')
  const { result } = await run({
    args: { maxReviewRounds: 1, tokenCeilings: { fix: 1 } },
    draftPr: { opened: true, number: 25, url: 'https://example.invalid/pr/25', detail: 'stub draft' },
    initialReview: {
      correctness: [{ title: 'Route resolves from cwd', file: 'src/route.js',
        claim: 'wrong repo', evidence: 'route.js:12' }],
      advocate: [],
    },
    verify: (id) => id === 'f1' ? true : undefined,
    fixHead: () => 'fix00000000000000000000000000000000000001',
    tailReview: [{ title: 'The fix fails open', file: 'src/route.js',
      claim: 'gate is skipped', evidence: 'route.js:20', duplicate_of: 'f1' }],
    staleness: () => [],
  })
  check('the run does not claim the suspect was judged',
    result.suspects_unverified === true || (result.unresolved_findings?.length ?? 0) > 0,
    true)
}

// Scenario BU -- #38: a check green at the base commit and red after
// Implement (the version-bump incident this ticket is about) is fixed in
// one checks-only round before Review ever runs, so the diff a reviewer
// reads already carries the fix and no reviewer finding is ever recorded.
async function scenarioBU() {
  console.log('\n== scenario BU: a check green at baseline and red after Implement is fixed before Review, with no reviewer finding')
  const { result, captured } = await run({
    args: { openPr: true },
    discovery: { checks: [{ name: 'run-tests.sh', command: 'bash scripts/run-tests.sh' }],
      detail: 'stub: found in AGENTS.md Commands' },
    checkRuns: (attempt) => attempt === 1
      ? { results: [{ name: 'run-tests.sh', command: 'bash scripts/run-tests.sh',
          exit_code: 0, output: 'ok' }], dirty: false }
      : attempt === 2
      ? { results: [{ name: 'run-tests.sh', command: 'bash scripts/run-tests.sh',
          exit_code: 1, output: 'FAILURE: workflows/ changed with no version bump' }], dirty: false }
      : { results: [{ name: 'run-tests.sh', command: 'bash scripts/run-tests.sh',
          exit_code: 0, output: 'OK' }], dirty: false },
    checksFixResult: { head_sha: 'checksfix00000000000000000000000000000002',
      note: 'bumped the version', scored: true },
    prResult: { opened: true, url: 'https://example.invalid/pr/38', note: 'stub ready' },
  })
  check('the baseline ran green, before Implement', callCount(captured, 'checks:run:1'), 1)
  const checksFix = captured.calls.find(c => c.label === 'checks:fix')?.prompt ?? ''
  check('the checks-only fix ran', checksFix.length > 0, true)
  check('the fix prompt carries the failing check\'s command',
    checksFix.includes('bash scripts/run-tests.sh'), true)
  check('the fix prompt carries its exit code', checksFix.includes('exited 1'), true)
  check('the fix prompt carries its output verbatim',
    checksFix.includes('FAILURE: workflows/ changed with no version bump'), true)
  check('the check was re-run after the pre-review fix landed', callCount(captured, 'checks:run:3'), 1)
  const checksFixIdx = captured.calls.findIndex(c => c.label === 'checks:fix')
  const reviewIdx = captured.calls.findIndex(c => c.label.startsWith('review:'))
  check('the checks-only fix ran before any review lens',
    checksFixIdx >= 0 && reviewIdx >= 0 && checksFixIdx < reviewIdx, true)
  const reviewPrompt = captured.calls.find(c => c.label.startsWith('review:'))?.prompt ?? ''
  check('a review lens ran', reviewPrompt.length > 0, true)
  check('review reads the fixed range, including the checks-only commit',
    reviewPrompt.includes('checksfix00000000000000000000000000000002'), true)
  check('the run does not halt', result.halted_at, undefined)
  check('no reviewer finding was recorded for the check', (result.unresolved_findings ?? []).length, 0)
  check('the result reports the check as no longer red', result.checks?.red?.length, 0)
  check('the run reaches the PR phase', result.pr?.opened, true)
}

// Scenario BV -- #38: a check red at the base commit, before any work
// started, is the repo's own environment, not this run's doing. It must be
// dropped outright, never merely downgraded, so it cannot re-enter later as
// something an unrelated fix round is told to act on.
async function scenarioBV() {
  console.log('\n== scenario BV: a check red at baseline is dropped as environmental and never reaches a fixer')
  const { result, captured } = await run({
    args: { maxReviewRounds: 1 },
    discovery: { checks: [{ name: 'run-go-tests.sh', command: 'bash scripts/run-go-tests.sh' }],
      detail: 'stub' },
    checkRuns: () => ({ results: [{ name: 'run-go-tests.sh', command: 'bash scripts/run-go-tests.sh',
      exit_code: 1, output: 'go: command not found' }], dirty: false }),
    initialReview: {
      correctness: [{ title: 'Off-by-one', file: 'src/parser.js',
        claim: 'boundary is wrong', evidence: 'parser.js:12' }],
      advocate: [],
    },
    verify: () => undefined,
    fixHead: () => 'fix00000000000000000000000000000000000003',
    staleness: () => [],
  })
  check('the baseline ran exactly once', callCount(captured, 'checks:run:1'), 1)
  check('nothing was re-checked after Implement, nothing left to check', callCount(captured, 'checks:run:2'), 0)
  check('the checks-only pre-review fix never ran', callCount(captured, 'checks:fix'), 0)
  check('halted at Fix, over the unrelated finding, not a check', result.halted_at, 'Fix')
  const fix1 = captured.calls.find(c => c.label === 'fix:1')?.prompt ?? ''
  check('the fix phase ran', fix1.length > 0, true)
  check('the dropped check\'s command never reaches the fixer',
    fix1.includes('run-go-tests.sh'), false)
  check('the result explains it was dropped, not left open',
    (result.checks?.detail ?? '').includes('dropped 1 as environmental'), true)
  check('no red check is reported', result.checks?.red?.length, 0)
}

// Scenario BW -- #38: most repos have never heard of any of this. Discovery
// finding nothing must be a logged, ordinary outcome, never a halt, and must
// not spend a check-run call it has nothing to run.
async function scenarioBW() {
  console.log('\n== scenario BW: discovery finding no repo checks is logged, not a halt')
  const { result, captured } = await run({})
  check('discovery ran exactly once', callCount(captured, 'checks:discover'), 1)
  check('no check-run call was made', callCount(captured, 'checks:run:1'), 0)
  check('the run does not halt', result.halted_at, undefined)
  check('discovery finding nothing is logged',
    captured.logs.some(l => /no repo-advertised checks found/.test(l)), true)
  check('the final result reports zero discovered checks', result.checks?.discovered, 0)
}

// Scenario BX -- #38, #87: existingBranch resumes a worktree that already
// carries the branch's own commits, so there is no clean base tree left to
// classify a check against. A red check there is reported, never blocking.
async function scenarioBX() {
  console.log('\n== scenario BX: existingBranch skips the baseline and never blocks on a discovered check')
  const { result, captured } = await run({
    args: { existingBranch: true, openPr: true },
    discovery: { checks: [{ name: 'lint.sh', command: 'bash scripts/lint.sh' }], detail: 'stub' },
    checkRuns: () => ({ results: [{ name: 'lint.sh', command: 'bash scripts/lint.sh',
      exit_code: 1, output: 'lint: 3 problems' }], dirty: false }),
    prResult: { opened: true, url: 'https://example.invalid/pr/38x', note: 'stub ready' },
  })
  const runLabels = captured.calls.filter(c => c.label.startsWith('checks:run:'))
  check('exactly one check run happened, no separate baseline pass', runLabels.length, 1)
  check('the checks-only pre-review fix never ran', callCount(captured, 'checks:fix'), 0)
  check('the run does not halt', result.halted_at, undefined)
  check('the check is reported as non-blocking', result.checks?.blocking, false)
  check('the check is still reported red, for visibility', result.checks?.red?.length, 1)
  check('the run reaches the PR phase', result.pr?.opened, true)
}

// Scenario BY -- #38: a cap stated only in a prompt is a request; this
// proves the bound is a real slice. Both ends of a huge check's output must
// survive, since a gate prints its resolved repo and branch first and its
// verdict last, and only the middle is safe to drop.
async function scenarioBY() {
  console.log('\n== scenario BY: oversized check output is truncated with head and tail kept, middle marked')
  const bigOutput = 'HEAD_MARKER' + 'x'.repeat(5000) + 'MIDDLE_MARKER_XYZ' + 'y'.repeat(15000) + 'TAIL_MARKER'
  const { captured } = await run({
    discovery: { checks: [{ name: 'run-tests.sh', command: 'bash scripts/run-tests.sh' }], detail: 'stub' },
    checkRuns: (attempt) => attempt === 1
      ? { results: [{ name: 'run-tests.sh', command: 'bash scripts/run-tests.sh', exit_code: 0, output: 'ok' }], dirty: false }
      : { results: [{ name: 'run-tests.sh', command: 'bash scripts/run-tests.sh', exit_code: 1, output: bigOutput }], dirty: false },
  })
  const checksFix = captured.calls.find(c => c.label === 'checks:fix')?.prompt ?? ''
  check('the pre-review fix ran', checksFix.length > 0, true)
  check('the head of the output survives', checksFix.includes('HEAD_MARKER'), true)
  check('the tail of the output survives', checksFix.includes('TAIL_MARKER'), true)
  check('the truncation marker is present', checksFix.includes('[touchstone: truncated,'), true)
  check('the middle of the output does not reach the prompt',
    checksFix.includes('MIDDLE_MARKER_XYZ'), false)
}

// Scenario BZ -- #38: redness is keyed on exit_code alone. AGENTS.md is
// explicit that exit 2 and exit 4 are not passes either, and the schema
// carries no pass/fail field a model could misjudge one against.
async function scenarioBZ() {
  console.log('\n== scenario BZ: a non-zero exit code (4, could-not-measure) is treated as red')
  const { captured } = await run({
    discovery: { checks: [{ name: 'coverage-gate.sh', command: 'bash scripts/coverage-gate.sh' }], detail: 'stub' },
    checkRuns: (attempt) => attempt === 1
      ? { results: [{ name: 'coverage-gate.sh', command: 'bash scripts/coverage-gate.sh', exit_code: 0, output: 'ok' }], dirty: false }
      : { results: [{ name: 'coverage-gate.sh', command: 'bash scripts/coverage-gate.sh', exit_code: 4, output: 'could not measure' }], dirty: false },
  })
  check('a check that merely ran, exit 4, still triggers the pre-review fix', callCount(captured, 'checks:fix'), 1)
  const checksFix = captured.calls.find(c => c.label === 'checks:fix')?.prompt ?? ''
  check('the fix phase ran', checksFix.length > 0, true)
  check('the prompt carries the exit code verbatim', checksFix.includes('exited 4'), true)
}

for (const scenario of [scenarioA, scenarioB, scenarioG, scenarioC, scenarioD, scenarioE, scenarioH,
                        scenarioI, scenarioJ, scenarioK, scenarioL, scenarioM, scenarioN,
                        scenarioO, scenarioP, scenarioQ, scenarioR, scenarioS, scenarioT,
                        scenarioU, scenarioV, scenarioW, scenarioX, scenarioY,
                        scenarioZ, scenarioAA, scenarioAB, scenarioAC, scenarioAD,
                        scenarioAE, scenarioAF, scenarioAG, scenarioAH, scenarioAI,
                        scenarioAJ, scenarioAK, scenarioAL, scenarioAM, scenarioAN,
                        scenarioAO, scenarioAS, scenarioAT, scenarioAU, scenarioAV,
                        scenarioAW, scenarioAX, scenarioAY,
                        scenarioAP, scenarioAQ, scenarioAR, scenarioBB, scenarioBC, scenarioBD,
                        scenarioBE, scenarioAZ, scenarioBA, scenarioBF, scenarioBG,
                        scenarioBH, scenarioBI, scenarioBJ, scenarioBK, scenarioBL,
                        scenarioBM, scenarioBN, scenarioBO, scenarioBP, scenarioBQ,
                        scenarioBR, scenarioBS, scenarioBT, scenarioBU, scenarioBV, scenarioBW,
                        scenarioBX, scenarioBY, scenarioBZ]) {
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
